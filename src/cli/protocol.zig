//! Pearl control v1 is independent of Aqueous IPC v1. One bounded request/reply.
const std = @import("std");
const e = @import("../aqueous/entities.zig");
pub const Edge = @import("../ui/surfaces/policy.zig").Edge;
pub const max_frame = 8192;
pub const Op = enum { status, popup_show, popup_hide, popup_toggle, bar_set, frame_set, osd_show, quit };
pub const Request = struct {
    pearl: u32 = 1,
    id: []const u8 = "1",
    session: []const u8 = "",
    display: []const u8 = "",
    op: Op,
    output: ?[]const u8 = null,
    edge: ?Edge = null,
    size: ?u16 = null,
    text: ?[]const u8 = null,
    duration_ms: ?u32 = null,
};
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Request {
    if (bytes.len == 0 or bytes.len > max_frame or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidRequest;
    // Reject nesting before constructing a JSON DOM.
    var string = false;
    var escaped = false;
    var depth: usize = 0;
    for (bytes) |ch| {
        if (string) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                string = false;
            }
        } else switch (ch) {
            '"' => string = true,
            '[' => return error.InvalidRequest,
            '{' => {
                depth += 1;
                if (depth > 1) return error.InvalidRequest;
            },
            '}' => {
                if (depth == 0) return error.InvalidRequest;
                depth -= 1;
            },
            else => {},
        }
    }
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .max_value_len = max_frame });
    if (value != .object) return error.InvalidRequest;
    for ([_][]const u8{ "pearl", "id", "session", "display", "op" }) |name| if (!value.object.contains(name)) return error.InvalidRequest;
    const r = try e.read(Request, a, value);
    if (r.pearl != 1) return error.Version;
    try e.decimal(r.id);
    try e.sessionToken(r.session);
    if (r.display.len == 0 or r.display.len > 4096 or std.mem.indexOfScalar(u8, r.display, 0) != null) return error.InvalidRequest;
    var it = value.object.iterator();
    while (it.next()) |field| {
        const key = field.key_ptr.*;
        if (std.mem.eql(u8, key, "pearl") or std.mem.eql(u8, key, "id") or std.mem.eql(u8, key, "session") or std.mem.eql(u8, key, "display") or std.mem.eql(u8, key, "op")) continue;
        const allowed = switch (r.op) {
            .status, .popup_hide, .quit => &[_][]const u8{},
            .popup_show, .popup_toggle => &[_][]const u8{"output"},
            .bar_set, .frame_set => &[_][]const u8{ "output", "edge", "size" },
            .osd_show => &[_][]const u8{ "output", "text", "duration_ms" },
        };
        var found = false;
        for (allowed) |name| if (std.mem.eql(u8, key, name)) {
            found = true;
            break;
        };
        if (!found) return error.InvalidRequest;
    }
    if (r.output) |id| if (id.len == 0 or id.len > 1024 or std.mem.indexOfScalar(u8, id, 0) != null) return error.InvalidRequest;
    switch (r.op) {
        .bar_set, .frame_set => {
            if (r.output == null or r.edge == null or r.size == null) return error.InvalidRequest;
            if (r.size.? > 160 or (r.op == .bar_set and r.size.? < 32)) return error.InvalidRequest;
        },
        .osd_show => {
            const message = r.text orelse return error.InvalidRequest;
            if (message.len == 0 or message.len > 512 or std.mem.indexOfScalar(u8, message, 0) != null) return error.InvalidRequest;
            if (r.duration_ms) |ms| if (ms < 100 or ms > 10000) return error.InvalidRequest;
        },
        else => {},
    }
    return r;
}
pub fn displayPath(a: std.mem.Allocator, runtime: []const u8, display: []const u8) ![:0]u8 {
    if (display.len == 0 or std.mem.indexOfScalar(u8, display, 0) != null) return error.InvalidDisplay;
    if (display[0] == '/') {
        const normalized = try std.fs.path.resolve(a, &.{display});
        defer a.free(normalized);
        return a.dupeZ(u8, normalized);
    }
    if (std.mem.indexOfScalar(u8, display, '/') != null or std.mem.eql(u8, display, ".") or std.mem.eql(u8, display, "..")) return error.InvalidDisplay;
    return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ runtime, display }, 0);
}
pub fn endpoint(a: std.mem.Allocator, runtime: []const u8, session: []const u8) ![:0]u8 {
    try e.sessionToken(session);
    const result = try std.fmt.allocPrintSentinel(a, "{s}/pearl/{s}/control.sock", .{ runtime, session }, 0);
    errdefer a.free(result);
    if (result.len >= 108) return error.InvalidEndpoint;
    return result;
}

