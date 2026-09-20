//! Serialize generation invalidation with each bounded destination transaction.
const gio = @import("gio2");
const glib = @import("glib2");
pub const Gate = struct {
    mutex: glib.Mutex = .{ .f_p = null },
    generation: u64 = 0,
    pub fn advance(self: *Gate) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.generation += 1;
        return self.generation;
    }
};
pub const Guard = struct {
    gate: ?*Gate = null,
    generation: u64 = 0,
    pub fn begin(self: Guard, cancel: *gio.Cancellable) !void {
        if (self.gate) |g| g.mutex.lock();
        if (cancel.isCancelled() != 0 or (if (self.gate) |g| g.generation != self.generation else false)) {
            self.end();
            return error.Cancelled;
        }
    }
    pub fn end(self: Guard) void {
        if (self.gate) |g| g.mutex.unlock();
    }
};

test "obsolete and cancelled generations cannot enter publication" {
    const std = @import("std");
    var gate: Gate = .{};
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    const first: Guard = .{ .gate = &gate, .generation = gate.advance() };
    try first.begin(cancel);
    first.end();
    const second: Guard = .{ .gate = &gate, .generation = gate.advance() };
    try std.testing.expectError(error.Cancelled, first.begin(cancel));
    try second.begin(cancel);
    second.end();
    cancel.cancel();
    try std.testing.expectError(error.Cancelled, second.begin(cancel));
}
