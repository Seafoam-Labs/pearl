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
const BarVisibility = @import("../../desktop/bar_visibility.zig");
const BarAutohide = @import("../../desktop/bar_autohide.zig").Controller;
const Osd = @import("osd.zig");
const Apps = @import("../../desktop/apps.zig");
const Running = @import("../../desktop/running_apps.zig");
const LauncherPicker = @import("../../desktop/launcher_picker.zig");
const Launcher = @import("../../desktop/launcher.zig").Launcher;
const Panels = @import("../../desktop/panels.zig");
const navigation = @import("../../desktop/settings_navigation.zig");
const Owner = @import("../../services/view_ownership.zig").Owner;
const Layout = @import("../../platform/wayland/layout.zig").Layout;
const Groups = @import("../../desktop/policy.zig").Groups;
const slideshow_policy = @import("../../config/slideshow_policy.zig");
const tr = @import("../../desktop/text.zig").tr;
const a = std.heap.c_allocator;
const Rect = policy.Rect;
const Edge = policy.Edge;
const Switcher = @import("../../desktop/window_switcher.zig");
const Kind = enum { switcher, wallpaper, bar, popup, osd, frame, notification };
const Surface = struct {
    manager: *Manager,
    output: *Output,
    kind: Kind,
    window: *gtk.Window,
    panel: *gtk.Widget,
    viewport: ?*gtk.ScrolledWindow = null,
    effects: native.Surface = undefined,
    edge: Edge = .top,
    switcher_label: ?*gtk.Label = null,
    switcher_location: ?*gtk.Label = null,
    switcher_controls: ?*gtk.Widget = null,
    switcher_spoken: ?[:0]u8 = null,
    bar: ?*Bar.Bar = null,
    autohide: ?*BarAutohide = null,
    launcher: ?*Launcher = null,
    launcher_picker: ?*LauncherPicker.View = null,
    running_apps: ?*Running.Chooser = null,
    control: ?*Panels.Control = null,
    calendar: ?*@import("../../desktop/calendar.zig").View = null,
    wallpapers: ?*@import("../../desktop/wallpapers.zig").View = null,
    notifications: ?*@import("../../desktop/notifications.zig").View = null,
    media: ?*@import("../../desktop/media.zig").View = null,
    tray: ?*@import("../../desktop/tray.zig").View = null,
    aqueous_settings: ?*@import("../../desktop/aqueous_settings.zig").View = null,
    clipboard_capture: ?*@import("../../desktop/clipboard_capture.zig").View = null,
    settings: ?*@import("../../desktop/settings.zig").View = null,
    wallpaper_stack: ?*gtk.Stack = null,
    wallpaper_pictures: [2]?*gtk.Picture = .{ null, null },
    wallpaper_index: u8 = 0,
    wallpaper_texture: ?*gdk.Texture = null,
    appearance_revision: u64 = std.math.maxInt(u64),
    measure_signal: c_ulong = 0,
    measure_clock: ?*gdk.FrameClock = null,
    fn destroy(self: *Surface) void {
        if (self.switcher_spoken) |spoken| a.free(spoken);
        if (self.autohide) |controller| controller.destroy();
        self.autohide = null;
        if (self.aqueous_settings) |view| view.destroy();
        if (self.settings) |view| view.destroy();
        if (self.notifications) |view| view.destroy();
        if (self.media) |view| view.destroy();
        if (self.tray) |view| view.destroy();
        if (self.bar) |bar| bar.destroy();
        if (self.launcher) |launcher| launcher.destroy();
        if (self.launcher_picker) |view| view.destroy();
        if (self.running_apps) |view| view.destroy();
        if (self.clipboard_capture) |view| view.destroy();
        if (self.control) |control| control.destroy();
        if (self.calendar) |view| view.destroy();
        if (self.wallpapers) |view| view.destroy();
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
    plugin_overlays: std.ArrayList(*@import("../../plugins/overlay.zig").Overlay) = .empty,
    dock: ?*@import("../../desktop/dock.zig").Dock = null,
    frames: [4]?*Surface = .{ null, null, null, null },
    seen: bool = false,
    preferences_revision: u64 = 0,
    bar_content_hash: ?u64 = null,
    fn destroy(self: *Output) void {
        for (self.plugin_overlays.items) |overlay| overlay.destroy();
        self.plugin_overlays.deinit(a);
        if (self.dock) |dock| dock.destroy();
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
    picker_request: ?LauncherPicker.Request = null,
    settings_page: ?navigation.Route = null,
    owner_probe: if (@import("build_options").test_hooks) @import("../../desktop/settings_owner_probe.zig").Probe else void = if (@import("build_options").test_hooks) .{} else {},
    audio: @import("../../services/audio.zig").Audio = undefined,
    lifecycle: @import("../../services/lifecycle.zig").Lifecycle = undefined,
    auth: @import("../../services/polkit.zig").Agent = undefined,
    night_light: @import("../../services/night_light.zig").NightLight = undefined,
    power: @import("../../services/power.zig").Power = undefined,
    network: @import("../../services/network.zig").Network = undefined,
    bluetooth: @import("../../services/bluetooth.zig").Bluetooth = undefined,
    session_services: @import("../../services/session.zig").Session = undefined,
    clipboard: @import("../../services/clipboard.zig").Clipboard = undefined,
    capture: @import("../../services/capture.zig").Capture = undefined,
    capture_hide: bool = false,
    capture_feedback: bool = false,
    services_started: bool = false,
    activity: ?*@import("../../platform/wayland/input_activity.zig").Broker = null,
    plugins: ?*@import("../../plugins/manager.zig").Manager = null,
    settings_observer_context: ?*anyopaque = null,
    settings_observer: ?*const fn (*anyopaque) void = null,
    aqueous_settings: @import("../../config/aqueous_client.zig").Client = undefined,
    preferences: @import("../../config/service.zig").Service = undefined,
    slideshow: @import("../../config/slideshow.zig").Engine = undefined,
    border_theme: @import("../../config/border_theme.zig").Sync = .{},
    identifiers: std.ArrayList(*Surface) = .empty,
    identify_timer: c_uint = 0,
    osd_view: ?Osd.View = null,
    osd_content: ?Osd.Content = null,
    osd_text: @import("../../services/policy.zig").Text(512) = .{},
    osd_pending: ?Osd.Content = null,
    osd_pending_output: ?*Output = null,
    osd_flush: c_uint = 0,
    index: Apps.Index = undefined,
    tasks: @import("../../desktop/task_apps.zig").Store = .{},
    layout: ?Layout = null,
    layout_stamp: u64 = 0,
    clock_source: c_uint = 0,
    clock_monitor: c_uint = 0,
    clock_last_real: i64 = 0,
    clock_last_monotonic: i64 = 0,
    clock_zone_stamp: u64 = 0,
    error_pending: bool = false,
    switcher: ?*Surface = null,
    switcher_serial: u64 = 0,
    switcher_announcement: c_uint = 0,
    osd: ?*Surface = null,
    notification: ?*Surface = null,
    osd_source: c_uint = 0,
    sync_source: c_uint = 0,
    monitor_signal: c_ulong = 0,
    gtk_settings_signal: c_ulong = 0,
    monitor_watches: std.ArrayList(struct { monitor: *gdk.Monitor, signal: c_ulong }) = .empty,
    running: bool = false,
    context: ?*anyopaque = null,
    changed: ?*const fn (*anyopaque) void = null,
    logout: ?*const fn (*anyopaque) void = null,
    pub fn init(app: *gtk.Application, display: *gdk.Display, client: *adapter.Client) Manager {
        return .{ .app = app, .display = display, .client = client };
    }
    pub fn start(self: *Manager) !void {
        if (layer.isSupported() == 0) return error.LayerShellUnavailable;
        self.index = .{ .app = self.app.as(gio.Application), .context = self, .changed = appsChanged };
        self.effects = try native.Effects.init(self.display);
        self.running = true;
        self.activity = @import("../../platform/wayland/input_activity.zig").Broker.create(self.display) catch null;
        if (self.activity) |broker| {
            broker.context = self;
            broker.changed = activityChanged;
            broker.activity = activityEvent;
        }
        self.effects.context = self;
        self.effects.changed = nativeChanged;
        self.effects.start();
        self.layout = try Layout.init(self.display, self, layoutChanged);
        self.layout.?.start();
        self.index.start();
        self.audio = .{ .context = self, .changed = audioChanged };
        self.night_light = .{ .display = self.display, .context = self, .changed = nightLightChanged };
        self.power = .{ .app = self.app.as(gio.Application), .context = self, .changed = powerChanged };
        if (@import("build_options").test_hooks) if (glib.getenv("PEARL_TEST_BACKLIGHT")) |root| self.power.backlight_root.set(std.mem.span(root));
        self.network = .{ .app = self.app.as(gio.Application), .context = self, .changed = connectivityChanged };
        self.bluetooth = .{ .app = self.app.as(gio.Application), .context = self, .changed = connectivityChanged };
        self.clipboard = .{ .display = self.display, .context = self, .changed = nativeChanged };
        self.capture = .{ .app = self.app.as(gio.Application), .display = self.display, .context = self, .changed = captureChanged };
        self.session_services = .{ .app = self.app.as(gio.Application), .context = self, .changed = sessionChanged };
        self.preferences = .{ .app = self.app.as(gio.Application), .display = self.display, .context = self, .changed = preferencesChanged, .validate = validatePreferences, .shell_appearance = true };
        try self.preferences.start();
        self.slideshow = .{ .service = &self.preferences };
        self.slideshow.configure();
        self.aqueous_settings = .{ .app = self.app.as(gio.Application), .context = self, .changed = aqueousSettingsChanged, .reload = aqueousReload, .can_reload = aqueousCanReload, .can_record = aqueousCanRecord, .identify_outputs = identifyDisplays, .peer_pid = aqueousPeerPid };
        self.aqueous_settings.start();
        self.services_started = true;
        self.night_light.start();
        self.night_light.configure(self.preferences.prefs().night_light);
        self.audio.start();
        self.lifecycle = .{ .app = self.app.as(gio.Application), .display = self.display, .client = self.client, .context = self, .changed = lifecycleChanged, .request_logout = logoutRequested, .activity_broker = self.activity };
        self.auth = .{ .app = self.app.as(gio.Application), .context = self, .changed = authChanged, .activity_broker = self.activity };
        self.auth.start();
        try self.lifecycle.start();
        self.power.start();
        self.network.start();
        self.bluetooth.start();
        self.session_services.start();
        try self.clipboard.start();
        try self.capture.start();
        self.plugins = try @import("../../plugins/manager.zig").Manager.create(self.app.as(gio.Application), self, pluginsChanged);
        self.plugins.?.broker = self.activity;
        if (self.activity) |broker| self.plugins.?.setActivity(broker.state());
        self.plugins.?.configure(self.preferences.prefs().plugins, self.preferences.prefs().reduced_motion);
        self.syncClipboardPrivacy();
        self.armClock();
        gtk.IconTheme.getForDisplay(self.display).addResourcePath("/org/aqueous/Pearl/icons");
        self.monitor_signal = gio.ListModel.signals.items_changed.connect(self.display.getMonitors(), *Manager, monitorsChanged, self, .{});
        self.gtk_settings_signal = object.Object.signals.notify.connect(gtk.Settings.getForDisplay(self.display).as(object.Object), *Manager, gtkSettingsChanged, self, .{});
        self.watchMonitors();
        self.schedule();
    }
    pub fn deinit(self: *Manager) void {
        if (!self.running) return;
        self.running = false;
        if (self.clock_source != 0) _ = glib.Source.remove(self.clock_source);
        self.clock_source = 0;
        if (self.clock_monitor != 0) _ = glib.Source.remove(self.clock_monitor);
        self.clock_monitor = 0;
        self.slideshow.stop();
        self.index.stop();
        if (self.sync_source != 0) _ = glib.Source.remove(self.sync_source);
        self.sync_source = 0;
        if (self.monitor_signal != 0) object.signalHandlerDisconnect(self.display.getMonitors().as(object.Object), self.monitor_signal);
        if (self.gtk_settings_signal != 0) object.signalHandlerDisconnect(gtk.Settings.getForDisplay(self.display).as(object.Object), self.gtk_settings_signal);
        self.unwatchMonitors();
        self.monitor_watches.deinit(a);
        self.clear();
        self.tasks.deinit();
        self.tasks = .{};
        if (self.plugins) |plugins| plugins.stop();
        self.plugins = null;
        if (self.services_started) {
            self.aqueous_settings.stop();
            self.preferences.stop();
            self.audio.stop();
            self.lifecycle.stop();
            self.auth.stop();
            self.night_light.stop();
            self.power.stop();
            self.network.stop();
            self.bluetooth.stop();
            self.clipboard.stop();
            self.capture.stop();
            self.session_services.stop();
            self.services_started = false;
        }
        if (self.osd_flush != 0) _ = glib.Source.remove(self.osd_flush);
        self.osd_flush = 0;
        self.outputs.deinit(a);
        if (self.activity) |broker| broker.destroy();
        self.activity = null;
        self.effects.deinit();
        if (self.layout) |*layout| layout.deinit();
        self.layout = null;
    }
    pub fn schedule(self: *Manager) void {
        if (self.running and self.sync_source == 0) self.sync_source = glib.idleAdd(syncIdle, self);
    }
    fn gtkSettingsChanged(_: *object.Object, _: *object.ParamSpec, self: *Manager) callconv(.c) void {
        self.schedule();
    }
    pub fn clear(self: *Manager) void {
        self.hideSwitcher();
        self.hideIdentifiers();
        self.hidePopup();
        self.hideOsd();
        self.hideNotifications();
        for (self.outputs.items) |o| o.destroy();
        self.outputs.clearRetainingCapacity();
        self.tasks.snapshot.reset();
    }
    fn aqueousSettingsChanged(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        if (self.popup) |surface| if (surface.aqueous_settings) |view| view.update();
        if (self.settings_observer) |notify| notify(self.settings_observer_context.?);
        self.schedule();
    }
    fn syncBorderTheme(self: *Manager) void {
        const borders = @import("../../config/border_theme.zig");
        const live = self.preferences.live orelse return;
        const c = &self.aqueous_settings;
        const enabled = live.prefs.theme.sync_borders and live.prefs.theme.mode != .gtk;
        if (enabled and self.client.model.session.len != 32) return;
        const desired: ?borders.Target = if (enabled) .{ .colors = borders.colors(live.palette) catch return, .session = self.client.model.session[0..32].* } else null;
        const action = self.border_theme.next(desired, .{
            .allowed = self.running and self.preferences.integration_allowed and self.preferences.job == null and aqueousCanReload(self),
            .busy = c.job != null or c.reload_ticket != null or c.recording,
            .draft = c.draft != null,
            .unresolved = c.unresolved,
            .jobs = c.jobs,
            .completed_job = c.completed_job,
            .failed = c.err != null,
        });
        switch (action) {
            .none => return,
            .refresh => c.begin(.refresh) catch |err| {
                self.border_theme.pending = false;
                c.err = err;
                c.changed(c.context);
            },
            .apply => {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const draft = borders.request(arena.allocator(), c.value(), desired.?.colors) catch |err| {
                    c.err = err;
                    c.changed(c.context);
                    return;
                };
                if (draft) |bytes| {
                    c.keepDraft(bytes) catch |err| {
                        c.err = err;
                        c.changed(c.context);
                        return;
                    };
                    c.begin(.apply) catch |err| {
                        c.err = err;
                        c.changed(c.context);
                    };
                }
            },
        }
    }
    fn aqueousCanRecord(context: *anyopaque) bool {
        const self: *Manager = @ptrCast(@alignCast(context));
        return aqueousCanReload(context) and self.client.capabilities.shortcut_inhibition;
    }
    fn aqueousCanReload(context: *anyopaque) bool {
        const self: *Manager = @ptrCast(@alignCast(context));
        @import("../../aqueous/commands.zig").validate(.session_reload, &self.client.model, self.client.capabilities) catch return false;
        return true;
    }
    fn aqueousPeerPid(context: *anyopaque) ?u32 {
        const self: *Manager = @ptrCast(@alignCast(context));
        if (self.client.availability != .ready) return null;
        return self.client.request.wire.peerPid();
    }
    fn aqueousReload(context: *anyopaque) !u64 {
        const self: *Manager = @ptrCast(@alignCast(context));
        return self.client.enqueue(.session_reload);
    }
    fn validatePreferences(context: *anyopaque, prefs: @import("../../config/preferences.zig").Preferences) !void {
        const self: *Manager = @ptrCast(@alignCast(context));
        try self.validatePlugins(prefs);
        for (self.outputs.items) |output| {
            var reservations = output.reservations;
            const bar = prefs.forOutput(output.connector);
            try reservations.bar(bar.edge, bar.size);
        }
    }
    fn validatePlugins(self: *Manager, prefs: @import("../../config/preferences.zig").Preferences) !void {
        const plugins = self.plugins orelse return;
        for (prefs.plugins.entries) |cfg| {
            const old = self.preferences.prefs().plugins.find(cfg.id);
            const new_approval = cfg.digest.len > 0 and (old == null or !std.mem.eql(u8, old.?.digest, cfg.digest));
            var found_package = false;
            for (plugins.slots.items) |slot| if (std.mem.eql(u8, cfg.id, slot.id())) {
                found_package = true;
                if (new_approval and (slot.discovery_error != null or !std.mem.eql(u8, cfg.digest, &slot.entry.package.digest))) return error.PluginContentChanged;
                if ((cfg.enabled or new_approval) and std.mem.eql(u8, cfg.digest, &slot.entry.package.digest)) try slot.entry.package.manifest.config(cfg);
            };
            if (new_approval and !found_package) return error.PluginPackageMissing;
        }
    }
    fn logoutRequested(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        if (self.logout) |callback| callback(self.context.?);
    }
    pub fn syncClipboardPrivacy(self: *Manager) void {
        const gate = self.lifecycle.gate;
        const matched = if (self.effects.display_session) |identity| std.mem.eql(u8, &identity, self.client.model.session) else false;
        const locked = (if (self.activity) |broker| broker.inhibited() else false) or !matched or self.client.availability != .ready or !gate.available or !gate.active or gate.locked or gate.requesting or gate.preparing or self.auth.request != null or (if (self.client.model.get(.session, "session")) |session| session.locked else true);
        for (self.outputs.items) |output| if (output.bar) |surface| if (surface.autohide) |controller| controller.inhibit(self.barInhibited());
        // A lock request may originate inside a flyout button callback. Revoke
        // reveal immediately, but destroy that callback's view from syncIdle.
        if (self.barInhibited() and self.popup != null) self.schedule();
        self.night_light.interactive = !locked;
        self.clipboard.setLocked(locked);
        self.capture.setLocked(locked);
        if (self.plugins) |plugins| plugins.setLocked(locked);
        if (locked) for (self.outputs.items) |output| {
            for (output.plugin_overlays.items) |overlay| overlay.window.as(gtk.Widget).setVisible(0);
            if (output.bar) |surface| if (surface.bar) |bar| for (bar.plugin_views.items) |view| view.update();
        };
    }
    fn lifecycleChanged(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        if (!self.running) return;
        self.syncClipboardPrivacy();
        if (!self.osdAllowed()) self.hideOsd();
        if (self.lifecycle.gate.locked or self.lifecycle.gate.requesting or self.lifecycle.gate.preparing or (self.lifecycle.session_id.slice().len != 0 and !self.lifecycle.gate.active)) self.hideIdentifiers();
        if (self.settings_observer) |notify| notify(self.settings_observer_context.?);
        self.auth.setSession(self.lifecycle.session_id.slice(), self.lifecycle.gate.available and self.lifecycle.gate.active and !self.lifecycle.gate.locked and !self.lifecycle.gate.requesting and !self.lifecycle.gate.preparing);
        self.schedule();
    }
    fn authChanged(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        if (!self.running) return;
        self.syncClipboardPrivacy();
        if (self.auth.window) |window| self.preferences.style(window.as(gtk.Widget), self.auth.panel.?.as(gtk.Widget));
        self.schedule();
    }
    fn activityChanged(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        if (!self.running) return;
        self.syncClipboardPrivacy();
        if (self.plugins) |plugins| if (self.activity) |broker| plugins.setActivity(broker.state());
        if (self.settings_observer) |notify| notify(self.settings_observer_context.?);
        self.schedule();
    }
    fn activityEvent(context: *anyopaque, mask: u32, epoch: u64) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        if (!self.running) return;
        self.syncClipboardPrivacy();
        if (self.plugins) |plugins| plugins.noteActivity(mask, epoch);
    }
    fn pluginsChanged(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        self.servicesChanged();
    }
    fn preferencesChanged(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        if (!self.running) return;
        for (self.outputs.items) |o| {
            if (o.wallpaper) |surface| self.styleSurface(surface);
            if (o.bar) |surface| self.styleSurface(surface);
        }
        for ([_]?*Surface{ self.popup, self.osd, self.notification, self.switcher }) |maybe| if (maybe) |surface| self.styleSurface(surface);
        if (self.popup) |surface| if (surface.settings) |view| view.update();
        if (self.popup) |surface| if (surface.wallpapers) |view| view.update();
        self.lifecycle.configure(self.preferences.prefs().idle, self.power.on_battery);
        self.slideshow.configure();
        if (self.plugins) |plugins| plugins.configure(self.preferences.prefs().plugins, self.preferences.prefs().reduced_motion);
        self.authChangedSelf();
        self.positionPopup();
        self.schedule();
    }
    fn authChangedSelf(self: *Manager) void {
        authChanged(self);
    }
    /// The reveal sensor is a window of its own; without the scope class the
    /// transparent `.pearl-shell` rule misses and GTK paints the default background.
    fn styleReveal(self: *Manager, controller: *BarAutohide) void {
        const child = controller.sensor.getChild().?;
        self.preferences.style(controller.sensor.as(gtk.Widget), child);
        child.removeCssClass("background");
    }
    fn styleSurface(self: *Manager, surface: *Surface) void {
        if (surface.appearance_revision == self.preferences.appearance) return;
        surface.appearance_revision = self.preferences.appearance;
        self.preferences.style(surface.window.as(gtk.Widget), surface.panel);
        if (surface.autohide) |controller| self.styleReveal(controller);
        if (surface.kind == .wallpaper or surface.kind == .frame) surface.panel.removeCssClass("background");
        if (surface.bar) |bar| bar.styleIslands();
        if (surface.wallpaper_stack) |stack| {
            const prefs = self.preferences.prefs();
            const transition = prefs.wallpaper.slideshow.transition;
            const image = if (self.preferences.live) |live| live.texture else null;
            const shown = image != null and (prefs.wallpaper.mode == .cover or prefs.wallpaper.mode == .contain);
            // Only a replacement image animates; the first paint must not.
            const animated = shown and !prefs.reduced_motion and
                surface.wallpaper_texture != null and image.? != surface.wallpaper_texture.?;
            // Seeded per change so `.random` re-rolls on every rotation.
            const animation = if (animated) slideshow_policy.animation(transition, @intFromPtr(image.?) ^ self.preferences.appearance) else null;
            stack.setTransitionDuration(prefs.wallpaper.slideshow.transition_ms);
            stack.setTransitionType(if (animation) |kind| switch (kind) {
                .fade => .crossfade,
                .slide => .slide_left,
                .rotate => .rotate_left,
                .cover => .over_left,
            } else .none);
            if (shown) {
                const index: u8 = if (animated) surface.wallpaper_index ^ 1 else surface.wallpaper_index;
                const picture = surface.wallpaper_pictures[index].?;
                picture.setPaintable(image.?.as(gdk.Paintable));
                picture.setContentFit(if (prefs.wallpaper.mode == .cover) .cover else .contain);
                if (animated) {
                    surface.wallpaper_index = index;
                    stack.setVisibleChildName(if (index == 0) "a" else "b");
                }
            } else {
                for (surface.wallpaper_pictures) |maybe| if (maybe) |picture| picture.setPaintable(null);
            }
            surface.wallpaper_texture = image;
        }
    }
    fn sessionChanged(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        self.servicesChanged();
    }
    fn servicesChanged(self: *Manager) void {
        if (!self.running) return;
        if (self.settings_observer) |notify| notify(self.settings_observer_context.?);
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
        // Invalidate stale cards even on service loss, before considering new feedback.
        if (self.osd_content) |content| if (content == .volume and !self.validVolume(&content.volume)) self.hideOsd();
        if (self.osd_pending) |content| if (content == .volume and !self.validVolume(&content.volume)) self.cancelPendingOsd();
        if (event == .failure and self.audio.err != null) {
            self.queueOsd(self.audio.err.?);
            return;
        }
        if (self.audio.snapshot_change == .volume) {
            if (self.audio.observed.baseline) |volume| self.queueOsdContent(.{ .volume = volume });
        }
        if (event == .applied) {
            if (self.audio.feedback_write) |write| if (self.audio.find(write.key)) |d| {
                const default = self.audio.default(.sink);
                // The complete-snapshot observer owns default-output volume/mute feedback.
                if (default != null and std.meta.eql(default.?.key, write.key) and (write.volume != null or write.mute != null)) return;
                var buffer: [512]u8 = undefined;
                self.queueOsd(std.fmt.bufPrint(&buffer, "{s} · {d}%{s}", .{ d.label.slice(), d.volume, if (d.mute) " · Muted" else "" }) catch "Audio updated");
            };
        }
    }
    fn validVolume(self: *Manager, volume: *const Osd.Volume) bool {
        const device = self.audio.default(.sink) orelse return false;
        const current = Osd.Volume.from(device);
        return self.audio.ready and volume.sameDevice(&current);
    }
    fn barInhibited(self: *Manager) bool {
        const gate = self.lifecycle.gate;
        const matched = if (self.effects.display_session) |identity| std.mem.eql(u8, &identity, self.client.model.session) else false;
        return (if (self.activity) |broker| broker.inhibited() else false) or !matched or self.client.availability != .ready or (self.lifecycle.session_id.len != 0 and (!gate.available or !gate.active)) or gate.locked or gate.requesting or gate.preparing or self.auth.request != null or (if (self.client.model.get(.session, "session")) |session| session.locked else true);
    }
    fn osdAllowed(self: *Manager) bool {
        if (!self.running or self.client.availability != .ready) return false;
        const session = self.client.model.get(.session, "session") orelse return false;
        const gate = self.lifecycle.gate;
        return !session.locked and !gate.locked and !gate.requesting and !gate.preparing and
            (self.lifecycle.session_id.slice().len == 0 or (gate.available and gate.active));
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
        var content: Osd.Content = .{ .text = .{} };
        content.text.set(text);
        self.queueOsdContent(content);
    }
    fn queueOsdContent(self: *Manager, content: Osd.Content) void {
        if (!self.osdAllowed()) return;
        const output = if (self.osd) |surface| surface.output else self.osd_pending_output orelse (self.selected(null) catch return);
        self.osd_pending = content;
        self.osd_pending_output = output;
        if (self.osd_flush == 0) self.osd_flush = glib.timeoutAdd(80, flushOsd, self);
    }
    fn cancelPendingOsd(self: *Manager) void {
        if (self.osd_flush != 0) _ = glib.Source.remove(self.osd_flush);
        self.osd_flush = 0;
        self.osd_pending = null;
        self.osd_pending_output = null;
    }
    fn flushOsd(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Manager = @ptrCast(@alignCast(data.?));
        self.osd_flush = 0;
        const content = self.osd_pending orelse return 0;
        const output = self.osd_pending_output orelse return 0;
        self.osd_pending = null;
        self.osd_pending_output = null;
        if (content == .volume and !self.validVolume(&content.volume)) return 0;
        self.showOsd(output, content, 1800) catch {};
        return 0;
    }
    fn positionOsd(surface: *Surface) void {
        const output = surface.output;
        // A zero exclusive zone already places the surface inside the compositor's
        // usable area. Adding our reservation again would double the bottom gap.
        const clearance = barPlacementBounds(output);
        const extra = (output.usable.y + output.usable.height) - (clearance.y + clearance.height);
        layer.setMargin(surface.window, .bottom, @min(24 + extra, @max(0, output.usable.height - 100)));
        surface.window.setDefaultSize(@max(1, @min(320, output.usable.width - 32)), -1);
    }
    fn showOsd(self: *Manager, output: *Output, content: Osd.Content, duration: u32) !void {
        if (!self.osdAllowed()) return error.Unavailable;
        _ = try self.selected(output.id);
        if (self.osd != null and self.osd.?.output != output) self.hideOsd();
        const surface = self.osd orelse try self.create(output, .osd);
        self.osd = surface;
        if (self.osd_view == null) self.osd_view = Osd.View.init(object.ext.cast(gtk.Box, surface.panel).?);
        self.osd_content = content;
        self.osd_text = content.summary();
        self.osd_view.?.update(&content);
        positionOsd(surface);
        surface.window.present();
        if (self.osd_source != 0) _ = glib.Source.remove(self.osd_source);
        self.osd_source = glib.timeoutAdd(duration, osdExpired, self);
    }
    fn chooseLauncher(context: *anyopaque, output_id: []const u8, request: LauncherPicker.Request) !void {
        const self: *Manager = @ptrCast(@alignCast(context));
        self.picker_request = request;
        defer self.picker_request = null;
        try self.showPane(try self.selected(output_id), .launcher_picker);
    }
    fn appsChanged(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        self.schedule();
        if (self.running) if (self.popup) |p| if (p.launcher) |launcher| launcher.refresh();
    }
    fn refreshClocks(self: *Manager, zones_changed: bool) void {
        const now = glib.DateTime.newNowUtc() orelse return;
        defer now.unref();
        // Release zones across all bars before re-resolving GLib's shared objects.
        if (zones_changed) for (self.outputs.items) |o| if (o.bar) |surface| if (surface.bar) |bar| {
            for (bar.clock_views.items) |*view| view.deinit();
        };
        for (self.outputs.items) |o| if (o.bar) |surface| if (surface.bar) |bar| {
            if (zones_changed) bar.reloadClockZones();
            bar.tickAt(now);
        };
    }
    fn monitorClock(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Manager = @ptrCast(@alignCast(data.?));
        const real = glib.getRealTime();
        const monotonic = glib.getMonotonicTime();
        const stamp = @import("../../desktop/clock_time.zig").databaseStamp();
        const changed = stamp != self.clock_zone_stamp;
        const gap = monotonic - self.clock_last_monotonic;
        if (changed or gap > 2000000 or @abs((real - self.clock_last_real) - gap) > 500000) {
            self.refreshClocks(changed);
            if (self.clock_source != 0) _ = glib.Source.remove(self.clock_source);
            self.clock_source = 0;
            self.armClock();
        }
        self.clock_zone_stamp = stamp;
        self.clock_last_real = real;
        self.clock_last_monotonic = monotonic;
        return 1;
    }
    fn armClock(self: *Manager) void {
        if (self.clock_monitor == 0) {
            self.clock_last_real = glib.getRealTime();
            self.clock_last_monotonic = glib.getMonotonicTime();
            self.clock_zone_stamp = @import("../../desktop/clock_time.zig").databaseStamp();
            self.clock_monitor = glib.timeoutAdd(1000, monitorClock, self);
        }
        const now = glib.DateTime.newNowLocal() orelse return;
        defer now.unref();
        const ms: c_uint = @intCast((60 - now.getSecond()) * 1000);
        self.clock_source = glib.timeoutAdd(ms, clockTick, self);
    }
    fn clockTick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Manager = @ptrCast(@alignCast(data.?));
        self.clock_source = 0;
        self.refreshClocks(false);
        if (self.running) self.armClock();
        return 0;
    }
    pub fn settingsLauncherIconRetry(context: *anyopaque, selection: @import("../../desktop/launcher_icon_policy.zig").Config) !void {
        const self: *Manager = @ptrCast(@alignCast(context));
        // Retry only artwork already committed for a display. An unsaved
        // preview can never change that display's selected artwork.
        for (self.outputs.items) |output| {
            if (output.bar) |surface| if (surface.bar) |bar| {
                if (bar.launcher_icon.selection.eql(selection)) try bar.launcher_icon.want(selection, true);
            };
        }
    }
    pub fn settingsLayoutRows(context: *anyopaque, alloc: std.mem.Allocator) ![]const @import("../../settings/live_protocol.zig").Row {
        const self: *Manager = @ptrCast(@alignCast(context));
        const ui = @import("../../settings/live_protocol.zig");
        const p = @import("../../settings/editor_protocol.zig");
        var rows: std.ArrayList(ui.Row) = .empty;
        const layout = if (self.layout) |*v| v else return &.{};
        for (self.outputs.items) |output| {
            const stamp = self.workspaceStamp(output);
            const current = self.layout_stamp == stamp and std.mem.eql(u8, output.connector, layout.output[0..layout.output_len]);
            var controls: std.ArrayList(ui.Control) = .empty;
            try controls.append(alloc, try ui.button(alloc, "query", "Read workspace layout", .@"layout.get", .{ .output = output.id, .generation = p.num(stamp) }, layout.global != null and layout.manager == null));
            for (@import("../../platform/wayland/layout.zig").names) |name| try controls.append(alloc, try ui.button(alloc, name, name, .@"layout.set", .{ .output = output.id, .generation = p.num(stamp), .layout = name }, layout.global != null and layout.manager == null));
            try rows.append(alloc, .{ .id = output.id, .title = try std.fmt.allocPrint(alloc, "{s} · Workspace layout", .{output.connector}), .detail = if (current) layout.err orelse layout.value[0..layout.value_len] else "Choose a layout for this output’s active workspace.", .controls = controls.items });
        }
        return rows.items;
    }
    pub fn settingsLayoutAction(context: *anyopaque, value: @import("../../settings/live_protocol.zig").Layout) !void {
        const self: *Manager = @ptrCast(@alignCast(context));
        const output = try self.selected(value.output);
        if (try @import("../../settings/editor_protocol.zig").number(value.generation) != self.workspaceStamp(output)) return error.Stale;
        try self.queryLayout(output, value.layout);
    }
    fn layoutChanged(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        if (!self.running) return;
        if (self.popup) |popup| if (popup.control) |panel| panel.update();
        if (self.settings_observer) |notify| notify(self.settings_observer_context.?);
    }
    fn captureChanged(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        if (!self.running) return;
        if (self.capture_feedback and !self.capture.pending()) {
            self.capture_feedback = false;
            if (!self.capture.locked) self.queueOsd(self.capture.message);
        }
        self.schedule();
    }
    fn nightLightChanged(context: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        self.servicesChanged();
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
        self.night_light.configure(self.preferences.prefs().night_light);
        self.night_light.refresh();
        if (self.capture_hide) {
            self.capture_hide = false;
            if (self.pane == .clipboard_capture) self.hidePopup();
        }
        self.lifecycle.sync();
        self.lifecycle.configure(self.preferences.prefs().idle, self.power.on_battery);
        if (self.plugins) |plugins| plugins.configure(self.preferences.prefs().plugins, self.preferences.prefs().reduced_motion);
        self.syncClipboardPrivacy();
        if (self.barInhibited()) self.hidePopup();
        if (!self.osdAllowed()) self.hideOsd();
        if (self.lifecycle.gate.locked or self.lifecycle.gate.requesting or self.lifecycle.gate.preparing or (self.lifecycle.session_id.slice().len != 0 and !self.lifecycle.gate.active)) self.hideIdentifiers();
        if (self.settings_observer) |notify| notify(self.settings_observer_context.?);
        self.auth.setSession(self.lifecycle.session_id.slice(), self.lifecycle.gate.available and self.lifecycle.gate.active and !self.lifecycle.gate.locked and !self.lifecycle.gate.requesting and !self.lifecycle.gate.preparing);
        self.syncSettingsAccess();
        self.syncBorderTheme();
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
        try self.tasks.update(&self.client.model, &self.index, self.preferences.prefs().application_launchers, self.preferences.prefs().pinned_apps);
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
                const bar_pref = self.preferences.prefs().forOutput(o.connector);
                try o.reservations.bar(bar_pref.edge, bar_pref.size);
                o.bar = try self.create(o, .bar);
                errdefer o.bar.?.destroy();
                o.dock = try @import("../../desktop/dock.zig").Dock.create(self.app, o.monitor, &self.effects, self.client, &self.index, &self.tasks, &self.preferences, o.id, self, appsChanged);
                o.dock.?.choose_launcher = chooseLauncher;
                errdefer o.dock.?.destroy();
                try self.outputs.append(a, o);
                output = o;
                std.log.info("event=output-mapped id={s} connector={s} scale={d}", .{ o.id, o.connector, o.scale });
            }
            const o = output.?;
            o.seen = true;
            if (o.preferences_revision != self.preferences.appearance) {
                if (self.popup != null and self.pane == .running_apps) self.hidePopup();
                const pref = self.preferences.prefs().forOutput(o.connector);
                try o.reservations.bar(pref.edge, pref.size);
                o.bar.?.edge = pref.edge;
                sizeEdge(o.bar.?, pref.edge, pref.size);
                try o.bar.?.bar.?.launcher_icon.want(pref.launcher_icon, false);
                o.bar.?.bar.?.setWorkspaceMode(pref.workspace_mode);
                if (o.bar.?.bar.?.islands != pref.islands) if (o.bar.?.autohide) |controller| controller.clearGesture();
                o.bar.?.bar.?.setIslands(pref.islands);
                const content = try std.json.Stringify.valueAlloc(a, .{ .groups = pref.groups, .clocks = pref.clocks, .plugins = self.preferences.prefs().plugins }, .{});
                defer a.free(content);
                const content_hash = std.hash.Wyhash.hash(0, content);
                if (o.bar_content_hash == null or o.bar_content_hash.? != content_hash) {
                    if (o.bar.?.autohide) |controller| controller.clearGesture();
                    if (self.popup != null and self.popup.?.output == o) self.hidePopup();
                    try o.bar.?.bar.?.configure(pref.groups, pref.clocks);
                    o.bar_content_hash = content_hash;
                }
                self.preferences.style(o.bar.?.window.as(gtk.Widget), o.bar.?.panel);
                o.bar.?.bar.?.styleIslands();
                o.bar.?.effects.islands = if (pref.islands) &o.bar.?.bar.?.sections else null;
                o.preferences_revision = self.preferences.appearance;
            }
            const changed = !std.meta.eql(o.bounds, bounds) or !std.meta.eql(o.usable, usable);
            self.capture.validateTarget(o.connector, bounds.width, bounds.height);
            o.bounds = bounds;
            o.usable = usable;
            o.scale = record.scale;
            if (o.bar) |s| if (s.bar) |bar| {
                const vertical = s.edge == .left or s.edge == .right;
                bar.geometry(vertical, if (vertical) bounds.height else bounds.width);
                try bar.setBackgroundOpacity(self.preferences.prefs().forOutput(o.connector).background_opacity, self.preferences.barBackgroundColor(s.panel));
                bar.update();
            };
            const gate = self.lifecycle.gate;
            const dock_locked = self.client.model.get(.session, "session").?.locked or gate.locked or gate.requesting or gate.preparing or self.auth.request != null or (self.lifecycle.session_id.slice().len != 0 and (!gate.available or !gate.active));
            if (dock_locked and (self.pane == .running_apps or self.pane == .launcher_picker)) self.hidePopup();
            if (suspendTasks(o)) |host| host.setSensitive(@intFromBool(!dock_locked));
            if (o.bar.?.autohide) |controller| {
                var fullscreen = false;
                var windows = self.client.model.entities.valueIterator();
                while (windows.next()) |entity_| if (entity_.* == .window) {
                    const win = entity_.window;
                    if (win.visible and !win.minimized and win.fullscreen and win.output != null and std.mem.eql(u8, win.output.?, o.id)) fullscreen = true;
                };
                controller.configure(self.preferences.prefs().forOutput(o.connector).mode, o.bar.?.edge, o.reservations.bar_size, self.barInhibited(), fullscreen);
            }
            if (o.dock) |dock| try dock.update(self.preferences.prefs().dockForOutput(o.connector), o.reservations.bar_edge, bounds, dock_locked);
            try self.syncPluginOverlays(o, dock_locked);
            if (self.osd) |surface| if (surface.output == o) positionOsd(surface);
            if (changed and self.popup != null and self.popup.?.output == o) self.positionPopup();
        }
        var i: usize = 0;
        while (i < self.outputs.items.len) {
            const o = self.outputs.items[i];
            if (!o.seen) {
                if (self.capture.target) |target| if (std.mem.eql(u8, target.name.slice(), o.connector)) self.capture.cancel();
                if (self.popup != null and self.popup.?.output == o) self.hidePopup();
                self.hideIdentifiers();
                if ((self.osd != null and self.osd.?.output == o) or self.osd_pending_output == o) self.hideOsd();
                if (self.notification != null and self.notification.?.output == o) self.hideNotifications();
                if (self.switcher != null and self.switcher.?.output == o) self.hideSwitcher();
                _ = self.outputs.orderedRemove(i);
                o.destroy();
            } else i += 1;
        }
        try self.syncSwitcher();
        if (self.popup) |popup| if (popup.launcher_picker) |view| {
            if (view.update()) self.hidePopup();
        };
        if (self.popup) |popup| {
            if (popup.running_apps) |view| try view.update();
            if (popup.launcher) |launcher| launcher.refresh();
            if (popup.clipboard_capture) |view| view.update();
            if (popup.control) |panel| panel.update();
            if (popup.notifications) |view| view.update();
            if (popup.media) |view| view.update();
            if (popup.tray) |view| view.update();
            if (self.pane == .tray) self.positionPopup();
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
            self.syncSettingsAccess();
            self.hidePopup();
            self.hideIdentifiers();
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
            .switcher => "pearl:window-switcher",
            .osd => "pearl:osd",
            .notification => "pearl:notification",
            .frame => "pearl:frame-exclusion",
        });
        layer.setLayer(window, switch (kind) {
            .wallpaper => .background,
            .bar, .frame => .top,
            .switcher, .popup, .osd, .notification => .overlay,
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
            if (s.launcher_picker) |view| view.destroy();
            if (s.running_apps) |view| view.destroy();
            if (s.clipboard_capture) |view| view.destroy();
            if (s.control) |panel_control| panel_control.destroy();
            if (s.calendar) |view| view.destroy();
            if (s.wallpapers) |view| view.destroy();
            if (s.notifications) |view| view.destroy();
            if (s.media) |view| view.destroy();
            if (s.tray) |view| view.destroy();
            if (s.aqueous_settings) |view| view.destroy();
            if (s.settings) |view| view.destroy();
        }
        switch (kind) {
            .wallpaper => {
                window.as(gtk.Widget).addCssClass("pearl-wallpaper");
                anchors(window, null);
                layer.setExclusiveZone(window, -1);
                // Two stacked pictures so a wallpaper change can crossfade or slide.
                const stack = gtk.Stack.new();
                stack.as(gtk.Widget).setHexpand(1);
                stack.as(gtk.Widget).setVexpand(1);
                for (0..2) |i| {
                    const picture = gtk.Picture.new();
                    picture.setCanShrink(1);
                    picture.as(gtk.Widget).setHexpand(1);
                    picture.as(gtk.Widget).setVexpand(1);
                    _ = stack.addNamed(picture.as(gtk.Widget), if (i == 0) "a" else "b");
                    s.wallpaper_pictures[i] = picture;
                }
                stack.setVisibleChildName("a");
                panel.append(stack.as(gtk.Widget));
                s.wallpaper_stack = stack;
                window.setChild(panel_widget);
            },
            .bar => {
                panel_widget.addCssClass("pearl-bar-panel");
                inline for ([_]fn (*gtk.Widget, c_int) callconv(.c) void{ gtk.Widget.setMarginStart, gtk.Widget.setMarginEnd, gtk.Widget.setMarginTop, gtk.Widget.setMarginBottom }) |set| set(panel_widget, 4);
                s.bar = try Bar.Bar.create(panel, self.client, output.id, s, barAction, &self.audio, &self.power, &self.network, &self.bluetooth, &self.session_services, self.plugins, &self.tasks.snapshot, &self.index);
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
                if (self.pane == .aqueous_settings or self.pane == .launcher_picker) {
                    // GtkFixed otherwise allocates the child's natural width,
                    // which can exceed the popup rectangle with enlarged text.
                    const viewport = gtk.ScrolledWindow.new();
                    viewport.setPolicy(.never, .automatic);
                    viewport.setPropagateNaturalWidth(0);
                    viewport.setPropagateNaturalHeight(0);
                    viewport.setChild(panel_widget);
                    s.viewport = viewport;
                    fixed.put(viewport.as(gtk.Widget), 0, 0);
                } else fixed.put(panel_widget, 0, 0);
                window.setChild(fixed.as(gtk.Widget));
                panel_widget.addCssClass("pearl-popup-panel");
                if (self.pane == .tray) panel_widget.addCssClass("pearl-menu-panel");
                switch (self.pane) {
                    .aqueous_settings => s.aqueous_settings = try @import("../../desktop/aqueous_settings.zig").View.create(panel, &self.aqueous_settings, window),
                    .settings => s.settings = try @import("../../desktop/settings.zig").View.create(panel, &self.preferences),
                    .launcher_picker => s.launcher_picker = try LauncherPicker.View.create(panel, &self.index, &self.preferences, self.client, self.picker_request orelse return error.InvalidRequest),
                    .running_apps => s.running_apps = try Running.Chooser.create(panel, &self.tasks.snapshot, &self.index, s, runningAction),
                    .launcher => s.launcher = try Launcher.create(panel, self.app.as(gio.Application), self.display, &self.index, self.client, self, dismiss),
                    .calendar => s.calendar = try @import("../../desktop/calendar.zig").View.create(panel),
                    .wallpapers => s.wallpapers = try @import("../../desktop/wallpapers.zig").View.create(panel, &self.preferences),
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
                    .clipboard_capture => s.clipboard_capture = try @import("../../desktop/clipboard_capture.zig").View.create(panel, &self.clipboard, &self.capture, s, captureRequested),
                    .control => {
                        s.control = try Panels.Control.create(panel, &self.layout.?, s, layoutAction, controlTask, settingsNavigate, self.settings_page.?, window, .{ .audio = &self.audio, .power = &self.power, .night_light = &self.night_light, .network = &self.network, .bluetooth = &self.bluetooth, .lifecycle = &self.lifecycle, .auth = &self.auth });
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
            .switcher => {
                layer.setAnchor(window, .bottom, 1);
                layer.setMargin(window, .bottom, 24);
                const title = gtk.Label.new("");
                title.setEllipsize(.end);
                title.setMaxWidthChars(40);
                panel.append(title.as(gtk.Widget));
                s.switcher_label = title;
                const location = gtk.Label.new("");
                location.setEllipsize(.middle);
                location.setMaxWidthChars(40);
                panel.append(location.as(gtk.Widget));
                s.switcher_location = location;
                const row = gtk.Box.new(.horizontal, 8);
                row.setHomogeneous(1);
                s.switcher_controls = row.as(gtk.Widget);
                const previous = gtk.Button.newWithLabel(tr("Previous", "Zurück"));
                const next = gtk.Button.newWithLabel(tr("Cycle →", "Weiter →"));
                next.as(gtk.Widget).addCssClass("suggested-action");
                _ = gtk.Button.signals.clicked.connect(previous, *Surface, switcherPrevious, s, .{});
                _ = gtk.Button.signals.clicked.connect(next, *Surface, switcherNext, s, .{});
                row.append(previous.as(gtk.Widget));
                row.append(next.as(gtk.Widget));
                panel.append(row.as(gtk.Widget));
                window.setDefaultSize(320, -1);
                window.setChild(panel_widget);
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
        const effect_panel = if (kind == .switcher) s.switcher_controls.? else if (kind == .popup and s.viewport != null) s.viewport.?.as(gtk.Widget) else panel_widget;
        try s.effects.init(&self.effects, window, effect_panel, kind == .bar or kind == .popup or kind == .osd or kind == .notification or kind == .switcher, if (kind == .popup) .full else if (kind == .bar or kind == .notification or kind == .switcher) .panel else .empty);
        if (s.bar) |bar| s.effects.islands = if (bar.islands) &bar.sections else null;
        if (kind == .bar) {
            _ = gtk.Widget.signals.map.connect(window.as(gtk.Widget), *Surface, barMapped, s, .{});
            s.autohide = BarAutohide.create(window, output.monitor, s, barVisibilityChanged) catch |err| blk: {
                std.log.err("event=bar-autohide-unavailable error={s}", .{@errorName(err)});
                break :blk null;
            };
            if (s.autohide) |controller| {
                self.styleReveal(controller);
                controller.configure(self.preferences.prefs().forOutput(output.connector).mode, s.edge, output.reservations.bar_size, self.barInhibited(), false);
            } else window.present();
        } else if (kind != .popup and kind != .osd and kind != .frame and kind != .notification and kind != .switcher) window.present();
        return s;
    }
    fn hideSwitcher(self: *Manager) void {
        if (self.switcher_announcement != 0) _ = glib.Source.remove(self.switcher_announcement);
        self.switcher_announcement = 0;
        if (self.switcher) |surface| {
            self.switcher = null;
            surface.destroy();
        }
    }
    fn cycleWindow(self: *Manager, output: *Output, direction: Switcher.Direction) !void {
        if (self.barInhibited()) return error.Locked;
        const action = try Switcher.action(&self.client.model, output.id, direction, self.preferences.prefs().reduced_motion, self.client.capabilities.global_window_switcher_v1);
        if (direction != .dismiss) self.hidePopup();
        _ = try self.client.enqueue(action);
    }
    fn syncSwitcher(self: *Manager) !void {
        const state = self.client.model.get(.session, "session") orelse {
            self.hideSwitcher();
            return;
        };
        if (state.switcher_pending) return;
        const id = state.switcher_output orelse {
            self.hideSwitcher();
            return;
        };
        if (self.barInhibited() or self.popup != null) {
            self.hideSwitcher();
            return;
        }
        const output = self.selected(id) catch {
            self.hideSwitcher();
            return;
        };
        if (self.switcher) |surface| if (surface.output != output) self.hideSwitcher();
        const surface = self.switcher orelse try self.create(output, .switcher);
        self.switcher = surface;
        const window = self.client.model.get(.window, state.switcher_window orelse "");
        const title = if (window) |w| w.title orelse w.app_id orelse "Window" else "Window";
        const workspace = if (state.switcher_workspace) |workspace_id| self.client.model.get(.workspace, workspace_id) else self.client.model.activeWorkspace(output.id);
        const destination = if (state.switcher_destination_output) |destination_id| self.client.model.get(.output, destination_id) else self.client.model.get(.output, output.id);
        const location = try std.fmt.allocPrintSentinel(a, "{d} / {d} · {s} {s} · {s}", .{ state.switcher_position, state.switcher_total, tr("Workspace", "Arbeitsfläche"), if (workspace) |ws| ws.name else "", if (destination) |dest| dest.name else "" }, 0);
        defer a.free(location);
        const title_z = try a.dupeZ(u8, title);
        defer a.free(title_z);
        const label = try std.fmt.allocPrintSentinel(a, "{s} · {s}", .{ title, location }, 0);
        defer a.free(label);
        const spoken = try std.fmt.allocPrintSentinel(a, "{s}, {s}", .{ if (window) |w| w.app_id orelse "Window" else "Window", label }, 0);
        if (surface.switcher_spoken) |old| a.free(old);
        surface.switcher_spoken = spoken;
        surface.switcher_label.?.setText(title_z);
        surface.switcher_location.?.setText(location);
        surface.switcher_location.?.as(gtk.Widget).setTooltipText(location);
        surface.switcher_label.?.as(gtk.Widget).setTooltipText(label);
        surface.panel.as(gtk.Accessible).updateProperty(.label, spoken.ptr, @as(c_int, -1));
        if (self.switcher_serial != state.switcher_serial) {
            if (self.switcher_announcement != 0) _ = glib.Source.remove(self.switcher_announcement);
            self.switcher_announcement = glib.timeoutAdd(100, announceSwitcher, self);
        }
        self.switcher_serial = state.switcher_serial;
        positionOsd(surface);
        surface.window.present();
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
    fn syncPluginOverlays(self: *Manager, output: *Output, locked: bool) !void {
        const plugins = self.plugins orelse return;
        for (output.plugin_overlays.items) |overlay| overlay.seen = false;
        var fullscreen = false;
        var entities = self.client.model.entities.valueIterator();
        while (entities.next()) |entity| if (entity.* == .window and entity.window.fullscreen and entity.window.visible) {
            if (entity.window.output) |id| if (std.mem.eql(u8, id, output.id)) {
                fullscreen = true;
            };
        };
        for (self.preferences.prefs().plugins.entries) |cfg| {
            if (!cfg.enabled or cfg.placement.mode != .overlay or !cfg.grants.overlay) continue;
            if (cfg.placement.output.len > 0) {
                if (!std.mem.eql(u8, cfg.placement.output, output.connector)) continue;
            } else if (self.outputs.items.len == 0 or self.outputs.items[0] != output) continue;
            var active = false;
            for (plugins.slots.items) |slot| if (std.mem.eql(u8, slot.id(), cfg.id) and slot.status == .active and slot.scene != null) {
                active = true;
                break;
            };
            if (!active or locked) continue;
            var found: ?*@import("../../plugins/overlay.zig").Overlay = null;
            for (output.plugin_overlays.items) |overlay| if (std.mem.eql(u8, overlay.view.id, cfg.id)) {
                found = overlay;
                break;
            };
            if (found == null) {
                const overlay = try @import("../../plugins/overlay.zig").Overlay.create(self.app, output.monitor, &self.effects, plugins, &self.preferences, cfg.id);
                try output.plugin_overlays.append(a, overlay);
                found = overlay;
            }
            found.?.update(cfg.placement, output.bounds.width, output.bounds.height, cfg.placement.hide_fullscreen and fullscreen);
        }
        var i: usize = 0;
        while (i < output.plugin_overlays.items.len) {
            if (!output.plugin_overlays.items[i].seen) {
                const overlay = output.plugin_overlays.orderedRemove(i);
                overlay.destroy();
            } else i += 1;
        }
    }
    fn syncSettingsAccess(self: *Manager) void {
        const matched = if (self.effects.display_session) |identity| std.mem.eql(u8, &identity, self.client.model.session) else false;
        const allowed = matched and self.client.availability == .ready and if (self.client.model.get(.session, "session")) |session| !session.locked else false;
        self.preferences.setIntegrationAllowed(allowed);
        self.network.interest.enabled = allowed;
        self.bluetooth.interest.enabled = allowed;
        self.power.interest.enabled = allowed;
        if (allowed) return;
        if (self.network.interest.count() != 0) self.network.revokeViews();
        if (self.bluetooth.interest.count() != 0) self.bluetooth.revokeViews();
        if (self.power.interest.count() != 0) self.power.revokeViews();
    }
    fn openSettings(self: *Manager, target: navigation.Target, activation: ?[]const u8) !void {
        if (self.client.availability != .ready) return error.Unavailable;
        if (self.client.model.get(.session, "session").?.locked) return error.Locked;
        const display = gdk.Display.getDefault() orelse return error.Unavailable;
        const context = display.getAppLaunchContext();
        defer context.unref();
        context.setTimestamp(0);
        try @import("../../settings/launch.zig").open(target, context.as(gio.AppLaunchContext), activation);
        self.hidePopup();
    }
    fn settingsAction(self: *Manager, output_id: ?[]const u8, page: navigation.Route, intent: navigation.Intent) !void {
        if (!page.isCompact()) return error.InvalidRequest;
        const output = try self.selected(output_id);
        if (self.client.model.get(.session, "session").?.locked) return error.Locked;
        const current: ?navigation.Selection = if (self.popup) |popup| if (self.settings_page) |visible| .{ .page = visible, .output = popup.output.id } else null else null;
        const decision = try navigation.transition(current, .{ .page = page, .output = output.id }, intent, &.{output.id});
        switch (decision.action) {
            .close => self.hidePopup(),
            .select => {
                try self.popup.?.control.?.selectPage(page, decision.position);
                self.settings_page = page;
            },
            .open, .replace => try self.showPaneAt(output, .control, page),
        }
    }
    fn connectivityOwner(self: *Manager, page: navigation.Route) !Owner {
        const popup = self.popup orelse return error.Unavailable;
        const panel = popup.control orelse return error.Unavailable;
        if (panel.page != page) return error.Unavailable;
        return (panel.connection orelse return error.Unavailable).owner;
    }
    fn suspendTasks(output: *Output) ?*gtk.Widget {
        const bar = (output.bar orelse return null).bar orelse return null;
        return if (bar.running_apps) |view| view.host.as(gtk.Widget) else null;
    }
    pub fn showPane(self: *Manager, output: *Output, pane: Bar.Pane) !void {
        return self.showPaneAt(output, pane, .overview);
    }
    fn showPaneAt(self: *Manager, output: *Output, pane: Bar.Pane, page: navigation.Route) !void {
        if (self.switcher) |surface| {
            self.cycleWindow(surface.output, .dismiss) catch {};
            self.hideSwitcher();
        }
        if (self.barInhibited()) return error.Locked;
        if ((pane == .running_apps or pane == .launcher_picker) and (self.lifecycle.gate.locked or self.lifecycle.gate.requesting or self.lifecycle.gate.preparing or self.auth.request != null)) return error.Locked;
        if (pane == .clipboard_capture) {
            self.syncClipboardPrivacy();
            if (self.clipboard.locked) return error.Locked;
        }
        if (self.client.model.get(.session, "session").?.locked) return error.Locked;
        for (self.outputs.items) |o| if (o.dock) |dock| {
            if (dock.keyboard) dock.reveal(false);
        };
        self.hidePopup();
        self.pane = pane;
        self.settings_page = if (pane == .control) page else null;
        errdefer self.settings_page = null;
        self.popup = try self.create(output, .popup);
        if (output.bar.?.autohide) |controller| controller.holdPopup(true);
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
        if (self.popup.?.running_apps) |view| view.focus();
        if (self.popup.?.launcher_picker) |view| _ = view.search.as(gtk.Widget).grabFocus();
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
        const launcher = self.pane == .launcher or self.pane == .launcher_picker;
        const settings = self.pane == .settings or self.pane == .aqueous_settings;
        const centered = prefs.placement == .centered or launcher;
        var width = @min(@as(i32, if (launcher) 620 else if (settings) 700 else if (self.pane == .control or self.pane == .clipboard_capture) 600 else if (self.pane == .wallpapers) 640 else 440), prefs.max_width);
        var height = @min(@as(i32, if (launcher) 600 else if (settings) 720 else if (self.pane == .calendar) 480 else 560), prefs.max_height);
        if (self.pane == .tray) {
            // Tray menus hug their entries instead of reserving a full pane.
            if (s.tray) |view| {
                const size = view.preferred();
                width = @min(@max(size.width + 16, 220), width);
                height = @min(@max(size.height + 16, 160), height);
            }
        }
        var rect = if (centered) policy.popup(o.bounds, o.usable, width, height) else policy.anchored(o.bounds, barPlacementBounds(o), width, height, o.reservations.bar_edge, self.pane != .calendar);
        if (self.pane == .wallpapers) {
            // Sit under the bar icon that opened the pane, the way the calendar
            // sits under the clock. The bar spans the whole edge, so the
            // cross-axis coordinate is already output-relative.
            if (o.bar) |surface| if (surface.bar) |bar| if (bar.pane_anchor) |anchor| {
                if (o.reservations.bar_edge == .top or o.reservations.bar_edge == .bottom) {
                    const left = @max(0, o.usable.x - o.bounds.x);
                    const right = @min(o.bounds.width, o.usable.x - o.bounds.x + o.usable.width) - rect.width;
                    rect.x = @min(@max(anchor.x + @divTrunc(anchor.width, 2) - @divTrunc(rect.width, 2), left), @max(left, right));
                } else {
                    const top = @max(0, o.usable.y - o.bounds.y);
                    const bottom = @min(o.bounds.height, o.usable.y - o.bounds.y + o.usable.height) - rect.height;
                    rect.y = @min(@max(anchor.y + @divTrunc(anchor.height, 2) - @divTrunc(rect.height, 2), top), @max(top, bottom));
                }
            };
        }
        if (self.popup_rect) |previous| if (std.meta.eql(previous, rect)) return;
        self.popup_rect = rect;
        const fixed = object.ext.cast(gtk.Fixed, s.window.getChild().?).?;
        const positioned = if (s.viewport) |viewport| viewport.as(gtk.Widget) else s.panel;
        fixed.move(positioned, @floatFromInt(rect.x - (o.usable.x - o.bounds.x)), @floatFromInt(rect.y - (o.usable.y - o.bounds.y)));
        positioned.setSizeRequest(rect.width, rect.height);
        self.positionNotifications();
    }
    pub fn hidePopup(self: *Manager) void {
        if (self.popup) |s| {
            self.popup = null;
            self.settings_page = null;
            self.popup_rect = null;
            if (s.output.bar.?.autohide) |controller| controller.holdPopup(false);
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
        const usable = s.output.usable;
        const clearance = barPlacementBounds(s.output);
        layer.setMargin(s.window, .top, 16 + clearance.y - usable.y);
        layer.setMargin(s.window, .right, if (left) 0 else 16 + usable.x + usable.width - clearance.x - clearance.width);
        layer.setMargin(s.window, .left, if (left) 16 + clearance.x - usable.x else 0);
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
    fn identifyDisplays(context: *anyopaque) !void {
        const self: *Manager = @ptrCast(@alignCast(context));
        const session = self.client.model.get(.session, "session") orelse return error.Unavailable;
        if (session.locked or self.lifecycle.gate.locked or self.lifecycle.gate.requesting or self.lifecycle.gate.preparing or (self.lifecycle.session_id.slice().len != 0 and !self.lifecycle.gate.active)) return error.SessionInactive;
        self.hideIdentifiers();
        errdefer self.hideIdentifiers();
        const model = @import("../../config/aqueous_model.zig");
        const outputs = model.list(model.get(model.get(self.aqueous_settings.baseValue(), "display_observation"), "outputs"));
        for (outputs, 0..) |output, i| {
            const connector = model.str(model.get(output, "connector"));
            for (self.outputs.items) |o| {
                if (!std.mem.eql(u8, o.connector, connector)) continue;
                const surface = try self.create(o, .osd);
                self.identifiers.append(a, surface) catch |err| {
                    surface.destroy();
                    return err;
                };
                var buffer: [256]u8 = undefined;
                const label = gtk.Label.new(try std.fmt.bufPrintZ(&buffer, "{d}  ·  {s}", .{ @import("../../config/aqueous_display_setup.zig").number(output, i + 1), connector }));
                label.as(gtk.Widget).addCssClass("pearl-title");
                object.ext.cast(gtk.Box, surface.panel).?.append(label.as(gtk.Widget));
                surface.window.present();
            }
        }
        self.identify_timer = glib.timeoutAdd(3000, identifiersExpired, self);
    }
    fn identifiersExpired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Manager = @ptrCast(@alignCast(data.?));
        self.identify_timer = 0;
        self.hideIdentifiers();
        return 0;
    }
    fn hideIdentifiers(self: *Manager) void {
        if (self.identify_timer != 0) _ = glib.Source.remove(self.identify_timer);
        self.identify_timer = 0;
        for (self.identifiers.items) |surface| surface.destroy();
        self.identifiers.deinit(a);
        self.identifiers = .empty;
    }
    fn hideOsd(self: *Manager) void {
        self.cancelPendingOsd();
        self.dismissOsd();
    }
    fn dismissOsd(self: *Manager) void {
        if (self.osd_source != 0) _ = glib.Source.remove(self.osd_source);
        self.osd_source = 0;
        self.osd_view = null;
        self.osd_content = null;
        self.osd_text = .{};
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
        if (self.aqueous_settings.completion(result)) return;
        if (result.status == .rejected or result.status == .unknown or result.status == .dropped) {
            self.error_pending = true;
            self.schedule();
            std.log.info("event=desktop-action status={s} detail={s}", .{ @tagName(result.status), result.detail });
        }
    }
    pub fn control(self: *Manager, request: protocol.Request, alloc: std.mem.Allocator) ![]const u8 {
        self.syncSettingsAccess();
        self.syncClipboardPrivacy();
        if (request.op == .clipboard_status) return self.clipboard.status(alloc);
        if (request.op == .capture_status) return self.capture.status(alloc);
        if (request.op == .capture_windows) return self.capture.native.status(alloc, request.offset orelse 0);
        if (request.op == .lifecycle_status) return self.lifecycle.status(alloc, &self.auth);
        if (request.op == .lifecycle_action) {
            try self.lifecycle.act(request.text.?, request.generation);
            return "{\"queued\":true}";
        }
        if (request.op == .session_status) {
            self.session_services.notifications.setLocked(self.client.availability != .ready or (if (self.client.model.get(.session, "session")) |session| session.locked else true));
            return self.session_services.status(alloc, request.offset orelse 0);
        }
        if (@import("build_options").test_hooks and request.op == .aqueous_status and std.mem.eql(u8, request.text orelse "", "test-launcher-picker")) {
            const popup = self.popup orelse return error.Unavailable;
            const view = popup.launcher_picker orelse return error.Unavailable;
            return std.json.Stringify.valueAlloc(alloc, .{ .rows = try view.report(alloc, popup.window.as(gtk.Widget)), .selected = view.selected_id, .pending = view.pending != null }, .{});
        }
        if (@import("build_options").test_hooks and request.op == .aqueous_status and std.mem.startsWith(u8, request.text orelse "", "test-running-apps")) {
            const text = request.text.?;
            if (std.mem.startsWith(u8, text, "test-running-apps:bar:")) {
                const output = try self.selected(text["test-running-apps:bar:".len..]);
                const surface = output.bar orelse return error.Unavailable;
                const strip = surface.bar.?.running_apps orelse return error.Unavailable;
                return std.json.Stringify.valueAlloc(alloc, try strip.report(alloc, surface.window.as(gtk.Widget)), .{});
            }
            if (std.mem.startsWith(u8, text, "test-running-apps:rows:")) {
                const offset = try std.fmt.parseInt(usize, text["test-running-apps:rows:".len..], 10);
                const surface = self.popup orelse return error.Unavailable;
                const view = surface.running_apps orelse return error.Unavailable;
                const rows = try view.report(alloc, surface.window.as(gtk.Widget));
                const begin = @min(offset, rows.len);
                return std.json.Stringify.valueAlloc(alloc, rows[begin..@min(begin + 20, rows.len)], .{});
            }
            const Group = struct { key: []const u8, name: []const u8, count: usize };
            var groups: std.ArrayList(Group) = .empty;
            for (self.tasks.snapshot.groups) |g| try groups.append(alloc, .{ .key = g.key, .name = g.name, .count = g.windows.items.len });
            const Strip = struct { output: []const u8, shown: usize, slots: usize, keyboard_mode: []const u8 };
            var strips: std.ArrayList(Strip) = .empty;
            for (self.outputs.items) |o| if (o.bar) |surface| if (surface.bar.?.running_apps) |strip| {
                try strips.append(alloc, .{ .output = o.id, .shown = strip.shown, .slots = strip.slots, .keyboard_mode = @tagName(layer.getKeyboardMode(surface.window)) });
            };
            var rows: []const Running.ProbeRow = &.{};
            var popup_output: ?[]const u8 = null;
            if (self.popup) |surface| if (surface.running_apps) |view| {
                rows = try view.report(alloc, surface.window.as(gtk.Widget));
                popup_output = surface.output.id;
            };
            return std.json.Stringify.valueAlloc(alloc, .{ .revision = self.tasks.snapshot.revision, .groups = groups.items, .strips = strips.items, .row_count = rows.len, .popup_output = popup_output }, .{});
        }
        if (@import("build_options").test_hooks and request.op == .aqueous_status and std.mem.eql(u8, request.text orelse "", "test-focus")) {
            const popup = self.popup orelse return error.Unavailable;
            const viewport = if (popup.viewport) |v| v.as(gtk.Widget) else popup.panel;
            return std.json.Stringify.valueAlloc(alloc, .{ .focus = @import("../../desktop/aqueous_settings.zig").View.focusName(popup.window), .width = viewport.getWidth(), .height = viewport.getHeight(), .content_width = popup.panel.getWidth(), .limit = self.popup_rect }, .{});
        }
        if (@import("build_options").test_hooks and request.op == .aqueous_status and std.mem.startsWith(u8, request.text orelse "", "test-bar-autohide:")) {
            const output = try self.selected(request.text.?["test-bar-autohide:".len..]);
            const c = output.bar.?.autohide orelse return error.Unavailable;
            return std.json.Stringify.valueAlloc(alloc, .{ .state = c.state, .sensor_mapped = c.sensor.as(gtk.Widget).getMapped() != 0, .sensor_width = c.sensor.as(gtk.Widget).getWidth(), .sensor_height = c.sensor.as(gtk.Widget).getHeight(), .bar_mapped = c.window.as(gtk.Widget).getMapped() != 0, .layer = @tagName(layer.getLayer(c.window)), .keyboard_mode = @tagName(layer.getKeyboardMode(c.window)) }, .{});
        }
        if (@import("build_options").test_hooks and request.op == .aqueous_status and (std.mem.eql(u8, request.text orelse "", "test-bar-layout") or std.mem.startsWith(u8, request.text orelse "", "test-bar-layout:"))) {
            if (self.outputs.items.len == 0) return error.Unavailable;
            const output = if (request.text.?.len == "test-bar-layout".len) self.outputs.items[0] else try self.selected(request.text.?["test-bar-layout:".len..]);
            const surface = output.bar orelse return error.Unavailable;
            return surface.bar.?.layoutReport(alloc, @tagName(layer.getKeyboardMode(surface.window)));
        }
        if (@import("build_options").test_hooks and request.op == .aqueous_status and std.mem.eql(u8, request.text orelse "", "test-settings-page")) {
            const popup = self.popup orelse return error.Unavailable;
            const control_page = popup.control orelse return error.Unavailable;
            return control_page.report(popup.window, alloc);
        }
        if (request.op == .aqueous_status) return self.aqueous_settings.status(alloc, request.text);
        if (request.op == .plugin_refresh) {
            const plugins = self.plugins orelse return error.Unavailable;
            return std.json.Stringify.valueAlloc(alloc, .{ .version = 1, .requested = plugins.requestRefresh(), .pending = true }, .{});
        }
        if (request.op == .plugin_list or request.op == .plugin_inspect) return (self.plugins orelse return error.Unavailable).report(alloc, request.path, request.offset orelse 0);
        if (request.op == .preferences_status) return self.preferences.status(alloc);
        if (request.op == .status) return self.status(alloc);
        if (request.op == .connectivity_status) return @import("../../services/connectivity_status.zig").encode(alloc, &self.network, &self.bluetooth, request.offset orelse 0);
        if (request.op == .night_light_status) return std.json.Stringify.valueAlloc(alloc, try self.night_light.snapshot(alloc), .{});
        if (request.op == .services_status) return std.json.Stringify.valueAlloc(alloc, try self.serviceStatus(alloc, request.offset orelse 0), .{});
        if (self.client.availability != .ready) return error.Unavailable;
        if (request.op != .quit and self.client.model.get(.session, "session").?.locked) return error.Locked;
        if (@import("build_options").test_hooks and request.op == .aqueous_draft and std.mem.startsWith(u8, request.text orelse "", "{\"test_owner\":"))
            return self.owner_probe.command(alloc, request.text.?, &self.network, &self.bluetooth, &self.power);
        switch (request.op) {
            .night_light_action => {
                self.syncClipboardPrivacy();
                try self.night_light.act(std.meta.stringToEnum(@import("../../services/night_light_policy.zig").Action, request.text.?).?);
                return std.json.Stringify.valueAlloc(alloc, try self.night_light.snapshot(alloc), .{});
            },
            .night_light_status, .plugin_refresh, .plugin_list, .plugin_inspect, .clipboard_status, .capture_status, .capture_windows, .lifecycle_action, .lifecycle_status, .aqueous_status, .preferences_status, .status, .services_status, .connectivity_status, .session_status => unreachable,
            .dock_show, .dock_hide, .dock_pin, .dock_unpin => {
                const dock = (try self.selected(request.output)).dock orelse return error.Unavailable;
                if (dock.locked) return error.Locked;
                if (request.op == .dock_show) {
                    self.hidePopup();
                    for (self.outputs.items) |o| if (o.dock) |other| {
                        if (other != dock and other.keyboard) other.reveal(false);
                    };
                }
                if (request.op == .dock_pin or request.op == .dock_unpin) try dock.pin(request.text.?, request.op == .dock_pin) else dock.reveal(request.op == .dock_show);
            },
            .clipboard_show, .capture_show => {
                try self.showPane(try self.selected(request.output), .clipboard_capture);
                if (request.op == .capture_show) self.popup.?.clipboard_capture.?.showCapture();
            },
            .clipboard_clear => self.clipboard.clear(),
            .clipboard_select => try self.clipboard.select(request.generation.?),
            .clipboard_delete => try self.clipboard.delete(request.generation.?),
            .wm_action => {
                const action = try std.json.parseFromSliceLeaky(@import("../../aqueous/commands.zig").Action, alloc, request.text.?, .{ .allocate = .alloc_always });
                if (action == .session_exit) return error.UseLifecycleLogout;
                if (action == .session_reload) try self.aqueous_settings.requestReload() else _ = try self.client.enqueue(action);
            },
            .capture_window => try self.capture.native.takeWindow(request.text.?),
            .capture_cancel => self.capture.cancel(),
            .capture_copy => try self.capture.copy(&self.clipboard, request.generation.?),
            .capture_save => try self.capture.save(request.generation.?, request.path),
            .capture_output, .capture_region => {
                const output = try self.selected(request.output);
                const crop = if (request.op == .capture_region) try @import("../../services/clipboard_policy.zig").region(request.text.?, output.bounds.width, output.bounds.height) else null;
                try self.capture.take(output.connector, output.bounds.width, output.bounds.height, crop);
                return "{\"queued\":true}";
            },
            .plugin_reload => {
                try (self.plugins orelse return error.Unavailable).retry(request.path.?);
            },
            .plugin_enable, .plugin_disable => {
                const plugins = self.plugins orelse return error.Unavailable;
                if (plugins.locked) return error.Locked;
                if (self.preferences.draft.text != null) return error.Conflict;
                const m = @import("../../plugins/model.zig");
                var prefs = self.preferences.prefs();
                var configs: std.ArrayList(m.Config) = .empty;
                const previous = prefs.plugins.find(request.path.?) orelse m.Config{ .id = request.path.? };
                var cfg = previous;
                cfg.enabled = request.op == .plugin_enable;
                if (cfg.enabled) {
                    if (!std.mem.eql(u8, cfg.digest, request.text.?)) cfg.grants = .{};
                    cfg.digest = request.text.?;
                    var found = false;
                    for (plugins.slots.items) |slot| if (std.mem.eql(u8, slot.id(), cfg.id) and std.mem.eql(u8, &slot.entry.package.digest, cfg.digest)) {
                        try slot.entry.package.manifest.config(cfg);
                        found = true;
                        break;
                    };
                    if (!found) return error.PluginContentChanged;
                }
                for (prefs.plugins.entries) |old| if (!std.mem.eql(u8, old.id, cfg.id)) {
                    try configs.append(alloc, old);
                };
                try @import("../../plugins/placement.zig").update(alloc, &prefs, previous, &cfg, false);
                try configs.append(alloc, cfg);
                prefs.plugins.entries = configs.items;
                try self.preferences.apply(try std.json.Stringify.valueAlloc(alloc, prefs, .{}), request.revision.?);
            },
            .preferences_apply => {
                try self.preferences.apply(request.text.?, request.revision.?);
                return "{\"queued\":true}";
            },
            .preferences_reload => {
                self.preferences.reload();
                return "{\"queued\":true}";
            },
            .aqueous_show, .settings_show => {
                if (request.output != null) _ = try self.selected(request.output);
                try self.openSettings(request.settingsTarget(), request.activation);
                return "{\"launched\":true}";
            },
            .aqueous_reload => try self.aqueous_settings.requestReload(),
            .aqueous_keep => try self.aqueous_settings.choose(true),
            .aqueous_revert => try self.aqueous_settings.choose(false),
            .aqueous_rebase => try self.aqueous_settings.rebase(),
            .aqueous_record => {
                const view = if (self.popup) |p| p.aqueous_settings else null;
                try (view orelse return error.Unavailable).record(request.text.?);
            },
            .aqueous_refresh => try self.aqueous_settings.begin(.refresh),
            .aqueous_validate => try self.aqueous_settings.begin(.validate),
            .aqueous_apply => try self.aqueous_settings.begin(.apply),
            .aqueous_draft => {
                try self.aqueous_settings.keepDraft(request.text.?);
                aqueousSettingsChanged(self);
            },
            .aqueous_discard => {
                self.aqueous_settings.discard();
                aqueousSettingsChanged(self);
            },
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
                        .scan => try self.network.scan(try self.connectivityOwner(.network), request.generation.?, request.path.?),
                        .connect => try self.network.connectAP(try self.connectivityOwner(.network), request.generation.?, request.path.?),
                        .connect_saved => try self.network.connectSaved(try self.connectivityOwner(.network), request.generation.?, request.path.?),
                        .disconnect => try self.network.disconnect(request.generation.?, request.path.?),
                        .enable, .disable => try self.network.setEnabled(request.action.? == .enable),
                        .cancel => self.network.cancelOwned(try self.connectivityOwner(.network)),
                        else => return error.InvalidRequest,
                    }
                } else {
                    if (request.generation.? != self.bluetooth.peer.epoch) return error.Unavailable;
                    switch (request.action.?) {
                        .discover => try self.bluetooth.discover(try self.connectivityOwner(.bluetooth), request.generation.?, request.path.?),
                        .stop_discovery => self.bluetooth.stopDiscoveryOwned(try self.connectivityOwner(.bluetooth)),
                        .cancel => self.bluetooth.cancelOwned(try self.connectivityOwner(.bluetooth)),
                        else => try self.bluetooth.request(try self.connectivityOwner(.bluetooth), request.generation.?, request.path.?, switch (request.action.?) {
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
            .control_show, .control_toggle => try self.settingsAction(request.output, request.compactPage(), if (request.op == .control_toggle) .toggle else .show),
            .running_apps_show, .launcher_show, .launcher_toggle, .calendar_toggle => {
                const output = try self.selected(request.output);
                const pane: Bar.Pane = switch (request.op) {
                    .running_apps_show => .running_apps,
                    .calendar_toggle => .calendar,
                    else => .launcher,
                };
                const toggle = request.op == .launcher_toggle or request.op == .calendar_toggle;
                if (toggle and self.popup != null and self.popup.?.output == output and self.pane == pane) self.hidePopup() else try self.showPane(output, pane);
            },
            .bar_groups => {
                const output = try self.selected(request.output);
                const bar = output.bar.?.bar.?;
                const groups: @import("../../desktop/policy.zig").Groups = .{ .left = request.left.?, .center = request.center.?, .right = request.right.? };
                try groups.validate();
                try @import("../../desktop/clock_policy.zig").validate(bar.clock_definitions, groups);
                if (self.popup != null and self.popup.?.output == output) self.hidePopup();
                try bar.configure(groups, bar.clock_definitions);
            },
            .layout_get, .layout_set => {
                try self.queryLayout(try self.selected(request.output), request.layout);
                return "{\"queued\":true}";
            },
            .window_switcher_next, .window_switcher_previous, .window_switcher_dismiss => {
                try self.cycleWindow(try self.selected(request.output), switch (request.op) {
                    .window_switcher_next => .next,
                    .window_switcher_previous => .previous,
                    else => .dismiss,
                });
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
                if (s.autohide) |controller| controller.configure(controller.state.mode, s.edge, request.size.?, controller.state.inhibited, controller.fullscreen);
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
                self.cancelPendingOsd();
                const output = try self.selected(request.output);
                var content: Osd.Content = .{ .text = .{} };
                content.text.set(request.text.?);
                try self.showOsd(output, content, request.duration_ms orelse 2000);
            },
        }
        return "{\"applied\":true}";
    }
    const OsdStatus = struct { kind: enum { text, volume }, output: []const u8, device: ?@import("../../services/policy.zig").Key = null, name: ?[]const u8 = null, percent: ?u8 = null, muted: ?bool = null };
    fn osdStatus(self: *Manager) ?OsdStatus {
        const surface = self.osd orelse return null;
        const content = if (self.osd_content) |*value| value else return null;
        return switch (content.*) {
            .text => .{ .kind = .text, .output = surface.output.id },
            .volume => |*v| .{ .kind = .volume, .output = surface.output.id, .device = v.key, .name = v.name.slice(), .percent = v.percent, .muted = v.muted },
        };
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
        const Item = struct { keyboard: []const u8, title: []const u8, groups: Groups, id: []const u8, connector: []const u8, scale: f64, bounds: Rect, usable: Rect, bar_edge: Edge, bar_size: u16, bar_mode: BarVisibility.Mode, bar_visible: bool, bar_visibility_reason: BarVisibility.Reason, bar_sensor_visible: bool, bar_exclusive_zone: i32, frames: [4]u16, islands: bool, island_rects: [3]?Rect, dock: struct { reason: @import("../../desktop/dock_policy.zig").Reason, groups: usize, truncated: bool, rect: Rect, edge: Edge } };
        var items: std.ArrayList(Item) = .empty;
        for (self.outputs.items) |o| try items.append(alloc, .{ .keyboard = if (o.bar.?.bar.?.keyboard) |label| std.mem.span(label.getText()) else "", .title = if (o.bar.?.bar.?.title) |label| titlePreview(std.mem.span(label.getText())) else "", .groups = .{ .left = o.bar.?.bar.?.groups[0], .center = o.bar.?.bar.?.groups[1], .right = o.bar.?.bar.?.groups[2] }, .id = o.id, .connector = o.connector, .scale = o.scale, .bounds = o.bounds, .usable = o.usable, .bar_edge = o.reservations.bar_edge, .bar_size = o.reservations.bar_size, .bar_mode = if (o.bar.?.autohide) |c| c.state.mode else .always, .bar_visible = o.bar.?.window.as(gtk.Widget).getVisible() != 0, .bar_visibility_reason = if (o.bar.?.autohide) |c| c.state.reason else .always, .bar_sensor_visible = if (o.bar.?.autohide) |c| c.sensor.as(gtk.Widget).getVisible() != 0 else false, .bar_exclusive_zone = layer.getExclusiveZone(o.bar.?.window), .frames = o.reservations.frames, .islands = o.bar.?.bar.?.islands, .island_rects = o.bar.?.effects.last_shapes, .dock = .{ .reason = o.dock.?.reason, .groups = o.dock.?.count, .truncated = o.dock.?.truncated, .rect = o.dock.?.rect, .edge = o.dock.?.config.edge } });
        return std.json.Stringify.valueAlloc(alloc, .{ .services = try self.serviceStatus(alloc, null), .apps = .{ .ready = self.index.catalog != null, .truncated = if (self.index.catalog) |c| c.truncated else false, .count = if (self.index.catalog) |c| c.entries.items.len else 0, .generation = self.index.generation }, .layout = .{ .available = self.layout.?.global != null, .pending = self.layout.?.manager != null, .output = self.layout.?.output[0..self.layout.?.output_len], .value = self.layout.?.value[0..self.layout.?.value_len], .workspace = self.layout.?.workspace, .err = self.layout.?.err }, .session = self.client.model.session, .availability = self.client.availability, .blur = self.effects.available, .outputs = items.items, .popup = if (self.popup) |s| @as(?struct { output: []const u8, rect: Rect, pane: Bar.Pane, page: ?navigation.Route, results: usize, latency_us: i64 }, .{ .output = s.output.id, .rect = self.popup_rect.?, .pane = self.pane, .page = self.settings_page, .results = if (s.launcher) |l| l.count else 0, .latency_us = if (s.launcher) |l| l.latency_us else 0 }) else null, .notification = self.notification != null, .media_views = self.session_services.media.viewers, .artwork = self.session_services.media.art.image != null, .artwork_pending = self.session_services.media.art.job != null, .identifying = self.identifiers.items.len, .osd = self.osd != null, .osd_text = self.osd_text.slice(), .osd_detail = self.osdStatus(), .window_switcher = if (self.switcher) |surface| @as(?struct { output: []const u8, keyboard_mode: []const u8, text: []const u8, serial: u64, rect: Rect }, .{ .output = surface.output.id, .keyboard_mode = @tagName(layer.getKeyboardMode(surface.window)), .text = surface.switcher_spoken orelse "", .serial = self.switcher_serial, .rect = .{ .x = surface.output.usable.x + @divTrunc(surface.output.usable.width - surface.window.as(gtk.Widget).getWidth(), 2), .y = surface.output.usable.y + surface.output.usable.height - layer.getMargin(surface.window, .bottom) - surface.window.as(gtk.Widget).getHeight(), .width = surface.window.as(gtk.Widget).getWidth(), .height = surface.window.as(gtk.Widget).getHeight() } }) else null }, .{});
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
    if (s.bar) |bar| {
        bar.thickness = size;
        bar.geometry(!horizontal, if (horizontal) s.output.bounds.width else s.output.bounds.height);
        if (!horizontal and s.viewport == null) {
            // Retain the panel's existing reference while changing parents.
            // A short output scrolls vertically instead of widening the bar.
            s.window.setChild(null);
            const scroll = gtk.ScrolledWindow.new();
            scroll.setPolicy(.never, .automatic);
            scroll.setPropagateNaturalHeight(0);
            scroll.setChild(s.panel);
            s.window.setChild(scroll.as(gtk.Widget));
            s.viewport = scroll;
        } else if (horizontal) {
            if (s.viewport) |scroll| {
                scroll.setChild(null);
                s.window.setChild(s.panel);
                s.viewport = null;
            }
        }
    }
    s.window.setDefaultSize(if (horizontal) 1 else size, if (horizontal) size else 1);
    const content = if (s.kind == .frame) size else size -| 8;
    s.panel.setSizeRequest(if (horizontal) -1 else content, if (horizontal) content else -1);
    if (s.autohide) |controller| controller.measured(size) else layer.setExclusiveZone(s.window, size);
}
fn serviceProbe(_: *gdk.FrameClock, s: *Surface) callconv(.c) void {
    if (s.settings) |view| view.probe(s.window);
    if (s.notifications) |view| view.probe(s.window);
    if (s.media) |view| view.probe(s.window);
    if (s.tray) |view| view.probe(s.window);
    if (s.control) |panel| panel.probe(s.window);
}
fn barMapped(_: *gtk.Widget, s: *Surface) callconv(.c) void {
    if (s.measure_clock) |clock| {
        if (object.signalHandlerIsConnected(clock.as(object.Object), s.measure_signal) != 0) object.signalHandlerDisconnect(clock.as(object.Object), s.measure_signal);
        clock.unref();
        s.measure_clock = null;
    }
    if (s.window.as(gtk.Widget).getFrameClock()) |clock| {
        _ = clock.ref();
        s.measure_clock = clock;
        s.measure_signal = gdk.FrameClock.signals.after_paint.connect(clock, *Surface, measured, s, .{});
    }
}
fn barVisibilityChanged(context: *anyopaque) void {
    const s: *Surface = @ptrCast(@alignCast(context));
    if (s.manager.popup) |popup| if (popup.output == s.output) s.manager.positionPopup();
    if (s.manager.osd) |osd| if (osd.output == s.output) Manager.positionOsd(osd);
    s.manager.positionNotifications();
}
fn barPlacementBounds(o: *Output) Rect {
    const surface = o.bar orelse return o.usable;
    const controller = surface.autohide orelse return o.usable;
    if (controller.state.mode != .autohide) return o.usable;
    return policy.withBarFootprint(o.bounds, o.usable, surface.edge, o.reservations.bar_size);
}
fn measured(_: *gdk.FrameClock, s: *Surface) callconv(.c) void {
    const horizontal = s.edge == .top or s.edge == .bottom;
    const size = if (horizontal) s.window.as(gtk.Widget).getHeight() else s.window.as(gtk.Widget).getWidth();
    if (size > 0 and size <= 65535) {
        if (s.autohide) |controller| controller.measured(size) else layer.setExclusiveZone(s.window, size);
        if (s.output.reservations.bar_size != size) {
            s.output.reservations.bar_size = @intCast(size);
            barVisibilityChanged(s);
        }
    }
}
fn barAction(context: *anyopaque, event: Bar.Event) void {
    const s: *Surface = @ptrCast(@alignCast(context));
    const self = s.manager;
    switch (event) {
        .running_apps => |task| runningAction(s, task),
        .settings => |page| self.settingsAction(s.output.id, page, .toggle) catch {},
        .pane => |pane| {
            if (pane == .control) {
                self.settingsAction(s.output.id, .overview, .toggle) catch {};
                return;
            }
            if (pane == .tray and self.popup != null and self.popup.?.output == s.output and self.pane == .tray) {
                self.popup.?.tray.?.update();
                self.positionPopup();
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
        .window_switcher => self.cycleWindow(s.output, .next) catch {
            self.error_pending = true;
            self.schedule();
        },
        .overview => {
            self.enqueueAction(.{ .overview_toggle = .{ .output = s.output.id } });
            self.hidePopup();
        },
    }
}
fn runningAction(context: *anyopaque, event: Running.Event) void {
    const surface: *Surface = @ptrCast(@alignCast(context));
    const self = surface.manager;
    switch (event) {
        .activate => |id| {
            // enqueue copies opaque IDs and validates current model/capabilities.
            self.enqueueAction(.{ .window_activate = .{ .id = id } });
            self.hidePopup();
        },
        .group => |group| {
            const owned = a.dupe(u8, group) catch return;
            defer a.free(owned);
            const output = surface.output;
            self.showPane(output, .running_apps) catch return;
            self.popup.?.running_apps.?.select(owned, 0) catch {};
        },
        .overflow => |skip| {
            const output = surface.output;
            self.showPane(output, .running_apps) catch return;
            self.popup.?.running_apps.?.select(null, skip) catch {};
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
        if (s.control.?.label) |label| label.setText(tr("Layout change unavailable", "Anordnung kann nicht geändert werden"));
    };
}
fn settingsNavigate(context: *anyopaque, page: navigation.Route) anyerror!void {
    const s: *Surface = @ptrCast(@alignCast(context));
    try s.manager.settingsAction(s.output.id, page, .navigate);
}
fn controlTask(context: *anyopaque, task: Panels.Control.Task) void {
    const s: *Surface = @ptrCast(@alignCast(context));
    switch (task) {
        .full_settings, .night_settings => {
            const manager = s.manager;
            const page: navigation.Route = if (task == .night_settings) .appearance else manager.settings_page orelse .overview;
            manager.openSettings(.{ .page = page }, null) catch |err| {
                s.control.?.launchFailed(err);
                return;
            };
        },
        .media => barAction(s, .{ .pane = .media }),
        .settings => barAction(s, .{ .pane = .settings }),
        .aqueous_settings => barAction(s, .{ .pane = .aqueous_settings }),
        .overview => barAction(s, .overview),
        .close => s.manager.hidePopup(),
    }
}
fn keyPressed(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, _: gdk.ModifierType, self: *Manager) callconv(.c) c_int {
    if (key != 0xff1b) return 0;
    if (self.popup) |popup| if (popup.aqueous_settings) |view| {
        if (view.recording != null) return 0; // The recorder owns Escape and restores entry focus.
    };
    self.hidePopup();
    return 1;
}
fn outsideReleased(_: *gtk.GestureClick, _: c_int, x: f64, y: f64, self: *Manager) callconv(.c) void {
    if (!self.preferences.prefs().popup.dismiss_outside) return;
    const s = self.popup orelse return;
    const picked = s.window.as(gtk.Widget).pick(x, y, .{});
    const inside = if (s.viewport) |viewport| viewport.as(gtk.Widget) else s.panel;
    if (picked) |widget| if (widget == inside or widget.isAncestor(inside) != 0) return;
    self.hidePopup();
}
fn osdExpired(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Manager = @ptrCast(@alignCast(data.?));
    self.osd_source = 0;
    self.dismissOsd();
    return 0;
}

fn titlePreview(text: []const u8) []const u8 {
    var n = @min(text.len, 128);
    while (n > 0 and n < text.len and text[n] & 0xc0 == 0x80) n -= 1;
    return text[0..n];
}

fn captureRequested(context: *anyopaque, region: ?[]const u8) !void {
    const surface: *Surface = @ptrCast(@alignCast(context));
    const manager = surface.manager;
    manager.syncClipboardPrivacy();
    const output = surface.output;
    const crop = if (region) |text| try @import("../../services/clipboard_policy.zig").region(text, output.bounds.width, output.bounds.height) else null;
    try manager.capture.take(output.connector, output.bounds.width, output.bounds.height, crop);
    manager.capture_hide = true;
    manager.capture_feedback = true;
    manager.schedule();
}

fn switcherPrevious(_: *gtk.Button, surface: *Surface) callconv(.c) void {
    surface.manager.cycleWindow(surface.output, .previous) catch {
        surface.manager.error_pending = true;
        surface.manager.schedule();
    };
}
fn switcherNext(_: *gtk.Button, surface: *Surface) callconv(.c) void {
    surface.manager.cycleWindow(surface.output, .next) catch {
        surface.manager.error_pending = true;
        surface.manager.schedule();
    };
}

fn announceSwitcher(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Manager = @ptrCast(@alignCast(data.?));
    self.switcher_announcement = 0;
    if (self.switcher) |surface| surface.panel.as(gtk.Accessible).announce((surface.switcher_spoken orelse return 0).ptr, .medium);
    return 0;
}
