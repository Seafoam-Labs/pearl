//! Pure desktop selection, ranking and bar configuration. Runtime IDs stay opaque.
const std = @import("std");
const Window = @import("../aqueous/entities.zig").Window;
pub const Layout = enum { tile, monocle, grid, rows, dwindle, @"reverse-dwindle", scrolling, float, @"game-mode", composable };
pub const Item = enum { launcher, workspaces, title, clock, keyboard, overview, control, audio, battery };
pub const Groups = struct {
    left: []const u8 = "launcher,workspaces,title",
    center: []const u8 = "clock",
    right: []const u8 = "audio,battery,keyboard,overview,control",
    pub fn validate(self: Groups) !void {
        var seen = std.EnumSet(Item).initEmpty();
        for ([_][]const u8{ self.left, self.center, self.right }) |group| {
            if (group.len > 128) return error.InvalidGroups;
            if (group.len == 0) continue;
            var parts = std.mem.splitScalar(u8, group, ',');
            while (parts.next()) |part| {
                const item = std.meta.stringToEnum(Item, part) orelse return error.InvalidGroups;
                if (seen.contains(item)) return error.InvalidGroups;
                seen.insert(item);
            }
        }
        if (!seen.contains(.launcher)) return error.InvalidGroups;
    }
};
pub fn eligible(w: Window) bool {
    // Hidden workspaces and minimized windows remain discoverable, with explicit
    // state subtitles; the compositor's switcher exclusion remains authoritative.
    return !w.skip_switcher and w.can_activate;
}
/// Inputs are Unicode-casefolded once by the GIO worker. All query words must match.
pub fn score(query: []const u8, name: []const u8, keywords: []const u8, recent: bool, running: bool, visible: bool) ?i32 {
    if (query.len == 0) return (if (recent) @as(i32, 200) else 0) + (if (running) @as(i32, 100) else 0) + (if (visible) @as(i32, 10) else 0);
    var result: i32 = 0;
    var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (words.next()) |word| {
        if (std.mem.eql(u8, name, word)) result += 1000 else if (std.mem.startsWith(u8, name, word)) result += 700 else if (std.mem.indexOf(u8, name, word) != null) result += 400 else if (std.mem.indexOf(u8, keywords, word) != null) result += 100 else return null;
    }
    return result + (if (running) @as(i32, 20) else 0) + (if (recent) @as(i32, 10) else 0);
}
test "bar groups reject duplicate, unknown and missing primary controls" {
    try (Groups{}).validate();
    try std.testing.expectError(error.InvalidGroups, (Groups{ .right = "clock" }).validate());
    try std.testing.expectError(error.InvalidGroups, (Groups{ .left = "workspaces" }).validate());
    try std.testing.expectError(error.InvalidGroups, (Groups{ .center = "weather" }).validate());
}
test "ranking favors exact names and recent empty-query entries without conflating IDs" {
    try std.testing.expect(score("term", "term", "", false, false, false).? > score("term", "terminal", "", false, false, false).?);
    try std.testing.expect(score("photo edit", "photos", "image editor", false, false, false) != null);
    try std.testing.expect(score("photo music", "photos", "image editor", false, false, false) == null);
    try std.testing.expect(score("", "z", "", true, false, false).? > score("", "a", "", false, false, false).?);
}

test "launcher respects switcher policy and represents minimized windows separately from visibility" {
    var window = std.mem.zeroes(Window);
    window.can_activate = true;
    window.minimized = true;
    window.visible = false;
    try std.testing.expect(eligible(window));
    window.skip_taskbar = true;
    try std.testing.expect(eligible(window));
    window.skip_switcher = true;
    try std.testing.expect(!eligible(window));
    window.skip_switcher = false;
    window.can_activate = false;
    try std.testing.expect(!eligible(window));
}
