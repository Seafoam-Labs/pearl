const std = @import("std");
const m = @import("../core/model.zig");
const io = @import("io.zig");
const c = io.c;
pub const Target = struct {
    fd: c_int,
    id: m.Identity,
    pub fn open(id: m.Identity) !Target {
        if (id.pid <= 1 or id.pid == c.getpid()) return error.ProtectedProcess;
        const result = c.syscall(@as(c_long, c.SYS_pidfd_open), @as(c_int, id.pid), @as(c_uint, 0));
        if (result < 0) return error.ProcessUnavailable;
        const fd: c_int = @intCast(result);
        errdefer _ = c.close(fd);
        const p = io.path("/proc/{d}/stat", .{id.pid});
        var buffer: [8192]u8 = undefined;
        const process = m.parseProcess(io.read(p.slice(), &buffer) orelse return error.ProcessExited, 4096) orelse return error.ProcessExited;
        if (!process.id.eql(id)) return error.IdentityChanged;
        // This pidfd is retained from confirmation through dispatch; PID reuse cannot retarget it.
        return .{ .fd = fd, .id = id };
    }
    pub fn close(self: Target) void {
        _ = c.close(self.fd);
    }
    pub fn signal(self: Target, force: bool) !void {
        if (c.syscall(@as(c_long, c.SYS_pidfd_send_signal), self.fd, @as(c_int, if (force) c.SIGKILL else c.SIGTERM), @as(?*anyopaque, null), @as(c_uint, 0)) < 0) {
            return switch (c.__errno_location().*) {
                c.ESRCH => error.ProcessExited,
                c.EPERM => error.PermissionDenied,
                else => error.SignalFailed,
            };
        }
    }
};
test "process controls reject self and reused identity" {
    try std.testing.expectError(error.ProtectedProcess, Target.open(.{ .pid = c.getpid(), .start = 1 }));
    try std.testing.expectError(error.ProtectedProcess, Target.open(.{ .pid = 1, .start = 1 }));
}
test "pidfd rejects stale identity and signals only a disposable child" {
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        while (true) _ = c.pause();
    }
    var reaped = false;
    defer if (!reaped) {
        _ = c.kill(pid, c.SIGKILL);
        _ = c.waitpid(pid, null, 0);
    };
    const path = io.path("/proc/{d}/stat", .{pid});
    var buf: [8192]u8 = undefined;
    const process = m.parseProcess(io.read(path.slice(), &buf).?, 4096).?;
    var stale = process.id;
    stale.start +%= 1;
    try std.testing.expectError(error.IdentityChanged, Target.open(stale));
    const target = try Target.open(process.id);
    defer target.close();
    try target.signal(false);
    var status: c_int = 0;
    try std.testing.expectEqual(pid, c.waitpid(pid, &status, 0));
    reaped = true;
    try std.testing.expectError(error.ProcessExited, target.signal(true));
}
