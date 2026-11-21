//! Native, offline controller contract tests. The Python subprocess implements
//! HTTP/SSE only; all tool execution, assertions and scenario policy live here.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const controller = @import("controller.zig");
const cfg = @import("config.zig");
const llama = @import("llama.zig");
const Runtime = @import("runtime.zig").Runtime;
const Live = @import("sse.zig").Live;
const memory = @import("memory.zig");
const t = std.testing;

const source: controller.Source = .{ .id = 1, .title = "Local timetable", .url = "https://fixture.invalid/timetable", .snippet = "The current journey takes 47 minutes.", .provider = "offline" };
const Reply = struct {
    text: []const u8 = "",
    name: []const u8 = "",
    arguments: []const u8 = "",
    id: []const u8 = "call-1",
    finish: []const u8 = "stop",
    status: u16 = 200,
    gated: bool = false,
};
const search_call: Reply = .{ .name = "search_web", .arguments = "{\"query\":\"current timetable\"}" };
const read_call: Reply = .{ .name = "read_page", .arguments = "{\"result_id\":1}", .id = "read-1" };
const cited: Reply = .{ .text = "The current journey takes 47 minutes. [1]" };
const Plan = struct {
    qualification: enum { full, chat_only, failed } = .full,
    replies: []const Reply,
};
const Payload = struct {
    messages: []const llama.Message = &.{},
    tools: ?std.json.Value = null,
    max_tokens: u32 = 0,
};
const Request = struct { kind: []const u8, payload: Payload };

const Fixture = struct {
    a: std.mem.Allocator,
    directory: [:0]const u8,
    executable: [:0]const u8,
    plan: [:0]const u8,
    requests: [:0]const u8,
    release: [:0]const u8,
    model: [:0]const u8,
    runtime: Runtime = .{},
    config: cfg.Config,
    cancel: *gio.Cancellable,
    phase: std.atomic.Value(controller.Phase) = .init(.preparing),
    live: Live = .{},
    searches: usize = 0,
    reads: usize = 0,
    search_mode: enum { success, failed, empty, cancelled } = .success,
    read_fails: bool = false,

    fn write(path: [:0]const u8, bytes: []const u8) !void {
        const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c_uint, 0o700));
        if (fd < 0) return error.FixtureWriteFailed;
        defer _ = std.c.close(fd);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
            if (n <= 0) return error.FixtureWriteFailed;
            offset += @intCast(n);
        }
    }
    fn init(a: std.mem.Allocator, plan: Plan) !Fixture {
        var pattern = "/tmp/pearl-conversation-XXXXXX".*;
        const directory = glib.mkdtemp(&pattern) orelse return error.FixtureDirectoryFailed;
        var self: Fixture = .{
            .a = a,
            .directory = try a.dupeSentinel(u8, std.mem.span(directory), 0),
            .executable = try std.fmt.allocPrintSentinel(a, "{s}/conversation-fixture", .{directory}, 0),
            .plan = try std.fmt.allocPrintSentinel(a, "{s}/conversation-fixture.plan", .{directory}, 0),
            .requests = try std.fmt.allocPrintSentinel(a, "{s}/conversation-fixture.requests.jsonl", .{directory}, 0),
            .release = try std.fmt.allocPrintSentinel(a, "{s}/conversation-fixture.release", .{directory}, 0),
            .model = try std.fmt.allocPrintSentinel(a, "{s}/fixture.gguf", .{directory}, 0),
            .config = .{},
            .cancel = gio.Cancellable.new(),
        };
        errdefer self.deinit();
        var buffer: [32768]u8 = undefined;
        try write(self.executable, try memory.read("tests/integration/agent_conversation_fixture.py", &buffer));
        try write(self.plan, try std.json.Stringify.valueAlloc(a, plan, .{}));
        try write(self.model, "GGUF\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00");
        // No default external provider: only explicit local callbacks can search.
        self.config = .{ .enabled = true, .model_id = "custom", .custom_model = self.model, .providers = &.{}, .runtime = .{ .source = .custom, .executable = self.executable }, .context_tokens = 4096, .answer_tokens = 384 };
        return self;
    }
    fn deinit(self: *Fixture) void {
        self.runtime.stop();
        self.cancel.unref();
        for ([_][:0]const u8{ self.executable, self.plan, self.requests, self.release, self.model }) |path| _ = std.c.unlink(path);
        _ = std.c.rmdir(self.directory);
    }
    fn tools(self: *Fixture) controller.Tools {
        return .{ .context = self, .search = search, .read = read };
    }
    fn search(context: *anyopaque, _: std.mem.Allocator, query: []const u8, cancel: *gio.Cancellable) ![]const controller.Source {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.searches += 1;
        try t.expectEqualStrings("current timetable", query);
        switch (self.search_mode) {
            .success => return &.{source},
            .failed => return error.SearchUnavailable,
            .empty => return &.{},
            .cancelled => {
                cancel.cancel();
                return error.Cancelled;
            },
        }
    }
    fn read(context: *anyopaque, _: std.mem.Allocator, item: controller.Source, _: *gio.Cancellable) ![]const u8 {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.reads += 1;
        try t.expectEqual(@as(u32, 1), item.id);
        try t.expectEqualStrings(source.url, item.url);
        if (self.read_fails) return error.PageUnavailable;
        return "The complete timetable confirms a 47 minute journey.";
    }
    fn run(self: *Fixture, question: []const u8, history: []const controller.Turn, previous: []const controller.Source, local_tools: bool) !controller.Answer {
        return controller.runWithTools(self.a, &self.runtime, self.config, question, history, previous, self.cancel, &self.phase, &self.live, if (local_tools) self.tools() else null);
    }
    fn log(self: *Fixture, kind: []const u8) ![]const Payload {
        const buffer = try self.a.alloc(u8, 2 * 1024 * 1024);
        const bytes = try memory.read(self.requests, buffer);
        var rows: std.ArrayList(Payload) = .empty;
        var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const row = try std.json.parseFromSliceLeaky(Request, self.a, line, .{ .ignore_unknown_fields = true });
            if (std.mem.eql(u8, kind, row.kind)) try rows.append(self.a, row.payload);
        }
        return rows.items;
    }
    fn expectCounts(self: *Fixture, completions: usize, searches: usize, reads: usize) !void {
        try t.expectEqual(completions, (try self.log("completion")).len);
        try t.expectEqual(searches, self.searches);
        try t.expectEqual(reads, self.reads);
        try t.expectEqual(@as(usize, 3), (try self.log("qualification")).len);
    }
};

