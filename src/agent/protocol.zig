//! The verified shell passes an anonymous same-user socket to its child.
//! There is no ambient/public activation endpoint or prompt in argv.
const std = @import("std");
const intent = @import("intent.zig");
// A question can expand sixfold in JSON; config also carries up to sixteen
// 4096-byte folder paths plus provider/runtime strings (escaped at most twice).
pub const max_frame_bytes = 512 * 1024;
pub const Request = struct {
    agent: u8 = 1,
    id: u64,
    op: enum { configure, ask, @"resume", @"suspend", clear, stop, release_runtime, test_state, test_submit, test_hide },
    config: ?@import("config.zig").Config = null,
    question: []const u8 = "",
    activation: []const u8 = "",
    palette: ?@import("../theme/theme.zig").Palette = null,
};
pub const State = struct { visible: bool, busy: bool, suspended: bool, runtime: bool, conversations: usize, turns: []const @import("controller.zig").Turn, sources: usize, status: []const u8, error_code: []const u8 = "", draft_chars: usize = 0, cpu_retry_available: bool = false };
// enforced_memory remains false for compatibility with existing status clients.
pub const ComputeStatus = struct { busy: bool = false, loaded: bool = false, gpu: bool = false, backend: @import("config.zig").Backend = .auto, layers: u16 = 0, fallback: bool = false, enforced_memory: bool = false };
/// Phase 6 app-open request, child -> shell. It rides a Reply with id 0 on the
/// private authenticated socket; there is no public launch endpoint and no
/// command/argument/URI surface. The shell answers with a narrow Reply whose
/// id is request_id (ok/err only). request_id is chosen by the child and must
/// not be 0; application_id must be a resolved installed desktop-entry id.
pub const LaunchRequest = struct {
    request_id: u64,
    application_id: []const u8,
    pub fn validate(self: LaunchRequest) !void {
        if (self.request_id == 0) return error.InvalidLaunchRequest;
        const id = self.application_id;
        // Same character policy as dock_policy.desktopId, capped at 256 bytes:
        // a desktop id, never a path, command line or URI.
        if (id.len < 9 or id.len > 256 or !std.mem.endsWith(u8, id, ".desktop")) return error.InvalidLaunchRequest;
        if (!std.unicode.utf8ValidateSlice(id)) return error.InvalidLaunchRequest;
        var chars = std.unicode.Utf8View.initUnchecked(id).iterator();
        while (chars.nextCodepoint()) |ch| if (ch < 32 or (ch >= 127 and ch <= 159) or ch == '/' or ch == '\\') return error.InvalidLaunchRequest;
    }
};
pub const Reply = struct { agent: u8 = 1, id: u64, ok: bool = true, err: ?[]const u8 = null, settings: bool = false, compute: ?ComputeStatus = null, state: ?State = null, launch: ?LaunchRequest = null };
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Request {
    try @import("../config/preferences.zig").boundedJson(bytes, max_frame_bytes, 8);
    const request = try std.json.parseFromSliceLeaky(Request, a, bytes, .{});
    if (request.agent != 1 or request.id == 0) return error.InvalidAgentRequest;
    if (request.activation.len > 4096) return error.InvalidAgentRequest;
    if (request.question.len > 0 or request.op == .ask or request.op == .test_submit)
        intent.validateQuestion(request.question) catch return error.InvalidAgentRequest;
    if (request.config) |config| try config.validate();
    if (request.palette) |palette| try @import("../theme/theme.zig").validate(palette);
    return request;
}
test "agent test state exposes CPU recovery without losing partial answers or warnings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state: State = .{
        .visible = true,
        .busy = false,
        .suspended = false,
        .runtime = false,
        .conversations = 1,
        .turns = &.{.{ .question = "Explain this", .answer = "An incomplete draft" }},
        .sources = 0,
        .status = "The selected GPU could not be used.\nA search failed.\nChat-only: tools unavailable.",
        .error_code = @errorName(error.GpuOffloadUnverified),
        .draft_chars = 12,
    };
    try std.testing.expect(!state.cpu_retry_available);
    for ([_]bool{ false, true }) |available| {
        var reply: Reply = .{ .id = 1, .state = state };
        reply.state.?.cpu_retry_available = available;
        const json = try std.json.Stringify.valueAlloc(a, reply, .{});
        const decoded = try std.json.parseFromSliceLeaky(Reply, a, json, .{});
        const saved = decoded.state.?;
        try std.testing.expectEqual(available, saved.cpu_retry_available);
        try std.testing.expectEqualStrings(state.error_code, saved.error_code);
        try std.testing.expectEqualStrings(state.status, saved.status);
        try std.testing.expectEqualStrings(state.turns[0].answer, saved.turns[0].answer);
        try std.testing.expectEqual(state.draft_chars, saved.draft_chars);
    }
}

