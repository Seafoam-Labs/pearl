//! Bounded, nonrecursive, worker-only Linux browsing. No symlink components are
//! followed, including ancestors of the model's canonical root. This protects
//! enumeration, not a subsequent path-based editor load against rename races.
const std = @import("std");
const fs = @import("manifest_fs.zig");
const manifest = @import("manifest.zig");
const c = @import("../c.zig").c;
pub const limit = 500;
pub const Kind = enum { directory, file, blocked };
pub const Entry = struct { name: []const u8, kind: Kind };
pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,
    truncated: bool,
    pub fn deinit(self: *Listing) void {
        self.arena.deinit();
    }
};

/// Join without lexical dot-dot normalization: link/.. has physical semantics.
/// Model canonicalizes available roots; missing roots keep their absolute spelling.
pub fn absolute(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    try manifest.validateString(path, manifest.limits.path_bytes);
    if (path[0] == '/') return allocator.dupe(u8, path);
    const cwd = c.g_get_current_dir();
    defer c.g_free(cwd);
    const result = try std.fs.path.join(allocator, &.{ std.mem.span(cwd), path });
    errdefer allocator.free(result);
    try fs.absolutePath(result);
    return result;
}

fn component(part: []const u8) !void {
    if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.indexOfScalar(u8, part, '/') != null) return error.OutsideRoot;
    try manifest.validateString(part, manifest.limits.path_bytes);
}

