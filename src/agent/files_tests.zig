//! Filesystem executor contract tests. All fixtures live in private mkdtemp
//! directories under /tmp or /dev/shm; no real user files are touched. Trash
//! side effects are cleaned out of the user's trash afterwards. Mount-boundary
//! enforcement (RESOLVE_NO_XDEV plus the root-device comparison) cannot be
//! exercised with a real mount without privileges; the symlink and substitution
//! tests cover the reachable escape paths.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const files = @import("files.zig");
const t = std.testing;
const linux = std.os.linux;
const c = std.c;
extern fn mkdtemp([*:0]u8) ?[*:0]u8;

fn writeAbs(path: [:0]const u8, bytes: []const u8) !void {
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c_uint, 0o600));
    if (fd < 0) return error.FixtureWrite;
    defer _ = c.close(fd);
    var done: usize = 0;
    while (done < bytes.len) {
        const n = c.write(fd, bytes[done..].ptr, bytes.len - done);
        if (n <= 0) return error.FixtureWrite;
        done += @intCast(n);
    }
}

fn readAbs(a: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.FixtureRead;
    defer _ = c.close(fd);
    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx)) != .SUCCESS) return error.FixtureRead;
    const buf = try a.alloc(u8, @intCast(stx.size));
    errdefer a.free(buf);
    var done: usize = 0;
    while (done < buf.len) {
        const n = c.read(fd, buf[done..].ptr, buf.len - done);
        if (n < 0) return error.FixtureRead;
        if (n == 0) break;
        done += @intCast(n);
    }
    return buf[0..done];
}

fn lexists(path: [:0]const u8) bool {
    var stx: linux.Statx = undefined;
    return linux.errno(linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx)) == .SUCCESS;
}

/// Self-contained recursive fixture cleanup (never follows symlinks).
fn removeTree(a: std.mem.Allocator, path: [:0]const u8) void {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return;
    const dir = c.fdopendir(fd) orelse {
        _ = c.close(fd);
        return;
    };
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(entry.*.name[0..], 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const z = a.dupeSentinel(u8, name, 0) catch continue;
        defer a.free(z);
        var stx: linux.Statx = undefined;
        if (linux.errno(linux.statx(fd, z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx)) != .SUCCESS) continue;
        if (stx.mode & linux.S.IFMT == linux.S.IFDIR) {
            const child = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ path, name }, 0) catch continue;
            defer a.free(child);
            removeTree(a, child);
        } else {
            _ = c.unlinkat(fd, z, 0);
        }
    }
    _ = c.rmdir(path);
}

const Fixture = struct {
    root: [:0]u8,
    a: std.mem.Allocator,

    fn init(a: std.mem.Allocator, base: []const u8) !Fixture {
        const template = try std.fmt.allocPrintSentinel(a, "{s}/pearl-fs-test-XXXXXX", .{base}, 0);
        const root = mkdtemp(template) orelse return error.FixtureUnavailable;
        return .{ .root = std.mem.span(root), .a = a };
    }

    fn deinit(self: *Fixture) void {
        removeTree(self.a, self.root);
        self.a.free(self.root);
    }

    fn path(self: *Fixture, rel: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(self.a, "{s}/{s}", .{ self.root, rel }, 0);
    }

    fn write(self: *Fixture, rel: []const u8, bytes: []const u8) !void {
        const p = try self.path(rel);
        defer self.a.free(p);
        try writeAbs(p, bytes);
    }

    fn append(self: *Fixture, rel: []const u8, bytes: []const u8) !void {
        const p = try self.path(rel);
        defer self.a.free(p);
        const fd = c.open(p, .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true }, @as(c_uint, 0));
        if (fd < 0) return error.FixtureWrite;
        defer _ = c.close(fd);
        var done: usize = 0;
        while (done < bytes.len) {
            const n = c.write(fd, bytes[done..].ptr, bytes.len - done);
            if (n <= 0) return error.FixtureWrite;
            done += @intCast(n);
        }
    }

    fn read(self: *Fixture, rel: []const u8) ![]u8 {
        const p = try self.path(rel);
        defer self.a.free(p);
        return readAbs(self.a, p);
    }

    fn mkdir(self: *Fixture, rel: []const u8) !void {
        const p = try self.path(rel);
        defer self.a.free(p);
        if (glib.mkdirWithParents(p, 0o700) != 0) return error.FixtureDirectory;
    }

    fn symlink(self: *Fixture, target: []const u8, rel: []const u8) !void {
        const p = try self.path(rel);
        defer self.a.free(p);
        const tz = try self.a.dupeSentinel(u8, target, 0);
        defer self.a.free(tz);
        if (c.symlink(tz, p) != 0) return error.FixtureSymlink;
    }

    fn mkfifo(self: *Fixture, rel: []const u8) !void {
        const p = try self.path(rel);
        defer self.a.free(p);
        if (linux.errno(linux.mknodat(linux.AT.FDCWD, p, linux.S.IFIFO | 0o600, 0)) != .SUCCESS) return error.FixtureFifo;
    }

    fn exists(self: *Fixture, rel: []const u8) bool {
        const p = self.path(rel) catch return false;
        defer self.a.free(p);
        return lexists(p);
    }

    fn rename(self: *Fixture, from: []const u8, to: []const u8) !void {
        const a = try self.path(from);
        defer self.a.free(a);
        const b = try self.path(to);
        defer self.a.free(b);
        if (linux.errno(linux.renameat2(linux.AT.FDCWD, a, linux.AT.FDCWD, b, .{})) != .SUCCESS) return error.FixtureRename;
    }

    fn unlink(self: *Fixture, rel: []const u8) !void {
        const p = try self.path(rel);
        defer self.a.free(p);
        if (c.unlink(p) != 0) return error.FixtureUnlink;
    }

    fn countTemps(self: *Fixture) !usize {
        const fd = c.open(self.root, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, @as(c_uint, 0));
        if (fd < 0) return error.FixtureDirectory;
        const dir = c.fdopendir(fd) orelse {
            _ = c.close(fd);
            return error.FixtureDirectory;
        };
        defer _ = c.closedir(dir);
        var n: usize = 0;
        while (c.readdir(dir)) |entry| {
            const name = std.mem.sliceTo(entry.*.name[0..], 0);
            if (std.mem.startsWith(u8, name, ".pearl-tmp-")) n += 1;
        }
        return n;
    }

    fn mode(self: *Fixture, rel: []const u8) !u16 {
        const p = try self.path(rel);
        defer self.a.free(p);
        var stx: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .{ .MODE = true }, &stx)) != .SUCCESS) return error.FixtureStat;
        return stx.mode;
    }
};

