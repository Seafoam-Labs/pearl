//! Bounded, service-independent power telemetry and automatic profile policy.
const std = @import("std");
pub const Point = struct { seconds: i64, percent: f64 };
pub const History = struct {
    points: [361]Point = undefined,
    len: usize = 0,
    pub fn add(self: *History, seconds: i64, percent: ?f64) void {
        if (self.len > 0 and seconds < self.points[self.len - 1].seconds) self.len = 0;
        while (self.len > 0 and seconds - self.points[0].seconds > 21600) {
            std.mem.copyForwards(Point, self.points[0 .. self.len - 1], self.points[1..self.len]);
            self.len -= 1;
        }
        const value = validPercent(percent) orelse return;
        if (self.len > 0) {
            const last = &self.points[self.len - 1];
            if (seconds < last.seconds) {
                self.len = 0;
            } else if (@divFloor(seconds, 60) == @divFloor(last.seconds, 60)) {
                last.percent = value;
                last.seconds = seconds;
                return;
            }
        }
        if (self.len == self.points.len) {
            std.mem.copyForwards(Point, self.points[0 .. self.len - 1], self.points[1..self.len]);
            self.len -= 1;
        }
        self.points[self.len] = .{ .seconds = seconds, .percent = value };
        self.len += 1;
    }
};
pub fn validPercent(value: ?f64) ?f64 {
    const n = value orelse return null;
    return if (std.math.isFinite(n) and n >= 0 and n <= 100) n else null;
}

/// UPower's `UP_DEVICE_STATE_*` values.
pub const Charge = enum {
    unknown,
    charging,
    discharging,
    empty,
    full,
    /// Plugged in but not charging: what charge-threshold firmware reports on AC.
    pending_charge,
    pending_discharge,
    pub fn of(state: u32) Charge {
        return switch (state) {
            1 => .charging,
            2 => .discharging,
            3 => .empty,
            4 => .full,
            5 => .pending_charge,
            6 => .pending_discharge,
            else => .unknown,
        };
    }
    /// Power is flowing in, whether or not the cell is accepting charge yet.
    pub fn plugged(self: Charge) bool {
        return switch (self) {
            .charging, .full, .pending_charge => true,
            else => false,
        };
    }
};

/// The unknown state keeps the generic battery glyph rather than an invented
/// charge level, so an unavailable reading is visibly not a measured one.
pub fn icon(state: u32, percent: ?f64) [:0]const u8 {
    switch (Charge.of(state)) {
        .charging, .pending_charge => return "pearl-battery-charging-symbolic",
        .full => return "pearl-battery-full-symbolic",
        .empty => return "pearl-battery-empty-symbolic",
        else => {},
    }
    const n = validPercent(percent) orelse return "pearl-battery-symbolic";
    if (n < 8) return "pearl-battery-empty-symbolic";
    if (n < 30) return "pearl-battery-quarter-symbolic";
    if (n < 55) return "pearl-battery-half-symbolic";
    if (n < 85) return "pearl-battery-three-quarters-symbolic";
    return "pearl-battery-full-symbolic";
}

/// One warning per level per discharging episode. Escalation warns again;
/// dithering across a threshold does not, and recovery past the exit margin
/// ends the episode so a later genuine drop is announced afresh.
pub const Alarm = struct {
    pub const Level = enum { low, very_low, critical };
    pub const low_percent: f64 = 20;
    pub const very_low_percent: f64 = 10;
    pub const critical_percent: f64 = 5;
    pub const margin: f64 = 2;

    episode: bool = false,
    seen: Level = .low,
    pending: ?Level = null,

    pub fn levelOf(percent: f64) ?Level {
        if (percent < critical_percent) return .critical;
        if (percent < very_low_percent) return .very_low;
        if (percent < low_percent) return .low;
        return null;
    }
    pub fn update(self: *Alarm, discharging: bool, percent: ?f64) void {
        // Not discharging, or no measured reading: the episode is over.
        const n = (if (discharging) validPercent(percent) else null) orelse {
            self.reset();
            return;
        };
        if (!self.episode) {
            const crossed = levelOf(n) orelse return;
            self.episode = true;
            self.seen = crossed;
            self.pending = crossed;
            return;
        }
        if (n >= low_percent + margin) {
            self.reset();
            return;
        }
        const crossed = levelOf(n) orelse return;
        if (@intFromEnum(crossed) <= @intFromEnum(self.seen)) return;
        self.seen = crossed;
        self.pending = crossed;
    }
    pub fn reset(self: *Alarm) void {
        self.* = .{};
    }
    pub fn take(self: *Alarm) ?Level {
        defer self.pending = null;
        return self.pending;
    }
};
pub const Snapshot = struct {
    available: bool = false,
    battery_present: bool = false,
    percentage: ?f64 = null,
    state: u32 = 0,
    estimate: i64 = 0,
    health: ?f64 = null,
    history: []const Point = &.{},
    on_battery: bool = false,
    profile: []const u8 = "",
    profiles: [3]bool = @splat(false),
    profile_generation: []const u8 = "0",
    profile_pending: bool = false,
    degraded: []const u8 = "",
    brightness: u8 = 0,
    brightness_available: bool = false,
    brightness_pending: bool = false,
    brightness_generation: []const u8 = "0",
    display_power_available: bool = false,
    idle_available: bool = false,
    config: @import("idle_policy.zig").Config = .{},
    revision: []const u8 = "0",
    saving: bool = false,
    error_message: []const u8 = "",
};

