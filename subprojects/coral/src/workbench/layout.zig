//! Bounded machine-owned presentation state. Workspace settings cannot set this.
//! Store desired sizes, not transient GTK allocations in a compact window.
const std = @import("std");
pub const Dock = enum { left, right, bottom };
pub const Panel = enum { explorer, search };
pub const State = struct {
    explorer: Dock = .left,
    search: Dock = .bottom,
    explorer_visible: bool = true,
    search_visible: bool = false,
    active: Panel = .explorer,
    left_size: u16 = 280,
    right_size: u16 = 320,
    bottom_size: u16 = 240,
};

pub fn normalized(value: State) State {
    var state = value;
    state.left_size = std.math.clamp(state.left_size, 120, 1200);
    state.right_size = std.math.clamp(state.right_size, 120, 1200);
    state.bottom_size = std.math.clamp(state.bottom_size, 100, 1000);
    return state;
}

/// Persisted invalid values are rejected; only interactive sizing is clamped.
pub fn validate(state: State) !void {
    if (!std.meta.eql(state, normalized(state))) return error.InvalidLayout;
}

test "dock defaults and every supported placement are valid" {
    try validate(.{});
    inline for (.{ Dock.left, Dock.right, Dock.bottom }) |side| {
        try validate(.{ .explorer = side, .search = side, .explorer_visible = false, .search_visible = true, .active = .search });
    }
}

test "interactive sizes clamp but stored out-of-range sizes fail closed" {
    const invalid: State = .{ .left_size = 0, .right_size = 65535, .bottom_size = 99 };
    try std.testing.expectError(error.InvalidLayout, validate(invalid));
    const clamped = normalized(invalid);
    try std.testing.expectEqual(@as(u16, 120), clamped.left_size);
    try std.testing.expectEqual(@as(u16, 1200), clamped.right_size);
    try std.testing.expectEqual(@as(u16, 100), clamped.bottom_size);
    try validate(clamped);
    try std.testing.expectEqualDeep(clamped, normalized(clamped));
}
