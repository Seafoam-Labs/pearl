//! Pure lock/suspend gate. Request acceptance never means the screen is locked.
const std = @import("std");
pub const Timeouts = struct {
    lock_seconds: u32 = 0,
    suspend_seconds: u32 = 0,
    screen_off_seconds: u32 = 0,
    dim: bool = false,
    pub fn dimSeconds(self: Timeouts) u32 {
        return if (self.dim and self.screen_off_seconds > 1) self.screen_off_seconds - @min(30, self.screen_off_seconds / 2) else 0;
    }
};
pub const Config = struct {
    ac: Timeouts = .{},
    battery: Timeouts = .{},
    automatic_saver: u8 = 0,
    pub fn validate(self: Config) !void {
        for ([_]Timeouts{ self.ac, self.battery }) |p| {
            if (p.lock_seconds > 86400 or p.suspend_seconds > 86400 or p.screen_off_seconds > 86400) return error.InvalidIdleTimeout;
            if (p.suspend_seconds > 0 and (p.lock_seconds == 0 or p.suspend_seconds <= p.lock_seconds)) return error.LockBeforeSuspendRequired;
            if (p.suspend_seconds > 0 and p.screen_off_seconds > p.suspend_seconds) return error.ScreenOffAfterSuspend;
        }
        if (self.automatic_saver != 0 and self.automatic_saver != 10 and self.automatic_saver != 20 and self.automatic_saver != 30) return error.InvalidPowerSaverThreshold;
    }
};
pub const Gate = struct {
    available: bool = false,
    active: bool = false,
    locked: bool = false,
    ready: bool = false,
    requesting: bool = false,
    failed: bool = false,
    sleep_pending: bool = false,
    inhibited: bool = false,
    preparing: bool = false,
    pub fn acquired(self: Gate) bool {
        return self.available and self.active and self.locked and self.ready and !self.failed;
    }
    pub fn canSuspend(self: Gate) bool {
        return self.sleep_pending and self.acquired() and !self.inhibited and !self.preparing;
    }
    pub fn fail(self: *Gate) void {
        self.failed = true;
        self.requesting = false;
        self.sleep_pending = false;
        self.ready = false;
    }
    pub fn reset(self: *Gate) void {
        self.sleep_pending = false;
        self.preparing = false;
        self.failed = false;
    }
};
test "lock requires actual acquisition and current session; inhibitors and failure block suspend" {
    var g: Gate = .{ .available = true, .active = true, .requesting = true, .sleep_pending = true };
    try std.testing.expect(!g.canSuspend());
    g.ready = true;
    try std.testing.expect(!g.canSuspend());
    g.locked = true;
    try std.testing.expect(g.canSuspend());
    g.inhibited = true;
    try std.testing.expect(!g.canSuspend());
    g.inhibited = false;
    g.available = false;
    try std.testing.expect(!g.canSuspend());
    g.available = true;
    g.fail();
    try std.testing.expect(!g.canSuspend());
    g.reset();
    try std.testing.expect(!g.sleep_pending);
}
test "idle policy is opt-in and must lock before suspend" {
    try (Config{}).validate();
    try std.testing.expectError(error.LockBeforeSuspendRequired, (Config{ .battery = .{ .suspend_seconds = 5 } }).validate());
    try (Config{ .battery = .{ .lock_seconds = 300, .suspend_seconds = 600 } }).validate();
}
test "dimming precedes blanking and new policies are opt in" {
    const defaults: Config = .{};
    try std.testing.expectEqual(@as(u32, 0), defaults.ac.dimSeconds());
    try std.testing.expectEqual(@as(u8, 0), defaults.automatic_saver);
    try std.testing.expectEqual(@as(u32, 270), (Timeouts{ .dim = true, .screen_off_seconds = 300 }).dimSeconds());
    try std.testing.expectEqual(@as(u32, 2), (Timeouts{ .dim = true, .screen_off_seconds = 4 }).dimSeconds());
    try std.testing.expectError(error.ScreenOffAfterSuspend, (Config{ .ac = .{ .lock_seconds = 10, .suspend_seconds = 20, .screen_off_seconds = 30 } }).validate());
    try std.testing.expectError(error.InvalidPowerSaverThreshold, (Config{ .automatic_saver = 21 }).validate());
}
