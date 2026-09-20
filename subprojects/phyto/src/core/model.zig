const std = @import("std");

pub fn validName(name: []const u8) bool {
    return name.len > 0 and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and std.mem.indexOfAny(u8, name, "/\x00") == null;
}

pub const History = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([:0]u8) = .empty,
    cursor: usize = 0,
    pub fn deinit(self: *History) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit(self.allocator);
    }
    pub fn visit(self: *History, uri: []const u8) !void {
        if (self.items.items.len > 0 and std.mem.eql(u8, self.items.items[self.cursor], uri)) return;
        const owned = try self.allocator.dupeZ(u8, uri);
        errdefer self.allocator.free(owned);
        try self.items.ensureUnusedCapacity(self.allocator, 1);
        const keep = if (self.items.items.len == 0) 0 else self.cursor + 1;
        for (self.items.items[keep..]) |item| self.allocator.free(item);
        self.items.shrinkRetainingCapacity(keep);
        if (self.items.items.len == 64) self.allocator.free(self.items.orderedRemove(0));
        self.items.appendAssumeCapacity(owned);
        self.cursor = self.items.items.len - 1;
    }
    pub fn back(self: *History) ?[:0]const u8 {
        if (self.cursor == 0) return null;
        self.cursor -= 1;
        return self.items.items[self.cursor];
    }
    pub fn forward(self: *History) ?[:0]const u8 {
        if (self.cursor + 1 >= self.items.items.len) return null;
        self.cursor += 1;
        return self.items.items[self.cursor];
    }
};

test "navigation branches after back, preserves failed-navigation history policy, and bounds memory" {
    var h = History{ .allocator = std.testing.allocator };
    defer h.deinit();
    try h.visit("file:///a");
    try h.visit("file:///b");
    try h.visit("file:///c");
    try std.testing.expectEqualStrings("file:///b", h.back().?);
    try h.visit("file:///d");
    try std.testing.expect(h.forward() == null);
    try std.testing.expectEqualStrings("file:///b", h.back().?);
    try std.testing.expectEqualStrings("file:///d", h.forward().?);
    for (0..100) |n| {
        const s = try std.fmt.allocPrint(std.testing.allocator, "file:///{d}", .{n});
        defer std.testing.allocator.free(s);
        try h.visit(s);
    }
    try std.testing.expectEqual(@as(usize, 64), h.items.items.len);
}

test "new names cannot address another directory" {
    for ([_][]const u8{ "", ".", "..", "a/b", "x\x00y" }) |name| try std.testing.expect(!validName(name));
    for ([_][]const u8{ "notes.txt", ".hidden", "日本語", "a b", "quote'$(literal)" }) |name| try std.testing.expect(validName(name));
}