fn completed(answer: controller.Answer, text: []const u8) !void {
    try t.expectEqual(controller.Outcome.completed, answer.outcome);
    try t.expectEqualStrings(text, answer.text);
    try t.expectEqualStrings("", answer.error_code);
}
fn contains(text: []const u8, needle: []const u8) !void {
    try t.expect(std.mem.indexOf(u8, text, needle) != null);
}
fn toolResult(a: std.mem.Allocator, payload: Payload, index: usize) !std.json.Value {
    const message = payload.messages[index];
    try t.expectEqualStrings("tool", message.role);
    return std.json.parseFromSliceLeaky(std.json.Value, a, message.content, .{});
}
fn expectToolError(a: std.mem.Allocator, payload: Payload, status: []const u8, err: []const u8) !void {
    const result = try toolResult(a, payload, payload.messages.len - 1);
    try t.expectEqualStrings(status, result.object.get("status").?.string);
    try t.expectEqualStrings(err, result.object.get("error").?.string);
    try contains(result.object.get("message").?.string, "do not invent results");
}

test "conversation: ordinary chat and thanks after sourced history never force a search" {
    const cases = [_]struct { question: []const u8, answer: []const u8, sourced: bool = false }{
        .{ .question = "Hello!", .answer = "Hello! How can I help?" },
        .{ .question = "Explain why ice floats.", .answer = "Ice is less dense than liquid water." },
        .{ .question = "Write a tiny poem about rain.", .answer = "Rain taps the sill;\nThe quiet garden drinks." },
        .{ .question = "What is 6 times 7?", .answer = "42." },
        .{ .question = "Thanks!", .answer = "You're welcome!", .sourced = true },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var f = try Fixture.init(arena.allocator(), .{ .replies = &.{.{ .text = case.answer }} });
        defer f.deinit();
        const history: []const controller.Turn = if (case.sourced) &.{.{ .question = "How long is the current journey?", .answer = cited.text }} else &.{};
        const answer = try f.run(case.question, history, if (case.sourced) &.{source} else &.{}, true);
        try completed(answer, case.answer);
        try t.expectEqualStrings("", answer.warning);
        try t.expectEqualStrings("", answer.capability_warning);
        try f.expectCounts(1, 0, 0);
        const requests = try f.log("completion");
        try t.expect(requests[0].tools != null);
        try t.expectEqualStrings(case.question, requests[0].messages[requests[0].messages.len - 1].content);
        if (case.sourced) {
            try t.expectEqual(@as(usize, 1), answer.sources.len);
            try t.expectEqualStrings(cited.text, requests[0].messages[2].content);
            try contains(requests[0].messages[3].content, "Previous search evidence");
        }
    }
}