const Rights = struct { read: bool = true, create: bool = true, delete: bool = true };

fn makeTools(a: std.mem.Allocator, root: []const u8, rights: Rights) !files.Tools {
    const roots = [_]files.FolderGrant{.{ .id = "docs", .path = root, .read = rights.read, .create = rights.create, .delete = rights.delete }};
    return files.Tools.init(a, .{ .enabled = true, .roots = &roots });
}

fn newCancel() *gio.Cancellable {
    return gio.Cancellable.new();
}

fn json(a: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
}

fn field(v: std.json.Value, name: []const u8) std.json.Value {
    return v.object.get(name) orelse .null;
}

fn str(v: std.json.Value, name: []const u8) []const u8 {
    const f = field(v, name);
    return if (f == .string) f.string else "";
}

fn statusIs(v: std.json.Value, expected: []const u8) bool {
    return std.mem.eql(u8, str(v, "status"), expected);
}

fn search(a: std.mem.Allocator, tools: *files.Tools, root_id: []const u8, query: []const u8, mode: []const u8, cursor: ?u64, cancel: *gio.Cancellable) !std.json.Value {
    const args = try std.json.Stringify.valueAlloc(a, .{ .root_id = root_id, .query = query, .mode = mode, .cursor = cursor }, .{});
    return json(a, try tools.dispatch(a, "search_files", args, cancel));
}

fn firstMatchId(v: std.json.Value) []const u8 {
    const matches = field(v, "matches");
    if (matches != .array or matches.array.items.len == 0) return "";
    return str(matches.array.items[0], "file_id");
}

fn matchById(v: std.json.Value, name: []const u8) ?std.json.Value {
    const matches = field(v, "matches");
    if (matches != .array) return null;
    for (matches.array.items) |m| {
        if (std.mem.eql(u8, str(m, "name"), name)) return m;
    }
    return null;
}

fn eachDirEntry(dirpath: [:0]const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const u8) void) void {
    const fd = c.open(dirpath, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return;
    const dir = c.fdopendir(fd) orelse {
        _ = c.close(fd);
        return;
    };
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(entry.*.name[0..], 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        f(ctx, name);
    }
}

/// Remove fixtures this suite trashed from the user's trash (unique names).
fn cleanupTrash(a: std.mem.Allocator, basename: []const u8) void {
    const Ctx = struct { a: std.mem.Allocator, base: []const u8, cand: []const u8 };
    const visit = struct {
        fn f(ctx: Ctx, name: []const u8) void {
            if (!std.mem.startsWith(u8, name, ctx.base)) return;
            const fp = std.fmt.allocPrintSentinel(ctx.a, "{s}/files/{s}", .{ ctx.cand, name }, 0) catch return;
            defer ctx.a.free(fp);
            _ = c.unlink(fp);
            const ip = std.fmt.allocPrintSentinel(ctx.a, "{s}/info/{s}.trashinfo", .{ ctx.cand, name }, 0) catch return;
            defer ctx.a.free(ip);
            _ = c.unlink(ip);
        }
    }.f;
    var buf: [512]u8 = undefined;
    const home = std.mem.printSentinel(&buf, "{s}/Trash", .{std.mem.span(glib.getUserDataDir())}, 0) catch return;
    var hbuf: [512]u8 = undefined;
    const home_files = std.mem.printSentinel(&hbuf, "{s}/files", .{home}, 0) catch return;
    eachDirEntry(home_files, Ctx{ .a = a, .base = basename, .cand = home }, visit);
    var buf2: [128]u8 = undefined;
    const top = std.mem.printSentinel(&buf2, "/.Trash-{d}", .{linux.getuid()}, 0) catch return;
    var tbuf: [128]u8 = undefined;
    const top_files = std.mem.printSentinel(&tbuf, "{s}/files", .{top}, 0) catch return;
    eachDirEntry(top_files, Ctx{ .a = a, .base = basename, .cand = top }, visit);
}

fn fdCount() usize {
    const fd = c.open("/proc/self/fd", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return 0;
    const dir = c.fdopendir(fd) orelse {
        _ = c.close(fd);
        return 0;
    };
    defer _ = c.closedir(dir);
    var n: usize = 0;
    while (c.readdir(dir)) |_| n += 1;
    return n;
}

test "disabled local config withholds tools and denies dispatch" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tools = try files.Tools.init(a, .{ .enabled = false, .roots = &[_]files.FolderGrant{.{ .id = "docs", .path = "/tmp", .read = true }} });
    defer tools.deinit();
    try t.expect(tools.tools() == null);
    const cancel = newCancel();
    defer cancel.unref();
    const out = try tools.dispatch(a, "search_files", "{\"root_id\":\"root:docs\",\"query\":\"x\"}", cancel);
    const v = try json(a, out);
    try t.expect(statusIs(v, "denied"));
    try t.expectEqualStrings("LocalFilesDisabled", str(v, "error"));
}

test "init rejects duplicate, relative and protected grants" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = files.FolderGrant{ .id = "docs", .path = "/tmp/pearl-grant-check" };
    try t.expectError(error.DuplicateGrant, files.Tools.init(a, .{ .enabled = true, .roots = &[_]files.FolderGrant{ g, g } }));
    try t.expectError(error.DuplicateGrant, files.Tools.init(a, .{ .enabled = true, .roots = &[_]files.FolderGrant{ g, .{ .id = "other", .path = g.path } } }));
    try t.expectError(error.AbsoluteGrantPathRequired, files.Tools.init(a, .{ .enabled = true, .roots = &[_]files.FolderGrant{.{ .id = "docs", .path = "relative/dir" }} }));
    try t.expectError(error.ProtectedGrantPath, files.Tools.init(a, .{ .enabled = true, .roots = &[_]files.FolderGrant{.{ .id = "docs", .path = "/etc/pearl" }} }));
    try t.expectError(error.ProtectedGrantPath, files.Tools.init(a, .{ .enabled = true, .roots = &[_]files.FolderGrant{.{ .id = "docs", .path = "/home/zoey/.ssh" }} }));
    try t.expectError(error.InvalidGrantId, files.Tools.init(a, .{ .enabled = true, .roots = &[_]files.FolderGrant{.{ .id = "bad id!", .path = "/tmp/x" }} }));
}

