//! Compare only complete audio snapshots. Copies survive replacement of service storage.
const std = @import("std");
const policy = @import("policy.zig");
pub const Volume = struct {
    key: policy.Key,
    name: policy.Text(256) = .{},
    label: policy.Text(256) = .{},
    percent: u8,
    muted: bool,

    pub fn from(device: anytype) Volume {
        return .{ .key = device.key, .name = device.name, .label = device.label, .percent = device.volume, .muted = device.mute };
    }
    pub fn sameDevice(self: *const Volume, other: *const Volume) bool {
        return std.meta.eql(self.key, other.key) and std.mem.eql(u8, self.name.slice(), other.name.slice());
    }
};
pub const Change = enum { unchanged, reset, volume };
pub const Observer = struct {
    baseline: ?Volume = null,
    pub fn observe(self: *Observer, current: ?Volume) Change {
        const previous = self.baseline;
        self.baseline = current;
        const next = current orelse return if (previous != null) .reset else .unchanged;
        const old = previous orelse return .reset;
        if (!old.sameDevice(&next)) return .reset;
        return if (old.percent != next.percent or old.muted != next.muted) .volume else .unchanged;
    }
};

test "complete snapshots suppress startup, repeats, and identity changes" {
    var observer: Observer = .{};
    var v: Volume = .{ .key = .{ .generation = 1, .kind = .sink, .index = 2 }, .percent = 50, .muted = false };
    v.name.set("speakers");
    try std.testing.expectEqual(Change.reset, observer.observe(v));
    try std.testing.expectEqual(Change.unchanged, observer.observe(v));
    v.percent = 0;
    try std.testing.expectEqual(Change.volume, observer.observe(v));
    v.muted = true;
    try std.testing.expectEqual(Change.volume, observer.observe(v));
    v.label.set("Renamed speakers");
    try std.testing.expectEqual(Change.unchanged, observer.observe(v));
    v.name.set("replacement");
    try std.testing.expectEqual(Change.reset, observer.observe(v));
    v.key.index += 1;
    try std.testing.expectEqual(Change.reset, observer.observe(v));
    v.key.generation += 1;
    try std.testing.expectEqual(Change.reset, observer.observe(v));
    try std.testing.expectEqual(Change.reset, observer.observe(null));
    try std.testing.expectEqual(Change.unchanged, observer.observe(null));
    try std.testing.expectEqual(Change.reset, observer.observe(v));
}

test "suppressed observations advance baseline without replay" {
    var observer: Observer = .{};
    var v: Volume = .{ .key = .{ .generation = 1, .kind = .sink, .index = 2 }, .percent = 10, .muted = false };
    _ = observer.observe(v);
    v.percent = 80;
    // A locked consumer discards this event but the baseline still advances.
    _ = observer.observe(v);
    try std.testing.expectEqual(Change.unchanged, observer.observe(v));
    v.muted = true;
    try std.testing.expectEqual(Change.volume, observer.observe(v));
    v.muted = false;
    try std.testing.expectEqual(Change.volume, observer.observe(v));
}