test "conversation: missing and disabled providers allow chat without advertising tools" {
    for ([_]bool{ false, true }) |disabled| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var f = try Fixture.init(arena.allocator(), .{ .replies = &.{.{ .text = "I can explain the idea without browsing." }} });
        defer f.deinit();
        if (disabled) f.config.providers = &.{.{ .enabled = false }};
        const answer = try f.run("Explain a binary tree.", &.{}, &.{}, false);
        try completed(answer, "I can explain the idea without browsing.");
        try contains(answer.capability_warning, "no enabled search provider");
        try f.expectCounts(1, 0, 0);
        const request = (try f.log("completion"))[0];
        try t.expect(request.tools == null);
        try contains(request.messages[0].content, "No tools are available");
    }
}

test "conversation: current search is cited with matching tools and budget" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, .{ .replies = &.{ search_call, cited } });
    defer f.deinit();
    const answer = try f.run("Check the current journey time.", &.{}, &.{}, true);
    try completed(answer, cited.text);
    try f.expectCounts(2, 1, 0);
    try t.expectEqual(@as(usize, 1), answer.sources.len);
    try t.expectEqualStrings(source.url, answer.sources[0].url);
    try t.expect(controller.citations(answer.text, answer.sources));
    const requests = try f.log("completion");
    try t.expectEqual(@as(usize, 2), requests.len);
    for (requests) |request| {
        try t.expectEqualStrings(try std.json.Stringify.valueAlloc(a, (try llama.toolsForConfig(a, f.config, false)).?, .{}), try std.json.Stringify.valueAlloc(a, request.tools.?, .{}));
        try t.expectEqual(f.config.answerTokens(), request.max_tokens);
    }
    const messages = requests[1].messages;
    try t.expectEqualStrings(search_call.id, messages[2].tool_calls.?[0].id);
    try t.expectEqualStrings(search_call.id, messages[3].tool_call_id.?);
    const result = try toolResult(a, requests[1], 3);
    try t.expectEqual(@as(i64, 1), result.array.items[0].object.get("id").?.integer);
    try t.expectEqualStrings(source.title, result.array.items[0].object.get("title").?.string);
    try t.expectEqualStrings(source.snippet, result.array.items[0].object.get("evidence").?.string);
    try contains(messages[0].content, "Lead with a useful answer");
}

test "conversation: invalid citations receive exactly one correction with tools disabled" {
    for ([_]bool{ false, true }) |still_invalid| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var f = try Fixture.init(arena.allocator(), .{ .replies = &.{ search_call, .{ .text = "Unsupported. [99]" }, if (still_invalid) .{ .text = "Still unsupported. [99]" } else cited } });
        defer f.deinit();
        const answer = try f.run("Verify the current timetable.", &.{}, &.{}, true);
        if (still_invalid) {
            try t.expectEqual(controller.Outcome.partial, answer.outcome);
            try contains(answer.text, "valid source references");
        } else try completed(answer, cited.text);
        try f.expectCounts(3, 1, 0);
        const requests = try f.log("completion");
        try t.expect(requests[1].tools != null);
        try t.expect(requests[2].tools == null);
        try contains(requests[2].messages[requests[2].messages.len - 1].content, "Rewrite that answer");
        try t.expectEqual(@as(usize, 1), answer.sources.len);
    }
}

