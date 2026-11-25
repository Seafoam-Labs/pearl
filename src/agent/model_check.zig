//! Independent chat health and optional tool qualification, using local fixtures only.
const std = @import("std");
const gio = @import("gio2");
const llama = @import("llama.zig");
pub fn chat(a: std.mem.Allocator, runtime: *@import("runtime.zig").Runtime, cancel: *gio.Cancellable) !void {
    const messages = [_]llama.Message{
        .{ .role = "system", .content = "Answer briefly in plain text. Do not use tools." },
        .{ .role = "user", .content = "Say hello in one short sentence." },
    };
    const answer = try llama.complete(a, runtime, &messages, runtime.check_tokens, false, cancel);
    if (std.mem.trim(u8, answer.content, " \t\r\n").len == 0 or answer.calls.len != 0) return error.ModelChatIncompatible;
}

/// A warning is returned only after ordinary chat has passed. Probe failures
/// never dispatch a tool: the only tool result below is a fixed local fixture.
/// String literals outlive the probe allocator and remain valid until reset.
pub fn qualify(a: std.mem.Allocator, runtime: *@import("runtime.zig").Runtime, tool_support: bool, cancel: *gio.Cancellable) ![]const u8 {
    try chat(a, runtime, cancel);
    if (!tool_support) return "Chat-only: this runtime lacks Jinja tool support. Web search and page reading are unavailable.";
    check(a, runtime, cancel) catch |err| {
        switch (err) {
            error.Cancelled, error.BenchmarkSkipped, error.OutOfMemory, error.SystemMemoryPressure, error.RuntimeExited, error.RuntimeCheckTimedOut => return err,
            else => {},
        }
        // An HTTP/stream failure may mean either unsupported tools or a broken
        // server. Do not retain a dead runtime merely because chat worked once.
        try chat(a, runtime, cancel);
        return "Chat-only: this runtime/model failed the tool compatibility check. Web search and page reading are unavailable.";
    };
    return "";
}

pub fn check(a: std.mem.Allocator, runtime: *@import("runtime.zig").Runtime, cancel: *gio.Cancellable) !void {
    const messages = [_]llama.Message{
        .{ .role = "system", .content = "Use search_web to find evidence before answering. Cite returned source IDs. Never invent sources." },
        .{ .role = "user", .content = "What is the difference between RAM and storage?" },
    };
    const result = try llama.complete(a, runtime, &messages, runtime.check_tokens, true, cancel);
    if (result.calls.len != 1 or !std.mem.eql(u8, result.calls[0].function.name, "search_web")) return error.ModelToolsIncompatible;
    const args = try std.json.parseFromSliceLeaky(struct { query: []const u8 }, a, result.calls[0].function.arguments, .{});
    if (std.mem.trim(u8, args.query, " \t\r\n").len == 0 or args.query.len > 600) return error.ModelToolsIncompatible;
    // The search phase is complete. Check evidence consumption with the same
    // answer instructions used in chat, without requesting another search.
    const followup = [_]llama.Message{ .{ .role = "system", .content = @import("controller.zig").answer_prompt }, messages[1], .{ .role = "assistant", .content = result.content, .tool_calls = result.calls }, .{ .role = "tool", .tool_call_id = result.calls[0].id, .content = "[{\"id\":1,\"snippet\":\"RAM holds working data temporarily. Storage retains saved files.\"}]" } };
    const answer = try llama.complete(a, runtime, &followup, runtime.check_tokens, false, cancel);
    if (std.mem.trim(u8, answer.content, " \t\r\n").len == 0 or answer.calls.len != 0) return error.ModelToolsIncompatible;
}
