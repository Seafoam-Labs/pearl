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
const Bar = @import("../../desktop/bar.zig");
const Apps = @import("../../desktop/apps.zig");
const Launcher = @import("../../desktop/launcher.zig").Launcher;
const Panels = @import("../../desktop/panels.zig");
const Layout = @import("../../platform/wayland/layout.zig").Layout;
const Groups = @import("../../desktop/policy.zig").Groups;
const tr = @import("../../desktop/text.zig").tr;
const a = std.heap.c_allocator;
const Rect = policy.Rect;
const Edge = policy.Edge;
const Kind = enum { wallpaper, bar, popup, osd, frame, notification };
const Surface = struct {
    manager: *Manager,
    output: *Output,
    kind: Kind,
    window: *gtk.Window,
    panel: *gtk.Widget,
    effects: native.Surface = undefined,
    edge: Edge = .top,
    bar: ?*Bar.Bar = null,
    launcher: ?*Launcher = null,
    control: ?*Panels.Control = null,
    notifications: ?*@import("../../desktop/notifications.zig").View = null,
    media: ?*@import("../../desktop/media.zig").View = null,
    tray: ?*@import("../../desktop/tray.zig").View = null,
    settings: ?*@import("../../desktop/settings.zig").View = null,
    wallpaper_picture: ?*gtk.Picture = null,
    appearance_revision: u64 = std.math.maxInt(u64),
    measure_signal: c_ulong = 0,
    measure_clock: ?*gdk.FrameClock = null,
    fn destroy(self: *Surface) void {
        if (self.settings) |view| view.destroy();
        if (self.notifications) |view| view.destroy();
        if (self.media) |view| view.destroy();
        if (self.tray) |view| view.destroy();
        if (self.bar) |bar| bar.destroy();
        if (self.launcher) |launcher| launcher.destroy();
        if (self.control) |control| control.destroy();
        if (self.measure_clock) |clock| {
            if (object.signalHandlerIsConnected(clock.as(object.Object), self.measure_signal) != 0) object.signalHandlerDisconnect(clock.as(object.Object), self.measure_signal);
            clock.unref();
        }
        self.effects.deinit();

        self.window.destroy();
        self.window.unref();
        self.panel.unref();
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
    preferences_revision: u64 = 0,
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
    pane: Bar.Pane = .launcher,
    audio: @import("../../services/audio.zig").Audio = undefined,
    power: @import("../../services/power.zig").Power = undefined,
    network: @import("../../services/network.zig").Network = undefined,
    bluetooth: @import("../../services/bluetooth.zig").Bluetooth = undefined,
    session_services: @import("../../services/session.zig").Session = undefined,
    services_started: bool = false,
    preferences: @import("../../config/service.zig").Service = undefined,
    osd_label: ?*gtk.Label = null,
    osd_pending: @import("../../services/policy.zig").Text(512) = .{},
    osd_flush: c_uint = 0,
    index: Apps.Index = undefined,
    layout: ?Layout = null,
    layout_stamp: u64 = 0,
    clock_source: c_uint = 0,
    error_pending: bool = false,
    osd: ?*Surface = null,
    notification: ?*Surface = null,
    osd_source: c_uint = 0,
    sync_source: c_uint = 0,
    monitor_signal: c_ulong = 0,
    monitor_watches: std.ArrayList(struct { monitor: *gdk.Monitor, signal: c_ulong }) = .empty,
    running: bool = false,
    context: ?*anyopaque = null,
    changed: ?*const fn (*anyopaque) void = null,
    pub fn init(app: *gtk.Application, display: *gdk.Display, client: *adapter.Client) Manager {
        return .{ .app = app, .display = display, .client = client };
    }
    pub fn start(self: *Manager) !void {
        if (layer.isSupported() == 0) return error.LayerShellUnavailable;
        self.index = .{ .app = self.app.as(gio.Application), .context = self, .changed = appsChanged };
        self.effects = try native.Effects.init(self.display);
        self.running = true;
        self.effects.context = self;
        self.effects.changed = nativeChanged;
        self.effects.start();
        self.layout = try Layout.init(self.display, self, layoutChanged);
        self.layout.?.start();
        self.index.start();
        self.audio = .{ .context = self, .changed = audioChanged };
        self.power = .{ .app = self.app.as(gio.Application), .context = self, .changed = powerChanged };
        if (@import("build_options").test_hooks) if (glib.getenv("PEARL_TEST_BACKLIGHT")) |root| self.power.backlight_root.set(std.mem.span(root));
        self.network = .{ .app = self.app.as(gio.Application), .context = self, .changed = connectivityChanged };
        self.bluetooth = .{ .app = self.app.as(gio.Application), .context = self, .changed = connectivityChanged };
        self.session_services = .{ .app = self.app.as(gio.Application), .context = self, .changed = sessionChanged };
        self.preferences = .{ .app = self.app.as(gio.Application), .display = self.display, .context = self, .changed = preferencesChanged, .validate = validatePreferences };
        try self.preferences.start();
        self.services_started = true;
        self.audio.start();
        self.power.start();
        self.network.start();
        self.bluetooth.start();
        self.session_services.start();
        self.armClock();
        gtk.IconTheme.getForDisplay(self.display).addResourcePath("/org/aqueous/Pearl/icons");
        self.monitor_signal = gio.ListModel.signals.items_changed.connect(self.display.getMonitors(), *Manager, monitorsChanged, self, .{});
        self.watchMonitors();
        self.schedule();
    }
    pub fn deinit(self: *Manager) void {
        if (!self.running) return;
        self.running = false;
        if (self.clock_source != 0) _ = glib.Source.remove(self.clock_source);
        self.clock_source = 0;
        self.index.stop();
        if (self.sync_source != 0) _ = glib.Source.remove(self.sync_source);
        self.sync_source = 0;
        if (self.monitor_signal != 0) object.signalHandlerDisconnect(self.display.getMonitors().as(object.Object), self.monitor_signal);
        self.unwatchMonitors();
        self.monitor_watches.deinit(a);
        self.clear();
        if (self.services_started) {
            self.preferences.stop();
            self.audio.stop();
            self.power.stop();
            self.network.stop();
            self.bluetooth.stop();
            self.session_services.stop();
            self.services_started = false;
        }
        if (self.osd_flush != 0) _ = glib.Source.remove(self.osd_flush);
        self.osd_flush = 0;
        self.outputs.deinit(a);
        self.effects.deinit();
        if (self.layout) |*layout| layout.deinit();
        self.layout = null;
    }
    pub fn schedule(self: *Manager) void {
        if (self.running and self.sync_source == 0) self.sync_source = glib.idleAdd(syncIdle, self);
    }
    pub fn clear(self: *Manager) void {
        self.hidePopup();
        self.hideOsd();
        self.hideNotifications();
        for (self.outputs.items) |o| o.destroy();
        self.outputs.clearRetainingCapacity();
    }
    fn validatePreferences(context: *anyopaque, prefs: @import("../../config/preferences.zig").Preferences) !void {
        const self: *Manager = @ptrCast(@alignCast(context));
        for (self.outputs.items) |output| {
            var reservations = output.reservations;
            const bar = prefs.forOutput(output.connector);
            try reservations.bar(bar.edge, bar.size);
        }
    }
    fn preferencesChanged(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        if (!self.running) return;
        for (self.outputs.items) |o| {
            if (o.wallpaper) |surface| self.styleSurface(surface);
            if (o.bar) |surface| self.styleSurface(surface);
        }
        for ([_]?*Surface{ self.popup, self.osd, self.notification }) |maybe| if (maybe) |surface| self.styleSurface(surface);
        if (self.popup) |surface| if (surface.settings) |view| view.update();
        self.positionPopup();
        self.schedule();
    }
    fn styleSurface(self: *Manager, surface: *Surface) void {
        if (surface.appearance_revision == self.preferences.appearance) return;
        surface.appearance_revision = self.preferences.appearance;
        self.preferences.style(surface.window.as(gtk.Widget), surface.panel);
        if (surface.kind == .wallpaper or surface.kind == .frame) surface.panel.removeCssClass("background");
        if (surface.wallpaper_picture) |picture| {
            const prefs = self.preferences.prefs();
            const image = if (self.preferences.live) |live| live.texture else null;
            if (image != null and (prefs.wallpaper.mode == .cover or prefs.wallpaper.mode == .contain)) {
                picture.setPaintable(image.?.as(gdk.Paintable));
                picture.setContentFit(if (prefs.wallpaper.mode == .cover) .cover else .contain);
            } else picture.setPaintable(null);
        }
    }
    fn sessionChanged(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        self.servicesChanged();
    }
    fn servicesChanged(self: *Manager) void {
        if (!self.running) return;
        // Reconcile UI only in an idle callback, outside service signal stacks.
        self.schedule();
    }
    fn connectivityChanged(context: *anyopaque, _: @import("../../services/audio.zig").Event) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        self.servicesChanged();
    }
    fn audioChanged(context: *anyopaque, event: @import("../../services/audio.zig").Event) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        self.servicesChanged();
        if (event == .failure and self.audio.err != null) self.queueOsd(self.audio.err.?) else if (event == .applied) {
            if (self.audio.feedback) |key| if (self.audio.find(key)) |d| {
                var buffer: [512]u8 = undefined;
                self.queueOsd(std.fmt.bufPrint(&buffer, "{s} · {d}%{s}", .{ d.label.slice(), d.volume, if (d.mute) " · Muted" else "" }) catch "Audio updated");
            };
        }
    }
    fn powerChanged(context: *anyopaque, event: @import("../../services/power.zig").Event) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        self.servicesChanged();
        if (event == .failure and self.power.err != null) self.queueOsd(self.power.err.?) else if (event == .applied) {
            var buffer: [128]u8 = undefined;
            self.queueOsd(if (self.power.feedback != null) std.fmt.bufPrint(&buffer, "Brightness · {d}%", .{self.power.backlight.percent()}) catch "Brightness updated" else "Power service accepted the change");
        }
    }
    fn queueOsd(self: *Manager, text: []const u8) void {
        if (!self.running) return;
        self.osd_pending.set(text);
        if (self.osd_flush == 0) self.osd_flush = glib.timeoutAdd(80, flushOsd, self);
    }
    fn flushOsd(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Manager = @ptrCast(@alignCast(data.?));
        self.osd_flush = 0;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        _ = self.control(.{ .op = .osd_show, .text = self.osd_pending.slice(), .duration_ms = 1800 }, arena.allocator()) catch "";
        return 0;
    }
    fn appsChanged(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        if (self.running) if (self.popup) |p| if (p.launcher) |launcher| launcher.refresh();
    }
    fn armClock(self: *Manager) void {
        const now = glib.DateTime.newNowLocal() orelse return;
        defer now.unref();
        const ms: c_uint = @intCast((60 - now.getSecond()) * 1000);
        self.clock_source = glib.timeoutAdd(ms, clockTick, self);
    }
    fn clockTick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Manager = @ptrCast(@alignCast(data.?));
        self.clock_source = 0;
        for (self.outputs.items) |o| if (o.bar) |s| if (s.bar) |bar| bar.tick();
        if (self.running) self.armClock();
        return 0;
    }
    fn layoutChanged(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        if (!self.running) return;
        if (self.popup) |popup| if (popup.control) |panel| panel.update();
    }
    fn nativeChanged(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        self.schedule();
        if (self.changed) |notify| notify(self.context.?);
    }
    fn unwatchMonitors(self: *Manager) void {
        for (self.monitor_watches.items) |watch| {
            if (object.signalHandlerIsConnected(watch.monitor.as(object.Object), watch.signal) != 0) object.signalHandlerDisconnect(watch.monitor.as(object.Object), watch.signal);
            watch.monitor.unref();
        }
        self.monitor_watches.clearRetainingCapacity();
    }
    fn watchMonitors(self: *Manager) void {
        self.unwatchMonitors();
        const monitors = self.display.getMonitors();
        for (0..@min(monitors.getNItems(), 64)) |i| {
            const monitor: *gdk.Monitor = @ptrCast(@alignCast(monitors.getItem(@intCast(i)) orelse continue));
            const signal = object.Object.signals.notify.connect(monitor.as(object.Object), *Manager, monitorChanged, self, .{});
            self.monitor_watches.append(a, .{ .monitor = monitor, .signal = signal }) catch {
                object.signalHandlerDisconnect(monitor.as(object.Object), signal);
                monitor.unref();
            };
        }
    }
    fn monitorChanged(_: *object.Object, _: *object.ParamSpec, self: *Manager) callconv(.c) void {
        self.schedule();
    }
    fn monitorsChanged(_: *gio.ListModel, _: c_uint, _: c_uint, _: c_uint, self: *Manager) callconv(.c) void {
        self.watchMonitors();
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
            self.session_services.notifications.setLocked(true);
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
            if (o.preferences_revision != self.preferences.appearance) {
                const pref = self.preferences.prefs().forOutput(o.connector);
                try o.reservations.bar(pref.edge, pref.size);
                o.bar.?.edge = pref.edge;
                sizeEdge(o.bar.?, pref.edge, pref.size);
                try o.bar.?.bar.?.configure(pref.groups);
                o.preferences_revision = self.preferences.appearance;
            }
            const changed = !std.meta.eql(o.bounds, bounds) or !std.meta.eql(o.usable, usable);
            o.bounds = bounds;
            o.usable = usable;
            o.scale = record.scale;
            if (o.bar) |s| if (s.bar) |bar| {
                const vertical = s.edge == .left or s.edge == .right;
                bar.geometry(vertical, if (vertical) bounds.height else bounds.width);
                bar.update();
            };
            if (changed and self.popup != null and self.popup.?.output == o) self.positionPopup();
        }
        var i: usize = 0;
        while (i < self.outputs.items.len) {
            const o = self.outputs.items[i];
            if (!o.seen) {
                if (self.popup != null and self.popup.?.output == o) self.hidePopup();
                if (self.osd != null and self.osd.?.output == o) self.hideOsd();
                if (self.notification != null and self.notification.?.output == o) self.hideNotifications();
                _ = self.outputs.orderedRemove(i);
                o.destroy();
            } else i += 1;
        }
        if (self.popup) |popup| {
            if (popup.launcher) |launcher| launcher.refresh();
            if (popup.control) |panel| panel.update();
            if (popup.notifications) |view| view.update();
            if (popup.media) |view| view.update();
            if (popup.tray) |view| view.update();
            if (popup.control != null and self.layout_stamp != self.workspaceStamp(popup.output)) {
                self.layout.?.cancel();
                self.queryLayout(popup.output, null) catch {};
            }
        }
        if (self.error_pending) {
            self.error_pending = false;
            if (self.popup) |popup| {
                if (popup.launcher) |launcher| launcher.message.setText(tr("The desktop action could not be confirmed.", "Die Desktop-Aktion konnte nicht bestätigt werden."));
            }
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            _ = self.control(.{ .op = .osd_show, .text = tr("The desktop action could not be completed.", "Die Desktop-Aktion konnte nicht abgeschlossen werden."), .duration_ms = 3000 }, arena.allocator()) catch "";
        }
        self.session_services.notifications.setLocked(self.client.model.get(.session, "session").?.locked);
        try self.syncNotifications();
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
            .notification => "pearl:notification",
            .frame => "pearl:frame-exclusion",
        });
        layer.setLayer(window, switch (kind) {
            .wallpaper => .background,
            .bar, .frame => .top,
            .popup, .osd, .notification => .overlay,
        });
        layer.setExclusiveZone(window, 0);
        layer.setKeyboardMode(window, if (kind == .popup) .exclusive else .none);
        const panel = gtk.Box.new(.vertical, 12);
        const panel_widget = panel.as(gtk.Widget);
        _ = panel_widget.ref();
        errdefer panel_widget.unref();
        if (kind != .wallpaper and kind != .frame) panel_widget.addCssClass("pearl-surface-panel");
        s.* = .{ .manager = self, .output = output, .kind = kind, .window = window, .panel = panel_widget };
        errdefer {
            if (s.bar) |bar| bar.destroy();
            if (s.launcher) |launcher| launcher.destroy();
            if (s.control) |panel_control| panel_control.destroy();
            if (s.notifications) |view| view.destroy();
            if (s.media) |view| view.destroy();
            if (s.tray) |view| view.destroy();
            if (s.settings) |view| view.destroy();
        }
        switch (kind) {
            .wallpaper => {
                window.as(gtk.Widget).addCssClass("pearl-wallpaper");
                anchors(window, null);
                layer.setExclusiveZone(window, -1);
                const picture = gtk.Picture.new();
                picture.setCanShrink(1);
                picture.as(gtk.Widget).setHexpand(1);
                picture.as(gtk.Widget).setVexpand(1);
                panel.append(picture.as(gtk.Widget));
                s.wallpaper_picture = picture;
                window.setChild(panel_widget);
            },
            .bar => {
                panel_widget.addCssClass("pearl-bar-panel");
                inline for ([_]fn (*gtk.Widget, c_int) callconv(.c) void{ gtk.Widget.setMarginStart, gtk.Widget.setMarginEnd, gtk.Widget.setMarginTop, gtk.Widget.setMarginBottom }) |set| set(panel_widget, 4);
                s.bar = try Bar.Bar.create(panel, self.client, output.id, s, barAction, &self.audio, &self.power, &self.network, &self.bluetooth, &self.session_services);
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
                switch (self.pane) {
                    .settings => s.settings = try @import("../../desktop/settings.zig").View.create(panel, &self.preferences),
                    .launcher => s.launcher = try Launcher.create(panel, self.app.as(gio.Application), self.display, &self.index, self.client, self, dismiss),
                    .calendar => Panels.calendar(panel),
                    .notifications => s.notifications = try @import("../../desktop/notifications.zig").View.create(panel, &self.session_services.notifications, false),
                    .media => {
                        const scroll = gtk.ScrolledWindow.new();
                        scroll.setPolicy(.never, .automatic);
                        scroll.as(gtk.Widget).setVexpand(1);
                        const content = gtk.Box.new(.vertical, 12);
                        scroll.setChild(content.as(gtk.Widget));
                        panel.append(scroll.as(gtk.Widget));
                        s.media = try @import("../../desktop/media.zig").View.create(content, &self.session_services.media);
                    },
                    .tray => s.tray = try @import("../../desktop/tray.zig").View.create(panel, &self.session_services.tray),
                    .control => {
                        s.control = try Panels.Control.create(panel, &self.layout.?, s, layoutAction, &self.audio, &self.power, &self.network, &self.bluetooth, &self.session_services.media);
                        const overview = gtk.Button.newWithLabel(tr("Window overview", "Fensterübersicht"));
                        _ = gtk.Button.signals.clicked.connect(overview, *Surface, overviewClicked, s, .{});
                        panel.append(overview.as(gtk.Widget));
                        const settings = gtk.Button.newWithLabel("Pearl settings");
                        _ = gtk.Button.signals.clicked.connect(settings, *Surface, settingsClicked, s, .{});
                        panel.append(settings.as(gtk.Widget));
                    },
                }
                const keys = gtk.EventControllerKey.new();
                keys.as(gtk.EventController).setPropagationPhase(.capture);
                _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Manager, keyPressed, self, .{});
                window.as(gtk.Widget).addController(keys.as(gtk.EventController));
                const click = gtk.GestureClick.new();
                click.as(gtk.EventController).setPropagationPhase(.capture);
                _ = gtk.GestureClick.signals.released.connect(click, *Manager, outsideReleased, self, .{});
                window.as(gtk.Widget).addController(click.as(gtk.EventController));
            },
            .notification => {
                layer.setAnchor(window, .top, 1);
                layer.setAnchor(window, .right, 1);
                layer.setMargin(window, .top, 16);
                layer.setMargin(window, .right, 16);
                window.setDefaultSize(@min(400, output.bounds.width - 32), -1);
                window.setChild(panel_widget);
                s.notifications = try @import("../../desktop/notifications.zig").View.create(panel, &self.session_services.notifications, true);
            },
            .osd => {
                layer.setAnchor(window, .bottom, 1);
                layer.setMargin(window, .bottom, 24);
                panel_widget.addCssClass("pearl-osd-panel");
                window.setDefaultSize(320, 72);
                window.setChild(panel_widget);
            },
        }
        self.styleSurface(s);
        try s.effects.init(&self.effects, window, panel_widget, kind == .bar or kind == .popup or kind == .osd or kind == .notification, if (kind == .popup) .full else if (kind == .bar or kind == .notification) .panel else .empty);
        if (kind != .popup and kind != .osd and kind != .frame and kind != .notification) window.present();
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
        return self.showPane(output, .launcher);
    }
    pub fn showPane(self: *Manager, output: *Output, pane: Bar.Pane) !void {
        if (self.client.model.get(.session, "session").?.locked) return error.Locked;
        self.hidePopup();
        self.pane = pane;
        self.popup = try self.create(output, .popup);
        self.positionPopup();
        self.popup.?.window.present();
        if (@import("build_options").test_hooks and pane != .launcher and pane != .calendar) {
            const surface = self.popup.?;
            if (surface.window.as(gtk.Widget).getFrameClock()) |clock| {
                _ = clock.ref();
                surface.measure_clock = clock;
                surface.measure_signal = gdk.FrameClock.signals.after_paint.connect(clock, *Surface, serviceProbe, surface, .{});
            }
        }
        if (self.popup.?.launcher) |launcher| {
            if (self.popup.?.window.as(gtk.Widget).getFrameClock()) |clock| launcher.observeFrame(clock);
            _ = launcher.search.as(gtk.Widget).grabFocus();
        }
        if (pane == .control) self.queryLayout(output, null) catch {};
        std.log.info("event=popup-opened output={s}", .{output.id});
    }
    fn positionPopup(self: *Manager) void {
        const s = self.popup orelse return;
        const o = s.output;
        const prefs = self.preferences.prefs().popup;
        var rect = if (self.pane == .launcher) policy.popup(o.bounds, o.usable, 620, 600) else policy.anchored(o.bounds, o.usable, if (self.pane == .settings) 700 else if (self.pane == .control) 600 else 440, if (self.pane == .settings) 720 else if (self.pane == .calendar) 480 else 560, o.reservations.bar_edge, self.pane != .calendar);
        const width = @min(rect.width, prefs.max_width);
        const height = @min(rect.height, prefs.max_height);
        rect = if (prefs.placement == .centered or self.pane == .launcher) policy.popup(o.bounds, o.usable, width, height) else policy.anchored(o.bounds, o.usable, width, height, o.reservations.bar_edge, self.pane != .calendar);
        self.popup_rect = rect;
        const fixed = object.ext.cast(gtk.Fixed, s.window.getChild().?).?;
        fixed.move(s.panel, @floatFromInt(rect.x - (o.usable.x - o.bounds.x)), @floatFromInt(rect.y - (o.usable.y - o.bounds.y)));
        s.panel.setSizeRequest(rect.width, rect.height);
        self.positionNotifications();
    }
    pub fn hidePopup(self: *Manager) void {
        if (self.popup) |s| {
            self.popup = null;
            self.popup_rect = null;
            if (self.layout) |*layout| layout.cancel();
            s.destroy();
            self.positionNotifications();
            std.log.info("event=popup-closed", .{});
        }
    }
    fn positionNotifications(self: *Manager) void {
        const s = self.notification orelse return;
        const left = self.popup != null;
        layer.setAnchor(s.window, .right, @intFromBool(!left));
        layer.setAnchor(s.window, .left, @intFromBool(left));
        layer.setMargin(s.window, .right, if (left) 0 else 16);
        layer.setMargin(s.window, .left, if (left) 16 else 0);
    }
    fn hideNotifications(self: *Manager) void {
        if (self.notification) |s| {
            self.notification = null;
            s.destroy();
        }
    }
    fn syncNotifications(self: *Manager) !void {
        const model = &self.session_services.notifications.model;
        var count: usize = 0;
        if (!model.locked and !model.dnd) for (&model.records) |*r| {
            if (r.toast_until > glib.getMonotonicTime()) count += 1;
        };
        if (count == 0) {
            self.hideNotifications();
            return;
        }
        if (self.notification == null) {
            const output = self.selected(null) catch return;
            self.notification = try self.create(output, .notification);
            self.notification.?.window.present();
        }
        self.notification.?.notifications.?.display_limit = @intCast(@min(3, @max(1, @divTrunc(self.notification.?.output.usable.height - 32, 210))));
        self.positionNotifications();
        self.notification.?.notifications.?.update();
    }
    fn hideOsd(self: *Manager) void {
        if (self.osd_source != 0) _ = glib.Source.remove(self.osd_source);
        self.osd_source = 0;
        self.osd_label = null;
        if (self.osd) |s| {
            self.osd = null;
            s.destroy();
        }
    }
    fn workspaceStamp(self: *Manager, output: *Output) u64 {
        var hash = std.hash.Wyhash.init(0);
        hash.update(output.id);
        if (self.client.model.get(.output, output.id)) |record| if (record.active_workspace) |workspace| hash.update(workspace);
        return hash.final();
    }
    fn queryLayout(self: *Manager, output: *Output, value: ?[]const u8) !void {
        if (self.client.availability != .ready) return error.Unavailable;
        if (self.client.model.get(.session, "session").?.locked) return error.Locked;
        self.layout_stamp = self.workspaceStamp(output);
        try self.layout.?.request(output.connector, value);
    }
    fn enqueueAction(self: *Manager, action: adapter.Action) void {
        _ = self.client.enqueue(action) catch {
            self.error_pending = true;
            self.schedule();
            return;
        };
    }
    pub fn completion(self: *Manager, result: adapter.Completion) void {
        if (result.status == .rejected or result.status == .unknown or result.status == .dropped) {
            self.error_pending = true;
            self.schedule();
            std.log.info("event=desktop-action status={s} detail={s}", .{ @tagName(result.status), result.detail });
        }
    }
    pub fn control(self: *Manager, request: protocol.Request, alloc: std.mem.Allocator) ![]const u8 {
        if (request.op == .session_status) {
            self.session_services.notifications.setLocked(self.client.availability != .ready or (if (self.client.model.get(.session, "session")) |session| session.locked else true));
            return self.session_services.status(alloc, request.offset orelse 0);
        }
        if (request.op == .preferences_status) return self.preferences.status(alloc);
        if (request.op == .status) return self.status(alloc);
        if (request.op == .connectivity_status) return @import("../../services/connectivity_status.zig").encode(alloc, &self.network, &self.bluetooth, request.offset orelse 0);
        if (request.op == .services_status) return std.json.Stringify.valueAlloc(alloc, try self.serviceStatus(alloc, request.offset orelse 0), .{});
        if (self.client.availability != .ready) return error.Unavailable;
        if (request.op != .quit and self.client.model.get(.session, "session").?.locked) return error.Locked;
        switch (request.op) {
            .preferences_status, .status, .services_status, .connectivity_status, .session_status => unreachable,
            .preferences_apply => {
                try self.preferences.apply(request.text.?, request.revision.?);
                return "{\"queued\":true}";
            },
            .preferences_reload => {
                self.preferences.reload();
                return "{\"queued\":true}";
            },
            .settings_show => try self.showPane(try self.selected(request.output), .settings),
            .session_action => {
                try self.session_services.act(request);
                return "{\"queued\":true}";
            },
            .notifications_toggle, .media_toggle, .tray_toggle => {
                const pane: Bar.Pane = switch (request.op) {
                    .notifications_toggle => .notifications,
                    .media_toggle => .media,
                    else => .tray,
                };
                const output = try self.selected(request.output);
                if (self.popup != null and self.popup.?.output == output and self.pane == pane) self.hidePopup() else try self.showPane(output, pane);
            },
            .connectivity_action => {
                if (request.service.? == .network) {
                    if (request.generation.? != self.network.peer.epoch) return error.Unavailable;
                    switch (request.action.?) {
                        .scan => try self.network.scan(request.generation.?, request.path.?),
                        .connect => try self.network.connectAP(request.generation.?, request.path.?),
                        .connect_saved => try self.network.connectSaved(request.generation.?, request.path.?),
                        .disconnect => try self.network.disconnect(request.generation.?, request.path.?),
                        .enable, .disable => try self.network.setEnabled(request.action.? == .enable),
                        .cancel => self.network.cancelOperation(),
                        else => return error.InvalidRequest,
                    }
                } else {
                    if (request.generation.? != self.bluetooth.peer.epoch) return error.Unavailable;
                    switch (request.action.?) {
                        .discover => try self.bluetooth.discover(request.generation.?, request.path.?),
                        .stop_discovery => self.bluetooth.stopDiscovery(),
                        .cancel => self.bluetooth.cancelOperation(),
                        else => try self.bluetooth.request(request.generation.?, request.path.?, switch (request.action.?) {
                            .pair => .pair,
                            .connect => .connect,
                            .disconnect => .disconnect,
                            .trust => .trust,
                            .untrust => .untrust,
                            .enable => .power_on,
                            .disable => .power_off,
                            else => return error.InvalidRequest,
                        }),
                    }
                }
                return "{\"queued\":true}";
            },
            .audio_set => {
                const device = if (request.device) |id| self.audio.find(.{ .generation = request.generation.?, .kind = request.kind.?, .index = id }) else self.audio.default(request.kind.?);
                try self.audio.request(.{ .key = (device orelse return error.Unavailable).key, .volume = request.volume, .mute = request.mute, .default = request.make_default orelse false, .move = request.target });
                return "{\"queued\":true}";
            },
            .brightness_set => {
                try self.power.setBrightness(request.percent.?);
                return "{\"queued\":true}";
            },
            .profile_set => {
                try self.power.setProfile(request.profile.?);
                return "{\"queued\":true}";
            },
            .quit => {},
            .launcher_hide => if (self.pane == .launcher) {
                self.hidePopup();
            },
            .launcher_show, .launcher_toggle, .control_show, .control_toggle, .calendar_toggle => {
                const output = try self.selected(request.output);
                const pane: Bar.Pane = switch (request.op) {
                    .control_show, .control_toggle => .control,
                    .calendar_toggle => .calendar,
                    else => .launcher,
                };
                const toggle = request.op == .launcher_toggle or request.op == .control_toggle or request.op == .calendar_toggle;
                if (toggle and self.popup != null and self.popup.?.output == output and self.pane == pane) self.hidePopup() else try self.showPane(output, pane);
            },
            .bar_groups => {
                const output = try self.selected(request.output);
                try output.bar.?.bar.?.configure(.{ .left = request.left.?, .center = request.center.?, .right = request.right.? });
            },
            .layout_get, .layout_set => {
                try self.queryLayout(try self.selected(request.output), request.layout);
                return "{\"queued\":true}";
            },
            .overview_toggle => {
                const output = try self.selected(request.output);
                _ = try self.client.enqueue(.{ .overview_toggle = .{ .output = output.id } });
                self.hidePopup();
                return "{\"queued\":true}";
            },
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
                if (self.osd_flush != 0) _ = glib.Source.remove(self.osd_flush);
                self.osd_flush = 0;
                const o = try self.selected(request.output);
                if (self.osd != null and self.osd.?.output != o) self.hideOsd();
                const s = self.osd orelse try self.create(o, .osd);
                self.osd = s;
                const text = try alloc.dupeZ(u8, request.text.?);
                const label = self.osd_label orelse gtk.Label.new(text);
                label.setText(text);
                label.setWrap(1);
                label.setWrapMode(.word_char);
                label.setMaxWidthChars(40);
                if (self.osd_label == null) object.ext.cast(gtk.Box, s.panel).?.append(label.as(gtk.Widget));
                self.osd_label = label;
                s.window.present();
                if (self.osd_source != 0) _ = glib.Source.remove(self.osd_source);
                self.osd_source = glib.timeoutAdd(request.duration_ms orelse 2000, osdExpired, self);
            },
        }
        return "{\"applied\":true}";
    }
    const ServiceStatus = struct {
        audio: struct { ready: bool, generation: u64, count: usize, truncated: bool, pending: bool, in_flight: bool, err: ?[]const u8, default_sink: ?u32, default_source: ?u32, devices: []const DeviceStatus, next_offset: ?usize },
        power: struct { battery_present: bool, percentage: f64, state: u32, on_battery: bool, time_to_empty: i64, time_to_full: i64, profile: []const u8, profiles: [3]bool, degraded: []const u8, can_power_off: bool, can_reboot: bool, session_active: bool, preparing: bool, pending: bool, profile_in_flight: bool, err: ?[]const u8 },
        brightness: struct { available: bool, device: []const u8, maximum: u32, value: u32, percent: u8, pending: bool, in_flight: bool },
    };
    const DeviceStatus = struct { kind: @import("../../services/audio.zig").Kind, index: u32, name: []const u8, label: []const u8, volume: u8, mute: bool, target: u32, writable: bool };
    fn serviceStatus(self: *Manager, alloc: std.mem.Allocator, offset: ?u16) !ServiceStatus {
        var devices: std.ArrayList(DeviceStatus) = .empty;
        const first: usize = @min(offset orelse self.audio.count, self.audio.count);
        const end = @min(first + 4, self.audio.count);
        for (self.audio.devices[first..end]) |*d| try devices.append(alloc, .{ .kind = d.key.kind, .index = d.key.index, .name = textPreview(d.name.slice(), 64), .label = textPreview(d.label.slice(), 96), .volume = d.volume, .mute = d.mute, .target = d.target, .writable = d.writable });
        const power = &self.power;
        return .{
            .audio = .{ .ready = self.audio.ready, .generation = self.audio.generation, .count = self.audio.count, .truncated = self.audio.truncated, .pending = self.audio.active != null or self.audio.queue.len > 0 or self.audio.feedback != null, .in_flight = self.audio.active != null, .err = self.audio.err, .default_sink = if (self.audio.default(.sink)) |d| d.key.index else null, .default_source = if (self.audio.default(.source)) |d| d.key.index else null, .devices = devices.items, .next_offset = if (end < self.audio.count) end else null },
            .power = .{ .battery_present = power.battery_present, .percentage = power.percentage, .state = power.battery_state, .on_battery = power.on_battery, .time_to_empty = power.time_to_empty, .time_to_full = power.time_to_full, .profile = power.profile.slice(), .profiles = power.profiles, .degraded = power.degraded.slice(), .can_power_off = power.can_off, .can_reboot = power.can_reboot, .session_active = power.session_active, .preparing = power.preparing, .pending = power.profile_pending or power.profile_wanted != null or power.action_pending, .profile_in_flight = power.profile_pending, .err = power.err },
            .brightness = .{ .available = power.brightnessAvailable(), .device = power.backlight.name.slice(), .maximum = power.backlight.maximum, .value = power.backlight.value, .percent = power.backlight.percent(), .pending = power.brightness_pending or power.brightness_wanted != null, .in_flight = power.brightness_pending },
        };
    }
    fn textPreview(value: []const u8, maximum: usize) []const u8 {
        var end = @min(value.len, maximum);
        while (end > 0 and !std.unicode.utf8ValidateSlice(value[0..end])) end -= 1;
        return value[0..end];
    }
    fn status(self: *Manager, alloc: std.mem.Allocator) ![]const u8 {
        const Item = struct { keyboard: []const u8, title: []const u8, groups: Groups, id: []const u8, connector: []const u8, scale: f64, bounds: Rect, usable: Rect, bar_edge: Edge, bar_size: u16, frames: [4]u16 };
        var items: std.ArrayList(Item) = .empty;
        for (self.outputs.items) |o| try items.append(alloc, .{ .keyboard = if (o.bar.?.bar.?.keyboard) |label| std.mem.span(label.getText()) else "", .title = if (o.bar.?.bar.?.title) |label| titlePreview(std.mem.span(label.getText())) else "", .groups = .{ .left = o.bar.?.bar.?.groups[0], .center = o.bar.?.bar.?.groups[1], .right = o.bar.?.bar.?.groups[2] }, .id = o.id, .connector = o.connector, .scale = o.scale, .bounds = o.bounds, .usable = o.usable, .bar_edge = o.reservations.bar_edge, .bar_size = o.reservations.bar_size, .frames = o.reservations.frames });
        return std.json.Stringify.valueAlloc(alloc, .{ .services = try self.serviceStatus(alloc, null), .apps = .{ .ready = self.index.catalog != null, .truncated = if (self.index.catalog) |c| c.truncated else false, .count = if (self.index.catalog) |c| c.entries.items.len else 0, .generation = self.index.generation }, .layout = .{ .available = self.layout.?.global != null, .pending = self.layout.?.manager != null, .output = self.layout.?.output[0..self.layout.?.output_len], .value = self.layout.?.value[0..self.layout.?.value_len], .workspace = self.layout.?.workspace, .err = self.layout.?.err }, .session = self.client.model.session, .availability = self.client.availability, .blur = self.effects.available, .outputs = items.items, .popup = if (self.popup) |s| @as(?struct { output: []const u8, rect: Rect, pane: Bar.Pane, results: usize, latency_us: i64 }, .{ .output = s.output.id, .rect = self.popup_rect.?, .pane = self.pane, .results = if (s.launcher) |l| l.count else 0, .latency_us = if (s.launcher) |l| l.latency_us else 0 }) else null, .notification = self.notification != null, .media_views = self.session_services.media.viewers, .artwork = self.session_services.media.art.image != null, .artwork_pending = self.session_services.media.art.job != null, .osd = self.osd != null, .osd_text = if (self.osd_label) |label| std.mem.span(label.getText()) else "" }, .{});
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
fn serviceProbe(_: *gdk.FrameClock, s: *Surface) callconv(.c) void {
    if (s.settings) |view| view.probe(s.window);
    if (s.notifications) |view| view.probe(s.window);
    if (s.media) |view| view.probe(s.window);
    if (s.tray) |view| view.probe(s.window);
    if (s.control) |panel| {
        panel.media.probe(s.window);
        panel.services.probe(s.window);
        panel.connectivity.probe(s.window);
    }
}
fn measured(_: *gdk.FrameClock, s: *Surface) callconv(.c) void {
    if (s.bar) |bar| bar.painted();
    const horizontal = s.edge == .top or s.edge == .bottom;
    const size = if (horizontal) s.window.as(gtk.Widget).getHeight() else s.window.as(gtk.Widget).getWidth();
    if (size > 0 and size <= 65535 and layer.getExclusiveZone(s.window) != size) {
        layer.setExclusiveZone(s.window, size);
        s.output.reservations.bar_size = @intCast(size);
    }
}
fn barAction(context: *anyopaque, event: Bar.Event) void {
    const s: *Surface = @ptrCast(@alignCast(context));
    const self = s.manager;
    switch (event) {
        .pane => |pane| {
            if (pane == .tray and self.popup != null and self.popup.?.output == s.output and self.pane == .tray) {
                self.popup.?.tray.?.update();
                return;
            }
            if (self.popup != null and self.popup.?.output == s.output and self.pane == pane) self.hidePopup() else self.showPane(s.output, pane) catch {};
        },
        .workspace => |id| {
            self.enqueueAction(.{ .workspace_activate = .{ .id = id } });
        },
        .keyboard => {
            self.enqueueAction(.{ .keyboard_next = .{} });
        },
        .overview => {
            self.enqueueAction(.{ .overview_toggle = .{ .output = s.output.id } });
            self.hidePopup();
        },
    }
}
fn dismiss(context: *anyopaque) void {
    const self: *Manager = @ptrCast(@alignCast(context));
    self.hidePopup();
}
fn layoutAction(context: *anyopaque, value: ?[]const u8) void {
    const s: *Surface = @ptrCast(@alignCast(context));
    s.manager.queryLayout(s.output, value) catch {
        s.control.?.label.setText(tr("Layout change unavailable", "Anordnung kann nicht geändert werden"));
    };
}
fn settingsClicked(_: *gtk.Button, s: *Surface) callconv(.c) void {
    barAction(s, .{ .pane = .settings });
}
fn overviewClicked(_: *gtk.Button, s: *Surface) callconv(.c) void {
    barAction(s, .overview);
}
fn keyPressed(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, _: gdk.ModifierType, self: *Manager) callconv(.c) c_int {
    if (key != 0xff1b) return 0;
    self.hidePopup();
    return 1;
}
fn outsideReleased(_: *gtk.GestureClick, _: c_int, x: f64, y: f64, self: *Manager) callconv(.c) void {
    if (!self.preferences.prefs().popup.dismiss_outside) return;
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

fn titlePreview(text: []const u8) []const u8 {
    var n = @min(text.len, 128);
    while (n > 0 and n < text.len and text[n] & 0xc0 == 0x80) n -= 1;
    return text[0..n];
}