test "symlinked grant root stays unavailable and fails closed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/tmp");
    defer fix.deinit();
    try fix.mkdir("real");
    try fix.write("real/secret.txt", "data");
    const real = try fix.path("real");
    defer a.free(real);
    try fix.symlink(real, "link");
    const linked = try fix.path("link");
    defer a.free(linked);
    var tools = try files.Tools.init(a, .{ .enabled = true, .roots = &[_]files.FolderGrant{.{ .id = "docs", .path = linked, .read = true }} });
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const v = try search(a, &tools, "root:docs", "secret", "filename", null, cancel);
    try t.expect(statusIs(v, "not_found"));
    try t.expectEqualStrings("GrantUnavailable", str(v, "error"));
}

test "search returns opaque ids with relative and root display paths" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/tmp");
    defer fix.deinit();
    try fix.write("alpha.txt", "alpha");
    try fix.mkdir("sub");
    try fix.write("sub/beta.txt", "beta");
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const v = try search(a, &tools, "root:docs", "txt", "filename", null, cancel);
    try t.expect(statusIs(v, "ok"));
    try t.expectEqual(@as(usize, 2), field(v, "matches").array.items.len);
    const alpha = matchById(v, "alpha.txt").?;
    const id = str(alpha, "file_id");
    try t.expect(id.len > 0 and id[0] == 'h');
    try t.expectEqualStrings("alpha.txt", str(alpha, "path"));
    try t.expectEqualStrings(fix.root, str(alpha, "root_path"));
    try t.expectEqualStrings("file", str(alpha, "type"));
    const beta = matchById(v, "beta.txt").?;
    try t.expectEqualStrings("sub/beta.txt", str(beta, "path"));
    // The opaque id reads the file; forged path-shaped ids never resolve.
    const read_args = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\"}}", .{id});
    const rv = try json(a, try tools.dispatch(a, "read_file", read_args, cancel));
    try t.expect(statusIs(rv, "ok"));
    try t.expectEqualStrings("alpha", str(rv, "content"));
    const forged = try json(a, try tools.dispatch(a, "read_file", "{\"file_id\":\"../../etc/passwd\"}", cancel));
    try t.expect(statusIs(forged, "not_found"));
    const forged2 = try json(a, try tools.dispatch(a, "read_file", "{\"file_id\":\"root:docs\"}", cancel));
    try t.expect(statusIs(forged2, "not_found"));
    const unknown_root = try search(a, &tools, "root:nope", "x", "filename", null, cancel);
    try t.expect(statusIs(unknown_root, "not_found"));
}

test "search pagination is bounded at 20 and the cursor resumes without duplicates" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/dev/shm");
    defer fix.deinit();
    for (0..45) |i| {
        const name = try std.fmt.allocPrint(a, "page-{d:0>3}.txt", .{i});
        try fix.write(name, "x");
    }
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();
    var cursor: ?u64 = null;
    var pages: usize = 0;
    while (true) {
        const v = try search(a, &tools, "root:docs", "page-", "filename", cursor, cancel);
        try t.expect(statusIs(v, "ok"));
        const matches = field(v, "matches").array.items;
        try t.expect(matches.len <= files.max_matches);
        for (matches) |m| {
            const name = str(m, "name");
            try t.expect(!seen.contains(name));
            try seen.put(name, {});
        }
        pages += 1;
        const next = field(v, "cursor");
        if (next == .null) break;
        cursor = @intCast(next.integer);
        try t.expect(pages < 10);
    }
    try t.expectEqual(@as(usize, 45), seen.count());
    try t.expectEqual(@as(usize, 3), pages);
}

test "content search matches bytes, skips binary and oversize, and paginates" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/dev/shm");
    defer fix.deinit();
    for (0..25) |i| {
        const name = try std.fmt.allocPrint(a, "doc-{d:0>3}.md", .{i});
        try fix.write(name, "intro\nThe NEEDLE is here.\noutro");
    }
    try fix.write("binary.dat", "NEEDLE\x00binary");
    const big = try a.alloc(u8, files.max_read_size + 1);
    @memset(big, 'A');
    @memcpy(big[0..6], "NEEDLE");
    try fix.write("oversize.txt", big);
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();
    var cursor: ?u64 = null;
    var skipped_total: u64 = 0;
    while (true) {
        const v = try search(a, &tools, "root:docs", "needle", "content", cursor, cancel);
        try t.expect(statusIs(v, "ok"));
        skipped_total += @intCast(field(v, "skipped").integer);
        for (field(v, "matches").array.items) |m| {
            const name = str(m, "name");
            try t.expect(std.mem.startsWith(u8, name, "doc-"));
            try t.expect(!seen.contains(name));
            try seen.put(name, {});
        }
        const next = field(v, "cursor");
        if (next == .null) break;
        cursor = @intCast(next.integer);
    }
    try t.expectEqual(@as(usize, 25), seen.count());
    try t.expect(skipped_total >= 2); // binary + oversize
}

