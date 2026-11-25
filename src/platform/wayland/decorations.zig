//! Shell-drawn server-side decorations (aqueous_shell_manager_v1 version 4).
//! Borrow GTK's display connection; GTK remains its sole reader/dispatcher.
//! Pearl owns every pixel of the titlebars and frames: the compositor only
//! attaches the surfaces to windows and keeps window policy. Windows report
//! `ssd_renderer == "shell"` in the shell state when drawing is expected.
//!
//! Each decorated window owns two surfaces:
//! - an above-placement titlebar (title, icon, window buttons), and
//! - a below-placement frame (shadow + invisible resize grips around the
//!   window content; its input region excludes content and titlebar).
const std = @import("std");
const gdk = @import("gdk4");
const backend = @import("gdkwayland4");
const object = @import("gobject2");
const glib = @import("glib2");
const pixbuf = @import("gdkpixbuf2");
const cairo = @import("cairo1");
const pango = @import("pango1");
const wl = @import("wayland").client.wl;
const aq = @import("wayland").client.aqueous;
const wp = @import("wayland").client.wp;
const entities = @import("../../aqueous/entities.zig");
const Model = @import("../../aqueous/reducer.zig").Model;
const theme = @import("../../theme/theme.zig");
const log = std.log.scoped(.platform);
const a = std.heap.c_allocator;

// Pango-Cairo integration is not part of the generated GIR namespaces; these
// are the stable libpangocairo-1.0 C ABI entry points (linked through GTK).
extern fn pango_cairo_create_context(cr: *cairo.Context) *pango.Context;
extern fn pango_cairo_show_layout(cr: *cairo.Context, layout: *pango.Layout) void;

pub const Action = union(enum) {
    close,
    activate,
    minimize: bool,
    maximize: bool,
};

pub const Options = struct {
    font: []const u8 = "",
    font_size_pt: u8 = 11,
    corner_radius: i32 = 15,
    shadows: bool = true,
};

const bar_height: i32 = 32;
const pad_x: i32 = 10;
const icon_size: i32 = 16;
const button_size: i32 = 24;
const button_gap: i32 = 6;
const buttons_right_pad: i32 = 8;
const max_width: i32 = 8192;
const max_height: i32 = 8192;
const grip: i32 = 6;
const double_click_ms: u32 = 400;
const op_sync_watchdog_us: i64 = 2_000_000;
const btn_left: u32 = 0x110;
const btn_right: u32 = 0x111;

// xdg_toplevel resize edge bits.
const edge_top: u32 = 1;
const edge_bottom: u32 = 2;
const edge_left: u32 = 4;
const edge_right: u32 = 8;

const Region = enum { none, title, minimize, maximize, close };

const Rgb = struct { r: f64, g: f64, b: f64 };

fn hex(text: []const u8) Rgb {
    const fallback: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    if (text.len != 7 or text[0] != '#') return fallback;
    const value = std.fmt.parseInt(u24, text[1..7], 16) catch return fallback;
    return .{
        .r = @as(f64, @floatFromInt((value >> 16) & 0xff)) / 255.0,
        .g = @as(f64, @floatFromInt((value >> 8) & 0xff)) / 255.0,
        .b = @as(f64, @floatFromInt(value & 0xff)) / 255.0,
    };
}

fn setSource(cr: *cairo.Context, color: Rgb) void {
    cairo.Context.setSourceRgb(cr, color.r, color.g, color.b);
}

fn roundedRect(cr: *cairo.Context, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    const radius = @max(0, @min(r, w / 2, h / 2));
    cairo.Context.moveTo(cr, x, y + h);
    cairo.Context.lineTo(cr, x, y + radius);
    if (radius > 0) cairo.Context.arc(cr, x + radius, y + radius, radius, std.math.pi, 1.5 * std.math.pi);
    cairo.Context.lineTo(cr, x + w - radius, y);
    if (radius > 0) cairo.Context.arc(cr, x + w - radius, y + radius, radius, 1.5 * std.math.pi, 2 * std.math.pi);
    cairo.Context.lineTo(cr, x + w, y + h);
    cairo.Context.closePath(cr);
}

