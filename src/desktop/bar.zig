//! Live per-output bar; callbacks carry opaque IDs, never workspace numbers/titles.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const glib = @import("glib2");
const object = @import("gobject2");
const Client = @import("../aqueous/client.zig").Client;
const workspace_policy = @import("workspace_policy.zig");
const policy = @import("policy.zig");
const w = @import("../ui/components/widgets.zig");
const tr = @import("text.zig").tr;
const a = std.heap.c_allocator;
const clocks = @import("clock_policy.zig");
const Clock = @import("clock_view.zig").View;
const Running = @import("running_apps.zig");
pub const Pane = enum { launcher_picker, running_apps, clipboard_capture, aqueous_settings, settings, launcher, calendar, control, notifications, media, tray, wallpapers };
pub const Event = union(enum) { running_apps: Running.Event, pane: Pane, settings: @import("settings_navigation.zig").Route, workspace: []const u8, keyboard, overview, window_switcher };
const Button = struct { owner: *Bar, event: Event, id: ?[]u8 = null };
pub const Bar = struct {
    background_opacity: @import("bar_opacity.zig").Config = .{},
    background_css: ?*gtk.CssProvider = null,
    background_color: ?gdk.RGBA = null,
    launcher_icon: @import("../ui/components/launcher_icon.zig").Renderer = .{},
    host: *gtk.Box,
    tasks: *const @import("task_model.zig").Snapshot,
    app_index: *@import("apps.zig").Index,
    running_apps: ?*Running.Strip = null,
    audio_service: *@import("../services/audio.zig").Audio,
    power_service: *@import("../services/power.zig").Power,
    network_service: *@import("../services/network.zig").Network,
    bluetooth_service: *@import("../services/bluetooth.zig").Bluetooth,
    session_services: *@import("../services/session.zig").Session,
    plugins: ?*@import("../plugins/manager.zig").Manager = null,
    plugin_views: std.ArrayList(*@import("../plugins/view.zig").View) = .empty,
    tray: ?*@import("tray.zig").Bar = null,
    /// Geometry of the widget that last opened a pane, in bar-window coordinates.
    pane_anchor: ?struct { x: i32, y: i32, width: i32, height: i32 } = null,
    notification_label: ?*gtk.Label = null,
    media_label: ?*gtk.Label = null,
    network_label: ?*gtk.Label = null,
    bluetooth_label: ?*gtk.Label = null,
    audio_label: ?*gtk.Label = null,
    battery_label: ?*gtk.Label = null,
    client: *Client,
    output: []const u8,
    context: *anyopaque,
    action: *const fn (*anyopaque, Event) void,
    groups: [3][:0]u8,
    widgets: [@typeInfo(policy.Item).@"enum".fields.len]?*gtk.Widget = @splat(null),
    handlers: std.ArrayList(*Button) = .empty,
    workspace_handlers: std.ArrayList(*Button) = .empty,
    workspace_hash: ?u64 = null,
    workspace_mode: workspace_policy.Mode = .large,
    title: ?*gtk.Label = null,
    clock_views: std.ArrayList(Clock) = .empty,
    clock_arena: std.heap.ArenaAllocator = .init(a),
    clock_definitions: []const clocks.Definition = &.{},
    keyboard: ?*gtk.Label = null,
    islands: bool = true,
    sections: [3]?*gtk.Widget = @splat(null),
    vertical: bool = false,
    compact: bool = false,
    length: i32 = 1280,
    thickness: i32 = 48,
    pub fn create(host: *gtk.Box, client: *Client, output: []const u8, context: *anyopaque, action: @FieldType(Bar, "action"), audio: *@import("../services/audio.zig").Audio, power: *@import("../services/power.zig").Power, network: *@import("../services/network.zig").Network, bluetooth: *@import("../services/bluetooth.zig").Bluetooth, session: *@import("../services/session.zig").Session, plugins: ?*@import("../plugins/manager.zig").Manager, tasks: *const @import("task_model.zig").Snapshot, app_index: *@import("apps.zig").Index) !*Bar {
        const self = try a.create(Bar);
        self.* = .{ .host = host, .tasks = tasks, .app_index = app_index, .plugins = plugins, .session_services = session, .audio_service = audio, .power_service = power, .network_service = network, .bluetooth_service = bluetooth, .client = client, .output = output, .context = context, .action = action, .groups = undefined };
        self.groups = .{ try a.dupeZ(u8, "launcher,workspaces,title"), try a.dupeZ(u8, "clock"), try a.dupeZ(u8, (policy.Groups{}).right) };
        try self.build();
        return self;
    }
    pub fn destroy(self: *Bar) void {
        self.clear();
        if (self.background_css) |provider| {
            self.host.as(gtk.Widget).getStyleContext().removeProvider(provider.as(gtk.StyleProvider));
            provider.unref();
        }
        self.launcher_icon.deinit();
        self.clock_arena.deinit();
        for (self.groups) |g| a.free(g);
        a.destroy(self);
    }
    fn freeHandlers(list: *std.ArrayList(*Button)) void {
        for (list.items) |b| {
            if (b.id) |id| a.free(id);
            a.destroy(b);
        }
        list.deinit(a);
        list.* = .empty;
    }
    fn clear(self: *Bar) void {
        self.pane_anchor = null;
        for (self.clock_views.items) |*view| view.deinit();
        self.clock_views.deinit(a);
        self.clock_views = .empty;
        self.launcher_icon.clearTargets();
        if (self.running_apps) |view| view.destroy();
        self.running_apps = null;
        for (self.plugin_views.items) |view| view.destroy();
        self.plugin_views.deinit(a);
        self.plugin_views = .empty;
        self.sections = @splat(null);
        if (self.tray) |tray| tray.destroy();
        self.tray = null;
        self.notification_label = null;
        self.media_label = null;
        while (self.host.as(gtk.Widget).getFirstChild()) |child| self.host.remove(child);
        freeHandlers(&self.handlers);
        freeHandlers(&self.workspace_handlers);
        self.widgets = @splat(null);
        self.title = null;
        self.keyboard = null;
        self.audio_label = null;
        self.battery_label = null;
        self.network_label = null;
        self.bluetooth_label = null;
        self.workspace_hash = null;
    }
    pub fn configure(self: *Bar, groups: policy.Groups, definitions: []const clocks.Definition) !void {
        try groups.validate();
        try clocks.validate(definitions, groups);
        var arena = std.heap.ArenaAllocator.init(a);
        var transferred = false;
        defer if (!transferred) arena.deinit();
        const alloc = arena.allocator();
        const owned = try alloc.alloc(clocks.Definition, definitions.len);
        for (definitions, owned) |d, *copy| {
            copy.* = d;
            copy.id = try alloc.dupe(u8, d.id);
            copy.timezone = try alloc.dupe(u8, d.timezone);
            copy.label = try alloc.dupe(u8, d.label);
        }
        var next: [3][:0]u8 = undefined;
        var count: usize = 0;
        errdefer for (next[0..count]) |v| a.free(v);
        for ([_][]const u8{ groups.left, groups.center, groups.right }, 0..) |g, i| {
            next[i] = try a.dupeZ(u8, g);
            count += 1;
        }
        self.clear();
        self.clock_arena.deinit();
        self.clock_arena = arena;
        self.clock_definitions = owned;
        transferred = true;
        for (self.groups) |g| a.free(g);
        self.groups = next;
        count = 0;
        try self.build();
    }
    pub fn setWorkspaceMode(self: *Bar, mode: workspace_policy.Mode) void {
        if (self.workspace_mode == mode) return;
        self.workspace_mode = mode;
        self.workspace_hash = null;
        self.update();
    }
    pub fn setBackgroundOpacity(self: *Bar, config: @import("bar_opacity.zig").Config, color: gdk.RGBA) !void {
        const alpha = config.alpha();
        var resolved = color;
        resolved.f_alpha = alpha orelse 1;
        if (std.meta.eql(self.background_opacity, config) and (alpha == null or (self.background_color != null and std.meta.eql(self.background_color.?, resolved)))) return;
        if (alpha != null) {
            const css = try std.fmt.allocPrintSentinel(a, ".pearl-bar-panel:not(.pearl-islands), .pearl-island {{ background: rgba({d}, {d}, {d}, {d:.2}); }}", .{ @as(u8, @intFromFloat(@round(resolved.f_red * 255))), @as(u8, @intFromFloat(@round(resolved.f_green * 255))), @as(u8, @intFromFloat(@round(resolved.f_blue * 255))), resolved.f_alpha }, 0);
            defer a.free(css);
            if (self.background_css == null) {
                self.background_css = gtk.CssProvider.new();
                self.host.as(gtk.Widget).getStyleContext().addProvider(self.background_css.?.as(gtk.StyleProvider), 602);
                for (self.sections) |section| if (section) |widget| widget.getStyleContext().addProvider(self.background_css.?.as(gtk.StyleProvider), 602);
            }
            self.background_css.?.loadFromString(css);
        } else if (self.background_css) |provider| provider.loadFromString("");
        self.background_color = if (alpha != null) resolved else null;
        self.background_opacity = config;
    }
    pub fn setIslands(self: *Bar, enabled: bool) void {
        if (self.islands != enabled) {
            self.islands = enabled;
            self.build() catch {};
        }
        self.styleIslands();
    }
    pub fn styleIslands(self: *Bar) void {
        const host = self.host.as(gtk.Widget);
        if (self.islands) {
            host.addCssClass("pearl-islands");
            host.removeCssClass("background");
        } else host.removeCssClass("pearl-islands");
        for (self.sections) |maybe| if (maybe) |section| {
            if (self.islands) {
                section.addCssClass("pearl-island");
                section.addCssClass("background");
            } else {
                section.removeCssClass("pearl-island");
                section.removeCssClass("background");
            }
        };
    }
    fn makeButton(self: *Bar, event: Event, icon: ?[*:0]const u8, text: [*:0]const u8, workspace: bool) !*gtk.Button {
        const b = try a.create(Button);
        errdefer a.destroy(b);
        b.* = .{ .owner = self, .event = event };
        if (event == .workspace) {
            b.id = try a.dupe(u8, event.workspace);
            b.event = .{ .workspace = b.id.? };
        }
        try (if (workspace) &self.workspace_handlers else &self.handlers).append(a, b);
        // Custom contents must start without a GtkButton label. An empty label
        // otherwise overrides the accessible name even after replacing its child.
        const button = if (icon) |symbol| w.iconButton(symbol, text) else if (text[0] == 0) gtk.Button.new() else gtk.Button.newWithLabel(text);
        _ = gtk.Button.signals.clicked.connect(button, *Button, clicked, b, .{});
        return button;
    }
    fn build(self: *Bar) !void {
        self.clear();
        if (self.vertical) self.host.as(gtk.Widget).addCssClass("pearl-bar-vertical") else self.host.as(gtk.Widget).removeCssClass("pearl-bar-vertical");
        self.host.as(gtk.Orientable).setOrientation(if (self.vertical) .vertical else .horizontal);
        self.host.setSpacing(8);
        const center = gtk.CenterBox.new();
        center.as(gtk.Orientable).setOrientation(if (self.vertical) .vertical else .horizontal);
        center.as(gtk.Widget).setHexpand(1);
        center.as(gtk.Widget).setVexpand(1);
        self.host.append(center.as(gtk.Widget));
        for (self.groups, 0..) |group, section| {
            const box = gtk.Box.new(if (self.vertical) .vertical else .horizontal, 4);
            self.sections[section] = if (group.len != 0) box.as(gtk.Widget) else null;
            if (self.background_css) |provider| box.as(gtk.Widget).getStyleContext().addProvider(provider.as(gtk.StyleProvider), 602);
            if (self.vertical) box.as(gtk.Widget).setVexpand(@intFromBool(!self.islands and section != 1)) else box.as(gtk.Widget).setHexpand(@intFromBool(!self.islands and section != 1));
            box.as(gtk.Widget).setHalign(if (self.vertical) .fill else if (section == 2) .end else .fill);
            box.as(gtk.Widget).setValign(if (self.vertical and section == 2) .end else .fill);
            switch (section) {
                0 => center.setStartWidget(box.as(gtk.Widget)),
                1 => center.setCenterWidget(box.as(gtk.Widget)),
                2 => center.setEndWidget(box.as(gtk.Widget)),
                else => unreachable,
            }
            var parts = std.mem.splitScalar(u8, group, ',');
            while (parts.next()) |part| {
                if (std.mem.startsWith(u8, part, "plugin:") and @import("../plugins/model.zig").reference(part)) {
                    if (self.plugins) |manager| {
                        const host = gtk.Box.new(if (self.vertical) .vertical else .horizontal, 4);
                        const viewport = gtk.ScrolledWindow.new();
                        viewport.setPolicy(.external, .external);
                        viewport.setPropagateNaturalWidth(1);
                        viewport.setPropagateNaturalHeight(1);
                        viewport.setMaxContentWidth(if (self.vertical) 128 else 192);
                        viewport.setMaxContentHeight(if (self.vertical) 192 else 128);
                        viewport.setChild(host.as(gtk.Widget));
                        box.append(viewport.as(gtk.Widget));
                        const view = try @import("../plugins/view.zig").View.create(host, manager, part[7 .. part.len - 5], false);
                        try self.plugin_views.append(a, view);
                    }
                    continue;
                }
                if (clocks.reference(part)) |id| {
                    const definition = clocks.find(self.clock_definitions, id) orelse continue;
                    const button = try self.makeButton(.{ .pane = .calendar }, null, "", false);
                    box.append(button.as(gtk.Widget));
                    button.as(gtk.Widget).addCssClass("pearl-bar-item");
                    try self.clock_views.ensureUnusedCapacity(a, 1);
                    self.clock_views.appendAssumeCapacity(Clock.create(button, definition, part, self.vertical));
                    continue;
                }
                const item = std.meta.stringToEnum(policy.Item, part) orelse continue;
                const widget: *gtk.Widget = switch (item) {
                    .running_apps => blk: {
                        const host = gtk.Box.new(if (self.vertical) .vertical else .horizontal, 2);
                        self.running_apps = try Running.Strip.create(host, self.tasks, self.app_index, self.vertical, self, runningAction);
                        break :blk host.as(gtk.Widget);
                    },
                    .tray => blk: {
                        const tray_host = gtk.Box.new(if (self.vertical) .vertical else .horizontal, 2);
                        self.tray = try @import("tray.zig").Bar.create(tray_host, &self.session_services.tray, self, openTray);
                        break :blk tray_host.as(gtk.Widget);
                    },
                    .notifications, .media => blk: {
                        const button = try self.makeButton(.{ .pane = if (item == .media) .media else .notifications }, null, "", false);
                        const content = gtk.Box.new(if (self.vertical) .vertical else .horizontal, if (self.vertical) 0 else 4);
                        content.append(w.icon(if (item == .media) "pearl-media-symbolic" else "pearl-notifications-symbolic").as(gtk.Widget));
                        const label = gtk.Label.new("");
                        label.setEllipsize(.end);
                        label.setMaxWidthChars(if (self.vertical) 2 else if (item == .media) 16 else 4);
                        if (self.vertical) label.as(gtk.Widget).addCssClass("pearl-bar-value");
                        content.append(label.as(gtk.Widget));
                        button.setChild(content.as(gtk.Widget));
                        if (item == .media) self.media_label = label else self.notification_label = label;
                        w.name(button.as(gtk.Widget), if (item == .media) "Media" else "Notifications");
                        break :blk button.as(gtk.Widget);
                    },
                    .launcher => blk: {
                        const button = try self.makeButton(.{ .pane = .launcher }, @import("launcher_icon_policy.zig").default_icon, tr("Applications", "Programme"), false);
                        button.setChild((try self.launcher_icon.image(20)).as(gtk.Widget));
                        break :blk button.as(gtk.Widget);
                    },
                    .window_switcher => (try self.makeButton(.window_switcher, "pearl-window-switcher-symbolic", tr("Cycle windows", "Fenster durchschalten"), false)).as(gtk.Widget),
                    .overview => (try self.makeButton(.overview, "pearl-view-grid-symbolic", tr("Overview", "Übersicht"), false)).as(gtk.Widget),
                    .clipboard => (try self.makeButton(.{ .pane = .clipboard_capture }, "pearl-edit-copy-symbolic", tr("Clipboard & capture", "Zwischenablage & Bildschirmfoto"), false)).as(gtk.Widget),
                    .wallpaper => (try self.makeButton(.{ .pane = .wallpapers }, "pearl-image-symbolic", tr("Wallpaper", "Hintergrundbild"), false)).as(gtk.Widget),
                    .control => (try self.makeButton(.{ .settings = .overview }, "pearl-emblem-system-symbolic", tr("Open settings Overview", "Einstellungsübersicht öffnen"), false)).as(gtk.Widget),
                    .clock => unreachable,
                    .audio, .battery, .network, .bluetooth => blk: {
                        const button = try self.makeButton(.{ .settings = switch (item) {
                            .audio => .sound,
                            .battery => .power,
                            .network => .network,
                            .bluetooth => .bluetooth,
                            else => unreachable,
                        } }, null, "", false);
                        const content = gtk.Box.new(if (self.vertical) .vertical else .horizontal, if (self.vertical) 0 else 4);
                        content.append(w.icon(switch (item) {
                            .audio => "pearl-audio-volume-high-symbolic",
                            .battery => "pearl-battery-symbolic",
                            .network => "pearl-network-wireless-symbolic",
                            .bluetooth => "pearl-bluetooth-active-symbolic",
                            else => unreachable,
                        }).as(gtk.Widget));
                        const label = gtk.Label.new("");
                        if (self.vertical) {
                            label.setEllipsize(.end);
                            label.setMaxWidthChars(3);
                            label.as(gtk.Widget).addCssClass("pearl-bar-value");
                        }
                        content.append(label.as(gtk.Widget));
                        switch (item) {
                            .audio => self.audio_label = label,
                            .battery => self.battery_label = label,
                            .network => self.network_label = label,
                            .bluetooth => self.bluetooth_label = label,
                            else => unreachable,
                        }
                        button.setChild(content.as(gtk.Widget));
                        break :blk button.as(gtk.Widget);
                    },
                    .keyboard => blk: {
                        const button = try self.makeButton(.keyboard, null, "", false);
                        button.as(gtk.Widget).setTooltipText(tr("Switch keyboard layout", "Tastaturbelegung wechseln"));
                        self.keyboard = gtk.Label.new("");
                        self.keyboard.?.setEllipsize(.end);
                        self.keyboard.?.setMaxWidthChars(if (self.vertical) 2 else 14);
                        button.setChild(self.keyboard.?.as(gtk.Widget));
                        break :blk button.as(gtk.Widget);
                    },
                    .title => blk: {
                        const title = gtk.Label.new("");
                        title.setXalign(0);
                        title.setEllipsize(.end);
                        title.setMaxWidthChars(28);
                        title.as(gtk.Widget).setHexpand(@intFromBool(!self.islands));
                        title.as(gtk.Widget).setMarginStart(8);
                        self.title = title;
                        break :blk title.as(gtk.Widget);
                    },
                    .workspaces => blk: {
                        const grid = gtk.Grid.new();
                        grid.setColumnSpacing(2);
                        grid.setRowSpacing(2);
                        grid.setColumnHomogeneous(1);
                        grid.setRowHomogeneous(1);
                        break :blk grid.as(gtk.Widget);
                    },
                };
                widget.addCssClass("pearl-bar-item");
                self.widgets[@intFromEnum(item)] = widget;
                box.append(widget);
            }
        }
        self.update();
        self.tick();
        self.styleIslands();
        self.fit();
    }
    pub fn geometry(self: *Bar, vertical: bool, length: i32) void {
        self.length = length;
        const compact = length < 1000;
        if (self.vertical != vertical) {
            self.vertical = vertical;
            self.compact = compact;
            self.build() catch {};
        }
        if (self.compact != compact) {
            self.compact = compact;
            self.fit();
        }
        self.layoutWorkspaces();
        self.fitTasks();
    }
    fn fit(self: *Bar) void {
        if (self.tray) |tray| tray.setLimit(if (self.compact or self.vertical) 2 else 4);
        if (self.media_label) |label| label.as(gtk.Widget).setVisible(@intFromBool(!self.compact and !self.vertical));
        if (self.widgets[@intFromEnum(policy.Item.title)]) |v| v.setVisible(@intFromBool(!self.compact and !self.vertical));
        if (self.widgets[@intFromEnum(policy.Item.overview)]) |v| v.setVisible(@intFromBool(!self.compact));
        self.layoutWorkspaces();
        // Primary controls survive; overview also lives in the control center.
    }
    fn runningAction(data: *anyopaque, event: Running.Event) void {
        const self: *Bar = @ptrCast(@alignCast(data));
        self.action(self.context, .{ .running_apps = event });
    }
    fn fitTasks(self: *Bar) void {
        const view = self.running_apps orelse return;
        view.compact = self.thickness < 40;
        const orientation: gtk.Orientation = if (self.vertical) .vertical else .horizontal;
        var used: c_int = 64;
        for (self.sections) |maybe| if (maybe) |section| {
            var child = section.getFirstChild();
            while (child) |widget| : (child = widget.getNextSibling()) {
                if (widget == view.host.as(gtk.Widget) or widget.getVisible() == 0) continue;
                var minimum: c_int = 0;
                var natural: c_int = 0;
                widget.measure(orientation, -1, &minimum, &natural, null, null);
                used += (if (widget == self.widgets[@intFromEnum(policy.Item.title)]) minimum else natural) + 4;
            }
        };
        var cell: c_int = 40;
        var child = view.host.as(gtk.Widget).getFirstChild();
        while (child) |widget| : (child = widget.getNextSibling()) {
            var natural: c_int = 0;
            widget.measure(orientation, -1, null, &natural, null, null);
            cell = @max(cell, natural);
        }
        view.slots = @intCast(@max(1, @divTrunc(self.length - used, cell + 2)));
        view.update() catch {};
        // An otherwise empty island must not reserve a blank input/blur region.
        for (self.sections) |maybe| if (maybe) |section| {
            var visible = false;
            child = section.getFirstChild();
            while (child) |widget| : (child = widget.getNextSibling()) {
                visible = visible or widget.getVisible() != 0;
            }
            section.setVisible(@intFromBool(visible));
        };
    }
    fn openTray(data: *anyopaque) void {
        const self: *Bar = @ptrCast(@alignCast(data));
        self.action(self.context, .{ .pane = .tray });
    }
    pub fn update(self: *Bar) void {
        if (self.widgets[@intFromEnum(policy.Item.window_switcher)]) |widget| {
            const n = @import("window_switcher.zig").count(&self.client.model, self.output);
            const supported = self.client.capabilities.workspace_switcher_v1;
            widget.setSensitive(@intFromBool(supported and n > 1));
            var buffer: [160]u8 = undefined;
            const title = if (!supported) tr("Cycle windows requires updated Aqueous", "Fensterwechsel benötigt aktualisiertes Aqueous") else if (n == 0) tr("No open windows on this workspace", "Keine offenen Fenster auf dieser Arbeitsfläche") else if (n == 1) tr("Only window on this workspace", "Nur ein Fenster auf dieser Arbeitsfläche") else std.fmt.bufPrintZ(&buffer, "{s} · {d}", .{ tr("Cycle windows on this workspace", "Fenster dieser Arbeitsfläche durchschalten"), n }) catch "Cycle windows";
            widget.setTooltipText(title);
            w.name(widget, title);
        }
        for (self.plugin_views.items) |view| view.update();
        if (self.tray) |tray| tray.update();
        if (self.notification_label) |label| {
            var count: usize = 0;
            for (&self.session_services.notifications.model.records) |*r| if (r.id != 0) {
                count += 1;
            };
            var buf: [20]u8 = undefined;
            label.setText(std.fmt.bufPrintZ(&buf, "{s}{d}", .{ if (self.session_services.notifications.model.dnd) "− " else "", count }) catch "");
        }
        if (self.media_label) |label| label.setText(if (self.session_services.media.current()) |p| p.title.z() else "");
        var service_buffer: [256]u8 = undefined;
        if (self.audio_label) |label| {
            const device = self.audio_service.default(.sink);
            label.setText(if (device) |d| if (d.mute) tr("Muted", "Stumm") else std.fmt.bufPrintZ(&service_buffer, "{d}%", .{d.volume}) catch "" else "—");
            const widget = self.widgets[@intFromEnum(policy.Item.audio)].?;
            var detail: [768]u8 = undefined;
            serviceName(widget, tr("Open Sound controls", "Klangsteuerung öffnen"), if (device) |d| std.fmt.bufPrintZ(&detail, "{s} · {s}", .{ d.label.slice(), std.mem.span(label.getText()) }) catch d.label.z() else tr("Audio unavailable", "Audio nicht verfügbar"));
        }
        if (self.battery_label) |label| {
            label.setText(std.fmt.bufPrintZ(&service_buffer, "{d:.0}%", .{self.power_service.percentage}) catch "");
            const widget = self.widgets[@intFromEnum(policy.Item.battery)].?;
            widget.setVisible(@intFromBool(self.power_service.battery_present));
            var detail: [128]u8 = undefined;
            serviceName(widget, tr("Open Power controls", "Energiesteuerung öffnen"), std.fmt.bufPrintZ(&detail, "{s} · {s}", .{ std.mem.span(label.getText()), if (self.power_service.battery_state == 1) tr("Charging", "Wird geladen") else tr("Battery", "Akku") }) catch "");
        }
        if (self.network_label) |label| {
            const n = self.network_service;
            var connected = false;
            for (n.devices[0..n.device_count]) |dev| if (dev.state == 100) {
                connected = true;
            };
            label.setText(if (n.peer.snapshot == null) "—" else if (n.pending) "…" else if (connected) "On" else if (n.enabled) "Wi-Fi" else "Off");
            const widget = self.widgets[@intFromEnum(policy.Item.network)].?;
            serviceName(widget, tr("Open Network controls", "Netzwerksteuerung öffnen"), if (n.peer.snapshot == null) tr("Network unavailable", "Netzwerk nicht verfügbar") else if (n.pending) tr("Connecting…", "Verbindung wird hergestellt…") else if (connected) tr("Connected", "Verbunden") else if (n.enabled) tr("Wi-Fi on", "WLAN an") else tr("Wi-Fi off", "WLAN aus"));
        }
        if (self.bluetooth_label) |label| {
            const b = self.bluetooth_service;
            var connected: usize = 0;
            for (b.devices[0..b.device_count]) |dev| if (dev.connected) {
                connected += 1;
            };
            label.setText(if (b.peer.snapshot == null) "—" else std.fmt.bufPrintZ(&service_buffer, "{d}", .{connected}) catch "");
            const widget = self.widgets[@intFromEnum(policy.Item.bluetooth)].?;
            var powered = false;
            for (b.adapters[0..b.adapter_count]) |adapter| powered = powered or adapter.powered;
            var detail: [128]u8 = undefined;
            serviceName(widget, tr("Open Bluetooth controls", "Bluetooth-Steuerung öffnen"), if (b.peer.snapshot == null) tr("Bluetooth unavailable", "Bluetooth nicht verfügbar") else if (!powered) tr("Bluetooth off", "Bluetooth aus") else std.fmt.bufPrintZ(&detail, "{s} · {d} {s}", .{ tr("Bluetooth on", "Bluetooth an"), connected, tr("connected", "verbunden") }) catch "");
        }
        const focus = self.client.model.focus(null) catch null;
        if (self.title) |label| {
            const title: []const u8 = if (focus) |f| blk: {
                if (f.seat.focus_kind == .window) if (f.window) |window| if (window.output) |output| if (std.mem.eql(u8, output, self.output)) break :blk window.title orelse window.app_id orelse "";
                break :blk if (f.seat.focus_kind == .layer_surface) "Pearl" else tr("Desktop", "Desktop");
            } else tr("Desktop", "Desktop");
            const text = a.dupeZ(u8, title) catch return;
            defer a.free(text);
            label.setText(text);
            label.as(gtk.Widget).setTooltipText(text);
        }
        if (self.keyboard) |label| {
            const keyboard = if (focus) |f| f.keyboard else null;
            const text = if (keyboard) |k| (if (k.layouts.len > 0) k.layouts[k.index] else "—") else "—";
            const value = a.dupeZ(u8, text) catch return;
            defer a.free(value);
            if (self.vertical) {
                // Keep a compact language indicator; the full layout stays in
                // the tooltip and accessible name, including non-Latin names.
                var short: [9:0]u8 = @splat(0);
                var utf8 = (std.unicode.Utf8View.init(text) catch return).iterator();
                const prefix = utf8.peek(2);
                for (prefix, 0..) |byte, i| short[i] = std.ascii.toUpper(byte);
                label.setText(&short);
            } else label.setText(value);
            self.widgets[@intFromEnum(policy.Item.keyboard)].?.setTooltipText(value);
            w.name(self.widgets[@intFromEnum(policy.Item.keyboard)].?, value);
            self.widgets[@intFromEnum(policy.Item.keyboard)].?.setSensitive(@intFromBool(keyboard != null and self.client.capabilities.keyboard));
        }
        if (self.widgets[@intFromEnum(policy.Item.workspaces)]) |host| {
            const list = self.client.model.workspaces(a, self.output) catch return;
            defer a.free(list);
            const active = self.client.model.activeWorkspace(self.output);
            var active_index: ?usize = null;
            if (active) |current| for (list, 0..) |ws, i| {
                if (std.mem.eql(u8, ws.id, current.id)) {
                    active_index = i;
                    break;
                }
            };
            const range = workspace_policy.visibleRange(list.len, active_index, self.workspace_mode);
            const visible = list[range.start..range.end];
            var hash = std.hash.Wyhash.init(0);
            hash.update(@tagName(self.workspace_mode));
            if (active) |current| std.hash.autoHashStrat(&hash, current.id, .Deep);
            for (visible) |ws| {
                std.hash.autoHashStrat(&hash, ws.id, .Deep);
                std.hash.autoHashStrat(&hash, ws.name, .Deep);
                std.hash.autoHash(&hash, ws.number);
                hash.update(&.{ @intFromBool(ws.active), @intFromBool(ws.urgent) });
            }
            const value = hash.final();
            if (self.workspace_hash == null or value != self.workspace_hash.?) {
                self.workspace_hash = value;
                const box = object.ext.cast(gtk.Grid, host).?;
                while (host.getFirstChild()) |child| box.remove(child);
                freeHandlers(&self.workspace_handlers);
                for (visible, 0..) |ws, i| {
                    var buffer: [20]u8 = undefined;
                    const number = std.fmt.bufPrintZ(&buffer, "{d}", .{ws.number}) catch unreachable;
                    const button = self.makeButton(.{ .workspace = ws.id }, null, number, true) catch continue;
                    const tooltip = std.fmt.allocPrintSentinel(a, "{s} · {s}", .{ ws.name, ws.id }, 0) catch continue;
                    defer a.free(tooltip);
                    button.as(gtk.Widget).setTooltipText(tooltip);
                    w.name(button.as(gtk.Widget), tooltip);
                    button.as(gtk.Widget).addCssClass(if (ws.active) "pearl-workspace-active" else "pearl-workspace");
                    if (ws.urgent) button.as(gtk.Widget).addCssClass("pearl-urgent");
                    box.attach(button.as(gtk.Widget), @intCast(i), 0, 1, 1);
                }
            }
        }
        self.layoutWorkspaces();
        self.fitTasks();
    }
    fn layoutWorkspaces(self: *Bar) void {
        const host = self.widgets[@intFromEnum(policy.Item.workspaces)] orelse return;
        const orientation: gtk.Orientation = if (self.vertical) .vertical else .horizontal;
        // Account for the host margins, island padding, group gaps and sibling
        // controls. The optional window title can ellipsize to leave room.
        var available = self.length - 64;
        for (self.widgets, 0..) |maybe, i| if (maybe) |widget| {
            if (widget == host or widget.getVisible() == 0) continue;
            var minimum: c_int = 0;
            var natural: c_int = 0;
            widget.measure(orientation, -1, &minimum, &natural, null, null);
            available -= (if (i == @intFromEnum(policy.Item.title)) minimum else natural) + 4;
        };
        for (self.clock_views.items) |view| {
            var minimum: c_int = 0;
            var natural: c_int = 0;
            view.button.as(gtk.Widget).measure(orientation, -1, &minimum, &natural, null, null);
            available -= (if (self.compact and !self.vertical) minimum else natural) + 4;
        }
        var cell: c_int = 1;
        var child = host.getFirstChild();
        while (child) |widget| : (child = widget.getNextSibling()) {
            var natural: c_int = 0;
            widget.measure(orientation, -1, null, &natural, null, null);
            cell = @max(cell, natural);
        }
        const per_line = @max(1, @divTrunc(available + 2, cell + 2));
        const layout = host.getLayoutManager().?;
        child = host.getFirstChild();
        var i: c_int = 0;
        while (child) |widget| : ({
            child = widget.getNextSibling();
            i += 1;
        }) {
            const item = object.ext.cast(gtk.GridLayoutChild, layout.getLayoutChild(widget)).?;
            // A side bar keeps its thickness. Overflow scrolls along the edge
            // instead of adding another workspace column.
            item.setColumn(if (self.vertical) 0 else @mod(i, per_line));
            item.setRow(if (self.vertical) i else @divTrunc(i, per_line));
        }
    }
    pub fn tick(self: *Bar) void {
        const now = glib.DateTime.newNowUtc() orelse return;
        defer now.unref();
        self.tickAt(now);
    }
    pub fn tickAt(self: *Bar, now: *glib.DateTime) void {
        for (self.clock_views.items) |*view| view.update(now);
        self.layoutWorkspaces();
        self.fitTasks();
    }
    pub fn reloadClockZones(self: *Bar) void {
        // Drop every reference before resolving again, including shared zones.
        for (self.clock_views.items) |*view| view.deinit();
        for (self.clock_views.items) |*view| view.reload();
    }
    fn serviceName(widget: *gtk.Widget, action: [:0]const u8, detail: [:0]const u8) void {
        w.name(widget, action);
        widget.as(gtk.Accessible).updateProperty(.description, detail.ptr, @as(c_int, -1));
        var buffer: [1024]u8 = undefined;
        widget.setTooltipText(std.fmt.bufPrintZ(&buffer, "{s} · {s}", .{ action, detail }) catch action);
    }
    // Compiled only by the integration hook: measure actual allocated children.
    pub fn layoutReport(self: *Bar, alloc: std.mem.Allocator, keyboard_mode: []const u8) ![]const u8 {
        const Rect = struct { x: f64, y: f64, width: i32, height: i32 };
        const allocation = struct {
            fn read(widget: *gtk.Widget, host: *gtk.Widget) Rect {
                var x: f64 = 0;
                var y: f64 = 0;
                _ = widget.translateCoordinates(host, 0, 0, &x, &y);
                return .{ .x = x, .y = y, .width = widget.getWidth(), .height = widget.getHeight() };
            }
        };
        const Item = struct { name: []const u8, rect: Rect, parts: []const Rect };
        var items: std.ArrayList(Item) = .empty;
        for (self.widgets, 0..) |maybe, i| if (maybe) |widget| {
            if (widget.getVisible() == 0) continue;
            var parts: std.ArrayList(Rect) = .empty;
            const parent = if (object.ext.cast(gtk.Button, widget)) |button| button.getChild() orelse widget else widget;
            var child = parent.getFirstChild();
            while (child) |v| : (child = v.getNextSibling()) {
                if (v.getVisible() != 0) try parts.append(alloc, allocation.read(v, self.host.as(gtk.Widget)));
            }
            try items.append(alloc, .{ .name = @tagName(@as(policy.Item, @enumFromInt(i))), .rect = allocation.read(widget, self.host.as(gtk.Widget)), .parts = try parts.toOwnedSlice(alloc) });
        };
        for (self.clock_views.items) |view| {
            const widget = view.button.as(gtk.Widget);
            var parts: std.ArrayList(Rect) = .empty;
            var child = view.button.getChild().?.getFirstChild();
            while (child) |v| : (child = v.getNextSibling()) if (v.getVisible() != 0) {
                try parts.append(alloc, allocation.read(v, self.host.as(gtk.Widget)));
            };
            try items.append(alloc, .{ .name = view.reference, .rect = allocation.read(widget, self.host.as(gtk.Widget)), .parts = try parts.toOwnedSlice(alloc) });
        }
        var workspace_ids: std.ArrayList([]const u8) = .empty;
        for (self.workspace_handlers.items) |handler| try workspace_ids.append(alloc, handler.id.?);
        const ClockReport = struct { reference: []const u8, timezone: []const u8, time: []const u8, detail: []const u8, available: bool };
        var clock_reports: std.ArrayList(ClockReport) = .empty;
        for (self.clock_views.items) |view| try clock_reports.append(alloc, .{ .reference = view.reference, .timezone = view.definition.timezone, .time = std.mem.span(view.label.getText()), .detail = std.mem.span(view.button.as(gtk.Widget).getTooltipText() orelse ""), .available = view.zone != null });
        return std.json.Stringify.valueAlloc(alloc, .{ .items = items.items, .clocks = clock_reports.items, .background_opacity = self.background_opacity, .background_color = self.background_color, .keyboard_mode = keyboard_mode, .launcher_icon = self.launcher_icon.selection, .launcher_icon_loading = self.launcher_icon.job != null, .launcher_icon_failed = self.launcher_icon.failed, .workspace_mode = self.workspace_mode, .workspace_ids = workspace_ids.items }, .{});
    }
    fn clicked(button: *gtk.Button, data: *Button) callconv(.c) void {
        if (data.event == .pane) data.owner.recordPaneAnchor(button.as(gtk.Widget));
        data.owner.action(data.owner.context, data.event);
    }
    /// Root-relative geometry of the widget that opened a pane, so the popup can
    /// sit under the icon that was clicked. The bar spans the whole edge, so the
    /// cross-axis coordinate is already output-relative.
    fn recordPaneAnchor(self: *Bar, widget: *gtk.Widget) void {
        const root = widget.getRoot() orelse return;
        var x: f64 = 0;
        var y: f64 = 0;
        if (widget.translateCoordinates(root.as(gtk.Widget), 0, 0, &x, &y) == 0) return;
        self.pane_anchor = .{ .x = @intFromFloat(x), .y = @intFromFloat(y), .width = widget.getWidth(), .height = widget.getHeight() };
    }
};
