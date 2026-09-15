//! Bounded backend-issued page leases. Tokens never repeat within a service's
//! lifetime, including after lock/revocation; frontend disconnect releases only
//! the tokens issued to that frontend. They are not wire authentication.
const std = @import("std");
pub const Owner = enum(u64) { _ };
pub const Interest = struct {
    slots: [16]?Owner = @splat(null),
    next: u64 = 0,
    enabled: bool = true,
    pub fn acquire(self: *Interest) !Owner {
        if (!self.enabled) return error.Locked;
        for (&self.slots) |*slot| if (slot.* == null) {
            if (self.next == std.math.maxInt(u64)) return error.Unavailable;
            self.next += 1;
            const owner: Owner = @enumFromInt(self.next);
            slot.* = owner;
            return owner;
        };
        return error.Busy;
    }
    pub fn contains(self: Interest, owner: ?Owner) bool {
        if (!self.enabled) return false;
        const token = owner orelse return false;
        for (self.slots) |slot| if (slot == token) return true;
        return false;
    }
    pub fn release(self: *Interest, owner: Owner) bool {
        for (&self.slots) |*slot| if (slot.* == owner) {
            slot.* = null;
            return true;
        };
        return false;
    }
    pub fn count(self: Interest) usize {
        var n: usize = 0;
        for (self.slots) |slot| if (slot != null) {
            n += 1;
        };
        return n;
    }
    pub fn revoke(self: *Interest) void {
        self.slots = @splat(null);
    }
};

test "view leases are bounded, independent and never reused after release or lock" {
    const t = std.testing;
    var interest: Interest = .{};
    var owners: [16]Owner = undefined;
    for (&owners) |*owner| owner.* = try interest.acquire();
    try t.expectError(error.Busy, interest.acquire());
    try t.expect(interest.release(owners[0]));
    try t.expect(!interest.release(owners[0]));
    try t.expect(interest.contains(owners[1]));
    const replacement = try interest.acquire();
    try t.expect(replacement != owners[0]);
    interest.enabled = false;
    try t.expectError(error.Locked, interest.acquire());
    try t.expect(!interest.contains(replacement));
    interest.revoke();
    try t.expectEqual(@as(usize, 0), interest.count());
    interest.enabled = true;
    const after_lock = try interest.acquire();
    try t.expect(after_lock != replacement);
    for (owners) |owner| try t.expect(!interest.contains(owner));
    try t.expect(!interest.contains(null));
}