test "search skips hidden dirs, credential dirs, symlinks and special files" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/tmp");
    defer fix.deinit();
    try fix.write("plain.txt", "ok");
    try fix.mkdir(".hidden");
    try fix.write(".hidden/secret.txt", "hidden");
    try fix.mkdir("credentials");
    try fix.write("credentials/keys.txt", "sensitive");
    try fix.mkdir(".ssh");
    try fix.write(".ssh/id_rsa", "key");
    try fix.write("outside.txt", "outside");
    const outside = try fix.path("outside.txt");
    defer a.free(outside);
    try fix.symlink(outside, "escape.txt");
    try fix.mkfifo("pipe.txt");
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const v = try search(a, &tools, "root:docs", "txt", "filename", null, cancel);
    try t.expect(statusIs(v, "ok"));
    const matches = field(v, "matches").array.items;
    try t.expectEqual(@as(usize, 2), matches.len); // plain.txt + outside.txt
    try t.expect(matchById(v, "secret.txt") == null);
    try t.expect(matchById(v, "keys.txt") == null);
    try t.expect(matchById(v, "escape.txt") == null);
    try t.expect(matchById(v, "pipe.txt") == null);
    try t.expect(field(v, "skipped").integer >= 4);
    // Content mode must not read credential or hidden files either.
    const cv = try search(a, &tools, "root:docs", "sensitive", "content", null, cancel);
    try t.expect(statusIs(cv, "ok"));
    try t.expectEqual(@as(usize, 0), field(cv, "matches").array.items.len);
}

test "search depth is bounded and reports truncation" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/dev/shm");
    defer fix.deinit();
    var rel: std.ArrayList(u8) = .empty;
    for (0..20) |i| {
        try rel.appendSlice(a, if (i == 0) "d" else "/d");
        try fix.mkdir(rel.items);
        const name = try std.fmt.allocPrint(a, "{s}/level{d}.txt", .{ rel.items, i });
        try fix.write(name, "x");
    }
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const v = try search(a, &tools, "root:docs", "level", "filename", null, cancel);
    try t.expect(statusIs(v, "ok"));
    try t.expect(field(v, "truncated").bool);
    for (field(v, "matches").array.items) |m| {
        const p = str(m, "path");
        var depth: usize = 0;
        for (p) |ch| if (ch == '/') {
            depth += 1;
        };
        try t.expect(depth < files.max_search_depth);
    }
    try t.expect(matchById(v, "level19.txt") == null);
    try t.expect(matchById(v, "level0.txt") != null);
}

test "read rejects binary, invalid UTF-8, special files, directories and oversize" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/tmp");
    defer fix.deinit();
    try fix.write("binary.txt", "abc\x00def");
    try fix.write("invalid.txt", "abc\xff\xfe");
    try fix.write("special.txt", "regular");
    const big = try a.alloc(u8, files.max_read_size + 1);
    @memset(big, 'A');
    try fix.write("big.txt", big);
    try fix.mkdir("adir");
    try fix.write("adir/inner.txt", "x");
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const v = try search(a, &tools, "root:docs", "txt", "filename", null, cancel);
    try t.expect(statusIs(v, "ok"));
    const cases = [_]struct { name: []const u8, err: []const u8 }{
        .{ .name = "binary.txt", .err = "BinaryFile" },
        .{ .name = "invalid.txt", .err = "InvalidUtf8" },
        .{ .name = "big.txt", .err = "FileTooLarge" },
    };
    for (cases) |case| {
        const id = str(matchById(v, case.name).?, "file_id");
        const args = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\"}}", .{id});
        const rv = try json(a, try tools.dispatch(a, "read_file", args, cancel));
        try t.expect(statusIs(rv, "failed"));
        try t.expectEqualStrings(case.err, str(rv, "error"));
    }
    // Replace a regular file with a FIFO after its handle was minted.
    const special_id = str(matchById(v, "special.txt").?, "file_id");
    try fix.unlink("special.txt");
    try fix.mkfifo("special.txt");
    const args = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\"}}", .{special_id});
    const rv = try json(a, try tools.dispatch(a, "read_file", args, cancel));
    try t.expect(statusIs(rv, "failed"));
    try t.expectEqualStrings("NotRegularFile", str(rv, "error"));
    // Directory handles are searchable parents but never readable files.
    const dv = try search(a, &tools, "root:docs", "adir", "filename", null, cancel);
    const dir_id = str(matchById(dv, "adir").?, "file_id");
    const dargs = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\"}}", .{dir_id});
    const dr = try json(a, try tools.dispatch(a, "read_file", dargs, cancel));
    try t.expect(statusIs(dr, "failed"));
    try t.expectEqualStrings("IsDirectory", str(dr, "error"));
}

test "read returns character-safe UTF-8 ranges that reassemble exactly" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/tmp");
    defer fix.deinit();
    const text = "héllo wörld — pearl 文件 😀 end";
    try fix.write("utf8.txt", text);
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const v = try search(a, &tools, "root:docs", "utf8", "filename", null, cancel);
    const id = firstMatchId(v);
    // Offset 2 lands inside "é"; the range must snap to whole characters.
    const args = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\",\"offset\":2,\"length\":1}}", .{id});
    const rv = try json(a, try tools.dispatch(a, "read_file", args, cancel));
    try t.expect(statusIs(rv, "ok"));
    try t.expectEqual(@as(i64, 1), field(rv, "offset").integer);
    try t.expect(std.unicode.utf8ValidateSlice(str(rv, "content")));
    try t.expectEqualStrings("é", str(rv, "content"));
    // Walk the whole file with a tiny length; chunks must concatenate exactly.
    var assembled: std.ArrayList(u8) = .empty;
    var offset: u64 = 0;
    var steps: usize = 0;
    while (true) {
        const wargs = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\",\"offset\":{d},\"length\":3}}", .{ id, offset });
        const wv = try json(a, try tools.dispatch(a, "read_file", wargs, cancel));
        try t.expect(statusIs(wv, "ok"));
        const content = str(wv, "content");
        try t.expect(std.unicode.utf8ValidateSlice(content));
        try assembled.appendSlice(a, content);
        const next = field(wv, "next_offset");
        if (next == .null) break;
        const n: u64 = @intCast(next.integer);
        try t.expect(n > offset);
        offset = n;
        steps += 1;
        try t.expect(steps < 200);
    }
    try t.expectEqualStrings(text, assembled.items);
    // Oversized length requests are clamped, offsets past EOF return empty.
    const long_bytes = try a.alloc(u8, 40000);
    @memset(long_bytes, 'A');
    try fix.write("long.txt", long_bytes);
    const lv = try search(a, &tools, "root:docs", "long", "filename", null, cancel);
    const lid = firstMatchId(lv);
    const largs = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\",\"length\":99999}}", .{lid});
    const lr = try json(a, try tools.dispatch(a, "read_file", largs, cancel));
    try t.expect(statusIs(lr, "ok"));
    try t.expect(field(lr, "bytes").integer <= files.max_read_length + 3);
    const eargs = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\",\"offset\":999999}}", .{lid});
    const er = try json(a, try tools.dispatch(a, "read_file", eargs, cancel));
    try t.expect(statusIs(er, "ok"));
    try t.expectEqual(@as(i64, 0), field(er, "bytes").integer);
}

