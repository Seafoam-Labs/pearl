//! Per-bar reveal surface and one-shot hide timer. GTK callbacks stay on the main thread.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const glib = @import("glib2");
const object = @import("gobject2");
const layer = @import("gtk4layershell1");
const p = @import("bar_visibility.zig");
const Edge = @import("../ui/surfaces/policy.zig").Edge;
const a = std.heap.c_allocator;
const fade_ms: f64 = 180;
const fade_step_ms: c_uint = 16;

pub const Controller = struct {
    window: *gtk.Window,
    sensor: *gtk.Window,
    motion: [2]*gtk.EventControllerMotion,
    events: *gtk.EventControllerLegacy,
    state: p.State = .{},
    edge: Edge = .top,
    thickness: i32 = 48,
    fullscreen: bool = false,
    timer: c_uint = 0,
    destroying: bool = false,
    applying: bool = false,
    shown: bool = false,
    fade: c_uint = 0,
    fade_start: i64 = 0,
    fade_from: f64 = 1,
    fade_to: f64 = 1,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,

    pub fn create(window: *gtk.Window, monitor: *gdk.Monitor, context: *anyopaque, changed: @FieldType(Controller, "changed")) !*Controller {
        const self = try a.create(Controller);
        const sensor = gtk.Window.new();
        _ = sensor.as(object.Object).refSink();
        sensor.setApplication(window.getApplication());
        sensor.setDecorated(0);
        sensor.setTitle("Pearl bar reveal");
        sensor.as(gtk.Widget).addCssClass("pearl-root");
        sensor.as(gtk.Widget).addCssClass("pearl-shell");
        layer.initForWindow(sensor);
        layer.setMonitor(sensor, monitor);
        layer.setNamespace(sensor, "pearl:bar-reveal");
        layer.setLayer(sensor, .overlay);
        layer.setExclusiveZone(sensor, -1);
        layer.setKeyboardMode(sensor, .none);
        const pixels = glib.Bytes.newStatic(&[_]u8{ 0, 0, 0, 0 }, 4);
        defer pixels.unref();
        const texture = gdk.MemoryTexture.new(1, 1, .r8g8b8a8_premultiplied, pixels, 4);
        defer texture.unref();
        const picture = gtk.Picture.newForPaintable(texture.as(gdk.Paintable));
        picture.setContentFit(.fill);
        sensor.setChild(picture.as(gtk.Widget));
        self.* = .{ .window = window, .sensor = sensor, .motion = undefined, .events = gtk.EventControllerLegacy.new(), .context = context, .changed = changed };
        for ([_]*gtk.Window{ window, sensor }, 0..) |win, i| {
            self.motion[i] = self.connectMotion(win);
        }
        self.events.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerLegacy.signals.event.connect(self.events, *Controller, event, self, .{});
        window.as(gtk.Widget).addController(self.events.as(gtk.EventController));
        return self;
    }
    fn connectMotion(self: *Controller, window: *gtk.Window) *gtk.EventControllerMotion {
        const motion = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.enter.connect(motion, *Controller, entered, self, .{});
        _ = gtk.EventControllerMotion.signals.motion.connect(motion, *Controller, entered, self, .{});
        _ = gtk.EventControllerMotion.signals.leave.connect(motion, *Controller, left, self, .{});
        window.as(gtk.Widget).addController(motion.as(gtk.EventController));
        return motion;
    }
    pub fn destroy(self: *Controller) void {
        self.destroying = true;
        self.cancelTimer();
        self.stopFade();
        self.window.as(gtk.Widget).removeController(self.motion[0].as(gtk.EventController));
        self.window.as(gtk.Widget).removeController(self.events.as(gtk.EventController));
        self.sensor.destroy();
        self.sensor.unref();
        a.destroy(self);
    }
    fn cancelTimer(self: *Controller) void {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.timer = 0;
    }
    pub fn configure(self: *Controller, mode: p.Mode, edge: Edge, thickness: i32, inhibited: bool, fullscreen: bool) void {
        const geometry_changed = self.state.mode != mode or self.edge != edge or self.thickness != thickness;
        const reset = self.state.mode != mode or self.edge != edge or self.state.inhibited != inhibited;
        self.state.mode = mode;
        self.state.inhibited = inhibited;
        self.edge = edge;
        self.thickness = thickness;
        self.fullscreen = fullscreen;
        if (reset) {
            self.cancelTimer();
            // Motion controllers retain contains-pointer across unmap, and do
            // not implement reset(). Fresh controllers receive the next enter.
            for ([_]*gtk.Window{ self.window, self.sensor }, 0..) |win, i| {
                win.as(gtk.Widget).removeController(self.motion[i].as(gtk.EventController));
                self.motion[i] = self.connectMotion(win);
            }
            self.events.as(gtk.EventController).reset();
            self.state.resetPointer();
            if (!inhibited) self.readPointer();
        }
        for (std.enums.values(Edge)) |e| {
            const opposite: Edge = switch (edge) {
                .top => .bottom,
                .bottom => .top,
                .left => .right,
                .right => .left,
            };
            layer.setAnchor(self.sensor, nativeEdge(e), @intFromBool(e != opposite));
        }
        const vertical = edge == .left or edge == .right;
        self.sensor.setDefaultSize(if (vertical) 2 else 1, if (vertical) 1 else 2);
        self.apply();
        if (geometry_changed) self.changed(self.context);
    }
    pub fn inhibit(self: *Controller, inhibited: bool) void {
        self.configure(self.state.mode, self.edge, self.thickness, inhibited, self.fullscreen);
    }
    pub fn holdPopup(self: *Controller, held: bool) void {
        self.state.popup = held;
        self.apply();
    }
    pub fn clearGesture(self: *Controller) void {
        self.state.gesture = false;
        self.apply();
    }
    pub fn measured(self: *Controller, thickness: i32) void {
        self.thickness = thickness;
        layer.setExclusiveZone(self.window, self.state.exclusiveZone(thickness));
    }
    fn readPointer(self: *Controller) void {
        const seat = self.window.as(gtk.Widget).getDisplay().getDefaultSeat() orelse return;
        const pointer = seat.getPointer() orelse return;
        const surface = pointer.getSurfaceAtPosition(null, null) orelse return;
        self.state.bar_pointer = surface == self.window.as(gtk.Native).getSurface();
        self.state.sensor_pointer = surface == self.sensor.as(gtk.Native).getSurface();
    }
    fn apply(self: *Controller) void {
        if (self.destroying or self.applying) return;
        self.applying = true;
        defer self.applying = false;
        const now = @divTrunc(glib.getMonotonicTime(), 1000);
        self.state.update(now);
        self.cancelTimer();
        if (self.state.deadline) |deadline| self.timer = glib.timeoutAdd(@intCast(@max(1, deadline - now)), hideLater, self);
        layer.setExclusiveZone(self.window, self.state.exclusiveZone(self.thickness));
        const overlay = self.state.mode == .autohide and self.state.visible and self.fullscreen;
        layer.setLayer(self.window, if (overlay) .overlay else .top);
        self.sensor.as(gtk.Widget).setVisible(@intFromBool(self.state.sensor()));
        if (self.shown != self.state.visible) {
            self.shown = self.state.visible;
            self.animate(self.state.visible);
            self.changed(self.context);
        }
    }
    /// Fades the bar instead of popping it; only autohide animates, and reduced
    /// motion keeps the instant switch.
    fn animate(self: *Controller, show: bool) void {
        const widget = self.window.as(gtk.Widget);
        if (self.state.mode != .autohide or widget.hasCssClass("pearl-reduced-motion") != 0) {
            self.stopFade();
            widget.setOpacity(1);
            widget.setVisible(@intFromBool(show));
            return;
        }
        const was_visible = widget.getVisible() != 0;
        self.fade_from = if (was_visible) widget.getOpacity() else 0;
        self.fade_to = if (show) 1 else 0;
        self.fade_start = @divTrunc(glib.getMonotonicTime(), 1000);
        if (show) {
            if (!was_visible) widget.setOpacity(0);
            widget.setVisible(1);
        }
        if (self.fade == 0) self.fade = glib.timeoutAdd(fade_step_ms, fadeStep, self);
    }
    fn stopFade(self: *Controller) void {
        if (self.fade != 0) _ = glib.Source.remove(self.fade);
        self.fade = 0;
    }
    fn fadeStep(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        self.fade = 0;
        if (self.destroying) return 0;
        const widget = self.window.as(gtk.Widget);
        const elapsed = @divTrunc(glib.getMonotonicTime(), 1000) - self.fade_start;
        const t = @min(1.0, @max(0.0, @as(f64, @floatFromInt(elapsed)) / fade_ms));
        const eased = 1 - std.math.pow(f64, 1 - t, 3);
        widget.setOpacity(self.fade_from + (self.fade_to - self.fade_from) * eased);
        if (t >= 1.0) {
            if (self.fade_to == 0) widget.setVisible(0);
            return 0;
        }
        self.fade = glib.timeoutAdd(fade_step_ms, fadeStep, self);
        return 0;
    }
    fn entered(motion: *gtk.EventControllerMotion, _: f64, _: f64, self: *Controller) callconv(.c) void {
        if (self.destroying or self.state.inhibited) return;
        if (motion == self.motion[0]) self.state.bar_pointer = true else self.state.sensor_pointer = true;
        self.apply();
    }
    fn left(motion: *gtk.EventControllerMotion, self: *Controller) callconv(.c) void {
        if (self.destroying) return;
        if (motion == self.motion[0]) self.state.bar_pointer = false else self.state.sensor_pointer = false;
        self.apply();
    }
    fn event(_: *gtk.EventControllerLegacy, ev: *gdk.Event, self: *Controller) callconv(.c) c_int {
        if (self.destroying) return 0;
        switch (ev.getEventType()) {
            .button_press, .touch_begin => self.state.gesture = true,
            .button_release, .touch_end, .touch_cancel => self.state.gesture = false,
            else => return 0,
        }
        self.apply();
        return 0;
    }
    fn hideLater(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        self.timer = 0;
        self.apply();
        return 0;
    }
};
fn nativeEdge(edge: Edge) layer.Edge {
    return switch (edge) {
        .top => .top,
        .bottom => .bottom,
        .left => .left,
        .right => .right,
    };
}