test "conversation: failed and empty searches yield honest useful answers without forced citations" {
    for ([_]bool{ false, true }) |empty| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const text = if (empty) "No results were returned. Check the station's published timetable before travel." else "Search is unavailable, so I cannot verify today's time. Check the station timetable before travel.";
        var f = try Fixture.init(arena.allocator(), .{ .replies = &.{ search_call, .{ .text = text } } });
        defer f.deinit();
        f.search_mode = if (empty) .empty else .failed;
        const answer = try f.run("Find the current timetable.", &.{}, &.{}, true);
        try completed(answer, text);
        try t.expectEqualStrings(if (empty) "" else "SearchUnavailable", answer.warning);
        try t.expectEqual(@as(usize, 0), answer.sources.len);
        try f.expectCounts(2, 1, 0);
        const request = (try f.log("completion"))[1];
        if (empty) {
            const result = try toolResult(arena.allocator(), request, 3);
            try t.expectEqualStrings("empty", result.object.get("status").?.string);
        } else try expectToolError(arena.allocator(), request, "failed", "SearchUnavailable");
    }
}

test "conversation: page read success failure and permission denial preserve host authority" {
    for ([_]enum { success, failed, disabled }{ .success, .failed, .disabled }) |mode| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const text = if (mode == .success) "The full timetable confirms 47 minutes. [1]" else "I could not read the page. The search snippet says 47 minutes. [1]";
        var f = try Fixture.init(arena.allocator(), .{ .replies = &.{ search_call, read_call, .{ .text = text } } });
        defer f.deinit();
        f.config.read_pages = mode != .disabled;
        f.read_fails = mode == .failed;
        const answer = try f.run("Find and read the current timetable.", &.{}, &.{}, true);
        try completed(answer, text);
        try f.expectCounts(3, 1, if (mode == .disabled) 0 else 1);
        const request = (try f.log("completion"))[2];
        try t.expectEqualStrings(read_call.id, request.messages[5].tool_call_id.?);
        if (mode == .success) {
            try contains(answer.sources[0].text, "complete timetable");
            try t.expectEqualStrings("", answer.warning);
        } else {
            const err = if (mode == .failed) "PageUnavailable" else "PageReadingDisabled";
            try expectToolError(arena.allocator(), request, if (mode == .failed) "failed" else "denied", err);
            try t.expectEqualStrings(err, answer.warning);
            try t.expectEqualStrings("", answer.sources[0].text);
        }
    }
}

test "conversation: chat-only qualification permits chat but never unexpected tool execution" {
    for ([_]bool{ false, true }) |unexpected_call| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const text = "I cannot verify the current timetable, but can help you plan the journey.";
        var f = try Fixture.init(arena.allocator(), .{ .qualification = .chat_only, .replies = &.{if (unexpected_call) search_call else .{ .text = text }} });
        defer f.deinit();
        const answer = try f.run("Find the current timetable.", &.{}, &.{}, true);
        if (unexpected_call) {
            try t.expectEqual(controller.Outcome.failed, answer.outcome);
            try t.expectEqualStrings("ToolsUnavailable", answer.error_code);
            try t.expect(f.runtime.process == null);
        } else {
            try completed(answer, text);
            try t.expect(f.runtime.process != null);
            try t.expect(!f.runtime.tools_available);
        }
        try contains(answer.capability_warning, "Chat-only");
        try f.expectCounts(1, 0, 0);
        try t.expect((try f.log("completion"))[0].tools == null);
    }
}

test "conversation: duplicate normalized tool calls reuse results without executing twice" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var f = try Fixture.init(arena.allocator(), .{ .replies = &.{ search_call, .{ .name = "search_web", .arguments = "{ \"query\" : \" current timetable \" }", .id = "call-2" }, cited } });
    defer f.deinit();
    const answer = try f.run("Check the current timetable.", &.{}, &.{}, true);
    try completed(answer, cited.text);
    try f.expectCounts(3, 1, 0);
    try t.expectEqual(@as(usize, 1), answer.sources.len);
    const request = (try f.log("completion"))[2];
    try t.expectEqualStrings("call-1", request.messages[3].tool_call_id.?);
    try t.expectEqualStrings("call-2", request.messages[5].tool_call_id.?);
    try t.expectEqualStrings(request.messages[3].content, request.messages[5].content);
}

