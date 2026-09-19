//! Presentation only: neighbors are positions in the output's sorted list.
const std = @import("std");
pub const Mode = enum {
    small,
    medium,
    large,

    pub fn label(self: Mode) [:0]const u8 {
        return switch (self) {
            .small => "Small",
            .medium => "Medium",
            .large => "Large",
        };
    }
    pub fn description(self: Mode) [:0]const u8 {
        return switch (self) {
            .small => "Active + 1 on each side",
            .medium => "Active + 2 on each side",
            .large => "All workspaces",
        };
    }
};
pub const Range = struct { start: usize, end: usize };
pub fn visibleRange(count: usize, active_index: ?usize, mode: Mode) Range {
    const all: Range = .{ .start = 0, .end = count };
    const index = active_index orelse return all;
    if (index >= count or mode == .large) return all;
    const radius: usize = if (mode == .small) 1 else 2;
    return .{ .start = index -| radius, .end = index + @min(count - index, radius + 1) };
}

test "workspace ranges clip boundaries and tolerate unknown active state" {
    const expect = std.testing.expectEqualDeep;
    try expect(Range{ .start = 3, .end = 6 }, visibleRange(9, 4, .small));
    try expect(Range{ .start = 2, .end = 7 }, visibleRange(9, 4, .medium));
    for (std.enums.values(Mode)) |mode| {
        try expect(Range{ .start = 0, .end = 0 }, visibleRange(0, null, mode));
        try expect(Range{ .start = 0, .end = 0 }, visibleRange(0, 0, mode));
        try expect(Range{ .start = 0, .end = 1 }, visibleRange(1, 0, mode));
        try expect(Range{ .start = 0, .end = 2 }, visibleRange(2, 0, mode));
        try expect(Range{ .start = 0, .end = 2 }, visibleRange(2, 1, mode));
        try expect(Range{ .start = 0, .end = 9 }, visibleRange(9, null, mode));
        try expect(Range{ .start = 0, .end = 9 }, visibleRange(9, 9, mode));
    }
    try expect(Range{ .start = 0, .end = 2 }, visibleRange(9, 0, .small));
    try expect(Range{ .start = 0, .end = 3 }, visibleRange(9, 0, .medium));
    try expect(Range{ .start = 7, .end = 9 }, visibleRange(9, 8, .small));
    try expect(Range{ .start = 6, .end = 9 }, visibleRange(9, 8, .medium));
    try expect(Range{ .start = 0, .end = 9 }, visibleRange(9, 4, .large));
    const max = std.math.maxInt(usize);
    try expect(Range{ .start = max - 3, .end = max }, visibleRange(max, max - 1, .medium));
    // Sparse numbers are still adjacent positions; never synthesize numbers.
    const numbers = [_]u32{ 1, 3, 7, 9 };
    const range = visibleRange(numbers.len, 2, .small);
    try std.testing.expectEqualSlices(u32, &.{ 3, 7, 9 }, numbers[range.start..range.end]);
}
