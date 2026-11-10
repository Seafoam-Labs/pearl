//! Backend-only tests; the parent test root/build owns discovery of this file.
const std = @import("std");
const fs = @import("operations_fs.zig");
const c = @import("pearl_app_c");
const a = std.testing.allocator;
const io = std.testing.io;
extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    base: [:0]u8,
    root: [:0]u8,
    cancel: *c.GCancellable,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(io, "root", .fromMode(0o700));
        var buf: [4096]u8 = undefined;
        const len = try tmp.dir.realPath(io, &buf);
        const base = try a.dupeSentinel(u8, buf[0..len], 0);
        errdefer a.free(base);
        const root = try std.fmt.allocPrintSentinel(a, "{s}/root", .{base}, 0);
        errdefer a.free(root);
        return .{ .tmp = tmp, .base = base, .root = root, .cancel = c.g_cancellable_new().? };
    }
    fn deinit(self: *Fixture) void {
        c.g_object_unref(self.cancel);
        a.free(self.root);
        a.free(self.base);
        self.tmp.cleanup();
    }
    fn path(self: *const Fixture, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ self.root, name }, 0);
    }
    fn write(self: *const Fixture, name: []const u8, bytes: []const u8) !void {
        const p = try self.path(name);
        defer a.free(p);
        const fd = std.c.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
            try std.testing.expect(n > 0);
            offset += @intCast(n);
        }
    }
    fn mkdir(self: *const Fixture, name: []const u8) !void {
        const p = try self.path(name);
        defer a.free(p);
        try std.testing.expectEqual(@as(c_int, 0), std.c.mkdir(p, 0o700));
    }
    fn rename(self: *const Fixture, from: []const u8, to: []const u8) !void {
        const src = try self.path(from);
        defer a.free(src);
        const dst = try self.path(to);
        defer a.free(dst);
        try std.testing.expectEqual(@as(c_int, 0), std.c.rename(src, dst));
    }
    fn unlink(self: *const Fixture, name: []const u8) !void {
        const p = try self.path(name);
        defer a.free(p);
        try std.testing.expectEqual(@as(c_int, 0), std.c.unlink(p));
    }
    fn symlink(self: *const Fixture, target: [:0]const u8, name: []const u8) !void {
        const p = try self.path(name);
        defer a.free(p);
        try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(target, p));
    }
    fn stat(self: *const Fixture, name: []const u8) !std.os.linux.Statx {
        const p = try self.path(name);
        defer a.free(p);
        var result: std.os.linux.Statx = undefined;
        const rc = std.c.statx(std.os.linux.AT.FDCWD, p, std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .SIZE = true, .INO = true, .MTIME = true, .CTIME = true }, &result);
        if (rc != 0 and std.c.errno(rc) == .NOENT) return error.NotFound;
        try std.testing.expectEqual(@as(c_int, 0), rc);
        return result;
    }
    fn contents(self: *const Fixture, name: []const u8, expected: []const u8) !void {
        const p = try self.path(name);
        defer a.free(p);
        const fd = std.c.open(p, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true });
        try std.testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        var buf: [256]u8 = undefined;
        const n = std.c.read(fd, &buf, buf.len);
        try std.testing.expect(n >= 0);
        try std.testing.expectEqualStrings(expected, buf[0..@intCast(n)]);
    }
    fn prepare(self: *const Fixture, kind: fs.Kind, source: []const u8, destination: []const u8) !fs.Prepared {
        return fs.prepare(a, .{ .kind = kind, .root = self.root, .source = source, .destination = destination }, self.cancel);
    }
    fn run(self: *const Fixture, kind: fs.Kind, source: []const u8, destination: []const u8) !void {
        var prepared = try self.prepare(kind, source, destination);
        defer prepared.deinit();
        try fs.apply(&prepared, self.cancel);
    }
};

test "operations: empty exclusive creates, Unicode and leading dash names, private modes" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.run(.create_directory, "", "-目录");
    try f.run(.create_file, "", "-目录/-é 🐚.txt");
    const dir = try f.stat("-目录");
    const file = try f.stat("-目录/-é 🐚.txt");
    try std.testing.expectEqual(std.c.S.IFDIR, dir.mode & std.c.S.IFMT);
    try std.testing.expectEqual(std.c.S.IFREG, file.mode & std.c.S.IFMT);
    // umask may restrict the requested modes further, never broaden them.
    try std.testing.expectEqual(@as(u16, 0), dir.mode & 0o077);
    try std.testing.expectEqual(@as(u16, 0), file.mode & 0o177);
    try std.testing.expectEqual(@as(u64, 0), file.size);
}

