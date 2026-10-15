//! Local fixtures only: verifies actual tool production and result consumption.
const std = @import("std");
const gio = @import("gio2");
const llama = @import("llama.zig");
pub fn check(a: std.mem.Allocator, runtime: *@import("runtime.zig").Runtime, cancel: *gio.Cancellable) !void {
    const messages = [_]llama.Message{
        .{ .role = "system", .content = "Use search_web to find evidence before answering. Cite returned source IDs. Never invent sources." },
        .{ .role = "user", .content = "What is the difference between RAM and storage?" },
    };
    const result = try llama.complete(a, runtime, &messages, runtime.check_tokens, true, cancel);
    if (result.calls.len != 1 or !std.mem.eql(u8, result.calls[0].function.name, "search_web")) return error.ModelToolsIncompatible;
    const args = try std.json.parseFromSliceLeaky(struct { query: []const u8 }, a, result.calls[0].function.arguments, .{});
    if (args.query.len == 0 or args.query.len > 600) return error.ModelToolsIncompatible;
    // The search phase is complete. Check evidence consumption with the same
    // answer instructions used in chat, without requesting another search.
    const followup = [_]llama.Message{ .{ .role = "system", .content = @import("controller.zig").answer_prompt }, messages[1], .{ .role = "assistant", .content = result.content, .tool_calls = result.calls }, .{ .role = "tool", .tool_call_id = result.calls[0].id, .content = "[{\"id\":1,\"snippet\":\"RAM holds working data temporarily. Storage retains saved files.\"}]" } };
    const answer = try llama.complete(a, runtime, &followup, runtime.check_tokens, false, cancel);
    if (answer.content.len == 0 or answer.calls.len != 0) return error.ModelToolsIncompatible;
}
