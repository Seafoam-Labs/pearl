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
const Text = @import("../services/policy.zig").Text;

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
    night_toggle: ?*gtk.Button = null,
    night_resume: ?*gtk.Button = null,
    handoff: *gtk.Button,
    handoff_box: *gtk.Box,
    handoff_message: *gtk.Label,
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
    chooser: *gtk.DropDown,
    chooser_signal: c_ulong = 0,
    close: *gtk.Button,
    close_signal: c_ulong = 0,
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
    links: [pages.len]Link = undefined,
    tasks: [4]TaskLink = undefined,
    probe_focus: ?*gtk.Widget = null,
    const Choice = struct { owner: *Control, name: []const u8 };
    const Link = struct { owner: *Control, page: navigation.Route };
    const TaskLink = struct { owner: *Control, task: Task };

    pub fn create(host: *gtk.Box, layout: *native.Layout, context: *anyopaque, action: @FieldType(Control, "action"), task: @FieldType(Control, "task"), navigate: @FieldType(Control, "navigate"), initial: navigation.Route, window: *gtk.Window, models: Models) !*Control {
        if (!initial.isCompact()) return error.InvalidRoute;
        const self = try a.create(Control);
        const header = w.flow(3);
        header.setHomogeneous(0);
        header.setColumnSpacing(8);
        header.setRowSpacing(8);
        host.append(header.as(gtk.Widget));
        const heading = w.label(title(initial), "pearl-card-title");
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
        header.insert(heading_box.as(gtk.Widget), -1);
        var names: [pages.len:null]?[*:0]const u8 = @splat(null);
        for (pages, 0..) |page, i| names[i] = title(page).ptr;
        const chooser = gtk.DropDown.newFromStrings(@ptrCast(&names));
        w.name(chooser.as(gtk.Widget), tr("Settings section", "Einstellungsbereich"));
        chooser.as(gtk.Widget).setTooltipText(tr("Choose a settings section", "Einstellungsbereich auswählen"));
        chooser.as(gtk.Widget).setHalign(.end);
        header.insert(chooser.as(gtk.Widget), -1);
        const close = w.wrappingButton(tr("Close", "Schließen"));
        close.as(gtk.Widget).setHalign(.end);
        header.insert(close.as(gtk.Widget), -1);
        const stack = gtk.Stack.new();
        stack.setVhomogeneous(0);
        stack.setHhomogeneous(0);
        stack.setTransitionType(.none);
        stack.as(gtk.Widget).setVexpand(1);
        host.append(stack.as(gtk.Widget));
        const handoff = w.wrappingButton(tr("Open full settings", "Alle Einstellungen öffnen"));
        const handoff_box = w.column(8);
        _ = handoff_box.as(object.Object).refSink();
        focus_state.tag(handoff.as(gtk.Widget), "settings:full", .{});
        const installed = @import("../settings/launch.zig").available();
        handoff.as(gtk.Widget).setSensitive(@intFromBool(installed));
        handoff_box.append(handoff.as(gtk.Widget));
        const handoff_message = w.label(if (installed) "" else tr("Full settings is not installed.", "Die vollständigen Einstellungen sind nicht installiert."), "pearl-secondary");
        handoff_message.as(gtk.Widget).setVisible(@intFromBool(!installed));
        handoff_box.append(handoff_message.as(gtk.Widget));
        self.* = .{ .handoff = handoff, .handoff_box = handoff_box, .handoff_message = handoff_message, .models = models, .window = window, .navigate = navigate, .page = initial, .stack = stack, .heading = heading, .header = header.as(gtk.Widget), .heading_focus = heading_box.as(gtk.Widget), .chooser = chooser, .close = close, .layout = layout, .context = context, .action = action, .task = task };
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
        try self.enterPage();
        stack.setVisibleChildName(self.page.id());
        chooser.setSelected(@intCast(index(initial)));
        self.focus_signal = object.Object.signals.notify.connect(window.as(object.Object), *Control, focusChanged, self, .{ .detail = "focus-widget" });
        self.queueRestore(.heading);
        self.chooser_signal = object.Object.signals.notify.connect(chooser.as(object.Object), *Control, sectionChanged, self, .{ .detail = "selected" });
        self.close_signal = gtk.Button.signals.clicked.connect(close, *Control, closeClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(handoff, *Control, fullSettingsClicked, self, .{});
        return self;
    }
    fn fullSettingsClicked(_: *gtk.Button, self: *Control) callconv(.c) void {
        self.task(self.context, .full_settings);
    }
    pub fn launchFailed(self: *Control, err: anyerror) void {
        self.handoff_message.setText(if (err == error.SettingsNotInstalled) tr("Full settings is not installed.", "Die vollständigen Einstellungen sind nicht installiert.") else tr("Full settings could not be started. Try again after checking the installation.", "Die Einstellungen konnten nicht gestartet werden. Bitte die Installation prüfen."));
        self.handoff_message.as(gtk.Widget).setVisible(1);
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
        // Share the handoff across pages without imposing fixed footer height on
        // short outputs. The retained reference survives page-body teardown.
        defer body.append(self.handoff_box.as(gtk.Widget));
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
        const sections = w.flow(2);
        body.append(sections.as(gtk.Widget));
        for (pages, 0..) |page, i| {
            if (page == .overview) continue;
            const button = w.wrappingButton(title(page));
            focus_state.tag(button.as(gtk.Widget), "page:{s}", .{page.id()});
            self.links[i] = .{ .owner = self, .page = page };
            _ = gtk.Button.signals.clicked.connect(button, *Link, linkClicked, &self.links[i], .{});
            sections.insert(button.as(gtk.Widget), -1);
        }
        if (self.models.night_light != null) {
            const night = w.card();
            night.append(w.label(tr("Night Light", "Nachtlicht"), "pearl-card-title").as(gtk.Widget));
            self.night_label = w.label("", "pearl-secondary");
            night.append(self.night_label.?.as(gtk.Widget));
            self.night_toggle = w.wrappingButton(tr("Toggle Night Light", "Nachtlicht umschalten"));
            night.append(self.night_toggle.?.as(gtk.Widget));
            _ = gtk.Button.signals.clicked.connect(self.night_toggle.?, *Control, nightToggled, self, .{});
            self.night_resume = w.wrappingButton(tr("Resume saved policy", "Gespeicherte Einstellungen fortsetzen"));
            night.append(self.night_resume.?.as(gtk.Widget));
            _ = gtk.Button.signals.clicked.connect(self.night_resume.?, *Control, nightResumed, self, .{});
            const settings = w.wrappingButton(tr("Night Light settings", "Nachtlicht-Einstellungen"));
            settings.as(gtk.Widget).setSensitive(@intFromBool(@import("../settings/launch.zig").available()));
            night.append(settings.as(gtk.Widget));
            _ = gtk.Button.signals.clicked.connect(settings, *Control, nightSettings, self, .{});
            body.append(night.as(gtk.Widget));
        }
        const tasks = w.flow(2);
        body.append(tasks.as(gtk.Widget));
        for ([_]Task{ .media, .overview, .settings, .aqueous_settings }, [_][:0]const u8{ tr("Media controls", "Mediensteuerung"), tr("Window overview", "Fensterübersicht"), tr("Pearl settings", "Pearl-Einstellungen"), tr("Aqueous settings", "Aqueous-Einstellungen") }, 0..) |task, label, i| {
            const button = w.wrappingButton(label);
            focus_state.tag(button.as(gtk.Widget), "task:{s}", .{@tagName(task)});
            self.tasks[i] = .{ .owner = self, .task = task };
            _ = gtk.Button.signals.clicked.connect(button, *TaskLink, taskClicked, &self.tasks[i], .{});
            tasks.insert(button.as(gtk.Widget), -1);
        }
        self.lifecycle = try @import("lifecycle.zig").View.create(body, self.models.lifecycle, self.models.auth, self.models.power);
        const section = w.card();
        section.as(gtk.Widget).addCssClass("pearl-layout-card");
        section.append(w.label(tr("Workspace layout", "Anordnung der Arbeitsfläche"), "pearl-card-title").as(gtk.Widget));
        self.label = w.label("", "pearl-secondary");
        self.label.?.setWrap(1);
        section.append(self.label.?.as(gtk.Widget));
        const layouts = w.flow(3);
        section.append(layouts.as(gtk.Widget));
        for (native.names, 0..) |name, i| {
            const button = w.wrappingButton(name);
            focus_state.tag(button.as(gtk.Widget), "layout:{s}", .{name});
            self.buttons[i] = button;
            self.rows[i] = .{ .owner = self, .name = name };
            _ = gtk.Button.signals.clicked.connect(button, *Choice, selected, &self.rows[i], .{});
            layouts.insert(button.as(gtk.Widget), -1);
        }
        const refresh = w.wrappingButton(tr("Refresh layout", "Anordnung aktualisieren"));
        focus_state.tag(refresh.as(gtk.Widget), "layout-refresh", .{});
        _ = gtk.Button.signals.clicked.connect(refresh, *Control, refreshed, self, .{});
        section.append(refresh.as(gtk.Widget));
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
        self.chooser.setSelected(@intCast(index(page)));
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
        if (self.chooser_signal != 0) object.signalHandlerDisconnect(self.chooser.as(object.Object), self.chooser_signal);
        if (self.close_signal != 0) object.signalHandlerDisconnect(self.close.as(object.Object), self.close_signal);
        self.leavePage();
        self.handoff_box.as(object.Object).unref();
        a.destroy(self);
    }
    fn nightToggled(_: *gtk.Button, self: *Control) callconv(.c) void {
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
            self.night_toggle.?.as(gtk.Widget).setSensitive(@intFromBool(night.interactive and (night.requested or night.warming.available())));
            self.night_resume.?.as(gtk.Widget).setVisible(@intFromBool(night.model.override != null));
        }
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
        const chooser = self.chooser.as(gtk.Widget);
        return if (focus == chooser or focus.isAncestor(chooser) != 0) "section-chooser" else if (focus == self.heading_focus) "heading" else "body";
    }
    fn focusedButton(window: *gtk.Window) ?[]const u8 {
        const focus = window.getFocus() orelse return null;
        const button = object.ext.cast(gtk.Button, focus) orelse if (focus.getAncestor(gtk.Button.getGObjectType())) |ancestor| object.ext.cast(gtk.Button, ancestor).? else return null;
        return if (button.getLabel()) |label| std.mem.span(label) else null;
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
        return std.json.Stringify.valueAlloc(alloc, .{ .handoff_available = self.handoff.as(gtk.Widget).getSensitive() != 0, .handoff_error = std.mem.span(self.handoff_message.getText()), .page = self.page, .heading = std.mem.span(self.heading.getText()), .focus = self.focusName(window), .button = focusedButton(window), .saved_focus = self.focus_ids[index(self.page)].slice(), .restoring = self.restore_tick != 0, .labels = labels.items, .populated_pages = populated, .viewports = self.viewports.len, .panel_width = panel.getAllocatedWidth(), .panel_height = panel.getAllocatedHeight(), .header_height = self.header.getHeight(), .body_width = scroll.as(gtk.Widget).getWidth(), .body_height = scroll.as(gtk.Widget).getHeight(), .scroll = scroll.getVadjustment().getValue(), .scroll_upper = scroll.getVadjustment().getUpper(), .scroll_page_size = scroll.getVadjustment().getPageSize(), .interest = .{ .network = self.models.network.interest.count() != 0, .bluetooth = self.models.bluetooth.interest.count() != 0, .power = self.models.power.panel_open } }, .{});
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
    fn sectionChanged(_: *object.Object, _: *object.ParamSpec, self: *Control) callconv(.c) void {
        const i = self.chooser.getSelected();
        if (i < pages.len) self.navigate(self.context, pages[i]) catch {};
    }
    fn linkClicked(_: *gtk.Button, link: *Link) callconv(.c) void {
        link.owner.navigate(link.owner.context, link.page) catch {};
    }
    fn taskClicked(_: *gtk.Button, link: *TaskLink) callconv(.c) void {
        link.owner.task(link.owner.context, link.task);
    }
    fn closeClicked(_: *gtk.Button, self: *Control) callconv(.c) void {
        self.task(self.context, .close);
    }
    fn selected(_: *gtk.Button, choice: *Choice) callconv(.c) void {
        choice.owner.action(choice.owner.context, choice.name);
    }
    fn refreshed(_: *gtk.Button, self: *Control) callconv(.c) void {
        self.action(self.context, null);
    }
};
pub fn calendar(host: *gtk.Box) void {
    const now = glib.DateTime.newNowLocal() orelse return;
    defer now.unref();
    const date = now.format("%A, %d %B %Y") orelse return;
    defer glib.free(date);
    host.append(w.label(date, "pearl-card-title").as(gtk.Widget));
    const scroll = gtk.ScrolledWindow.new();
    scroll.setPolicy(.never, .automatic);
    scroll.as(gtk.Widget).setVexpand(1);
    const content = w.column(16);
    scroll.setChild(content.as(gtk.Widget));
    host.append(scroll.as(gtk.Widget));
    const grid = gtk.Calendar.new();
    grid.setShowDayNames(1);
    grid.setShowHeading(1);
    grid.selectDay(now);
    grid.as(gtk.Widget).setHalign(.center);
    content.append(grid.as(gtk.Widget));
    content.append(w.status(.empty, w.label(tr("Your local calendar", "Dein lokaler Kalender"), null), w.label(tr("Browse months and dates. Calendar accounts are not connected.", "Blättere durch Monate und Tage. Kalenderkonten sind nicht verbunden."), "pearl-secondary")).as(gtk.Widget));
}
