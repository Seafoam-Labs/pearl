//! Provider registry and implementations.
//!
//! Two providers ship built in:
//!   * `fake`   — deterministic, scripted, offline; used by CI and tests.
//!   * `openai` — opt-in OpenAI-compatible HTTP provider using std.http.Client
//!                in the calling worker, with SSE streaming. The endpoint
//!                (`base_url`) and API key come ONLY from user config / env;
//!                no proxy is ever substituted and no secret is logged.
//!
//! A Provider streams events into a Sink. The engine drives the Sink on a
//! worker thread and checks the cancellation Token between events.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cancel = @import("cancel.zig");
const auth = @import("auth.zig");
pub const Token = cancel.Token;

pub const Role = enum { system, user, assistant, tool };

pub const ChatMessage = struct {
    role: Role,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8 = "{}",
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};

pub const Request = struct {
    model: []const u8 = "",
    messages: []const ChatMessage,
    tools: []const ToolSpec = &.{},
};

/// Event sink supplied by the engine. Callbacks may run on a worker thread.
pub const Sink = struct {
    ctx: *anyopaque,
    text: *const fn (ctx: *anyopaque, delta: []const u8) anyerror!void,
    toolCall: *const fn (ctx: *anyopaque, call: ToolCall) anyerror!void,
    done: *const fn (ctx: *anyopaque) anyerror!void,
};

pub const Provider = struct {
    ptr: *anyopaque,
    name: []const u8,
    stream: *const fn (ptr: *anyopaque, allocator: Allocator, io: Io, req: Request, sink: Sink, token: *Token) anyerror!void,
    destroy: ?*const fn (ptr: *anyopaque, allocator: Allocator) void = null,

    pub fn deinit(self: Provider, allocator: Allocator) void {
        if (self.destroy) |d| d(self.ptr, allocator);
    }
};

pub const Config = union(enum) {
    fake: FakeConfig,
    openai: OpenAiConfig,
};

pub const Factory = *const fn (allocator: Allocator, config: Config) anyerror!Provider;

pub const Registry = struct {
    allocator: Allocator,
    factories: std.StringHashMap(Factory),

    pub fn init(allocator: Allocator) Registry {
        return .{ .allocator = allocator, .factories = std.StringHashMap(Factory).init(allocator) };
    }

    pub fn deinit(self: *Registry) void {
        self.factories.deinit();
    }

    pub fn register(self: *Registry, name: []const u8, factory: Factory) !void {
        try self.factories.put(name, factory);
    }

    pub fn contains(self: *const Registry, name: []const u8) bool {
        return self.factories.contains(name);
    }

    pub fn create(self: *const Registry, name: []const u8, allocator: Allocator, config: Config) !Provider {
        const factory = self.factories.get(name) orelse return error.UnknownProvider;
        return factory(allocator, config);
    }

    /// Registry with the built-in providers registered.
    pub fn withDefaults(allocator: Allocator) !Registry {
        var r = Registry.init(allocator);
        errdefer r.deinit();
        try r.register("fake", fakeFactory);
        try r.register("openai", openaiFactory);
        return r;
    }
};

// ---------------------------------------------------------------------------
// Deterministic fake provider
// ---------------------------------------------------------------------------

pub const Step = union(enum) {
    text: []const u8,
    tool_call: ToolCall,
    /// Block until cancelled, then return error.Cancelled. Used to test
    /// mid-stream cancellation deterministically.
    wait_cancel: void,
    fail: []const u8,
};

pub const FakeConfig = struct {
    /// Borrowed; must outlive the provider.
    steps: []const Step = &.{},
    chunk_delay_ms: u32 = 0,
};

pub const FakeProvider = struct {
    config: FakeConfig,

    pub fn stream(ptr: *anyopaque, allocator: Allocator, io: Io, req: Request, sink: Sink, token: *Token) anyerror!void {
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));
        _ = req;
        for (self.config.steps) |step| {
            try token.check();
            if (self.config.chunk_delay_ms > 0) {
                try Io.sleep(io, Io.Duration.fromMilliseconds(self.config.chunk_delay_ms), .real);
            }
            switch (step) {
                .text => |t| try sink.text(sink.ctx, t),
                .tool_call => |c| try sink.toolCall(sink.ctx, c),
                .wait_cancel => {
                    while (!token.isCancelled()) {
                        try Io.sleep(io, Io.Duration.fromMilliseconds(2), .real);
                    }
                    return error.Cancelled;
                },
                .fail => return error.ProviderFailed,
            }
        }
        try token.check();
        _ = allocator;
        try sink.done(sink.ctx);
    }

    pub fn destroy(ptr: *anyopaque, allocator: Allocator) void {
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};