fn child(fd: c_int, name: []const u8, directory: bool) !c_int {
    try component(name);
    const z = try std.heap.c_allocator.dupeSentinel(u8, name, 0);
    defer std.heap.c_allocator.free(z);
    const result = std.c.openat(fd, z, .{ .ACCMODE = .RDONLY, .DIRECTORY = directory, .PATH = true, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (result < 0) return error.UnavailableOrSymlink;
    return result;
}

fn rootDescriptor(root: []const u8) !c_int {
    try fs.absolutePath(root);
    // Ancestors need search permission, never directory-listing permission.
    // O_PATH|O_DIRECTORY|O_NOFOLLOW rejects directory symlinks; the final
    // O_PATH file descriptor is separately inspected by checkFile below.
    var fd = std.c.open("/", .{ .PATH = true, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) return error.UnavailableOrSymlink;
    errdefer _ = std.c.close(fd);
    if (root.len == 1) return fd;
    var parts = std.mem.splitScalar(u8, root[1..], '/');
    while (parts.next()) |part| {
        const next = try child(fd, part, true);
        _ = std.c.close(fd);
        fd = next;
    }
    return fd;
}

fn walk(root: []const u8, relative: []const u8, directory: bool) !c_int {
    var fd = try rootDescriptor(root);
    errdefer _ = std.c.close(fd);
    if (relative.len == 0) {
        if (!directory) return error.NotRegularFile;
        return fd;
    }
    var parts = std.mem.splitScalar(u8, relative, '/');
    while (parts.next()) |part| {
        const next = try child(fd, part, directory or parts.peek() != null);
        _ = std.c.close(fd);
        fd = next;
    }
    return fd;
}

pub fn checkFile(root: []const u8, relative: []const u8) !void {
    const fd = try walk(root, relative, false);
    defer _ = std.c.close(fd);
    var stat: std.os.linux.Statx = undefined;
    if (std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stat) != 0 or !stat.mask.TYPE) return error.Io;
    if (stat.mode & std.c.S.IFMT != std.c.S.IFREG) return error.NotRegularFile;
}

pub fn scan(allocator: std.mem.Allocator, root: []const u8, relative: []const u8, cancel: *c.GCancellable) !Listing {
    const traversal = try walk(root, relative, true);
    defer _ = std.c.close(traversal);
    // Reopen the pinned final directory, not its original spelling. fdopendir
    // must receive a readable FD, and takes ownership only on success.
    const fd = std.c.openat(traversal, ".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) return error.UnavailableOrSymlink;
    const dir = std.c.fdopendir(fd) orelse {
        _ = std.c.close(fd);
        return error.Io;
    };
    defer _ = std.c.closedir(dir);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var entries: std.ArrayList(Entry) = .empty;
    var truncated = false;
    while (true) {
        if (c.g_cancellable_is_cancelled(cancel) != 0) return error.Cancelled;
        std.c._errno().* = 0;
        const raw = std.c.readdir(dir) orelse {
            if (std.c.errno(@as(c_int, -1)) != .SUCCESS) return error.Io;
            break;
        };
        const name = std.mem.sliceTo(&raw.name, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (entries.items.len == limit) {
            truncated = true;
            break;
        }
        var stat: std.os.linux.Statx = undefined;
        const kind: Kind = if (std.c.statx(fd, @ptrCast(&raw.name), std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stat) != 0 or !stat.mask.TYPE) .blocked else switch (stat.mode & std.c.S.IFMT) {
            std.c.S.IFDIR => .directory,
            std.c.S.IFREG => .file,
            else => .blocked,
        };
        // Keep invalid native names visible, but never pass them to GTK or open.
        const valid = std.unicode.utf8ValidateSlice(name);
        try entries.append(a, .{ .name = try a.dupe(u8, if (valid) name else "[unsupported filename encoding]"), .kind = if (valid) kind else .blocked });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, x: Entry, y: Entry) bool {
            if (x.kind != y.kind) return @backingInt(x.kind) < @backingInt(y.kind);
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.less);
    return .{ .arena = arena, .entries = try entries.toOwnedSlice(a), .truncated = truncated };
}

test "browser traverses execute-only ancestors but requires a readable final scan directory" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    const a = std.testing.allocator;
    const temp = c.g_dir_make_tmp("coral-browser-permissions-XXXXXX", null) orelse return error.TempDirectory;
    defer c.g_free(temp);
    defer _ = c.g_rmdir(temp);
    const parent = try std.fmt.allocPrintSentinel(a, "{s}/search-only", .{std.mem.span(temp)}, 0);
    defer a.free(parent);
    const root = try std.fmt.allocPrintSentinel(a, "{s}/readable", .{parent}, 0);
    defer a.free(root);
    const middle = try std.fmt.allocPrintSentinel(a, "{s}/middle", .{root}, 0);
    defer a.free(middle);
    const leaf = try std.fmt.allocPrintSentinel(a, "{s}/leaf", .{middle}, 0);
    defer a.free(leaf);
    const file = try std.fmt.allocPrintSentinel(a, "{s}/file.txt", .{leaf}, 0);
    defer a.free(file);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdir(parent, 0o700));
    defer _ = c.g_rmdir(parent);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdir(root, 0o700));
    defer _ = c.g_rmdir(root);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdir(middle, 0o700));
    defer _ = c.g_rmdir(middle);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdir(leaf, 0o700));
    defer _ = c.g_rmdir(leaf);
    try std.testing.expect(c.g_file_set_contents(file, "test", 4, null) != 0);
    defer _ = c.g_unlink(file);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(parent, 0o111));
    defer _ = std.c.chmod(parent, 0o700);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(middle, 0o111));
    defer _ = std.c.chmod(middle, 0o700);
    const denied = std.c.open(parent, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    defer if (denied >= 0) {
        _ = std.c.close(denied);
    };
    try std.testing.expect(denied < 0);
    try std.testing.expectEqual(std.c.E.ACCES, std.c.errno(denied));
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var top = try scan(a, root, "", cancel);
    defer top.deinit();
    try std.testing.expectEqualStrings("middle", top.entries[0].name);
    var nested = try scan(a, root, "middle/leaf", cancel);
    defer nested.deinit();
    try std.testing.expectEqualStrings("file.txt", nested.entries[0].name);
    try checkFile(root, "middle/leaf/file.txt");
    try std.testing.expectError(error.UnavailableOrSymlink, scan(a, root, "middle", cancel));
}

test "browser components reject lexical escapes" {
    try std.testing.expectError(error.OutsideRoot, component(".."));
    try std.testing.expectError(error.OutsideRoot, component("."));
    try std.testing.expectError(error.OutsideRoot, component("/outside"));
    try std.testing.expectError(error.OutsideRoot, component("a/b"));
    try component("normal file");
}
