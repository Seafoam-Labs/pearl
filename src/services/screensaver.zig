//! Throwback screensaver animations shared by the lock and the desktop idle
//! path. The mode is a runtime preference (idle.screensaver); the panel only
//! powers off after a further timeout owned by the caller, so short idle
//! periods never lose the display. Drawing is GTK4 DrawingArea + Cairo on
//! ordinary surfaces: the lock swaps in a per-view overlay child, the shell
//! maps layer-shell windows through Overlay.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const glib = @import("glib2");
const cairo = @import("cairo1");
const layer = @import("gtk4layershell1");
const policy = @import("idle_policy.zig");
pub const Mode = policy.Screensaver;

const frame_ms = 33;
const star_count = 512;
const star_depth = 1.0;
const matrix_cols = 256;
const matrix_cell = 18.0;
const matrix_trail = 16;
const mystify_shapes = 2;
const mystify_sides = 4;
const mystify_trail = 64;
const glyphs = [_][:0]const u8{ "ア", "イ", "ウ", "エ", "オ", "カ", "キ", "ク", "ケ", "コ", "サ", "シ", "ス", "セ", "ソ", "タ", "チ", "ツ", "テ", "ト", "ナ", "ニ", "ヌ", "ネ", "ノ", "ハ", "ヒ", "フ", "ヘ", "ホ", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "Z", "X", "P", "E", "A", "R", "L" };

const Star = struct { x: f64, y: f64, z: f64, pz: f64 };
const Point = struct { x: f64, y: f64 };
const Vertex = struct { x: f64, y: f64, vx: f64, vy: f64 };
const Column = struct { head: f64, speed: f64 };

