const std = @import("std");
const prefs = @import("../config/preferences.zig");
const palette = @import("theme.zig");
const style = @import("style.zig");
const catalog = @import("catalog.zig");
pub const Resolved = struct {
    palette_api: u32 = 1,
    style_api: u32 = 1,
    palette: ?palette.Palette = null,
    tokens: style.Tokens = .{},
    css: []const u8 = "",
    palette_css: []const u8 = "",
    digest: []const u8 = "",
    images: []const @import("assets.zig").Image = &.{},
    blobs: []const @import("assets.zig").Blob = &.{},
    pub fn jsonStringify(self: Resolved, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        inline for (@typeInfo(Resolved).@"struct".fields) |field| {
            if (comptime !std.mem.eql(u8, field.name, "blobs")) {
                if (comptime std.mem.eql(u8, field.name, "images")) {
                    if (self.images.len > 0) {
                        try writer.objectField(field.name);
                        try writer.write(self.images);
                    }
                } else if (comptime std.mem.eql(u8, field.name, "palette_css")) {
                    if (self.palette_css.len > 0) {
                        try writer.objectField(field.name);
                        try writer.write(self.palette_css);
                    }
                } else {
                    try writer.objectField(field.name);
                    try writer.write(@field(self, field.name));
                }
            }
        }
        try writer.endObject();
    }
};
pub fn resolve(a: std.mem.Allocator, p: prefs.Theme, c: catalog.Catalog, check_revision: bool) !Resolved {
    if (p.mode == .gtk) return .{};
    if (check_revision and p.catalog_revision.len != 0 and !std.mem.eql(u8, p.catalog_revision, &c.revision)) return error.ThemeCatalogChanged;
    const active = if (p.package_id.len > 0) (try c.get(p.package_id)).package else null;
    var result: Resolved = .{ .digest = try a.dupe(u8, &c.revision) };
    if (p.mode == .package) {
        const entry = try c.get(if (p.palette_id.len > 0) p.palette_id else p.package_id);
        if (entry.palette_file) |file| {
            result.palette = if (p.variant == .dark) file.document.dark else file.document.light;
            result.palette_css = try @import("palette_resolver.zig").shellCss(a, file.document, p.variant == .light);
        } else {
            const selected = entry.package.?;
            result.palette = (if (p.variant == .dark) selected.dark else selected.light) orelse return error.ThemeVariantUnavailable;
            if (selected.palette_hover) |hover| result.palette_css = try @import("palette_resolver.zig").hoverCss(a, if (p.variant == .light) hover.light else hover.dark);
        }
    }
    if (!std.mem.eql(u8, p.style_id, "pearl.default")) {
        const selected = if (p.style_id.len > 0) (try c.get(p.style_id)).package else active;
        if (p.style_id.len > 0 and selected == null) return error.ThemeStyleUnavailable;
        if (selected) |s| {
            if (p.style_id.len > 0 and s.manifest.style == null) return error.ThemeStyleUnavailable;
            result.tokens = s.tokens;
            result.css = s.css;
            if (s.images.len > 0) {
                const entry = try c.get(s.manifest.id);
                const captured = try @import("package.zig").load(a, entry.path);
                if (!std.mem.eql(u8, &captured.digest, &s.digest)) return error.ThemeCatalogChanged;
                result.style_api = 2;
                result.images = captured.images;
                result.blobs = captured.blobs;
            }
        }
    }
    return result;
}