pub const Saver = struct {
    episode: bool = false,
    suppressed: bool = false,
    previous: ?u8 = null,
    owned: bool = false,
    awaiting: bool = false,
    pub fn manual(self: *Saver) void {
        if (self.episode) self.suppressed = true;
        self.owned = false;
        self.awaiting = false;
        self.previous = null;
    }
    pub fn failed(self: *Saver) void {
        self.manual();
    }
    pub fn update(self: *Saver, threshold: u8, battery: bool, discharging: bool, percent: ?f64, current: ?u8, supported: [3]bool, pending: bool) ?u8 {
        const n = validPercent(percent);
        const low = threshold > 0 and battery and discharging and n != null and n.? < @as(f64, @floatFromInt(threshold));
        const recovered = threshold == 0 or !battery or !discharging or (n != null and n.? >= @as(f64, @floatFromInt(@as(u16, threshold) + 5)));
        if (recovered) {
            if (pending) return null;
            const restore = if (self.owned and current == 0) self.previous else null;
            self.* = .{};
            if (restore) |index| if (supported[index]) return index;
            return null;
        }
        if (self.awaiting and current == 0) {
            self.awaiting = false;
            self.owned = true;
        }
        if (self.owned and !pending and current != 0) self.manual();
        if (low and !self.episode) self.episode = true;
        if (!low or self.suppressed or self.owned or self.awaiting or pending or !supported[0] or current == null or current == 0) return null;
        self.previous = current;
        self.awaiting = true;
        return 0;
    }
};

test "presence does not depend on a valid percentage and history stays bounded" {
    try std.testing.expectEqual(@as(?f64, 0), validPercent(0));
    try std.testing.expect(validPercent(std.math.nan(f64)) == null);
    var h: History = .{};
    for (0..1000) |i| h.add(@intCast(i * 60), 73);
    try std.testing.expectEqual(@as(usize, 361), h.len);
    try std.testing.expectEqual(@as(f64, 73), h.points[h.len - 1].percent);
    h.add(0, 20);
    try std.testing.expectEqual(@as(usize, 1), h.len);
    h.add(21601, null);
    try std.testing.expectEqual(@as(usize, 0), h.len);
}
test "automatic saver restores only owned changes and honors overrides" {
    var s: Saver = .{};
    const modes = [3]bool{ true, true, true };
    try std.testing.expectEqual(@as(?u8, 0), s.update(20, true, true, 19, 1, modes, false));
    _ = s.update(20, true, true, 19, 0, modes, false);
    try std.testing.expect(s.update(20, true, true, 22, 0, modes, false) == null);
    try std.testing.expectEqual(@as(?u8, 1), s.update(20, false, false, null, 0, modes, false));
    _ = s.update(20, true, true, 19, 2, modes, false);
    s.manual();
    try std.testing.expect(s.update(20, true, true, 18, 2, modes, false) == null);
    _ = s.update(20, true, false, 18, 2, modes, false);
    try std.testing.expectEqual(@as(?u8, 0), s.update(20, true, true, 18, 2, modes, false));
    s.failed();
    try std.testing.expect(s.update(20, true, true, 18, 2, modes, false) == null);
}
/// Every glyph the policy can select, all registered in pearl.gresource.xml.
/// An unregistered name renders as a broken image rather than an error, so a
/// rename here must be matched in the manifest.
const shipped_icons = [_][:0]const u8{
    "pearl-battery-symbolic",
    "pearl-battery-empty-symbolic",
    "pearl-battery-quarter-symbolic",
    "pearl-battery-half-symbolic",
    "pearl-battery-three-quarters-symbolic",
    "pearl-battery-full-symbolic",
    "pearl-battery-charging-symbolic",
};

test "every battery icon the policy selects is a shipped, reachable glyph" {
    var reachable = [_]bool{false} ** shipped_icons.len;
    // Sweep states past the documented UPower range and the whole percent grid.
    var state: u32 = 0;
    while (state <= 8) : (state += 1) {
        var percent: f64 = -1;
        while (percent <= 101) : (percent += 1) {
            const optional = if (percent < 0 or percent > 100) null else percent;
            const symbol = icon(state, optional);
            const index = for (shipped_icons, 0..) |name, i| {
                if (std.mem.eql(u8, name, symbol)) break i;
            } else {
                std.debug.print("unregistered battery icon: {s}\n", .{symbol});
                return error.TestUnexpectedResult;
            };
            reachable[index] = true;
        }
    }
    // A glyph no state can select means the policy or the asset set drifted.
    for (shipped_icons, 0..) |name, i| {
        try std.testing.expect(reachable[i]);
        _ = name;
    }
}

