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
    return streamedDynamic(a, runtime, messages, tokens, tools, cancel, live);
}
pub fn streamedDynamic(a: std.mem.Allocator, runtime: *Runtime, messages: []const Message, tokens: u32, tools: ?std.json.Value, cancel: *gio.Cancellable, live: ?*@import("sse.zig").Live) !Result {
    const body = try std.json.Stringify.valueAlloc(a, .{ .model = "pearl-local", .messages = messages, .tools = tools, .temperature = @as(f32, 0), .max_tokens = tokens, .stream = true, .stream_options = .{ .include_usage = true } }, .{ .emit_null_optional_fields = false });
    var stream: @import("sse.zig").Stream = .{ .a = a, .live = live };
    const response = try @import("fetch.zig").request(a, .{ .url = try std.fmt.allocPrint(a, "{s}/v1/chat/completions", .{runtime.base}), .headers = &.{ runtime.authorization, "Content-Type: application/json" }, .body = body, .private_endpoint = true, .timeout_seconds = runtime.inference_seconds, .receiver = .{ .context = &stream, .feed = feed }, .monitor = .{ .context = runtime, .check = Runtime.monitorCallback } }, cancel);
    if (response.status != 200 or !stream.done) return error.InferenceFailed;
    if (runtime.telemetry) |metrics| metrics.tokens.add(stream.telemetry);
    if (stream.truncated) return error.GenerationTruncated;
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
/// Conservative byte-based prompt budget. mistral.rs exposes no /tokenize or
/// /apply-template endpoint, so tokens are estimated from message content
/// bytes (~3 bytes per token for a 128K multilingual vocabulary) plus chat
/// template and tool-schema overhead. Overestimating keeps context fitting
/// safe; the signatures match the previous server-measured implementation.
pub fn promptTokens(a: std.mem.Allocator, runtime: *Runtime, messages: []const Message, use_tools: bool, cancel: *gio.Cancellable) !usize {
    const tools = if (use_tools) try std.json.parseFromSliceLeaky(std.json.Value, a, tools_json, .{}) else null;
    return promptTokensDynamic(a, runtime, messages, tools, cancel);
}
pub fn promptTokensDynamic(a: std.mem.Allocator, runtime: *Runtime, messages: []const Message, tools: ?std.json.Value, cancel: *gio.Cancellable) !usize {
    _ = runtime;
    _ = cancel;
    var bytes: usize = 0;
    for (messages) |message| bytes += message.content.len;
    var overhead: usize = 200;
    if (tools) |value| overhead += (try std.json.Stringify.valueAlloc(a, value, .{})).len / 4;
    return bytes / 3 + overhead;
}
pub fn tokenCount(a: std.mem.Allocator, runtime: *Runtime, text: []const u8, cancel: *gio.Cancellable) !usize {
    _ = a;
    _ = runtime;
    _ = cancel;
    return text.len / 3 + 1;
}
/// Build the tool schema array for the enabled capabilities.
pub fn toolsForConfig(a: std.mem.Allocator, config: @import("config.zig").Config, local_enabled: bool) !?std.json.Value {
    var tools = std.json.Array.init(a);
    if (config.hasSearch()) {
        try tools.append(try std.json.parseFromSliceLeaky(std.json.Value, a,
            \\{"type":"function","function":{"name":"search_web","description":"Search the web for current information. Use a short query.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}}}
        , .{}));
    }
    if (config.read_pages) {
        try tools.append(try std.json.parseFromSliceLeaky(std.json.Value, a,
            \\{"type":"function","function":{"name":"read_page","description":"Read a web search result by its numeric source ID.","parameters":{"type":"object","properties":{"result_id":{"type":"integer"}},"required":["result_id"],"additionalProperties":false}}}
        , .{}));
    }
    if (local_enabled and config.local.enabled) {
        try tools.append(try std.json.parseFromSliceLeaky(std.json.Value, a,
            \\{"type":"function","function":{"name":"search_files","description":"Search granted local folders by filename or content. Returns file IDs for reading.","parameters":{"type":"object","properties":{"root_id":{"type":"string"},"query":{"type":"string"},"mode":{"type":"string","enum":["filename","content"]},"cursor":{"type":"integer"}},"required":["root_id","query","mode"],"additionalProperties":false}}}
        , .{}));
        try tools.append(try std.json.parseFromSliceLeaky(std.json.Value, a,
            \\{"type":"function","function":{"name":"read_file","description":"Read a local file by its opaque file ID. Returns bounded UTF-8 text.","parameters":{"type":"object","properties":{"file_id":{"type":"string"},"offset":{"type":"integer"},"length":{"type":"integer"}},"required":["file_id"],"additionalProperties":false}}}
        , .{}));
        try tools.append(try std.json.parseFromSliceLeaky(std.json.Value, a,
            \\{"type":"function","function":{"name":"create_file","description":"Create a new text file in a granted folder. Requires user confirmation. Never overwrites.","parameters":{"type":"object","properties":{"parent_id":{"type":"string"},"name":{"type":"string"},"content":{"type":"string"}},"required":["parent_id","name","content"],"additionalProperties":false}}}
        , .{}));
        try tools.append(try std.json.parseFromSliceLeaky(std.json.Value, a,
            \\{"type":"function","function":{"name":"delete_file","description":"Delete a local file (moves to Trash). Requires explicit user confirmation of the exact target.","parameters":{"type":"object","properties":{"file_id":{"type":"string"}},"required":["file_id"],"additionalProperties":false}}}
        , .{}));
        try tools.append(try std.json.parseFromSliceLeaky(std.json.Value, a,
            \\{"type":"function","function":{"name":"find_applications","description":"Find installed applications by name. Returns desktop IDs for opening.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}}}
        , .{}));
        if (config.local.open_apps) {
            try tools.append(try std.json.parseFromSliceLeaky(std.json.Value, a,
                \\{"type":"function","function":{"name":"open_application","description":"Open an installed application by its desktop ID. Requires user confirmation.","parameters":{"type":"object","properties":{"application_id":{"type":"string"}},"required":["application_id"],"additionalProperties":false}}}
            , .{}));
        }
    }
    if (tools.items.len == 0) return null;
    return std.json.Value{ .array = tools };
}
