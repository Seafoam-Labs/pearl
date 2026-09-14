//! Descriptor-based trusted reads. Production paths must be root-owned and immutable to greeter/users.
const std = @import("std");
const options = @import("build_options");
const a = std.heap.c_allocator;
pub fn open(path: []const u8, directory: bool) !c_int {
    if (path.len == 0 or path[0] != '/' or path.len > 4096) return error.InvalidPath;
    var fd = std.c.open("/", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.Open;
    errdefer _ = std.c.close(fd);
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidPath;
        const z = try a.dupeZ(u8, part);
        defer a.free(z);
        const last = parts.peek() == null;
        const next = std.c.openat(fd, z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true, .DIRECTORY = !last or directory }, @as(c_uint, 0));
        if (next < 0) return error.UntrustedPath;
        _ = std.c.close(fd);
        fd = next;
        var stat: std.os.linux.Statx = undefined;
        if (std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .UID = true, .SIZE = true }, &stat) != 0) return error.Stat;
        if (!options.test_hooks and (stat.uid != 0 or stat.mode & 0o022 != 0)) return error.UntrustedPath;
        if (last and !directory and !std.c.S.ISREG(stat.mode)) return error.NotRegular;
    }
    return fd;
}
pub fn read(allocator: std.mem.Allocator, path: []const u8, max: usize) ![]const u8 {
    const fd = try open(path, false);
    defer _ = std.c.close(fd);
    const bytes = try allocator.alloc(u8, max + 1);
    errdefer allocator.free(bytes);
    var n: usize = 0;
    while (n < bytes.len) {
        const got = std.c.read(fd, bytes[n..].ptr, bytes.len - n);
        if (got < 0) {
            if (std.posix.errno(got) == .INTR) continue;
            return error.Read;
        }
        if (got == 0) break;
        n += @intCast(got);
    }
    if (n > max) return error.FileTooLarge;
    const result = try allocator.dupe(u8, bytes[0..n]);
    allocator.free(bytes);
    return result;
}
