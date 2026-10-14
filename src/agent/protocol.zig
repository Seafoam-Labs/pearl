//! The verified shell passes an anonymous same-user socket to its child.
//! There is no ambient/public activation endpoint or prompt in argv.
const std = @import("std");
pub const Request = struct {
    agent: u8 = 1,
    id: u64,
    op: enum { configure, ask, @"resume", @"suspend", clear, stop, release_runtime, test_state, test_submit, test_hide },
    config: ?@import("config.zig").Config = null,
    question: []const u8 = "",
    activation: []const u8 = "",
    palette: ?@import("../theme/theme.zig").Palette = null,
};
pub const State = struct { visible: bool, busy: bool, suspended: bool, runtime: bool, conversations: usize, turns: []const @import("controller.zig").Turn, sources: usize, status: []const u8, error_code: []const u8 = "", draft_chars: usize = 0 };
pub const ComputeStatus = struct { busy: bool = false, loaded: bool = false, gpu: bool = false, backend: @import("config.zig").Backend = .auto, layers: u16 = 0, fallback: bool = false, enforced_memory: bool = false };
pub const Reply = struct { agent: u8 = 1, id: u64, ok: bool = true, err: ?[]const u8 = null, settings: bool = false, compute: ?ComputeStatus = null, state: ?State = null };
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Request {
    try @import("../config/preferences.zig").boundedJson(bytes, 32768, 8);
    const request = try std.json.parseFromSliceLeaky(Request, a, bytes, .{});
    if (request.agent != 1 or request.id == 0) return error.InvalidAgentRequest;
    if (request.question.len > 2048 or request.activation.len > 4096 or std.mem.indexOfScalar(u8, request.question, 0) != null or !std.unicode.utf8ValidateSlice(request.question)) return error.InvalidAgentRequest;
    if (request.op == .ask and std.mem.trim(u8, request.question, " \t\r\n").len == 0) return error.InvalidAgentRequest;
    if (request.config) |config| try config.validate();
    if (request.palette) |palette| try @import("../theme/theme.zig").validate(palette);
    return request;
}
test "agent activation has bounded questions and a version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidAgentRequest, parse(arena.allocator(), "{\"agent\":2,\"id\":1,\"op\":\"resume\"}"));
    try std.testing.expectError(error.InvalidAgentRequest, parse(arena.allocator(), "{\"id\":1,\"op\":\"ask\",\"question\":\" \"}"));
}
