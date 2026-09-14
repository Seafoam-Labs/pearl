//! Pure lock/suspend gate. Request acceptance never means the screen is locked.
const std = @import("std");
pub const Timeouts = struct { lock_seconds: u32 = 0, suspend_seconds: u32 = 0 };
pub const Config = struct {
    ac: Timeouts = .{},
    battery: Timeouts = .{},
    pub fn validate(self: Config) !void {
        for ([_]Timeouts{ self.ac, self.battery }) |p| {
            if (p.lock_seconds > 86400 or p.suspend_seconds > 86400) return error.InvalidIdleTimeout;
            if (p.suspend_seconds > 0 and (p.lock_seconds == 0 or p.suspend_seconds <= p.lock_seconds)) return error.LockBeforeSuspendRequired;
        }
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