/// Double-buffered wl_shm storage shared by the titlebar and the frame.
const Shm = struct {
    buffers: [2]?*wl.Buffer = .{ null, null },
    mapping: ?[]u8 = null,
    slot: u1 = 0,
    phys_w: i32 = 0,
    phys_h: i32 = 0,

    fn deinit(self: *Shm) void {
        for (self.buffers) |buffer| if (buffer) |b| b.destroy();
        self.buffers = .{ null, null };
        if (self.mapping) |mapping| {
            _ = std.c.munmap(@ptrCast(@alignCast(mapping.ptr)), mapping.len);
            self.mapping = null;
        }
        self.phys_w = 0;
        self.phys_h = 0;
    }

    fn resize(self: *Shm, shm_global: *wl.Shm, phys_w: i32, phys_h: i32) !void {
        if (self.phys_w == phys_w and self.phys_h == phys_h and self.mapping != null) return;
        self.deinit();
        if (phys_w <= 0 or phys_h <= 0) return;
        const stride = phys_w * 4;
        const size: usize = @as(usize, @intCast(stride * phys_h)) * 2;
        const raw = std.os.linux.memfd_create("pearl-decoration", 1);
        if (std.os.linux.errno(raw) != .SUCCESS) return error.Allocation;
        const fd: c_int = @intCast(raw);
        defer _ = std.c.close(fd);
        if (std.c.ftruncate(fd, @intCast(size)) != 0) return error.Allocation;
        const ptr = std.c.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (ptr == std.c.MAP_FAILED) return error.Allocation;
        self.mapping = @as([*]u8, @ptrCast(ptr))[0..size];
        const pool = try shm_global.createPool(fd, @intCast(size));
        defer pool.destroy();
        const half: i32 = @intCast(size / 2);
        self.buffers[0] = try pool.createBuffer(0, phys_w, phys_h, stride, .argb8888);
        self.buffers[1] = try pool.createBuffer(half, phys_w, phys_h, stride, .argb8888);
        self.phys_w = phys_w;
        self.phys_h = phys_h;
    }

    fn data(self: *Shm) ?[]u8 {
        const mapping = self.mapping orelse return null;
        const half: usize = @intCast(self.phys_w * 4 * self.phys_h);
        return mapping[@as(usize, self.slot) * half ..][0..half];
    }
};