test "symlink substitution after minting blocks read and delete" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/tmp");
    defer fix.deinit();
    try fix.write("victim.txt", "approved");
    try fix.write("outside-secret.txt", "secret");
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const v = try search(a, &tools, "root:docs", "victim", "filename", null, cancel);
    const id = firstMatchId(v);
    const args = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\"}}", .{id});
    const preview = try tools.prepare(a, "delete_file", args, cancel);
    // Replace the entry with a symlink to another file before execution.
    try fix.rename("victim.txt", "victim-real.txt");
    const secret = try fix.path("outside-secret.txt");
    defer a.free(secret);
    try fix.symlink(secret, "victim.txt");
    const rv = try json(a, try tools.dispatch(a, "read_file", args, cancel));
    try t.expect(statusIs(rv, "denied"));
    try t.expectEqualStrings("SymlinkRejected", str(rv, "error"));
    try t.expectError(error.SymlinkRejected, tools.prepare(a, "delete_file", args, cancel));
    try t.expectError(error.SymlinkRejected, tools.execute(a, "delete_file", args, preview, cancel));
    try t.expectEqualStrings("secret", try fix.read("outside-secret.txt"));
    try t.expect(fix.exists("victim-real.txt"));
}

test "parent directory substitution invalidates the handle" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/tmp");
    defer fix.deinit();
    try fix.mkdir("sub");
    try fix.write("sub/keep.txt", "keep");
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const v = try search(a, &tools, "root:docs", "sub", "filename", null, cancel);
    const dir_id = str(matchById(v, "sub").?, "file_id");
    const args = try std.fmt.allocPrint(a, "{{\"parent_id\":\"{s}\",\"name\":\"new.txt\",\"content\":\"x\"}}", .{dir_id});
    const preview = try tools.prepare(a, "create_file", args, cancel);
    // Swap the directory for a different inode at the same path.
    try fix.rename("sub", "sub-old");
    try fix.mkdir("sub");
    try t.expectError(error.HandleStale, tools.execute(a, "create_file", args, preview, cancel));
    try t.expect(!fix.exists("sub/new.txt"));
    try t.expect(fix.exists("sub-old/keep.txt"));
}

test "grant root substitution is detected before mutation" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/tmp");
    defer fix.deinit();
    try fix.write("file.txt", "original");
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const v = try search(a, &tools, "root:docs", "file", "filename", null, cancel);
    const id = firstMatchId(v);
    const args = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\"}}", .{id});
    const preview = try tools.prepare(a, "delete_file", args, cancel);
    // Move the whole grant root away and put a different directory in place.
    const old = try std.fmt.allocPrintSentinel(a, "{s}-old", .{fix.root}, 0);
    defer a.free(old);
    if (linux.errno(linux.renameat2(linux.AT.FDCWD, fix.root, linux.AT.FDCWD, old, .{})) != .SUCCESS) return error.FixtureRename;
    if (glib.mkdirWithParents(fix.root, 0o700) != 0) return error.FixtureDirectory;
    const replacement = try std.fmt.allocPrintSentinel(a, "{s}/file.txt", .{fix.root}, 0);
    defer a.free(replacement);
    try writeAbs(replacement, "replacement");
    try t.expectError(error.GrantChanged, tools.execute(a, "delete_file", args, preview, cancel));
    try t.expectEqualStrings("replacement", try fix.read("file.txt"));
    // Restore so fixture cleanup removes the original tree too.
    removeTree(a, fix.root);
    if (linux.errno(linux.renameat2(linux.AT.FDCWD, old, linux.AT.FDCWD, fix.root, .{})) != .SUCCESS) return error.FixtureRename;
}

test "revoked grants and missing rights deny every operation" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/tmp");
    defer fix.deinit();
    try fix.write("file.txt", "data");
    const cancel = newCancel();
    defer cancel.unref();
    {
        var tools = try makeTools(a, fix.root, .{ .read = false });
        defer tools.deinit();
        const v = try search(a, &tools, "root:docs", "file", "filename", null, cancel);
        try t.expect(statusIs(v, "denied"));
        try t.expectError(error.PermissionDenied, tools.resource(a, .{ .grant_id = "docs", .path = "file.txt" }, cancel));
        const cv = try json(a, try tools.dispatch(a, "create_file", "{\"parent_id\":\"root:docs\",\"name\":\"x.txt\",\"content\":\"x\"}", cancel));
        try t.expect(statusIs(cv, "denied"));
    }
    {
        var tools = try makeTools(a, fix.root, .{ .create = false });
        defer tools.deinit();
        try t.expectError(error.PermissionDenied, tools.prepare(a, "create_file", "{\"parent_id\":\"root:docs\",\"name\":\"x.txt\",\"content\":\"x\"}", cancel));
    }
    {
        var tools = try makeTools(a, fix.root, .{ .delete = false });
        defer tools.deinit();
        const v = try search(a, &tools, "root:docs", "file", "filename", null, cancel);
        const id = firstMatchId(v);
        const args = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\"}}", .{id});
        try t.expectError(error.PermissionDenied, tools.prepare(a, "delete_file", args, cancel));
    }
    // Revocation: ids from a destroyed executor never resolve in a new one.
    var old_id: []const u8 = "";
    {
        var tools = try makeTools(a, fix.root, .{});
        defer tools.deinit();
        const v = try search(a, &tools, "root:docs", "file", "filename", null, cancel);
        old_id = try a.dupe(u8, firstMatchId(v));
    }
    {
        var tools = try makeTools(a, fix.root, .{});
        defer tools.deinit();
        const args = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\"}}", .{old_id});
        const rv = try json(a, try tools.dispatch(a, "read_file", args, cancel));
        try t.expect(statusIs(rv, "not_found"));
    }
}