test "control schema rejects malformed, nested, unversioned and oversized requests" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = "\"id\":\"7\",\"session\":\"0123456789abcdef0123456789abcdef\",\"display\":\"/run/user/1/wayland-1\",\"op\":\"status\"";
    const valid = try parse(a, "{\"pearl\":1," ++ prefix ++ "}");
    try t.expectEqualStrings("7", valid.id);
    try t.expectError(error.Version, parse(a, "{\"pearl\":2," ++ prefix ++ "}"));
    try t.expectError(error.InvalidRequest, parse(a, "{" ++ prefix ++ "}"));
    try t.expectError(error.InvalidRequest, parse(a, "{\"pearl\":1," ++ prefix ++ ",\"extra\":true}"));
    try t.expectError(error.InvalidRequest, parse(a, "{\"pearl\":1," ++ prefix ++ ",\"extra\":{\"deep\":[]}}"));
    try t.expectError(error.InvalidRequest, parse(a, "\xff"));
    try t.expectError(error.InvalidRequest, parse(a, " " ** (max_frame + 1)));
    if (parse(a, "{\"pearl\":\"1\"," ++ prefix ++ "}")) |_| return error.AcceptedWrongType else |_| {}
    if (parse(a, "{\"pearl\":1,\"pearl\":1," ++ prefix ++ "}")) |_| return error.AcceptedDuplicateField else |_| {}
}

test "control fields have operation-specific bounds and endpoint identity is normalized" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Request = .{ .op = .bar_set, .session = "0123456789abcdef0123456789abcdef", .display = "/run/user/1/wayland-1", .output = "output:1", .edge = .left, .size = 32 };
    _ = try parse(a, try std.json.Stringify.valueAlloc(a, r, .{ .emit_null_optional_fields = false }));
    r.size = 31;
    try t.expectError(error.InvalidRequest, parse(a, try std.json.Stringify.valueAlloc(a, r, .{ .emit_null_optional_fields = false })));
    r.op = .frame_set;
    r.size = 0;
    _ = try parse(a, try std.json.Stringify.valueAlloc(a, r, .{ .emit_null_optional_fields = false }));
    r.size = 161;
    try t.expectError(error.InvalidRequest, parse(a, try std.json.Stringify.valueAlloc(a, r, .{ .emit_null_optional_fields = false })));
    r = .{ .op = .osd_show, .session = r.session, .display = r.display, .text = "test", .duration_ms = 10001 };
    try t.expectError(error.InvalidRequest, parse(a, try std.json.Stringify.valueAlloc(a, r, .{ .emit_null_optional_fields = false })));
    r.duration_ms = 100;
    r.text = "x" ** 513;
    try t.expectError(error.InvalidRequest, parse(a, try std.json.Stringify.valueAlloc(a, r, .{ .emit_null_optional_fields = false })));
    try t.expectEqualStrings("/run/user/1/wayland-1", try displayPath(a, "/run/user/1", "wayland-1"));
    try t.expectEqualStrings("/run/user/1/wayland-1", try displayPath(a, "/unused", "/run/user/1/./wayland-1"));
    try t.expectError(error.InvalidDisplay, displayPath(a, "/run/user/1", "../wayland-1"));
    try t.expectError(error.InvalidEndpoint, endpoint(a, "/" ++ "x" ** 90, r.session));
}
