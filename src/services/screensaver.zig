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
const ocean_cell = 28.0;
const mystify_shapes = 2;
const mystify_sides = 4;
const mystify_trail = 64;
const pipes_cell = 24.0;
const pipes_walkers = 2;
const pipes_max = 4096;
const qix_trail = 48;
const maze_max = 15000;
const maze_cell = 16.0;
const life_max = 16000;
const life_cell = 12.0;
const glyphs = [_][:0]const u8{ "ア", "イ", "ウ", "エ", "オ", "カ", "キ", "ク", "ケ", "コ", "サ", "シ", "ス", "セ", "ソ", "タ", "チ", "ツ", "テ", "ト", "ナ", "ニ", "ヌ", "ネ", "ノ", "ハ", "ヒ", "フ", "ヘ", "ホ", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "Z", "X", "P", "E", "A", "R", "L" };
const ocean_glyphs = [_][:0]const u8{ "🐟", "🐠", "", "🐬", "🐳", "", "", "", "🦑", "🦀", "", "🐚", "🌊", "⚓" };

fn fallCell(mode: Mode) f64 {
    return if (mode == .ocean_fall) ocean_cell else matrix_cell;
}

const Star = struct { x: f64, y: f64, z: f64, pz: f64 };
const Point = struct { x: f64, y: f64 };
const Vertex = struct { x: f64, y: f64, vx: f64, vy: f64 };
const Column = struct { head: f64, speed: f64 };
const PipeWalker = struct { gx: i32, gy: i32, dx: i32, dy: i32, hue: f64 };
const PipeSegment = struct { x0: f32, y0: f32, x1: f32, y1: f32, hue: f32, joint: bool };

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
    pipes: [pipes_walkers]PipeWalker = undefined,
    /// Recorded pipe artwork, repainted every frame. GTK's recorder keeps a
    /// Cairo snapshot of anything a draw callback painted, so mutating a
    /// presented surface would assert; a plain segment list sidesteps that.
    pipes_segs: [pipes_max]PipeSegment = undefined,
    pipes_n: usize = 0,
    pipes_cols: i32 = 32,
    pipes_rows: i32 = 24,
    qix_v: [2]Vertex = undefined,
    qix_ring: [qix_trail][2]Point = undefined,
    qix_i: usize = 0,
    qix_n: usize = 0,
    /// Maze carve state: bits 0-3 are opened right/down/left/up, bit 4 visited.
    maze_walls: [maze_max]u8 = undefined,
    maze_stack: [maze_max]u32 = undefined,
    maze_sp: usize = 0,
    maze_cols: i32 = 0,
    maze_rows: i32 = 0,
    maze_head: i32 = -1,
    maze_hold: u32 = 0,
    life_a: [life_max]u8 = undefined,
    life_b: [life_max]u8 = undefined,
    life_cols: i32 = 0,
    life_rows: i32 = 0,
    life_front: bool = false,
    life_pop: u32 = 0,
    life_gen: u32 = 0,
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
            .matrix, .ocean_fall => {
                const rows = @max(4.0, dim.h / fallCell(self.mode));
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
            .pipes => {
                self.pipes_n = 0;
                self.pipes_cols = @max(4, @as(i32, @intFromFloat(dim.w / pipes_cell)));
                self.pipes_rows = @max(4, @as(i32, @intFromFloat(dim.h / pipes_cell)));
                self.initPipes();
            },
            .qix => {
                for (&self.qix_v) |*v| {
                    v.* = .{
                        .x = r.float(f64) * dim.w,
                        .y = r.float(f64) * dim.h,
                        .vx = (r.float(f64) * 2 - 1) * 260,
                        .vy = (r.float(f64) * 2 - 1) * 260,
                    };
                }
                self.qix_i = 0;
                self.qix_n = 0;
            },
            .maze => {
                self.maze_cols = @min(150, @max(8, @as(i32, @intFromFloat(dim.w / maze_cell))));
                self.maze_rows = @min(100, @max(8, @as(i32, @intFromFloat(dim.h / maze_cell))));
                const cells: usize = @intCast(self.maze_cols * self.maze_rows);
                @memset(self.maze_walls[0..cells], 0);
                self.maze_stack[0] = 0;
                self.maze_sp = 1;
                self.maze_walls[0] = 16;
                self.maze_head = 0;
                self.maze_hold = 0;
            },
            .life => {
                self.life_cols = @min(160, @max(16, @as(i32, @intFromFloat(dim.w / life_cell))));
                self.life_rows = @min(100, @max(16, @as(i32, @intFromFloat(dim.h / life_cell))));
                self.reseedLife();
            },
        }
    }
    fn reseedLife(self: *Saver) void {
        const r = self.prng.random();
        const cells: usize = @intCast(self.life_cols * self.life_rows);
        for (self.life_a[0..cells]) |*cell| cell.* = @intFromBool(r.int(u8) % 100 < 24);
        @memset(self.life_b[0..cells], 0);
        self.life_front = false;
        self.life_gen = 0;
        self.life_pop = 1;
    }
    fn initPipes(self: *Saver) void {
        const r = self.prng.random();
        const dirs = [_]struct { dx: i32, dy: i32 }{ .{ .dx = 1, .dy = 0 }, .{ .dx = -1, .dy = 0 }, .{ .dx = 0, .dy = 1 }, .{ .dx = 0, .dy = -1 } };
        for (&self.pipes) |*walker| {
            const dir = dirs[r.intRangeAtMost(usize, 0, dirs.len - 1)];
            walker.* = .{
                .gx = r.intRangeAtMost(i32, 0, self.pipes_cols - 1),
                .gy = r.intRangeAtMost(i32, 0, self.pipes_rows - 1),
                .dx = dir.dx,
                .dy = dir.dy,
                .hue = r.float(f64) * 360,
            };
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
            .matrix, .ocean_fall => {
                const cell = fallCell(self.mode);
                const rows = @max(4.0, dim.h / cell);
                const used = @min(matrix_cols, @as(usize, @intFromFloat(@ceil(dim.w / cell))));
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
            .pipes => {
                // One grid step per walker every other tick keeps the crawl
                // at a stately ~11 cells/s regardless of frame rate.
                if (self.tick % 2 == 0) {
                    // A full history wipes the screen and starts a new pattern.
                    if (self.pipes_n + pipes_walkers > pipes_max) self.reset();
                    for (&self.pipes) |*walker| self.pipeStep(walker);
                }
            },
            .qix => {
                for (&self.qix_v) |*v| {
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
                }
                self.qix_ring[self.qix_i] = .{
                    .{ .x = self.qix_v[0].x, .y = self.qix_v[0].y },
                    .{ .x = self.qix_v[1].x, .y = self.qix_v[1].y },
                };
                self.qix_i = (self.qix_i + 1) % qix_trail;
                self.qix_n = @min(self.qix_n + 1, qix_trail);
            },
            .maze => {
                if (self.maze_head >= 0) {
                    var steps: u32 = 0;
                    while (steps < 8 and self.maze_sp > 0) : (steps += 1) self.mazeCarve();
                    if (self.maze_sp == 0) {
                        self.maze_head = -1;
                        self.maze_hold = 90;
                    }
                } else if (self.maze_hold > 0) {
                    self.maze_hold -= 1;
                } else self.reset();
            },
            .life => {
                if (self.tick % 4 == 0) {
                    self.lifeStep();
                    if (self.life_pop < 12 or self.life_gen > 900) self.reset();
                }
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
    fn pipeStep(self: *Saver, walker: *PipeWalker) void {
        const r = self.prng.random();
        const dirs = [_]struct { dx: i32, dy: i32 }{ .{ .dx = 1, .dy = 0 }, .{ .dx = -1, .dy = 0 }, .{ .dx = 0, .dy = 1 }, .{ .dx = 0, .dy = -1 } };
        var dx = walker.dx;
        var dy = walker.dy;
        // Mostly straight runs with the occasional elbow, like the original.
        if (r.float(f64) > 0.65) {
            if (dx != 0) {
                dy = if (r.boolean()) @as(i32, 1) else -1;
                dx = 0;
            } else {
                dx = if (r.boolean()) @as(i32, 1) else -1;
                dy = 0;
            }
        }
        var nx = walker.gx + dx;
        var ny = walker.gy + dy;
        if (nx < 0 or ny < 0 or nx >= self.pipes_cols or ny >= self.pipes_rows) {
            // Walled in: reroute along any in-bounds direction.
            var picked = false;
            var attempts: usize = 0;
            while (attempts < 8 and !picked) : (attempts += 1) {
                const dir = dirs[r.intRangeAtMost(usize, 0, dirs.len - 1)];
                nx = walker.gx + dir.dx;
                ny = walker.gy + dir.dy;
                if (nx >= 0 and ny >= 0 and nx < self.pipes_cols and ny < self.pipes_rows) {
                    dx = dir.dx;
                    dy = dir.dy;
                    picked = true;
                }
            }
            if (!picked) return;
        }
        if (self.pipes_n < pipes_max) {
            self.pipes_segs[self.pipes_n] = .{
                .x0 = @floatCast((@as(f64, @floatFromInt(walker.gx)) + 0.5) * pipes_cell),
                .y0 = @floatCast((@as(f64, @floatFromInt(walker.gy)) + 0.5) * pipes_cell),
                .x1 = @floatCast((@as(f64, @floatFromInt(nx)) + 0.5) * pipes_cell),
                .y1 = @floatCast((@as(f64, @floatFromInt(ny)) + 0.5) * pipes_cell),
                .hue = @floatCast(walker.hue),
                .joint = dx != walker.dx or dy != walker.dy,
            };
            self.pipes_n += 1;
        }
        walker.gx = nx;
        walker.gy = ny;
        walker.dx = dx;
        walker.dy = dy;
        walker.hue += 2;
    }
    /// One recursive-backtracker step: extend from the stack head into a
    /// random unvisited neighbour, or backtrack when walled in.
    fn mazeCarve(self: *Saver) void {
        const r = self.prng.random();
        const cur = self.maze_stack[self.maze_sp - 1];
        const cx: i32 = @intCast(cur % @as(u32, @intCast(self.maze_cols)));
        const cy: i32 = @intCast(cur / @as(u32, @intCast(self.maze_cols)));
        var options: [4]u32 = undefined;
        var count: usize = 0;
        const consider = struct {
            fn f(walls: *[maze_max]u8, ok: bool, n: u32, opts: *[4]u32, cnt: *usize) void {
                if (ok and walls[n] & 16 == 0) {
                    opts[cnt.*] = n;
                    cnt.* += 1;
                }
            }
        }.f;
        const cols_u: u32 = @intCast(self.maze_cols);
        // Saturating math: the index is only read when the bound check passes.
        consider(&self.maze_walls, cx + 1 < self.maze_cols, cur + 1, &options, &count);
        consider(&self.maze_walls, cy + 1 < self.maze_rows, cur + cols_u, &options, &count);
        consider(&self.maze_walls, cx > 0, cur -| 1, &options, &count);
        consider(&self.maze_walls, cy > 0, cur -| cols_u, &options, &count);
        if (count == 0) {
            self.maze_sp -= 1;
            self.maze_head = if (self.maze_sp > 0) @intCast(self.maze_stack[self.maze_sp - 1]) else -1;
            return;
        }
        const n = options[r.intRangeAtMost(usize, 0, count - 1)];
        const nx: i32 = @intCast(n % @as(u32, @intCast(self.maze_cols)));
        const ny: i32 = @intCast(n / @as(u32, @intCast(self.maze_cols)));
        if (nx == cx + 1) {
            self.maze_walls[cur] |= 1;
            self.maze_walls[n] |= 4;
        } else if (ny == cy + 1) {
            self.maze_walls[cur] |= 2;
            self.maze_walls[n] |= 8;
        } else if (nx == cx - 1) {
            self.maze_walls[cur] |= 4;
            self.maze_walls[n] |= 1;
        } else {
            self.maze_walls[cur] |= 8;
            self.maze_walls[n] |= 2;
        }
        self.maze_walls[n] |= 16;
        self.maze_stack[self.maze_sp] = n;
        self.maze_sp += 1;
        self.maze_head = @intCast(n);
    }
    fn lifeStep(self: *Saver) void {
        const cols = self.life_cols;
        const rows = self.life_rows;
        const src = if (self.life_front) &self.life_b else &self.life_a;
        const dst = if (self.life_front) &self.life_a else &self.life_b;
        var pop: u32 = 0;
        var cy: i32 = 0;
        while (cy < rows) : (cy += 1) {
            var cx: i32 = 0;
            while (cx < cols) : (cx += 1) {
                var neighbors: u32 = 0;
                var dy: i32 = -1;
                while (dy <= 1) : (dy += 1) {
                    var dx: i32 = -1;
                    while (dx <= 1) : (dx += 1) {
                        if (dx == 0 and dy == 0) continue;
                        const px = cx + dx;
                        const py = cy + dy;
                        if (px < 0 or py < 0 or px >= cols or py >= rows) continue;
                        neighbors += src[@intCast(py * cols + px)];
                    }
                }
                const alive = src[@intCast(cy * cols + cx)] != 0;
                const next = (alive and (neighbors == 2 or neighbors == 3)) or (!alive and neighbors == 3);
                dst[@intCast(cy * cols + cx)] = @intFromBool(next);
                pop += @intFromBool(next);
            }
        }
        self.life_front = !self.life_front;
        self.life_pop = pop;
        self.life_gen += 1;
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
    fn oceanGlyph(col: u64, row: i64, tick: u64) [:0]const u8 {
        var h = col *% 0x9E3779B97F4A7C15 ^ @as(u64, @bitCast(row)) *% 0xC2B2AE3D27D4EB4F ^ tick *% 0x165667B19E3779F9;
        h ^= h >> 29;
        h *%= 0xBF58476D1CE4E5B9;
        h ^= h >> 32;
        return ocean_glyphs[h % ocean_glyphs.len];
    }
    fn text(cr: *cairo.Context, family: [:0]const u8, str: [:0]const u8, x: f64, y: f64, size_pt: f64) void {
        cr.selectFontFace(family, .normal, .normal);
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
                        text(cr, "sans", glyph(col, row, self.tick / 6), x + matrix_cell / 2 - 2, y - matrix_cell / 2 + 2, matrix_cell - 4);
                    }
                }
            },
            .ocean_fall => {
                const used = @min(matrix_cols, @as(usize, @intFromFloat(@ceil(w / ocean_cell))));
                for (self.cols[0..used], 0..) |c, col| {
                    const base: i64 = @intFromFloat(@floor(c.head));
                    var k: i64 = 0;
                    while (k < matrix_trail) : (k += 1) {
                        const row = base - k;
                        if (row < 0) break;
                        const y: f64 = @as(f64, @floatFromInt(row)) * ocean_cell + ocean_cell - 6;
                        if (y > h) continue;
                        const x: f64 = @as(f64, @floatFromInt(col)) * ocean_cell + ocean_cell / 2;
                        const fade = 1 - @as(f64, @floatFromInt(k)) / matrix_trail;
                        // Foam-white head, then a turquoise-to-deep-blue trail.
                        if (k == 0) cr.setSourceRgba(0.85, 1, 1, fade) else cr.setSourceRgba(0.05 + 0.1 * fade, 0.25 + 0.5 * fade, 0.45 + 0.5 * fade, fade);
                        text(cr, "Noto Color Emoji", oceanGlyph(col, row, self.tick / 8), x, y - ocean_cell / 2, ocean_cell - 6);
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
            .pipes => {
                cr.setLineCap(.round);
                cr.setLineWidth(pipes_cell * 0.3);
                for (self.pipes_segs[0..self.pipes_n]) |seg| {
                    const rgb = hsv(seg.hue, 0.75, 1);
                    cr.setSourceRgb(rgb[0], rgb[1], rgb[2]);
                    cr.moveTo(seg.x0, seg.y0);
                    cr.lineTo(seg.x1, seg.y1);
                    cr.stroke();
                    if (seg.joint) {
                        // Ball joint at the elbow, slightly fatter than the pipe.
                        cr.arc(seg.x1, seg.y1, pipes_cell * 0.26, 0, std.math.pi * 2);
                        cr.fill();
                    }
                }
            },
            .qix => {
                var i: usize = 0;
                while (i + 1 < self.qix_n) : (i += 1) {
                    const slot = (self.qix_i + qix_trail - self.qix_n + i) % qix_trail;
                    const next = (slot + 1) % qix_trail;
                    const fade = @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(self.qix_n));
                    const rgb = hsv(fade * 300 + @as(f64, @floatFromInt(self.tick)) * 0.6, 0.9, 1);
                    cr.setSourceRgba(rgb[0], rgb[1], rgb[2], fade * 0.45);
                    cr.moveTo(self.qix_ring[slot][0].x, self.qix_ring[slot][0].y);
                    cr.lineTo(self.qix_ring[slot][1].x, self.qix_ring[slot][1].y);
                    cr.lineTo(self.qix_ring[next][1].x, self.qix_ring[next][1].y);
                    cr.lineTo(self.qix_ring[next][0].x, self.qix_ring[next][0].y);
                    cr.closePath();
                    cr.fill();
                }
                cr.setSourceRgb(1, 1, 1);
                cr.setLineWidth(2);
                cr.moveTo(self.qix_v[0].x, self.qix_v[0].y);
                cr.lineTo(self.qix_v[1].x, self.qix_v[1].y);
                cr.stroke();
            },
            .maze => {
                const cw = w / @as(f64, @floatFromInt(self.maze_cols));
                const ch = h / @as(f64, @floatFromInt(self.maze_rows));
                cr.setSourceRgba(0.55, 0.9, 0.65, 0.85);
                cr.setLineWidth(1.5);
                var cy: i32 = 0;
                while (cy < self.maze_rows) : (cy += 1) {
                    var cx: i32 = 0;
                    while (cx < self.maze_cols) : (cx += 1) {
                        const cell = self.maze_walls[@intCast(cy * self.maze_cols + cx)];
                        const x = @as(f64, @floatFromInt(cx)) * cw;
                        const y = @as(f64, @floatFromInt(cy)) * ch;
                        // Walls are the sides the carve never opened.
                        if (cx + 1 >= self.maze_cols or cell & 1 == 0) {
                            cr.moveTo(x + cw, y);
                            cr.lineTo(x + cw, y + ch);
                        }
                        if (cy + 1 >= self.maze_rows or cell & 2 == 0) {
                            cr.moveTo(x, y + ch);
                            cr.lineTo(x + cw, y + ch);
                        }
                        if (cx == 0) {
                            cr.moveTo(x, y);
                            cr.lineTo(x, y + ch);
                        }
                        if (cy == 0) {
                            cr.moveTo(x, y);
                            cr.lineTo(x + cw, y);
                        }
                    }
                }
                cr.stroke();
                if (self.maze_head >= 0) {
                    const hx = @as(f64, @floatFromInt(@mod(self.maze_head, self.maze_cols))) * cw;
                    const hy = @as(f64, @floatFromInt(@divTrunc(self.maze_head, self.maze_cols))) * ch;
                    cr.setSourceRgb(1, 0.8, 0.2);
                    cr.rectangle(hx + cw * 0.25, hy + ch * 0.25, cw * 0.5, ch * 0.5);
                    cr.fill();
                }
            },
            .life => {
                const cw = w / @as(f64, @floatFromInt(self.life_cols));
                const ch = h / @as(f64, @floatFromInt(self.life_rows));
                const src = if (self.life_front) &self.life_b else &self.life_a;
                cr.setSourceRgb(0.45, 1, 0.55);
                var cy: i32 = 0;
                while (cy < self.life_rows) : (cy += 1) {
                    var cx: i32 = 0;
                    while (cx < self.life_cols) : (cx += 1) {
                        if (src[@intCast(cy * self.life_cols + cx)] == 0) continue;
                        cr.rectangle(@as(f64, @floatFromInt(cx)) * cw + 1, @as(f64, @floatFromInt(cy)) * ch + 1, cw - 2, ch - 2);
                    }
                }
                cr.fill();
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
