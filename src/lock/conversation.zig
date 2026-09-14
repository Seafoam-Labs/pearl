//! Private, same-executable PAM conversation framing. No secrets in argv/logs.
const std = @import("std");
pub const Packet = extern struct {
    kind: u32 = 0, // PAM message style, 100=result (value=status), 101=response
    value: u32 = 0,
    length: u32 = 0,
    bytes: [1024]u8 = @splat(0),
    pub fn set(self: *Packet, value: []const u8) void {
        self.length = @intCast(@min(value.len, self.bytes.len - 1));
        @memcpy(self.bytes[0..self.length], value[0..self.length]);
        self.bytes[self.length] = 0;
    }
    pub fn valid(self: Packet) bool {
        return self.length < self.bytes.len and self.bytes[self.length] == 0 and
            std.mem.indexOfScalar(u8, self.bytes[0..self.length], 0) == null and std.unicode.utf8ValidateSlice(self.bytes[0..self.length]);
    }
    pub fn wipe(self: *Packet) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }
};
pub fn write(fd: c_int, p: *const Packet) bool {
    const bytes = std.mem.asBytes(p);
    var used: usize = 0;
    while (used < bytes.len) {
        const n = std.c.write(fd, bytes[used..].ptr, bytes.len - used);
        if (n <= 0) return false;
        used += @intCast(n);
    }
    return true;
}
pub fn read(fd: c_int, p: *Packet) bool {
    const bytes = std.mem.asBytes(p);
    var used: usize = 0;
    while (used < bytes.len) {
        const n = std.c.read(fd, bytes[used..].ptr, bytes.len - used);
        if (n <= 0) return false;
        used += @intCast(n);
    }
    return p.valid();
}
test "conversation framing rejects overlong, embedded NUL and invalid UTF8" {
    var p: Packet = .{};
    p.set("Password:");
    try std.testing.expect(p.valid());
    p.length = 1024;
    try std.testing.expect(!p.valid());
    p.length = 3;
    p.bytes = @splat(0);
    try std.testing.expect(!p.valid());
    p.set("\xff");
    try std.testing.expect(!p.valid());
    p.wipe();
    try std.testing.expectEqual(@as(u32, 0), p.length);
}