test "operations: rename and move preserve inode and contents; delete files and empty directories" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("target");
    try f.write("-原名", "keep these bytes");
    const before = try f.stat("-原名");
    try f.run(.rename, "-原名", "é");
    try std.testing.expectError(error.NotFound, f.stat("-原名"));
    try f.run(.move, "é", "target/-新名");
    try f.contents("target/-新名", "keep these bytes");
    try std.testing.expectEqual(before.ino, (try f.stat("target/-新名")).ino);
    try f.run(.delete, "target/-新名", "");
    try f.run(.delete, "target", "");
    try std.testing.expectError(error.NotFound, f.stat("target"));
}

test "operations: populated directories can move but deletion is never recursive" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("dir");
    try f.mkdir("other");
    try f.write("dir/child", "preserve");
    try f.run(.rename, "dir", "renamed");
    try f.run(.move, "renamed", "other/moved");
    var prepared = try f.prepare(.delete, "other/moved", "");
    defer prepared.deinit();
    try std.testing.expectError(error.DirectoryNotEmpty, fs.apply(&prepared, f.cancel));
    try f.contents("other/moved/child", "preserve");
}

test "operations: collisions preserve both entries, including hardlink aliases" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("source", "source bytes");
    try f.write("target", "target bytes");
    try f.mkdir("dir");
    for ([_]fs.Kind{ .create_file, .create_directory }) |kind| {
        try std.testing.expectError(error.AlreadyExists, f.prepare(kind, "", "target"));
        try std.testing.expectError(error.AlreadyExists, f.prepare(kind, "", "dir"));
    }
    for ([_]fs.Kind{ .rename, .move }) |kind| {
        try std.testing.expectError(error.AlreadyExists, f.prepare(kind, "source", "target"));
        try std.testing.expectError(error.AlreadyExists, f.prepare(kind, "source", "dir"));
    }
    const src = try f.path("source");
    defer a.free(src);
    const alias = try f.path("alias");
    defer a.free(alias);
    try std.testing.expectEqual(@as(c_int, 0), std.c.link(src, alias));
    try std.testing.expectError(error.AlreadyExists, f.prepare(.rename, "source", "alias"));
    try f.contents("source", "source bytes");
    try f.contents("target", "target bytes");
}

test "operations: destinations appearing after prepare are not replaced" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("source", "source");
    for ([_]fs.Kind{ .create_file, .create_directory, .rename, .move }) |kind| {
        var prepared = try f.prepare(kind, if (kind == .rename or kind == .move) "source" else "", "target");
        defer prepared.deinit();
        try f.write("target", "competitor");
        // Parent metadata changes fail even before the exclusive mutation syscall.
        try std.testing.expectError(error.StaleSnapshot, fs.apply(&prepared, f.cancel));
        try f.contents("target", "competitor");
        try f.contents("source", "source");
        try f.unlink("target");
    }
}

test "operations: reject traversal, absolute relatives, empty components, NUL, git and root mutation" {
    var f = try Fixture.init();
    defer f.deinit();
    const invalid = [_][]const u8{ ".", "..", "../escape", "/absolute", "a//b", "a/", "./a", "a/../b", "a/./b", "a\x00b", "\xff" };
    for (invalid) |path| {
        try std.testing.expectError(error.InvalidPath, f.prepare(.create_file, "", path));
        try std.testing.expectError(error.InvalidPath, f.prepare(.delete, path, ""));
    }
    for ([_][]const u8{ ".git", ".git/config", "a/.git", "a/.git/config" }) |path| {
        try std.testing.expectError(error.GitPath, f.prepare(.create_directory, "", path));
        try std.testing.expectError(error.GitPath, f.prepare(.delete, path, ""));
    }
    try std.testing.expectError(error.RootMutation, f.prepare(.delete, "", ""));
    try std.testing.expectError(error.RootMutation, f.prepare(.create_file, "", ""));
    try std.testing.expectError(error.InvalidRequest, f.prepare(.delete, "a", "b"));
    try std.testing.expectError(error.InvalidRequest, f.prepare(.create_file, "a", "b"));
    try f.run(.create_file, "", ".gitignore");
    try f.run(.create_directory, "", ".github");
}