test "agent activation has bounded questions and a version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidAgentRequest, parse(arena.allocator(), "{\"agent\":2,\"id\":1,\"op\":\"resume\"}"));
    try std.testing.expectError(error.InvalidAgentRequest, parse(arena.allocator(), "{\"id\":1,\"op\":\"ask\",\"question\":\" \"}"));
    try std.testing.expectError(error.InvalidAgentRequest, parse(arena.allocator(), "{\"id\":1,\"op\":\"ask\",\"question\":\"\\u0000\"}"));
}

test "agent protocol preserves long multiline Unicode questions through fragmented frames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const question = try repeated(a, "I would like help with this paragraph.\n日本語 café 🌊\r\n\t\"quoted\" \\ path\n", 64);
    try std.testing.expect(question.len > 2048);
    const json = try std.json.Stringify.valueAlloc(a, Request{ .id = 1, .op = .ask, .question = question }, .{});
    const frame = try std.fmt.allocPrint(a, "{s}\n", .{json});
    var framer = try @import("../aqueous/codec.zig").Framer.init(a, max_frame_bytes);
    defer framer.deinit();
    var offset: usize = 0;
    var received: usize = 0;
    while (offset < frame.len) {
        const part = try framer.push(frame[offset..@min(offset + 17, frame.len)]);
        offset += part.consumed;
        if (part.frame) |bytes| {
            const request = try parse(a, bytes);
            try std.testing.expectEqualStrings(question, request.question);
            received += 1;
        }
    }
    try framer.finish();
    try std.testing.expectEqual(@as(usize, 1), received);
}

test "agent protocol enforces the decoded question byte limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const question = try std.fmt.allocPrint(a, "{s}x", .{try repeated(a, "é", intent.max_query / 2)});
    for ([_]usize{ 2050, intent.max_query, intent.max_query + 1 }) |length| {
        const json = try std.json.Stringify.valueAlloc(a, Request{ .id = 1, .op = .ask, .question = question[0..length] }, .{});
        if (length <= intent.max_query) {
            try std.testing.expectEqualStrings(question[0..length], (try parse(a, json)).question);
        } else try std.testing.expectError(error.InvalidAgentRequest, parse(a, json));
    }
}

test "agent frame budget covers escaped maximum questions and configuration but remains bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = @import("config.zig");
    const path = try repeated(a, "\"", 4096);
    path[0] = '/';
    var folders: [16][]const u8 = undefined;
    for (&folders, 0..) |*folder, i| folder.* = try std.fmt.allocPrint(a, "/{s}{d:0>2}", .{ try repeated(a, "\"", 4093), i });
    var providers: [8]cfg.Provider = undefined;
    for (&providers, 0..) |*provider, i| provider.* = .{
        .id = try std.fmt.allocPrint(a, "provider-{d}", .{i}),
        .name = try repeated(a, "\"", 80),
        .endpoint = try std.fmt.allocPrint(a, "https://example.org/{s}", .{try repeated(a, "a", 1004)}),
        .engine_id = try repeated(a, "\\", 128),
        .language = try repeated(a, "\"", 16),
    };
    const request: Request = .{
        .id = 1,
        .op = .ask,
        .question = try repeated(a, "\x01", intent.max_query),
        .activation = try repeated(a, "\x01", 4096),
        .config = .{
            .runtime = .{ .source = .custom, .executable = path },
            .custom_model = path,
            .compute = .{ .device_id = try repeated(a, "\"", 512) },
            .providers = &providers,
            .default_provider_id = providers[0].id,
            .semantic = .{ .folders = &folders },
        },
        .palette = @import("../theme/theme.zig").dark,
    };
    const json = try std.json.Stringify.valueAlloc(a, request, .{});
    try std.testing.expect(json.len > intent.max_query * 6);
    try std.testing.expect(json.len < max_frame_bytes);
    const decoded = try parse(a, json);
    try std.testing.expectEqualStrings(request.question, decoded.question);
    try std.testing.expectEqualStrings(folders[15], decoded.config.?.semantic.folders[15]);
    var framer = try @import("../aqueous/codec.zig").Framer.init(a, max_frame_bytes);
    defer framer.deinit();
    const framed = try framer.push(try std.fmt.allocPrint(a, "{s}\n", .{json}));
    try std.testing.expectEqualStrings(json, framed.frame.?);
    const oversized = try a.alloc(u8, max_frame_bytes + 1);
    @memset(oversized, ' ');
    try std.testing.expectError(error.InvalidConfig, parse(a, oversized));
    try std.testing.expectError(error.FrameTooLarge, framer.push(oversized));
}