test "charge state covers pending-charge firmware and unknown readings" {
    try std.testing.expectEqual(Charge.charging, Charge.of(1));
    try std.testing.expectEqual(Charge.discharging, Charge.of(2));
    try std.testing.expectEqual(Charge.pending_charge, Charge.of(5));
    try std.testing.expectEqual(Charge.unknown, Charge.of(0));
    try std.testing.expectEqual(Charge.unknown, Charge.of(99));
    // Plugged in but held below a charge threshold is still on AC.
    try std.testing.expect(Charge.of(5).plugged());
    try std.testing.expect(Charge.of(4).plugged());
    try std.testing.expect(!Charge.of(2).plugged());
    try std.testing.expect(!Charge.of(6).plugged());
    try std.testing.expect(!Charge.of(0).plugged());
}
test "battery icon reflects charge state before level and never invents a level" {
    try std.testing.expectEqualStrings("pearl-battery-charging-symbolic", icon(1, 42));
    try std.testing.expectEqualStrings("pearl-battery-charging-symbolic", icon(5, 80));
    try std.testing.expectEqualStrings("pearl-battery-full-symbolic", icon(4, 80));
    try std.testing.expectEqualStrings("pearl-battery-empty-symbolic", icon(3, null));
    try std.testing.expectEqualStrings("pearl-battery-symbolic", icon(0, null));
    try std.testing.expectEqualStrings("pearl-battery-symbolic", icon(2, null));
    try std.testing.expectEqualStrings("pearl-battery-empty-symbolic", icon(2, 4));
    try std.testing.expectEqualStrings("pearl-battery-quarter-symbolic", icon(2, 20));
    try std.testing.expectEqualStrings("pearl-battery-half-symbolic", icon(2, 50));
    try std.testing.expectEqualStrings("pearl-battery-three-quarters-symbolic", icon(2, 70));
    try std.testing.expectEqualStrings("pearl-battery-full-symbolic", icon(2, 95));
    // A valid 0% is a measurement, not an absent one.
    try std.testing.expectEqualStrings("pearl-battery-empty-symbolic", icon(2, 0));
}
test "low battery alarm warns once per level and ends only on real recovery" {
    var alarm: Alarm = .{};
    // Healthy charge: nothing pending, no episode.
    alarm.update(true, 80);
    try std.testing.expectEqual(@as(?Alarm.Level, null), alarm.take());
    try std.testing.expect(!alarm.episode);
    // Crossing 20% warns once.
    alarm.update(true, 19);
    try std.testing.expectEqual(@as(?Alarm.Level, .low), alarm.take());
    alarm.update(true, 18);
    try std.testing.expectEqual(@as(?Alarm.Level, null), alarm.take());
    // Dithering across the threshold does not end the episode or re-warn.
    alarm.update(true, 21);
    alarm.update(true, 19);
    try std.testing.expectEqual(@as(?Alarm.Level, null), alarm.take());
    try std.testing.expect(alarm.episode);
    // Escalation warns again, and only the deeper level.
    alarm.update(true, 9);
    try std.testing.expectEqual(@as(?Alarm.Level, .very_low), alarm.take());
    alarm.update(true, 4);
    try std.testing.expectEqual(@as(?Alarm.Level, .critical), alarm.take());
    alarm.update(true, 3);
    try std.testing.expectEqual(@as(?Alarm.Level, null), alarm.take());
    // Plugging in ends the episode without a warning.
    alarm.update(false, 4);
    try std.testing.expectEqual(@as(?Alarm.Level, null), alarm.take());
    try std.testing.expect(!alarm.episode);
    // Recovery past the exit margin re-arms, so a later drop warns afresh.
    alarm.update(true, 19);
    _ = alarm.take();
    alarm.update(true, 25);
    try std.testing.expect(!alarm.episode);
    alarm.update(true, 19);
    try std.testing.expectEqual(@as(?Alarm.Level, .low), alarm.take());
    // Starting already critical warns the critical level only.
    var fresh: Alarm = .{};
    fresh.update(true, 4);
    try std.testing.expectEqual(@as(?Alarm.Level, .critical), fresh.take());
    // An unmeasured reading never warns and never keeps a stale episode.
    var stale: Alarm = .{};
    stale.update(true, 15);
    _ = stale.take();
    stale.update(true, null);
    try std.testing.expect(!stale.episode);
    try std.testing.expectEqual(@as(?Alarm.Level, null), stale.take());
}
