//! Matugen 4's full JSON color input, preserved verbatim after validation.
const std = @import("std");
const model = @import("package_model.zig");
const theme = @import("theme.zig");
pub const Document = struct { schema_version: u32, renderer: []const u8, colors: std.json.Value, base16: std.json.Value, palettes: std.json.Value };
pub fn validate(a: std.mem.Allocator, bytes: []const u8, variant: []const u8, shell: theme.Palette) !void {
    const document = try model.parse(Document, a, bytes, 131072);
    if (document.schema_version != 1 or !std.mem.eql(u8, document.renderer, "matugen-4")) return error.UnsupportedRenderData;
    if (document.colors != .object or document.base16 != .object or document.colors.object.count() > 128 or document.base16.object.count() != 16) return error.InvalidRenderData;
    // The complete semantic roles used by Matugen's Material templates.
    const required = [_][]const u8{ "background", "surface", "surface_dim", "surface_bright", "surface_container_lowest", "surface_container_low", "surface_container", "surface_container_high", "surface_container_highest", "on_surface", "on_surface_variant", "primary", "on_primary", "primary_container", "on_primary_container", "secondary", "on_secondary", "secondary_container", "on_secondary_container", "tertiary", "on_tertiary", "tertiary_container", "on_tertiary_container", "error", "on_error", "error_container", "on_error_container", "outline", "outline_variant", "inverse_surface", "inverse_on_surface", "inverse_primary", "shadow", "scrim", "surface_tint", "source_color" };
    for (required) |role| if (!document.colors.object.contains(role)) return error.MissingRenderRole;
    for ([_][]const u8{ "on_background", "surface_variant", "primary_fixed", "primary_fixed_dim", "on_primary_fixed", "on_primary_fixed_variant", "secondary_fixed", "secondary_fixed_dim", "on_secondary_fixed", "on_secondary_fixed_variant", "tertiary_fixed", "tertiary_fixed_dim", "on_tertiary_fixed", "on_tertiary_fixed_variant" }) |role| if (!document.colors.object.contains(role)) return error.MissingRenderRole;
    for (0..16) |n| {
        var key: [6]u8 = undefined;
        const name = try std.fmt.bufPrint(&key, "base{x:0>2}", .{n});
        // Matugen uses lowercase hexadecimal base16 role suffixes.
        if (!document.base16.object.contains(name)) return error.MissingRenderRole;
    }
    if (document.palettes != .object or document.palettes.object.count() != 6) return error.InvalidRenderData;
    for ([_][]const u8{ "primary", "secondary", "tertiary", "neutral", "neutral_variant", "error" }) |name| {
        const tones = document.palettes.object.get(name) orelse return error.MissingRenderRole;
        if (tones != .object or tones.object.count() != 18) return error.InvalidRenderData;
        for ([_][]const u8{ "0", "5", "10", "15", "20", "25", "30", "35", "40", "50", "60", "70", "80", "90", "95", "98", "99", "100" }) |tone| {
            const color = tones.object.get(tone) orelse return error.MissingRenderRole;
            if (color != .object or color.object.count() != 1) return error.InvalidRenderData;
            const hex = color.object.get("color") orelse return error.InvalidRenderData;
            if (hex != .string or !@import("../config/preferences.zig").hex(hex.string)) return error.InvalidRenderData;
        }
    }
    for ([_]std.json.Value{ document.colors, document.base16 }) |map| {
        var it = map.object.iterator();
        while (it.next()) |entry| {
            try model.identifier(entry.key_ptr.*);
            const value = entry.value_ptr.*;
            if (value != .object or value.object.count() != 3) return error.InvalidRenderData;
            for ([_][]const u8{ "dark", "light", "default" }) |mode| {
                const color = value.object.get(mode) orelse return error.InvalidRenderData;
                if (color != .object or color.object.count() != 1) return error.InvalidRenderData;
                const hex = color.object.get("color") orelse return error.InvalidRenderData;
                if (hex != .string or !@import("../config/preferences.zig").hex(hex.string)) return error.InvalidRenderData;
            }
        }
    }
    const projected = try theme.matugenPalette(a, bytes, variant);
    inline for (@typeInfo(theme.Palette).@"struct".fields) |field| if (!std.ascii.eqlIgnoreCase(@field(projected, field.name), @field(shell, field.name))) return error.RenderPaletteMismatch;
}
