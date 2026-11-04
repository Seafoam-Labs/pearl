//! A level-triggered, coalescing worker wakeup. No pointers cross this boundary.
//! The owner removes its main-context watch before joining/destroying the worker.
const std = @import("std");

pub const Completion = struct {
    fd: c_int,

    pub fn init() error{NotificationUnavailable}!Completion {
        const result = std.os.linux.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC);
        if (std.os.linux.errno(result) != .SUCCESS) return error.NotificationUnavailable;
        return .{ .fd = @intCast(result) };
    }

    pub fn signal(self: *const Completion) void {
        const value: u64 = 1;
        while (std.c.write(self.fd, std.mem.asBytes(&value).ptr, @sizeOf(u64)) < 0) {
            const err = std.c._errno().*;
            if (err == @backingInt(std.posix.E.INTR)) continue;
            // Saturation already means the descriptor is readable. No close is
            // permitted while the worker runs, so other failures are bugs.
            std.debug.assert(err == @backingInt(std.posix.E.AGAIN));
            return;
        }
    }

    pub fn drain(self: *const Completion) void {
        var value: u64 = undefined;
        // One read consumes the accumulated count. A concurrent signal remains
        // readable for the next dispatch; draining never waits for the worker.
        while (std.c.read(self.fd, std.mem.asBytes(&value).ptr, @sizeOf(u64)) < 0) {
            const err = std.c._errno().*;
            if (err == @backingInt(std.posix.E.INTR)) continue;
            std.debug.assert(err == @backingInt(std.posix.E.AGAIN));
            return;
        }
    }

    pub fn deinit(self: *Completion) void {
        _ = std.c.close(self.fd);
        self.fd = -1;
    }
};
