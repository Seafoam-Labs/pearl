//! One deterministic compiler for editable shell and application colors.
const std = @import("std");
const model = @import("palette_model.zig");
const theme = @import("theme.zig");
pub const Document = struct {
    source: model.Source,
    dark: theme.Palette,
    light: theme.Palette,
    render_json: []const u8,
    digest: [64]u8,
    dark_hover: [2][]const u8,
    light_hover: [2][]const u8,
};
pub fn shellCss(a: std.mem.Allocator, document: Document, light: bool) ![]const u8 {
    return hoverCss(a, if (light) document.light_hover else document.dark_hover);
}
pub fn hoverCss(a: std.mem.Allocator, colors: [2][]const u8) ![]const u8 {
    return std.fmt.allocPrint(a, ".pearl-root.$scope button:hover {{ background: {s}; color: {s}; }}\n", .{ colors[0], colors[1] });
}
pub const shell_roles = .{ "surface", "surface_container_low", "surface_container", "surface_container_high", "on_surface", "on_surface_variant", "primary", "on_primary", "primary_container", "on_primary_container", "outline", "error", "error_container" };
pub fn contrast(x: []const u8, y: []const u8) f64 {
    const first = luminance(x);
    const second = luminance(y);
    return (@max(first, second) + 0.05) / (@min(first, second) + 0.05);
}
fn luminance(hex: []const u8) f64 {
    var rgb: [3]f64 = undefined;
    for (&rgb, 0..) |*v, i| {
        const c = @as(f64, @floatFromInt(std.fmt.parseInt(u8, hex[1 + i * 2 ..][0..2], 16) catch unreachable)) / 255;
        v.* = if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
    }
    return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
}
pub fn foreground(background: []const u8) []const u8 {
    return if (contrast("#ffffff", background) > contrast("#000000", background)) "#ffffff" else "#000000";
}
fn mix(a: std.mem.Allocator, x: []const u8, y: []const u8, weight: u8) ![]const u8 {
    var out: [3]u8 = undefined;
    for (&out, 0..) |*v, i| {
        const first = std.fmt.parseInt(u16, x[1 + i * 2 ..][0..2], 16) catch unreachable;
        const second = std.fmt.parseInt(u16, y[1 + i * 2 ..][0..2], 16) catch unreachable;
        v.* = @intCast((first * (100 - @as(u16, weight)) + second * weight + 50) / 100);
    }
    return std.fmt.allocPrint(a, "#{x:0>2}{x:0>2}{x:0>2}", .{ out[0], out[1], out[2] });
}
fn default(a: std.mem.Allocator, v: *std.json.Value, authored: std.json.Value, key: []const u8, value: []const u8) !void {
    try model.set(a, v, key, if (authored.object.get(key)) |explicit| explicit.string else value);
}
fn resolveVariant(a: std.mem.Allocator, authored: std.json.Value, variant: []const u8, defaults: std.json.Value, d: *model.Diagnostic) !std.json.Value {
    var v = model.object();
    var it = defaults.object.iterator();
    while (it.next()) |item| try model.set(a, &v, item.key_ptr.*, item.value_ptr.object.get(variant).?.object.get("color").?.string);
    const surface = model.get(authored, "surface");
    const text = model.get(authored, "on_surface");
    const primary = model.get(authored, "primary");
    try model.set(a, &v, "surface", surface);
    try model.set(a, &v, "on_surface", text);
    try model.set(a, &v, "primary", primary);
    for ([_][]const u8{ "background", "surface_dim", "surface_container_lowest" }) |role| try default(a, &v, authored, role, surface);
    try default(a, &v, authored, "on_background", text);
    for ([_][]const u8{ "surface_container_low", "surface_container", "surface_container_high", "surface_container_highest", "surface_bright", "surface_variant" }, [_]u8{ 4, 8, 12, 16, 16, 8 }) |role, weight| {
        const blended = try mix(a, surface, text, weight);
        try default(a, &v, authored, role, if (contrast(text, blended) >= 4.5) blended else surface);
    }
    const muted = try mix(a, surface, text, 75);
    try default(a, &v, authored, "on_surface_variant", if (contrast(muted, model.get(v, "surface_container")) >= 4.5) muted else text);
    try default(a, &v, authored, "outline", try mix(a, surface, text, 55));
    try default(a, &v, authored, "outline_variant", try mix(a, surface, text, 25));
    for ([_][]const u8{ "primary", "secondary", "tertiary" }) |accent| {
        try default(a, &v, authored, accent, primary);
        const color = model.get(v, accent);
        const container_key = try std.fmt.allocPrint(a, "{s}_container", .{accent});
        try default(a, &v, authored, container_key, try mix(a, surface, color, 20));
        const container = model.get(v, container_key);
        try default(a, &v, authored, try std.fmt.allocPrint(a, "on_{s}", .{accent}), foreground(color));
        try default(a, &v, authored, try std.fmt.allocPrint(a, "on_{s}_container", .{accent}), if (contrast(text, container) >= 4.5) text else foreground(container));
        for ([_][]const u8{ "_fixed", "_fixed_dim" }) |suffix| try default(a, &v, authored, try std.fmt.allocPrint(a, "{s}{s}", .{ accent, suffix }), color);
        for ([_][]const u8{ "_fixed", "_fixed_variant" }) |suffix| try default(a, &v, authored, try std.fmt.allocPrint(a, "on_{s}{s}", .{ accent, suffix }), foreground(color));
    }
    try default(a, &v, authored, "hover", model.get(v, "surface_container_high"));
    try default(a, &v, authored, "on_hover", text);
    try default(a, &v, authored, "surface_tint", primary);
    try default(a, &v, authored, "source_color", primary);
    try default(a, &v, authored, "inverse_surface", text);
    try default(a, &v, authored, "inverse_on_surface", surface);
    try default(a, &v, authored, "inverse_primary", foreground(text));
    // Apply other explicit roles, including error colors, after defaults.
    var explicit = authored.object.iterator();
    while (explicit.next()) |item| if (!std.mem.eql(u8, item.key_ptr.*, "terminal")) try model.set(a, &v, item.key_ptr.*, item.value_ptr.string);
    try default(a, &v, authored, "on_error", foreground(model.get(v, "error")));
    try default(a, &v, authored, "on_error_container", foreground(model.get(v, "error_container")));
    const pairs = [_][2][]const u8{ .{ "on_surface", "surface" }, .{ "on_surface", "surface_container_high" }, .{ "on_surface_variant", "surface_container" }, .{ "on_primary", "primary" }, .{ "on_primary_container", "primary_container" }, .{ "error", "error_container" }, .{ "on_secondary", "secondary" }, .{ "on_secondary_container", "secondary_container" }, .{ "on_tertiary", "tertiary" }, .{ "on_tertiary_container", "tertiary_container" }, .{ "on_hover", "hover" } };
    for (pairs) |pair| {
        const fg = model.get(v, pair[0]);
        const bg = model.get(v, pair[1]);
        const ratio = contrast(fg, bg);
        if (ratio < 4.5) {
            d.* = .{ .path = try std.fmt.allocPrint(a, "$.{s}.{s}", .{ variant, pair[0] }), .code = "InsufficientContrast", .value = fg, .background = pair[1], .ratio = ratio, .required = 4.5, .suggested = foreground(bg) };
            return error.InsufficientContrast;
        }
    }
    return v;
}
fn project(v: std.json.Value) theme.Palette {
    var result: theme.Palette = undefined;
    inline for (@typeInfo(theme.Palette).@"struct".fields, shell_roles) |field, role| @field(result, field.name) = model.get(v, role);
    return result;
}
fn colorValue(a: std.mem.Allocator, hex: []const u8) !std.json.Value {
    var v = model.object();
    try model.set(a, &v, "color", hex);
    return v;
}
fn modes(a: std.mem.Allocator, dark: []const u8, light: []const u8) !std.json.Value {
    var v = model.object();
    try v.object.put(a, "dark", try colorValue(a, dark));
    try v.object.put(a, "light", try colorValue(a, light));
    try v.object.put(a, "default", try colorValue(a, dark));
    return v;
}
fn terminal(a: std.mem.Allocator, authored: std.json.Value, v: std.json.Value, base: std.json.Value, variant: []const u8) !std.json.Value {
    var t = model.object();
    for ([_][]const u8{ "background", "foreground", "cursor", "cursorText", "selectionBg", "selectionFg" }, [_][]const u8{ "surface", "on_surface", "primary", "on_primary", "primary_container", "on_primary_container" }) |key, role| try model.set(a, &t, key, model.get(v, role));
    const input = authored.object.get("terminal");
    const keys = [_][]const u8{ "base00", "base08", "base0b", "base0a", "base0d", "base0e", "base0c", "base05" };
    for ([_][]const u8{ "normal", "bright" }) |level| {
        var ansi = model.object();
        for (model.ansi_names, keys, 0..) |name, key, i| {
            const basekey = if (std.mem.eql(u8, level, "bright") and i == 0) "base03" else if (std.mem.eql(u8, level, "bright") and i == 7) "base07" else key;
            var hex = base.object.get(basekey).?.object.get(variant).?.object.get("color").?.string;
            if (i == 0 and std.mem.eql(u8, level, "normal")) hex = model.get(v, "surface");
            if (i == 7) hex = model.get(v, "on_surface");
            if (input) |in| if (in.object.get(level)) |group| if (group.object.get(name)) |override| {
                hex = override.string;
            };
            try model.set(a, &ansi, name, hex);
        }
        try t.object.put(a, level, ansi);
    }
    if (input) |in| {
        var it = in.object.iterator();
        while (it.next()) |item| if (item.value_ptr.* == .string) try model.set(a, &t, item.key_ptr.*, item.value_ptr.string);
    }
    return t;
}
pub fn compile(a: std.mem.Allocator, bytes: []const u8, d: *model.Diagnostic) !Document {
    const source = try model.parse(a, bytes, d);
    var full = try @import("package_model.zig").parse(std.json.Value, a, @embedFile("material/palette.json"), 131072);
    const colors = full.object.get("colors").?;
    const base = full.object.get("base16").?;
    const dark_source = source.dark orelse source.light.?;
    const light_source = source.light orelse source.dark.?;
    const dark = try resolveVariant(a, dark_source, if (source.dark != null) "dark" else "light", colors, d);
    const light = if (source.dark == null or source.light == null) dark else try resolveVariant(a, light_source, "light", colors, d);
    var resolved = model.object();
    for (model.roles) |role| try resolved.object.put(a, role, try modes(a, model.get(dark, role), model.get(light, role)));
    const td = try terminal(a, dark_source, dark, base, if (source.dark != null) "dark" else "light");
    const tl = if (source.dark == null or source.light == null) td else try terminal(a, light_source, light, base, "light");
    for ([_][]const u8{ "background", "foreground", "cursor", "cursorText", "selectionBg", "selectionFg" }) |key| try resolved.object.put(a, try std.fmt.allocPrint(a, "terminal_{s}", .{if (std.mem.eql(u8, key, "cursorText")) "cursor_text" else if (std.mem.eql(u8, key, "selectionBg")) "selection_bg" else if (std.mem.eql(u8, key, "selectionFg")) "selection_fg" else key}), try modes(a, model.get(td, key), model.get(tl, key)));
    for ([_][]const u8{ "normal", "bright" }) |level| for (model.ansi_names) |name| try resolved.object.put(a, try std.fmt.allocPrint(a, "terminal_{s}_{s}", .{ level, name }), try modes(a, model.get(td.object.get(level).?, name), model.get(tl.object.get(level).?, name)));
    var base16 = model.object();
    var it = base.object.iterator();
    while (it.next()) |item| try base16.object.put(a, item.key_ptr.*, item.value_ptr.*);
    for ([_][]const u8{ "base00", "base01", "base02", "base03", "base04", "base05", "base06", "base07" }, [_][]const u8{ "surface", "surface_container_low", "surface_container", "outline", "on_surface_variant", "on_surface", "on_surface", "on_surface" }) |key, role| try base16.object.put(a, key, try modes(a, model.get(dark, role), model.get(light, role)));
    for ([_][]const u8{ "base08", "base0b", "base0a", "base0d", "base0e", "base0c" }, [_][]const u8{ "red", "green", "yellow", "blue", "magenta", "cyan" }) |key, name| try base16.object.put(a, key, try modes(a, model.get(td.object.get("normal").?, name), model.get(tl.object.get("normal").?, name)));
    try full.object.put(a, "colors", resolved);
    try full.object.put(a, "base16", base16);
    // Matugen requires these transport ramps. They are inherited defaults, not
    // tone ramps generated from this palette; authored semantic colors are exact.
    const render = try std.json.Stringify.valueAlloc(a, full, .{});
    const identity = try std.json.Stringify.valueAlloc(a, .{ .compiler = model.compiler_version, .source = source, .render = render }, .{});
    return .{ .source = source, .dark = project(dark), .light = project(light), .render_json = render, .digest = @import("package_model.zig").hash(identity), .dark_hover = .{ model.get(dark, "hover"), model.get(dark, "on_hover") }, .light_hover = .{ model.get(light, "hover"), model.get(light, "on_hover") } };
}