test "operations: only canonical absolute roots, including root ancestor validation" {
    var f = try Fixture.init();
    defer f.deinit();
    for ([_][]const u8{ "", "relative" }) |root| {
        try std.testing.expectError(error.InvalidRoot, fs.prepare(a, .{ .kind = .create_file, .root = root, .destination = "x" }, f.cancel));
    }
    for ([_][]const u8{ "/tmp/", "/tmp//a", "/tmp/../a", "/tmp/./a", "//", "/tmp/\x00a" }) |root| {
        try std.testing.expectError(error.InvalidPath, fs.prepare(a, .{ .kind = .create_file, .root = root, .destination = "x" }, f.cancel));
    }
    try std.testing.expectError(error.GitPath, fs.prepare(a, .{ .kind = .delete, .root = "/tmp/.git/tree", .source = "x" }, f.cancel));
    try std.testing.expectError(error.RootMutation, fs.prepare(a, .{ .kind = .delete, .root = "/", .source = "" }, f.cancel));
}

test "operations: reject symlink sources, destinations, parents, root and root ancestors" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("real");
    try f.write("real/file", "safe");
    try f.symlink("real/file", "file-link");
    try f.symlink("real", "dir-link");
    try f.symlink("absent", "dangling");
    for ([_][]const u8{ "file-link", "dir-link", "dangling" }) |name| {
        try std.testing.expectError(error.Symlink, f.prepare(.delete, name, ""));
        try std.testing.expectError(error.Symlink, f.prepare(.create_file, "", name));
        try std.testing.expectError(error.Symlink, f.prepare(.move, "real/file", name));
    }
    try std.testing.expectError(error.Symlink, f.prepare(.create_file, "", "dir-link/new"));
    try std.testing.expectError(error.Symlink, f.prepare(.delete, "dir-link/file", ""));
    const root_link = try f.path("dir-link");
    defer a.free(root_link);
    try std.testing.expectError(error.Symlink, fs.prepare(a, .{ .kind = .create_file, .root = root_link, .destination = "new" }, f.cancel));
    try f.mkdir("real/sub");
    const ancestor_link = try f.path("dir-link/sub");
    defer a.free(ancestor_link);
    try std.testing.expectError(error.Symlink, fs.prepare(a, .{ .kind = .create_file, .root = ancestor_link, .destination = "new" }, f.cancel));
    try f.contents("real/file", "safe");
}

test "operations: FIFO and socket entries fail without opening or blocking" {
    var f = try Fixture.init();
    defer f.deinit();
    const fifo = try f.path("fifo");
    defer a.free(fifo);
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(fifo, 0o600));
    // A filesystem socket inode suffices: no listener or external service needed.
    const socket_path = try f.path("socket");
    defer a.free(socket_path);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.mknod(socket_path, std.c.S.IFSOCK | 0o600, 0)));
    for ([_][]const u8{ "fifo", "socket" }) |name| {
        try std.testing.expectError(error.SpecialFile, f.prepare(.delete, name, ""));
        try std.testing.expectError(error.SpecialFile, f.prepare(.rename, name, "new"));
        try std.testing.expectError(error.SpecialFile, f.prepare(.create_file, "", name));
    }
    try std.testing.expectError(error.SpecialFile, f.prepare(.create_file, "", "fifo/child"));
}

test "operations: no recursive mkdir and no rename to self or descendant" {
    var f = try Fixture.init();
    defer f.deinit();
    try std.testing.expectError(error.NotFound, f.prepare(.create_directory, "", "missing/child"));
    try std.testing.expectError(error.NotFound, f.stat("missing"));
    try f.mkdir("dir");
    try f.mkdir("dir/sub");
    try f.write("file", "x");
    try std.testing.expectError(error.NotDirectory, f.prepare(.create_file, "", "file/child"));
    for ([_]fs.Kind{ .rename, .move }) |kind| {
        try std.testing.expectError(error.InvalidDestination, f.prepare(kind, "dir", "dir"));
        try std.testing.expectError(error.InvalidDestination, f.prepare(kind, "dir", "dir/sub/child"));
        try std.testing.expectError(error.InvalidDestination, f.prepare(kind, "file", "file"));
    }
    // Component boundaries matter: this is not a descendant.
    try f.run(.rename, "dir", "directory");
}

