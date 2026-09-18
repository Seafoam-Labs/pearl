//! Pure guest-facing availability and bounded, non-counting activity coalescing.
const std = @import("std");
pub const Availability = enum { available, @"permission-denied", unsupported, suspended };
pub const HostState = struct { availability: Availability = .unsupported, epoch: u64 = 1 };
pub const Pending = struct {
    mask: u32 = 0,
    at: i64 = 0,
    epoch: u64 = 0,
    pub fn clear(self: *Pending) void {
        self.* = .{};
    }
    pub fn offer(self: *Pending, mask: u32, epoch: u64, now: i64) void {
        if (mask == 0 or mask & ~@as(u32, 3) != 0) return;
        if (self.epoch != epoch or now - self.at > 100_000) self.clear();
        if (self.mask == 0) self.at = now;
        self.mask |= mask;
        self.epoch = epoch;
    }
    pub fn take(self: *Pending, epoch: u64, now: i64) bool {
        defer self.clear();
        return self.mask != 0 and self.epoch == epoch and now - self.at <= 100_000;
    }
};
test "activity coalesces presence and drops stale epochs or old input" {
    var p: Pending = .{};
    for (0..2000) |_| p.offer(1, 4, 100);
    p.offer(2, 4, 200);
    try std.testing.expectEqual(@as(u32, 3), p.mask);
    try std.testing.expect(p.take(4, 100_100));
    try std.testing.expect(!p.take(4, 100_100));
    p.offer(1, 4, 100);
    try std.testing.expect(!p.take(5, 200));
    p.offer(1, 5, 100);
    try std.testing.expect(!p.take(5, 100_101));
    p.offer(4, 5, 200);
    try std.testing.expectEqual(@as(u32, 0), p.mask);
}
