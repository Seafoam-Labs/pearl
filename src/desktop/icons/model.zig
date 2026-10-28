//! Desktop policy has no GTK or filesystem dependencies.
const std = @import("std");
pub const sizes = [_]u16{ 32, 48, 64, 96 };
pub const Config = struct {
    enabled: bool = false,
    output: []const u8 = "",
    icon_size: u16 = 48,
    show_hidden: bool = false,
    arrangement: enum { automatic, manual } = .automatic,
    pub fn validate(self: Config) !void {
        if (std.mem.indexOfScalar(u16, &sizes, self.icon_size) == null) return error.InvalidDesktopIconSize;
        if (self.output.len > 128 or !std.unicode.utf8ValidateSlice(self.output)) return error.InvalidDesktopOutput;
        for (self.output) |c| if (c < 32 or c == 127) return error.InvalidDesktopOutput;
    }
};
/// Only the XDG user-dir grammar is accepted; no shell expansion or execution.
/// Missing, disabled and home-valued directories deliberately resolve to null.
pub fn desktopPath(a: std.mem.Allocator, contents: []const u8, home: []const u8) !?[:0]u8 {
    var result: ?[:0]u8 = null;
    errdefer if (result) |p| a.free(p);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "XDG_DESKTOP_DIR=")) continue;
        if (result) |p| a.free(p);
        result = null;
        const value = std.mem.trim(u8, line[16..], " \t");
        if (value.len < 2 or value[0] != '"') continue;
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(a);
        var i: usize = 1;
        if (std.mem.startsWith(u8, value[i..], "$HOME/") or std.mem.startsWith(u8, value[i..], "$HOME\"")) {
            try path.appendSlice(a, home);
            i += 5;
        }
        var valid = false;
        while (i < value.len) : (i += 1) {
            const c = value[i];
            if (c == '"') {
                const tail = std.mem.trim(u8, value[i + 1 ..], " \t");
                valid = tail.len == 0 or tail[0] == '#';
                break;
            }
            if (c == '\\') {
                i += 1;
                if (i == value.len or std.mem.indexOfScalar(u8, "\\\"$`", value[i]) == null) break;
                try path.append(a, value[i]);
            } else {
                if (c == '$' or c == '`' or c < 32) break;
                try path.append(a, c);
            }
        }
        if (!valid or path.items.len == 0 or path.items[0] != '/') continue;
        const normalized = try std.fs.path.resolve(a, &.{path.items});
        defer a.free(normalized);
        if (std.mem.eql(u8, normalized, home) or std.mem.eql(u8, normalized, "/")) continue;
        result = try a.dupeSentinel(u8, normalized, 0);
    }
    return result;
}
pub fn validName(name: []const u8) bool {
    return name.len > 0 and name.len <= 255 and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and std.mem.indexOfScalar(u8, name, '/') == null and std.mem.indexOfScalar(u8, name, 0) == null;
}
pub fn displayText(a: std.mem.Allocator, text: []const u8) ![:0]u8 {
    const result = try a.dupeSentinel(u8, text, 0);
    for (result) |*byte| if (byte.* < 32 or byte.* == 127) {
        byte.* = ' ';
    };
    return result;
}
pub const Selection = struct {
    bits: []bool,
    focus: usize = 0,
    anchor: usize = 0,
    pub fn clear(self: *Selection) void {
        @memset(self.bits, false);
    }
    pub fn select(self: *Selection, index: usize, ctrl: bool, shift: bool) void {
        if (index >= self.bits.len) return;
        self.focus = index;
        if (shift) {
            if (!ctrl) self.clear();
            const anchor = @min(self.anchor, self.bits.len - 1);
            @memset(self.bits[@min(anchor, index) .. @max(anchor, index) + 1], true);
        } else {
            const previous = self.bits[index];
            if (!ctrl) self.clear();
            self.bits[index] = !ctrl or !previous;
            self.anchor = index;
        }
    }
};
test "desktop directory grammar rejects execution and disabled roots" {
    const a = std.testing.allocator;
    const p = (try desktopPath(a, "XDG_DESKTOP_DIR=\"$HOME/Bureau\"", "/home/u")).?;
    defer a.free(p);
    try std.testing.expectEqualStrings("/home/u/Bureau", p);
    for ([_][]const u8{ "", "XDG_DESKTOP_DIR=\"$HOME\"", "XDG_DESKTOP_DIR=\"$HOME/../u\"", "XDG_DESKTOP_DIR=\"$(touch /tmp/x)\"", "XDG_DESKTOP_DIR=\"/tmp/`id`\"", "XDG_DESKTOP_DIR=\"/\"" }) |input| try std.testing.expectEqual(@as(?[:0]u8, null), try desktopPath(a, input, "/home/u"));
}
test "selection range toggle and names" {
    var bits = @as([5]bool, @splat(false));
    var s: Selection = .{ .bits = &bits };
    s.select(1, false, false);
    s.select(3, false, true);
    try std.testing.expectEqualSlices(bool, &.{ false, true, true, true, false }, &bits);
    s.select(2, true, false);
    try std.testing.expect(!bits[2]);
    try std.testing.expect(!validName("../bad"));
    try std.testing.expect(validName("a $ b.txt"));
}

test "desktop configuration validates sizes and keeps disconnected connectors" {
    try (Config{ .output = "disconnected-DP-4", .icon_size = 96 }).validate();
    try std.testing.expectError(error.InvalidDesktopIconSize, (Config{ .icon_size = 49 }).validate());
    try std.testing.expectError(error.InvalidDesktopOutput, (Config{ .output = "DP-1\n" }).validate());
    const display = try displayText(std.testing.allocator, "line\nname\t.txt");
    defer std.testing.allocator.free(display);
    try std.testing.expectEqualStrings("line name .txt", display);
}
