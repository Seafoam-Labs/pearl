const std = @import("std");
const u = @import("widgets.zig");
const c = u.c;
const m = @import("../core/model.zig");
pub const Graph = struct {
    history: *m.History,
    duration: *i64,
    light: *bool,
    native: ?*bool = null,
    unit: enum { percent, bytes, rate, celsius, rpm } = .percent,
    accent: usize = 0,
    fixed: ?f64 = null,
    pub fn create(history: *m.History, duration: *i64, light: *bool, native: *bool, accent: usize, height: c_int, fixed: ?f64, key: []const u8) u.W {
        const self = u.a.create(Graph) catch unreachable;
        self.* = .{ .history = history, .duration = duration, .light = light, .native = native, .accent = accent, .fixed = fixed, .unit = if (std.mem.startsWith(u8, key, "disk:") or std.mem.startsWith(u8, key, "net:")) .rate else if (std.mem.eql(u8, key, "memory")) .bytes else if (std.mem.startsWith(u8, key, "sensor:")) (if (accent == 5) .celsius else .rpm) else .percent };
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
        c.cairo_set_source_rgba(ctx, if (self.light.*) 0.35 else 0.65, if (self.light.*) 0.3 else 0.6, if (self.light.*) 0.4 else 0.7, 0.16);
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
        const dark = [_][3]f64{ .{ 0.816, 0.737, 1 }, .{ 0.93, 0.737, 0.627 }, .{ 0.65, 0.84, 0.71 }, .{ 0.655, 0.784, 0.98 }, .{ 0.91, 0.71, 0.83 }, .{ 0.86, 0.81, 0.58 } };
        const light = [_][3]f64{ .{ 0.404, 0.314, 0.643 }, .{ 0.58, 0.33, 0.18 }, .{ 0.2, 0.44, 0.3 }, .{ 0.22, 0.38, 0.59 }, .{ 0.58, 0.32, 0.47 }, .{ 0.46, 0.4, 0.12 } };
        var rgb = (if (self.light.*) light else dark)[self.accent % 6];
        if (self.native) |native| {
            if (native.* and area != null) {
                var color: c.GdkRGBA = undefined;
                c.gtk_widget_get_color(@ptrCast(area.?), &color);
                rgb = .{ color.red, color.green, color.blue };
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