fn fakeFactory(allocator: Allocator, config: Config) anyerror!Provider {
    const p = try allocator.create(FakeProvider);
    p.* = .{ .config = config.fake };
    return .{ .ptr = p, .name = "fake", .stream = FakeProvider.stream, .destroy = FakeProvider.destroy };
}

// ---------------------------------------------------------------------------
// OpenAI-compatible HTTP provider (opt-in, SSE streaming)
// ---------------------------------------------------------------------------

pub const Header = struct { name: []const u8, value: []const u8 };

/// Line sink for streaming transports; one callback per received line.
pub const LineSink = struct {
    ctx: *anyopaque,
    line: *const fn (ctx: *anyopaque, line: []const u8) anyerror!void,
};

/// Pluggable transport so tests can stream canned SSE without any network.
pub const Transport = struct {
    ptr: *anyopaque,
    post: *const fn (ptr: *anyopaque, allocator: Allocator, io: Io, url: []const u8, headers: []const Header, body: []const u8, sink: LineSink, token: *Token) anyerror!void,
    destroy: ?*const fn (ptr: *anyopaque, allocator: Allocator) void = null,
};

pub const OpenAiConfig = struct {
    /// User-supplied endpoint base, e.g. "https://api.openai.com/v1".
    /// Never replaced with a proxy by the backend.
    base_url: []const u8,
    api_key: ?[]const u8 = null,
    api_key_env: []const u8 = "OPENAI_API_KEY",
    model: []const u8 = "gpt-4o-mini",
    env: auth.Env = .{},
    /// null selects the real std.http.Client transport.
    transport: ?Transport = null,
};

pub const OpenAiProvider = struct {
    config: OpenAiConfig,
    transport: Transport,

    pub fn stream(ptr: *anyopaque, allocator: Allocator, io: Io, req: Request, sink: Sink, token: *Token) anyerror!void {
        const self: *OpenAiProvider = @ptrCast(@alignCast(ptr));
        const key = self.config.api_key orelse self.config.env.lookup(self.config.api_key_env) orelse return error.MissingApiKey;

        const url = try chatCompletionsUrl(allocator, self.config.base_url);
        defer allocator.free(url);
        const body = try buildRequestBody(allocator, req, self.config.model);
        defer allocator.free(body);

        const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
        defer allocator.free(auth_value);
        const headers = [_]Header{
            .{ .name = "authorization", .value = auth_value },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "text/event-stream" },
        };

        var handler = SseHandler{ .allocator = allocator, .sink = sink, .token = token };
        defer handler.deinit();
        const line_sink: LineSink = .{ .ctx = &handler, .line = SseHandler.onLine };
        // Errors are surfaced without the key; the transport never logs it.
        try self.transport.post(self.transport.ptr, allocator, io, url, &headers, body, line_sink, token);
        try handler.flush();
    }

    pub fn destroy(ptr: *anyopaque, allocator: Allocator) void {
        const self: *OpenAiProvider = @ptrCast(@alignCast(ptr));
        if (self.transport.destroy) |d| d(self.transport.ptr, allocator);
        allocator.destroy(self);
    }
};

fn openaiFactory(allocator: Allocator, config: Config) anyerror!Provider {
    const p = try allocator.create(OpenAiProvider);
    const cfg = config.openai;
    p.* = .{ .config = cfg, .transport = cfg.transport orelse HttpTransport.default() };
    return .{ .ptr = p, .name = "openai", .stream = OpenAiProvider.stream, .destroy = OpenAiProvider.destroy };
}

/// Join base_url + "/chat/completions" without double slashes.
pub fn chatCompletionsUrl(allocator: Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    return std.fmt.allocPrint(allocator, "{s}/chat/completions", .{trimmed});
}

