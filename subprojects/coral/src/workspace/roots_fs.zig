//! Worker-only manifest editing boundary. No root directory is ever created,
//! renamed or deleted. GIO's expected-etag replacement is not a kernel CAS against
//! a hostile same-UID writer: identity, bytes and metadata are checked immediately
//! before replacement, and the exact etag is always supplied (never force-save).
//! Save As publishes a fully written private file with renameat2(NOREPLACE).
const std = @import("std");
const c = @import("pearl_app_c");
const model = @import("model.zig");
const manifest = @import("manifest.zig");
const native = @import("manifest_fs.zig");
const Allocator = std.mem.Allocator;
const Stat = std.os.linux.Statx;
pub const Kind = enum { add, remove, save_as };
pub const Root = struct { id: model.RootId, name: []const u8, path: []const u8 };

/// GTK-only copying, with no filesystem access. The worker never borrows Model.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    source: ?[]const u8,
    roots: []const Root,
    settings: manifest.settings.Config,
    exclude: []const []const u8,
    fingerprint: [32]u8,

    pub fn capture(allocator: Allocator, value: *const model.Model) !Snapshot {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const roots = try a.alloc(Root, value.roots.len);
        for (value.roots, roots) |root, *copy| copy.* = .{
            .id = root.id,
            .name = try a.dupe(u8, root.display_name),
            .path = try a.dupe(u8, root.lexical_path),
        };
        const excludes = try a.alloc([]const u8, value.exclude.len);
        for (value.exclude, excludes) |pattern, *copy| copy.* = try a.dupe(u8, pattern);
        const source = if (value.manifest_path) |p| try a.dupe(u8, p) else null;
        const settings = try value.workspace_settings.clone(a);
        return .{
            .arena = arena,
            .source = source,
            .roots = roots,
            .settings = settings,
            .exclude = excludes,
            .fingerprint = value.policy_fingerprint,
        };
    }
    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Request = struct {
    kind: Kind,
    snapshot: *const Snapshot,
    /// Absolute existing folder for Add, absolute new manifest for Save As.
    path: []const u8 = "",
    selected: ?model.RootId = null,
};

const Document = struct {
    roots: []const manifest.Root,
    settings: manifest.settings.Config,
    exclude: []const []const u8,
    pub fn jsonStringify(self: Document, out: *std.json.Stringify) !void {
        try out.beginObject();
        try out.objectField("version");
        try out.write(@as(u8, 1));
        try out.objectField("roots");
        try out.write(self.roots);
        try out.objectField("settings");
        try out.beginObject();
        try patchFields(out, self.settings.general);
        if (self.settings.languages.len != 0) {
            try out.objectField("languages");
            try out.beginObject();
            for (self.settings.languages) |language| {
                try out.objectField(language.id);
                try out.beginObject();
                try patchFields(out, language.patch);
                try out.endObject();
            }
            try out.endObject();
        }
        try out.endObject();
        try out.objectField("exclude");
        try out.write(self.exclude);
        try out.endObject();
    }
};
fn patchFields(out: *std.json.Stringify, patch: manifest.settings.Patch) !void {
    inline for (.{ "lines", "wrap", "spaces", "indent" }) |key| if (@field(patch, key)) |value| {
        try out.objectField(key);
        try out.write(value);
    };
}

/// Pure serializer. Absolute lexical spellings are intentional: path.resolve
/// would change link/.. traversal and moving the manifest would change relatives.
pub fn serialize(a: Allocator, snapshot: *const Snapshot, kind: Kind, path: []const u8, selected: ?model.RootId) ![]u8 {
    if (kind != .save_as and snapshot.source == null) return error.SaveWorkspaceFirst;
    var roots: [manifest.limits.roots]manifest.Root = undefined;
    var count: usize = 0;
    var removed = false;
    for (snapshot.roots) |root| {
        if (kind == .remove and selected == root.id) {
            removed = true;
            continue;
        }
        if (count == roots.len) return error.TooManyRoots;
        try native.absolutePath(root.path);
        roots[count] = .{ .name = root.name, .path = root.path };
        count += 1;
    }
    if (kind == .remove) {
        if (!removed) return error.NoSelection;
        if (count == 0) return error.LastRoot;
    }
    if (kind == .add) {
        if (count == roots.len) return error.TooManyRoots;
        try native.absolutePath(path);
        roots[count] = .{ .path = path };
        count += 1;
    }
    const bytes = try std.json.Stringify.valueAlloc(a, Document{ .roots = roots[0..count], .settings = snapshot.settings, .exclude = snapshot.exclude }, .{ .emit_null_optional_fields = false, .whitespace = .indent_2 });
    errdefer a.free(bytes);
    var validated = try manifest.parse(a, bytes);
    validated.deinit();
    return bytes;
}

