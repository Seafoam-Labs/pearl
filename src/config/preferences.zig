//! Versioned, strict preferences. Strings belong to the caller's arena.
const std = @import("std");
pub const Groups = @import("../desktop/policy.zig").Groups;
pub const Edge = @import("../ui/surfaces/policy.zig").Edge;
pub const max_bytes = 65536;
pub const Theme = struct {
    mode: enum { static, dynamic, gtk } = .static,
    variant: enum { dark, light } = .dark,
    seed: []const u8 = "#6750a4",
    source: enum { seed, wallpaper } = .seed,
    // Empty follows GTK settings, including GTK_THEME and user gtk.css.
    gtk_name: []const u8 = "",
};
pub const Wallpaper = struct {
    mode: enum { gradient, solid, cover, contain } = .gradient,
    path: []const u8 = "",
    color: []const u8 = "#141218",
};
pub const Bar = struct { edge: Edge = .top, size: u16 = 48, groups: Groups = .{} };
pub const Output = struct { connector: []const u8, bar: Bar = .{} };
pub const Export = struct { name: []const u8, template: []const u8 };
pub const Preferences = struct {
    version: u32 = 1,
    idle: @import("../services/idle_policy.zig").Config = .{},
    theme: Theme = .{},
    wallpaper: Wallpaper = .{},
    font: []const u8 = "",
    font_size: u8 = 14,
    density: enum { normal, compact } = .normal,
    reduced_motion: bool = false,
    bar: Bar = .{},
    outputs: []const Output = &.{},
    popup: struct { dismiss_outside: bool = true, placement: enum { anchored, centered } = .anchored, max_width: u16 = 720, max_height: u16 = 800 } = .{},
    // Only explicitly listed files in Pearl's export directory are managed.
    exports: []const Export = &.{},
    pub fn forOutput(self: Preferences, connector: []const u8) Bar {
        for (self.outputs) |o| if (std.mem.eql(u8, o.connector, connector)) return o.bar;
        return self.bar;
    }
    pub fn validate(self: Preferences) !void {
        try self.idle.validate();
        if (self.version != 1) return error.UnsupportedVersion;
        try safeText(self.font, 96);
        try safeText(self.theme.gtk_name, 96);
        for (self.font) |ch| if (ch == '"' or ch == '\\' or ch == ';' or ch == '{' or ch == '}') return error.InvalidFont;
        for (self.theme.gtk_name) |ch| if (ch == '/' or ch == '\\' or ch == ':') return error.InvalidThemeName;
        if (!hex(self.theme.seed) or !hex(self.wallpaper.color)) return error.InvalidColor;
        if (self.font_size < 10 or self.font_size > 24) return error.InvalidFontSize;
        try safeText(self.wallpaper.path, 1024);
        if (self.wallpaper.path.len > 0 and self.wallpaper.path[0] != '/') return error.AbsoluteImagePathRequired;
        if ((self.wallpaper.mode == .cover or self.wallpaper.mode == .contain or (self.theme.mode == .dynamic and self.theme.source == .wallpaper)) and self.wallpaper.path.len == 0) return error.ImageRequired;
        try barValid(self.bar);
        if (self.outputs.len > 16) return error.TooManyOutputs;
        for (self.outputs, 0..) |o, i| {
            try safeText(o.connector, 128);
            if (o.connector.len == 0) return error.InvalidConnector;
            for (self.outputs[0..i]) |previous| if (std.mem.eql(u8, previous.connector, o.connector)) return error.DuplicateOutput;
            try barValid(o.bar);
        }
        if (self.popup.max_width < 320 or self.popup.max_width > 1280 or self.popup.max_height < 320 or self.popup.max_height > 1600) return error.InvalidPopupSize;
        if (self.exports.len > 8) return error.TooManyExports;
        for (self.exports, 0..) |e, i| {
            if (e.name.len == 0 or e.name.len > 64 or e.name[0] == '.' or std.mem.endsWith(u8, e.name, ".bak")) return error.InvalidExportName;
            for (e.name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.')) return error.InvalidExportName;
            for (self.exports[0..i]) |p| if (std.mem.eql(u8, p.name, e.name)) return error.DuplicateExport;
            try safeText(e.template, 8192);
        }
    }
};
fn barValid(b: Bar) !void {
    if (b.size < 32 or b.size > 160) return error.InvalidBarSize;
    try b.groups.validate();
}
fn safeText(s: []const u8, max: usize) !void {
    if (s.len > max or !std.unicode.utf8ValidateSlice(s)) return error.InvalidText;
    for (s) |ch| if (ch == 0 or ch == 127 or (ch < 32 and ch != '\n' and ch != '\t')) return error.InvalidText;
}
pub fn hex(s: []const u8) bool {
    if (s.len != 7 or s[0] != '#') return false;
    for (s[1..]) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Preferences {
    try boundedJson(bytes, max_bytes, 8);
    const dom = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    if (dom != .object) return error.InvalidConfig;
    const version: std.json.Value = dom.object.get("version") orelse .{ .integer = 1 };
    if (version != .integer) return error.UnsupportedVersion;
    const p: Preferences = if (version.integer == 0) blk: {
        const Legacy = struct { version: u32, dark: bool = true, wallpaper: []const u8 = "" };
        const old = try std.json.parseFromSliceLeaky(Legacy, a, bytes, .{ .allocate = .alloc_always });
        break :blk .{ .theme = .{ .variant = if (old.dark) .dark else .light }, .wallpaper = .{ .path = old.wallpaper, .mode = if (old.wallpaper.len == 0) .gradient else .cover } };
    } else if (version.integer == 1) try std.json.parseFromSliceLeaky(Preferences, a, bytes, .{ .allocate = .alloc_always }) else return error.UnsupportedVersion;
    try p.validate();
    return p;
}
pub fn boundedJson(bytes: []const u8, max: usize, max_depth: usize) !void {
    if (bytes.len > max or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidConfig;
    // Bound nesting before allocating a DOM (including unknown fields).
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |ch| {
        if (quoted) {
            if (escaped) escaped = false else if (ch == '\\') escaped = true else if (ch == '"') quoted = false;
        } else switch (ch) {
            '"' => quoted = true,
            '{', '[' => {
                depth += 1;
                if (depth > max_depth) return error.InvalidConfig;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidConfig;
                depth -= 1;
            },
            else => {},
        }
    }
}
test "preferences migrate legacy, reject unknown versions, injection and conflicting output groups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try (Preferences{}).validate();
    const p = try parse(a, "{\"version\":0,\"dark\":false}");
    try std.testing.expectEqual(.light, p.theme.variant);
    try std.testing.expectError(error.UnsupportedVersion, parse(a, "{\"version\":9}"));
    try std.testing.expectError(error.UnknownField, parse(a, "{\"oops\":true}"));
    try std.testing.expectError(error.InvalidColor, parse(a, "{\"theme\":{\"seed\":\"red;}\"}}"));
    try std.testing.expectError(error.InvalidGroups, parse(a, "{\"bar\":{\"groups\":{\"right\":\"clock\"}}}"));
    try std.testing.expectError(error.DuplicateOutput, parse(a, "{\"outputs\":[{\"connector\":\"DP-1\"},{\"connector\":\"DP-1\"}]}"));
    try std.testing.expectError(error.InvalidExportName, parse(a, "{\"exports\":[{\"name\":\"../gtk.css\",\"template\":\"\"}]}"));
}

test "preferences enforce JSON bounds and own parsed strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bytes = "{\"font\":\"Inter\"}".*;
    const p = try parse(a, &bytes);
    @memset(&bytes, ' ');
    try std.testing.expectEqualStrings("Inter", p.font);
    try std.testing.expectError(error.InvalidConfig, parse(a, "[" ** 9));
    try std.testing.expectError(error.InvalidConfig, parse(a, " " ** (max_bytes + 1)));
    try std.testing.expectError(error.DuplicateField, parse(a, "{\"version\":1,\"version\":1}"));
}
