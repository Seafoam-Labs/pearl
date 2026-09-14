//! Bounded, volatile passive status text. Never contains submitted responses.
const std = @import("std");
const protocol = @import("protocol.zig");
pub const History = struct {
    messages: [4][16384:0]u8 = @splat(@splat(0)),
    lengths: [4]usize = @splat(0),
    count: usize = 0,
    next: usize = 0,
    pub fn clear(self: *History) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }
    pub fn latest(self: *const History) ?[:0]const u8 {
        if (self.count == 0) return null;
        const i = (self.next + 3) % 4;
        return self.messages[i][0..self.lengths[i] :0];
    }
    pub fn append(self: *History, text: []const u8) !void {
        if (!protocol.validText(text, 16384)) return error.InvalidStatus;
        if (self.latest()) |last| if (std.mem.eql(u8, text, last)) return;
        std.crypto.secureZero(u8, &self.messages[self.next]);
        @memcpy(self.messages[self.next][0..text.len], text);
        self.lengths[self.next] = text.len;
        self.next = (self.next + 1) % 4;
        self.count = @min(self.count + 1, 4);
    }
};
test "status history owns bounded UTF8 text, coalesces duplicates and clears" {
    var h: History = .{};
    try h.append("Touch the reader");
    try h.append("Touch the reader");
    try std.testing.expectEqual(@as(usize, 1), h.count);
    for (0..10) |i| {
        var text = [_]u8{@intCast('a' + i)};
        try h.append(&text);
    }
    try std.testing.expectEqual(@as(usize, 4), h.count);
    try std.testing.expectEqualStrings("j", h.latest().?);
    try std.testing.expectError(error.InvalidStatus, h.append("\xff"));
    try std.testing.expectError(error.InvalidStatus, h.append(&(@as([16385]u8, @splat('a')))));
    try h.append(&(@as([16384]u8, @splat('a'))));
    h.clear();
    try std.testing.expect(h.latest() == null);
    for (std.mem.asBytes(&h)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
