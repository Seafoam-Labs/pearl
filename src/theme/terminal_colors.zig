//! Bridge legacy Matugen input to the editable palette's terminal roles.
const std = @import("std");
const model = @import("palette_model.zig");
fn copyModes(a: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    if (value != .object) return error.InvalidRenderData;
    // Rendering rewrites each role's default mode. A shallow map copy would
    // leave two owners of its storage when put grows the original map.
    return .{ .object = try value.object.clone(a) };
}
pub fn populate(a: std.mem.Allocator, document: *std.json.Value, application: []const u8) !void {
    const colors = document.object.getPtr("colors") orelse return error.InvalidRenderData;
    const base = document.object.get("base16") orelse return error.InvalidRenderData;
    if (colors.* != .object or base != .object) return error.InvalidRenderData;
    const kitty = std.mem.eql(u8, application, "kitty");
    const cursor_text = if (kitty) "on_surface_variant" else "background";
    const keys = [_][]const u8{ "background", "foreground", "cursor", "cursor_text", "selection_bg", "selection_fg" };
    // Foreground is on_surface for every terminal: primary is an accent role
    // with no contrast guarantee against the terminal background.
    const defaults = [_][]const u8{ "background", "on_surface", "on_surface", cursor_text, if (kitty) "secondary_fixed_dim" else "primary_container", if (kitty) "on_secondary" else "on_surface" };
    for (keys, defaults) |key, role| {
        const target = try std.fmt.allocPrint(a, "terminal_{s}", .{key});
        if (!colors.object.contains(target)) try colors.object.put(a, target, try copyModes(a, colors.object.get(role) orelse return error.InvalidRenderData));
    }
    const indices = [_][]const u8{ "base00", "base08", "base0b", "base0a", "base0d", "base0e", "base0c", "base05" };
    // Matugen 4's base16 output carries no usable hues, so the six ANSI colors
    // come from contrast-guaranteed Material roles; black/white stay base16.
    const hue_roles = [_][]const u8{ "", "error", "primary", "secondary", "tertiary", "inverse_primary", "secondary_fixed", "" };
    for (model.ansi_names, indices, hue_roles, 0..) |name, index, role, i| {
        const target_normal = try std.fmt.allocPrint(a, "terminal_normal_{s}", .{name});
        const target_bright = try std.fmt.allocPrint(a, "terminal_bright_{s}", .{name});
        if (role.len > 0) {
            if (!colors.object.contains(target_normal)) try colors.object.put(a, target_normal, try copyModes(a, colors.object.get(role) orelse return error.InvalidRenderData));
            if (!colors.object.contains(target_bright)) try colors.object.put(a, target_bright, try copyModes(a, colors.object.get(role) orelse return error.InvalidRenderData));
        } else {
            const key = if (i == 0) "base00" else if (i == 7) "base05" else index;
            const bright_key = if (i == 0) "base03" else if (i == 7) "base07" else index;
            if (!colors.object.contains(target_normal)) try colors.object.put(a, target_normal, try copyModes(a, base.object.get(key) orelse return error.InvalidRenderData));
            if (!colors.object.contains(target_bright)) try colors.object.put(a, target_bright, try copyModes(a, base.object.get(bright_key) orelse return error.InvalidRenderData));
        }
    }
}