pub const Saver = struct {
    mode: Mode = .off,
    active: bool = false,
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),
    source: c_uint = 0,
    tick: u64 = 0,
    stars: [star_count]Star = undefined,
    cols: [matrix_cols]Column = undefined,
    verts: [mystify_shapes][mystify_sides]Vertex = undefined,
    ring: [mystify_trail][mystify_shapes][mystify_sides]Point = undefined,
    ring_i: usize = 0,
    ring_n: usize = 0,
    /// Every drawing area currently presenting this saver; one shared
    /// animation state drives all monitors, each draw call scaling to its
    /// own width and height.
    areas: [64]?*gtk.DrawingArea = @splat(null),

    pub fn attach(self: *Saver, area: *gtk.DrawingArea) void {
        for (&self.areas) |*slot| if (slot.* == null) {
            slot.* = area;
            return;
        };
    }
    pub fn detach(self: *Saver, area: *gtk.DrawingArea) void {
        for (&self.areas) |*slot| if (slot.* == area) {
            slot.* = null;
            return;
        };
    }
    pub fn start(self: *Saver, mode: Mode) void {
        if (mode == .off) return;
        self.mode = mode;
        self.prng = std.Random.DefaultPrng.init(@bitCast(glib.getRealTime()));
        self.reset();
        self.active = true;
        if (self.source == 0) self.source = glib.timeoutAdd(frame_ms, frame, self);
    }
    pub fn stop(self: *Saver) void {
        self.active = false;
        self.mode = .off;
        if (self.source != 0) {
            _ = glib.Source.remove(self.source);
            self.source = 0;
        }
    }
    fn size(self: *const Saver) struct { w: f64, h: f64 } {
        for (self.areas) |slot| if (slot) |area| {
            const widget = area.as(gtk.Widget);
            if (widget.getWidth() < 64 or widget.getHeight() < 64) continue;
            return .{ .w = @floatFromInt(widget.getWidth()), .h = @floatFromInt(widget.getHeight()) };
        };
        return .{ .w = 1024, .h = 640 };
    }
    fn reset(self: *Saver) void {
        const r = self.prng.random();
        const dim = self.size();
        self.tick = 0;
        switch (self.mode) {
            .off => {},
            .starfield => for (&self.stars) |*s| self.respawn(s, true),
            .matrix => {
                const rows = @max(4.0, dim.h / matrix_cell);
                for (&self.cols) |*c| {
                    c.head = -r.float(f64) * rows;
                    c.speed = 4 + r.float(f64) * 10;
                }
            },
            .mystify => {
                for (&self.verts) |*shape| for (shape) |*v| {
                    v.* = .{
                        .x = r.float(f64) * dim.w,
                        .y = r.float(f64) * dim.h,
                        .vx = (r.float(f64) * 2 - 1) * 160,
                        .vy = (r.float(f64) * 2 - 1) * 160,
                    };
                };
                self.ring_i = 0;
                self.ring_n = 0;
            },
        }
    }
    fn frame(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Saver = @ptrCast(@alignCast(data.?));
        if (!self.active) return 1;
        const dt: f64 = @as(f64, frame_ms) / 1000.0;
        const dim = self.size();
        self.tick += 1;
        switch (self.mode) {
            .off => {},
            .starfield => {
                for (&self.stars) |*s| {
                    s.pz = s.z;
                    s.z -= 0.35 * dt * (0.5 + s.z);
                    if (s.z <= 0.02) self.respawn(s, false);
                }
            },
            .matrix => {
                const rows = @max(4.0, dim.h / matrix_cell);
                const used = @min(matrix_cols, @as(usize, @intFromFloat(@ceil(dim.w / matrix_cell))));
                for (self.cols[0..used]) |*c| {
                    c.head += c.speed * dt;
                    if (c.head - matrix_trail > rows and self.prng.random().int(u8) < 8) {
                        c.head = -self.prng.random().float(f64) * rows * 0.5;
                        c.speed = 4 + self.prng.random().float(f64) * 10;
                    }
                }
            },
            .mystify => {
                for (&self.verts) |*shape| for (shape) |*v| {
                    v.x += v.vx * dt;
                    v.y += v.vy * dt;
                    if (v.x <= 0 or v.x >= dim.w) {
                        v.x = std.math.clamp(v.x, 0, dim.w);
                        v.vx = -v.vx;
                    }
                    if (v.y <= 0 or v.y >= dim.h) {
                        v.y = std.math.clamp(v.y, 0, dim.h);
                        v.vy = -v.vy;
                    }
                };
                for (self.verts, 0..) |shape, si| for (shape, 0..) |v, vi| {
                    self.ring[self.ring_i][si][vi] = .{ .x = v.x, .y = v.y };
                };
                self.ring_i = (self.ring_i + 1) % mystify_trail;
                self.ring_n = @min(self.ring_n + 1, mystify_trail);
            },
        }
        for (self.areas) |slot| if (slot) |area| area.as(gtk.Widget).queueDraw();
        return 1;
    }
    fn respawn(self: *Saver, s: *Star, spread: bool) void {
        const r = self.prng.random();
        s.x = r.float(f64) * 2 - 1;
        s.y = r.float(f64) * 2 - 1;
        s.z = if (spread) r.float(f64) * star_depth else star_depth;
        s.pz = s.z;
    }
    fn hsv(h: f64, s: f64, v: f64) [3]f64 {
        const sector = @mod(h, 360) / 60;
        const c = v * s;
        const x = c * (1 - @abs(@mod(sector, 2) - 1));
        const m = v - c;
        const rgb: [3]f64 = switch (@as(u8, @intFromFloat(@min(sector, 5.99)))) {
            0 => .{ c, x, 0 },
            1 => .{ x, c, 0 },
            2 => .{ 0, c, x },
            3 => .{ 0, x, c },
            4 => .{ x, 0, c },
            else => .{ c, 0, x },
        };
        return .{ rgb[0] + m, rgb[1] + m, rgb[2] + m };
    }
    fn glyph(col: u64, row: i64, tick: u64) [:0]const u8 {
        var h = col *% 0x9E3779B97F4A7C15 ^ @as(u64, @bitCast(row)) *% 0xC2B2AE3D27D4EB4F ^ tick *% 0x165667B19E3779F9;
        h ^= h >> 29;
        h *%= 0xBF58476D1CE4E5B9;
        h ^= h >> 32;
        return glyphs[h % glyphs.len];
    }
    fn text(cr: *cairo.Context, str: [:0]const u8, x: f64, y: f64, size_pt: f64) void {
        cr.selectFontFace("sans", .normal, .normal);
        cr.setFontSize(size_pt);
        var extents: cairo.TextExtents = undefined;
        cr.textExtents(str, &extents);
        cr.moveTo(x - extents.width / 2 - extents.x_bearing, y + extents.height / 2);
        cr.showText(str);
    }
    pub fn draw(area: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        _ = area;
        const self: *Saver = @ptrCast(@alignCast(data.?));
        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(height);
        cr.setSourceRgb(0, 0, 0);
        cr.paint();
        if (!self.active) return;
        switch (self.mode) {
            .off => {},
            .starfield => {
                const cx = w / 2;
                const cy = h / 2;
                const scale = @min(w, h) * 0.9;
                cr.setLineCap(.round);
                for (self.stars) |s| {
                    const sx = cx + s.x / s.z * scale;
                    const sy = cy + s.y / s.z * scale;
                    if (sx < -50 or sx > w + 50 or sy < -50 or sy > h + 50) continue;
                    const px = cx + s.x / s.pz * scale;
                    const py = cy + s.y / s.pz * scale;
                    const near = std.math.clamp(1 - s.z / star_depth, 0, 1);
                    const ink = 0.25 + near * 0.75;
                    cr.setSourceRgb(ink, ink, ink);
                    cr.setLineWidth(0.6 + near * 2.4);
                    cr.moveTo(px, py);
                    cr.lineTo(sx, sy);
                    cr.stroke();
                }
            },
            .matrix => {
                const used = @min(matrix_cols, @as(usize, @intFromFloat(@ceil(w / matrix_cell))));
                for (self.cols[0..used], 0..) |c, col| {
                    const base: i64 = @intFromFloat(@floor(c.head));
                    var k: i64 = 0;
                    while (k < matrix_trail) : (k += 1) {
                        const row = base - k;
                        if (row < 0) break;
                        const y: f64 = @as(f64, @floatFromInt(row)) * matrix_cell + matrix_cell - 4;
                        if (y > h) continue;
                        const x: f64 = @as(f64, @floatFromInt(col)) * matrix_cell + 2;
                        const fade = 1 - @as(f64, @floatFromInt(k)) / matrix_trail;
                        if (k == 0) cr.setSourceRgba(0.75, 1, 0.75, fade) else cr.setSourceRgba(0.1, 0.9, 0.25, fade);
                        text(cr, glyph(col, row, self.tick / 6), x + matrix_cell / 2 - 2, y - matrix_cell / 2 + 2, matrix_cell - 4);
                    }
                }
            },
            .mystify => {
                cr.setLineWidth(1.6);
                var i: usize = 0;
                while (i < self.ring_n) : (i += 1) {
                    const slot = (self.ring_i + mystify_trail - self.ring_n + i) % mystify_trail;
                    const fade = @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(self.ring_n));
                    for (self.ring[slot], 0..) |shape, si| {
                        const rgb = hsv(fade * 300 + @as(f64, @floatFromInt(si)) * 180, 0.9, 1);
                        cr.setSourceRgba(rgb[0], rgb[1], rgb[2], fade * 0.9);
                        cr.moveTo(shape[0].x, shape[0].y);
                        for (shape[1..]) |p| cr.lineTo(p.x, p.y);
                        cr.closePath();
                        cr.stroke();
                    }
                }
            },
        }
    }
};

