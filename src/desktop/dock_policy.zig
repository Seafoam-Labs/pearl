//! Pure dock visibility and identity rules. Geometry is global logical Aqueous state.
const std = @import("std");
const e = @import("../aqueous/entities.zig");
const p = @import("../ui/surfaces/policy.zig");
pub const Mode = enum { always, intelligent, autohide };
pub const Config = struct { enabled: bool = true, edge: p.Edge = .bottom, mode: Mode = .intelligent, icon_size: u8 = 40, margin: u8 = 8 };
pub fn validate(c: Config) !void {
    if (c.icon_size < 24 or c.icon_size > 64 or c.margin < 4 or c.margin > 32) return error.InvalidDock;
}
pub fn desktopId(id: []const u8) bool {
    if (id.len < 9 or id.len > 1024 or !std.mem.endsWith(u8, id, ".desktop") or !std.unicode.utf8ValidateSlice(id)) return false;
    var chars = std.unicode.Utf8View.initUnchecked(id).iterator();
    while (chars.nextCodepoint()) |ch| if (ch < 32 or (ch >= 127 and ch <= 159) or ch == '/' or ch == '\\') return false;
    return true;
}
pub fn stem(id: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, id, ".desktop")) id[0 .. id.len - 8] else id;
}
pub fn eligible(window: e.Window, output: []const u8) bool {
    return !window.skip_taskbar and window.output != null and std.mem.eql(u8, window.output.?, output);
}
pub fn overlaps(window: e.Window, output: []const u8, rect: p.Rect) bool {
    if (!window.visible or window.minimized or window.output == null or !std.mem.eql(u8, window.output.?, output)) return false;
    const r = window.outer_geometry;
    return r.width > 0 and r.height > 0 and r.x < @as(i64, rect.x) + rect.width and r.y < @as(i64, rect.y) + rect.height and r.x +| r.width > rect.x and r.y +| r.height > rect.y;
}
pub fn edge(requested: p.Edge, bar: p.Edge) p.Edge {
    if (requested != bar) return requested;
    return switch (bar) {
        .top => .bottom,
        .bottom => .top,
        .left => .right,
        .right => .left,
    };
}
pub const Reason = enum { disabled, locked, empty, fullscreen, autohide, overlap, visible, interaction };
pub fn visibility(config: Config, locked: bool, empty: bool, hover: bool, keyboard: bool, fullscreen: bool, obstructed: bool) Reason {
    if (!config.enabled) return .disabled;
    if (locked) return .locked;
    if (empty) return .empty;
    if (hover or keyboard) return .interaction;
    if (fullscreen) return .fullscreen;
    if (config.mode == .autohide) return .autohide;
    if (config.mode == .intelligent and obstructed) return .overlap;
    return .visible;
}
pub fn shown(reason: Reason) bool {
    return reason == .visible or reason == .interaction;
}
test "dock uses taskbar exclusion, output ownership and visible outer geometry" {
    var w = std.mem.zeroes(e.Window);
    w.output = "o";
    w.can_activate = true;
    try std.testing.expect(eligible(w, "o"));
    w.skip_switcher = true;
    try std.testing.expect(eligible(w, "o"));
    w.skip_taskbar = true;
    try std.testing.expect(!eligible(w, "o"));
    w.outer_geometry = .{ .x = -400, .y = 700, .width = 300, .height = 30 };
    const rect: p.Rect = .{ .x = -300, .y = 690, .width = 100, .height = 30 };
    try std.testing.expect(!overlaps(w, "o", rect));
    w.visible = true;
    try std.testing.expect(overlaps(w, "o", rect));
    w.minimized = true;
    try std.testing.expect(!overlaps(w, "o", rect));
    try std.testing.expectEqual(p.Edge.top, edge(.bottom, .bottom));
}
test "dock hiding gates override interaction and keep non-obscured output visible" {
    const t = std.testing;
    try t.expectEqual(Reason.locked, visibility(.{}, true, false, true, true, false, false));
    try t.expectEqual(Reason.overlap, visibility(.{}, false, false, false, false, false, true));
    try t.expectEqual(Reason.visible, visibility(.{}, false, false, false, false, false, false));
    try t.expectEqual(Reason.interaction, visibility(.{}, false, false, true, false, true, true));
    try t.expectEqual(Reason.autohide, visibility(.{ .mode = .autohide }, false, false, false, false, false, false));
    try t.expect(desktopId("org.example.App.desktop"));
    try t.expect(!desktopId("../App.desktop"));
    try t.expectError(error.InvalidDock, validate(.{ .icon_size = 90 }));
}

test "desktop IDs accept installed names without allowing paths or control characters" {
    for ([_][]const u8{ "Custom App.desktop", "Éditeur 私用.desktop", "a" ** 1016 ++ ".desktop" }) |id| try std.testing.expect(desktopId(id));
    for ([_][]const u8{ "", ".desktop", "App", "App.desktop/other", "../App.desktop", "C:\\App.desktop", "bad\x00.desktop", "bad\n.desktop", "bad\x7f.desktop", "bad\xc2\x85.desktop", "bad\xff.desktop", "a" ** 1017 ++ ".desktop" }) |id| try std.testing.expect(!desktopId(id));
}