test "conversation: long history is complete then pruned by whole pairs and optional evidence" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Sizes are calibrated against the native byte estimator (content/3 plus
    // template/tool overhead): the first fit prunes the two oldest history
    // pairs, and the post-search fit prunes the newest pair then the evidence.
    // Neither the question nor the call/result pair may ever be clipped.
    var f = try Fixture.init(a, .{ .replies = &.{ search_call, cited } });
    defer f.deinit();
    const question = "Check the current timetable and preserve this entire request: " ++ @as([5000]u8, @splat('q')) ++ " END-QUESTION";
    const previous: controller.Source = .{ .id = 1, .title = "Local timetable", .url = source.url, .snippet = &@as([1000]u8, @splat('s')), .provider = "offline" };
    const history = [_]controller.Turn{
        .{ .question = "oldest question", .answer = @as([5000]u8, @splat('a')) ++ " END-OLDEST" },
        .{ .question = "middle question", .answer = @as([5000]u8, @splat('b')) ++ " END-MIDDLE" },
        .{ .question = "newest question", .answer = @as([1200]u8, @splat('c')) ++ " END-NEWEST" },
    };
    const answer = try f.run(question, &history, &.{previous}, true);
    try completed(answer, cited.text);
    try f.expectCounts(2, 1, 0);
    const requests = try f.log("completion");
    try t.expectEqual(@as(usize, 2), requests.len);
    // First completion keeps only the newest history pair plus the evidence.
    try t.expectEqual(@as(usize, 5), requests[0].messages.len);
    try t.expectEqualStrings("system", requests[0].messages[0].role);
    try t.expectEqualStrings(history[2].question, requests[0].messages[1].content);
    try t.expectEqualStrings(history[2].answer, requests[0].messages[2].content);
    try contains(requests[0].messages[3].content, "Previous search evidence");
    try t.expectEqualStrings(question, requests[0].messages[4].content);
    // Second completion drops the evidence but keeps the call/result pair.
    try t.expectEqual(@as(usize, 4), requests[1].messages.len);
    try t.expectEqualStrings("system", requests[1].messages[0].role);
    try t.expectEqualStrings(question, requests[1].messages[1].content);
    try t.expectEqualStrings("assistant", requests[1].messages[2].role);
    try t.expectEqualStrings(search_call.id, requests[1].messages[2].tool_calls.?[0].id);
    try t.expectEqualStrings("tool", requests[1].messages[3].role);
    try t.expectEqualStrings(search_call.id, requests[1].messages[3].tool_call_id.?);
    const result = try toolResult(a, requests[1], 3);
    try t.expectEqualStrings(previous.snippet, result.array.items[0].object.get("evidence").?.string);
}

test "conversation: context overflow returns an explicit outcome without dropping current tool pairs" {
    for ([_]bool{ false, true }) |after_search| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var f = try Fixture.init(arena.allocator(), .{ .replies = if (after_search) &.{search_call} else &.{} });
        defer f.deinit();
        // Without a search the question alone must exceed the budget; with a
        // search it fits first, then the evidence prompt plus tool result push
        // the second fit over while the call/result pair stays intact.
        var buffer: [9100]u8 = undefined;
        const xs = if (after_search) @as(usize, 7240) else 9000;
        @memset(buffer[0..xs], 'x');
        const question = try std.fmt.allocPrint(arena.allocator(), "Never truncate this question: {s} END", .{buffer[0..xs]});
        const answer = try f.run(question, &.{}, &.{}, true);
        try t.expectEqual(if (after_search) controller.Outcome.partial else .failed, answer.outcome);
        try t.expectEqualStrings("QuestionExceedsContext", answer.error_code);
        try f.expectCounts(if (after_search) 1 else 0, if (after_search) 1 else 0, 0);
        if (after_search) {
            const requests = try f.log("completion");
            try t.expectEqual(@as(usize, 1), requests.len);
            try t.expectEqual(@as(usize, 2), requests[0].messages.len);
            try t.expectEqualStrings(question, requests[0].messages[1].content);
        }
        try t.expect(f.runtime.process == null);
    }
}

