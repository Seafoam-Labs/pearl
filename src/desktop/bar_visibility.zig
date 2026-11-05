//! Pure autohide transitions; timestamps and dimensions are logical milliseconds/pixels.
const std = @import("std");
pub const Mode = enum { always, autohide };
pub const Reason = enum { always, inhibited, saver, pointer, interaction, delay, hidden };
pub const hide_delay_ms = 450;
pub const State = struct {
    mode: Mode = .always,
    inhibited: bool = true,
    /// Screensaver active: the bar yields in every mode so the saver covers it.
    saver: bool = false,
    bar_pointer: bool = false,
    sensor_pointer: bool = false,
    popup: bool = false,
    gesture: bool = false,
    visible: bool = false,
    deadline: ?i64 = null,
    reason: Reason = .hidden,

    pub fn resetPointer(self: *State) void {
        self.bar_pointer = false;
        self.sensor_pointer = false;
        self.gesture = false;
        self.deadline = null;
        self.visible = false;
    }
    pub fn update(self: *State, now: i64) void {
        self.reason = blk: {
            if (self.saver) break :blk .saver;
            if (self.mode == .always) break :blk .always;
            if (self.inhibited) {
                self.resetPointer();
                self.popup = false;
                break :blk .inhibited;
            }
            if (self.popup or self.gesture) break :blk .interaction;
            if (self.bar_pointer or self.sensor_pointer) break :blk .pointer;
            if (self.visible) {
                if (self.deadline == null) self.deadline = now + hide_delay_ms;
                if (now < self.deadline.?) break :blk .delay;
            }
            break :blk .hidden;
        };
        self.visible = switch (self.reason) {
            .always, .pointer, .interaction, .delay => true,
            .hidden, .inhibited, .saver => false,
        };
        if (self.reason != .delay) self.deadline = null;
    }
    pub fn sensor(self: State) bool {
        return self.mode == .autohide and !self.inhibited and !self.saver;
    }
    pub fn exclusiveZone(self: State, thickness: i32) i32 {
        return if (self.mode == .always) thickness else -1;
    }
};

test "screensaver hides the bar in every mode and restores it afterwards" {
    const t = std.testing;
    var s: State = .{ .mode = .always, .inhibited = false };
    s.update(0);
    try t.expect(s.visible);
    s.saver = true;
    s.update(10);
    try t.expect(!s.visible and s.reason == .saver and !s.sensor());
    s.mode = .autohide;
    s.update(20);
    try t.expect(!s.visible);
    s.saver = false;
    s.update(30);
    try t.expect(!s.visible and s.sensor());
    s.mode = .always;
    s.update(40);
    try t.expect(s.visible);
}

test "autohide starts hidden and independent pointer events cancel stale deadlines" {
    const t = std.testing;
    var s: State = .{ .mode = .autohide, .inhibited = false };
    s.update(0);
    try t.expect(!s.visible and s.sensor());
    s.sensor_pointer = true;
    s.update(10);
    try t.expect(s.visible);
    s.bar_pointer = true;
    s.sensor_pointer = false;
    s.update(20);
    try t.expectEqual(Reason.pointer, s.reason);
    s.bar_pointer = false;
    s.update(30);
    s.update(479);
    try t.expect(s.visible);
    s.sensor_pointer = true;
    s.update(480);
    try t.expect(s.visible and s.deadline == null);
    s.sensor_pointer = false;
    s.update(500);
    s.update(950);
    try t.expect(!s.visible);
    try t.expectEqual(@as(i32, -1), s.exclusiveZone(64));
}

test "popup and gesture holds compose and inhibition overrides deadlines and holds" {
    const t = std.testing;
    var s: State = .{ .mode = .autohide, .inhibited = false, .popup = true, .gesture = true };
    s.update(0);
    s.popup = false;
    s.update(1000);
    try t.expectEqual(Reason.interaction, s.reason);
    s.gesture = false;
    s.update(2000);
    try t.expectEqual(@as(?i64, 2450), s.deadline);
    s.inhibited = true;
    s.popup = true;
    s.update(2100);
    try t.expect(!s.visible and !s.sensor() and !s.popup and s.deadline == null);
    s.inhibited = false;
    s.update(2500);
    try t.expect(!s.visible);
    s.mode = .always;
    s.update(3000);
    try t.expect(s.visible and !s.sensor());
    try t.expectEqual(@as(i32, 64), s.exclusiveZone(64));
}
