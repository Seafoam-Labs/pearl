//! Archive installation with bounded extraction, ownership checks and a recovery journal.
const std = @import("std");
const glib = @import("glib2");
const gio = @import("gio2");
const io = @import("../config/io.zig");
const pkg = @import("package.zig");
const model = @import("package_model.zig");
const c = pkg.c;
const archive = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});
extern fn renameat2(c_int, [*:0]const u8, c_int, [*:0]const u8, c_uint) c_int;
extern fn mkdtemp([*:0]u8) ?[*:0]u8;
extern fn flock(c_int, c_int) c_int;
pub const Receipt = struct { id: []const u8, version: []const u8, digest: []const u8, origin: []const u8 };
const Member = struct { path: []const u8, digest: []const u8 };
pub const Journal = struct { id: []const u8, stage: []const u8, receipt: Receipt, previous: ?Receipt = null, operation: enum { publish, remove } = .publish, members: []const Member = &.{} };
pub const Store = struct {
    a: std.mem.Allocator,
    root: [:0]const u8,
    state: [:0]const u8,
    lock: c_int,
    pub fn init(a: std.mem.Allocator) !Store {
        const root = try std.fmt.allocPrintSentinel(a, "{s}/pearl/themes", .{std.mem.span(glib.getUserDataDir())}, 0);
        const state = try std.fmt.allocPrintSentinel(a, "{s}/pearl/themes", .{std.mem.span(glib.getUserStateDir())}, 0);
        try io.mkdir(root);
        try io.mkdir(state);
        for ([_][:0]const u8{ root, state }) |directory| {
            const fd = c.open(directory, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
            if (fd < 0) return error.ThemeStoreDirectory;
            _ = c.close(fd);
        }
        const lock = c.open(try std.fmt.allocPrintSentinel(a, "{s}/writer.lock", .{state}, 0), c.O_CREAT | c.O_RDWR | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
        if (lock < 0) return error.ThemeWriterUnavailable;
        errdefer _ = c.close(lock);
        if (flock(lock, 2 | 4) != 0) return error.ThemeWriterBusy;
        var self: Store = .{ .a = a, .root = root, .state = state, .lock = lock };
        try self.recover();
        return self;
    }
    pub fn deinit(self: Store) void {
        _ = c.close(self.lock);
    }
    fn path(self: Store, suffix: []const u8) ![:0]const u8 {
        return std.fmt.allocPrintSentinel(self.a, "{s}/{s}", .{ self.root, suffix }, 0);
    }
    fn record(self: Store, id: []const u8, previous: bool) ![:0]const u8 {
        try model.identifier(id);
        return std.fmt.allocPrintSentinel(self.a, "{s}/{s}{s}.json", .{ self.state, if (previous) "previous-" else "", id }, 0);
    }
    pub fn receipt(self: Store, id: []const u8) !?Receipt {
        const file = try io.read(self.a, try self.record(id, false), 65536, null);
        if (file.missing) return null;
        const value = try model.parse(Receipt, self.a, file.bytes, 65536);
        if (!std.mem.eql(u8, value.id, id)) return error.InvalidThemeReceipt;
        try model.digest(value.digest);
        _ = try model.version(value.version);
        try model.text(value.origin, 4096);
        return value;
    }
    fn journalPath(self: Store) ![:0]const u8 {
        return std.fmt.allocPrintSentinel(self.a, "{s}/journal.json", .{self.state}, 0);
    }
    fn recover(self: *Store) !void {
        const file = try io.read(self.a, try self.journalPath(), 1048576, null);
        if (file.missing) return;
        const j = try model.parse(Journal, self.a, file.bytes, 1048576);
        try model.identifier(j.id);
        try model.digest(j.receipt.digest);
        if (!std.mem.eql(u8, j.id, j.receipt.id)) return error.InvalidThemeJournal;
        if (j.previous) |old| {
            try model.digest(old.digest);
            if (!std.mem.eql(u8, j.id, old.id)) return error.InvalidThemeJournal;
        }
        try model.relative(j.stage);
        if (!std.mem.startsWith(u8, j.stage, "stage-") or std.mem.indexOfScalar(u8, j.stage, '/') != null) return error.InvalidThemeJournal;
        const destination = try self.path(j.id);
        const stage = try self.path(try std.fmt.allocPrint(self.a, ".{s}", .{j.stage}));
        if (j.operation == .remove) {
            if (glib.fileTest(destination, .{ .exists = true }) != 0) {
                if (glib.fileTest(stage, .{ .exists = true }) != 0) return error.ThemeRecoveryConflict;
                const untouched = try pkg.load(self.a, destination);
                if (!std.mem.eql(u8, &untouched.digest, j.receipt.digest)) return error.ThemeEdited;
            } else {
                if (j.members.len == 0 or j.members.len > model.max_entries) return error.InvalidThemeJournal;
                for (try pkg.remaining(self.a, stage)) |member| {
                    var owned = false;
                    for (j.members) |expected| if (std.mem.eql(u8, member.path, expected.path) and std.mem.eql(u8, &model.hash(member.bytes), expected.digest)) {
                        owned = true;
                        break;
                    };
                    if (!owned) return error.ThemeEdited;
                }
                try removeTree(self.a, stage);
                _ = c.unlink(try self.record(j.id, false));
            }
            _ = c.unlink(try self.journalPath());
            return;
        }
        const installed = pkg.load(self.a, destination) catch null;
        const staged = pkg.load(self.a, stage) catch null;
        if (installed != null and std.mem.eql(u8, &installed.?.digest, j.receipt.digest)) {
            if (j.previous) |old| {
                const previous = try self.path(try std.fmt.allocPrint(self.a, ".previous-{s}", .{j.id}));
                if (glib.fileTest(stage, .{ .is_dir = true }) != 0) {
                    if (staged == null or !std.mem.eql(u8, &staged.?.digest, old.digest)) return error.ThemeRecoveryConflict;
                    try self.checkPrevious(j.id);
                    try removeTree(self.a, previous);
                    if (std.c.rename(stage, previous) != 0) return error.ThemePublishFailed;
                }
                try io.atomic(try self.record(j.id, true), try std.json.Stringify.valueAlloc(self.a, old, .{}), false);
            }
            try io.atomic(try self.record(j.id, false), try std.json.Stringify.valueAlloc(self.a, j.receipt, .{}), false);
            crashPoint("receipt");
        } else {
            // An interrupted pre-publish operation may discard only its exact
            // staged bytes. Never erase a changed installed/previous package.
            if (installed) |p| {
                const old = j.previous orelse return error.ThemeRecoveryConflict;
                if (!std.mem.eql(u8, &p.digest, old.digest)) return error.ThemeRecoveryConflict;
            } else if (glib.fileTest(destination, .{ .exists = true }) != 0 or j.previous != null) return error.ThemeRecoveryConflict;
            if (staged == null or !std.mem.eql(u8, &staged.?.digest, j.receipt.digest)) return error.ThemeRecoveryConflict;
        }
        try removeTree(self.a, stage);
        _ = c.unlink(try self.journalPath());
    }
    fn checkPrevious(self: Store, id: []const u8) !void {
        const path_ = try self.path(try std.fmt.allocPrint(self.a, ".previous-{s}", .{id}));
        if (glib.fileTest(path_, .{ .exists = true }) == 0) return;
        const record_ = try io.read(self.a, try self.record(id, true), 65536, null);
        if (record_.missing) return error.UnmanagedTheme;
        const old = try model.parse(Receipt, self.a, record_.bytes, 65536);
        const package = try pkg.load(self.a, path_);
        if (!std.mem.eql(u8, &package.digest, old.digest)) return error.ThemeEdited;
    }
    pub fn publish(self: *Store, package: pkg.Package, origin: []const u8) !Receipt {
        const id = package.manifest.id;
        try self.checkPrevious(id);
        const destination = try self.path(id);
        const old = try self.receipt(id);
        const exists = glib.fileTest(destination, .{ .exists = true }) != 0;
        if (exists) {
            const receipt_ = old orelse return error.UnmanagedTheme;
            if (!std.mem.eql(u8, receipt_.origin, origin)) return error.ThemeRepositoryConflict;
            const installed = try pkg.load(self.a, destination);
            if (!std.mem.eql(u8, &installed.digest, receipt_.digest)) return error.ThemeEdited;
        }
        // A same-ID system/manual package cannot be silently shadowed.
        const catalog = try @import("catalog.zig").scan(self.a);
        for (catalog.entries) |entry| if (std.mem.eql(u8, entry.package.manifest.id, id) and !std.mem.eql(u8, entry.path, destination)) return error.DuplicateThemeId;
        const tmp = try std.fmt.allocPrintSentinel(self.a, "{s}/.stage-XXXXXX", .{self.root}, 0);
        if (mkdtemp(tmp) == null) return error.ThemeStagingFailed;
        var journaled = false;
        defer if (!journaled) removeTree(self.a, tmp) catch {};
        for (package.files) |file| {
            const target = try std.fmt.allocPrintSentinel(self.a, "{s}/{s}", .{ tmp, file.path }, 0);
            try io.mkdir(try self.a.dupeZ(u8, std.fs.path.dirname(target).?));
            try io.atomic(target, file.bytes, true);
        }
        const staged = try pkg.load(self.a, tmp);
        if (!std.mem.eql(u8, &staged.digest, &package.digest)) return error.ThemeChangedDuringRead;
        const next: Receipt = .{ .id = id, .version = package.manifest.asset_version, .digest = try self.a.dupe(u8, &package.digest), .origin = origin };
        const j: Journal = .{ .id = id, .stage = std.fs.path.basename(tmp)[1..], .receipt = next, .previous = if (exists) old else null };
        try io.atomic(try self.journalPath(), try std.json.Stringify.valueAlloc(self.a, j, .{}), false);
        journaled = true;
        crashPoint("journal");
        if (renameat2(c.AT_FDCWD, tmp, c.AT_FDCWD, destination, if (exists) 2 else 1) != 0) return error.ThemePublishFailed;
        crashPoint("publish");
        const fd = c.open(self.root, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
        if (fd >= 0) {
            defer _ = c.close(fd);
            if (c.fsync(fd) != 0) return error.ThemePublishFailed;
        }
        try self.recover();
        return next;
    }
    pub fn remove(self: *Store, id: []const u8) !void {
        const old = try self.receipt(id) orelse return error.UnmanagedTheme;
        const path_ = try self.path(id);
        const package = try pkg.load(self.a, path_);
        if (!std.mem.eql(u8, &package.digest, old.digest)) return error.ThemeEdited;
        var members: std.ArrayList(Member) = .empty;
        for (package.files) |file| try members.append(self.a, .{ .path = file.path, .digest = try self.a.dupe(u8, &model.hash(file.bytes)) });
        const stage = try std.fmt.allocPrintSentinel(self.a, "{s}/.stage-XXXXXX", .{self.root}, 0);
        if (mkdtemp(stage) == null or c.rmdir(stage) != 0) return error.ThemeStagingFailed;
        const journal: Journal = .{ .id = id, .stage = std.fs.path.basename(stage)[1..], .receipt = old, .operation = .remove, .members = members.items };
        try io.atomic(try self.journalPath(), try std.json.Stringify.valueAlloc(self.a, journal, .{}), false);
        crashPoint("remove-journal");
        if (renameat2(c.AT_FDCWD, path_, c.AT_FDCWD, stage, 1) != 0) return error.ThemeRemoveFailed;
        const fd = c.open(self.root, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
        if (fd < 0) return error.ThemeRemoveFailed;
        defer _ = c.close(fd);
        if (c.fsync(fd) != 0) return error.ThemeRemoveFailed;
        crashPoint("remove-publish");
        try self.recover();
    }
    pub fn rollback(self: *Store, id: []const u8) !Receipt {
        const old = try self.receipt(id) orelse return error.UnmanagedTheme;
        const previous = try pkg.load(self.a, try self.path(try std.fmt.allocPrint(self.a, ".previous-{s}", .{id})));
        return self.publish(previous, old.origin);
    }
    pub fn unpack(self: *Store, bytes: []const u8, cancel: *gio.Cancellable) !pkg.Package {
        if (bytes.len > model.max_bytes) return error.ThemeArchiveLimit;
        const handle = archive.archive_read_new() orelse return error.ThemeArchive;
        defer _ = archive.archive_read_free(handle);
        _ = archive.archive_read_support_filter_gzip(handle);
        _ = archive.archive_read_support_format_tar(handle);
        if (archive.archive_read_open_memory(handle, bytes.ptr, bytes.len) != archive.ARCHIVE_OK) return error.ThemeArchive;
        const temp = try std.fmt.allocPrintSentinel(self.a, "{s}/.download-XXXXXX", .{self.root}, 0);
        if (mkdtemp(temp) == null) return error.ThemeStagingFailed;
        defer removeTree(self.a, temp) catch {};
        var paths: std.StringHashMap(void) = .init(self.a);
        var entry: ?*archive.struct_archive_entry = null;
        var total: usize = 0;
        while (true) {
            if (cancel.isCancelled() != 0) return error.Cancelled;
            const code = archive.archive_read_next_header(handle, &entry);
            if (code == archive.ARCHIVE_EOF) break;
            if (code != archive.ARCHIVE_OK) return error.ThemeArchive;
            if (paths.count() >= model.max_entries) return error.ThemeEntryLimit;
            const raw = std.mem.span(archive.archive_entry_pathname(entry) orelse return error.ThemeArchive);
            const directory = archive.archive_entry_filetype(entry) == 0o040000;
            const name = if (directory) std.mem.trimEnd(u8, raw, "/") else raw;
            try model.relative(name);
            if (archive.archive_entry_symlink(entry) != null or archive.archive_entry_hardlink(entry) != null or (!directory and archive.archive_entry_filetype(entry) != 0o100000)) return error.ThemeArchiveSpecialFile;
            const key = try self.a.dupe(u8, name);
            if (paths.contains(key)) return error.ThemeArchiveDuplicate;
            try paths.put(key, {});
            const path_ = try std.fmt.allocPrintSentinel(self.a, "{s}/{s}", .{ temp, name }, 0);
            if (directory) {
                try io.mkdir(path_);
                continue;
            }
            const size = archive.archive_entry_size(entry);
            if (size < 0 or size > model.max_bytes - total) return error.ThemeArchiveLimit;
            const data = try self.a.alloc(u8, @intCast(size));
            total += data.len;
            var pos: usize = 0;
            while (pos < data.len) {
                const n = archive.archive_read_data(handle, data[pos..].ptr, data.len - pos);
                if (n <= 0) return error.ThemeArchive;
                pos += @intCast(n);
            }
            var extra: u8 = undefined;
            if (archive.archive_read_data(handle, &extra, 1) != 0) return error.ThemeArchive;
            try io.mkdir(try self.a.dupeZ(u8, std.fs.path.dirname(path_).?));
            try io.atomic(path_, data, true);
        }
        return pkg.load(self.a, temp);
    }
};
fn crashPoint(point: []const u8) void {
    if (@import("build_options").test_hooks) {
        if (glib.getenv("PEARL_TEST_THEME_CRASH")) |value| if (std.mem.eql(u8, std.mem.span(value), point)) std.process.exit(87);
    }
}
pub fn removeTree(a: std.mem.Allocator, path: [:0]const u8) anyerror!void {
    const fd = c.open(path, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) {
        if (std.posix.errno(fd) == .NOENT) return;
        return error.ThemeDirectory;
    }
    const dir = c.fdopendir(fd) orelse {
        _ = c.close(fd);
        return error.ThemeDirectory;
    };
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const z = try a.dupeZ(u8, name);
        var info: c.struct_stat = undefined;
        if (c.fstatat(fd, z, &info, c.AT_SYMLINK_NOFOLLOW) != 0) return error.ThemeFile;
        if (info.st_mode & c.S_IFMT == c.S_IFDIR) try removeTree(a, try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ path, name }, 0)) else if (c.unlinkat(fd, z, 0) != 0) return error.ThemeRemoveFailed;
    }
    if (c.rmdir(path) != 0) return error.ThemeRemoveFailed;
}
