//! Bounded style tokens and a small component CSS grammar; no arbitrary CSS rewriting.
const std = @import("std");
const model = @import("package_model.zig");
pub const Tokens = struct {
    card_radius: ?u8 = null,
    control_radius: ?u8 = null,
    border_width: ?u8 = null,
    padding: ?u8 = null,
    padding_x: ?u8 = null,
    padding_y: ?u8 = null,
    title_scale_percent: ?u8 = null,
    shadow: ?struct { x: i8 = 0, y: i8 = 2, blur: u8 = 8, spread: u8 = 0, opacity_percent: u8 = 20 } = null,
    motion_ms: ?u16 = null,
    pub fn validate(self: Tokens) !void {
        if ((self.card_radius orelse 0) > 40 or (self.control_radius orelse 0) > 40 or (self.border_width orelse 0) > 4 or (self.padding orelse 0) > 32 or (self.motion_ms orelse 0) > 1000) return error.InvalidStyleToken;
        if ((self.padding_x orelse 0) > 32 or (self.padding_y orelse 0) > 32) return error.InvalidStyleToken;
        if (self.title_scale_percent) |v| if (v < 80 or v > 160) return error.InvalidStyleToken;
        if (self.shadow) |s| if (s.x < -16 or s.x > 16 or s.y < -16 or s.y > 16 or s.blur > 32 or s.spread > 8 or s.opacity_percent > 40) return error.InvalidStyleToken;
    }
};
pub fn tokenCss(a: std.mem.Allocator, t: Tokens, reduced: bool) ![]const u8 {
    try t.validate();
    var out: std.ArrayList(u8) = .empty;
    if (t.card_radius) |v| try appendPrint(a, &out, ".pearl-root.$scope .pearl-card, .pearl-root.$scope .settings-card {{ border-radius: {d}px; }}\n", .{v});
    if (t.control_radius) |v| try appendPrint(a, &out, ".pearl-root.$scope button, .pearl-root.$scope entry {{ border-radius: {d}px; }}\n", .{v});
    if (t.border_width) |v| try appendPrint(a, &out, ".pearl-root.$scope button, .pearl-root.$scope .pearl-card, .pearl-root.$scope .settings-card {{ border-width: {d}px; border-style: solid; }}\n", .{v});
    if (t.padding) |v| try appendPrint(a, &out, ".pearl-root.$scope:not(.pearl-compact) .pearl-card {{ padding: {d}px; }}\n", .{v});
    if (t.padding_x) |v| try appendPrint(a, &out, ".pearl-root.$scope:not(.pearl-compact) .pearl-card {{ padding-left: {d}px; padding-right: {d}px; }}\n", .{ v, v });
    if (t.padding_y) |v| try appendPrint(a, &out, ".pearl-root.$scope:not(.pearl-compact) .pearl-card {{ padding-top: {d}px; padding-bottom: {d}px; }}\n", .{ v, v });
    if (t.title_scale_percent) |v| try appendPrint(a, &out, ".pearl-root.$scope .pearl-card-title {{ font-size: {d}%; }}\n", .{v});
    if (t.shadow) |s| try appendPrint(a, &out, ".pearl-root.$scope .pearl-card, .pearl-root.$scope .settings-card {{ box-shadow: {d}px {d}px {d}px {d}px alpha($surface$, 0.{d:0>2}); }}\n", .{ s.x, s.y, s.blur, s.spread, s.opacity_percent });
    if (t.motion_ms) |v| try appendPrint(a, &out, ".pearl-root.$scope button {{ transition-duration: {d}ms; }}\n", .{if (reduced) @as(u16, 0) else v});
    return out.toOwnedSlice(a);
}
fn appendPrint(a: std.mem.Allocator, out: *std.ArrayList(u8), comptime format: []const u8, args: anytype) !void {
    const value = try std.fmt.allocPrint(a, format, args);
    defer a.free(value);
    try out.appendSlice(a, value);
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \r\n\t");
}
fn one(s: []const u8, choices: []const []const u8) bool {
    for (choices) |v| if (std.mem.eql(u8, v, s)) return true;
    return false;
}
/// Imports are expanded from the immutable package file list, never GTK's
/// filesystem/network resolver. Only quoted package-relative CSS is accepted.
pub fn compileFiles(a: std.mem.Allocator, files: anytype, path: []const u8) ![]const u8 {
    var stack: [4][]const u8 = undefined;
    var bytes: usize = 0;
    return expand(a, files, path, &stack, 0, &bytes);
}
fn expand(a: std.mem.Allocator, files: anytype, path: []const u8, stack: *[4][]const u8, depth: usize, bytes: *usize) anyerror![]const u8 {
    try model.relative(path);
    if (depth >= stack.len) return error.ThemeCssImportDepth;
    for (stack[0..depth]) |old| if (std.mem.eql(u8, old, path)) return error.ThemeCssImportCycle;
    stack[depth] = path;
    var source: ?[]const u8 = null;
    for (files) |file| if (std.mem.eql(u8, path, file.path)) {
        source = file.bytes;
        break;
    };
    var rest = trim(source orelse return error.ThemeAssetMissing);
    bytes.* += rest.len;
    if (bytes.* > 2048) return error.ThemeCssTooLarge;
    var out: std.ArrayList(u8) = .empty;
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "@import ")) {
            const spec = trim(rest[8..]);
            if (spec.len == 0 or spec[0] != '"') return error.InvalidThemeCssImport;
            const end = std.mem.indexOfScalarPos(u8, spec, 1, '"') orelse return error.InvalidThemeCssImport;
            const relative = spec[1..end];
            try model.relative(relative);
            const tail = trim(spec[end + 1 ..]);
            if (tail.len == 0 or tail[0] != ';') return error.InvalidThemeCssImport;
            const imported = if (std.fs.path.dirname(path)) |dir| try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, relative }) else relative;
            try out.appendSlice(a, try expand(a, files, imported, stack, depth + 1, bytes));
            rest = trim(tail[1..]);
        } else {
            const end = std.mem.indexOfScalar(u8, rest, '}') orelse return error.InvalidThemeCss;
            try out.appendSlice(a, try compile(a, rest[0 .. end + 1]));
            rest = trim(rest[end + 1 ..]);
        }
        if (out.items.len > 3072) return error.ThemeCssTooLarge;
    }
    return out.toOwnedSlice(a);
}
/// Input selectors are component names; compilation constructs every scoped branch.
/// Only paint, border and radius properties are allowed; authentication never uses it.
pub fn compile(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    if (source.len > 2048) return error.ThemeCssTooLarge;
    var rest = trim(source);
    var out: std.ArrayList(u8) = .empty;
    while (rest.len > 0) {
        const open = std.mem.indexOfScalar(u8, rest, '{') orelse return error.InvalidThemeCss;
        const end = std.mem.indexOfScalarPos(u8, rest, open + 1, '}') orelse return error.InvalidThemeCss;
        var selectors = std.mem.splitScalar(u8, rest[0..open], ',');
        var count: usize = 0;
        while (selectors.next()) |selector| {
            const s = trim(selector);
            var parts = std.mem.splitScalar(u8, s, ':');
            if (!one(parts.next().?, &.{ "button", "entry", ".pearl-card", ".pearl-island", ".pearl-dock", ".pearl-tile" })) return error.UnsupportedThemeSelector;
            if (parts.next()) |state| if (!one(state, &.{ "hover", "active", "checked", "disabled", "focus-visible" }) or parts.next() != null) return error.UnsupportedThemeSelector;
            if (count > 0) try out.append(a, ',');
            try out.appendSlice(a, ".pearl-root.$scope ");
            try out.appendSlice(a, s);
            count += 1;
        }
        try out.append(a, '{');
        var declarations = std.mem.splitScalar(u8, rest[open + 1 .. end], ';');
        while (declarations.next()) |declaration| {
            const d = trim(declaration);
            if (d.len == 0) continue;
            const sep = std.mem.indexOfScalar(u8, d, ':') orelse return error.InvalidThemeCss;
            const key = trim(d[0..sep]);
            const value = trim(d[sep + 1 ..]);
            if (one(key, &.{ "color", "background-color", "border-color" })) {
                var valid = @import("../config/preferences.zig").hex(value);
                inline for (@typeInfo(@import("theme.zig").Palette).@"struct".fields) |field| {
                    if (std.mem.eql(u8, value, "$" ++ field.name ++ "$")) valid = true;
                }
                if (!valid) return error.InvalidThemeCssColor;
            } else if (one(key, &.{ "border-radius", "border-width" })) {
                if (!std.mem.endsWith(u8, value, "px")) return error.InvalidThemeCssDimension;
                const v = std.fmt.parseInt(u8, value[0 .. value.len - 2], 10) catch return error.InvalidThemeCssDimension;
                if (v > 32 or (std.mem.eql(u8, key, "border-width") and v > 4)) return error.InvalidThemeCssDimension;
            } else if (std.mem.eql(u8, key, "border-style")) {
                if (!one(value, &.{ "solid", "dashed", "none" })) return error.InvalidThemeCss;
            } else return error.UnsupportedThemeCssProperty;
            try out.appendSlice(a, key);
            try out.append(a, ':');
            try out.appendSlice(a, value);
            try out.append(a, ';');
        }
        try out.append(a, '}');
        rest = trim(rest[end + 1 ..]);
    }
    if (out.items.len > 3072) return error.ThemeCssTooLarge;
    return out.toOwnedSlice(a);
}
test "community CSS constructs scope for every selector and rejects global/asset/layout escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sheet = try compile(a, "button:hover, entry { color: $text$; border-radius: 4px; }");
    try std.testing.expect(std.mem.indexOf(u8, sheet, ",.pearl-root.$scope entry") != null);
    for ([_][]const u8{ "*{color:#ffffff}", "button{background-color:url(x)}", "@import 'x';", "button{opacity:0}", "button{border-radius:33px}", "button, window{color:#ffffff}" }) |bad| {
        if (compile(a, bad)) |_| return error.ExpectedRejection else |_| {}
    }
}
test "theme CSS imports resolve package assets and reject cycles and escape paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const File = struct { path: []const u8, bytes: []const u8 };
    const files = [_]File{ .{ .path = "css/main.css", .bytes = "@import \"buttons.css\";" }, .{ .path = "css/buttons.css", .bytes = "button { color: $text$; }" } };
    try std.testing.expect(std.mem.indexOf(u8, try compileFiles(a, &files, "css/main.css"), ".pearl-root.$scope button") != null);
    const cycle = [_]File{.{ .path = "a.css", .bytes = "@import \"a.css\";" }};
    try std.testing.expectError(error.ThemeCssImportCycle, compileFiles(a, &cycle, "a.css"));
    const escape = [_]File{.{ .path = "a.css", .bytes = "@import \"../b.css\";" }};
    try std.testing.expectError(error.InvalidThemePath, compileFiles(a, &escape, "a.css"));
}
