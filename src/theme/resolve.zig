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
    digest: []const u8 = "",
};
pub fn resolve(a: std.mem.Allocator, p: prefs.Theme, c: catalog.Catalog, check_revision: bool) !Resolved {
    if (p.mode == .gtk) return .{};
    if (check_revision and p.catalog_revision.len != 0 and !std.mem.eql(u8, p.catalog_revision, &c.revision)) return error.ThemeCatalogChanged;
    const active = if (p.package_id.len > 0) (try c.get(p.package_id)).package else null;
    var result: Resolved = .{ .digest = try a.dupe(u8, &c.revision) };
    if (p.mode == .package) {
        const selected = (try c.get(if (p.palette_id.len > 0) p.palette_id else p.package_id)).package;
        result.palette = (if (p.variant == .dark) selected.dark else selected.light) orelse return error.ThemeVariantUnavailable;
    }
    if (!std.mem.eql(u8, p.style_id, "pearl.default")) {
        const selected = if (p.style_id.len > 0) (try c.get(p.style_id)).package else active;
        if (selected) |s| {
            if (p.style_id.len > 0 and s.manifest.style == null) return error.ThemeStyleUnavailable;
            result.tokens = s.tokens;
            result.css = s.css;
        }
    }
    return result;
}