test "create requires approval, is exclusive and cleans up staging files" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/tmp");
    defer fix.deinit();
    try fix.write("existing.txt", "old");
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const args = "{\"parent_id\":\"root:docs\",\"name\":\"fresh.txt\",\"content\":\"hello\\nworld\"}";
    // The model-facing dispatch never mutates.
    const dv = try json(a, try tools.dispatch(a, "create_file", args, cancel));
    try t.expect(statusIs(dv, "denied"));
    try t.expectEqualStrings("ApprovalRequired", str(dv, "error"));
    try t.expectError(error.ApprovalRequired, tools.execute(a, "create_file", args, null, cancel));
    const preview = try tools.prepare(a, "create_file", args, cancel);
    try t.expectEqual(@as(@TypeOf(preview.kind), .create_file), preview.kind);
    try t.expectEqualStrings("hello\nworld", preview.content);
    try t.expectEqual(@as(usize, 11), preview.bytes);
    const expected_target = try std.fmt.allocPrint(a, "{s}/fresh.txt", .{fix.root});
    try t.expectEqualStrings(expected_target, preview.target_path);
    try t.expectEqualStrings(fix.root, preview.resource.path);
    const out = try tools.execute(a, "create_file", args, preview, cancel);
    const ov = try json(a, out);
    try t.expect(statusIs(ov, "ok"));
    try t.expectEqualStrings("hello\nworld", try fix.read("fresh.txt"));
    try t.expectEqual(@as(u16, 0o600), (try fix.mode("fresh.txt")) & 0o777);
    try t.expectEqual(@as(usize, 0), try fix.countTemps());
    // The new handle reads back immediately.
    const nid = str(ov, "file_id");
    const rargs = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\"}}", .{nid});
    const rv = try json(a, try tools.dispatch(a, "read_file", rargs, cancel));
    try t.expectEqualStrings("hello\nworld", str(rv, "content"));
    // Existing targets are refused at prepare and at execute (race).
    const exist_args = "{\"parent_id\":\"root:docs\",\"name\":\"existing.txt\",\"content\":\"new\"}";
    try t.expectError(error.AlreadyExists, tools.prepare(a, "create_file", exist_args, cancel));
    const race_args = "{\"parent_id\":\"root:docs\",\"name\":\"raced.txt\",\"content\":\"x\"}";
    const race_preview = try tools.prepare(a, "create_file", race_args, cancel);
    try fix.write("raced.txt", "appeared");
    // The parent directory changed, so the original approval is stale; either
    // refusal is safe and nothing may be overwritten.
    if (tools.execute(a, "create_file", race_args, race_preview, cancel)) |_| {
        return error.ExpectedRefusal;
    } else |err| {
        try t.expect(err == error.StaleApproval or err == error.AlreadyExists);
    }
    // Even a preview refreshed against the new parent identity must refuse to
    // overwrite the target that appeared (RENAME_NOREPLACE / O_EXCL).
    const parent_now = try tools.resource(a, .{ .grant_id = "docs", .path = "" }, cancel);
    const fresh_preview = files.ActionPreview{ .kind = .create_file, .target_path = race_preview.target_path, .content = "x", .bytes = 1, .resource = parent_now };
    try t.expectError(error.AlreadyExists, tools.execute(a, "create_file", race_args, fresh_preview, cancel));
    try t.expectEqualStrings("appeared", try fix.read("raced.txt"));
    try t.expectEqual(@as(usize, 0), try fix.countTemps());
    // Content mismatch against the approved preview is a stale approval.
    const tampered = "{\"parent_id\":\"root:docs\",\"name\":\"fresh2.txt\",\"content\":\"different\"}";
    const tp = try tools.prepare(a, "create_file", tampered, cancel);
    try t.expectError(error.StaleApproval, tools.execute(a, "create_file", "{\"parent_id\":\"root:docs\",\"name\":\"fresh2.txt\",\"content\":\"evil\"}", tp, cancel));
    try t.expect(!fix.exists("fresh2.txt"));
}

test "create rejects protected names, paths and executable content" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/tmp");
    defer fix.deinit();
    try fix.mkdir("autostart");
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const bad_names = [_][]const u8{ "launcher.desktop", "run.sh", "tool.exe", "unit.service", ".bashrc", "authorized_keys", "../escape", "a/b", "..", "" };
    for (bad_names) |name| {
        const args = try std.json.Stringify.valueAlloc(a, .{ .parent_id = "root:docs", .name = name, .content = "x" }, .{});
        if (tools.prepare(a, "create_file", args, cancel)) |_| {
            return error.ExpectedProtectedName;
        } else |err| {
            try t.expect(err == error.ProtectedName or err == error.InvalidName);
        }
    }
    const shebang = "{\"parent_id\":\"root:docs\",\"name\":\"note.txt\",\"content\":\"#!/bin/sh\\necho hi\"}";
    try t.expectError(error.ProtectedName, tools.prepare(a, "create_file", shebang, cancel));
    const elf = try std.json.Stringify.valueAlloc(a, .{ .parent_id = "root:docs", .name = "note.txt", .content = "\x7fELFbinary" }, .{});
    try t.expectError(error.ProtectedName, tools.prepare(a, "create_file", elf, cancel));
    const oversize_content = try a.alloc(u8, files.max_create_bytes + 1);
    @memset(oversize_content, 'x');
    const oversize = try std.json.Stringify.valueAlloc(a, .{ .parent_id = "root:docs", .name = "note.txt", .content = oversize_content }, .{});
    try t.expectError(error.FileTooLarge, tools.prepare(a, "create_file", oversize, cancel));
    // autostart directories inside a grant are protected targets.
    const v = try search(a, &tools, "root:docs", "autostart", "filename", null, cancel);
    const dir_id = str(matchById(v, "autostart").?, "file_id");
    const args = try std.fmt.allocPrint(a, "{{\"parent_id\":\"{s}\",\"name\":\"item.txt\",\"content\":\"x\"}}", .{dir_id});
    try t.expectError(error.ProtectedPath, tools.prepare(a, "create_file", args, cancel));
}