const Bar = struct {
    owner: *Decorations,
    id: [:0]u8,
    // Titlebar (above placement).
    surface: *wl.Surface,
    decoration: ?*aq.ShellDecorationV1 = null,
    created: bool = false,
    shm: Shm = .{},
    width: i32 = 0,
    scale: i32 = 1,
    title: []u8 = &.{},
    icon_revision: []u8 = &.{},
    focused: bool = false,
    maximized: bool = false,
    minimized: bool = false,
    hover: Region = .none,
    last_x: f64 = 0,
    last_y: f64 = 0,
    dirty: bool = true,
    commit_pending: bool = false,
    // Frame (below placement): shadow + resize grips.
    frame_surface: ?*wl.Surface = null,
    frame_decoration: ?*aq.ShellDecorationV1 = null,
    frame_created: bool = false,
    frame_shm: Shm = .{},
    frame_dirty: bool = true,
    frame_pending: bool = false,
    hover_edges: u32 = 0,
    // Window geometry (logical, committed content).
    geom_x: i32 = 0,
    geom_y: i32 = 0,
    content_height: i32 = 0,
    last_width: i64 = -1,
    last_height: i64 = -1,
    // Interactive-op atomicity (sync_next_commit) with a watchdog.
    sync_commit: bool = false,
    op_active_since: i64 = 0,
    enter_serial: u32 = 0,
    seen: bool = false,

    fn destroy(self: *Bar) void {
        if (self.decoration) |decoration| decoration.destroy();
        if (self.frame_decoration) |decoration| decoration.destroy();
        self.shm.deinit();
        self.frame_shm.deinit();
        if (self.frame_surface) |surface| surface.destroy();
        self.surface.destroy();
        a.free(self.title);
        a.free(self.icon_revision);
        a.free(self.id);
        a.destroy(self);
    }

    fn resize(self: *Bar, width: i32, content_height: i32, scale: i32) !void {
        const size_changed = self.width != width or self.content_height != content_height or self.scale != scale;
        self.width = width;
        self.content_height = content_height;
        self.scale = scale;
        if (size_changed) {
            self.surface.setBufferScale(scale);
            if (self.decoration) |decoration| decoration.setOffset(0, -bar_height);
            try self.shm.resize(self.owner.shm.?, width * scale, bar_height * scale);
            self.dirty = true;
            if (self.frame_surface) |surface| {
                surface.setBufferScale(scale);
                if (self.frame_decoration) |decoration| decoration.setOffset(-grip, -bar_height);
                try self.frame_shm.resize(self.owner.shm.?, (width + 2 * grip) * scale, (bar_height + content_height + grip) * scale);
                self.updateFrameInput();
                self.frame_dirty = true;
            }
        }
    }

    /// The frame accepts input only on the grip ring: never over the window
    /// content, never over the titlebar (a separate above-placement surface).
    fn updateFrameInput(self: *Bar) void {
        const surface = self.frame_surface orelse return;
        const compositor = self.owner.compositor orelse return;
        const region = compositor.createRegion() catch return;
        defer region.destroy();
        const fw = self.width + 2 * grip;
        const fh = bar_height + self.content_height + grip;
        region.add(0, 0, fw, fh);
        region.subtract(grip, bar_height, self.width, self.content_height);
        region.subtract(grip, 0, self.width, bar_height);
        surface.setInputRegion(region);
    }

    fn regionAt(self: *const Bar, x: f64, y: f64) Region {
        if (x < 0 or y < 0 or x > @as(f64, @floatFromInt(self.width)) or y > @as(f64, @floatFromInt(bar_height))) return .none;
        const right = @as(f64, @floatFromInt(self.width - buttons_right_pad));
        const size: f64 = @floatFromInt(button_size);
        const gap: f64 = @floatFromInt(button_gap);
        const top = @as(f64, @floatFromInt(bar_height - button_size)) / 2;
        if (y >= top and y <= top + size) {
            const close_x = right - size;
            const max_x = close_x - gap - size;
            const min_x = max_x - gap - size;
            if (x >= close_x and x <= close_x + size) return .close;
            if (x >= max_x and x <= max_x + size) return .maximize;
            if (x >= min_x and x <= min_x + size) return .minimize;
        }
        return .title;
    }

    /// Resize edges for a frame-local position (only the grip ring is input).
    fn edgesAt(self: *const Bar, x: f64, y: f64) u32 {
        var edges: u32 = 0;
        const g: f64 = @floatFromInt(grip);
        const w: f64 = @floatFromInt(self.width);
        const h: f64 = @floatFromInt(self.content_height);
        const bh: f64 = @floatFromInt(bar_height);
        if (x < g) edges |= edge_left;
        if (x >= g + w) edges |= edge_right;
        if (y < bh) edges |= edge_top;
        if (y >= bh + h) edges |= edge_bottom;
        return edges;
    }

    fn beginSync(self: *Bar) void {
        if (!self.sync_commit) return;
        self.sync_commit = false;
        if (self.decoration) |decoration| decoration.syncNextCommit();
        if (self.frame_decoration) |decoration| decoration.syncNextCommit();
    }

    fn draw(self: *Bar) void {
        const data = self.shm.data() orelse return;
        const buffer = self.shm.buffers[self.shm.slot] orelse return;
        const phys_w = self.shm.phys_w;
        const phys_h = self.shm.phys_h;
        if (phys_w <= 0 or phys_h <= 0) return;
        const stride = phys_w * 4;
        const cs = cairo.Surface.imageCreateForData(data.ptr, .argb32, phys_w, phys_h, stride);
        defer cairo.Surface.destroy(cs);
        const cr = cairo.Context.create(cs);
        defer cairo.Context.destroy(cr);
        const s: f64 = @floatFromInt(self.scale);
        cairo.Context.scale(cr, s, s);
        const w: f64 = @floatFromInt(self.width);
        const h: f64 = @floatFromInt(bar_height);
        const palette = self.owner.palette;
        // Background with rounded top corners matching compositor rounding.
        const radius: f64 = @floatFromInt(@max(0, @min(self.owner.options.corner_radius, @divTrunc(self.width, 2), bar_height)));
        setSource(cr, hex(if (self.focused) palette.container else palette.surface));
        roundedRect(cr, 0, 0, w, h, radius);
        cairo.Context.fill(cr);
        // App icon (borrowed from the session cache for this draw only).
        var title_x: f64 = @floatFromInt(pad_x);
        if (self.owner.icon) |lookup| {
            if (lookup(self.owner.context.?, self.id, @intCast(icon_size), @intCast(self.scale))) |pb| {
                const pw: f64 = @floatFromInt(pb.getWidth());
                const ph: f64 = @floatFromInt(pb.getHeight());
                if (pw > 0 and ph > 0) {
                    cairo.Context.save(cr);
                    cairo.Context.translate(cr, title_x, (h - @as(f64, @floatFromInt(icon_size))) / 2);
                    cairo.Context.scale(cr, @as(f64, @floatFromInt(icon_size)) / pw, @as(f64, @floatFromInt(icon_size)) / ph);
                    gdk.cairoSetSourcePixbuf(cr, pb, 0, 0);
                    cairo.Context.paint(cr);
                    cairo.Context.restore(cr);
                    title_x += @floatFromInt(icon_size + 6);
                }
            }
        }
        // Title.
        const buttons_w: f64 = @floatFromInt(button_size * 3 + button_gap * 2 + buttons_right_pad);
        const title_w = w - buttons_w - title_x - 4;
        if (title_w > 8 and self.title.len > 0) {
            const pc = pango_cairo_create_context(cr);
            defer pc.unref();
            const layout = pango.Layout.new(pc);
            defer layout.unref();
            const title_z = a.dupeSentinel(u8, self.title, 0) catch return;
            defer a.free(title_z);
            layout.setText(title_z, -1);
            var font_buf: [128]u8 = undefined;
            const family = if (self.owner.options.font.len > 0 and self.owner.options.font.len < 96) self.owner.options.font else "sans-serif";
            const font = std.fmt.bufPrintSentinel(&font_buf, "{s} {d}", .{ family, self.owner.options.font_size_pt }, 0) catch return;
            const desc = pango.FontDescription.fromString(font);
            defer desc.free();
            layout.setFontDescription(desc);
            layout.setEllipsize(.end);
            layout.setWidth(@intFromFloat(title_w * @as(f64, pango.SCALE)));
            var text_h: c_int = 0;
            layout.getPixelSize(null, &text_h);
            setSource(cr, hex(if (self.focused) palette.text else palette.secondary));
            cairo.Context.moveTo(cr, title_x, @max(0, (h - @as(f64, @floatFromInt(text_h))) / 2));
            pango_cairo_show_layout(cr, layout);
        }
        // Window buttons: minimize, maximize, close (left to right).
        const right = w - @as(f64, @floatFromInt(buttons_right_pad));
        const size: f64 = @floatFromInt(button_size);
        const gap: f64 = @floatFromInt(button_gap);
        const top = (h - size) / 2;
        const centers = [3]f64{ right - size * 2.5 - gap * 2, right - size * 1.5 - gap, right - size * 0.5 };
        const regions = [3]Region{ .minimize, .maximize, .close };
        for (centers, regions) |cx, region| {
            const hovered = self.hover == region;
            if (hovered) {
                setSource(cr, hex(if (region == .close) palette.error_container else palette.high));
                cairo.Context.arc(cr, cx, top + size / 2, size / 2, 0, 2 * std.math.pi);
                cairo.Context.fill(cr);
            }
            const glyph = hex(if (region == .close and hovered) palette.error_color else if (self.focused) palette.text else palette.secondary);
            setSource(cr, glyph);
            cairo.Context.setLineWidth(cr, 1.4);
            const cy = top + size / 2;
            const r: f64 = 4.5;
            switch (region) {
                .minimize => {
                    cairo.Context.moveTo(cr, cx - r, cy + 2);
                    cairo.Context.lineTo(cr, cx + r, cy + 2);
                    cairo.Context.stroke(cr);
                },
                .maximize => {
                    cairo.Context.rectangle(cr, cx - r, cy - r, r * 2, r * 2);
                    cairo.Context.stroke(cr);
                },
                .close => {
                    cairo.Context.moveTo(cr, cx - r, cy - r);
                    cairo.Context.lineTo(cr, cx + r, cy + r);
                    cairo.Context.moveTo(cr, cx + r, cy - r);
                    cairo.Context.lineTo(cr, cx - r, cy + r);
                    cairo.Context.stroke(cr);
                },
                else => {},
            }
        }
        self.beginSync();
        self.surface.attach(buffer, 0, 0);
        self.surface.damageBuffer(0, 0, phys_w, phys_h);
        self.shm.slot ^= 1;
        self.dirty = false;
        self.commit_pending = true;
        const frame = self.surface.frame() catch {
            self.commit_pending = false;
            return;
        };
        frame.setListener(*Bar, frameDone, self);
        self.surface.commit();
        self.owner.display.flush();
    }

    fn drawFrame(self: *Bar) void {
        const surface = self.frame_surface orelse return;
        const data = self.frame_shm.data() orelse return;
        const buffer = self.frame_shm.buffers[self.frame_shm.slot] orelse return;
        const phys_w = self.frame_shm.phys_w;
        const phys_h = self.frame_shm.phys_h;
        if (phys_w <= 0 or phys_h <= 0) return;
        const stride = phys_w * 4;
        const cs = cairo.Surface.imageCreateForData(data.ptr, .argb32, phys_w, phys_h, stride);
        defer cairo.Surface.destroy(cs);
        const cr = cairo.Context.create(cs);
        defer cairo.Context.destroy(cr);
        const s: f64 = @floatFromInt(self.scale);
        cairo.Context.scale(cr, s, s);
        // Transparent everywhere; the window content and titlebar render above.
        cairo.Context.save(cr);
        cairo.Context.setOperator(cr, .clear);
        cairo.Context.paint(cr);
        cairo.Context.restore(cr);
        if (self.owner.options.shadows and !self.maximized) {
            // Soft shadow: layered rounded rects expanding from the content
            // rect. The window covers the interior, leaving only the halo.
            const g: f64 = @floatFromInt(grip);
            const bh: f64 = @floatFromInt(bar_height);
            const w: f64 = @floatFromInt(self.width);
            const h: f64 = @floatFromInt(self.content_height);
            const base_radius: f64 = @floatFromInt(@max(0, self.owner.options.corner_radius));
            var layer: i32 = 5;
            while (layer >= 1) : (layer -= 1) {
                const expand: f64 = @as(f64, @floatFromInt(layer)) * 1.2;
                const alpha = 0.05 + @as(f64, @floatFromInt(5 - layer)) * 0.025;
                cairo.Context.setSourceRgba(cr, 0, 0, 0, alpha);
                roundedRect(cr, g - expand, bh - expand, w + expand * 2, h + expand * 2, base_radius + expand);
                cairo.Context.fill(cr);
            }
        }
        surface.attach(buffer, 0, 0);
        surface.damageBuffer(0, 0, phys_w, phys_h);
        self.frame_shm.slot ^= 1;
        self.frame_dirty = false;
        self.frame_pending = true;
        const frame = surface.frame() catch {
            self.frame_pending = false;
            return;
        };
        frame.setListener(*Bar, frameSurfaceDone, self);
        surface.commit();
        self.owner.display.flush();
    }

    fn frameDone(_: *wl.Callback, _: wl.Callback.Event, self: *Bar) void {
        self.commit_pending = false;
        if (self.dirty) self.draw();
    }

    fn frameSurfaceDone(_: *wl.Callback, _: wl.Callback.Event, self: *Bar) void {
        self.frame_pending = false;
        if (self.frame_dirty) self.drawFrame();
    }

    fn markDirty(self: *Bar) void {
        self.dirty = true;
        if (!self.commit_pending) self.draw();
    }

    fn markFrameDirty(self: *Bar) void {
        self.frame_dirty = true;
        if (!self.frame_pending) self.drawFrame();
    }
};