test "launch requests ride zero-id replies and validate resolved desktop ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request: LaunchRequest = .{ .request_id = 7, .application_id = "org.example.App.desktop" };
    try request.validate();
    const json = try std.json.Stringify.valueAlloc(a, Reply{ .id = 0, .launch = request }, .{ .emit_null_optional_fields = false });
    try std.testing.expect(std.mem.indexOf(u8, json, "\"err\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\"") == null);
    const decoded = try std.json.parseFromSliceLeaky(Reply, a, json, .{});
    try std.testing.expectEqual(@as(u64, 0), decoded.id);
    try std.testing.expectEqual(@as(u64, 7), decoded.launch.?.request_id);
    try std.testing.expectEqualStrings(request.application_id, decoded.launch.?.application_id);
    // Replies without the field keep parsing for older children.
    const legacy = try std.json.parseFromSliceLeaky(Reply, a, "{\"agent\":1,\"id\":3,\"ok\":true}", .{});
    try std.testing.expect(legacy.launch == null);
    try (LaunchRequest{ .request_id = 1, .application_id = "a.desktop" }).validate();
    try (LaunchRequest{ .request_id = 1, .application_id = "kde-konsole.desktop" }).validate();
    try (LaunchRequest{ .request_id = 1, .application_id = "caf\u{e9}.desktop" }).validate();
    const longest = try std.fmt.allocPrint(a, "{s}.desktop", .{try repeated(a, "a", 248)});
    try std.testing.expectEqual(@as(usize, 256), longest.len);
    try (LaunchRequest{ .request_id = 1, .application_id = longest }).validate();
    const over = try std.fmt.allocPrint(a, "{s}.desktop", .{try repeated(a, "a", 249)});
    try std.testing.expectError(error.InvalidLaunchRequest, (LaunchRequest{ .request_id = 1, .application_id = over }).validate());
    for ([_][]const u8{ "", ".desktop", "org.example.App", "../escape.desktop", "a\\b.desktop", "line\nbreak.desktop", "\xff.desktop", "a b/../../etc.desktop" }) |bad| {
        try std.testing.expectError(error.InvalidLaunchRequest, (LaunchRequest{ .request_id = 1, .application_id = bad }).validate());
    }
    try std.testing.expectError(error.InvalidLaunchRequest, (LaunchRequest{ .request_id = 0, .application_id = "org.example.App.desktop" }).validate());
}

test "launch results are narrow replies matched by request id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = try std.json.Stringify.valueAlloc(a, Reply{ .id = 7, .ok = false, .err = "LaunchFailed" }, .{ .emit_null_optional_fields = false });
    try std.testing.expect(std.mem.indexOf(u8, json, "\"launch\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"compute\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\"") == null);
    const decoded = try std.json.parseFromSliceLeaky(Reply, a, json, .{});
    try std.testing.expectEqual(@as(u64, 7), decoded.id);
    try std.testing.expect(!decoded.ok);
    try std.testing.expectEqualStrings("LaunchFailed", decoded.err.?);
    try std.testing.expect(decoded.launch == null);
    const ok_json = try std.json.Stringify.valueAlloc(a, Reply{ .id = 9 }, .{ .emit_null_optional_fields = false });
    try std.testing.expect(std.mem.indexOf(u8, ok_json, "\"err\"") == null);
    const ok_decoded = try std.json.parseFromSliceLeaky(Reply, a, ok_json, .{});
    try std.testing.expect(ok_decoded.ok);
    try std.testing.expect(ok_decoded.err == null);
    // A launch request frame stays inside the shared frame budget.
    var framer = try @import("../aqueous/codec.zig").Framer.init(a, max_frame_bytes);
    defer framer.deinit();
    const framed = try framer.push(try std.fmt.allocPrint(a, "{s}\n", .{try std.json.Stringify.valueAlloc(a, Reply{ .id = 0, .launch = .{ .request_id = 1, .application_id = "org.example.App.desktop" } }, .{})}));
    const parsed = try std.json.parseFromSliceLeaky(Reply, a, framed.frame.?, .{});
    try std.testing.expectEqual(@as(u64, 1), parsed.launch.?.request_id);
    try framer.finish();
}

// Test-only hook: the shell host and launch policy live outside the child's
// import graph, so the native agent test build reaches them through here.
// Ignored outside test builds; agent_tests provides their gio/glib imports.
test {
    _ = @import("host.zig");
    _ = @import("applications.zig");
}

fn repeated(a: std.mem.Allocator, text: []const u8, count: usize) ![]u8 {
    const bytes = try a.alloc(u8, text.len * count);
    for (0..count) |i| @memcpy(bytes[i * text.len ..][0..text.len], text);
    return bytes;
}