const OaiMessage = struct {
    role: []const u8,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
};
const OaiFunction = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
};
const OaiTool = struct {
    type: []const u8 = "function",
    function: OaiFunction,
};
const OaiRequest = struct {
    model: []const u8,
    messages: []const OaiMessage,
    tools: []const OaiTool,
    stream: bool = true,
};

/// Build the JSON request body. Exposed for offline tests.
pub fn buildRequestBody(allocator: Allocator, req: Request, model: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const messages = try a.alloc(OaiMessage, req.messages.len);
    for (req.messages, 0..) |m, i| {
        messages[i] = .{ .role = @tagName(m.role), .content = m.content, .tool_call_id = m.tool_call_id };
    }
    const tools = try a.alloc(OaiTool, req.tools.len);
    for (req.tools, 0..) |t, i| {
        const params = try std.json.parseFromSliceLeaky(std.json.Value, a, t.parameters_json, .{});
        tools[i] = .{ .function = .{ .name = t.name, .description = t.description, .parameters = params } };
    }
    const oai: OaiRequest = .{ .model = model, .messages = messages, .tools = tools };
    return std.json.Stringify.valueAlloc(allocator, oai, .{ .emit_null_optional_fields = false });
}

/// Extract the payload of an SSE "data:" line, or null for other lines.
pub fn parseSseLine(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \r");
    if (!std.mem.startsWith(u8, trimmed, "data:")) return null;
    return std.mem.trim(u8, trimmed["data:".len..], " ");
}

const ToolBuilder = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    args: std.ArrayList(u8) = .empty,
};

/// Accumulates SSE deltas and forwards text / tool calls to the provider Sink.
const SseHandler = struct {
    allocator: Allocator,
    sink: Sink,
    token: *Token,
    tools: std.ArrayList(ToolBuilder) = .empty,
    finished: bool = false,

    fn onLine(ctx: *anyopaque, line: []const u8) anyerror!void {
        const self: *SseHandler = @ptrCast(@alignCast(ctx));
        try self.token.check();
        const data = parseSseLine(line) orelse return;
        if (std.mem.eql(u8, data, "[DONE]")) {
            try self.flush();
            self.finished = true;
            try self.sink.done(self.sink.ctx);
            return;
        }
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const choices = parsed.value.object.get("choices") orelse return;
        if (choices != .array or choices.array.items.len == 0) return;
        const choice = choices.array.items[0];
        if (choice != .object) return;
        if (choice.object.get("delta")) |delta| {
            if (delta == .object) {
                if (delta.object.get("content")) |content| {
                    if (content == .string and content.string.len > 0) {
                        try self.sink.text(self.sink.ctx, content.string);
                    }
                }
                if (delta.object.get("tool_calls")) |tcs| {
                    if (tcs == .array) {
                        for (tcs.array.items) |tc| try self.accumulateTool(tc);
                    }
                }
            }
        }
        if (choice.object.get("finish_reason")) |fr| {
            if (fr == .string and std.mem.eql(u8, fr.string, "tool_calls")) {
                try self.flush();
            }
        }
    }

    fn accumulateTool(self: *SseHandler, tc: std.json.Value) !void {
        if (tc != .object) return;
        var index: usize = 0;
        if (tc.object.get("index")) |idx| {
            if (idx == .integer and idx.integer >= 0) index = @intCast(idx.integer);
        }
        while (self.tools.items.len <= index) try self.tools.append(self.allocator, .{});
        const builder = &self.tools.items[index];
        if (tc.object.get("id")) |id| {
            if (id == .string) try builder.id.appendSlice(self.allocator, id.string);
        }
        if (tc.object.get("function")) |func| {
            if (func == .object) {
                if (func.object.get("name")) |n| {
                    if (n == .string) try builder.name.appendSlice(self.allocator, n.string);
                }
                if (func.object.get("arguments")) |args| {
                    if (args == .string) try builder.args.appendSlice(self.allocator, args.string);
                }
            }
        }
    }

    fn flush(self: *SseHandler) !void {
        for (self.tools.items) |*builder| {
            if (builder.name.items.len == 0) continue;
            const call: ToolCall = .{
                .id = if (builder.id.items.len > 0) builder.id.items else "call",
                .name = builder.name.items,
                .arguments_json = if (builder.args.items.len > 0) builder.args.items else "{}",
            };
            try self.sink.toolCall(self.sink.ctx, call);
        }
        for (self.tools.items) |*builder| {
            builder.id.deinit(self.allocator);
            builder.name.deinit(self.allocator);
            builder.args.deinit(self.allocator);
        }
        self.tools.clearRetainingCapacity();
    }

    fn deinit(self: *SseHandler) void {
        for (self.tools.items) |*builder| {
            builder.id.deinit(self.allocator);
            builder.name.deinit(self.allocator);
            builder.args.deinit(self.allocator);
        }
        self.tools.deinit(self.allocator);
    }
};

