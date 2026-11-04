//! Explicit samples make retention deterministic. No clock is ever modified.
const std = @import("std");
pub const Sample = struct { wall_seconds: i64, boottime_ns: u64 };
pub const Error = error{ClockUntrusted};
pub const Clock = struct {
    effective_ns: i128 = 0,
    boottime_ns: u64 = 0,
    initialized: bool = false,
    pub fn start(self: *Clock, sample: Sample, floor: i64) Error!i64 {
        if (sample.wall_seconds < 0 or floor < 0 or @as(i128, floor) - sample.wall_seconds > 300) return error.ClockUntrusted;
        self.* = .{ .effective_ns = @as(i128, @max(sample.wall_seconds, floor)) * 1_000_000_000, .boottime_ns = sample.boottime_ns, .initialized = true };
        return @intCast(@divFloor(self.effective_ns, 1_000_000_000));
    }
    pub fn advance(self: *Clock, sample: Sample) Error!i64 {
        if (!self.initialized or sample.wall_seconds < 0 or sample.boottime_ns < self.boottime_ns) return error.ClockUntrusted;
        const elapsed = std.math.add(i128, self.effective_ns, sample.boottime_ns - self.boottime_ns) catch return error.ClockUntrusted;
        const effective = @max(elapsed, @as(i128, sample.wall_seconds) * 1_000_000_000);
        const seconds = @divFloor(effective, 1_000_000_000);
        if (seconds > std.math.maxInt(i64)) return error.ClockUntrusted;
        self.effective_ns = effective;
        self.boottime_ns = sample.boottime_ns;
        return @intCast(seconds);
    }
};
pub fn read() Error!Sample {
    var wall: std.c.timespec = undefined;
    var boot: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &wall) != 0 or std.c.clock_gettime(.BOOTTIME, &boot) != 0 or wall.sec < 0 or boot.sec < 0 or boot.nsec < 0 or boot.nsec >= 1_000_000_000) return error.ClockUntrusted;
    const boot_ns = std.math.mul(u64, @intCast(boot.sec), 1_000_000_000) catch return error.ClockUntrusted;
    return .{ .wall_seconds = wall.sec, .boottime_ns = std.math.add(u64, boot_ns, @intCast(boot.nsec)) catch return error.ClockUntrusted };
}
