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
