//! Linux memory information. Pearl does not impose a runtime memory ceiling.
const std = @import("std");
pub fn read(path: [:0]const u8, buffer: []u8) ![]const u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, @as(c_uint, 0));
    if (fd < 0) return error.MemoryInformationUnavailable;
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, buffer.ptr, buffer.len);
    if (n <= 0 or n == buffer.len) return error.MemoryInformationUnavailable;
    return buffer[0..@intCast(n)];
}
pub fn kibField(bytes: []const u8, name: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, name)) continue;
        var fields = std.mem.tokenizeAny(u8, line[name.len..], " \t");
        return std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch null;
    }
    return null;
}
pub fn availableMiB() ?u64 {
    var buffer: [8192]u8 = undefined;
    return (kibField(read("/proc/meminfo", &buffer) catch return null, "MemAvailable:") orelse return null) / 1024;
}
pub fn check(pid: c_int) !void {
    var path: [128]u8 = undefined;
    var buffer: [8192]u8 = undefined;
    const bytes = try read(try std.fmt.bufPrintZ(&path, "/proc/{d}/status", .{pid}), &buffer);
    _ = kibField(bytes, "VmRSS:") orelse return error.RuntimeExited;
}
test "memory fields distinguish available RAM from total RAM" {
    try std.testing.expectEqual(@as(?u64, 3072000), kibField("MemTotal: 6000000 kB\nMemAvailable: 3072000 kB\n", "MemAvailable:"));
    try std.testing.expectEqual(@as(?u64, null), kibField("MemTotal: 6000000 kB", "MemAvailable:"));
}
