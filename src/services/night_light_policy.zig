//! Saved policy and transient override; no display or wall-clock dependencies.
const std = @import("std");
pub const Config = struct {
    enabled: bool = false,
    temperature_kelvin: u16 = 4500,
    schedule: enum { manual, custom } = .manual,
    start_minute: u16 = 1200,
    end_minute: u16 = 420,
    pub fn validate(self: Config) !void {
        if (self.temperature_kelvin < 2500 or self.temperature_kelvin > 6500) return error.InvalidNightLightTemperature;
        if (self.start_minute >= 1440 or self.end_minute >= 1440) return error.InvalidNightLightTime;
        if (self.schedule == .custom and self.start_minute == self.end_minute) return error.InvalidNightLightInterval;
    }
    pub fn scheduled(self: Config, minute: u16) bool {
        if (self.schedule == .manual) return true;
        return if (self.start_minute < self.end_minute)
            minute >= self.start_minute and minute < self.end_minute
        else
            minute >= self.start_minute or minute < self.end_minute;
    }
};
pub const Action = enum { on, off, toggle, @"resume", retry };
pub const Override = struct { enabled: bool, expires: ?i64 };
pub const OutputStatus = struct {
    connector: []const u8,
    available: bool = false,
    reason: []const u8 = "OutputColorEligibilityUnavailable",
    state: []const u8 = "unavailable",
    committed_kelvin: u32 = 0,
};
pub const Snapshot = struct {
    generation: []const u8 = "0",
    state: enum { off, scheduled, unavailable, pending, active, partial, restoring, failed } = .unavailable,
    available: bool = false,
    requested: bool = false,
    temperature_kelvin: u16 = 4500,
    override: ?Override = null,
    gamma_protocol: bool = false,
    reason: []const u8 = "OutputColorEligibilityUnavailable",
    outputs: []const OutputStatus = &.{},
};
pub const Policy = struct {
    config: Config = .{},
    override: ?Override = null,
    pub fn configure(self: *Policy, config: Config) void {
        if (!std.meta.eql(self.config, config)) self.override = null;
        self.config = config;
    }
    pub fn expire(self: *Policy, now: i64) void {
        if (self.override) |v| if (v.expires) |deadline| if (now >= deadline) {
            self.override = null;
        };
    }
    pub fn desired(self: *Policy, now: i64, minute: u16) bool {
        self.expire(now);
        if (self.override) |v| return v.enabled;
        return self.config.enabled and self.config.scheduled(minute);
    }
    pub fn clockChanged(self: *Policy, now: i64, next_boundary: ?i64) void {
        self.expire(now);
        if (self.override) |*v| if (v.expires) |deadline| if (next_boundary) |next| {
            // A clock/zone change may shorten, never extend a temporary override.
            v.expires = @min(deadline, next);
        };
    }
    pub fn act(self: *Policy, action: Action, now: i64, minute: u16, next_boundary: ?i64) void {
        const current = self.desired(now, minute);
        switch (action) {
            .on, .off, .toggle => self.override = .{ .enabled = if (action == .toggle) !current else action == .on, .expires = if (self.config.schedule == .custom) next_boundary else null },
            .@"resume" => self.override = null,
            .retry => {},
        }
    }
};

test "night light defaults and strict ranges" {
    try (Config{}).validate();
    try std.testing.expect(!(Config{}).enabled);
    try std.testing.expectError(error.InvalidNightLightTemperature, (Config{ .temperature_kelvin = 2499 }).validate());
    try std.testing.expectError(error.InvalidNightLightTemperature, (Config{ .temperature_kelvin = 6501 }).validate());
    try std.testing.expectError(error.InvalidNightLightTime, (Config{ .end_minute = 1440 }).validate());
    try std.testing.expectError(error.InvalidNightLightInterval, (Config{ .schedule = .custom, .start_minute = 60, .end_minute = 60 }).validate());
}
test "night light civil intervals cross midnight and exclude end" {
    const c: Config = .{ .schedule = .custom };
    for ([_]u16{ 0, 419, 1200, 1439 }) |minute| try std.testing.expect(c.scheduled(minute));
    for ([_]u16{ 420, 800, 1199 }) |minute| try std.testing.expect(!c.scheduled(minute));
    const day: Config = .{ .schedule = .custom, .start_minute = 60, .end_minute = 180 };
    try std.testing.expect(day.scheduled(60));
    try std.testing.expect(!day.scheduled(180));
    // A skipped hour or repeated local hour simply reevaluates civil membership.
    try std.testing.expect(!day.scheduled(181));
    try std.testing.expect(day.scheduled(90));
}
test "night light overrides expire across sleep and cannot resurrect after clock rollback" {
    var p: Policy = .{ .config = .{ .enabled = true, .schedule = .custom } };
    p.act(.off, 100, 1300, 200);
    try std.testing.expect(!p.desired(150, 1300));
    try std.testing.expect(p.desired(300, 1300));
    try std.testing.expect(p.override == null);
    try std.testing.expect(p.desired(100, 1300));
    p.act(.toggle, 100, 800, 200);
    try std.testing.expect(p.desired(150, 800));
    p.act(.@"resume", 150, 800, 200);
    try std.testing.expect(!p.desired(150, 800));
}
test "unchanged configuration preserves override; changed configuration clears it" {
    var p: Policy = .{};
    p.act(.on, 100, 800, null);
    p.configure(.{});
    try std.testing.expect(p.desired(999999, 800));
    p.configure(.{ .temperature_kelvin = 5000 });
    try std.testing.expect(p.override == null);
    try std.testing.expect(!p.desired(999999, 800));
}
test "timezone changes shorten an override without extending or resurrecting it" {
    var p: Policy = .{ .config = .{ .schedule = .custom } };
    p.act(.off, 100, 800, 400);
    p.clockChanged(110, 200);
    try std.testing.expectEqual(@as(?i64, 200), p.override.?.expires);
    p.clockChanged(90, 500);
    try std.testing.expectEqual(@as(?i64, 200), p.override.?.expires);
    p.clockChanged(250, 500);
    p.clockChanged(100, 500);
    try std.testing.expect(p.override == null);
}
