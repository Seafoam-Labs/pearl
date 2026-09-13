//! Bounded regular-file I/O, optimistic replacement, private atomic snapshots.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
pub const a = std.heap.c_allocator;
pub const Read = struct { bytes: []const u8, etag: ?[:0]const u8 = null, missing: bool = false, hash: [64]u8 };
pub fn digest(bytes: []const u8) [64]u8 {
    @setEvalBranchQuota(10000);
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}
fn etag(alloc: std.mem.Allocator, path: [:0]const u8) ![:0]const u8 {
    const file = gio.File.newForPath(path);
    defer file.unref();
    const info = file.queryInfo("etag::value", .{ .nofollow_symlinks = true }, null, null) orelse return error.ReadFailed;
    defer info.unref();
    return alloc.dupeZ(u8, std.mem.span(info.getEtag() orelse return error.ReadFailed));
}
pub fn read(alloc: std.mem.Allocator, path: [:0]const u8, limit: usize, cancel: ?*gio.Cancellable) !Read {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) {
        if (std.posix.errno(fd) == .NOENT) return .{ .bytes = "", .missing = true, .hash = digest("missing") };
        return error.ReadFailed;
    }
    defer _ = std.c.close(fd);
    var stat: std.os.linux.Statx = undefined;
    if (std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true }, &stat) != 0 or !stat.mask.TYPE or !stat.mask.SIZE or stat.mode & std.c.S.IFMT != std.c.S.IFREG or stat.size > limit) return error.InvalidFile;
    const tag = try etag(alloc, path);
    const bytes = try alloc.alloc(u8, limit + 1);
    var used: usize = 0;
    while (used < bytes.len) {
        if (cancel) |c| if (c.isCancelled() != 0) return error.Cancelled;
        const n = std.c.read(fd, bytes[used..].ptr, @min(65536, bytes.len - used));
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        used += @intCast(n);
    }
    if (used > limit) return error.FileTooLarge;
    const after = try etag(alloc, path);
    if (!std.mem.eql(u8, tag, after)) return error.Conflict;
    return .{ .bytes = bytes[0..used], .etag = tag, .hash = digest(bytes[0..used]) };
}
pub fn mkdir(path: [:0]const u8) !void {
    if (glib.mkdirWithParents(path, 0o700) != 0) return error.CreateDirectoryFailed;
}
/// GIO checks etag again at replacement; first creation uses link's no-replace guarantee.
pub fn replace(path: [:0]const u8, bytes: []const u8, expected: Read, cancel: ?*gio.Cancellable) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const disk = try read(arena.allocator(), path, 131072, cancel);
    if (!std.mem.eql(u8, &disk.hash, &expected.hash)) return error.Conflict;
    if (cancel) |c| if (c.isCancelled() != 0) return error.Cancelled;
    if (disk.missing) return atomic(path, bytes, true);
    const file = gio.File.newForPath(path);
    defer file.unref();
    var err: ?*glib.Error = null;
    const ok = file.replaceContents(bytes.ptr, bytes.len, disk.etag.?, 0, .{ .private = true, .replace_destination = true }, null, cancel, &err);
    if (err) |e| {
        defer e.free();
        if (e.matches(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.wrong_etag)) != 0) return error.Conflict;
    }
    if (ok == 0) return error.SaveFailed;
}
pub fn atomic(path: [:0]const u8, bytes: []const u8, exclusive: bool) !void {
    const temp = try std.fmt.allocPrintSentinel(a, "{s}.XXXXXX", .{path}, 0);
    defer a.free(temp);
    const fd = glib.mkstempFull(temp, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CLOEXEC = true }), 0o600);
    if (fd < 0) return error.SaveFailed;
    defer _ = std.c.close(fd);
    defer _ = std.c.unlink(temp);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n <= 0) return error.SaveFailed;
        offset += @intCast(n);
    }
    if (std.c.fsync(fd) != 0) return error.SaveFailed;
    if (exclusive) {
        if (std.c.link(temp, path) != 0) return error.Conflict;
    } else if (std.c.rename(temp, path) != 0) return error.SaveFailed;
    const parent = try a.dupeZ(u8, std.fs.path.dirname(path) orelse "/");
    defer a.free(parent);
    const dir = std.c.open(parent, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, @as(c_uint, 0));
    if (dir >= 0) {
        defer _ = std.c.close(dir);
        if (std.c.fsync(dir) != 0) return error.SaveFailed;
    }
}
