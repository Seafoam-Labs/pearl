//! Cooperative cancellation shared by streams, tool runs and RPC waits.

const std = @import("std");

pub const Token = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn cancel(self: *Token) void {
        self.cancelled.store(true, .release);
    }

    pub fn isCancelled(self: *const Token) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn check(self: *const Token) error{Cancelled}!void {
        if (self.isCancelled()) return error.Cancelled;
    }

    pub fn reset(self: *Token) void {
        self.cancelled.store(false, .release);
    }
};

test "Token cancel/check/reset" {
    var token: Token = .{};
    try token.check();
    try std.testing.expect(!token.isCancelled());
    token.cancel();
    try std.testing.expect(token.isCancelled());
    try std.testing.expectError(error.Cancelled, token.check());
    token.reset();
    try token.check();
}
