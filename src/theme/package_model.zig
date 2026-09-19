//! Versioned, declarative community theme contract. No filesystem or GTK access.
const std = @import("std");
const theme = @import("theme.zig");
pub const max_bytes = 16 * 1024 * 1024;
pub const max_entries = 1024;
pub const APIs = struct {
    palette_api: ?u32 = null,
    style_api: ?u32 = null,
    profile_api: ?u32 = null,
    render_data_api: ?u32 = null,
    pub fn supported(self: APIs) bool {
        return (self.palette_api == null or self.palette_api == 1) and
            (self.style_api == null or self.style_api == 1 or self.style_api == 2) and
            (self.profile_api == null or self.profile_api == 1) and
            (self.render_data_api == null or self.render_data_api == 1);
    }
};
pub const Manifest = struct {
    schema_version: u32,
    id: []const u8,
    name: []const u8,
    author: []const u8,
    license: []const u8,
    source: []const u8,
    asset_version: []const u8,
    requires: APIs,
    palettes: struct { dark: ?[]const u8 = null, light: ?[]const u8 = null } = .{},
    style: ?struct { tokens: ?[]const u8 = null, css: ?[]const u8 = null } = null,
    images: []const struct { id: []const u8, path: []const u8 } = &.{},
    profiles: []const []const u8 = &.{},
    defaults: []const struct { application: []const u8, profile: []const u8 } = &.{},
    render_data: ?struct { dark: ?[]const u8 = null, light: ?[]const u8 = null } = null,
    pub fn validate(self: Manifest) !void {
        if (self.schema_version != 1 and self.schema_version != 2) return error.UnsupportedThemeSchema;
        if (self.schema_version == 1 and (self.images.len != 0 or self.profiles.len != 0 or self.defaults.len != 0 or self.render_data != null or self.requires.profile_api != null or self.requires.render_data_api != null or self.requires.style_api == 2)) return error.UnsupportedThemeSchema;
        try identifier(self.id);
        if (std.mem.startsWith(u8, self.id, "pearl.")) return error.ReservedThemeId;
        for ([_][]const u8{ self.name, self.author, self.license, self.source }) |s| try text(s, 256);
        _ = try version(self.asset_version);
        if (self.requires.palette_api) |v| if (v != 1) return error.UnsupportedPaletteApi;
        if (self.requires.style_api) |v| if (v != 1 and v != 2) return error.UnsupportedStyleApi;
        if (!self.requires.supported()) return error.UnsupportedThemeApi;
        if (self.palettes.dark == null and self.palettes.light == null and self.style == null and self.profiles.len == 0) return error.EmptyTheme;
        for ([_]?[]const u8{ self.palettes.dark, self.palettes.light }) |p| if (p) |path| {
            if (self.requires.palette_api != 1) return error.MissingPaletteApi;
            try relative(path);
        };
        if (self.style) |s| {
            if (self.requires.style_api == null) return error.MissingStyleApi;
            if (s.tokens == null and s.css == null) return error.EmptyStyle;
            if (s.tokens) |p| try relative(p);
            if (s.css) |p| try relative(p);
        }
        if (self.images.len > 32 or self.profiles.len > 32 or self.defaults.len > 32) return error.ThemeEntryLimit;
        if (self.images.len > 0 and (self.requires.style_api != 2 or self.style == null)) return error.MissingStyleApi;
        for (self.images, 0..) |image, i| {
            try identifier(image.id);
            try relative(image.path);
            for (self.images[0..i]) |previous| if (std.mem.eql(u8, previous.id, image.id)) return error.DuplicateThemeAsset;
        }
        if ((self.profiles.len > 0 or self.defaults.len > 0) and self.requires.profile_api != 1) return error.MissingProfileApi;
        for (self.profiles, 0..) |path, i| {
            try relative(path);
            for (self.profiles[0..i]) |old| if (std.mem.eql(u8, old, path)) return error.DuplicateThemeProfile;
        }
        for (self.defaults, 0..) |entry, i| {
            try identifier(entry.application);
            try identifier(entry.profile);
            for (self.defaults[0..i]) |old| if (std.mem.eql(u8, old.application, entry.application)) return error.DuplicateThemeDefault;
        }
        if (self.render_data) |data| {
            if (self.requires.render_data_api != 1) return error.MissingRenderDataApi;
            if (data.dark == null and data.light == null) return error.EmptyRenderData;
            for ([_]?[]const u8{ data.dark, data.light }, [_]?[]const u8{ self.palettes.dark, self.palettes.light }) |path, shell| if (path) |p| {
                if (shell == null) return error.RenderDataRequiresPalette;
                try relative(p);
            };
        }
    }
};
pub fn parse(comptime T: type, a: std.mem.Allocator, bytes: []const u8, limit: usize) !T {
    try @import("../config/preferences.zig").boundedJson(bytes, limit, 12);
    return std.json.parseFromSliceLeaky(T, a, bytes, .{ .allocate = .alloc_always });
}
pub fn identifier(s: []const u8) !void {
    if (s.len == 0 or s.len > 96 or !std.ascii.isAlphanumeric(s[0])) return error.InvalidThemeId;
    for (s) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '.' or ch == '_' or ch == '-')) return error.InvalidThemeId;
}
pub fn text(s: []const u8, max: usize) !void {
    if (s.len == 0 or s.len > max or !std.unicode.utf8ValidateSlice(s)) return error.InvalidThemeText;
    for (s) |ch| if (ch < 32 or ch == 127) return error.InvalidThemeText;
}
pub fn relative(s: []const u8) !void {
    if (s.len == 0 or s.len > 512 or std.mem.indexOfScalar(u8, s, '\\') != null) return error.InvalidThemePath;
    var parts = std.mem.splitScalar(u8, s, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 255 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidThemePath;
        try text(part, 255);
    }
}
pub fn version(s: []const u8) ![3]u32 {
    if (s.len > 32) return error.InvalidThemeVersion;
    var parts = std.mem.splitScalar(u8, s, '.');
    var result: [3]u32 = undefined;
    for (&result) |*n| {
        const p = parts.next() orelse return error.InvalidThemeVersion;
        if (p.len == 0 or (p.len > 1 and p[0] == '0')) return error.InvalidThemeVersion;
        for (p) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidThemeVersion;
        n.* = std.fmt.parseInt(u32, p, 10) catch return error.InvalidThemeVersion;
    }
    if (parts.next() != null) return error.InvalidThemeVersion;
    return result;
}
pub fn hash(bytes: []const u8) [64]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}
pub fn digest(s: []const u8) !void {
    if (s.len != 64) return error.InvalidThemeDigest;
    for (s) |ch| if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return error.InvalidThemeDigest;
}
pub fn palette(a: std.mem.Allocator, bytes: []const u8) !theme.Palette {
    const p = try parse(theme.Palette, a, bytes, 65536);
    try theme.validate(p);
    return p;
}
test "theme contract rejects traversal, ambiguous versions, reserved IDs and unknown keys" {
    for ([_][]const u8{ "../theme.json", "/etc/passwd", "x//y", "x/./y", "x\\y" }) |bad| try std.testing.expectError(error.InvalidThemePath, relative(bad));
    try relative("palettes/dark.json");
    try std.testing.expectEqual([3]u32{ 1, 2, 3 }, try version("1.2.3"));
    for ([_][]const u8{ "01.2.3", "1.2", "1.2.3.4", "-1.2.3" }) |bad| try std.testing.expectError(error.InvalidThemeVersion, version(bad));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnknownField, parse(APIs, arena.allocator(), "{\"execute\":true}", 65536));
    try std.testing.expectError(error.DuplicateField, parse(APIs, arena.allocator(), "{\"style_api\":1,\"style_api\":1}", 65536));
}