test "operations: retained source descriptor pins an unlinked inode and rejects replacement" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("source", "original");
    const original = try f.stat("source");
    var prepared = try f.prepare(.delete, "source", "");
    defer prepared.deinit();
    try f.unlink("source");
    try f.write("source", "replacement");
    var retained: std.os.linux.Statx = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.statx(prepared.source_fd, "", std.os.linux.AT.EMPTY_PATH, .{ .INO = true, .NLINK = true }, &retained));
    try std.testing.expectEqual(original.ino, retained.ino);
    try std.testing.expectEqual(@as(u32, 0), retained.nlink);
    try std.testing.expect(original.ino != (try f.stat("source")).ino);
    try std.testing.expectError(error.StaleSnapshot, fs.apply(&prepared, f.cancel));
    try f.contents("source", "replacement");
}

test "operations: same-inode size and same-size content edits invalidate snapshots" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("source", "aaaa");
    for ([_][]const u8{ "longer data", "other bytes" }) |replacement| {
        const before = try f.stat("source");
        var prepared = try f.prepare(.rename, "source", "destination");
        defer prepared.deinit();
        try f.write("source", replacement);
        const after = try f.stat("source");
        try std.testing.expectEqual(before.ino, after.ino);
        try std.testing.expectError(error.StaleSnapshot, fs.apply(&prepared, f.cancel));
        try f.contents("source", replacement);
        try std.testing.expectError(error.NotFound, f.stat("destination"));
    }
}

test "operations: restored mtime still detects modification through ctime" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("source", "aaaa");
    const before = try f.stat("source");
    var prepared = try f.prepare(.delete, "source", "");
    defer prepared.deinit();
    try f.write("source", "bbbb");
    const p = try f.path("source");
    defer a.free(p);
    const times = [2]std.c.timespec{ .{ .sec = before.mtime.sec, .nsec = before.mtime.nsec }, .{ .sec = before.mtime.sec, .nsec = before.mtime.nsec } };
    try std.testing.expectEqual(@as(c_int, 0), std.c.utimensat(std.os.linux.AT.FDCWD, p, &times, 0));
    try std.testing.expectError(error.StaleSnapshot, fs.apply(&prepared, f.cancel));
    try f.contents("source", "bbbb");
}

test "operations: missing sources and symlink substitutions after prepare are stale" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("source", "original");
    try f.write("outside", "do not touch");
    var prepared = try f.prepare(.delete, "source", "");
    defer prepared.deinit();
    try f.unlink("source");
    try std.testing.expectError(error.StaleSnapshot, fs.apply(&prepared, f.cancel));
    try f.symlink("outside", "source");
    try std.testing.expectError(error.StaleSnapshot, fs.apply(&prepared, f.cancel));
    try f.contents("outside", "do not touch");
}

test "operations: source and destination parent replacement invalidate captured paths" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("from");
    try f.mkdir("to");
    try f.write("from/source", "original");
    {
        var prepared = try f.prepare(.move, "from/source", "to/result");
        defer prepared.deinit();
        try f.rename("from", "old-from");
        try f.mkdir("from");
        try f.write("from/source", "replacement");
        try std.testing.expectError(error.StaleSnapshot, fs.apply(&prepared, f.cancel));
        try f.contents("old-from/source", "original");
        try f.contents("from/source", "replacement");
    }
    {
        var prepared = try f.prepare(.move, "from/source", "to/result");
        defer prepared.deinit();
        try f.rename("to", "old-to");
        try f.mkdir("to");
        try std.testing.expectError(error.StaleSnapshot, fs.apply(&prepared, f.cancel));
        try std.testing.expectError(error.NotFound, f.stat("old-to/result"));
        try std.testing.expectError(error.NotFound, f.stat("to/result"));
    }
}

