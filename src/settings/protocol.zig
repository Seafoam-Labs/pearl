//! Settings frontend v1. S1 implements only hello/ping; editor capabilities are
//! enabled individually as their backend adapters land. See docs/SETTINGS_FRONTEND_API.md.
const std = @import("std");
const entities = @import("../aqueous/entities.zig");
const control = @import("../cli/protocol.zig");
pub const navigation = @import("../desktop/settings_navigation.zig");
pub const version = 1;
pub const Limits = struct {
    frame_bytes: usize = 256 * 1024,
    handshake_bytes: usize = 8192,
    document_chunk_bytes: usize = 32 * 1024,
    pearl_document_bytes: usize = @import("../config/preferences.zig").max_bytes,
    aqueous_request_bytes: usize = @import("../config/aqueous_model.zig").max_request,
    aqueous_response_bytes: usize = @import("../config/aqueous_model.zig").max_response,
    document_chunks: usize = 512,
    list_items: usize = 16,
    list_pages: usize = 8,
    connections: usize = 8,
    queued_frames: usize = 1,
    handshake_ms: c_uint = 5000,
    idle_ms: c_uint = 45000,
    heartbeat_ms: c_uint = 15000,
    transfer_ms: c_uint = 30000,
};
pub const Capabilities = struct {
    handshake: bool = true,
    committed_appearance: bool = false,
    page_snapshots: bool = false,
    pearl_draft: bool = false,
    aqueous_draft: bool = false,
    live_controls: bool = false,
    prompts: bool = false,
    display_preview: bool = false,
    community_themes: bool = false,
};
pub const Request = struct {
    settings: u32,
    id: []const u8,
    session: []const u8,
    display: []const u8,
    op: enum { hello, ping, @"theme.start", @"theme.get", @"theme.cancel", @"qt.retry", @"qt.review", @"qt.reapply", @"page.enter", @"page.leave", @"page.get", @"document.get", @"document.read", @"document.begin", @"document.write", @"document.finish", @"document.cancel", @"draft.discard", @"draft.merge", @"draft.validate", @"draft.apply", @"operation.get", @"frontend.close", @"list.get", @"plugin.refresh", @"plugin.action", @"audio.set", @"brightness.set", @"profile.set", @"network.action", @"network.editor", @"bluetooth.action", @"prompt.answer", @"notifications.action", @"lifecycle.action", @"power.action", @"media.action", @"layout.get", @"layout.set", @"aqueous.get", @"aqueous.action" },
    epoch: ?[]const u8 = null,
    params: ?std.json.Value = null,
};
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Request {
    @import("../config/preferences.zig").boundedJson(bytes, (Limits{}).frame_bytes, 4) catch return error.InvalidRequest;
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidRequest;
    if (value != .object) return error.InvalidRequest;
    for ([_][]const u8{ "settings", "id", "session", "display", "op" }) |key| if (!value.object.contains(key)) return error.InvalidRequest;
    var it = value.object.iterator();
    while (it.next()) |field| {
        inline for (@typeInfo(Request).@"struct".fields) |known| {
            if (std.mem.eql(u8, known.name, field.key_ptr.*)) break;
        } else return error.InvalidRequest;
    }
    const Header = struct { settings: u32, id: []const u8, session: []const u8, display: []const u8, op: @FieldType(Request, "op"), epoch: ?[]const u8 = null };
    const h = entities.read(Header, a, value) catch return error.InvalidRequest;
    const request: Request = .{ .settings = h.settings, .id = h.id, .session = h.session, .display = h.display, .op = h.op, .epoch = h.epoch, .params = value.object.get("params") };
    if (request.settings != version) return error.Version;
    entities.decimal(request.id) catch return error.InvalidRequest;
    if ((std.fmt.parseInt(u64, request.id, 10) catch return error.InvalidRequest) == 0) return error.InvalidRequest;
    entities.sessionToken(request.session) catch return error.InvalidRequest;
    if (request.display.len == 0 or request.display.len > 4096 or request.display[0] != '/' or std.mem.indexOfScalar(u8, request.display, 0) != null) return error.InvalidRequest;
    if (request.op == .hello or request.op == .ping) {
        if (value.object.count() != 5 or bytes.len > (Limits{}).handshake_bytes) return error.InvalidRequest;
    } else {
        if (value.object.count() != 7 or request.params == null or request.params.? != .object) return error.InvalidRequest;
        entities.sessionToken(request.epoch orelse return error.InvalidRequest) catch return error.InvalidRequest;
    }
    return request;
}
pub fn endpoint(a: std.mem.Allocator, runtime: []const u8, session: []const u8) ![:0]u8 {
    const ctl = try control.endpoint(a, runtime, session);
    defer a.free(ctl);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/settings.sock", .{std.fs.path.dirname(ctl).?}, 0);
    errdefer a.free(path);
    if (path.len >= 108) return error.InvalidEndpoint;
    return path;
}
/// Connection-local handshake gate. It does not confer mutation permission:
/// each adapter must additionally enforce live session, lock and service guards.
pub const Connection = struct {
    ready: bool = false,
    last_id: u64 = 0,
    pub fn accept(self: *Connection, r: Request, session: []const u8, display: []const u8) !void {
        if (!std.mem.eql(u8, session, r.session)) return error.StaleSession;
        if (!std.mem.eql(u8, display, r.display)) return error.DisplayMismatch;
        const id = try std.fmt.parseInt(u64, r.id, 10);
        if (id <= self.last_id) return error.StaleRequest;
        if (!self.ready and r.op != .hello) return error.HandshakeRequired;
        if (self.ready and r.op == .hello) return error.AlreadyInitialized;
        self.ready = true;
        self.last_id = id;
    }
};