test "stale approvals are refused for delete and create" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/tmp");
    defer fix.deinit();
    const unique = "pearl-fs-stale-unique.txt";
    defer cleanupTrash(a, "pearl-fs-stale-unique");
    try fix.write(unique, "one");
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const v = try search(a, &tools, "root:docs", "pearl-fs-stale", "filename", null, cancel);
    const id = firstMatchId(v);
    const args = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\"}}", .{id});
    const preview = try tools.prepare(a, "delete_file", args, cancel);
    try fix.append(unique, "two");
    try t.expectError(error.StaleApproval, tools.execute(a, "delete_file", args, preview, cancel));
    try t.expectEqualStrings("onetwo", try fix.read(unique));
    // A fresh preview approves the new identity and succeeds.
    const preview2 = try tools.prepare(a, "delete_file", args, cancel);
    _ = try tools.execute(a, "delete_file", args, preview2, cancel);
    try t.expect(!fix.exists(unique));
    // Create approvals pin the parent identity: a sibling change invalidates.
    const cargs = "{\"parent_id\":\"root:docs\",\"name\":\"approved.txt\",\"content\":\"x\"}";
    const cp = try tools.prepare(a, "create_file", cargs, cancel);
    try fix.write("sibling.txt", "y");
    try t.expectError(error.StaleApproval, tools.execute(a, "create_file", cargs, cp, cancel));
    try t.expect(!fix.exists("approved.txt"));
}

test "delete trashes regular files, verifies identity and rejects duplicates" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/tmp");
    defer fix.deinit();
    const unique = "pearl-fs-trash-unique.txt";
    const stem = "pearl-fs-trash-unique";
    defer cleanupTrash(a, stem);
    try fix.write(unique, "trash me");
    try fix.mkdir("adir");
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const v = try search(a, &tools, "root:docs", "pearl-fs-trash", "filename", null, cancel);
    const id = firstMatchId(v);
    const args = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\"}}", .{id});
    const preview = try tools.prepare(a, "delete_file", args, cancel);
    try t.expectEqual(@as(@TypeOf(preview.kind), .delete_file), preview.kind);
    try t.expectEqual(@as(usize, 8), preview.bytes);
    const out = try tools.execute(a, "delete_file", args, preview, cancel);
    const ov = try json(a, out);
    try t.expect(statusIs(ov, "ok"));
    try t.expectEqualStrings("trash", str(ov, "kind"));
    try t.expect(!fix.exists(unique));
    // The trash origin must be repaired to the real path so restore works.
    const RepairCtx = struct { a: std.mem.Allocator, root: []const u8, name: []const u8, file: []const u8, ok: bool = false };
    var rctx = RepairCtx{ .a = a, .root = fix.root, .name = stem, .file = unique };
    const check = struct {
        fn f(ctx: *RepairCtx, name: []const u8) void {
            if (!std.mem.startsWith(u8, name, ctx.name)) return;
            const ip = std.fmt.allocPrintSentinel(ctx.a, "{s}/Trash/info/{s}", .{ std.mem.span(glib.getUserDataDir()), name }, 0) catch return;
            defer ctx.a.free(ip);
            const text = readAbs(ctx.a, ip) catch return;
            defer ctx.a.free(text);
            const expected = std.fmt.allocPrint(ctx.a, "Path={s}/{s}\n", .{ ctx.root, ctx.file }) catch return;
            defer ctx.a.free(expected);
            if (std.mem.indexOf(u8, text, expected) != null) ctx.ok = true;
        }
    }.f;
    var ibuf: [512]u8 = undefined;
    const info_dir = try std.mem.printSentinel(&ibuf, "{s}/Trash/info", .{std.mem.span(glib.getUserDataDir())}, 0);
    eachDirEntry(info_dir, &rctx, check);
    try t.expect(rctx.ok);
    // Duplicate delete: the handle is gone, previews no longer resolve.
    try t.expectError(error.UnknownHandle, tools.prepare(a, "delete_file", args, cancel));
    try t.expectError(error.UnknownHandle, tools.execute(a, "delete_file", args, preview, cancel));
    const dv = try json(a, try tools.dispatch(a, "delete_file", args, cancel));
    try t.expect(statusIs(dv, "denied")); // dispatch never deletes on its own
    // Directories are never deleted.
    const dv2 = try search(a, &tools, "root:docs", "adir", "filename", null, cancel);
    const dir_id = str(matchById(dv2, "adir").?, "file_id");
    const dargs = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\"}}", .{dir_id});
    try t.expectError(error.DirectoriesNotSupported, tools.prepare(a, "delete_file", dargs, cancel));
    try t.expect(fix.exists("adir"));
}

test "trash unavailable gives a permanent preview and never falls back" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // /dev/shm is a system-internal tmpfs mount: GIO trash refuses it.
    var fix = try Fixture.init(a, "/dev/shm");
    defer fix.deinit();
    try fix.write("shmfile.txt", "data");
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const v = try search(a, &tools, "root:docs", "shmfile", "filename", null, cancel);
    const id = firstMatchId(v);
    const args = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\"}}", .{id});
    const preview = try tools.prepare(a, "delete_file", args, cancel);
    try t.expectEqual(@as(@TypeOf(preview.kind), .delete_file_permanent), preview.kind);
    // A trash-kind preview on this mount fails without deleting anything.
    const trash_preview = files.ActionPreview{
        .kind = .delete_file,
        .target_path = preview.target_path,
        .bytes = preview.bytes,
        .resource = preview.resource,
    };
    try t.expectError(error.TrashUnavailable, tools.execute(a, "delete_file", args, trash_preview, cancel));
    try t.expect(fix.exists("shmfile.txt"));
    try t.expectError(error.ApprovalRequired, tools.execute(a, "delete_file", args, null, cancel));
    // Only the explicit permanent preview removes the file.
    const out = try tools.execute(a, "delete_file", args, preview, cancel);
    const ov = try json(a, out);
    try t.expect(statusIs(ov, "ok"));
    try t.expectEqualStrings("permanent", str(ov, "kind"));
    try t.expect(!fix.exists("shmfile.txt"));
}