/// Real transport using std.http.Client. Runs in the calling worker thread.
pub const HttpTransport = struct {
    pub fn default() Transport {
        return .{ .ptr = undefined, .post = post };
    }

    fn post(_: *anyopaque, allocator: Allocator, io: Io, url: []const u8, headers: []const Header, body: []const u8, sink: LineSink, token: *Token) anyerror!void {
        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();
        const uri = try std.Uri.parse(url);
        var extra: std.ArrayList(std.http.Header) = .empty;
        defer extra.deinit(allocator);
        for (headers) |h| try extra.append(allocator, .{ .name = h.name, .value = h.value });

        var req = try client.request(.POST, uri, .{
            .headers = .{ .content_type = .omit, .authorization = .omit, .accept_encoding = .omit },
            .extra_headers = extra.items,
        });
        defer req.deinit();
        try req.sendBodyComplete(@constCast(body));
        var redirect_buf: [8192]u8 = undefined;
        var res = try req.receiveHead(&redirect_buf);
        if (res.head.status != .ok) return error.HttpError;
        var transfer_buf: [4096]u8 = undefined;
        const reader = res.reader(&transfer_buf);
        while (true) {
            try token.check();
            const line = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => return error.SseLineTooLong,
                error.ReadFailed => return error.HttpReadFailed,
            } orelse break;
            try sink.line(sink.ctx, line);
        }
    }
};

test "parseSseLine" {
    try std.testing.expectEqualStrings("{\"x\":1}", parseSseLine("data: {\"x\":1}").?);
    try std.testing.expectEqualStrings("[DONE]", parseSseLine("data: [DONE]").?);
    try std.testing.expect(parseSseLine("event: message") == null);
    try std.testing.expect(parseSseLine(": comment") == null);
}

test "chatCompletionsUrl trims slashes" {
    const a = std.testing.allocator;
    const u = try chatCompletionsUrl(a, "https://example.test/v1/");
    defer a.free(u);
    try std.testing.expectEqualStrings("https://example.test/v1/chat/completions", u);
}

test "buildRequestBody shape" {
    const a = std.testing.allocator;
    const body = try buildRequestBody(a, .{
        .messages = &.{.{ .role = .user, .content = "hi" }},
        .tools = &.{.{ .name = "read_file", .description = "read", .parameters_json = "{\"type\":\"object\"}" }},
    }, "test-model");
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"test-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"read_file\"") != null);
}

test "fake provider streams text and tool calls" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Collect = struct {
        text: std.ArrayList(u8) = .empty,
        calls: usize = 0,
        done: bool = false,
        fn textCb(ctx: *anyopaque, delta: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.text.appendSlice(a, delta);
        }
        fn toolCb(ctx: *anyopaque, call: ToolCall) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = call;
            self.calls += 1;
        }
        fn doneCb(ctx: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.done = true;
        }
    };
    var collect: Collect = .{};
    defer collect.text.deinit(a);

    const steps = [_]Step{ .{ .text = "Hello " }, .{ .text = "world" }, .{ .tool_call = .{ .id = "c1", .name = "read_file", .arguments_json = "{}" } } };
    var reg = try Registry.withDefaults(a);
    defer reg.deinit();
    const provider = try reg.create("fake", a, .{ .fake = .{ .steps = &steps } });
    defer provider.deinit(a);
    var token: Token = .{};
    const sink: Sink = .{ .ctx = &collect, .text = Collect.textCb, .toolCall = Collect.toolCb, .done = Collect.doneCb };
    try provider.stream(provider.ptr, a, io, .{ .messages = &.{} }, sink, &token);
    try std.testing.expectEqualStrings("Hello world", collect.text.items);
    try std.testing.expectEqual(@as(usize, 1), collect.calls);
    try std.testing.expect(collect.done);
}

