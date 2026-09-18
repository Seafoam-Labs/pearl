const std = @import("std");
const m = @import("model.zig");
pub const HostState = @import("activity_policy.zig").HostState;
pub const Request = struct { version: u8 = 2, generation: u64, sequence: u64, state: HostState = .{}, event: ?m.Event = null };
pub const Reply = struct { version: u8 = 2, generation: u64, sequence: u64, activity_requested: bool = false, activity_epoch: u64 = 1, scene: ?m.Scene = null, timer_ms: u32 = 0, timer_changed: bool = false, error_code: ?[]const u8 = null };
pub fn parse(comptime T: type, alloc: std.mem.Allocator, bytes: []const u8) !T {
    try @import("../config/preferences.zig").boundedJson(bytes, m.Limits.frame, 12);
    const value = try std.json.parseFromSliceLeaky(T, alloc, bytes, .{ .allocate = .alloc_always });
    if (value.version != 2 or value.generation == 0 or value.sequence == 0) return error.PluginProtocol;
    return value;
}
test "wire rejects stale version and repeated JSON keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.PluginProtocol, parse(Request, arena.allocator(), "{\"version\":1,\"generation\":1,\"sequence\":1,\"event\":{\"kind\":\"activate\"}}"));
    try std.testing.expectError(error.DuplicateField, parse(Request, arena.allocator(), "{\"generation\":1,\"generation\":2,\"sequence\":1,\"event\":{\"kind\":\"activate\"}}"));
}
