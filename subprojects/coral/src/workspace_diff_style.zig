//! Review paragraphs use the editor scheme's actual surface and text colors.
//! Signs and conflict marker text stay visible with every color treatment.
const std = @import("std");
const u = @import("c.zig");
const c = u.c;
const Palette = @import("appearance_client").theme.Palette;

extern fn gtk_source_style_scheme_get_style(scheme: *c.GtkSourceStyleScheme, id: [*:0]const u8) ?*anyopaque;

const Role = enum { added, removed, context };
const names = [_][*:0]const u8{ "review-addition", "review-removal", "review-context" };

fn color(hex: []const u8) c.GdkRGBA {
    const value = u.z(hex);
    defer u.a.free(value);
    var rgba: c.GdkRGBA = undefined;
    std.debug.assert(c.gdk_rgba_parse(&rgba, value) != 0);
    return rgba;
}

fn luminance(rgb: c.GdkRGBA) f64 {
    const linear = struct {
        fn value(component: f32) f64 {
            const s: f64 = component;
            return if (s <= 0.04045) s / 12.92 else std.math.pow(f64, (s + 0.055) / 1.055, 2.4);
        }
    }.value;
    return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue);
}

fn schemeColor(style: ?*anyopaque, property: [*:0]const u8, fallback: []const u8) c.GdkRGBA {
    if (style) |s| {
        var value: ?[*:0]u8 = null;
        c.g_object_get(s, property, &value, @as(?*anyopaque, null));
        if (value) |raw| {
            defer c.g_free(raw);
            var rgba: c.GdkRGBA = undefined;
            if (c.gdk_rgba_parse(&rgba, raw) != 0) return rgba;
        }
    }
    return color(fallback);
}

pub fn configure(buffer: *c.GtkTextBuffer, scheme: ?*c.GtkSourceStyleScheme, palette: Palette) void {
    const style = if (scheme) |s| gtk_source_style_scheme_get_style(s, "text") else null;
    const base = schemeColor(style, "background", palette.surface);
    const text = schemeColor(style, "foreground", palette.text);
    const accents = [_]c.GdkRGBA{ color(if (luminance(base) < 0.2) "#70d795" else "#22834f"), color(palette.error_color), color(palette.primary) };
    for (accents, names) |accent, name| {
        var bg = base;
        inline for (.{ "red", "green", "blue" }) |channel| @field(bg, channel) = @field(base, channel) * 0.82 + @field(accent, channel) * 0.18;
        bg.alpha = 1;
        const light = luminance(bg);
        const ink = luminance(text);
        const ratio = (@max(ink, light) + 0.05) / (@min(ink, light) + 0.05);
        const fg = if (ratio >= 4.5) text else color(if (light > 0.179) "#000000" else "#ffffff");
        const tag = c.gtk_text_tag_table_lookup(c.gtk_text_buffer_get_tag_table(buffer), name) orelse c.gtk_text_buffer_create_tag(buffer, name, @as(?[*:0]const u8, null)).?;
        c.g_object_set(tag, "foreground-rgba", &fg, "paragraph-background-rgba", &bg, @as(?*anyopaque, null));
    }
}

pub fn setText(buffer: *c.GtkTextBuffer, text: []const u8, conflict: bool) void {
    c.gtk_text_buffer_set_text(buffer, text.ptr, @intCast(text.len));
    var lines = std.mem.splitScalar(u8, text, '\n');
    var section: ?Role = null;
    var active: ?Role = null;
    var line: c_int = 0;
    var start: c_int = 0;
    while (lines.next()) |row| : (line += 1) {
        const role: ?Role = if (conflict) blk: {
            if (std.mem.eql(u8, row, "<<<<<<< Unsaved buffer")) section = .removed else if (section != null and std.mem.eql(u8, row, "||||||| Shared base")) section = .context else if (section != null and std.mem.eql(u8, row, "=======")) section = .added;
            const mark = section;
            if (section != null and std.mem.eql(u8, row, ">>>>>>> Agent change")) section = null;
            break :blk mark;
        } else if (std.mem.startsWith(u8, row, "+")) .added else if (std.mem.startsWith(u8, row, "-")) .removed else if (std.mem.startsWith(u8, std.mem.trimStart(u8, row, " "), "@@ ")) .context else null;
        if (role != active) {
            if (active) |previous| apply(buffer, previous, start, line);
            start = line;
            active = role;
        }
    }
    if (active) |previous| apply(buffer, previous, start, line);
}

fn apply(buffer: *c.GtkTextBuffer, role: Role, start: c_int, end: c_int) void {
    const tag = c.gtk_text_tag_table_lookup(c.gtk_text_buffer_get_tag_table(buffer), names[@backingInt(role)]) orelse return;
    var first: c.GtkTextIter = undefined;
    var last: c.GtkTextIter = undefined;
    _ = c.gtk_text_buffer_get_iter_at_line(buffer, &first, start);
    if (end < c.gtk_text_buffer_get_line_count(buffer)) {
        _ = c.gtk_text_buffer_get_iter_at_line(buffer, &last, end);
    } else c.gtk_text_buffer_get_end_iter(buffer, &last);
    c.gtk_text_buffer_apply_tag(buffer, tag, &first, &last);
}
