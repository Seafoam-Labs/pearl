//! Incremental OpenAI SSE decoding; incomplete UTF-8/JSON/tool syntax never
//! reaches the conversation view. Byte, line, call and argument limits apply.
const std = @import("std");
pub const Live = struct {
    mutex: std.atomic.Value(bool) = .init(false),
    bytes: [16384]u8 = undefined,
    len: usize = 0,
    revision: u64 = 0,
    first_visible_us: std.atomic.Value(i64) = .init(0),
    pub fn put(self: *Live, text: []const u8) void {
        if (text.len > self.bytes.len or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOf(u8, text, "<|") != null) return;
        while (self.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
        defer self.mutex.store(false, .release);
        @memcpy(self.bytes[0..text.len], text);
        self.len = text.len;
        self.revision += 1;
        if (text.len > 0 and self.first_visible_us.load(.monotonic) == 0) self.first_visible_us.store(@import("glib2").getMonotonicTime(), .monotonic);
    }
    pub fn copy(self: *Live, buffer: []u8, revision: *u64) ?[]const u8 {
        if (self.mutex.swap(true, .acquire)) return null;
        defer self.mutex.store(false, .release);
        if (self.revision == revision.* or self.len > buffer.len) return null;
        revision.* = self.revision;
        @memcpy(buffer[0..self.len], self.bytes[0..self.len]);
        return buffer[0..self.len];
    }
};
pub const Call = struct { id: std.ArrayList(u8) = .empty, name: std.ArrayList(u8) = .empty, arguments: std.ArrayList(u8) = .empty };
pub const Stream = struct {
    a: std.mem.Allocator,
    line: std.ArrayList(u8) = .empty,
    content: std.ArrayList(u8) = .empty,
    calls: [6]Call = @splat(.{}),
    count: usize = 0,
    done: bool = false,
    live: ?*Live = null,
    truncated: bool = false,
    telemetry: @import("telemetry.zig").Tokens = .{},
    pub fn feed(self: *Stream, bytes: []const u8) !void {
        for (bytes) |ch| {
            if (ch == '\n') {
                try self.consume(std.mem.trimEnd(u8, self.line.items, "\r"));
                self.line.clearRetainingCapacity();
            } else {
                if (self.line.items.len >= 65536) return error.StreamLineTooLarge;
                try self.line.append(self.a, ch);
            }
        }
    }
    fn append(self: *Stream, list: *std.ArrayList(u8), value: []const u8, max: usize) !void {
        if (value.len > max -| list.items.len) return error.ModelResponseTooLarge;
        try list.appendSlice(self.a, value);
    }
    fn consume(self: *Stream, line: []const u8) !void {
        if (!std.mem.startsWith(u8, line, "data:")) return;
        const bytes = std.mem.trimStart(u8, line[5..], " ");
        if (std.mem.eql(u8, bytes, "[DONE]")) {
            self.done = true;
            return;
        }
        if (self.done) return error.InvalidModelStream;
        const value = try std.json.parseFromSliceLeaky(std.json.Value, self.a, bytes, .{});
        const helpers = @import("providers.zig");
        self.telemetry.parse(value);
        const choices = helpers.field(value, "choices") orelse return error.InvalidModelStream;
        if (choices != .array or choices.array.items.len > 1) return error.InvalidModelStream;
        if (choices.array.items.len == 0) return;
        if (std.mem.eql(u8, helpers.string(choices.array.items[0], "finish_reason"), "length")) self.truncated = true;
        const delta = helpers.field(choices.array.items[0], "delta") orelse return;
        if (helpers.field(delta, "tool_calls")) |calls| {
            if (calls != .array) return error.InvalidToolCall;
            for (calls.array.items) |part| {
                const index = helpers.field(part, "index") orelse return error.InvalidToolCall;
                if (index != .integer or index.integer < 0 or index.integer >= self.calls.len) return error.InvalidToolCall;
                const i: usize = @intCast(index.integer);
                if (i > self.count) return error.InvalidToolCall;
                self.count = @max(self.count, i + 1);
                const call = &self.calls[i];
                try self.append(&call.id, helpers.string(part, "id"), 128);
                if (helpers.field(part, "function")) |function| {
                    try self.append(&call.name, helpers.string(function, "name"), 64);
                    try self.append(&call.arguments, helpers.string(function, "arguments"), 4096);
                }
            }
        }
        try self.append(&self.content, helpers.string(delta, "content"), 16384);
        if (self.count == 0) if (self.live) |live| live.put(self.content.items);
    }
};
test "SSE survives byte boundaries and accumulates split tool arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stream: Stream = .{ .a = arena.allocator() };
    const bytes = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"search_web\",\"arguments\":\"{\\\"query\\\":\"}}]}}]}\n\ndata: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"RAM\\\"}\"}}]}}]}\r\n\r\ndata: [DONE]\n\n";
    for (bytes) |ch| try stream.feed(&.{ch});
    try std.testing.expect(stream.done);
    try std.testing.expectEqualStrings("{\"query\":\"RAM\"}", stream.calls[0].arguments.items);
    var text: Stream = .{ .a = arena.allocator() };
    for ("data: {\"choices\":[{\"delta\":{\"content\":\"Grüße\"}}]}\n\ndata: [DONE]\n") |ch| try text.feed(&.{ch});
    try std.testing.expectEqualStrings("Grüße", text.content.items);
}

test "reasoning deltas are excluded from visible answers and citations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var live: Live = .{};
    var stream: Stream = .{ .a = arena.allocator(), .live = &live };
    try stream.feed("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Consider an unsupported source [99].\"}}]}\n\n");
    try std.testing.expectEqual(@as(i64, 0), live.first_visible_us.load(.monotonic));
    try stream.feed("data: {\"choices\":[{\"delta\":{\"content\":\"Supported answer. [1]\"}}]}\n\ndata: [DONE]\n\n");
    try std.testing.expect(stream.done);
    try std.testing.expectEqualStrings("Supported answer. [1]", stream.content.items);
    try std.testing.expect(live.first_visible_us.load(.monotonic) > 0);
}

test "truncation and trailing usage survive streaming without visible text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stream: Stream = .{ .a = arena.allocator() };
    try stream.feed("data: {\"choices\":[{\"delta\":{\"content\":\"Partial [1]\"},\"finish_reason\":\"length\"}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":8}}\n\ndata: [DONE]\n\n");
    try std.testing.expect(stream.done and stream.truncated);
    try std.testing.expectEqual(@as(?u64, 8), stream.telemetry.generated);
}