test "fake provider cancellation" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Collect = struct {
        fn textCb(_: *anyopaque, _: []const u8) anyerror!void {}
        fn toolCb(_: *anyopaque, _: ToolCall) anyerror!void {}
        fn doneCb(_: *anyopaque) anyerror!void {}
    };
    const steps = [_]Step{ .{ .text = "partial" }, .wait_cancel };
    var reg = try Registry.withDefaults(a);
    defer reg.deinit();
    const provider = try reg.create("fake", a, .{ .fake = .{ .steps = &steps } });
    defer provider.deinit(a);
    var token: Token = .{};
    token.cancel();
    const sink: Sink = .{ .ctx = undefined, .text = Collect.textCb, .toolCall = Collect.toolCb, .done = Collect.doneCb };
    try std.testing.expectError(error.Cancelled, provider.stream(provider.ptr, a, io, .{ .messages = &.{} }, sink, &token));
}

test "openai provider streams via fake transport (no network)" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const FakeTransport = struct {
        fn post(_: *anyopaque, _: Allocator, _: Io, url: []const u8, headers: []const Header, body: []const u8, sink: LineSink, token: *Token) anyerror!void {
            // Verify the endpoint is the user-supplied one, not a proxy.
            if (std.mem.indexOf(u8, url, "https://api.example.test/v1/chat/completions") == null) return error.BadUrl;
            _ = headers;
            _ = body;
            _ = token;
            const lines = [_][]const u8{
                "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}",
                "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}",
                "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}",
                "data: [DONE]",
            };
            for (lines) |l| try sink.line(sink.ctx, l);
        }
    };
    const Collect = struct {
        text: std.ArrayList(u8) = .empty,
        calls: usize = 0,
        done: bool = false,
        fn textCb(ctx: *anyopaque, delta: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.text.appendSlice(a, delta);
        }
        fn toolCb(ctx: *anyopaque, call: ToolCall) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!std.mem.eql(u8, call.name, "read_file")) return error.BadTool;
            self.calls += 1;
        }
        fn doneCb(ctx: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.done = true;
        }
    };
    var collect: Collect = .{};
    defer collect.text.deinit(a);

    var reg = try Registry.withDefaults(a);
    defer reg.deinit();
    const provider = try reg.create("openai", a, .{ .openai = .{
        .base_url = "https://api.example.test/v1",
        .api_key = "sk-test",
        .transport = .{ .ptr = undefined, .post = FakeTransport.post },
    } });
    defer provider.deinit(a);
    var token: Token = .{};
    const sink: Sink = .{ .ctx = &collect, .text = Collect.textCb, .toolCall = Collect.toolCb, .done = Collect.doneCb };
    try provider.stream(provider.ptr, a, io, .{ .messages = &.{.{ .role = .user, .content = "hi" }} }, sink, &token);
    try std.testing.expectEqualStrings("Hello", collect.text.items);
    try std.testing.expectEqual(@as(usize, 1), collect.calls);
    try std.testing.expect(collect.done);
}

test "openai provider requires api key" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const NoEnv = struct {
        fn get(_: ?*anyopaque, _: []const u8) ?[]const u8 {
            return null;
        }
    };
    var reg = try Registry.withDefaults(a);
    defer reg.deinit();
    const provider = try reg.create("openai", a, .{ .openai = .{
        .base_url = "https://api.example.test/v1",
        .env = .{ .get = NoEnv.get },
        .transport = .{ .ptr = undefined, .post = HttpTransport.post },
    } });
    defer provider.deinit(a);
    var token: Token = .{};
    const Collect = struct {
        fn textCb(_: *anyopaque, _: []const u8) anyerror!void {}
        fn toolCb(_: *anyopaque, _: ToolCall) anyerror!void {}
        fn doneCb(_: *anyopaque) anyerror!void {}
    };
    const sink: Sink = .{ .ctx = undefined, .text = Collect.textCb, .toolCall = Collect.toolCb, .done = Collect.doneCb };
    try std.testing.expectError(error.MissingApiKey, provider.stream(provider.ptr, a, io, .{ .messages = &.{} }, sink, &token));
}
