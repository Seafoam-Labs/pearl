//! Linux host-memory guard. GPU budgets remain estimates, not VRAM isolation.
const std = @import("std");
const glib = @import("glib2");
pub const limit = 1536 * 1024 * 1024;
pub fn read(path: [:0]const u8, buffer: []u8) ![]const u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, @as(c_uint, 0));
    if (fd < 0) return error.MemoryInformationUnavailable;
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, buffer.ptr, buffer.len);
    if (n <= 0 or n == buffer.len) return error.MemoryInformationUnavailable;
    return buffer[0..@intCast(n)];
}
fn write(path: [:0]const u8, value: []const u8) bool {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    return std.c.write(fd, value.ptr, value.len) == value.len;
}
pub const Group = struct {
    path: ?[:0]const u8 = null,
    procs: c_int = -1,
    pub fn create(a: std.mem.Allocator) Group {
        var buffer: [8192]u8 = undefined;
        const membership = read("/proc/self/cgroup", &buffer) catch return .{};
        var lines = std.mem.splitScalar(u8, membership, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "0::/") or std.mem.indexOf(u8, line, "..") != null) continue;
            const path = std.fmt.allocPrintSentinel(a, "/sys/fs/cgroup{s}/pearl-inference-{d}-{d}", .{ line[3..], std.c.getpid(), glib.getMonotonicTime() }, 0) catch return .{};
            if (std.c.mkdir(path, 0o700) != 0) return .{};
            const max_path = std.fmt.allocPrintSentinel(a, "{s}/memory.max", .{path}, 0) catch return .{};
            const high_path = std.fmt.allocPrintSentinel(a, "{s}/memory.high", .{path}, 0) catch return .{};
            const group_path = std.fmt.allocPrintSentinel(a, "{s}/cgroup.procs", .{path}, 0) catch return .{};
            if (!write(max_path, "1610612736") or !write(high_path, "1476395008")) {
                _ = std.c.rmdir(path);
                return .{};
            }
            const fd = std.c.open(group_path, .{ .ACCMODE = .WRONLY }, @as(c_uint, 0));
            if (fd < 0) {
                _ = std.c.rmdir(path);
                return .{};
            }
            return .{ .path = path, .procs = fd };
        }
        return .{};
    }
    pub fn close(self: *Group) void {
        if (self.procs >= 0) _ = std.c.close(self.procs);
        if (self.path) |path| _ = std.c.rmdir(path);
        self.* = .{};
    }
};
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
    const rss = kibField(bytes, "VmRSS:") orelse return error.RuntimeExited;
    if (rss > limit / 1024) return error.RuntimeMemoryBudgetExceeded;
    if (availableMiB()) |available| if (available < 384) return error.SystemMemoryPressure;
}
test "memory fields distinguish available RAM from total RAM" {
    try std.testing.expectEqual(@as(?u64, 3072000), kibField("MemTotal: 6000000 kB\nMemAvailable: 3072000 kB\n", "MemAvailable:"));
    try std.testing.expectEqual(@as(?u64, null), kibField("MemTotal: 6000000 kB", "MemAvailable:"));
}
