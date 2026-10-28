//! Opaque source labels: presentation must never change the returned bytes.
const std = @import("std");
pub const limit = 1024 * 1024;
pub const Sources = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList([:0]u8) = .empty,
    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Sources {
        if (bytes.len > limit) return error.SourceListTooLarge;
        if (std.mem.indexOfScalar(u8, bytes, 0) != null or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidSource;
        var result: Sources = .{ .allocator = allocator };
        errdefer result.deinit();
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (result.lines.items.len >= 4096) return error.TooManySources;
            const copy = try allocator.dupeSentinel(u8, line, 0);
            errdefer allocator.free(copy);
            try result.lines.append(allocator, copy);
        }
        return result;
    }
    pub fn deinit(self: *Sources) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
    }
};
test "preserve opaque labels, duplicates, Unicode and final unterminated line" {
    var sources = try Sources.parse(std.testing.allocator, "\n Monitor: DP-1  \nWindow: café <b>x</b>\n Monitor: DP-1  ");
    defer sources.deinit();
    try std.testing.expectEqual(@as(usize, 3), sources.lines.items.len);
    try std.testing.expectEqualStrings(" Monitor: DP-1  ", sources.lines.items[0]);
    try std.testing.expectEqualStrings("Window: café <b>x</b>", sources.lines.items[1]);
    try std.testing.expectEqualStrings(sources.lines.items[0], sources.lines.items[2]);
}
test "empty and invalid bounded input" {
    var empty = try Sources.parse(std.testing.allocator, "\n\n");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.lines.items.len);
    try std.testing.expectError(error.InvalidSource, Sources.parse(std.testing.allocator, "x\x00y"));
    try std.testing.expectError(error.InvalidSource, Sources.parse(std.testing.allocator, "\xff"));
    const large = try std.testing.allocator.alloc(u8, limit + 1);
    defer std.testing.allocator.free(large);
    @memset(large, 'a');
    try std.testing.expectError(error.SourceListTooLarge, Sources.parse(std.testing.allocator, large));
    var boundary = try Sources.parse(std.testing.allocator, large[0..limit]);
    defer boundary.deinit();
    try std.testing.expectEqual(limit, boundary.lines.items[0].len);
}

test "source count is bounded independently of byte count" {
    const bytes = try std.testing.allocator.alloc(u8, 8194);
    defer std.testing.allocator.free(bytes);
    for (bytes, 0..) |*value, i| value.* = if (i % 2 == 0) 'a' else '\n';
    try std.testing.expectError(error.TooManySources, Sources.parse(std.testing.allocator, bytes));
}
