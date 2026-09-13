//! Borrow GTK's display/surface connection. GTK remains its sole reader/dispatcher.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const backend = @import("gdkwayland4");
const object = @import("gobject2");
const cairo = @import("cairo1");
const wl = @import("wayland").client.wl;
const aq = @import("wayland").client.aqueous;
const ext = @import("wayland").client.ext;
const a = std.heap.c_allocator;
const Rect = @import("../../ui/surfaces/policy.zig").Rect;
pub const Effects = struct {
    display: *gdk.Display,
    registry: *wl.Registry,
    compositor: ?*wl.Compositor = null,
    manager: ?*ext.BackgroundEffectManagerV1 = null,
    manager_name: u32 = 0,
    available: bool = false,
    shell: ?*aq.ShellManagerV1 = null,
    display_session: ?[32]u8 = null,
    context: ?*anyopaque = null,
    changed: ?*const fn (*anyopaque) void = null,
    surfaces: std.ArrayList(*Surface) = .empty,
    pub fn init(display: *gdk.Display) !Effects {
        const wayland = object.ext.cast(backend.WaylandDisplay, display) orelse return error.NotWayland;
        const connection: *wl.Display = @ptrCast(wayland.getWlDisplay() orelse return error.NotWayland);
        return .{ .display = display, .registry = try connection.getRegistry() };
    }
    pub fn start(self: *Effects) void {
        self.registry.setListener(*Effects, registryEvent, self);
        self.display.flush();
    }
    pub fn deinit(self: *Effects) void {
        std.debug.assert(self.surfaces.items.len == 0);
        self.surfaces.deinit(a);
        if (self.manager) |v| v.destroy();
        if (self.shell) |v| v.destroy();
        if (self.compositor) |v| @as(*wl.Proxy, @ptrCast(v)).destroy();
        @as(*wl.Proxy, @ptrCast(self.registry)).destroy();
    }
    fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Effects) void {
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor") and self.compositor == null) self.compositor = registry.bind(g.name, wl.Compositor, @min(g.version, 6)) catch null;
                if (std.mem.eql(u8, name, "ext_background_effect_manager_v1") and self.manager == null) {
                    self.manager = registry.bind(g.name, ext.BackgroundEffectManagerV1, 1) catch null;
                    self.manager_name = g.name;
                    if (self.manager) |manager| manager.setListener(*Effects, capabilities, self);
                }
                if (std.mem.eql(u8, name, "aqueous_shell_manager_v1") and self.shell == null and self.display_session == null) {
                    self.shell = registry.bind(g.name, aq.ShellManagerV1, @min(g.version, 2)) catch null;
                    if (self.shell) |shell| shell.setListener(*Effects, identity, self);
                }
                self.display.flush();
            },
            .global_remove => |g| if (g.name == self.manager_name) {
                self.available = false;
                for (self.surfaces.items) |s| {
                    s.clearEffect();
                    s.refresh();
                }
                if (self.manager) |v| v.destroy();
                self.manager = null;
                self.manager_name = 0;
            },
        }
    }
    fn identity(shell: *aq.ShellManagerV1, event: aq.ShellManagerV1.Event, self: *Effects) void {
        if (event != .capabilities) return;
        const bytes = std.mem.span(event.capabilities.json);
        if (bytes.len > 65536) return;
        const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return;
        defer parsed.deinit();
        const e = @import("../../aqueous/entities.zig");
        const session = e.read([]const u8, a, e.field(parsed.value, "session") catch return) catch return;
        e.sessionToken(session) catch return;
        self.display_session = session[0..32].*;
        self.shell = null;
        shell.destroy();
        if (self.changed) |notify| notify(self.context.?);
    }
    fn capabilities(_: *ext.BackgroundEffectManagerV1, event: ext.BackgroundEffectManagerV1.Event, self: *Effects) void {
        switch (event) {
            .capabilities => |c| self.available = c.flags.blur,
        }
        std.log.info("event=blur-capability available={}", .{self.available});
        for (self.surfaces.items) |s| s.refresh();
    }
};
pub const Surface = struct {
    owner: *Effects,
    window: *gtk.Window,
    panel: ?*gtk.Widget,
    blur: bool,
    input: enum { empty, panel, full },
    native: ?*gdk.Surface = null,
    clock: ?*gdk.FrameClock = null,
    paint_signal: c_ulong = 0,
    map_signal: c_ulong = 0,
    unmap_signal: c_ulong = 0,
    unrealize_signal: c_ulong = 0,
    effect: ?*ext.BackgroundEffectSurfaceV1 = null,
    last: ?Rect = null,
    last_available: bool = false,
    pub fn init(self: *Surface, owner: *Effects, window: *gtk.Window, panel: ?*gtk.Widget, blur: bool, input: @FieldType(Surface, "input")) !void {
        self.* = .{ .owner = owner, .window = window, .panel = panel, .blur = blur, .input = input };
        try owner.surfaces.append(a, self);
        self.map_signal = gtk.Widget.signals.map.connect(window.as(gtk.Widget), *Surface, mapped, self, .{});
        self.unmap_signal = gtk.Widget.signals.unmap.connect(window.as(gtk.Widget), *Surface, unmapped, self, .{});
        self.unrealize_signal = gtk.Widget.signals.unrealize.connect(window.as(gtk.Widget), *Surface, unmapped, self, .{});
    }
    pub fn deinit(self: *Surface) void {
        self.detach();
        disconnect(self.window.as(object.Object), self.map_signal);
        disconnect(self.window.as(object.Object), self.unmap_signal);
        disconnect(self.window.as(object.Object), self.unrealize_signal);
        for (self.owner.surfaces.items, 0..) |s, i| if (s == self) {
            _ = self.owner.surfaces.orderedRemove(i);
            break;
        };
    }
    fn mapped(_: *gtk.Widget, self: *Surface) callconv(.c) void {
        self.detach();
        self.native = self.window.as(gtk.Native).getSurface();
        if (self.native) |native| {
            _ = native.ref();
            self.clock = native.getFrameClock();
            _ = self.clock.?.ref();
            self.paint_signal = gdk.FrameClock.signals.after_paint.connect(self.clock.?, *Surface, painted, self, .{});
            self.refresh();
        }
    }
    fn unmapped(_: *gtk.Widget, self: *Surface) callconv(.c) void {
        self.detach();
    }
    fn painted(_: *gdk.FrameClock, self: *Surface) callconv(.c) void {
        self.refresh();
    }
    fn detach(self: *Surface) void {
        if (self.clock) |clock| {
            disconnect(clock.as(object.Object), self.paint_signal);
            clock.unref();
        }
        self.clock = null;
        self.clearEffect();
        if (self.native) |surface| surface.unref();
        self.native = null;
        self.last = null;
    }
    fn clearEffect(self: *Surface) void {
        if (self.effect) |v| v.destroy();
        self.effect = null;
        self.last = null;
    }
    pub fn refresh(self: *Surface) void {
        const native = self.native orelse return;
        if (native.isDestroyed() != 0) {
            self.detach();
            return;
        }
        const available = self.blur and self.owner.available and self.owner.manager != null and self.owner.compositor != null;
        if (available) self.window.as(gtk.Widget).addCssClass("pearl-blur") else self.window.as(gtk.Widget).removeCssClass("pearl-blur");
        var allocation: gtk.Allocation = undefined;
        if (self.panel) |panel| panel.getAllocation(&allocation) else allocation = .{ .f_x = 0, .f_y = 0, .f_width = native.getWidth(), .f_height = native.getHeight() };
        const rect: Rect = .{ .x = allocation.f_x, .y = allocation.f_y, .width = allocation.f_width, .height = allocation.f_height };
        if (rect.width <= 0 or rect.height <= 0) return;
        if (self.last) |last| if (std.meta.eql(last, rect) and available == self.last_available) return;
        self.last = rect;
        self.last_available = available;
        const region = cairo.Region.create();
        defer region.destroy();
        if (self.input == .panel) rounded(region, rect, 14);
        if (self.input == .full) native.setInputRegion(null) else native.setInputRegion(region);
        if (available) {
            if (self.effect == null) {
                const wayland = object.ext.cast(backend.WaylandSurface, native) orelse return;
                const surface: *wl.Surface = @ptrCast(wayland.getWlSurface() orelse return);
                self.effect = self.owner.manager.?.getBackgroundEffect(surface) catch return;
            }
            const blur_region = self.owner.compositor.?.createRegion() catch return;
            defer blur_region.destroy();
            const shape = cairo.Region.create();
            defer shape.destroy();
            rounded(shape, rect, 14);
            for (0..@intCast(shape.numRectangles())) |i| {
                var r: cairo.RectangleInt = undefined;
                shape.getRectangle(@intCast(i), &r);
                blur_region.add(r.x, r.y, r.width, r.height);
            }
            self.effect.?.setBlurRegion(blur_region);
        } else if (self.effect) |effect| effect.setBlurRegion(null);
        // Region state is double buffered. Ask GTK for the next commit; never
        // commit/attach GTK's wl_surface ourselves or read its display socket.
        self.window.as(gtk.Widget).queueDraw();
        self.owner.display.flush();
    }
};
fn rounded(region: *cairo.Region, rect: Rect, radius: i32) void {
    const r = @min(radius, @divTrunc(@min(rect.width, rect.height), 2));
    for (0..@intCast(rect.height)) |row| {
        const y: i32 = @intCast(row);
        const dy = if (y < r) r - y - 1 else if (y >= rect.height - r) y - (rect.height - r) else 0;
        const inset: i32 = if (dy == 0) 0 else r - @as(i32, @intFromFloat(@sqrt(@as(f64, @floatFromInt(r * r - dy * dy)))));
        _ = region.unionRectangle(&.{ .x = rect.x + inset, .y = rect.y + y, .width = rect.width - 2 * inset, .height = 1 });
    }
}

fn disconnect(instance: *object.Object, id: c_ulong) void {
    // GDK may dispose clocks/windows during monitor removal before our cleanup.
    if (object.signalHandlerIsConnected(instance, id) != 0) object.signalHandlerDisconnect(instance, id);
}
