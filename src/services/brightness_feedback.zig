//! Compare only complete brightness snapshots. Copies survive replacement of service storage.
const std = @import("std");
const policy = @import("policy.zig");
pub const Brightness = struct {
    name: policy.Text(128) = .{},
    percent: u8,

    pub fn from(backlight: anytype) Brightness {
        return .{ .name = backlight.name, .percent = backlight.percent() };
    }
    pub fn sameDevice(self: *const Brightness, other: *const Brightness) bool {
        return std.mem.eql(u8, self.name.slice(), other.name.slice());
    }
};
pub const Change = enum { unchanged, reset, brightness };
pub const Observer = struct {
    baseline: ?Brightness = null,
    pub fn observe(self: *Observer, current: ?Brightness) Change {
        const previous = self.baseline;
        self.baseline = current;
        const next = current orelse return if (previous != null) .reset else .unchanged;
        const old = previous orelse return .reset;
        if (!old.sameDevice(&next)) return .reset;
        return if (old.percent != next.percent) .brightness else .unchanged;
    }
};

test "complete snapshots suppress startup, repeats, and identity changes" {
    var observer: Observer = .{};
    var b: Brightness = .{ .percent = 42 };
    b.name.set("amdgpu_bl1");
    try std.testing.expectEqual(Change.reset, observer.observe(b));
    try std.testing.expectEqual(Change.unchanged, observer.observe(b));
    b.percent = 0;
    try std.testing.expectEqual(Change.brightness, observer.observe(b));
    b.percent = 100;
    try std.testing.expectEqual(Change.brightness, observer.observe(b));
    try std.testing.expectEqual(Change.reset, observer.observe(null));
    try std.testing.expectEqual(Change.unchanged, observer.observe(null));
    try std.testing.expectEqual(Change.reset, observer.observe(b));
    b.name.set("amdgpu_bl0");
    try std.testing.expectEqual(Change.reset, observer.observe(b));
}

test "suppressed observations advance baseline without replay" {
    var observer: Observer = .{};
    var b: Brightness = .{ .percent = 10 };
    b.name.set("amdgpu_bl1");
    _ = observer.observe(b);
    b.percent = 80;
    // A locked consumer discards this event but the baseline still advances.
    _ = observer.observe(b);
    try std.testing.expectEqual(Change.unchanged, observer.observe(b));
    b.percent = 79;
    try std.testing.expectEqual(Change.brightness, observer.observe(b));
}

test "from copies the name and the displayed percent" {
    const Backlight = struct {
        name: policy.Text(128) = .{},
        maximum: u32 = 0,
        value: u32 = 0,
        fn percent(self: @This()) u8 {
            return if (self.maximum == 0) 0 else @intCast(@min(100, (@as(u64, self.value) * 100 + self.maximum / 2) / self.maximum));
        }
    };
    var backlight: Backlight = .{ .maximum = 1000, .value = 550 };
    backlight.name.set("test_panel");
    const b = Brightness.from(backlight);
    try std.testing.expectEqualStrings("test_panel", b.name.slice());
    try std.testing.expectEqual(@as(u8, 55), b.percent);
}
