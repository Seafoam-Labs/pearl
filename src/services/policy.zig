const std = @import("std");
pub fn Text(comptime size: usize) type {
    return struct {
        bytes: [size:0]u8 = @splat(0),
        len: usize = 0,
        pub fn set(self: *@This(), value: []const u8) void {
            self.len = @min(value.len, size);
            while (self.len > 0 and !std.unicode.utf8ValidateSlice(value[0..self.len])) self.len -= 1;
            @memcpy(self.bytes[0..self.len], value[0..self.len]);
            self.bytes[self.len] = 0;
        }
        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
        pub fn z(self: *const @This()) [:0]const u8 {
            return self.bytes[0..self.len :0];
        }
    };
}
pub const Kind = enum { sink, source, playback, recording };
pub const Key = struct { generation: u64, kind: Kind, index: u32 };
pub const Write = struct { key: Key, volume: ?u8 = null, mute: ?bool = null, default: bool = false, move: ?u32 = null };
pub const Queue = struct {
    items: [32]Write = undefined,
    len: usize = 0,
    pub fn put(self: *Queue, write: Write) !void {
        for (self.items[0..self.len]) |*item| if (std.meta.eql(item.key, write.key)) {
            if (write.volume) |v| item.volume = v;
            if (write.mute) |v| item.mute = v;
            if (write.default) item.default = true;
            if (write.move) |v| item.move = v;
            return;
        };
        if (self.len == self.items.len) return error.Busy;
        self.items[self.len] = write;
        self.len += 1;
    }
    // One operation per dispatch; keep unrelated intents for the same target.
    pub fn take(self: *Queue) ?Write {
        if (self.len == 0) return null;
        const item = &self.items[0];
        var result: Write = .{ .key = item.key };
        if (item.volume) |v| {
            result.volume = v;
            item.volume = null;
        } else if (item.mute) |v| {
            result.mute = v;
            item.mute = null;
        } else if (item.default) {
            result.default = true;
            item.default = false;
        } else {
            result.move = item.move;
            item.move = null;
        }
        if (item.volume == null and item.mute == null and !item.default and item.move == null) {
            self.len -= 1;
            std.mem.copyForwards(Write, self.items[0..self.len], self.items[1 .. self.len + 1]);
        }
        return result;
    }
};
pub fn brightness(percent: u8, maximum: u32) !u32 {
    if (percent > 100 or maximum == 0 or maximum > std.math.maxInt(i32)) return error.InvalidValue;
    // Keep a lit panel; zero slider position means the hardware's minimum nonzero value.
    return @max(1, @as(u32, @intCast((@as(u64, maximum) * percent + 50) / 100)));
}
pub fn deviceName(value: []const u8) bool {
    if (value.len == 0 or value.len > 128 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    return true;
}
test "rapid writes retain final per-target value and independent mute/default intent" {
    var q: Queue = .{};
    const key: Key = .{ .generation = 1, .kind = .sink, .index = 4 };
    for (0..101) |v| try q.put(.{ .key = key, .volume = @intCast(v) });
    try q.put(.{ .key = key, .mute = true });
    try q.put(.{ .key = .{ .generation = 1, .kind = .sink, .index = 5 }, .volume = 23 });
    try std.testing.expectEqual(@as(?u8, 100), q.take().?.volume);
    try std.testing.expectEqual(@as(?bool, true), q.take().?.mute);
    try std.testing.expectEqual(@as(?u8, 23), q.take().?.volume);
    try std.testing.expect(q.take() == null);
}
test "brightness validates device components and clamps hardware minimum" {
    try std.testing.expect(!deviceName("../intel_backlight"));
    try std.testing.expect(!deviceName("."));
    try std.testing.expect(deviceName("intel_backlight"));
    try std.testing.expectEqual(@as(u32, 1), try brightness(0, 1000));
    try std.testing.expectEqual(@as(u32, 510), try brightness(51, 1000));
    try std.testing.expectError(error.InvalidValue, brightness(101, 1000));
    try std.testing.expectError(error.InvalidValue, brightness(50, 0));
}