const Observer = struct {
    live: *Live,
    cancel: *gio.Cancellable,
    release: [:0]const u8,
    stop: bool,
    observed: bool = false,
    err: ?anyerror = null,
    fn run(self: *Observer) void {
        const deadline = glib.getMonotonicTime() + 4 * std.time.us_per_s;
        while (glib.getMonotonicTime() < deadline) {
            if (self.live.first_visible_us.load(.monotonic) != 0) {
                var buffer: [16384]u8 = undefined;
                var revision: u64 = 0;
                if (self.live.copy(&buffer, &revision)) |text| {
                    self.observed = std.mem.eql(u8, text, "Visible before completion.");
                    if (self.stop) self.cancel.cancel() else Fixture.write(self.release, "release") catch |err| {
                        self.err = err;
                    };
                    return;
                }
            }
            glib.usleep(1000);
        }
        self.err = error.FirstVisibleTimedOut;
        self.cancel.cancel();
    }
};

test "conversation: direct SSE becomes visible before completion and supports in-flight cancellation" {
    for ([_]bool{ false, true }) |stop| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var f = try Fixture.init(arena.allocator(), .{ .replies = &.{.{ .text = "Visible before completion.", .gated = true }} });
        defer f.deinit();
        // Qualification is not part of the bounded first-visible observation.
        try f.runtime.ensure(f.config, f.cancel);
        var observer: Observer = .{ .live = &f.live, .cancel = f.cancel, .release = f.release, .stop = stop };
        const thread = try std.Thread.spawn(.{}, Observer.run, .{&observer});
        const result = f.run("Explain streaming.", &.{}, &.{}, true);
        thread.join();
        if (observer.err) |err| return err;
        try t.expect(observer.observed);
        const answer = try result;
        if (stop) {
            try t.expectEqual(controller.Outcome.cancelled, answer.outcome);
            try t.expectEqualStrings("Response stopped.", answer.text);
            try t.expectEqualStrings("Cancelled", answer.error_code);
            try t.expect(f.runtime.process == null);
        } else try completed(answer, "Visible before completion.");
        try t.expect(f.live.first_visible_us.load(.monotonic) > 0);
        try f.expectCounts(1, 0, 0);
    }
}

test "conversation: truncation is partial and ordinary inference failures are explicit outcomes" {
    for ([_]enum { truncated, http, empty }{ .truncated, .http, .empty }) |mode| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const reply: Reply = switch (mode) {
            .truncated => .{ .text = "An unfinished explanation", .finish = "length" },
            .http => .{ .status = 503 },
            .empty => .{ .text = "" },
        };
        var f = try Fixture.init(arena.allocator(), .{ .replies = &.{reply} });
        defer f.deinit();
        const answer = try f.run("Explain memory.", &.{}, &.{}, true);
        try t.expectEqual(if (mode == .truncated) controller.Outcome.partial else .failed, answer.outcome);
        try t.expectEqualStrings(switch (mode) {
            .truncated => "GenerationTruncated",
            .http => "InferenceFailed",
            .empty => "EmptyAnswer",
        }, answer.error_code);
        if (mode == .truncated) {
            try contains(answer.text, reply.text);
            try contains(answer.text, "Response incomplete");
        }
        try f.expectCounts(1, 0, 0);
        try t.expect(f.runtime.process == null);
    }
}

test "conversation: cancellation at a tool boundary is not converted to a failed tool result" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var f = try Fixture.init(arena.allocator(), .{ .replies = &.{search_call} });
    defer f.deinit();
    f.search_mode = .cancelled;
    const answer = try f.run("Check the current timetable.", &.{}, &.{}, true);
    try t.expectEqual(controller.Outcome.cancelled, answer.outcome);
    try t.expectEqualStrings("Cancelled", answer.error_code);
    try t.expectEqualStrings("", answer.warning);
    try f.expectCounts(1, 1, 0);
}

test "conversation: startup qualification failures remain errors rather than answer outcomes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var f = try Fixture.init(arena.allocator(), .{ .qualification = .failed, .replies = &.{} });
    defer f.deinit();
    try t.expectError(error.ModelChatIncompatible, f.run("Hello!", &.{}, &.{}, true));
    try t.expectEqual(@as(usize, 0), f.searches);
    try t.expectEqual(@as(usize, 0), (try f.log("completion")).len);
    try t.expectEqual(@as(usize, 1), (try f.log("qualification")).len);
    try t.expect(f.runtime.process == null);
}
