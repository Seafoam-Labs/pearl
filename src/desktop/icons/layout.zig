const std = @import("std");
pub const Position = struct { column: u32 = 0, row: u32 = 0 };
pub const Grid = struct {
    columns: usize,
    min_rows: usize = 1,
    cell_width: i32,
    cell_height: i32,
    pub fn init(width: i32, size: u16, font: u8) Grid {
        const cw = @max(@as(i32, size) + 40, @as(i32, font) * 8);
        return .{ .columns = @intCast(@max(1, @divTrunc(width, cw))), .cell_width = cw, .cell_height = @as(i32, size) + @as(i32, font) * 3 + 24 };
    }
    pub fn position(self: Grid, index: usize) Position {
        return .{ .column = @intCast(index % self.columns), .row = @intCast(index / self.columns) };
    }
    pub fn slot(self: Grid, pos: Position) usize {
        return @as(usize, @min(pos.row, 10000)) * self.columns + @min(pos.column, self.columns - 1);
    }
    pub fn hit(self: Grid, x: f64, y: f64) usize {
        return @as(usize, @intFromFloat(@max(0, y) / @as(f64, @floatFromInt(self.cell_height)))) * self.columns + @min(self.columns - 1, @as(usize, @intFromFloat(@max(0, x) / @as(f64, @floatFromInt(self.cell_width)))));
    }
};
/// Bound overflow to the rows needed for content. Preferred coordinates remain
/// in state, so temporary small outputs cannot destroy the original layout.
pub fn arrange(a: std.mem.Allocator, grid: Grid, preferred: []const ?Position) ![]usize {
    const slots = try a.alloc(usize, preferred.len);
    errdefer a.free(slots);
    const capacity = @max(grid.min_rows, std.math.divCeil(usize, preferred.len, grid.columns) catch 1) * grid.columns;
    const occupied = try a.alloc(bool, capacity);
    defer a.free(occupied);
    @memset(occupied, false);
    @memset(slots, std.math.maxInt(usize));
    for (preferred, 0..) |p, i| if (p) |pos| {
        const slot = @min(grid.slot(pos), capacity - 1);
        if (!occupied[slot]) {
            occupied[slot] = true;
            slots[i] = slot;
        }
    };
    var next: usize = 0;
    for (slots) |*slot| if (slot.* == std.math.maxInt(usize)) {
        while (occupied[next]) next += 1;
        slot.* = next;
        occupied[next] = true;
    };
    return slots;
}
test "small displays collision recovery leaves preferred positions intact" {
    const g = Grid.init(100, 48, 14);
    const p = [_]?Position{ .{ .column = 4, .row = 0 }, .{ .column = 0, .row = 0 }, null };
    const result = try arrange(std.testing.allocator, g, &p);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, result);
    try std.testing.expectEqual(@as(u32, 4), p[0].?.column);
}
