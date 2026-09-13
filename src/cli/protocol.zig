//! Pearl control v1 is independent of Aqueous IPC v1. One bounded request/reply.
const std = @import("std");
const e = @import("../aqueous/entities.zig");
pub const Edge = @import("../ui/surfaces/policy.zig").Edge;
pub const max_frame = 8192;
pub const ConnectivityService = enum { network, bluetooth };
pub const ConnectivityAction = enum { scan, connect, connect_saved, disconnect, enable, disable, cancel, pair, trust, untrust, discover, stop_discovery };
pub const SessionAction = enum { dnd_on, dnd_off, clear_history, dismiss, invoke, select, play_pause, play, pause, stop, next, previous, seek, tray_activate, tray_secondary, tray_menu, tray_click };
pub const Op = enum { session_status, session_action, notifications_toggle, media_toggle, tray_toggle, connectivity_status, connectivity_action, status, popup_show, popup_hide, popup_toggle, bar_set, frame_set, osd_show, quit, launcher_show, launcher_hide, launcher_toggle, control_show, control_toggle, calendar_toggle, bar_groups, layout_get, layout_set, overview_toggle, services_status, audio_set, brightness_set, profile_set };
pub const Request = struct {
    pearl: u32 = 1,
    id: []const u8 = "1",
    session: []const u8 = "",
    display: []const u8 = "",
    op: Op,
    command: ?SessionAction = null,
    notification: ?u32 = null,
    position: ?i64 = null,
    menu_id: ?i32 = null,
    revision: ?u64 = null,
    service: ?ConnectivityService = null,
    action: ?ConnectivityAction = null,
    path: ?[]const u8 = null,
    generation: ?u64 = null,
    device: ?u32 = null,
    kind: ?@import("../services/policy.zig").Kind = null,
    volume: ?u8 = null,
    mute: ?bool = null,
    make_default: ?bool = null,
    target: ?u32 = null,
    percent: ?u8 = null,
    profile: ?u8 = null,
    offset: ?u16 = null,
    output: ?[]const u8 = null,
    edge: ?Edge = null,
    size: ?u16 = null,
    text: ?[]const u8 = null,
    duration_ms: ?u32 = null,
    left: ?[]const u8 = null,
    center: ?[]const u8 = null,
    right: ?[]const u8 = null,
    layout: ?[]const u8 = null,
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
            .status, .popup_hide, .launcher_hide, .quit => &[_][]const u8{},
            .notifications_toggle, .media_toggle, .tray_toggle, .popup_show, .popup_toggle, .launcher_show, .launcher_toggle, .control_show, .control_toggle, .calendar_toggle, .overview_toggle, .layout_get => &[_][]const u8{"output"},
            .bar_set, .frame_set => &[_][]const u8{ "output", "edge", "size" },
            .osd_show => &[_][]const u8{ "output", "text", "duration_ms" },
            .bar_groups => &[_][]const u8{ "output", "left", "center", "right" },
            .layout_set => &[_][]const u8{ "output", "layout" },
            .session_status => &[_][]const u8{"offset"},
            .session_action => &[_][]const u8{ "command", "notification", "generation", "position", "menu_id", "revision", "text" },
            .connectivity_status => &[_][]const u8{"offset"},
            .connectivity_action => &[_][]const u8{ "service", "action", "path", "generation" },
            .services_status => &[_][]const u8{"offset"},
            .audio_set => &[_][]const u8{ "generation", "device", "kind", "volume", "mute", "make_default", "target" },
            .brightness_set => &[_][]const u8{"percent"},
            .profile_set => &[_][]const u8{"profile"},
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
        .session_status => if ((r.offset orelse 0) > 64) return error.InvalidRequest,
        .session_action => {
            const c = r.command orelse return error.InvalidRequest;
            const note = c == .dismiss or c == .invoke;
            const player = c == .select or c == .play_pause or c == .play or c == .pause or c == .stop or c == .next or c == .previous or c == .seek;
            const tray = c == .tray_activate or c == .tray_secondary or c == .tray_menu or c == .tray_click;
            if (note != (r.notification != null) or (player or tray) != (r.generation != null) or (c == .seek) != (r.position != null) or (c == .invoke) != (r.text != null) or (c == .tray_click) != (r.revision != null)) return error.InvalidRequest;
            if (r.notification == 0 or r.generation == 0) return error.InvalidRequest;
            if (r.menu_id != null and c != .tray_menu and c != .tray_click) return error.InvalidRequest;
            if (c == .tray_click and r.menu_id == null) return error.InvalidRequest;
            if (r.position) |v| if (v < 0) return error.InvalidRequest;
            if (r.text) |v| if (v.len == 0 or v.len > 96 or std.mem.indexOfScalar(u8, v, 0) != null) return error.InvalidRequest;
        },
        .connectivity_action => {
            const service = r.service orelse return error.InvalidRequest;
            const action = r.action orelse return error.InvalidRequest;
            if (r.generation == null) return error.InvalidRequest;
            if (service == .network and (action == .pair or action == .trust or action == .untrust or action == .discover or action == .stop_discovery)) return error.InvalidRequest;
            if (service == .bluetooth and (action == .scan or action == .connect_saved)) return error.InvalidRequest;
            const needs_path = action != .cancel and action != .stop_discovery and !(service == .network and (action == .enable or action == .disable));
            if (needs_path != (r.path != null)) return error.InvalidRequest;
            if (r.path) |path| {
                if (path.len < 2 or path.len > 512 or path[0] != '/' or path[path.len - 1] == '/' or std.mem.indexOf(u8, path, "//") != null) return error.InvalidRequest;
                for (path) |c| if (!(std.ascii.isAlphanumeric(c) or c == '/' or c == '_')) return error.InvalidRequest;
            }
        },
        .audio_set => {
            const kind = r.kind orelse return error.InvalidRequest;
            if ((r.device == null) != (r.generation == null)) return error.InvalidRequest;
            if (r.device == null and kind != .sink and kind != .source) return error.InvalidRequest;
            if (r.volume == null and r.mute == null and r.make_default == null and r.target == null) return error.InvalidRequest;
            if (r.volume) |v| if (v > 100) return error.InvalidRequest;
            if (r.make_default) |v| if (!v or (kind != .sink and kind != .source)) return error.InvalidRequest;
            if (r.target != null and kind != .playback and kind != .recording) return error.InvalidRequest;
        },
        .brightness_set => if (r.percent == null or r.percent.? > 100) return error.InvalidRequest,
        .profile_set => if (r.profile == null or r.profile.? > 2) return error.InvalidRequest,
        .services_status => if (r.offset != null and r.offset.? > 128) return error.InvalidRequest,
        .bar_groups => {
            if (r.output == null or r.left == null or r.center == null or r.right == null) return error.InvalidRequest;
            try (@import("../desktop/policy.zig").Groups{ .left = r.left.?, .center = r.center.?, .right = r.right.? }).validate();
        },
        .layout_get => if (r.output == null) return error.InvalidRequest,
        .layout_set => {
            if (r.output == null or r.layout == null) return error.InvalidRequest;
            _ = std.meta.stringToEnum(@import("../desktop/policy.zig").Layout, r.layout.?) orelse return error.InvalidRequest;
        },
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