test "cancellation propagates through dispatch, prepare and execute" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/tmp");
    defer fix.deinit();
    try fix.write("file.txt", "x");
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const v = try search(a, &tools, "root:docs", "file", "filename", null, cancel);
    const id = firstMatchId(v);
    const args = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\"}}", .{id});
    const preview = try tools.prepare(a, "delete_file", args, cancel);
    cancel.cancel();
    try t.expectError(error.Cancelled, tools.dispatch(a, "search_files", "{\"root_id\":\"root:docs\",\"query\":\"x\"}", cancel));
    try t.expectError(error.Cancelled, tools.prepare(a, "delete_file", args, cancel));
    try t.expectError(error.Cancelled, tools.execute(a, "delete_file", args, preview, cancel));
    try t.expectError(error.Cancelled, tools.execute(a, "create_file", "{\"parent_id\":\"root:docs\",\"name\":\"n.txt\",\"content\":\"x\"}", null, cancel));
    try t.expect(fix.exists("file.txt"));
}

test "resource stats grant-relative paths with rights and traversal checks" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/tmp");
    defer fix.deinit();
    try fix.mkdir("sub");
    try fix.write("sub/file.txt", "hello");
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const r = try tools.resource(a, .{ .grant_id = "docs", .path = "sub/file.txt" }, cancel);
    const expected = try std.fmt.allocPrint(a, "{s}/sub/file.txt", .{fix.root});
    try t.expectEqualStrings(expected, r.path);
    try t.expectEqual(@as(u64, 5), r.size);
    try t.expect(r.dev != 0 and r.ino != 0);
    try t.expectError(error.UnknownRoot, tools.resource(a, .{ .grant_id = "nope", .path = "x" }, cancel));
    try t.expectError(error.NotFound, tools.resource(a, .{ .grant_id = "docs", .path = "missing.txt" }, cancel));
    try t.expectError(error.InvalidGrantPath, tools.resource(a, .{ .grant_id = "docs", .path = "../escape" }, cancel));
}

test "dispatch emits structured statuses for unknown tools and bad arguments" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/tmp");
    defer fix.deinit();
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const unknown = try json(a, try tools.dispatch(a, "format_disk", "{}", cancel));
    try t.expect(statusIs(unknown, "failed"));
    try t.expectEqualStrings("UnknownTool", str(unknown, "error"));
    const bad = try json(a, try tools.dispatch(a, "search_files", "not json", cancel));
    try t.expect(statusIs(bad, "failed"));
    try t.expectEqualStrings("InvalidToolCall", str(bad, "error"));
    const empty_root = try search(a, &tools, "", "x", "filename", null, cancel);
    try t.expect(statusIs(empty_root, "ambiguous"));
    try t.expectEqualStrings("docs", field(empty_root, "roots").array.items[0].string);
    const bad_mode = try search(a, &tools, "root:docs", "x", "regex", null, cancel);
    try t.expect(statusIs(bad_mode, "failed"));
}

test "search entry budget truncates at 4096 visited entries" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/dev/shm");
    defer fix.deinit();
    for (0..4200) |i| {
        const name = try std.fmt.allocPrint(a, "budget-{d:0>5}.txt", .{i});
        try fix.write(name, "x");
    }
    var tools = try makeTools(a, fix.root, .{});
    defer tools.deinit();
    const cancel = newCancel();
    defer cancel.unref();
    const v = try search(a, &tools, "root:docs", "zzz-nomatch", "filename", null, cancel);
    try t.expect(statusIs(v, "ok"));
    try t.expect(field(v, "truncated").bool);
    try t.expect(field(v, "visited").integer <= files.max_search_entries);
    try t.expectEqual(@as(usize, 0), field(v, "matches").array.items.len);
    try t.expect(field(v, "cursor") != .null);
}

test "handle map evicts oldest ids and deinit closes every descriptor" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fix = try Fixture.init(a, "/dev/shm");
    defer fix.deinit();
    const total = files.max_handles + 40;
    for (0..total) |i| {
        const name = try std.fmt.allocPrint(a, "evict-{d:0>5}.txt", .{i});
        try fix.write(name, "x");
    }
    const before = fdCount();
    var first_id: []const u8 = "";
    var last_id: []const u8 = "";
    {
        var tools = try makeTools(a, fix.root, .{});
        defer tools.deinit();
        const cancel = newCancel();
        defer cancel.unref();
        var cursor: ?u64 = null;
        var collected: usize = 0;
        while (true) {
            const v = try search(a, &tools, "root:docs", "evict-", "filename", cursor, cancel);
            try t.expect(statusIs(v, "ok"));
            for (field(v, "matches").array.items) |m| {
                if (first_id.len == 0) first_id = try a.dupe(u8, str(m, "file_id"));
                last_id = try a.dupe(u8, str(m, "file_id"));
                collected += 1;
            }
            const next = field(v, "cursor");
            if (next == .null) break;
            cursor = @intCast(next.integer);
        }
        try t.expectEqual(total, collected);
        // The oldest handle was evicted; the newest still resolves.
        const old_args = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\"}}", .{first_id});
        const old = try json(a, try tools.dispatch(a, "read_file", old_args, cancel));
        try t.expect(statusIs(old, "not_found"));
        const new_args = try std.fmt.allocPrint(a, "{{\"file_id\":\"{s}\"}}", .{last_id});
        const new = try json(a, try tools.dispatch(a, "read_file", new_args, cancel));
        try t.expect(statusIs(new, "ok"));
    }
    try t.expectEqual(before, fdCount());
}