test "minimal palette preserves exact colors and single variant; readable derivatives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: model.Diagnostic = .{};
    const doc = try compile(arena.allocator(), "{\"dark\":{\"surface\":\"#101c19\",\"on_surface\":\"#e8f4e9\",\"primary\":\"#a4dfb0\"}}", &diagnostic);
    try theme.validate(doc.dark);
    try theme.validate(doc.light);
    try std.testing.expectEqualStrings("#a4dfb0", doc.dark.primary);
    try std.testing.expectEqualStrings(doc.dark.surface, doc.light.surface);
    try @import("render_data.zig").validate(arena.allocator(), doc.render_json, "dark", doc.dark);
}
test "Noctalia accents are independent of secondary text and aliases report conflicts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: model.Diagnostic = .{};
    const doc = try compile(a, "{\"dark\":{\"mSurface\":\"#101c19\",\"mOnSurface\":\"#e8f4e9\",\"mPrimary\":\"#a4dfb0\",\"mSecondary\":\"#abcdef\"}}", &d);
    try std.testing.expect(!std.mem.eql(u8, doc.dark.secondary, "#abcdef"));
    const render = try @import("package_model.zig").parse(std.json.Value, a, doc.render_json, 131072);
    try std.testing.expectEqualStrings("#abcdef", render.object.get("colors").?.object.get("secondary").?.object.get("dark").?.object.get("color").?.string);
    try std.testing.expectError(error.InvalidPalette, compile(a, "{\"dark\":{\"surface\":\"#101c19\",\"mSurface\":\"#000000\",\"on_surface\":\"#e8f4e9\",\"primary\":\"#a4dfb0\"}}", &d));
    try std.testing.expectEqualStrings("$.dark.mSurface", d.path);
    try std.testing.expectError(error.InsufficientContrast, compile(a, "{\"dark\":{\"surface\":\"#101c19\",\"on_surface\":\"#101c19\",\"primary\":\"#a4dfb0\"}}", &d));
    try std.testing.expect(d.ratio.? < 4.5);
}
test "two variants and explicit terminal colors survive expansion and legacy augmentation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: model.Diagnostic = .{};
    const doc = try compile(a,
        \\{"dark":{"surface":"#101c19","on_surface":"#e8f4e9","primary":"#a4dfb0","terminal":{"cursor":"#123456","normal":{"red":"#abcdef"},"bright":{"red":"#fedcba"}}},"light":{"surface":"#ffffff","on_surface":"#101c19","primary":"#123456"}}
    , &d);
    try std.testing.expectEqualStrings("#ffffff", doc.light.surface);
    var full = try @import("package_model.zig").parse(std.json.Value, a, doc.render_json, 131072);
    try @import("terminal_colors.zig").populate(a, &full, "kitty");
    const colors = full.object.get("colors").?;
    for ([_][]const u8{ "terminal_cursor", "terminal_normal_red", "terminal_bright_red" }, [_][]const u8{ "#123456", "#abcdef", "#fedcba" }) |key, hex| try std.testing.expectEqualStrings(hex, colors.object.get(key).?.object.get("dark").?.object.get("color").?.string);
    try @import("render_data.zig").validate(a, doc.render_json, "light", doc.light);
    var legacy = try @import("package_model.zig").parse(std.json.Value, a, @embedFile("material/palette.json"), 131072);
    const cursor = legacy.object.get("colors").?.object.get("on_surface").?;
    try @import("terminal_colors.zig").populate(a, &legacy, "kitty");
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, cursor, .{}), try std.json.Stringify.valueAlloc(a, legacy.object.get("colors").?.object.get("terminal_cursor").?, .{}));
}
test "malformed palette fields are rejected before deriving colors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: model.Diagnostic = .{};
    const cases = [_][]const u8{ "{}", "{\"dark\":{}}", "{\"dark\":[]}", "{\"dark\":{\"surface\":\"red\"}}", "{\"dark\":{\"unknown\":\"#abcdef\"}}", "{\"dark\":{\"terminal\":{\"bright\":{\"orange\":\"#abcdef\"}}}}" };
    for (cases) |bytes| {
        if (compile(a, bytes, &d)) |_| return error.InvalidInputAccepted else |_| {}
    }
}
test "a light-only source supplies identical semantic and terminal colors in both modes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: model.Diagnostic = .{};
    const doc = try compile(a,
        \\{"light":{"surface":"#f5fbf6","on_surface":"#17231a","primary":"#28633b","hover":"#d2e3d6","on_hover":"#17231a","terminal":{"bright":{"red":"#a12835"}}}}
    , &d);
    inline for (@typeInfo(theme.Palette).@"struct".fields) |field| try std.testing.expectEqualStrings(@field(doc.dark, field.name), @field(doc.light, field.name));
    const full = try @import("package_model.zig").parse(std.json.Value, a, doc.render_json, 131072);
    for (full.object.get("colors").?.object.values()) |value| try std.testing.expectEqualStrings(value.object.get("dark").?.object.get("color").?.string, value.object.get("light").?.object.get("color").?.string);
    try std.testing.expect(std.mem.indexOf(u8, try shellCss(a, doc, false), "#d2e3d6") != null);
}
