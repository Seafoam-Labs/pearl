//! Logical-coordinate placement and one reservation owner per output edge.
const std = @import("std");
pub const Edge = enum { top, right, bottom, left };
pub const Rect = struct { x: i32, y: i32, width: i32, height: i32 };
pub const Reservation = struct {
    bar_edge: Edge = .top,
    bar_size: u16 = 48,
    frames: [4]u16 = .{ 0, 0, 0, 0 },
    pub fn bar(self: *Reservation, edge: Edge, size: u16) !void {
        if (size < 32 or size > 160) return error.InvalidSize;
        if (self.frames[@intFromEnum(edge)] != 0) return error.EdgeOccupied;
        self.bar_edge = edge;
        self.bar_size = size;
    }
    pub fn frame(self: *Reservation, edge: Edge, size: u16) !void {
        if (size > 160) return error.InvalidSize;
        if (size != 0 and edge == self.bar_edge) return error.EdgeOccupied;
        self.frames[@intFromEnum(edge)] = size;
    }
};
/// Aqueous geometry is global logical; layer margins are output-local logical.
/// Clamp first, then translate. Scale/rotation are already reflected in bounds.
pub fn popup(bounds: Rect, usable: Rect, width: i32, height: i32) Rect {
    const x0 = @max(@as(i64, bounds.x), usable.x);
    const y0 = @max(@as(i64, bounds.y), usable.y);
    const x1 = @max(x0, @min(@as(i64, bounds.x) + bounds.width, @as(i64, usable.x) + usable.width));
    const y1 = @max(y0, @min(@as(i64, bounds.y) + bounds.height, @as(i64, usable.y) + usable.height));
    const w = @min(@max(width, 1), @max(x1 - x0, 1));
    const h = @min(@max(height, 1), @max(y1 - y0, 1));
    return .{ .x = @intCast(x0 - bounds.x + @divTrunc(x1 - x0 - w, 2)), .y = @intCast(y0 - bounds.y + @divTrunc(y1 - y0 - h, 2)), .width = @intCast(w), .height = @intCast(h) };
}

test "one reservation per edge is preserved through failed changes" {
    var p: Reservation = .{};
    try std.testing.expectError(error.EdgeOccupied, p.frame(.top, 8));
    try p.frame(.left, 8);
    try std.testing.expectError(error.EdgeOccupied, p.bar(.left, 48));
    try std.testing.expectEqual(Edge.top, p.bar_edge);
    try p.bar(.bottom, 64);
    try p.frame(.top, 8);
    try std.testing.expectError(error.InvalidSize, p.bar(.right, 1));
}
test "popup clamps rotated negative-origin logical outputs without rescaling" {
    const r = popup(.{ .x = -720, .y = -80, .width = 720, .height = 1280 }, .{ .x = -712, .y = -32, .width = 704, .height = 1210 }, 440, 280);
    try std.testing.expectEqual(Rect{ .x = 140, .y = 513, .width = 440, .height = 280 }, r);
    const tiny = popup(.{ .x = 100, .y = 50, .width = 120, .height = 90 }, .{ .x = 110, .y = 60, .width = 100, .height = 70 }, 440, 280);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .width = 100, .height = 70 }, tiny);
}

/// Calendar/control popovers follow the occupied bar edge inside usable bounds.
pub fn anchored(bounds: Rect, usable: Rect, width: i32, height: i32, edge: Edge, end: bool) Rect {
    var rect = popup(bounds, usable, width, height);
    const left = @max(0, usable.x - bounds.x);
    const top = @max(0, usable.y - bounds.y);
    const right = @min(bounds.width, usable.x - bounds.x + usable.width) - rect.width;
    const bottom = @min(bounds.height, usable.y - bounds.y + usable.height) - rect.height;
    switch (edge) {
        .top, .bottom => {
            rect.y = if (edge == .top) @min(top + 4, bottom) else @max(top, bottom - 4);
            if (end) rect.x = @max(left, right - 4);
        },
        .left, .right => {
            rect.x = if (edge == .left) @min(left + 4, right) else @max(left, right - 4);
            if (end) rect.y = @max(top, bottom - 4);
        },
    }
    return rect;
}
test "edge-anchored control and calendar remain inside usable bounds" {
    const bounds: Rect = .{ .x = -1280, .y = 0, .width = 1280, .height = 720 };
    const usable: Rect = .{ .x = -1280, .y = 48, .width = 1280, .height = 672 };
    const top = anchored(bounds, usable, 600, 560, .top, true);
    try std.testing.expectEqual(@as(i32, 52), top.y);
    try std.testing.expectEqual(@as(i32, 676), top.x);
    const tiny = anchored(bounds, usable, 600, 800, .bottom, false);
    try std.testing.expectEqual(@as(i32, 48), tiny.y);
    try std.testing.expectEqual(@as(i32, 672), tiny.height);
}
