//! Output surfaces reconcile by connector identity, never by monitor list position.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const layer = @import("gtk4layershell1");
const native = @import("../../platform/wayland/effects.zig");
const adapter = @import("../../aqueous/client.zig");
const protocol = @import("../../cli/protocol.zig");
const policy = @import("policy.zig");
const a = std.heap.c_allocator;
const Rect = policy.Rect;
const Edge = policy.Edge;
const Kind = enum { wallpaper, bar, popup, osd, frame };
const Surface = struct {
    manager: *Manager,
    output: *Output,
    kind: Kind,
    window: *gtk.Window,
    panel: *gtk.Widget,
    effects: native.Surface = undefined,
    edge: Edge = .top,
    measure_signal: c_ulong = 0,
    measure_clock: ?*gdk.FrameClock = null,
    fn destroy(self: *Surface) void {
        if (self.measure_clock) |clock| {
            if (object.signalHandlerIsConnected(clock.as(object.Object), self.measure_signal) != 0) object.signalHandlerDisconnect(clock.as(object.Object), self.measure_signal);
            clock.unref();
        }
        self.effects.deinit();
        self.window.destroy();
        self.window.unref();
        a.destroy(self);
    }
};
const Output = struct {
    manager: *Manager,
    id: []u8,
    connector: [:0]u8,
    monitor: *gdk.Monitor,
    bounds: Rect,
    usable: Rect,
    scale: f64,
    reservations: policy.Reservation = .{},
    wallpaper: ?*Surface = null,
    bar: ?*Surface = null,
    frames: [4]?*Surface = .{ null, null, null, null },
    seen: bool = false,
    fn destroy(self: *Output) void {
        if (self.wallpaper) |s| s.destroy();
        if (self.bar) |s| s.destroy();
        for (self.frames) |s| if (s) |v| v.destroy();
        self.monitor.unref();
        a.free(self.id);
        a.free(self.connector);
        a.destroy(self);
    }
};
pub const Manager = struct {
    app: *gtk.Application,
    display: *gdk.Display,
    client: *adapter.Client,
    effects: native.Effects = undefined,
    outputs: std.ArrayList(*Output) = .empty,
    popup: ?*Surface = null,
    popup_rect: ?Rect = null,
    osd: ?*Surface = null,
    osd_source: c_uint = 0,
    sync_source: c_uint = 0,
    monitor_signal: c_ulong = 0,
    running: bool = false,
    context: ?*anyopaque = null,
    changed: ?*const fn (*anyopaque) void = null,
    pub fn init(app: *gtk.Application, display: *gdk.Display, client: *adapter.Client) Manager {
        return .{ .app = app, .display = display, .client = client };
    }
    pub fn start(self: *Manager) !void {
        if (layer.isSupported() == 0) return error.LayerShellUnavailable;
        self.effects = try native.Effects.init(self.display);
        self.running = true;
        self.effects.context = self;
        self.effects.changed = nativeChanged;
        self.effects.start();
        self.monitor_signal = gio.ListModel.signals.items_changed.connect(self.display.getMonitors(), *Manager, monitorsChanged, self, .{});
        self.schedule();
    }
    pub fn deinit(self: *Manager) void {
        if (!self.running) return;
        self.running = false;
        if (self.sync_source != 0) _ = glib.Source.remove(self.sync_source);
        self.sync_source = 0;
        object.signalHandlerDisconnect(self.display.getMonitors().as(object.Object), self.monitor_signal);
        self.clear();
        self.outputs.deinit(a);
        self.effects.deinit();
    }
    pub fn schedule(self: *Manager) void {
        if (self.running and self.sync_source == 0) self.sync_source = glib.idleAdd(syncIdle, self);
    }
    pub fn clear(self: *Manager) void {
        self.hidePopup();
        self.hideOsd();
        for (self.outputs.items) |o| o.destroy();
        self.outputs.clearRetainingCapacity();
    }
    fn nativeChanged(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        self.schedule();
        if (self.changed) |notify| notify(self.context.?);
    }
    fn monitorsChanged(_: *gio.ListModel, _: c_uint, _: c_uint, _: c_uint, self: *Manager) callconv(.c) void {
        self.schedule();
    }
    fn syncIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Manager = @ptrCast(@alignCast(data.?));
        self.sync_source = 0;
        self.sync() catch |err| std.log.err("event=surface-error error={s}", .{@errorName(err)});
        return 0;
    }
    fn sync(self: *Manager) !void {
        if (self.client.availability != .ready) {
            self.clear();
            return;
        }
        const identity = self.effects.display_session orelse return;
        if (!std.mem.eql(u8, &identity, self.client.model.session)) {
            self.clear();
            return error.SessionDisplayMismatch;
        }
        for (self.outputs.items) |o| o.seen = false;
        const monitors = self.display.getMonitors();
        var values = self.client.model.entities.valueIterator();
        while (values.next()) |entity| {
            if (entity.* != .output or !entity.output.enabled or !entity.output.powered) continue;
            const record = entity.output;
            var found: ?*gdk.Monitor = null;
            var matches: usize = 0;
            for (0..monitors.getNItems()) |i| {
                const item = monitors.getItem(@intCast(i)) orelse continue;
                const monitor: *gdk.Monitor = @ptrCast(@alignCast(item));
                defer monitor.unref();
                const connector = monitor.getConnector() orelse continue;
                if (std.mem.eql(u8, record.name, std.mem.span(connector)) and monitor.isValid() != 0) {
                    found = monitor;
                    matches += 1;
                }
            }
            if (matches != 1) continue;
            var output: ?*Output = null;
            for (self.outputs.items) |o| if (std.mem.eql(u8, o.id, record.id) and std.mem.eql(u8, o.connector, record.name) and o.monitor == found.?) {
                output = o;
                break;
            };
            const bounds = try rectangle(record.bounds);
            const usable = try rectangle(record.usable_bounds);
            if (output == null) {
                if (self.outputs.items.len >= 16) return error.TooManyOutputs;
                const o = try a.create(Output);
                errdefer a.destroy(o);
                const id = try a.dupe(u8, record.id);
                errdefer a.free(id);
                const connector = try a.dupeZ(u8, record.name);
                errdefer a.free(connector);
                _ = found.?.ref();
                o.* = .{ .manager = self, .id = id, .connector = connector, .monitor = found.?, .bounds = bounds, .usable = usable, .scale = record.scale };
                errdefer o.monitor.unref();
                o.wallpaper = try self.create(o, .wallpaper);
                errdefer o.wallpaper.?.destroy();
                o.bar = try self.create(o, .bar);
                errdefer o.bar.?.destroy();
                try self.outputs.append(a, o);
                output = o;
                std.log.info("event=output-mapped id={s} connector={s} scale={d}", .{ o.id, o.connector, o.scale });
            }
            const o = output.?;
            o.seen = true;
            const changed = !std.meta.eql(o.bounds, bounds) or !std.meta.eql(o.usable, usable);
            o.bounds = bounds;
            o.usable = usable;
            o.scale = record.scale;
            if (changed and self.popup != null and self.popup.?.output == o) self.positionPopup();
        }
        var i: usize = 0;
        while (i < self.outputs.items.len) {
            const o = self.outputs.items[i];
            if (!o.seen) {
                if (self.popup != null and self.popup.?.output == o) self.hidePopup();
                if (self.osd != null and self.osd.?.output == o) self.hideOsd();
                _ = self.outputs.orderedRemove(i);
                o.destroy();
            } else i += 1;
        }
        if (self.client.model.get(.session, "session").?.locked) {
            self.hidePopup();
            self.hideOsd();
        }
    }
    fn create(self: *Manager, output: *Output, kind: Kind) !*Surface {
        const s = try a.create(Surface);
        errdefer a.destroy(s);
        const window = gtk.ApplicationWindow.new(self.app).as(gtk.Window);
        _ = window.ref();
        errdefer {
            window.destroy();
            window.unref();
        }
        window.setTitle("Pearl");
        window.as(gtk.Widget).addCssClass("pearl-root");
        window.as(gtk.Widget).addCssClass("pearl-dark");
        window.as(gtk.Widget).addCssClass("pearl-shell");
        layer.initForWindow(window);
        layer.setMonitor(window, output.monitor);
        layer.setNamespace(window, switch (kind) {
            .wallpaper => "pearl:wallpaper",
            .bar => "pearl:bar",
            .popup => "pearl:popup",
            .osd => "pearl:osd",
            .frame => "pearl:frame-exclusion",
        });
        layer.setLayer(window, switch (kind) {
            .wallpaper => .background,
            .bar, .frame => .top,
            .popup, .osd => .overlay,
        });
        layer.setExclusiveZone(window, 0);
        layer.setKeyboardMode(window, if (kind == .popup) .exclusive else .none);
        const panel = gtk.Box.new(.vertical, 12);
        const panel_widget = panel.as(gtk.Widget);
        if (kind != .wallpaper and kind != .frame) panel_widget.addCssClass("pearl-surface-panel");
        s.* = .{ .manager = self, .output = output, .kind = kind, .window = window, .panel = panel_widget };
        switch (kind) {
            .wallpaper => {
                window.as(gtk.Widget).addCssClass("pearl-wallpaper");
                anchors(window, null);
                layer.setExclusiveZone(window, -1);
                window.setChild(panel_widget);
            },
            .bar => {
                panel_widget.addCssClass("pearl-bar-panel");
                inline for ([_]fn (*gtk.Widget, c_int) callconv(.c) void{ gtk.Widget.setMarginStart, gtk.Widget.setMarginEnd, gtk.Widget.setMarginTop, gtk.Widget.setMarginBottom }) |set| set(panel_widget, 4);
                const button = gtk.Button.newWithLabel("Pearl");
                button.as(gtk.Widget).setTooltipText("Open Pearl");
                _ = gtk.Button.signals.clicked.connect(button, *Surface, barClicked, s, .{});
                panel.append(button.as(gtk.Widget));
                window.setChild(panel_widget);
                s.edge = output.reservations.bar_edge;
                sizeEdge(s, s.edge, output.reservations.bar_size);
            },
            .frame => {
                // A transparent texture still creates a render node and buffer.
                // An empty transparent GtkBox may never map a layer surface.
                const pixels = glib.Bytes.newStatic(&[_]u8{ 0, 0, 0, 0 }, 4);
                defer pixels.unref();
                const texture = gdk.MemoryTexture.new(1, 1, .r8g8b8a8_premultiplied, pixels, 4);
                defer texture.unref();
                const picture = gtk.Picture.newForPaintable(texture.as(gdk.Paintable));
                picture.setCanShrink(1);
                picture.setContentFit(.fill);
                picture.as(gtk.Widget).setHexpand(1);
                picture.as(gtk.Widget).setVexpand(1);
                panel.append(picture.as(gtk.Widget));
                window.setChild(panel_widget);
            },
            .popup => {
                anchors(window, null);
                const fixed = gtk.Fixed.new();
                fixed.put(panel_widget, 0, 0);
                window.setChild(fixed.as(gtk.Widget));
                panel_widget.addCssClass("pearl-popup-panel");
                const title = gtk.Label.new("Pearl");
                title.as(gtk.Widget).addCssClass("pearl-card-title");
                panel.append(title.as(gtk.Widget));
                const label = gtk.Label.new("Your desktop controls will appear here.");
                label.setWrap(1);
                panel.append(label.as(gtk.Widget));
                const close = gtk.Button.newWithLabel("Close");
                _ = gtk.Button.signals.clicked.connect(close, *Manager, popupClosed, self, .{});
                panel.append(close.as(gtk.Widget));
                const keys = gtk.EventControllerKey.new();
                _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Manager, keyPressed, self, .{});
                window.as(gtk.Widget).addController(keys.as(gtk.EventController));
                const click = gtk.GestureClick.new();
                click.as(gtk.EventController).setPropagationPhase(.capture);
                _ = gtk.GestureClick.signals.released.connect(click, *Manager, outsideReleased, self, .{});
                window.as(gtk.Widget).addController(click.as(gtk.EventController));
            },
            .osd => {
                layer.setAnchor(window, .bottom, 1);
                layer.setMargin(window, .bottom, 24);
                panel_widget.addCssClass("pearl-osd-panel");
                window.setDefaultSize(320, 72);
                window.setChild(panel_widget);
            },
        }
        try s.effects.init(&self.effects, window, panel_widget, kind == .bar or kind == .popup or kind == .osd, if (kind == .popup) .full else if (kind == .bar) .panel else .empty);
        if (kind != .popup and kind != .osd and kind != .frame) window.present();
        if (kind == .bar) {
            if (window.as(gtk.Widget).getFrameClock()) |clock| {
                _ = clock.ref();
                s.measure_clock = clock;
                s.measure_signal = gdk.FrameClock.signals.after_paint.connect(clock, *Surface, measured, s, .{});
            }
        }
        return s;
    }
    fn selected(self: *Manager, id: ?[]const u8) !*Output {
        if (self.client.availability != .ready) return error.Unavailable;
        const target = id orelse blk: {
            const focus = try self.client.model.focus(null);
            break :blk (focus.output orelse return error.Unavailable).id;
        };
        for (self.outputs.items) |o| if (std.mem.eql(u8, target, o.id)) return o;
        return error.OutputUnavailable;
    }
    pub fn showPopup(self: *Manager, output: *Output) !void {
        if (self.client.model.get(.session, "session").?.locked) return error.Locked;
        self.hidePopup();
        self.popup = try self.create(output, .popup);
        self.positionPopup();
        self.popup.?.window.present();
        std.log.info("event=popup-opened output={s}", .{output.id});
    }
    fn positionPopup(self: *Manager) void {
        const s = self.popup orelse return;
        const o = s.output;
        const rect = policy.popup(o.bounds, o.usable, 440, 280);
        self.popup_rect = rect;
        const fixed = object.ext.cast(gtk.Fixed, s.window.getChild().?).?;
        fixed.move(s.panel, @floatFromInt(rect.x - (o.usable.x - o.bounds.x)), @floatFromInt(rect.y - (o.usable.y - o.bounds.y)));
        s.panel.setSizeRequest(rect.width, rect.height);
    }
    pub fn hidePopup(self: *Manager) void {
        if (self.popup) |s| {
            self.popup = null;
            self.popup_rect = null;
            s.destroy();
            std.log.info("event=popup-closed", .{});
        }
    }
    fn hideOsd(self: *Manager) void {
        if (self.osd_source != 0) _ = glib.Source.remove(self.osd_source);
        self.osd_source = 0;
        if (self.osd) |s| {
            self.osd = null;
            s.destroy();
        }
    }
    pub fn control(self: *Manager, request: protocol.Request, alloc: std.mem.Allocator) ![]const u8 {
        if (request.op == .status) return self.status(alloc);
        if (self.client.availability != .ready) return error.Unavailable;
        if (request.op != .quit and self.client.model.get(.session, "session").?.locked) return error.Locked;
        switch (request.op) {
            .status => unreachable,
            .quit => {},
            .popup_hide => self.hidePopup(),
            .popup_show => try self.showPopup(try self.selected(request.output)),
            .popup_toggle => {
                const o = try self.selected(request.output);
                if (self.popup != null and self.popup.?.output == o) self.hidePopup() else try self.showPopup(o);
            },
            .bar_set => {
                const o = try self.selected(request.output);
                try o.reservations.bar(request.edge.?, request.size.?);
                const s = o.bar.?;
                s.edge = request.edge.?;
                sizeEdge(s, s.edge, request.size.?);
            },
            .frame_set => {
                const o = try self.selected(request.output);
                const edge = request.edge.?;
                try o.reservations.frame(edge, request.size.?);
                const index = @intFromEnum(edge);
                if (o.frames[index]) |s| {
                    s.destroy();
                    o.frames[index] = null;
                }
                if (request.size.? != 0) {
                    const s = try self.create(o, .frame);
                    o.frames[index] = s;
                    s.edge = edge;
                    sizeEdge(s, edge, request.size.?);
                    s.window.present();
                }
            },
            .osd_show => {
                const o = try self.selected(request.output);
                self.hideOsd();
                const s = try self.create(o, .osd);
                self.osd = s;
                const text = try alloc.dupeZ(u8, request.text.?);
                const label = gtk.Label.new(text);
                label.setWrap(1);
                label.setWrapMode(.word_char);
                label.setMaxWidthChars(40);
                object.ext.cast(gtk.Box, s.panel).?.append(label.as(gtk.Widget));
                s.window.present();
                self.osd_source = glib.timeoutAdd(request.duration_ms orelse 2000, osdExpired, self);
            },
        }
        return "{\"applied\":true}";
    }
    fn status(self: *Manager, alloc: std.mem.Allocator) ![]const u8 {
        const Item = struct { id: []const u8, connector: []const u8, scale: f64, bounds: Rect, usable: Rect, bar_edge: Edge, bar_size: u16, frames: [4]u16 };
        var items: std.ArrayList(Item) = .empty;
        for (self.outputs.items) |o| try items.append(alloc, .{ .id = o.id, .connector = o.connector, .scale = o.scale, .bounds = o.bounds, .usable = o.usable, .bar_edge = o.reservations.bar_edge, .bar_size = o.reservations.bar_size, .frames = o.reservations.frames });
        return std.json.Stringify.valueAlloc(alloc, .{ .session = self.client.model.session, .availability = self.client.availability, .blur = self.effects.available, .outputs = items.items, .popup = if (self.popup) |s| @as(?struct { output: []const u8, rect: Rect }, .{ .output = s.output.id, .rect = self.popup_rect.? }) else null, .osd = self.osd != null }, .{});
    }
};
fn rectangle(r: anytype) !Rect {
    return .{ .x = std.math.cast(i32, r.x) orelse return error.InvalidGeometry, .y = std.math.cast(i32, r.y) orelse return error.InvalidGeometry, .width = std.math.cast(i32, r.width) orelse return error.InvalidGeometry, .height = std.math.cast(i32, r.height) orelse return error.InvalidGeometry };
}
fn anchors(window: *gtk.Window, edge: ?Edge) void {
    for ([_]Edge{ .top, .right, .bottom, .left }) |e| {
        const enabled = if (edge) |selected| e != opposite(selected) else true;
        layer.setAnchor(window, switch (e) {
            .top => .top,
            .bottom => .bottom,
            .left => .left,
            .right => .right,
        }, @intFromBool(enabled));
    }
}
fn opposite(edge: Edge) Edge {
    return switch (edge) {
        .top => .bottom,
        .bottom => .top,
        .left => .right,
        .right => .left,
    };
}
fn sizeEdge(s: *Surface, edge: Edge, size: u16) void {
    anchors(s.window, edge);
    const horizontal = edge == .top or edge == .bottom;
    s.window.setDefaultSize(if (horizontal) 1 else size, if (horizontal) size else 1);
    const content = if (s.kind == .frame) size else size -| 8;
    s.panel.setSizeRequest(if (horizontal) -1 else content, if (horizontal) content else -1);
    layer.setExclusiveZone(s.window, size);
}
fn measured(_: *gdk.FrameClock, s: *Surface) callconv(.c) void {
    const horizontal = s.edge == .top or s.edge == .bottom;
    const size = if (horizontal) s.window.as(gtk.Widget).getHeight() else s.window.as(gtk.Widget).getWidth();
    if (size > 0 and size <= 65535 and layer.getExclusiveZone(s.window) != size) {
        layer.setExclusiveZone(s.window, size);
        s.output.reservations.bar_size = @intCast(size);
    }
}
fn barClicked(_: *gtk.Button, s: *Surface) callconv(.c) void {
    const self = s.manager;
    if (self.popup != null and self.popup.?.output == s.output) self.hidePopup() else self.showPopup(s.output) catch {};
}
fn popupClosed(_: *gtk.Button, self: *Manager) callconv(.c) void {
    self.hidePopup();
}
fn keyPressed(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, _: gdk.ModifierType, self: *Manager) callconv(.c) c_int {
    if (key != 0xff1b) return 0;
    self.hidePopup();
    return 1;
}
fn outsideReleased(_: *gtk.GestureClick, _: c_int, x: f64, y: f64, self: *Manager) callconv(.c) void {
    const s = self.popup orelse return;
    const picked = s.window.as(gtk.Widget).pick(x, y, .{});
    if (picked) |widget| if (widget == s.panel or widget.isAncestor(s.panel) != 0) return;
    self.hidePopup();
}
fn osdExpired(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Manager = @ptrCast(@alignCast(data.?));
    self.osd_source = 0;
    self.hideOsd();
    return 0;
}