/// Pins a destination parent. Relative roots are still based on the original
/// manifest spelling, not this resolved publication path. Final symlinks refuse.
const Target = struct {
    a: Allocator,
    path: [:0]u8,
    parent_path: []u8,
    name: [:0]u8,
    fd: c_int,
    stat: Stat,
    fn open(a: Allocator, path: []const u8) !Target {
        try native.absolutePath(path);
        const name = std.fs.path.basename(path);
        if (path[path.len - 1] == '/' or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidPath;
        const parent = try native.directory(a, std.fs.path.dirname(path).?);
        errdefer a.free(parent);
        const z = try a.dupeSentinel(u8, parent, 0);
        defer a.free(z);
        const fd = std.c.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
        if (fd < 0) return osError(std.c.errno(fd));
        errdefer _ = std.c.close(fd);
        const owned_path = try a.dupeSentinel(u8, path, 0);
        errdefer a.free(owned_path);
        const stat = try inspect(fd, "", std.os.linux.AT.EMPTY_PATH);
        return .{ .a = a, .path = owned_path, .parent_path = parent, .name = try a.dupeSentinel(u8, name, 0), .fd = fd, .stat = stat };
    }
    fn deinit(self: *Target) void {
        _ = std.c.close(self.fd);
        self.a.free(self.path);
        self.a.free(self.parent_path);
        self.a.free(self.name);
    }
    fn validate(self: *const Target) !void {
        var current = try Target.open(self.a, self.path);
        defer current.deinit();
        if (!sameIdentity(current.stat, self.stat) or !std.mem.eql(u8, current.parent_path, self.parent_path)) return error.StaleSnapshot;
    }
    fn absent(self: *const Target) !void {
        _ = inspect(self.fd, self.name, std.os.linux.AT.SYMLINK_NOFOLLOW) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        return error.AlreadyExists;
    }
    fn gio(self: *const Target) !*c.GFile {
        // Descriptor-relative even if an external process renames an ancestor.
        const path = try std.fmt.allocPrintSentinel(self.a, "/proc/self/fd/{d}/{s}", .{ self.fd, self.name }, 0);
        defer self.a.free(path);
        return c.g_file_new_for_path(path).?;
    }
};

const Source = struct {
    a: Allocator,
    target: Target,
    origin: []u8,
    bytes: []u8,
    etag: [:0]u8,
    stat: Stat,
    fd: c_int,
    fn read(a: Allocator, path: []const u8, cancel: *c.GCancellable) !Source {
        try cancelled(cancel);
        // Resolve a source alias, but retain its original spelling for every
        // revalidation and for relative-root interpretation by the model.
        const resolved = try native.canonical(a, path);
        defer a.free(resolved);
        var target = try Target.open(a, resolved);
        errdefer target.deinit();
        const origin = try a.dupe(u8, path);
        errdefer a.free(origin);
        const fd = std.c.openat(target.fd, target.name, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
        if (fd < 0) return osError(std.c.errno(fd));
        errdefer _ = std.c.close(fd);
        const before = try inspect(fd, "", std.os.linux.AT.EMPTY_PATH);
        if (before.mode & std.c.S.IFMT != std.c.S.IFREG) return error.NotRegularFile;
        if (before.size > manifest.limits.manifest_bytes) return error.TooLarge;
        const file = try target.gio();
        defer c.g_object_unref(file);
        const etag = try getEtag(a, file, cancel);
        errdefer a.free(etag);
        const bytes = try a.alloc(u8, @intCast(before.size));
        errdefer a.free(bytes);
        var offset: usize = 0;
        while (offset < bytes.len) {
            try cancelled(cancel);
            const n = std.c.read(fd, bytes[offset..].ptr, bytes.len - offset);
            if (n < 0 and std.c.errno(n) == .INTR) continue;
            if (n < 0) return osError(std.c.errno(n));
            if (n == 0) return error.StaleSnapshot;
            offset += @intCast(n);
        }
        if (!sameVersion(before, try inspect(fd, "", std.os.linux.AT.EMPTY_PATH)) or
            !sameVersion(before, try inspect(target.fd, target.name, std.os.linux.AT.SYMLINK_NOFOLLOW))) return error.StaleSnapshot;
        const after_etag = try getEtag(a, file, cancel);
        defer a.free(after_etag);
        if (!std.mem.eql(u8, etag, after_etag)) return error.StaleSnapshot;
        try target.validate();
        const still_resolved = try native.canonical(a, origin);
        defer a.free(still_resolved);
        if (!std.mem.eql(u8, still_resolved, resolved)) return error.StaleSnapshot;
        return .{ .a = a, .target = target, .origin = origin, .bytes = bytes, .etag = etag, .stat = before, .fd = fd };
    }
    fn deinit(self: *Source) void {
        _ = std.c.close(self.fd);
        self.target.deinit();
        self.a.free(self.origin);
        self.a.free(self.bytes);
        self.a.free(self.etag);
    }
    fn validate(self: *const Source, cancel: *c.GCancellable) !void {
        try self.target.validate();
        var current = try Source.read(self.a, self.origin, cancel);
        defer current.deinit();
        // Exact bytes, not only mtime/size: restored timestamps cannot mask edits.
        if (!std.mem.eql(u8, self.target.path, current.target.path) or !sameVersion(self.stat, current.stat) or !std.mem.eql(u8, self.etag, current.etag) or !std.mem.eql(u8, self.bytes, current.bytes)) return error.StaleSnapshot;
    }
};

pub const Prepared = struct {
    a: Allocator,
    request: Request,
    source: ?Source = null,
    destination: ?Target = null,
    added: ?[]u8 = null,
    added_stat: ?Stat = null,
    bytes: []u8,
    committed: bool = false,
    pub fn deinit(self: *Prepared) void {
        if (self.source) |*source| source.deinit();
        if (self.destination) |*target| target.deinit();
        if (self.added) |p| self.a.free(p);
        self.a.free(self.bytes);
        self.* = undefined;
    }
    pub fn targetPath(self: *const Prepared) []const u8 {
        return if (self.destination) |target| target.path else self.source.?.target.path;
    }
};

/// Both calls receive freshly copied paths of ALL bound documents, including
/// peers/draining owners. The apply copy must be taken under the manager barrier.
pub fn prepare(a: Allocator, request: Request, bound_paths: []const []const u8, cancel: *c.GCancellable) !Prepared {
    try cancelled(cancel);
    if (request.kind != .save_as and request.snapshot.source == null) return error.SaveWorkspaceFirst;
    var source: ?Source = if (request.snapshot.source) |p| try Source.read(a, p, cancel) else null;
    errdefer if (source) |*s| s.deinit();
    var current = try reload(a, request.snapshot, if (source) |s| s.bytes else null);
    defer current.deinit();
    try matches(request.snapshot, &current);
    var destination: ?Target = if (request.kind == .save_as) try Target.open(a, request.path) else null;
    errdefer if (destination) |*d| d.deinit();
    if (destination) |*d| try d.absent();
    const target = if (destination) |*d| d else &source.?.target;
    try checkBound(a, target, bound_paths, cancel);
    var added: ?[]u8 = null;
    errdefer if (added) |p| a.free(p);
    var added_stat: ?Stat = null;
    if (request.kind == .add) {
        added = try native.directory(a, request.path);
        for (current.roots) |root| if (root.canonical_path) |p| {
            if (std.mem.eql(u8, added.?, p)) return error.DuplicateRoot;
        };
        added_stat = try pathStat(a, added.?);
    }
    const bytes = try serialize(a, request.snapshot, request.kind, request.path, request.selected);
    return .{ .a = a, .request = request, .source = source, .destination = destination, .added = added, .added_stat = added_stat, .bytes = bytes };
}

pub fn apply(p: *Prepared, bound_paths: []const []const u8, cancel: *c.GCancellable) !void {
    if (p.committed) return error.AlreadyApplied;
    try cancelled(cancel);
    if (p.source) |*source| try source.validate(cancel);
    var current = try reload(p.a, p.request.snapshot, if (p.source) |source| source.bytes else null);
    defer current.deinit();
    try matches(p.request.snapshot, &current);
    if (p.added) |added| {
        const now = try native.directory(p.a, p.request.path);
        defer p.a.free(now);
        if (!std.mem.eql(u8, now, added) or !sameIdentity(p.added_stat.?, try pathStat(p.a, now))) return error.StaleSnapshot;
    }
    const target = if (p.destination) |*d| d else &p.source.?.target;
    try target.validate();
    try checkBound(p.a, target, bound_paths, cancel);
    if (p.destination) |*d| {
        try d.absent();
        try publish(p, d, cancel);
    } else {
        // Do not turn a missing/changed expected snapshot into an unchecked save.
        try p.source.?.validate(cancel);
        try cancelled(cancel);
        const file = try target.gio();
        defer c.g_object_unref(file);
        var err: ?*c.GError = null;
        defer if (err) |e| c.g_error_free(e);
        if (c.g_file_replace_contents(file, p.bytes.ptr, p.bytes.len, p.source.?.etag.ptr, 0, c.G_FILE_CREATE_REPLACE_DESTINATION, null, cancel, &err) == 0) return gioError(err);
        p.committed = true;
    }
}

fn reload(a: Allocator, snapshot: *const Snapshot, bytes: ?[]const u8) !model.Model {
    if (snapshot.source) |path| return model.Model.fromManifestBytes(a, path, bytes.?);
    if (snapshot.roots.len != 1) return error.InvalidSchema;
    return model.Model.fromFolder(a, snapshot.roots[0].path);
}
fn matches(expected: *const Snapshot, current: *const model.Model) !void {
    if (!std.mem.eql(u8, &expected.fingerprint, &current.policy_fingerprint) or expected.roots.len != current.roots.len) return error.WorkspaceChanged;
    // The policy digest deliberately excludes display names and available lexical
    // aliases. Check both too, so fresh disk changes cannot silently be discarded.
    for (expected.roots, current.roots) |left, right| {
        if (!std.mem.eql(u8, left.name, right.display_name) or !std.mem.eql(u8, left.path, right.lexical_path)) return error.WorkspaceChanged;
    }
}
fn checkBound(a: Allocator, target: *const Target, paths: []const []const u8, cancel: *c.GCancellable) !void {
    const target_stat: ?Stat = inspect(target.fd, target.name, std.os.linux.AT.SYMLINK_NOFOLLOW) catch |err| if (err == error.NotFound) null else return err;
    const physical = try std.fs.path.join(a, &.{ target.parent_path, target.name });
    defer a.free(physical);
    for (paths) |path| {
        try cancelled(cancel);
        const canonical = native.canonical(a, path) catch |err| switch (err) {
            error.NotFound => blk: {
                // A bound missing document can still save back to this pathname.
                var missing = Target.open(a, path) catch |cause| return if (cause == error.OutOfMemory) cause else error.UnverifiableDocument;
                defer missing.deinit();
                break :blk try std.fs.path.join(a, &.{ missing.parent_path, missing.name });
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnverifiableDocument,
        };
        defer a.free(canonical);
        if (std.mem.eql(u8, physical, canonical)) return error.OpenDocument;
        if (target_stat) |st| {
            const other = pathStat(a, canonical) catch |err| if (err == error.NotFound) continue else return err;
            if (sameIdentity(st, other)) return error.OpenDocument;
        }
    }
}
fn publish(p: *Prepared, target: *Target, cancel: *c.GCancellable) !void {
    const uuid = c.g_uuid_string_random();
    defer c.g_free(uuid);
    const name = try std.fmt.allocPrintSentinel(p.a, ".coral-workspace-{s}.tmp", .{std.mem.span(uuid)}, 0);
    defer p.a.free(name);
    const fd = std.c.openat(target.fd, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return osError(std.c.errno(fd));
    defer _ = std.c.close(fd);
    defer if (!p.committed) {
        _ = std.c.unlinkat(target.fd, name, 0);
    };
    var offset: usize = 0;
    while (offset < p.bytes.len) {
        try cancelled(cancel);
        const n = std.c.write(fd, p.bytes[offset..].ptr, p.bytes.len - offset);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) return error.Io;
        offset += @intCast(n);
    }
    while (std.c.fsync(fd) != 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return error.Io;
    }
    try target.validate();
    if (p.source) |*source| try source.validate(cancel);
    try cancelled(cancel);
    const rc = std.os.linux.renameat2(target.fd, name, target.fd, target.name, .{ .NOREPLACE = true });
    const err = std.os.linux.errno(rc);
    if (err != .SUCCESS) return osError(err);
    p.committed = true;
    // Publication succeeded; fsync failure is not a safe rollback opportunity.
    while (std.c.fsync(target.fd) != 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return error.DurabilityUncertain;
    }
}
fn getEtag(a: Allocator, file: *c.GFile, cancel: *c.GCancellable) ![:0]u8 {
    var err: ?*c.GError = null;
    defer if (err) |e| c.g_error_free(e);
    const info = c.g_file_query_info(file, "standard::type,etag::value", c.G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, cancel, &err) orelse return gioError(err);
    defer c.g_object_unref(info);
    if (c.g_file_info_get_file_type(info) != c.G_FILE_TYPE_REGULAR) return error.NotRegularFile;
    const etag = c.g_file_info_get_etag(info);
    if (etag == null or etag[0] == 0) return error.NoEtag;
    return a.dupeSentinel(u8, std.mem.span(etag), 0);
}
fn pathStat(a: Allocator, path: []const u8) !Stat {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    return inspect(std.os.linux.AT.FDCWD, z, 0);
}
fn inspect(fd: c_int, name: [*:0]const u8, flags: u32) !Stat {
    var st: Stat = undefined;
    while (std.c.statx(fd, name, flags, .{ .TYPE = true, .INO = true, .SIZE = true, .MTIME = true, .CTIME = true }, &st) != 0) {
        const err = std.c.errno(@as(c_int, -1));
        if (err != .INTR) return osError(err);
    }
    if (!st.mask.TYPE or !st.mask.INO or !st.mask.SIZE or !st.mask.MTIME or !st.mask.CTIME) return error.Io;
    return st;
}
fn sameIdentity(x: Stat, y: Stat) bool {
    return x.ino == y.ino and x.dev_major == y.dev_major and x.dev_minor == y.dev_minor and x.mode & std.c.S.IFMT == y.mode & std.c.S.IFMT;
}
fn sameVersion(x: Stat, y: Stat) bool {
    return sameIdentity(x, y) and x.size == y.size and x.mtime.sec == y.mtime.sec and x.mtime.nsec == y.mtime.nsec and x.ctime.sec == y.ctime.sec and x.ctime.nsec == y.ctime.nsec;
}
fn cancelled(cancel: *c.GCancellable) !void {
    if (c.g_cancellable_is_cancelled(cancel) != 0) return error.Cancelled;
}
fn osError(err: std.c.E) anyerror {
    return switch (err) {
        .NOENT => error.NotFound,
        .NOTDIR => error.NotDirectory,
        .EXIST => error.AlreadyExists,
        .LOOP => error.Symlink,
        .ACCES, .PERM => error.PermissionDenied,
        else => error.Io,
    };
}
fn gioError(err: ?*c.GError) anyerror {
    if (err) |e| {
        if (c.g_error_matches(e, c.g_io_error_quark(), c.G_IO_ERROR_CANCELLED) != 0) return error.Cancelled;
        if (c.g_error_matches(e, c.g_io_error_quark(), c.G_IO_ERROR_WRONG_ETAG) != 0) return error.StaleSnapshot;
    }
    return error.Io;
}
