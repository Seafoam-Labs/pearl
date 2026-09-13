const std = @import("std");

/// Main-context-only state. Worker threads never read or modify this object.
pub const Lifecycle = struct {
    phase: enum { idle, running, stopping, stopped } = .idle,
    generation: u64 = 0,
    pending: bool = false,

    pub fn start(self: *Lifecycle) void {
        std.debug.assert(self.phase == .idle or self.phase == .stopped);
        std.debug.assert(!self.pending);
        self.generation += 1;
        self.phase = .running;
    }

    pub fn beginWork(self: *Lifecycle) !u64 {
        if (self.phase != .running) return error.Stopping;
        if (self.pending) return error.Busy;
        self.pending = true;
        return self.generation;
    }

    pub fn stop(self: *Lifecycle) bool {
        if (self.phase != .running) return false;
        self.phase = .stopping;
        return true;
    }

    /// Exactly one completion consumes each accepted task, including cancellation.
    pub fn complete(self: *Lifecycle, ticket: u64) bool {
        std.debug.assert(self.pending and ticket == self.generation);
        self.pending = false;
        return self.phase == .running;
    }

    pub fn finish(self: *Lifecycle) void {
        std.debug.assert(self.phase == .stopping and !self.pending);
        self.phase = .stopped;
    }
};

test "shutdown rejects new jobs and discards canceled completion before restart" {
    var state: Lifecycle = .{};
    for (0..20) |_| {
        state.start();
        const ticket = try state.beginWork();
        try std.testing.expectError(error.Busy, state.beginWork());
        try std.testing.expect(state.stop());
        try std.testing.expect(!state.stop());
        try std.testing.expectError(error.Stopping, state.beginWork());
        try std.testing.expect(!state.complete(ticket));
        state.finish();
    }
    try std.testing.expectEqual(@as(u64, 20), state.generation);
}

test "completed work may update a live view and releases the bounded slot" {
    var state: Lifecycle = .{};
    state.start();
    try std.testing.expect(state.complete(try state.beginWork()));
    try std.testing.expect(state.complete(try state.beginWork()));
    _ = state.stop();
    state.finish();
}
