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
    const defaults = [_][]const u8{ "background", "on_surface", if (kitty) "on_surface" else "primary", cursor_text, if (kitty) "secondary_fixed_dim" else "primary_container", if (kitty) "on_secondary" else "on_surface" };
    for (keys, defaults) |key, role| {
        const target = try std.fmt.allocPrint(a, "terminal_{s}", .{key});
        if (!colors.object.contains(target)) try colors.object.put(a, target, try copyModes(a, colors.object.get(role) orelse return error.InvalidRenderData));
    }
    const indices = [_][]const u8{ "base00", "base08", "base0b", "base0a", "base0d", "base0e", "base0c", "base05" };
    for ([_][]const u8{ "normal", "bright" }) |level| for (model.ansi_names, indices, 0..) |name, index, i| {
        const target = try std.fmt.allocPrint(a, "terminal_{s}_{s}", .{ level, name });
        const key = if (std.mem.eql(u8, level, "bright") and i == 0) "base03" else if (std.mem.eql(u8, level, "bright") and i == 7) "base07" else index;
        if (!colors.object.contains(target)) try colors.object.put(a, target, try copyModes(a, base.object.get(key) orelse return error.InvalidRenderData));
    };
}