const Pending = struct { request_id: u32, bar: *Bar, frame: bool };

pub const Decorations = struct {
    display: *gdk.Display,
    registry: *wl.Registry,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    seat: ?*wl.Seat = null,
    pointer: ?*wl.Pointer = null,
    cursor_manager: ?*wp.CursorShapeManagerV1 = null,
    cursor_device: ?*wp.CursorShapeDeviceV1 = null,
    shell: ?*aq.ShellManagerV1 = null,
    shell_name: u32 = 0,
    available: bool = false,
    bars: std.ArrayList(*Bar) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    next_request: u32 = 1,
    palette: theme.Palette = theme.dark,
    options: Options = .{},
    context: ?*anyopaque = null,
    action: ?*const fn (*anyopaque, []const u8, Action) void = null,
    /// Borrowed session-cache icon lookup; the pixbuf is only valid for the
    /// duration of the call (draw uses it immediately).
    icon: ?*const fn (*anyopaque, []const u8, u16, u16) ?*pixbuf.Pixbuf = null,
    /// Right-click on the titlebar: open a window menu at global logical (x, y).
    menu: ?*const fn (*anyopaque, []const u8, i32, i32) void = null,
    hovered: ?*Bar = null,
    hovered_frame: bool = false,
    pressed_bar: ?*Bar = null,
    pressed_region: Region = .none,
    last_click_time: u32 = 0,
    last_click_bar: ?*Bar = null,

    pub fn init(display: *gdk.Display) !Decorations {
        const wayland = object.ext.cast(backend.WaylandDisplay, display) orelse return error.NotWayland;
        const connection: *wl.Display = @ptrCast(wayland.getWlDisplay() orelse return error.NotWayland);
        return .{ .display = display, .registry = try connection.getRegistry() };
    }

    pub fn start(self: *Decorations) void {
        self.registry.setListener(*Decorations, registryEvent, self);
        self.display.flush();
    }

    pub fn deinit(self: *Decorations) void {
        self.clear();
        self.bars.deinit(a);
        self.pending.deinit(a);
        if (self.cursor_device) |device| device.destroy();
        if (self.cursor_manager) |manager| manager.destroy();
        if (self.pointer) |pointer| pointer.release();
        if (self.seat) |seat| @as(*wl.Proxy, @ptrCast(seat)).destroy();
        if (self.shm) |shm| @as(*wl.Proxy, @ptrCast(shm)).destroy();
        if (self.compositor) |compositor| @as(*wl.Proxy, @ptrCast(compositor)).destroy();
        if (self.shell) |shell| shell.destroy();
        @as(*wl.Proxy, @ptrCast(self.registry)).destroy();
    }

    /// Drop every titlebar and frame (session loss, lock, compositor restart).
    pub fn clear(self: *Decorations) void {
        for (self.bars.items) |bar| bar.destroy();
        self.bars.clearRetainingCapacity();
        self.pending.clearRetainingCapacity();
        self.hovered = null;
        self.pressed_bar = null;
        self.last_click_bar = null;
    }

    fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Decorations) void {
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor") and self.compositor == null) {
                    self.compositor = registry.bind(g.name, wl.Compositor, @min(g.version, 6)) catch null;
                }
                if (std.mem.eql(u8, name, "wl_shm") and self.shm == null) {
                    self.shm = registry.bind(g.name, wl.Shm, 1) catch null;
                    if (self.shm) |shm| shm.setListener(*Decorations, shmEvent, self);
                }
                if (std.mem.eql(u8, name, "wl_seat") and self.seat == null) {
                    self.seat = registry.bind(g.name, wl.Seat, @min(g.version, 9)) catch null;
                    if (self.seat) |seat| seat.setListener(*Decorations, seatEvent, self);
                }
                if (std.mem.eql(u8, name, "wp_cursor_shape_manager_v1") and self.cursor_manager == null) {
                    self.cursor_manager = registry.bind(g.name, wp.CursorShapeManagerV1, 1) catch null;
                    self.acquireCursorDevice();
                }
                if (std.mem.eql(u8, name, "aqueous_shell_manager_v1") and self.shell == null and g.version >= 4) {
                    self.shell = registry.bind(g.name, aq.ShellManagerV1, 4) catch null;
                    self.shell_name = g.name;
                    if (self.shell) |shell| shell.setListener(*Decorations, shellEvent, self);
                }
                self.display.flush();
            },
            .global_remove => |g| {
                if (g.name == self.shell_name and self.shell != null) {
                    self.available = false;
                    self.clear();
                    self.shell.?.destroy();
                    self.shell = null;
                    self.shell_name = 0;
                }
            },
        }
    }

    fn shmEvent(_: *wl.Shm, _: wl.Shm.Event, _: *Decorations) void {}

    fn acquireCursorDevice(self: *Decorations) void {
        if (self.cursor_device != null or self.cursor_manager == null or self.pointer == null) return;
        self.cursor_device = self.cursor_manager.?.getPointer(self.pointer.?) catch null;
    }

    fn setCursorShape(self: *Decorations, shape: wp.CursorShapeDeviceV1.Shape) void {
        const device = self.cursor_device orelse return;
        const bar = self.hovered orelse return;
        device.setShape(bar.enter_serial, shape);
        self.display.flush();
    }

    fn seatEvent(seat: *wl.Seat, event: wl.Seat.Event, self: *Decorations) void {
        switch (event) {
            .capabilities => |c| {
                if (c.capabilities.pointer and self.pointer == null) {
                    self.pointer = seat.getPointer() catch null;
                    if (self.pointer) |pointer| pointer.setListener(*Decorations, pointerEvent, self);
                    self.acquireCursorDevice();
                } else if (!c.capabilities.pointer and self.pointer != null) {
                    if (self.cursor_device) |device| {
                        device.destroy();
                        self.cursor_device = null;
                    }
                    self.pointer.?.release();
                    self.pointer = null;
                    self.hovered = null;
                    self.pressed_bar = null;
                }
            },
            .name => {},
        }
    }

    fn shellEvent(shell: *aq.ShellManagerV1, event: aq.ShellManagerV1.Event, self: *Decorations) void {
        switch (event) {
            .capabilities => |c| {
                const bytes = std.mem.span(c.json);
                if (bytes.len > 65536) return;
                const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return;
                defer parsed.deinit();
                const flag = entities.field(parsed.value, "window_decorations") catch return;
                self.available = flag == .bool and flag.bool;
                log.info("event=shell-decorations available={}", .{self.available});
                if (!self.available) self.clear();
            },
            .result => |r| {
                for (self.pending.items, 0..) |entry, i| {
                    if (entry.request_id != r.request_id) continue;
                    _ = self.pending.orderedRemove(i);
                    if (r.status != .applied) {
                        log.warn("event=shell-decoration-rejected status={s}", .{@tagName(r.status)});
                        self.removeBar(entry.bar);
                    } else if (entry.frame) {
                        entry.bar.frame_created = true;
                        entry.bar.updateFrameInput();
                        entry.bar.markFrameDirty();
                    } else {
                        entry.bar.created = true;
                        log.info("event=shell-decoration-created window={s}", .{entry.bar.id});
                        entry.bar.markDirty();
                    }
                    return;
                }
                // Interactive move/resize results are fire-and-forget.
                if (r.status != .applied) log.debug("event=shell-decoration-op status={s}", .{@tagName(r.status)});
            },
            else => {},
        }
        _ = shell;
    }

    fn removeBar(self: *Decorations, bar: *Bar) void {
        if (self.hovered == bar) self.hovered = null;
        if (self.pressed_bar == bar) self.pressed_bar = null;
        if (self.last_click_bar == bar) self.last_click_bar = null;
        for (self.bars.items, 0..) |item, i| {
            if (item == bar) {
                _ = self.bars.orderedRemove(i);
                break;
            }
        }
        bar.destroy();
    }

    const SurfaceHit = struct { bar: *Bar, frame: bool };

    fn barForSurface(self: *Decorations, surface: *wl.Surface) ?SurfaceHit {
        for (self.bars.items) |bar| {
            if (bar.surface == surface) return .{ .bar = bar, .frame = false };
            if (bar.frame_surface == surface) return .{ .bar = bar, .frame = true };
        }
        return null;
    }

    fn shapeForEdges(edges: u32) wp.CursorShapeDeviceV1.Shape {
        return switch (edges) {
            edge_top => .n_resize,
            edge_bottom => .s_resize,
            edge_left => .w_resize,
            edge_right => .e_resize,
            edge_top | edge_left => .nw_resize,
            edge_top | edge_right => .ne_resize,
            edge_bottom | edge_left => .sw_resize,
            edge_bottom | edge_right => .se_resize,
            else => .default,
        };
    }

    fn pointerEvent(pointer: *wl.Pointer, event: wl.Pointer.Event, self: *Decorations) void {
        switch (event) {
            .enter => |e| {
                const surface = e.surface orelse return;
                const hit = self.barForSurface(surface) orelse return;
                self.hovered = hit.bar;
                self.hovered_frame = hit.frame;
                hit.bar.enter_serial = e.serial;
                hit.bar.last_x = e.surface_x.toDouble();
                hit.bar.last_y = e.surface_y.toDouble();
                if (hit.frame) {
                    const edges = hit.bar.edgesAt(hit.bar.last_x, hit.bar.last_y);
                    hit.bar.hover_edges = edges;
                    self.setCursorShape(shapeForEdges(edges));
                } else {
                    const region = hit.bar.regionAt(hit.bar.last_x, hit.bar.last_y);
                    if (hit.bar.hover != region) {
                        hit.bar.hover = region;
                        hit.bar.markDirty();
                    }
                    self.setCursorShape(.default);
                }
            },
            .leave => |e| {
                const surface = e.surface orelse return;
                const hit = self.barForSurface(surface) orelse return;
                if (self.hovered == hit.bar) {
                    self.hovered = null;
                    self.setCursorShape(.default);
                }
                if (hit.frame) {
                    hit.bar.hover_edges = 0;
                } else if (hit.bar.hover != .none) {
                    hit.bar.hover = .none;
                    hit.bar.markDirty();
                }
            },
            .motion => |e| {
                const bar = self.hovered orelse return;
                bar.last_x = e.surface_x.toDouble();
                bar.last_y = e.surface_y.toDouble();
                if (self.hovered_frame) {
                    const edges = bar.edgesAt(bar.last_x, bar.last_y);
                    if (bar.hover_edges != edges) {
                        bar.hover_edges = edges;
                        self.setCursorShape(shapeForEdges(edges));
                    }
                } else {
                    const region = bar.regionAt(bar.last_x, bar.last_y);
                    if (bar.hover != region) {
                        bar.hover = region;
                        bar.markDirty();
                    }
                }
            },
            .button => |e| {
                const bar = self.hovered orelse return;
                if (e.button == btn_right and e.state == .pressed and !self.hovered_frame) {
                    if (bar.regionAt(bar.last_x, bar.last_y) == .title) {
                        if (self.menu) |callback| {
                            const x = bar.geom_x + @as(i32, @intFromFloat(bar.last_x));
                            const y = bar.geom_y - bar_height + @as(i32, @intFromFloat(bar.last_y));
                            callback(self.context.?, bar.id, x, y);
                        }
                    }
                    return;
                }
                if (e.button != btn_left) return;
                if (e.state == .pressed) {
                    if (self.hovered_frame) {
                        const edges = bar.edgesAt(bar.last_x, bar.last_y);
                        if (edges != 0) self.startResize(bar, e.serial, edges);
                        return;
                    }
                    const region = bar.regionAt(bar.last_x, bar.last_y);
                    switch (region) {
                        .title => {
                            if (self.last_click_bar == bar and e.time -% self.last_click_time < double_click_ms) {
                                self.last_click_bar = null;
                                self.emit(bar, .{ .maximize = !bar.maximized });
                            } else {
                                self.last_click_bar = bar;
                                self.last_click_time = e.time;
                                self.startMove(bar, e.serial);
                            }
                        },
                        .minimize, .maximize, .close => {
                            self.pressed_bar = bar;
                            self.pressed_region = region;
                        },
                        .none => {},
                    }
                } else {
                    const pressed = self.pressed_bar orelse return;
                    self.pressed_bar = null;
                    const region = self.pressed_region;
                    self.pressed_region = .none;
                    if (self.hovered != pressed or self.hovered_frame) return;
                    if (pressed.regionAt(pressed.last_x, pressed.last_y) != region) return;
                    switch (region) {
                        .close => self.emit(pressed, .close),
                        .minimize => self.emit(pressed, .{ .minimize = !pressed.minimized }),
                        .maximize => self.emit(pressed, .{ .maximize = !pressed.maximized }),
                        else => {},
                    }
                }
            },
            else => {},
        }
        _ = pointer;
    }

    fn emit(self: *Decorations, bar: *Bar, action: Action) void {
        if (self.action) |callback| callback(self.context.?, bar.id, action);
    }

    fn startMove(self: *Decorations, bar: *Bar, serial: u32) void {
        const shell = self.shell orelse return;
        const request_id = self.next_request;
        self.next_request +%= 1;
        shell.windowInteractiveMove(request_id, bar.id, "", serial);
        self.display.flush();
    }

    fn startResize(self: *Decorations, bar: *Bar, serial: u32, edges: u32) void {
        const shell = self.shell orelse return;
        const request_id = self.next_request;
        self.next_request +%= 1;
        shell.windowInteractiveResize(request_id, bar.id, "", serial, edges);
        self.display.flush();
    }

    /// Reconcile titlebars against the authoritative shell state. Called from
    /// the Manager's coalesced sync on state, availability and theme changes.
    pub fn sync(self: *Decorations, model: *const Model, palette: theme.Palette, options: Options) void {
        const palette_changed = !std.meta.eql(self.palette, palette);
        self.palette = palette;
        const options_changed = !std.meta.eql(self.options, options);
        self.options = options;
        const locked = if (model.get(.session, "session")) |session| session.locked else true;
        if (!self.available or self.shell == null or self.compositor == null or self.shm == null or locked or !model.ready) {
            if (self.bars.items.len > 0) self.clear();
            return;
        }
        for (self.bars.items) |bar| bar.seen = false;
        var it = model.entities.valueIterator();
        while (it.next()) |entity| {
            if (entity.* != .window) continue;
            const window = entity.window;
            const renderer = window.ssd_renderer orelse continue;
            if (!std.mem.eql(u8, renderer, "shell") or window.fullscreen) continue;
            self.syncBar(model, window, palette_changed or options_changed) catch |err| {
                log.warn("event=shell-decoration-sync-failed error={s}", .{@errorName(err)});
            };
        }
        var i: usize = 0;
        while (i < self.bars.items.len) {
            const bar = self.bars.items[i];
            if (bar.seen) {
                i += 1;
                continue;
            }
            self.removeBar(bar);
        }
    }

    fn syncBar(self: *Decorations, model: *const Model, window: entities.Window, force: bool) !void {
        const width = std.math.clamp(window.geometry.width, 1, max_width);
        const content_height = std.math.clamp(window.geometry.height, 1, max_height);
        // Output scale for crisp buffers on fractional/HiDPI outputs. XWayland
        // windows use native scaling, so their buffers stay at scale 1.
        var scale: i32 = 1;
        if (window.backend != .xwayland) {
            if (window.output) |output_id| {
                if (model.get(.output, output_id)) |output| {
                    if (output.scale > 0 and std.math.isFinite(output.scale)) {
                        scale = std.math.clamp(@as(i32, @intFromFloat(@ceil(output.scale))), 1, 4);
                    }
                }
            }
        }
        var bar: ?*Bar = null;
        for (self.bars.items) |item| {
            if (std.mem.eql(u8, item.id, window.id)) {
                bar = item;
                break;
            }
        }
        if (bar == null) {
            const shell = self.shell orelse return;
            const compositor = self.compositor orelse return;
            const id = try a.dupeSentinel(u8, window.id, 0);
            errdefer a.free(id);
            const surface = try compositor.createSurface();
            errdefer surface.destroy();
            const fresh = try a.create(Bar);
            errdefer a.destroy(fresh);
            fresh.* = .{ .owner = self, .id = id, .surface = surface };
            const request_id = self.next_request;
            self.next_request +%= 1;
            const decoration = shell.getWindowDecoration(request_id, id, .above, surface) catch |err| {
                fresh.destroy();
                return err;
            };
            fresh.decoration = decoration;
            try self.bars.append(a, fresh);
            try self.pending.append(a, .{ .request_id = request_id, .bar = fresh, .frame = false });
            bar = fresh;
        }
        const b = bar.?;
        b.seen = true;
        // Frame surface (shadow + grips), created once per bar.
        if (b.frame_surface == null) {
            if (self.compositor) |compositor| {
                if (self.shell) |shell| {
                    const surface = compositor.createSurface() catch null;
                    if (surface) |fs| {
                        const request_id = self.next_request;
                        self.next_request +%= 1;
                        const decoration = shell.getWindowDecoration(request_id, b.id, .below, fs) catch null;
                        if (decoration) |fd| {
                            b.frame_surface = fs;
                            b.frame_decoration = fd;
                            self.pending.append(a, .{ .request_id = request_id, .bar = b, .frame = true }) catch {
                                fd.destroy();
                                fs.destroy();
                                b.frame_surface = null;
                                b.frame_decoration = null;
                            };
                        } else {
                            fs.destroy();
                        }
                    }
                }
            }
        }
        b.geom_x = @intCast(std.math.clamp(window.geometry.x, std.math.minInt(i32), std.math.maxInt(i32)));
        b.geom_y = @intCast(std.math.clamp(window.geometry.y, std.math.minInt(i32), std.math.maxInt(i32)));
        try b.resize(@intCast(width), @intCast(content_height), scale);
        // Atomic decoration updates during interactive moves/resizes: ask the
        // compositor to sync our next commits with its render transaction.
        const operation = window.operation orelse "none";
        const op_active = std.mem.eql(u8, operation, "move") or std.mem.eql(u8, operation, "resize");
        const geometry_changed = b.last_width != window.geometry.width or b.last_height != window.geometry.height;
        b.last_width = window.geometry.width;
        b.last_height = window.geometry.height;
        if (op_active) {
            const now = glib.getMonotonicTime();
            if (b.op_active_since == 0) b.op_active_since = now;
            if (geometry_changed and now - b.op_active_since < op_sync_watchdog_us) b.sync_commit = true;
        } else {
            b.op_active_since = 0;
        }
        const title = window.title orelse window.app_id orelse "";
        if (!std.mem.eql(u8, b.title, title)) {
            const owned = try a.dupe(u8, title);
            a.free(b.title);
            b.title = owned;
            b.dirty = true;
        }
        const revision = if (window.icon) |icon| icon.revision else "";
        if (!std.mem.eql(u8, b.icon_revision, revision)) {
            const owned = try a.dupe(u8, revision);
            a.free(b.icon_revision);
            b.icon_revision = owned;
            b.dirty = true;
        }
        if (b.focused != window.focused or b.maximized != window.maximized or b.minimized != window.minimized) {
            const shadow_change = b.maximized != window.maximized;
            b.focused = window.focused;
            b.maximized = window.maximized;
            b.minimized = window.minimized;
            b.dirty = true;
            if (shadow_change) b.frame_dirty = true;
        }
        if (force) {
            b.dirty = true;
            b.frame_dirty = true;
        }
        if (b.created and b.dirty and !b.commit_pending) b.draw();
        if (b.frame_created and b.frame_dirty and !b.frame_pending) b.drawFrame();
    }
};

test "hex palette parsing" {
    const color = hex("#d0bcff");
    try std.testing.expectApproxEqAbs(@as(f64, 0xd0) / 255.0, color.r, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0xbc) / 255.0, color.g, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0xff) / 255.0, color.b, 0.001);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, hex("invalid"));
}