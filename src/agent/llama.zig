const std = @import("std");
const gio = @import("gio2");
const Runtime = @import("runtime.zig").Runtime;
pub const Call = struct { id: []const u8, type: []const u8 = "function", function: struct { name: []const u8, arguments: []const u8 } };
pub const Message = struct { role: []const u8, content: []const u8 = "", tool_calls: ?[]const Call = null, tool_call_id: ?[]const u8 = null };
pub const Result = struct { content: []const u8, calls: []const Call = &.{} };
pub const tools_json =
    \\[{"type":"function","function":{"name":"search_web","description":"Search the web for evidence. Use a short query.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}}},{"type":"function","function":{"name":"read_page","description":"Read a search result by its numeric source ID.","parameters":{"type":"object","properties":{"result_id":{"type":"integer"}},"required":["result_id"],"additionalProperties":false}}}]
;
pub fn complete(a: std.mem.Allocator, runtime: *Runtime, messages: []const Message, tokens: u32, use_tools: bool, cancel: *gio.Cancellable) !Result {
    return streamed(a, runtime, messages, tokens, use_tools, cancel, null);
}
pub fn streamed(a: std.mem.Allocator, runtime: *Runtime, messages: []const Message, tokens: u32, use_tools: bool, cancel: *gio.Cancellable, live: ?*@import("sse.zig").Live) !Result {
    const tools = if (use_tools) try std.json.parseFromSliceLeaky(std.json.Value, a, tools_json, .{}) else null;
    const body = try std.json.Stringify.valueAlloc(a, .{ .model = "pearl-local", .messages = messages, .tools = tools, .temperature = @as(f32, 0), .max_tokens = tokens, .stream = true }, .{ .emit_null_optional_fields = false });
    var stream: @import("sse.zig").Stream = .{ .a = a, .live = live };
    const response = try @import("fetch.zig").request(a, .{ .url = try std.fmt.allocPrint(a, "{s}/v1/chat/completions", .{runtime.base}), .headers = &.{ runtime.authorization, "Content-Type: application/json" }, .body = body, .private_endpoint = true, .timeout_seconds = runtime.inference_seconds, .receiver = .{ .context = &stream, .feed = feed }, .monitor = .{ .context = runtime, .check = Runtime.monitorCallback } }, cancel);
    if (response.status != 200 or !stream.done) return error.InferenceFailed;
    const calls = try a.alloc(Call, stream.count);
    for (calls, stream.calls[0..stream.count]) |*call, item| {
        if (item.id.items.len == 0 or item.name.items.len == 0) return error.InvalidToolCall;
        call.* = .{ .id = item.id.items, .function = .{ .name = item.name.items, .arguments = item.arguments.items } };
    }
    return .{ .content = stream.content.items, .calls = calls };
}
fn feed(context: *anyopaque, bytes: []const u8) !void {
    const stream: *@import("sse.zig").Stream = @ptrCast(@alignCast(context));
    try stream.feed(bytes);
}
pub fn tokenCount(a: std.mem.Allocator, runtime: *Runtime, text: []const u8, cancel: *gio.Cancellable) !usize {
    const body = try std.json.Stringify.valueAlloc(a, .{ .content = text, .add_special = false }, .{});
    const bytes = try runtime.post(a, "/tokenize", body, cancel);
    const v = try std.json.parseFromSliceLeaky(struct { tokens: []const u32 }, a, bytes, .{ .ignore_unknown_fields = true });
    return v.tokens.len;
}
