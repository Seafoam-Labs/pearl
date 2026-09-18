const std = @import("std");
pub const Phase = enum(u8) { preparing, fetching_index, downloading, validating, installing, generating };
pub const Progress = struct {
    phase: std.atomic.Value(Phase) = .init(.preparing),
    received: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    pub fn set(self: *Progress, phase: Phase) void {
        self.phase.store(phase, .monotonic);
    }
};
