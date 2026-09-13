const std = @import("std");

pub const Palette = struct {
    surface: []const u8,
    low: []const u8,
    container: []const u8,
    high: []const u8,
    text: []const u8,
    secondary: []const u8,
    primary: []const u8,
    on_primary: []const u8,
    primary_container: []const u8,
    on_container: []const u8,
    outline: []const u8,
    error_color: []const u8,
    error_container: []const u8,
};
pub const dark: Palette = .{
    .surface = "#141218",
    .low = "#1d1b20",
    .container = "#211f26",
    .high = "#2b2930",
    .text = "#e6e0e9",
    .secondary = "#cac4d0",
    .primary = "#d0bcff",
    .on_primary = "#381e72",
    .primary_container = "#4f378b",
    .on_container = "#eaddff",
    .outline = "#79747e",
    .error_color = "#ffb4ab",
    .error_container = "#601410",
};
pub const light: Palette = .{
    .surface = "#fdf7ff",
    .low = "#f7f2fa",
    .container = "#f3edf7",
    .high = "#ece6f0",
    .text = "#1d1b20",
    .secondary = "#49454f",
    .primary = "#6750a4",
    .on_primary = "#ffffff",
    .primary_container = "#eaddff",
    .on_container = "#21005d",
    .outline = "#79747e",
    .error_color = "#8c1d18",
    .error_container = "#f9dedc",
};
pub const spacing = [_]u8{ 2, 4, 8, 12, 16, 24 };
pub const radius = 12;
pub const motion_ms = 150;

/// Expand a scoped stylesheet for both palettes. Only background colors carry
/// state-layer alpha; foreground text and entire widget subtrees stay opaque.
pub fn css(allocator: std.mem.Allocator, template: []const u8) ![:0]u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    inline for (.{ .{ "pearl-dark", dark }, .{ "pearl-light", light } }) |pair| {
        var sheet = try std.mem.replaceOwned(u8, allocator, template, "$scope", pair[0]);
        defer allocator.free(sheet);
        inline for (@typeInfo(Palette).@"struct".fields) |field| {
            const next = try std.mem.replaceOwned(u8, allocator, sheet, "$" ++ field.name ++ "$", @field(pair[1], field.name));
            allocator.free(sheet);
            sheet = next;
        }
        try result.appendSlice(allocator, sheet);
    }
    return allocator.dupeZ(u8, result.items);
}

fn luminance(hex: []const u8) f64 {
    var rgb: [3]f64 = undefined;
    for (&rgb, 0..) |*value, i| {
        const channel = @as(f64, @floatFromInt(std.fmt.parseInt(u8, hex[1 + i * 2 ..][0..2], 16) catch unreachable)) / 255;
        value.* = if (channel <= 0.04045) channel / 12.92 else std.math.pow(f64, (channel + 0.055) / 1.055, 2.4);
    }
    return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
}
test "both palettes meet normal text and control contrast targets" {
    for ([_]Palette{ dark, light }) |p| {
        for ([_][2][]const u8{ .{ p.text, p.surface }, .{ p.text, p.high }, .{ p.secondary, p.container }, .{ p.on_primary, p.primary }, .{ p.on_container, p.primary_container }, .{ p.error_color, p.error_container } }) |pair| {
            const x = luminance(pair[0]);
            const y = luminance(pair[1]);
            try std.testing.expect((@max(x, y) + 0.05) / (@min(x, y) + 0.05) >= 4.5);
        }
        const x = luminance(p.primary);
        const y = luminance(p.surface);
        try std.testing.expect((@max(x, y) + 0.05) / (@min(x, y) + 0.05) >= 3);
    }
}