/// Desktop-side presentation: one borderless layer-shell overlay window per
/// monitor, mapped above every application. Input is never grabbed; wake
/// detection stays with the compositor idle notifications the shell already
/// listens to, so the overlay only needs to appear and disappear.
pub const Overlay = struct {
    windows: [32]?*gtk.Window = @splat(null),
    areas: [32]?*gtk.DrawingArea = @splat(null),
    count: usize = 0,

    pub fn show(self: *Overlay, display: *gdk.Display, saver: *Saver) !void {
        if (self.count != 0) return;
        if (layer.isSupported() == 0) return error.LayerShellUnavailable;
        const cursor = gdk.Cursor.newFromName("none", null);
        const monitors = display.getMonitors();
        var made: usize = 0;
        for (0..monitors.getNItems()) |i| {
            if (made == self.windows.len) break;
            const item = monitors.getItem(@intCast(i)) orelse continue;
            const monitor: *gdk.Monitor = @ptrCast(@alignCast(item));
            defer monitor.unref();
            const window = gtk.Window.new();
            window.ref();
            layer.initForWindow(window);
            layer.setMonitor(window, monitor);
            layer.setNamespace(window, "pearl:screensaver");
            layer.setLayer(window, .overlay);
            layer.setKeyboardMode(window, .none);
            for ([_]layer.Edge{ .top, .bottom, .left, .right }) |edge| layer.setAnchor(window, edge, 1);
            const area = gtk.DrawingArea.new();
            area.setDrawFunc(Saver.draw, saver, null);
            window.setChild(area.as(gtk.Widget));
            if (cursor) |c| window.as(gtk.Widget).setCursor(c);
            saver.attach(area);
            window.present();
            self.windows[made] = window;
            self.areas[made] = area;
            made += 1;
        }
        if (made == 0) return error.NoMonitors;
        self.count = made;
    }
    pub fn hide(self: *Overlay, saver: *Saver) void {
        for (0..self.count) |i| {
            if (self.areas[i]) |area| {
                area.setDrawFunc(null, null, null);
                saver.detach(area);
            }
            if (self.windows[i]) |window| {
                window.destroy();
                window.unref();
            }
            self.windows[i] = null;
            self.areas[i] = null;
        }
        self.count = 0;
    }
};
