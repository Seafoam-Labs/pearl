const std = @import("std");
const u = @import("widgets.zig");
const c = u.c;
const m = @import("../core/model.zig");
const Colors = @import("colors.zig").Colors;
pub const Graph = struct {
    history: *m.History,
    duration: *i64,
    colors: *const Colors,
    unit: enum { percent, bytes, rate, celsius, rpm } = .percent,
    accent: usize = 0,
    fixed: ?f64 = null,
    pub fn create(history: *m.History, duration: *i64, colors: *const Colors, accent: usize, height: c_int, fixed: ?f64, key: []const u8) u.W {
        const self = u.a.create(Graph) catch unreachable;
        self.* = .{ .history = history, .duration = duration, .colors = colors, .accent = accent, .fixed = fixed, .unit = if (std.mem.startsWith(u8, key, "disk:") or std.mem.startsWith(u8, key, "net:")) .rate else if (std.mem.eql(u8, key, "memory")) .bytes else if (std.mem.startsWith(u8, key, "sensor:")) (if (accent == 5) .celsius else .rpm) else .percent };
        const area = c.gtk_drawing_area_new().?;
        c.gtk_drawing_area_set_content_height(u.cast(c.GtkDrawingArea, area), height);
        u.expand(area);
        u.class(area, "graph");
        c.gtk_drawing_area_set_draw_func(u.cast(c.GtkDrawingArea, area), draw, self, destroy);
        return area;
    }
    fn destroy(data: ?*anyopaque) callconv(.c) void {
        u.a.destroy(u.cast(Graph, data));
    }
    pub fn draw(area: ?*c.GtkDrawingArea, cr: ?*c.cairo_t, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Graph, data);
        const ctx = cr.?;
        if (width < 2 or height < 2) return;
        const w: @TypeOf(@as(f64, 0)) = @floatFromInt(width);
        const h: f64 = @floatFromInt(height - 12);
        var foreground = self.colors.text;
        var rgb = self.colors.series[self.accent % 6];
        if (self.colors.native and area != null) {
            var color: c.GdkRGBA = undefined;
            c.gtk_widget_get_color(@ptrCast(area.?), &color);
            foreground = .{ color.red, color.green, color.blue };
            rgb = foreground;
        }
        c.cairo_set_source_rgba(ctx, foreground[0], foreground[1], foreground[2], 0.16);
        c.cairo_set_line_width(ctx, 0.5);
        for (0..5) |i| {
            const y = h * @as(f64, @floatFromInt(i)) / 4;
            c.cairo_move_to(ctx, 0, y);
            c.cairo_line_to(ctx, w, y);
        }
        for (0..7) |i| {
            const x = w * @as(f64, @floatFromInt(i)) / 6;
            c.cairo_move_to(ctx, x, 0);
            c.cairo_line_to(ctx, x, h);
        }
        c.cairo_stroke(ctx);
        const history = self.history;
        if (history.len == 0) return;
        const last = history.at(history.len - 1).time;
        const duration = self.duration.*;
        const from = last - duration;
        var maximum: f64 = 1;
        if (self.fixed) |v| maximum = v else {
            for (0..history.len) |i| {
                const point = history.at(i);
                if (point.time < from) continue;
                if (point.value) |v| maximum = @max(maximum, v * 1.15);
                if (point.second) |v| maximum = @max(maximum, v * 1.15);
            }
        }
        for (0..2) |series| {
            c.cairo_set_source_rgba(ctx, rgb[0], rgb[1], rgb[2], if (series == 0) 1 else 0.65);
            c.cairo_set_line_width(ctx, 1.6);
            var dash = [_]f64{ 5, 4 };
            if (series == 1) c.cairo_set_dash(ctx, &dash, 2, 0) else c.cairo_set_dash(ctx, null, 0, 0);
            var started = false;
            var previous_x: f64 = -2;
            for (0..history.len) |i| {
                const point = history.at(i);
                if (point.time < from) continue;
                const value = (if (series == 0) point.value else point.second) orelse {
                    started = false;
                    continue;
                };
                if (!std.math.isFinite(value)) {
                    started = false;
                    continue;
                }
                const x = w * @as(f64, @floatFromInt(point.time - from)) / @as(f64, @floatFromInt(duration));
                if (started and x - previous_x < 0.75 and i + 1 < history.len) continue;
                const y = h - h * std.math.clamp(value / maximum, 0, 1);
                if (!started) c.cairo_move_to(ctx, x, y) else c.cairo_line_to(ctx, x, y);
                started = true;
                previous_x = x;
            }
            c.cairo_stroke(ctx);
        }
        if (height > 100) {
            c.cairo_set_dash(ctx, null, 0, 0);
            c.cairo_set_source_rgba(ctx, rgb[0], rgb[1], rgb[2], 0.8);
            c.cairo_set_font_size(ctx, 10);
            var buf: [128]u8 = undefined;
            const scaled = u.bytes(maximum);
            const scale = if (self.unit == .bytes or self.unit == .rate) std.fmt.bufPrintZ(&buf, "0 – {s}{s} · {d}s", .{ scaled.slice(), if (self.unit == .rate) "/s" else "", @divTrunc(duration, 1000000) }) catch return else std.fmt.bufPrintZ(&buf, "0 – {d:.1}{s} · {d}s", .{ maximum, switch (self.unit) {
                .percent => "%",
                .celsius => "°C",
                .rpm => " RPM",
                else => "",
            }, @divTrunc(duration, 1000000) }) catch return;
            c.cairo_move_to(ctx, 4, @floatFromInt(height - 1));
            c.cairo_show_text(ctx, scale);
        }
    }
};

test "drawing uses changed colors without a new history sample" {
    var history: m.History = .{};
    history.add(0, 50, null);
    history.add(1000000, 50, null);
    var duration: i64 = 1000000;
    var colors: Colors = .{ .native = false };
    var graph: Graph = .{ .history = &history, .duration = &duration, .colors = &colors, .fixed = 100 };
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 100, 100).?;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface).?;
    defer c.cairo_destroy(cr);
    c.cairo_set_antialias(cr, c.CAIRO_ANTIALIAS_NONE);
    for ([_][3]f64{ .{ 1, 0, 0 }, .{ 0, 1, 0 } }, [_]u32{ 0x00ff0000, 0x0000ff00 }) |color, expected| {
        c.cairo_set_source_rgb(cr, 0, 0, 0);
        c.cairo_paint(cr);
        colors.series[0] = color;
        Graph.draw(null, cr, 100, 100, &graph);
        c.cairo_surface_flush(surface);
        const stride: usize = @intCast(c.cairo_image_surface_get_stride(surface));
        const pixels = c.cairo_image_surface_get_data(surface);
        const pixel: *align(1) const u32 = @ptrCast(pixels + 44 * stride + 50 * 4);
        try std.testing.expectEqual(expected, pixel.* & 0x00ffffff);
        try std.testing.expectEqual(@as(usize, 2), history.len);
    }
}
