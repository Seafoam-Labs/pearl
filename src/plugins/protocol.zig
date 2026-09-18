const std = @import("std");
const m = @import("model.zig");
pub const Request = struct { version: u8 = 1, generation: u64, sequence: u64, event: m.Event };
pub const Reply = struct { version: u8 = 1, generation: u64, sequence: u64, scene: ?m.Scene = null, timer_ms: u32 = 0, error_code: ?[]const u8 = null };
pub fn parse(comptime T: type, alloc: std.mem.Allocator, bytes: []const u8) !T {
    try @import("../config/preferences.zig").boundedJson(bytes, m.Limits.frame, 12);
    const value = try std.json.parseFromSliceLeaky(T, alloc, bytes, .{ .allocate = .alloc_always });
    if (value.version != 1 or value.generation == 0 or value.sequence == 0) return error.PluginProtocol;
    return value;
}
test "wire rejects stale version and repeated JSON keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.PluginProtocol, parse(Request, arena.allocator(), "{\"version\":2,\"generation\":1,\"sequence\":1,\"event\":{\"kind\":\"activate\"}}"));
    try std.testing.expectError(error.DuplicateField, parse(Request, arena.allocator(), "{\"generation\":1,\"generation\":2,\"sequence\":1,\"event\":{\"kind\":\"activate\"}}"));
}
