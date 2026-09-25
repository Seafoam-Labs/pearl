const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const tr = @import("text.zig").tr;
const native = @import("../platform/wayland/layout.zig");
const navigation = @import("settings_navigation.zig");
const services = @import("services.zig");
const connectivity = @import("connectivity.zig");
const a = std.heap.c_allocator;
const pages = navigation.compact_routes;
const focus_state = @import("focus_state.zig");
const policy = @import("../services/policy.zig");
const Text = policy.Text;

pub const Control = struct {
    pub const Task = enum { media, overview, settings, aqueous_settings, full_settings, night_settings, close };
    pub const Models = struct {
        night_light: ?*@import("../services/night_light.zig").NightLight = null,
        audio: *@import("../services/audio.zig").Audio,
        power: *@import("../services/power.zig").Power,
        network: *@import("../services/network.zig").Network,
        bluetooth: *@import("../services/bluetooth.zig").Bluetooth,
        lifecycle: *@import("../services/lifecycle.zig").Lifecycle,
        auth: *@import("../services/polkit.zig").Agent,
    };
    night_label: ?*gtk.Label = null,
    night_toggle: ?*gtk.ToggleButton = null,
    night_resume: ?*gtk.Button = null,
    night_updating: bool = false,
    handoff_message: *gtk.Label,
    settings_button: *gtk.Button,
    models: Models,
    window: *gtk.Window,
    navigate: *const fn (*anyopaque, navigation.Route) anyerror!void,
    focus_signal: c_ulong = 0,
    restore_tick: c_uint = 0,
    restore_frames: u8 = 0,
    restore_position: navigation.Position = .heading,
    positions: [pages.len]f64 = @splat(0),
    focus_ids: [pages.len]Text(1024) = @splat(.{}),
    expanded: [pages.len]bool = @splat(true),
    stack: *gtk.Stack,
    heading: *gtk.Label,
    header: *gtk.Widget,
    heading_focus: *gtk.Widget,
    logout_button: *gtk.Button,
    reboot_button: *gtk.Button,
    off_button: *gtk.Button,
    power_confirm: policy.Confirmation = .{},
    tabs: [pages.len]*gtk.ToggleButton = undefined,
    tab_rows: [pages.len]TabRow = undefined,
    volume_scale: ?*gtk.Scale = null,
    brightness_scale: ?*gtk.Scale = null,
    sliders_updating: bool = false,
    bodies: [pages.len]*gtk.Box = undefined,
    viewports: [pages.len]*gtk.ScrolledWindow = undefined,
    page: navigation.Route = .overview,
    changing: bool = false,
    lifecycle: ?*@import("lifecycle.zig").View = null,
    sound: ?*services.Sound = null,
    power: ?*services.PowerView = null,
    connection: ?*connectivity.View = null,
    layout: *native.Layout,
    label: ?*gtk.Label = null,
    buttons: [native.names.len]*gtk.Button = undefined,
    context: *anyopaque,
    action: *const fn (*anyopaque, ?[]const u8) void,
    task: *const fn (*anyopaque, Task) void,
    rows: [native.names.len]Choice = undefined,
    tasks: [4]TaskLink = undefined,
    probe_focus: ?*gtk.Widget = null,
    const Choice = struct { owner: *Control, name: []const u8 };
    const TaskLink = struct { owner: *Control, task: Task };
    const TabRow = struct { owner: *Control, page: navigation.Route };

    pub fn create(host: *gtk.Box, layout: *native.Layout, context: *anyopaque, action: @FieldType(Control, "action"), task: @FieldType(Control, "task"), navigate: @FieldType(Control, "navigate"), initial: navigation.Route, window: *gtk.Window, models: Models) !*Control {
        if (!initial.isCompact()) return error.InvalidRoute;
        const self = try a.create(Control);
        const header = w.row(10);
        header.as(gtk.Widget).addCssClass("pearl-control-header");
        host.append(header.as(gtk.Widget));
        const chip = w.row(10);
        chip.as(gtk.Widget).addCssClass("pearl-user-chip");
        const avatar = w.icon("pearl-avatar-default-symbolic");
        avatar.as(gtk.Widget).addCssClass("pearl-avatar");
        chip.append(avatar.as(gtk.Widget));
        const user_label = w.label(glib.getUserName(), "pearl-user-name");
        user_label.as(gtk.Widget).setHexpand(0);
        user_label.setWrap(0);
        chip.append(user_label.as(gtk.Widget));
        w.name(chip.as(gtk.Widget), tr("Signed-in user", "Angemeldete Person"));
        header.append(chip.as(gtk.Widget));
        // Session and settings actions stay reachable on every page.
        const spacer = w.row(0);
        spacer.as(gtk.Widget).setHexpand(1);
        header.append(spacer.as(gtk.Widget));
        const installed = @import("../settings/launch.zig").available();
        const handoff_message = w.label(if (installed) "" else tr("Full settings is not installed.", "Die vollständigen Einstellungen sind nicht installiert."), "pearl-secondary");
        handoff_message.as(gtk.Widget).setHexpand(0);
        handoff_message.as(gtk.Widget).setVisible(@intFromBool(!installed));
        _ = handoff_message.as(object.Object).refSink();
        header.append(handoff_message.as(gtk.Widget));
        const session_actions = w.row(6);
        header.append(session_actions.as(gtk.Widget));
        const logout = w.iconButton("pearl-system-log-out-symbolic", tr("Log out", "Abmelden"));
        const reboot = w.iconButton("pearl-system-reboot-symbolic", tr("Restart…", "Neu starten…"));
        const off = w.iconButton("pearl-system-shutdown-symbolic", tr("Power off…", "Ausschalten…"));
        const settings_button = w.iconButton("pearl-emblem-system-symbolic", tr("Settings", "Einstellungen"));
        settings_button.as(gtk.Widget).setSensitive(@intFromBool(installed));
        for ([_]*gtk.Button{ logout, reboot, off, settings_button }) |button| session_actions.append(button.as(gtk.Widget));
        const heading = w.label(title(initial), "pearl-page-title");
        heading.as(object.Object).set("accessible-role", @intFromEnum(gtk.AccessibleRole.heading), @as(?[*:0]const u8, null));
        heading.as(gtk.Accessible).updateProperty(.level, @as(c_int, 1), @as(c_int, -1));
        heading.setWrap(1);
        // GtkLabel's focus implementation requires selectable text. Give the
        // heading a focusable container without turning its text into an editor.
        const heading_box = w.row(0);
        heading_box.as(gtk.Widget).setHexpand(1);
        heading_box.as(gtk.Widget).setFocusable(1);
        heading_box.as(gtk.Widget).addCssClass("pearl-settings-heading");
        w.name(heading_box.as(gtk.Widget), title(initial));
        heading_box.append(heading.as(gtk.Widget));
        host.append(heading_box.as(gtk.Widget));
        const stack = gtk.Stack.new();
        stack.setVhomogeneous(0);
        stack.setHhomogeneous(0);
        stack.setTransitionType(.none);
        stack.as(gtk.Widget).setVexpand(1);
        host.append(stack.as(gtk.Widget));
        self.* = .{ .handoff_message = handoff_message, .settings_button = settings_button, .models = models, .window = window, .navigate = navigate, .page = initial, .stack = stack, .heading = heading, .header = header.as(gtk.Widget), .heading_focus = heading_box.as(gtk.Widget), .logout_button = logout, .reboot_button = reboot, .off_button = off, .layout = layout, .context = context, .action = action, .task = task };
        errdefer self.destroy();
        for (pages, 0..) |page, i| {
            const scroll = gtk.ScrolledWindow.new();
            scroll.setPolicy(.never, .automatic);
            scroll.setPropagateNaturalWidth(0);
            scroll.setPropagateNaturalHeight(0);
            const body = w.column(16);
            scroll.setChild(body.as(gtk.Widget));
            _ = stack.addNamed(scroll.as(gtk.Widget), page.id());
            self.viewports[i] = scroll;
            self.bodies[i] = body;
        }
        const tabs = w.row(4);
        tabs.as(gtk.Widget).addCssClass("pearl-tab-strip");
        host.append(tabs.as(gtk.Widget));
        for (pages, 0..) |page, i| {
            const tab = gtk.ToggleButton.newWithLabel(title(page).ptr);
            tab.as(gtk.Widget).setHexpand(1);
            tab.as(gtk.Widget).addCssClass("pearl-tab");
            focus_state.tag(tab.as(gtk.Widget), "tab:{s}", .{page.id()});
            self.tabs[i] = tab;
            self.tab_rows[i] = .{ .owner = self, .page = page };
            _ = gtk.Button.signals.clicked.connect(tab, *TabRow, tabClicked, &self.tab_rows[i], .{});
            tabs.append(tab.as(gtk.Widget));
        }
        try self.enterPage();
        stack.setVisibleChildName(self.page.id());
        self.focus_signal = object.Object.signals.notify.connect(window.as(object.Object), *Control, focusChanged, self, .{ .detail = "focus-widget" });
        self.queueRestore(.heading);
        _ = gtk.Button.signals.clicked.connect(logout, *Control, logoutClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(reboot, *Control, powerClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(off, *Control, powerClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(settings_button, *Control, fullSettingsClicked, self, .{});
        return self;
    }
    fn logoutClicked(_: *gtk.Button, self: *Control) callconv(.c) void {
        const life = self.models.lifecycle;
        const command = if (life.pending != null and life.pending.? == .logout) "confirm" else "logout";
        life.act(command, if (std.mem.eql(u8, command, "confirm")) life.confirmation else null) catch {
            life.err = "Session action unavailable.";
        };
        self.update();
    }
    fn powerClicked(button: *gtk.Button, self: *Control) callconv(.c) void {
        const reboot = button == self.reboot_button;
        const confirmed = self.power_confirm.click(reboot, self.models.power.epoch(), glib.getMonotonicTime());
        if (confirmed) self.models.power.powerAction(reboot) catch {
            self.models.power.err = "Power action unavailable. Review the current service state.";
            self.models.power.changed(self.models.power.context, .failure);
        };
        self.update();
    }
    fn tabClicked(_: *gtk.ToggleButton, row: *TabRow) callconv(.c) void {
        row.owner.navigate(row.owner.context, row.page) catch {};
    }
    fn fullSettingsClicked(_: *gtk.Button, self: *Control) callconv(.c) void {
        self.task(self.context, .full_settings);
    }
    pub fn launchFailed(self: *Control, err: anyerror) void {
        self.handoff_message.setText(if (err == error.SettingsNotInstalled) tr("Full settings is not installed.", "Die vollständigen Einstellungen sind nicht installiert.") else tr("Full settings could not be started. Try again after checking the installation.", "Die Einstellungen konnten nicht gestartet werden. Bitte die Installation prüfen."));
        self.handoff_message.as(gtk.Widget).setVisible(1);
        self.settings_button.as(gtk.Widget).setTooltipText(self.handoff_message.getText());
    }
    pub fn title(page: navigation.Route) [:0]const u8 {
        return tr(page.title(), switch (page) {
            .overview => "Übersicht",
            .sound => "Klang",
            .network => "Netzwerk",
            .bluetooth => "Bluetooth",
            .power => "Energie & Akku",
            else => unreachable,
        });
    }
    fn index(page: navigation.Route) usize {
        return std.mem.indexOfScalar(navigation.Route, &pages, page).?;
    }
    fn enterPage(self: *Control) !void {
        const body = self.bodies[index(self.page)];
        switch (self.page) {
            .overview => try self.composeOverview(body),
            .sound => self.sound = try services.Sound.create(body, self.models.audio),
            .power => self.power = try services.PowerView.create(body, self.models.power),
            .network => self.connection = try connectivity.View.createNetwork(body, self.models.network, self.models.bluetooth),
            .bluetooth => self.connection = try connectivity.View.createBluetooth(body, self.models.network, self.models.bluetooth),
            else => return error.InvalidRoute,
        }
    }
    fn composeOverview(self: *Control, body: *gtk.Box) !void {
        const quick = w.card();
        quick.as(gtk.Widget).addCssClass("pearl-quick-card");
        const volume = w.slider(w.label(tr("Volume", "Lautstärke"), "pearl-secondary"), "pearl-audio-volume-high-symbolic", 0);
        self.volume_scale = volume.scale;
        focus_state.tag(volume.scale.as(gtk.Widget), "quick-volume", .{});
        _ = gtk.Range.signals.value_changed.connect(volume.scale.as(gtk.Range), *Control, volumeChanged, self, .{});
        quick.append(volume.box.as(gtk.Widget));
        const brightness = w.slider(w.label(tr("Brightness", "Helligkeit"), "pearl-secondary"), "pearl-display-brightness-symbolic", 0);
        self.brightness_scale = brightness.scale;
        focus_state.tag(brightness.scale.as(gtk.Widget), "quick-brightness", .{});
        _ = gtk.Range.signals.value_changed.connect(brightness.scale.as(gtk.Range), *Control, brightnessChanged, self, .{});
        quick.append(brightness.box.as(gtk.Widget));
        body.append(quick.as(gtk.Widget));
        if (self.models.night_light != null) {
            const night = w.card();
            self.night_label = w.label("", "pearl-secondary");
            const tile = w.tile("pearl-weather-clear-night-symbolic", w.label(tr("Night Light", "Nachtlicht"), null), self.night_label.?, false);
            self.night_toggle = tile.button;
            w.name(tile.button.as(gtk.Widget), tr("Toggle Night Light", "Nachtlicht umschalten"));
            focus_state.tag(tile.button.as(gtk.Widget), "night-tile", .{});
            _ = gtk.ToggleButton.signals.toggled.connect(tile.button, *Control, nightToggled, self, .{});
            night.append(tile.button.as(gtk.Widget));
            const row = w.row(8);
            self.night_resume = w.wrappingButton(tr("Resume saved policy", "Gespeicherte Einstellungen fortsetzen"));
            _ = gtk.Button.signals.clicked.connect(self.night_resume.?, *Control, nightResumed, self, .{});
            row.append(self.night_resume.?.as(gtk.Widget));
            const settings = w.wrappingButton(tr("Night Light settings", "Nachtlicht-Einstellungen"));
            settings.as(gtk.Widget).setSensitive(@intFromBool(@import("../settings/launch.zig").available()));
            _ = gtk.Button.signals.clicked.connect(settings, *Control, nightSettings, self, .{});
            row.append(settings.as(gtk.Widget));
            night.append(row.as(gtk.Widget));
            body.append(night.as(gtk.Widget));
        }
        const tasks = w.flow(2);
        body.append(tasks.as(gtk.Widget));
        for ([_]Task{ .media, .overview, .settings, .aqueous_settings }, [_][:0]const u8{ tr("Media controls", "Mediensteuerung"), tr("Window overview", "Fensterübersicht"), tr("Pearl settings", "Pearl-Einstellungen"), tr("Aqueous settings", "Aqueous-Einstellungen") }, 0..) |task, label, i| {
            const button = w.wrappingButton(label);
            button.as(gtk.Widget).addCssClass("pearl-quick-tile");
            focus_state.tag(button.as(gtk.Widget), "task:{s}", .{@tagName(task)});
            self.tasks[i] = .{ .owner = self, .task = task };
            _ = gtk.Button.signals.clicked.connect(button, *TaskLink, taskClicked, &self.tasks[i], .{});
            tasks.insert(button.as(gtk.Widget), -1);
        }
        self.lifecycle = try @import("lifecycle.zig").View.create(body, self.models.lifecycle, self.models.auth, self.models.power);
        const section = w.card();
        section.as(gtk.Widget).addCssClass("pearl-layout-card");
        const title_row = w.row(8);
        title_row.append(w.label(tr("Workspace layout", "Anordnung der Arbeitsfläche"), "pearl-card-title").as(gtk.Widget));
        const refresh = w.iconButton("pearl-view-refresh-symbolic", tr("Refresh layout", "Anordnung aktualisieren"));
        focus_state.tag(refresh.as(gtk.Widget), "layout-refresh", .{});
        _ = gtk.Button.signals.clicked.connect(refresh, *Control, refreshed, self, .{});
        title_row.append(refresh.as(gtk.Widget));
        section.append(title_row.as(gtk.Widget));
        self.label = w.label("", "pearl-secondary");
        self.label.?.setWrap(1);
        section.append(self.label.?.as(gtk.Widget));
        const layouts = w.flow(3);
        section.append(layouts.as(gtk.Widget));
        for (native.names, 0..) |name, i| {
            const button = w.wrappingButton(name);
            button.as(gtk.Widget).addCssClass("pearl-pill");
            focus_state.tag(button.as(gtk.Widget), "layout:{s}", .{name});
            self.buttons[i] = button;
            self.rows[i] = .{ .owner = self, .name = name };
            _ = gtk.Button.signals.clicked.connect(button, *Choice, selected, &self.rows[i], .{});
            layouts.insert(button.as(gtk.Widget), -1);
        }
        body.append(section.as(gtk.Widget));
        self.update();
    }
    fn destroyPage(self: *Control) void {
        // Null pointers before service cleanup can synchronously notify the host.
        const lifecycle = self.lifecycle;
        const sound = self.sound;
        const power = self.power;
        const connection = self.connection;
        self.lifecycle = null;
        self.sound = null;
        self.power = null;
        self.connection = null;
        self.label = null;
        self.night_label = null;
        self.night_toggle = null;
        self.night_resume = null;
        self.volume_scale = null;
        self.brightness_scale = null;
        if (lifecycle) |view| view.destroy();
        if (sound) |view| view.destroy();
        if (power) |view| view.destroy();
        if (connection) |view| view.destroy();
        const body = self.bodies[index(self.page)];
        while (body.as(gtk.Widget).getFirstChild()) |child| body.remove(child);
    }
    fn focusChanged(_: *object.Object, _: *object.ParamSpec, self: *Control) callconv(.c) void {
        if (self.changing or self.restore_tick != 0) return;
        self.rememberFocus();
    }
    fn rememberFocus(self: *Control) void {
        const body = self.bodies[index(self.page)].as(gtk.Widget);
        var widget = self.window.getFocus() orelse return;
        if (widget.isAncestor(body) == 0) return;
        while (widget != body) {
            if (widget.hasCssClass("pearl-authentication") != 0) return;
            // Prompts are never restoration targets, including their buttons.
            var ancestor: ?*gtk.Widget = widget;
            while (ancestor) |parent| : (ancestor = parent.getParent()) if (parent.hasCssClass("pearl-authentication") != 0) return;
            const name = std.mem.span(widget.getName());
            if (std.mem.startsWith(u8, name, focus_state.prefix)) {
                self.focus_ids[index(self.page)].set(name);
                return;
            }
            widget = widget.getParent() orelse return;
        }
    }
    fn expander(widget: *gtk.Widget) ?*gtk.Expander {
        if (object.ext.cast(gtk.Expander, widget)) |item| return item;
        var child = widget.getFirstChild();
        while (child) |item| : (child = item.getNextSibling()) if (expander(item)) |found| return found;
        return null;
    }
    fn applyExpansion(self: *Control) void {
        if (expander(self.bodies[index(self.page)].as(gtk.Widget))) |item| item.setExpanded(@intFromBool(self.expanded[index(self.page)]));
    }
    fn leavePage(self: *Control) void {
        self.cancelRestore();
        self.rememberFocus();
        const i = index(self.page);
        self.positions[i] = self.viewports[i].getVadjustment().getValue();
        if (expander(self.bodies[i].as(gtk.Widget))) |item| self.expanded[i] = item.getExpanded() != 0;
        self.destroyPage();
    }
    fn cancelRestore(self: *Control) void {
        if (self.restore_tick != 0) self.stack.as(gtk.Widget).removeTickCallback(self.restore_tick);
        self.restore_tick = 0;
    }
    fn queueRestore(self: *Control, position: navigation.Position) void {
        self.cancelRestore();
        self.restore_position = position;
        self.restore_frames = 0;
        if (position == .heading) {
            self.positions[index(self.page)] = 0;
            self.focus_ids[index(self.page)] = .{};
        }
        self.restore_tick = self.stack.as(gtk.Widget).addTickCallback(restoreFrame, self, null);
    }
    fn restoreFrame(_: *gtk.Widget, _: *@import("gdk4").FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Control = @ptrCast(@alignCast(data.?));
        self.restore_frames += 1;
        if (self.restore_frames == 1) return 1;
        const i = index(self.page);
        if (self.restore_frames == 2) {
            const target = if (self.restore_position == .restore and self.focus_ids[i].len != 0) focus_state.find(self.bodies[i].as(gtk.Widget), self.focus_ids[i].slice()) else null;
            if (target) |widget| {
                if (widget.grabFocus() == 0) _ = self.heading_focus.grabFocus();
            } else _ = self.heading_focus.grabFocus();
        }
        const adjustment = self.viewports[i].getVadjustment();
        adjustment.setValue(@min(self.positions[i], @max(0, adjustment.getUpper() - adjustment.getPageSize())));
        if (self.restore_frames < 3) return 1;
        self.heading.as(gtk.Accessible).announce(title(self.page), .low);
        self.restore_tick = 0;
        return 0;
    }
    pub fn selectPage(self: *Control, page: navigation.Route, position: navigation.Position) !void {
        if (!page.isCompact()) return error.InvalidRoute;
        if (self.changing) return;
        if (self.page == page) {
            if (position == .heading) self.queueRestore(.heading);
            return;
        }
        self.changing = true;
        defer self.changing = false;
        self.leavePage();
        self.page = page;
        self.enterPage() catch |err| {
            self.bodies[index(page)].append(w.label(tr("Unable to open this section. Choose another section to retry.", "Bereich kann nicht geöffnet werden. Bitte einen anderen Bereich wählen und erneut versuchen."), "pearl-secondary").as(gtk.Widget));
            std.log.err("event=settings-page-failed page={s} error={s}", .{ page.id(), @errorName(err) });
        };
        self.stack.setVisibleChildName(page.id());
        self.heading.setText(title(page));
        w.name(self.heading_focus, title(page));
        self.applyExpansion();
        self.queueRestore(position);
        self.changing = false;
        self.update();
        if (@import("build_options").test_hooks) std.log.info("event=settings-page page={s}", .{page.id()});
    }
    pub fn destroy(self: *Control) void {
        self.changing = true;
        self.cancelRestore();
        if (self.focus_signal != 0) object.signalHandlerDisconnect(self.window.as(object.Object), self.focus_signal);
        self.leavePage();
        self.handoff_message.as(object.Object).unref();
        a.destroy(self);
    }
    fn nightToggled(_: *gtk.ToggleButton, self: *Control) callconv(.c) void {
        if (self.night_updating) return;
        self.models.night_light.?.act(.toggle) catch {};
        self.update();
    }
    fn nightResumed(_: *gtk.Button, self: *Control) callconv(.c) void {
        self.models.night_light.?.act(.@"resume") catch {};
        self.update();
    }
    fn nightSettings(_: *gtk.Button, self: *Control) callconv(.c) void {
        self.task(self.context, .night_settings);
    }
    pub fn update(self: *Control) void {
        if (self.changing) return;
        if (self.night_label) |label| {
            const night = self.models.night_light.?;
            label.setText(switch (night.state()) {
                .active => tr("Night Light is active.", "Nachtlicht ist aktiv."),
                .partial => tr("Night Light is active on some displays.", "Nachtlicht ist auf einigen Bildschirmen aktiv."),
                .pending => tr("Applying warmer colors…", "Wärmere Farben werden angewendet…"),
                .restoring => tr("Restoring display colors…", "Bildschirmfarben werden wiederhergestellt…"),
                .failed => tr("Display colors could not be updated.", "Bildschirmfarben konnten nicht aktualisiert werden."),
                .scheduled => tr("Waiting for the saved schedule.", "Warten auf den gespeicherten Zeitplan."),
                .off => tr("Night Light is off.", "Nachtlicht ist aus."),
                .unavailable => tr("Warming is unavailable on these displays.", "Nachtlicht ist auf diesen Bildschirmen nicht verfügbar."),
            });
            self.night_resume.?.as(gtk.Widget).setVisible(@intFromBool(night.model.override != null));
            if (self.night_toggle) |toggle| {
                const wanted = @intFromBool(night.requested);
                if (toggle.getActive() != wanted) {
                    self.night_updating = true;
                    toggle.setActive(wanted);
                    self.night_updating = false;
                }
                toggle.as(gtk.Widget).setSensitive(@intFromBool(night.interactive and (night.requested or night.warming.available())));
            }
        }
        if (self.volume_scale) |scale| {
            const audio = self.models.audio;
            const sink = audio.default(.sink);
            scale.as(gtk.Widget).setSensitive(@intFromBool(sink != null and sink.?.writable));
            if (!(audio.active != null or audio.queue.len > 0 or audio.feedback != null)) {
                self.sliders_updating = true;
                if (sink) |device| scale.as(gtk.Range).setValue(@floatFromInt(device.volume));
                self.sliders_updating = false;
            }
        }
        if (self.brightness_scale) |scale| {
            const power = self.models.power;
            scale.as(gtk.Widget).setSensitive(@intFromBool(power.brightnessAvailable()));
            if (!power.brightness_pending and power.brightness_wanted == null and power.feedback == null) {
                self.sliders_updating = true;
                scale.as(gtk.Range).setValue(@floatFromInt(power.backlight.percent()));
                self.sliders_updating = false;
            }
        }
        const life = self.models.lifecycle;
        const logout_pending = life.pending != null and life.pending.? == .logout;
        self.logout_button.as(gtk.Widget).setSensitive(@intFromBool(life.gate.available and life.gate.active and !life.gate.locked and life.client.capabilities.commands));
        self.logout_button.as(gtk.Widget).setTooltipText(if (logout_pending) tr("Confirm log out", "Abmelden bestätigen") else tr("Log out", "Abmelden"));
        if (logout_pending) self.logout_button.as(gtk.Widget).addCssClass("pearl-selected") else self.logout_button.as(gtk.Widget).removeCssClass("pearl-selected");
        const power = self.models.power;
        _ = self.power_confirm.valid(power.epoch(), glib.getMonotonicTime());
        for ([_]*gtk.Button{ self.reboot_button, self.off_button }, [_]bool{ true, false }) |button, reboot| {
            const can_act = if (reboot) power.can_reboot else power.can_off;
            const armed = self.power_confirm.action != null and self.power_confirm.action.? == reboot;
            button.as(gtk.Widget).setSensitive(@intFromBool(can_act and !power.action_pending and !power.preparing));
            button.as(gtk.Widget).setTooltipText(if (armed) (if (reboot) tr("Confirm restart", "Neustart bestätigen") else tr("Confirm power off", "Ausschalten bestätigen")) else if (can_act) (if (reboot) tr("Restart after confirmation", "Neustart nach Bestätigung") else tr("Power off after confirmation", "Ausschalten nach Bestätigung")) else (if (reboot) tr("Restart is unavailable or requires permission", "Neustart ist nicht verfügbar oder erfordert eine Berechtigung") else tr("Power off is unavailable or requires permission", "Ausschalten ist nicht verfügbar oder erfordert eine Berechtigung")));
            if (armed) button.as(gtk.Widget).addCssClass("pearl-selected") else button.as(gtk.Widget).removeCssClass("pearl-selected");
        }
        for (self.tabs, pages) |tab, page| tab.setActive(@intFromBool(page == self.page));
        if (self.lifecycle) |view| view.update();
        if (self.sound) |view| view.update();
        if (self.power) |view| view.update();
        if (self.connection) |view| view.update();
        const label = self.label orelse return;
        const layout = self.layout;
        var buffer: [100]u8 = undefined;
        const text = if (layout.manager != null) tr("Waiting for Aqueous…", "Warten auf Aqueous…") else if (layout.global == null or layout.err != null) tr("Layout unavailable. Refresh to retry.", "Anordnung nicht verfügbar. Bitte aktualisieren.") else if (layout.value_len == 0) tr("Querying the active workspace", "Aktive Arbeitsfläche wird abgefragt") else std.fmt.bufPrintZ(&buffer, "{s} · {d}", .{ layout.value[0..layout.value_len], layout.workspace }) catch unreachable;
        label.setText(text);
        for (self.buttons, native.names) |button, name| {
            button.as(gtk.Widget).setSensitive(@intFromBool(layout.manager == null and layout.global != null));
            if (std.mem.eql(u8, name, layout.value[0..layout.value_len])) button.as(gtk.Widget).addCssClass("pearl-selected") else button.as(gtk.Widget).removeCssClass("pearl-selected");
        }
    }
    pub fn probe(self: *Control, window: *gtk.Window) void {
        if (self.power) |view| view.probe(window);
        if (self.connection) |view| view.probe(window);
        const focus = window.getFocus();
        if (focus == self.probe_focus) return;
        self.probe_focus = focus;
        const target = self.focusName(window);
        std.log.info("event=settings-focus target={s}", .{target});
    }
    fn focusName(self: *Control, window: *gtk.Window) []const u8 {
        const focus = window.getFocus() orelse return "none";
        return if (focus == self.heading_focus) "heading" else "body";
    }
    fn focusedButton(window: *gtk.Window) ?[]const u8 {
        const focus = window.getFocus() orelse return null;
        const button = object.ext.cast(gtk.Button, focus) orelse if (focus.getAncestor(gtk.Button.getGObjectType())) |ancestor| object.ext.cast(gtk.Button, ancestor).? else return null;
        return if (button.getLabel()) |label| std.mem.span(label) else null;
    }
    fn focusedTab(window: *gtk.Window) []const u8 {
        const focus = window.getFocus() orelse return "";
        const tab = object.ext.cast(gtk.ToggleButton, focus) orelse if (focus.getAncestor(gtk.ToggleButton.getGObjectType())) |ancestor| object.ext.cast(gtk.ToggleButton, ancestor).? else return "";
        if (tab.as(gtk.Widget).hasCssClass("pearl-tab") == 0) return "";
        return if (tab.as(gtk.Button).getLabel()) |label| std.mem.span(label) else "";
    }
    fn focusedHeader(self: *Control, window: *gtk.Window) []const u8 {
        const focus = window.getFocus() orelse return "";
        if (focus.isAncestor(self.header) == 0) return "";
        const button = object.ext.cast(gtk.Button, focus) orelse return "";
        return if (button.as(gtk.Widget).getTooltipText()) |tooltip| std.mem.span(tooltip) else "";
    }
    // Private read-only evidence from the actual widget tree. Never inspect
    // editable widgets or their children, so credential text cannot be exposed.
    pub fn report(self: *Control, window: *gtk.Window, alloc: std.mem.Allocator) ![]const u8 {
        var labels: std.ArrayList([]const u8) = .empty;
        defer labels.deinit(alloc);
        const body = self.bodies[index(self.page)].as(gtk.Widget);
        try collectLabels(body, alloc, &labels);
        const scroll = self.viewports[index(self.page)];
        const panel = self.stack.as(gtk.Widget).getParent().?;
        var populated: usize = 0;
        for (self.bodies) |box| if (box.as(gtk.Widget).getFirstChild() != null) {
            populated += 1;
        };
        return std.json.Stringify.valueAlloc(alloc, .{ .handoff_available = self.settings_button.as(gtk.Widget).getSensitive() != 0, .handoff_error = std.mem.span(self.handoff_message.getText()), .page = self.page, .heading = std.mem.span(self.heading.getText()), .focus = self.focusName(window), .button = focusedButton(window), .tab = focusedTab(window), .header = self.focusedHeader(window), .saved_focus = self.focus_ids[index(self.page)].slice(), .restoring = self.restore_tick != 0, .labels = labels.items, .populated_pages = populated, .viewports = self.viewports.len, .panel_width = panel.getAllocatedWidth(), .panel_height = panel.getAllocatedHeight(), .header_height = self.header.getHeight(), .body_width = scroll.as(gtk.Widget).getWidth(), .body_height = scroll.as(gtk.Widget).getHeight(), .scroll = scroll.getVadjustment().getValue(), .scroll_upper = scroll.getVadjustment().getUpper(), .scroll_page_size = scroll.getVadjustment().getPageSize(), .interest = .{ .network = self.models.network.interest.count() != 0, .bluetooth = self.models.bluetooth.interest.count() != 0, .power = self.models.power.panel_open } }, .{});
    }
    fn collectLabels(widget: *gtk.Widget, alloc: std.mem.Allocator, labels: *std.ArrayList([]const u8)) !void {
        if (labels.items.len >= 32 or widget.getVisible() == 0 or widget.hasCssClass("pearl-authentication") != 0 or object.ext.cast(gtk.PasswordEntry, widget) != null or object.ext.cast(gtk.Entry, widget) != null) return;
        if (object.ext.cast(gtk.Label, widget)) |label| {
            const text = std.mem.span(label.getText());
            if (text.len <= 128) try labels.append(alloc, text);
        }
        var child = widget.getFirstChild();
        while (child) |item| : (child = item.getNextSibling()) try collectLabels(item, alloc, labels);
    }
    fn taskClicked(_: *gtk.Button, link: *TaskLink) callconv(.c) void {
        link.owner.task(link.owner.context, link.task);
    }
    fn selected(_: *gtk.Button, choice: *Choice) callconv(.c) void {
        choice.owner.action(choice.owner.context, choice.name);
    }
    fn refreshed(_: *gtk.Button, self: *Control) callconv(.c) void {
        self.action(self.context, null);
    }
    fn volumeChanged(range: *gtk.Range, self: *Control) callconv(.c) void {
        if (self.sliders_updating) return;
        const audio = self.models.audio;
        const device = audio.default(.sink) orelse return;
        audio.request(.{ .key = device.key, .volume = @intFromFloat(range.getValue()) }) catch {};
    }
    fn brightnessChanged(range: *gtk.Range, self: *Control) callconv(.c) void {
        if (self.sliders_updating) return;
        self.models.power.setBrightness(@intFromFloat(range.getValue())) catch {};
    }
};