test "settings handshake rejects malformed fields and versions before connection state changes" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const suffix = ",\"id\":\"1\",\"session\":\"0123456789abcdef0123456789abcdef\",\"display\":\"/tmp/wayland-1\",\"op\":\"hello\"}";
    const valid = "{\"settings\":1" ++ suffix;
    _ = try parse(a, valid);
    try t.expectError(error.Version, parse(a, "{\"settings\":2" ++ suffix));
    for ([_][]const u8{ "{\"settings\":\"1\"" ++ suffix, "{\"extra\":1,\"settings\":1" ++ suffix, "{\"settings\":1,\"settings\":1" ++ suffix, "[]", "{}", " " ** 8193 }) |bad| try t.expectError(error.InvalidRequest, parse(a, bad));
    for ([_][]const u8{ "0", "-1", "18446744073709551616" }) |id| {
        const bad = try std.json.Stringify.valueAlloc(a, Request{ .settings = 1, .id = id, .session = "0123456789abcdef0123456789abcdef", .display = "/tmp/wayland-1", .op = .hello }, .{ .emit_null_optional_fields = false });
        try t.expectError(error.InvalidRequest, parse(a, bad));
    }
}

test "settings requires hello, isolates sessions and displays, and rejects repeated IDs" {
    const t = std.testing;
    var state: Connection = .{};
    var r: Request = .{ .settings = 1, .id = "1", .session = "0123456789abcdef0123456789abcdef", .display = "/tmp/wayland-1", .op = .ping };
    try t.expectError(error.HandshakeRequired, state.accept(r, r.session, r.display));
    r.op = .hello;
    try t.expectError(error.StaleSession, state.accept(r, "fedcba9876543210fedcba9876543210", r.display));
    try t.expectError(error.DisplayMismatch, state.accept(r, r.session, "/tmp/wayland-2"));
    try t.expect(!state.ready);
    try state.accept(r, r.session, r.display);
    r.op = .ping;
    try t.expectError(error.StaleRequest, state.accept(r, r.session, r.display));
    r.id = "2";
    try state.accept(r, r.session, r.display);
    r.id = "3";
    r.op = .hello;
    try t.expectError(error.AlreadyInitialized, state.accept(r, r.session, r.display));
}

test "settings endpoint is distinct and document budgets cover existing complete models" {
    const t = std.testing;
    const path = try endpoint(t.allocator, "/tmp/r", "0123456789abcdef0123456789abcdef");
    defer t.allocator.free(path);
    try t.expectEqualStrings("/tmp/r/pearl/0123456789abcdef0123456789abcdef/settings.sock", path);
    try t.expectError(error.InvalidEndpoint, endpoint(t.allocator, "/" ++ "x" ** 90, "0123456789abcdef0123456789abcdef"));
    const limits: Limits = .{};
    try t.expectEqual(limits.aqueous_response_bytes, limits.document_chunks * limits.document_chunk_bytes);
    // JSON's worst-case escaping still fits a full transfer chunk in one frame.
    try t.expect(limits.document_chunk_bytes * 6 + 8192 < limits.frame_bytes);
}
