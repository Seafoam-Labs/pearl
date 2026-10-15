//! Persistent Power controls; telemetry updates never rebuild editable widgets.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const cairo = @import("cairo1");
const w = @import("../ui/components/widgets.zig");
const ui = @import("live_protocol.zig");
const model = @import("../services/power_presentation.zig");
const patch = @import("../config/power_patch.zig");
const Editor = @import("editor.zig").Editor;
const a = std.heap.c_allocator;
const Connection = struct { obj: *object.Object, id: c_ulong };
pub const Control = struct { id: []const u8, widget: *gtk.Widget };
const Binding = struct { view: *View, index: usize };
const Action = struct { view: *View, button: *gtk.Button, id: []const u8, spec: ?ui.Control = null };
const durations = [_]u32{ 0, 60, 300, 600, 900, 1800, 3600 };

pub const View = struct {
    editor: *Editor,
    window: *gtk.Window,
    lease: u64,
    root: *gtk.Box,
    status: *gtk.Label,
    battery: *gtk.Box,
    percentage: *gtk.Label,
    charge: *gtk.Label,
    estimate: *gtk.Label,
    battery_icon: *gtk.LevelBar,
    health: *gtk.Label,
    history_label: *gtk.Label,
    chart: *gtk.DrawingArea,
    modes: [3]*gtk.CheckButton = undefined,
    profile_bindings: [3]Binding = undefined,
    mode_detail: *gtk.Label,
    brightness: *gtk.Scale,
    percent: *gtk.Label,
    brightness_detail: *gtk.Label,
    dim: *gtk.Switch,
    source_row: *gtk.FlowBox,
    source: *gtk.DropDown,
    timeouts: [2]*gtk.DropDown = undefined,
    time_bindings: [2]Binding = undefined,
    custom: [2]?u32 = @splat(null),
    saver_row: *gtk.FlowBox,
    saver: *gtk.DropDown,
    sleep_status: *gtk.Label,
    locking: ?*gtk.Button = null,
    actions: [11]Action = undefined,
    action_detail: *gtk.Label,
    action_popover: ?*gtk.Popover = null,
    connections: std.ArrayList(Connection) = .empty,
    controls: std.ArrayList(Control) = .empty,
    arena: std.heap.ArenaAllocator,
    snapshot: model.Snapshot = .{},
    battery_selected: bool = false,
    initialized: bool = false,
    filling: bool = false,
    german: bool,
    wanted: ?u8 = null,
    brightness_target: ?u8 = null,
    wanted_generation: u64 = 0,
    timer: c_uint = 0,
    deadline: i64 = 0,

    fn t(self: *const View, en: [:0]const u8, de: [:0]const u8) [:0]const u8 {
        return if (self.german) de else en;
    }
    fn format(self: *const View, buffer: []u8, comptime en: []const u8, comptime de: []const u8, args: anytype) [:0]const u8 {
        return (if (self.german) std.fmt.bufPrintZ(buffer, de, args) else std.fmt.bufPrintZ(buffer, en, args)) catch "";
    }
    fn card() *gtk.Box {
        const box = w.column(12);
        box.as(gtk.Widget).addCssClass("power-card");
        return box;
    }
    fn section(self: *View, en: [:0]const u8, de: [:0]const u8) *gtk.Box {
        const box = w.column(8);
        box.append(w.label(self.t(en, de), "pearl-section-title").as(gtk.Widget));
        self.root.append(box.as(gtk.Widget));
        return box;
    }
    fn row(host: *gtk.Box, title: [:0]const u8, widget: *gtk.Widget) *gtk.FlowBox {
        const line = w.flow(2);
        line.setHomogeneous(0);
        const label = w.label(title, null);
        label.as(gtk.Widget).setHexpand(1);
        line.insert(label.as(gtk.Widget), -1);
        widget.setHalign(.end);
        widget.setValign(.center);
        line.insert(widget, -1);
        host.append(line.as(gtk.Widget));
        w.name(widget, title);
        return line;
    }
    fn control(self: *View, id: []const u8, widget: *gtk.Widget) !void {
        try self.controls.append(a, .{ .id = id, .widget = widget });
    }
    fn remember(self: *View, widget: anytype, id: c_ulong) !void {
        try self.connections.append(a, .{ .obj = widget.as(object.Object), .id = id });
    }

    pub fn create(host: *gtk.Box, window: *gtk.Window, editor: *Editor) !*View {
        const self = try a.create(View);
        const locale = if (glib.getenv("LANG")) |value| std.mem.span(value) else "";
        const root = w.column(16);
        root.as(gtk.Widget).addCssClass("power-view");
        const battery = card();
        const percentage = w.label("", "power-percentage");
        const charge = w.label("", "settings-row-title");
        const estimate = w.label("", "pearl-secondary");
        const health = w.label("", "pearl-secondary");
        const history_label = w.label("", "pearl-secondary");
        const chart = gtk.DrawingArea.new();
        chart.setContentHeight(70);
        chart.as(gtk.Widget).addCssClass("power-chart");
        const battery_icon = gtk.LevelBar.newForInterval(0, 100);
        battery_icon.as(gtk.Widget).addCssClass("power-battery-icon");
        const status = w.label("", "pearl-secondary");
        const mode_detail = w.label("", "pearl-secondary");
        const brightness = gtk.Scale.newWithRange(.horizontal, 1, 100, 1);
        brightness.setDrawValue(0);
        brightness.as(gtk.Widget).setHexpand(1);
        const percent = w.label("", null);
        percent.as(gtk.Widget).setHexpand(0);
        const brightness_detail = w.label("", "pearl-secondary");
        const dim = gtk.Switch.new();
        const source = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "On battery", "Plugged in", null }));
        const saver = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "Off", "Below 10%", "Below 20%", "Below 30%", null }));
        const sleep_status = w.label("", "pearl-secondary");
        const action_detail = w.label("", "pearl-secondary");
        self.* = .{ .editor = editor, .window = window, .lease = editor.view, .root = root, .status = status, .battery = battery, .percentage = percentage, .charge = charge, .estimate = estimate, .health = health, .history_label = history_label, .chart = chart, .battery_icon = battery_icon, .mode_detail = mode_detail, .brightness = brightness, .percent = percent, .brightness_detail = brightness_detail, .dim = dim, .source = source, .source_row = undefined, .saver = saver, .saver_row = undefined, .sleep_status = sleep_status, .action_detail = action_detail, .arena = .init(a), .german = std.mem.startsWith(u8, locale, "de") };
        host.append(root.as(gtk.Widget));
        errdefer {
            self.destroy();
            host.remove(root.as(gtk.Widget));
        }
        root.append(status.as(gtk.Widget));
        root.append(battery.as(gtk.Widget));
        try self.control("power/battery", battery.as(gtk.Widget));
        const battery_layout = w.flow(2);
        battery_layout.setHomogeneous(1);
        const summary = w.column(6);
        const hero = w.row(18);
        battery_icon.as(gtk.Widget).setSizeRequest(100, 32);
        battery_icon.as(gtk.Widget).setValign(.center);
        hero.append(battery_icon.as(gtk.Widget));
        hero.append(percentage.as(gtk.Widget));
        summary.append(hero.as(gtk.Widget));
        summary.append(charge.as(gtk.Widget));
        summary.append(estimate.as(gtk.Widget));
        battery_layout.insert(summary.as(gtk.Widget), -1);
        const history = w.column(8);
        history.append(history_label.as(gtk.Widget));
        history.append(chart.as(gtk.Widget));
        history.append(health.as(gtk.Widget));
        battery_layout.insert(history.as(gtk.Widget), -1);
        battery.append(battery_layout.as(gtk.Widget));
        chart.setDrawFunc(draw, self, null);
        const modes = self.section("Power mode", "Energiemodus");
        const mode_flow = w.flow(3);
        mode_flow.setHomogeneous(1);
        const titles = if (self.german) [_][:0]const u8{ "Energiesparen", "Ausgeglichen", "Leistung" } else [_][:0]const u8{ "Power saver", "Balanced", "Performance" };
        const details = if (self.german) [_][:0]const u8{ "Akkulaufzeit verlängern", "Leistung nach Bedarf", "Geschwindigkeit bevorzugen" } else [_][:0]const u8{ "Extend battery life", "Performance when you need it", "Prioritize speed" };
        for (0..3) |i| {
            const button = gtk.CheckButton.new();
            if (i > 0) button.setGroup(self.modes[0]);
            const labels = w.column(5);
            labels.append(w.label(titles[i], "settings-row-title").as(gtk.Widget));
            labels.append(w.label(details[i], "pearl-secondary").as(gtk.Widget));
            button.setChild(labels.as(gtk.Widget));
            button.as(gtk.Widget).addCssClass("power-mode");
            mode_flow.insert(button.as(gtk.Widget), -1);
            self.modes[i] = button;
            self.profile_bindings[i] = .{ .view = self, .index = i };
            try self.remember(button, gtk.CheckButton.signals.toggled.connect(button, *Binding, modeChanged, &self.profile_bindings[i], .{}));
            try self.control(([_][]const u8{ "power/power-saver", "power/balanced", "power/performance" })[i], button.as(gtk.Widget));
            w.name(button.as(gtk.Widget), titles[i]);
        }
        modes.append(mode_flow.as(gtk.Widget));
        modes.append(mode_detail.as(gtk.Widget));
        const display = card();
        self.section("Display", "Bildschirm").append(display.as(gtk.Widget));
        const slider = w.row(12);
        slider.append(w.icon("pearl-display-brightness-symbolic").as(gtk.Widget));
        const brightness_label = w.label(self.t("Brightness", "Helligkeit"), null);
        brightness_label.as(gtk.Widget).setHexpand(0);
        slider.append(brightness_label.as(gtk.Widget));
        slider.append(brightness.as(gtk.Widget));
        slider.append(percent.as(gtk.Widget));
        display.append(slider.as(gtk.Widget));
        display.append(brightness_detail.as(gtk.Widget));
        _ = row(display, self.t("Dim screen when inactive", "Bildschirm bei Inaktivität dimmen"), dim.as(gtk.Widget));
        display.append(w.label(self.t("Reduce brightness before the screen turns off", "Helligkeit vor dem Ausschalten reduzieren"), "pearl-secondary").as(gtk.Widget));
        w.name(brightness.as(gtk.Widget), self.t("Brightness", "Helligkeit"));
        try self.control("power/brightness", brightness.as(gtk.Widget));
        try self.control("power/dim", dim.as(gtk.Widget));
        try self.remember(brightness, gtk.Range.signals.value_changed.connect(brightness.as(gtk.Range), *View, brightnessChanged, self, .{}));
        try self.remember(dim, object.Object.signals.notify.connect(dim.as(object.Object), *View, dimChanged, self, .{ .detail = "active" }));
        const sleep = card();
        self.section("Sleep & energy saving", "Ruhezustand und Energiesparen").append(sleep.as(gtk.Widget));
        if (self.german) {
            const strings = gtk.StringList.new(@ptrCast(&[_]?[*:0]const u8{ "Akkubetrieb", "Netzbetrieb", null }));
            source.setModel(strings.as(gio.ListModel));
            strings.unref();
            const thresholds = gtk.StringList.new(@ptrCast(&[_]?[*:0]const u8{ "Aus", "Unter 10%", "Unter 20%", "Unter 30%", null }));
            saver.setModel(thresholds.as(gio.ListModel));
            thresholds.unref();
        }
        self.source_row = row(sleep, self.t("Settings for", "Einstellungen für"), source.as(gtk.Widget));
        try self.control("power/source", source.as(gtk.Widget));
        try self.remember(source, object.Object.signals.notify.connect(source.as(object.Object), *View, sourceChanged, self, .{ .detail = "selected" }));
        for (0..2) |i| {
            self.timeouts[i] = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "Never", "1 minute", "5 minutes", "10 minutes", "15 minutes", "30 minutes", "1 hour", "Custom", null }));
            self.time_bindings[i] = .{ .view = self, .index = i };
            _ = row(sleep, if (i == 0) self.t("Turn screen off after", "Bildschirm ausschalten nach") else self.t("Suspend after", "Bereitschaft nach"), self.timeouts[i].as(gtk.Widget));
            try self.control(if (i == 0) "power/screen-off" else "power/suspend-after", self.timeouts[i].as(gtk.Widget));
            try self.remember(self.timeouts[i], object.Object.signals.notify.connect(self.timeouts[i].as(object.Object), *Binding, timeoutChanged, &self.time_bindings[i], .{ .detail = "selected" }));
        }
        self.saver_row = row(sleep, self.t("Automatic power saver", "Automatisches Energiesparen"), saver.as(gtk.Widget));
        try self.control("power/automatic-saver", saver.as(gtk.Widget));
        try self.remember(saver, object.Object.signals.notify.connect(saver.as(object.Object), *View, saverChanged, self, .{ .detail = "selected" }));
        sleep.append(sleep_status.as(gtk.Widget));
        const locking = w.wrappingButton(self.t("Session & lock settings", "Einstellungen für Sitzung und Sperre"));
        self.locking = locking;
        locking.as(gtk.Widget).setHalign(.start);
        locking.as(gtk.Widget).addCssClass("flat");
        sleep.append(locking.as(gtk.Widget));
        try self.control("power/locking", locking.as(gtk.Widget));
        try self.remember(locking, gtk.Button.signals.clicked.connect(locking, *View, lockingClicked, self, .{}));
        const actions = card();
        root.append(actions.as(gtk.Widget));
        actions.append(w.label(self.t("Session actions", "Sitzungsaktionen"), "settings-row-title").as(gtk.Widget));
        const action_flow = w.flow(3);
        const more = gtk.MenuButton.new();
        more.setLabel(self.t("More", "Mehr"));
        const popover = gtk.Popover.new();
        const menu = w.column(6);
        popover.setChild(menu.as(gtk.Widget));
        more.setPopover(popover);
        self.action_popover = popover;
        for ([_][]const u8{ "lock", "suspend", "hibernate", "logout", "inhibit", "shutdown", "reboot", "confirm", "cancel", "power-cancel", "power-confirm" }, 0..) |id, i| {
            const button = w.wrappingButton("");
            self.actions[i] = .{ .view = self, .button = button, .id = id };
            if (i < 2 or i >= 7) action_flow.insert(button.as(gtk.Widget), -1) else menu.append(button.as(gtk.Widget));
            try self.remember(button, gtk.Button.signals.clicked.connect(button, *Action, actionClicked, &self.actions[i], .{}));
            try self.control(([_][]const u8{ "session/lock", "session/suspend", "session/hibernate", "session/logout", "session/inhibit", "session/shutdown", "session/reboot", "session/confirm", "session/cancel", "session/power-cancel", "session/power-confirm" })[i], button.as(gtk.Widget));
        }
        action_flow.insert(more.as(gtk.Widget), -1);
        actions.append(action_flow.as(gtk.Widget));
        actions.append(action_detail.as(gtk.Widget));
        try self.control("session/more", more.as(gtk.Widget));
        return self;
    }
    pub fn cancel(self: *View) void {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.timer = 0;
        self.wanted = null;
        self.brightness_target = null;
    }
    pub fn destroy(self: *View) void {
        self.cancel();
        self.chart.setDrawFunc(null, null, null);
        for (self.connections.items) |c| object.signalHandlerDisconnect(c.obj, c.id);
        self.connections.deinit(a);
        self.controls.deinit(a);
        self.arena.deinit();
        a.destroy(self);
    }
    fn visibility(self: *View, widget: *gtk.Widget, visible: bool) void {
        if (!visible) if (self.window.getFocus()) |focus| if (focus == widget or focus.isAncestor(widget) != 0) {
            _ = self.modes[1].as(gtk.Widget).grabFocus();
        };
        widget.setVisible(@intFromBool(visible));
    }
    pub fn update(self: *View, snapshot: model.Snapshot, rows: []const ui.Row) void {
        self.filling = true;
        defer self.filling = false;
        var next = std.heap.ArenaAllocator.init(a);
        const alloc = next.allocator();
        const encoded = std.json.Stringify.valueAlloc(alloc, snapshot, .{}) catch {
            next.deinit();
            return;
        };
        const copied = std.json.parseFromSliceLeaky(model.Snapshot, alloc, encoded, .{}) catch {
            next.deinit();
            return;
        };
        self.arena.deinit();
        self.arena = next;
        self.snapshot = copied;
        const s = self.snapshot;
        if (!self.initialized) self.battery_selected = s.battery_present and s.on_battery;
        if (!s.battery_present) self.battery_selected = false;
        self.initialized = true;
        self.visibility(self.battery.as(gtk.Widget), s.battery_present);
        self.visibility(self.source_row.as(gtk.Widget), s.battery_present);
        self.visibility(self.saver_row.as(gtk.Widget), s.battery_present);
        var buf: [512]u8 = undefined;
        self.percentage.setText(if (s.percentage) |n| std.fmt.bufPrintZ(&buf, "{d:.0}%", .{n}) catch "" else self.t("Charge unavailable", "Ladestand unbekannt"));
        self.battery_icon.setValue(s.percentage orelse 0);
        self.battery_icon.as(gtk.Widget).setVisible(@intFromBool(s.percentage != null));
        self.charge.setText(switch (s.state) {
            1 => self.t("Charging", "Wird geladen"),
            2 => self.t("On battery", "Akkubetrieb"),
            4 => self.t("Fully charged", "Vollständig geladen"),
            else => self.t("Battery", "Akku"),
        });
        self.estimate.setText(if (s.estimate > 0) (if (s.state == 1) self.format(&buf, "About {d} h {d} min until full", "Noch etwa {d} Std. {d} Min. bis voll", .{ @divTrunc(s.estimate, 3600), @divTrunc(@mod(s.estimate, 3600), 60) }) else self.format(&buf, "About {d} h {d} min remaining", "Noch etwa {d} Std. {d} Min.", .{ @divTrunc(s.estimate, 3600), @divTrunc(@mod(s.estimate, 3600), 60) })) else "");
        self.health.setText(if (s.health) |n| self.format(&buf, "Battery health: {s} ({d:.0}%)", "Akkuzustand: {s} ({d:.0}%)", .{ if (n >= 80) self.t("Good", "Gut") else self.t("Reduced", "Verringert"), n }) else self.t("Battery health unavailable", "Akkuzustand unbekannt"));
        const span = if (s.history.len > 1) s.history[s.history.len - 1].seconds - s.history[0].seconds else 0;
        self.history_label.setText(if (span >= 60) self.format(&buf, "Last {d} minutes · this session", "Letzte {d} Minuten · diese Sitzung", .{@divTrunc(span, 60)}) else self.t("Collecting battery history…", "Akkuverlauf wird erfasst…"));
        w.name(self.chart.as(gtk.Widget), self.history_label.getText());
        self.chart.as(gtk.Widget).queueDraw();
        for (self.modes, 0..) |mode, i| {
            const active = std.mem.eql(u8, s.profile, ([_][]const u8{ "power-saver", "balanced", "performance" })[i]);
            mode.setActive(@intFromBool(active));
            mode.as(gtk.Widget).setSensitive(@intFromBool(s.profiles[i] and !s.profile_pending));
            if (active) mode.as(gtk.Widget).addCssClass("power-selected") else mode.as(gtk.Widget).removeCssClass("power-selected");
            mode.as(gtk.Widget).setTooltipText(if (s.profiles[i]) null else self.t("This power mode is unavailable", "Dieser Energiemodus ist nicht verfügbar"));
        }
        self.mode_detail.setText(alloc.dupeZ(u8, if (s.profile_pending) self.t("Applying power mode…", "Energiemodus wird geändert…") else s.degraded) catch "");
        self.mode_detail.as(gtk.Widget).setVisible(@intFromBool(s.profile_pending or s.degraded.len > 0));
        const generation = std.fmt.parseInt(u64, s.brightness_generation, 10) catch 0;
        if (self.brightness_target != null and generation != self.wanted_generation) self.cancel();
        if (self.brightness_target) |target| {
            if (glib.getMonotonicTime() > self.deadline or (self.wanted == null and !s.brightness_pending and self.editor.live_command == null and s.brightness == target)) self.brightness_target = null;
        }
        if (self.brightness_target == null and self.wanted == null and !s.brightness_pending and self.editor.live_command == null) self.brightness.as(gtk.Range).setValue(@floatFromInt(s.brightness));
        self.brightness.as(gtk.Widget).setSensitive(@intFromBool(s.brightness_available));
        self.percent.setText(std.fmt.bufPrintZ(&buf, "{d:.0}%", .{self.brightness.as(gtk.Range).getValue()}) catch "");
        self.brightness_detail.setText(if (s.brightness_available) "" else self.t("Brightness control is unavailable for this display", "Helligkeitsregelung für diesen Bildschirm nicht verfügbar"));
        self.brightness_detail.as(gtk.Widget).setVisible(@intFromBool(!s.brightness_available));
        self.source.setSelected(if (self.battery_selected) 0 else 1);
        self.updateSettings();
        for (&self.actions) |*action| {
            action.spec = null;
            action.button.as(gtk.Widget).setVisible(0);
        }
        for (rows) |r| if (std.mem.eql(u8, r.id, "session")) {
            self.action_detail.setText(alloc.dupeZ(u8, r.detail) catch "");
            self.action_detail.as(gtk.Widget).setVisible(@intFromBool(r.detail.len > 0));
            for (r.controls) |spec| for (&self.actions) |*action| if (std.mem.eql(u8, action.id, spec.id) or (std.mem.eql(u8, action.id, "inhibit") and std.mem.eql(u8, spec.id, "uninhibit"))) {
                const params = alloc.dupe(u8, spec.params) catch continue;
                action.spec = spec;
                action.spec.?.params = params;
                action.button.setLabel(alloc.dupeZ(u8, self.actionLabel(spec)) catch "");
                action.button.as(gtk.Widget).setVisible(1);
                action.button.as(gtk.Widget).setSensitive(@intFromBool(spec.enabled));
                if (spec.op == .@"power.action") {
                    const confirmation = std.json.parseFromSliceLeaky(struct { confirmation: ?[]const u8 = null, cancel: bool = false }, alloc, params, .{ .ignore_unknown_fields = true }) catch continue;
                    if (confirmation.confirmation != null and !confirmation.cancel) {
                        const confirm = &self.actions[10];
                        confirm.spec = action.spec;
                        confirm.button.setLabel(alloc.dupeZ(u8, self.actionLabel(spec)) catch "");
                        confirm.button.as(gtk.Widget).setVisible(1);
                        confirm.button.as(gtk.Widget).setSensitive(@intFromBool(spec.enabled));
                        action.button.as(gtk.Widget).setVisible(0);
                    }
                }
                break;
            };
        };
        const message = if (s.saving) self.t("Saving power settings…", "Energieeinstellungen werden gespeichert…") else if (s.error_message.len > 0) s.error_message else if (!s.available) self.t("Battery service unavailable", "Akkudienst nicht verfügbar") else "";
        self.status.setText(alloc.dupeZ(u8, message) catch "");
        self.status.as(gtk.Widget).setVisible(@intFromBool(message.len > 0));
    }
    fn updateSettings(self: *View) void {
        const s = self.snapshot;
        const timers = if (self.battery_selected) s.config.battery else s.config.ac;
        if (self.locking) |locking| locking.as(gtk.Widget).setVisible(@intFromBool(timers.lock_seconds == 0));
        self.dim.setActive(@intFromBool(timers.dim));
        self.dim.as(gtk.Widget).setSensitive(@intFromBool(!s.saving and s.brightness_available and s.display_power_available and s.idle_available));
        for ([_]u32{ timers.screen_off_seconds, timers.suspend_seconds }, 0..) |seconds, i| {
            var index: u32 = durations.len;
            for (durations, 0..) |duration, j| if (seconds == duration) {
                index = @intCast(j);
                break;
            };
            if (self.custom[i] == null or (index == durations.len and self.custom[i].? != seconds)) {
                self.custom[i] = seconds;
                var buffer: [80]u8 = undefined;
                const label = self.format(&buffer, "Custom: {d} seconds", "Benutzerdefiniert: {d} Sekunden", .{seconds});
                const labels = if (self.german) [_]?[*:0]const u8{ "Nie", "1 Minute", "5 Minuten", "10 Minuten", "15 Minuten", "30 Minuten", "1 Stunde", label, null } else [_]?[*:0]const u8{ "Never", "1 minute", "5 minutes", "10 minutes", "15 minutes", "30 minutes", "1 hour", label, null };
                const strings = gtk.StringList.new(@ptrCast(&labels));
                self.timeouts[i].setModel(strings.as(gio.ListModel));
                strings.unref();
            }
            self.timeouts[i].setSelected(index);
            self.timeouts[i].as(gtk.Widget).setSensitive(@intFromBool(!s.saving and s.idle_available and (i == 1 or s.display_power_available)));
        }
        self.saver.setSelected(s.config.automatic_saver / 10);
        self.saver.as(gtk.Widget).setSensitive(@intFromBool(!s.saving and s.profiles[0]));
        const message = if (!s.idle_available) self.t("Idle notifications unavailable", "Inaktivitätsmeldungen nicht verfügbar") else if (!s.display_power_available) self.t("Screen power control unavailable", "Bildschirm-Energiesteuerung nicht verfügbar") else if (timers.lock_seconds == 0) self.t("Enable automatic locking in Session & lock before setting a suspend timeout.", "Vor automatischer Bereitschaft die automatische Sperre unter Sitzung und Sperre aktivieren.") else "";
        self.sleep_status.setText(message);
        self.sleep_status.as(gtk.Widget).setVisible(@intFromBool(message.len > 0));
    }
    fn send(self: *View, op: ui.Op, value: anytype) bool {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const params = std.json.parseFromSliceLeaky(std.json.Value, alloc, std.json.Stringify.valueAlloc(alloc, value, .{}) catch return false, .{}) catch return false;
        self.editor.liveAction(op, params) catch |err| {
            self.editor.error_code.set(@errorName(err));
            return false;
        };
        self.editor.error_code = .{};
        return true;
    }
    fn save(self: *View, field: patch.Field, value: u32) void {
        if (self.filling) return;
        _ = self.send(.@"power.settings", .{ .revision = self.snapshot.revision, .source = if (self.battery_selected) patch.Source.battery else patch.Source.ac, .field = field, .value = value });
        // Keep observed committed values until the backend acknowledges the save.
        self.filling = true;
        defer self.filling = false;
        self.updateSettings();
    }
    fn lockingClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.editor.navigate(.{ .page = .session }, false);
    }
    fn modeChanged(button: *gtk.CheckButton, binding: *Binding) callconv(.c) void {
        const self = binding.view;
        if (self.filling or button.getActive() == 0) return;
        _ = self.send(.@"profile.set", .{ .generation = self.snapshot.profile_generation, .profile = ([_][]const u8{ "power-saver", "balanced", "performance" })[binding.index] });
        self.filling = true;
        defer self.filling = false;
        for (self.modes, [_][]const u8{ "power-saver", "balanced", "performance" }) |mode, name| mode.setActive(@intFromBool(std.mem.eql(u8, self.snapshot.profile, name)));
    }
    fn sourceChanged(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        if (self.filling) return;
        self.battery_selected = self.snapshot.battery_present and self.source.getSelected() == 0;
        self.filling = true;
        defer self.filling = false;
        self.updateSettings();
    }
    fn dimChanged(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        self.save(.dim, @intFromBool(self.dim.getActive() != 0));
    }
    fn saverChanged(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        self.save(.automatic_saver, self.saver.getSelected() * 10);
    }
    fn timeoutChanged(_: *object.Object, _: *object.ParamSpec, b: *Binding) callconv(.c) void {
        const index = b.view.timeouts[b.index].getSelected();
        if (index >= durations.len) return;
        b.view.save(if (b.index == 0) .screen_off_seconds else .suspend_seconds, durations[index]);
    }
    fn brightnessChanged(range: *gtk.Range, self: *View) callconv(.c) void {
        if (self.filling) return;
        self.wanted = @intFromFloat(range.getValue());
        self.brightness_target = self.wanted;
        self.wanted_generation = std.fmt.parseInt(u64, self.snapshot.brightness_generation, 10) catch return;
        self.deadline = glib.getMonotonicTime() + 5_000_000;
        var buffer: [16]u8 = undefined;
        self.percent.setText(std.fmt.bufPrintZ(&buffer, "{d}%", .{self.wanted.?}) catch "");
        if (self.timer == 0) self.timer = glib.timeoutAdd(80, dispatch, self);
    }
    fn dispatch(data: ?*anyopaque) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(data.?));
        if (!self.editor.online or self.editor.suspended or self.editor.state.locked or self.editor.view != self.lease or self.editor.target.page != .power or glib.getMonotonicTime() > self.deadline) {
            self.timer = 0;
            self.wanted = null;
            return 0;
        }
        if (self.editor.live_command != null) return 1;
        if (self.wanted) |value| {
            if (!self.send(.@"brightness.set", .{ .generation = @import("editor_protocol.zig").num(self.wanted_generation), .percent = value }) and std.mem.eql(u8, self.editor.error_code.slice(), "Busy")) return 1;
        }
        self.wanted = null;
        self.timer = 0;
        return 0;
    }
    fn actionClicked(_: *gtk.Button, action: *Action) callconv(.c) void {
        const spec = action.spec orelse return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const params = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), spec.params, .{}) catch return;
        action.view.editor.liveAction(spec.op, params) catch |err| {
            action.view.editor.error_code.set(@errorName(err));
        };
        if (action.view.action_popover) |popover| popover.popdown();
    }
    fn actionLabel(self: *const View, spec: ui.Control) []const u8 {
        if (!self.german) return spec.label;
        if (std.mem.startsWith(u8, spec.label, "Confirm")) return if (std.mem.eql(u8, spec.id, "reboot")) "Neustart bestätigen" else if (std.mem.eql(u8, spec.id, "shutdown")) "Ausschalten bestätigen" else "Sitzungsaktion bestätigen";
        const ids = [_][]const u8{ "lock", "suspend", "hibernate", "logout", "inhibit", "uninhibit", "shutdown", "reboot", "cancel", "power-cancel" };
        const labels = [_][]const u8{ "Sperren", "Bereitschaft", "Ruhezustand", "Abmelden…", "Automatische Inaktivität pausieren", "Automatische Inaktivität fortsetzen", "Ausschalten…", "Neustart…", "Abbrechen", "Energieaktion abbrechen" };
        for (ids, labels) |id, label| if (std.mem.eql(u8, spec.id, id)) return label;
        return spec.label;
    }
    fn draw(area: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(data.?));
        const points = self.snapshot.history;
        var color: gdk.RGBA = undefined;
        area.as(gtk.Widget).getColor(&color);
        const wide: f64 = @floatFromInt(width);
        const tall: f64 = @floatFromInt(height);
        cr.setSourceRgba(color.f_red, color.f_green, color.f_blue, 0.2);
        cr.setLineWidth(1);
        for ([_]f64{ 0, 0.5, 1 }) |fraction| {
            cr.moveTo(0, 2 + fraction * (tall - 4));
            cr.lineTo(wide, 2 + fraction * (tall - 4));
        }
        cr.stroke();
        if (points.len < 2) return;
        const span = @max(60, points[points.len - 1].seconds - points[0].seconds);
        cr.setSourceRgba(color.f_red, color.f_green, color.f_blue, 1);
        cr.setLineWidth(2);
        for (points, 0..) |point, i| {
            const x = 2 + @as(f64, @floatFromInt(point.seconds - points[0].seconds)) / @as(f64, @floatFromInt(span)) * (wide - 4);
            const y = 2 + (1 - point.percent / 100) * (tall - 4);
            if (i == 0 or point.seconds - points[i - 1].seconds > 300) cr.moveTo(x, y) else cr.lineTo(x, y);
        }
        cr.stroke();
    }
};