test "operations: root pathname replacement cannot mutate either old or new tree" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("source", "original");
    var prepared = try f.prepare(.delete, "source", "");
    defer prepared.deinit();
    const old = try std.fmt.allocPrintSentinel(a, "{s}/old-root", .{f.base}, 0);
    defer a.free(old);
    try std.testing.expectEqual(@as(c_int, 0), std.c.rename(f.root, old));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdir(f.root, 0o700));
    try f.write("source", "replacement");
    try std.testing.expectError(error.StaleSnapshot, fs.apply(&prepared, f.cancel));
    try f.contents("source", "replacement");
    try f.unlink("source");
    try std.testing.expectEqual(@as(c_int, 0), std.c.rmdir(f.root));
    try std.testing.expectEqual(@as(c_int, 0), std.c.rename(old, f.root));
    try f.contents("source", "original");
}

test "operations: cancellation before prepare/apply never mutates; committed values cannot replay" {
    var f = try Fixture.init();
    defer f.deinit();
    c.g_cancellable_cancel(f.cancel);
    try std.testing.expectError(error.Cancelled, f.prepare(.create_file, "", "new"));
    c.g_cancellable_reset(f.cancel);
    var prepared = try f.prepare(.create_file, "", "new");
    defer prepared.deinit();
    c.g_cancellable_cancel(f.cancel);
    try std.testing.expectError(error.Cancelled, fs.apply(&prepared, f.cancel));
    try std.testing.expectError(error.NotFound, f.stat("new"));
    c.g_cancellable_reset(f.cancel);
    try fs.apply(&prepared, f.cancel);
    c.g_cancellable_cancel(f.cancel);
    try std.testing.expectError(error.AlreadyApplied, fs.apply(&prepared, f.cancel));
    try f.contents("new", "");
}

test "operations: prepared owns all input bytes" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("source", "owned");
    const root = try a.dupe(u8, f.root);
    const source = try a.dupe(u8, "source");
    const destination = try a.dupe(u8, "target");
    var prepared = try fs.prepare(a, .{ .kind = .move, .root = root, .source = source, .destination = destination }, f.cancel);
    defer prepared.deinit();
    @memset(root, 'x');
    @memset(source, 'x');
    @memset(destination, 'x');
    a.free(root);
    a.free(source);
    a.free(destination);
    try fs.apply(&prepared, f.cancel);
    try f.contents("target", "owned");
}

test "operations: 4095-byte absolute path cap and per-component kernel limit" {
    var f = try Fixture.init();
    defer f.deinit();
    const oversized = try a.alloc(u8, fs.path_limit + 1);
    defer a.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.PathTooLong, f.prepare(.create_file, "", oversized));
    oversized[0] = '/';
    try std.testing.expectError(error.PathTooLong, fs.prepare(a, .{ .kind = .create_file, .root = oversized, .destination = "x" }, f.cancel));
    const name: [256]u8 = @splat('x');
    // prepare may see ENAMETOOLONG from the final absence lookup.
    try std.testing.expectError(error.PathTooLong, f.prepare(.create_file, "", &name));
    const relative = try a.alloc(u8, fs.path_limit - f.root.len - 1);
    defer a.free(relative);
    @memset(relative, 'x');
    var offset: usize = 200;
    while (offset < relative.len - 1) : (offset += 201) relative[offset] = '/';
    const parent_end = std.mem.lastIndexOfScalar(u8, relative, '/').?;
    const parent = try std.fmt.allocPrint(a, "root/{s}", .{relative[0..parent_end]});
    defer a.free(parent);
    try f.tmp.dir.createDirPath(io, parent);
    try f.run(.create_file, "", relative);
    try std.testing.expectEqual(@as(u64, 0), (try f.stat(relative)).size);
    const too_long = try std.fmt.allocPrint(a, "{s}x", .{relative});
    defer a.free(too_long);
    try std.testing.expectError(error.PathTooLong, f.prepare(.create_file, "", too_long));
}

fn allocationCase(allocator: std.mem.Allocator, root: []const u8, cancel: *c.GCancellable) !void {
    var prepared = try fs.prepare(allocator, .{ .kind = .move, .root = root, .source = "from/source", .destination = "to/result" }, cancel);
    defer prepared.deinit();
}

fn descriptorCount() !usize {
    var dir = try std.Io.Dir.openDirAbsolute(io, "/proc/self/fd", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

test "operations: preparation cleans all allocations and descriptors on failure" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("from");
    try f.mkdir("to");
    try f.write("from/source", "original");
    const descriptors = try descriptorCount();
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{ f.root, f.cancel });
    try std.testing.expectEqual(descriptors, try descriptorCount());
    try f.contents("from/source", "original");
    try std.testing.expectError(error.NotFound, f.stat("to/result"));
}

