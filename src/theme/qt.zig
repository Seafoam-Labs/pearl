//! Versioned Qt appearance policy and deterministic palette serialization.
const std = @import("std");
const theme = @import("theme.zig");
pub const Config = struct {
    enabled: bool = false,
    style: enum { darkly } = .darkly,
    targets: struct { qt5: bool = true, qt6: bool = true } = .{},
    palette: enum { follow_pearl, static_dark, static_light } = .follow_pearl,
    sync_font: bool = true,
    icon_theme: []const u8 = "",
    darkly: struct {
        corner_radius: ?u8 = null,
        sync_reduced_motion: bool = true,
        sync_density: bool = false,
        sync_kde_colors: bool = true,
    } = .{},
    pub fn validate(self: Config) !void {
        if (self.icon_theme.len > 96) return error.InvalidIconTheme;
        for (self.icon_theme) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == ' ')) return error.InvalidIconTheme;
        if (self.darkly.corner_radius) |radius| if (radius < 1 or radius > 16) return error.InvalidQtRadius;
    }
};
pub const Target = struct {
    state: enum { disabled, applying, applied, missing_dependency, conflict, failed, restore_incomplete } = .disabled,
    error_code: ?[]const u8 = null,
};
pub const Status = struct {
    desired_revision: u64 = 0,
    applied_revision: u64 = 0,
    qt5: Target = .{},
    qt6: Target = .{},
    engine: Target = .{},
    darkly: Target = .{},
    kde: Target = .{},
    environment: Target = .{},
    restart_apps: bool = false,
    restart_session: bool = false,
    gtk_fallback: bool = false,
    busy: bool = false,
};
/// QtEngine accepts integer point sizes. Map Pearl's logical pixels at 96 DPI,
/// rounding to the nearest representable point; Qt handles output scaling.
pub fn fontPoints(pixels: u8) u8 {
    return @intCast((@as(u16, pixels) * 3 + 2) / 4);
}
/// KDE color scheme consumed by QtEngine for both Qt runtimes.
pub fn serializeEngine(a: std.mem.Allocator, p: theme.Palette) ![]const u8 {
    try theme.validate(p);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "[General]\nName=Pearl\nColorScheme=Pearl\n\n[KDE]\ncontrast=4\n\n[ColorEffects:Inactive]\nEnable=false\nChangeSelectionColor=false\n\n[ColorEffects:Disabled]\nIntensityEffect=0\nColorEffect=0\nContrastEffect=1\nContrastAmount=0.5\n");
    for ([_][]const u8{ "Window", "View", "Button", "Selection", "Tooltip", "Complementary", "Header" }) |group| {
        const selection = std.mem.eql(u8, group, "Selection");
        const button = std.mem.eql(u8, group, "Button");
        try out.appendSlice(a, try std.fmt.allocPrint(a, "\n[Colors:{s}]\n", .{group}));
        for ([_]struct { []const u8, []const u8 }{
            .{ "BackgroundNormal", if (selection) p.primary else if (button) p.high else p.surface },
            .{ "BackgroundAlternate", p.container },
            .{ "ForegroundNormal", if (selection) p.on_primary else p.text },
            .{ "ForegroundInactive", p.secondary },
            .{ "ForegroundActive", p.primary },
            .{ "ForegroundLink", p.primary },
            .{ "ForegroundVisited", p.secondary },
            .{ "ForegroundNegative", p.error_color },
            .{ "ForegroundNeutral", p.secondary },
            .{ "ForegroundPositive", p.primary },
            .{ "DecorationFocus", p.primary },
            .{ "DecorationHover", p.primary },
        }) |field| {
            const color = field[1];
            try out.appendSlice(a, try std.fmt.allocPrint(a, "{s}={d},{d},{d}\n", .{ field[0], try std.fmt.parseInt(u8, color[1..3], 16), try std.fmt.parseInt(u8, color[3..5], 16), try std.fmt.parseInt(u8, color[5..7], 16) }));
        }
    }
    return out.toOwnedSlice(a);
}
test "QtEngine color scheme is shared and font conversion uses logical points" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try serializeEngine(arena.allocator(), theme.dark);
    try std.testing.expectEqual(@as(usize, 7), std.mem.count(u8, bytes, "[Colors:"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "DecorationFocus=208,188,255") != null);
    try std.testing.expectEqual(@as(u8, 11), fontPoints(14));
    try std.testing.expectEqual(@as(u8, 18), fontPoints(24));
}
pub fn selected(config: Config, palette: theme.Palette) theme.Palette {
    return switch (config.palette) {
        .follow_pearl => palette,
        .static_dark => theme.dark,
        .static_light => theme.light,
    };
}
/// QPalette enum order, Qt 5.15 (21 roles) and Qt >=6.6 (22 roles).
/// NoRole is serialized too, as required by qtct's positional format.
pub fn roles(p: theme.Palette, disabled: bool) [22][]const u8 {
    const text = if (disabled) p.secondary else p.text;
    return .{ text, p.high, p.high, p.container, p.surface, p.outline, text, p.on_primary, text, p.low, p.surface, p.outline, p.primary, p.on_primary, p.primary, p.primary, p.container, p.text, p.high, p.text, p.secondary, p.primary };
}
pub fn serialize(alloc: std.mem.Allocator, p: theme.Palette, qt6: bool) ![]const u8 {
    try theme.validate(p);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "[ColorScheme]\n");
    for ([_][]const u8{ "active_colors", "inactive_colors", "disabled_colors" }, 0..) |key, group| {
        try out.appendSlice(alloc, key);
        try out.append(alloc, '=');
        const colors = roles(p, group == 2);
        for (colors[0..if (qt6) @as(usize, 22) else 21], 0..) |color, i| {
            if (i != 0) try out.appendSlice(alloc, ", ");
            try out.appendSlice(alloc, "#ff");
            try out.appendSlice(alloc, color[1..]);
        }
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}
test "Qt palette groups contain the consumer's exact role count" {
    for ([_]bool{ false, true }) |qt6| {
        const bytes = try serialize(std.testing.allocator, theme.dark, qt6);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqual(@as(usize, if (qt6) 66 else 63), std.mem.count(u8, bytes, "#ff"));
    }
    try std.testing.expectEqualStrings(theme.light.primary, roles(theme.light, false)[12]);
    try std.testing.expectEqualStrings(theme.light.secondary, roles(theme.light, true)[0]);
}
test "Qt appearance defaults, bounds and GTK-independent palette selection" {
    const defaults: Config = .{};
    try std.testing.expect(!defaults.enabled);
    try defaults.validate();
    var invalid: Config = .{};
    invalid.darkly.corner_radius = 17;
    try std.testing.expectError(error.InvalidQtRadius, invalid.validate());
    invalid = .{ .icon_theme = "../icons" };
    try std.testing.expectError(error.InvalidIconTheme, invalid.validate());
    try std.testing.expectEqualStrings(theme.light.surface, selected(.{ .palette = .static_light }, theme.dark).surface);
}