var collision_path: ?[:0]const u8 = null;
fn createCollision(_: *c.GCancellable) void {
    const fd = std.c.open(collision_path.?, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    std.debug.assert(fd >= 0);
    defer _ = std.c.close(fd);
    std.debug.assert(std.c.write(fd, "racer", 5) == 5);
}
fn cancelAtBoundary(cancel: *c.GCancellable) void {
    c.g_cancellable_cancel(cancel);
}

test "operations: exclusive syscalls preserve destinations racing the final validation" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("source", "original");
    const target = try f.path("target");
    defer a.free(target);
    collision_path = target;
    fs.TestHooks.before_mutation = createCollision;
    defer {
        fs.TestHooks.before_mutation = null;
        collision_path = null;
    }
    for ([_]fs.Kind{ .create_file, .create_directory, .rename, .move }) |kind| {
        var prepared = try f.prepare(kind, if (kind == .rename or kind == .move) "source" else "", "target");
        defer prepared.deinit();
        try std.testing.expectError(error.AlreadyExists, fs.apply(&prepared, f.cancel));
        try std.testing.expect(!prepared.committed);
        try f.contents("target", "racer");
        try f.contents("source", "original");
        try f.unlink("target");
    }
}

test "operations: last pre-syscall cancellation aborts; post-commit cancellation returns success" {
    defer {
        fs.TestHooks.before_mutation = null;
        fs.TestHooks.after_mutation = null;
    }
    for ([_]fs.Kind{ .create_file, .create_directory, .rename, .move, .delete }) |kind| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.write("source", "original");
        var prepared = try f.prepare(kind, if (kind == .create_file or kind == .create_directory) "" else "source", if (kind == .delete) "" else "target");
        defer prepared.deinit();
        fs.TestHooks.before_mutation = cancelAtBoundary;
        try std.testing.expectError(error.Cancelled, fs.apply(&prepared, f.cancel));
        try std.testing.expect(!prepared.committed);
        try f.contents("source", "original");
        try std.testing.expectError(error.NotFound, f.stat("target"));
        fs.TestHooks.before_mutation = null;
        c.g_cancellable_reset(f.cancel);
        fs.TestHooks.after_mutation = cancelAtBoundary;
        try fs.apply(&prepared, f.cancel);
        try std.testing.expect(prepared.committed);
        try std.testing.expect(c.g_cancellable_is_cancelled(f.cancel) != 0);
        if (kind == .delete) {
            try std.testing.expectError(error.NotFound, f.stat("source"));
        } else {
            _ = try f.stat("target");
        }
        fs.TestHooks.after_mutation = null;
    }
}

test "operations: cross-device move fails without copying or deleting" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("source", "original");
    // Both names are relative to one canonical root (/), but the destination
    // uses a second filesystem. Do not require mount privileges in the suite.
    const other = try a.dupeSentinel(u8, "/dev/shm/coral-operations-XXXXXX", 0);
    defer a.free(other);
    if (mkdtemp(other) == null) return error.SkipZigTest;
    defer std.debug.assert(std.c.rmdir(other) == 0);
    var other_stat: std.os.linux.Statx = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.statx(std.os.linux.AT.FDCWD, other, 0, .{ .TYPE = true }, &other_stat));
    const source_stat = try f.stat("source");
    if (source_stat.dev_major == other_stat.dev_major and source_stat.dev_minor == other_stat.dev_minor) return error.SkipZigTest;
    const source = try f.path("source");
    defer a.free(source);
    const destination = try std.fmt.allocPrintSentinel(a, "{s}/target", .{other}, 0);
    defer a.free(destination);
    for ([_]fs.Kind{ .rename, .move }) |kind| {
        var prepared = try fs.prepare(a, .{ .kind = kind, .root = "/", .source = source[1..], .destination = destination[1..] }, f.cancel);
        defer prepared.deinit();
        try std.testing.expectError(error.CrossDevice, fs.apply(&prepared, f.cancel));
        try f.contents("source", "original");
        var result: std.os.linux.Statx = undefined;
        const rc = std.c.statx(std.os.linux.AT.FDCWD, destination, 0, .{ .TYPE = true }, &result);
        try std.testing.expectEqual(std.os.linux.E.NOENT, std.c.errno(rc));
    }
}
