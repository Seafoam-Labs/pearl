//! Live per-output bar; callbacks carry opaque IDs, never workspace numbers/titles.
const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const object = @import("gobject2");
const Client = @import("../aqueous/client.zig").Client;
const policy = @import("policy.zig");
const w = @import("../ui/components/widgets.zig");
const tr = @import("text.zig").tr;
const a = std.heap.c_allocator;
pub const Pane = enum { clipboard_capture, aqueous_settings, settings, launcher, calendar, control, notifications, media, tray };
pub const Event = union(enum) { pane: Pane, settings: @import("settings_navigation.zig").Route, workspace: []const u8, keyboard, overview };
const Button = struct { owner: *Bar, event: Event, id: ?[]u8 = null };
pub const Bar = struct {
    host: *gtk.Box,
    audio_service: *@import("../services/audio.zig").Audio,
    power_service: *@import("../services/power.zig").Power,
    network_service: *@import("../services/network.zig").Network,
    bluetooth_service: *@import("../services/bluetooth.zig").Bluetooth,
    session_services: *@import("../services/session.zig").Session,
    plugins: ?*@import("../plugins/manager.zig").Manager = null,
    plugin_views: std.ArrayList(*@import("../plugins/view.zig").View) = .empty,
    tray: ?*@import("tray.zig").Bar = null,
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
    workspace_hash: u64 = 0,
    title: ?*gtk.Label = null,
    clock: ?*gtk.Label = null,
    clock_date: ?*gtk.Label = null,
    keyboard: ?*gtk.Label = null,
    islands: bool = true,
    sections: [3]?*gtk.Widget = @splat(null),
    vertical: bool = false,
    compact: bool = false,
    length: i32 = 1280,
    pub fn create(host: *gtk.Box, client: *Client, output: []const u8, context: *anyopaque, action: @FieldType(Bar, "action"), audio: *@import("../services/audio.zig").Audio, power: *@import("../services/power.zig").Power, network: *@import("../services/network.zig").Network, bluetooth: *@import("../services/bluetooth.zig").Bluetooth, session: *@import("../services/session.zig").Session, plugins: ?*@import("../plugins/manager.zig").Manager) !*Bar {
        const self = try a.create(Bar);
        self.* = .{ .host = host, .plugins = plugins, .session_services = session, .audio_service = audio, .power_service = power, .network_service = network, .bluetooth_service = bluetooth, .client = client, .output = output, .context = context, .action = action, .groups = undefined };
        self.groups = .{ try a.dupeZ(u8, "launcher,workspaces,title"), try a.dupeZ(u8, "clock"), try a.dupeZ(u8, (policy.Groups{}).right) };
        try self.build();
        return self;
    }
    pub fn destroy(self: *Bar) void {
        self.clear();
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
        self.clock = null;
        self.clock_date = null;
        self.keyboard = null;
        self.audio_label = null;
        self.battery_label = null;
        self.network_label = null;
        self.bluetooth_label = null;
        self.workspace_hash = 0;
    }
    pub fn configure(self: *Bar, groups: policy.Groups) !void {
        try groups.validate();
        var next: [3][:0]u8 = undefined;
        var count: usize = 0;
        errdefer for (next[0..count]) |v| a.free(v);
        for ([_][]const u8{ groups.left, groups.center, groups.right }, 0..) |g, i| {
            next[i] = try a.dupeZ(u8, g);
            count += 1;
        }
        for (self.groups) |g| a.free(g);
        self.groups = next;
        try self.build();
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
                const item = std.meta.stringToEnum(policy.Item, part) orelse continue;
                const widget: *gtk.Widget = switch (item) {
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
                    .launcher => (try self.makeButton(.{ .pane = .launcher }, "pearl-application-x-executable-symbolic", tr("Applications", "Programme"), false)).as(gtk.Widget),
                    .overview => (try self.makeButton(.overview, "pearl-view-grid-symbolic", tr("Overview", "Übersicht"), false)).as(gtk.Widget),
                    .clipboard => (try self.makeButton(.{ .pane = .clipboard_capture }, "pearl-edit-copy-symbolic", tr("Clipboard & capture", "Zwischenablage & Bildschirmfoto"), false)).as(gtk.Widget),
                    .control => (try self.makeButton(.{ .settings = .overview }, "pearl-emblem-system-symbolic", tr("Open settings Overview", "Einstellungsübersicht öffnen"), false)).as(gtk.Widget),
                    .clock => blk: {
                        const button = try self.makeButton(.{ .pane = .calendar }, null, "", false);
                        self.clock = gtk.Label.new("");
                        self.clock.?.setJustify(.center);
                        if (self.vertical) {
                            const content = gtk.Box.new(.vertical, 4);
                            self.clock_date = gtk.Label.new("");
                            self.clock_date.?.setJustify(.center);
                            self.clock_date.?.setEllipsize(.end);
                            self.clock_date.?.setMaxWidthChars(3);
                            self.clock_date.?.as(gtk.Widget).addCssClass("pearl-bar-value");
                            content.append(self.clock_date.?.as(gtk.Widget));
                            content.append(self.clock.?.as(gtk.Widget));
                            button.setChild(content.as(gtk.Widget));
                        } else button.setChild(self.clock.?.as(gtk.Widget));
                        break :blk button.as(gtk.Widget);
                    },
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
    }
    fn fit(self: *Bar) void {
        if (self.tray) |tray| tray.setLimit(if (self.compact or self.vertical) 2 else 4);
        if (self.media_label) |label| label.as(gtk.Widget).setVisible(@intFromBool(!self.compact and !self.vertical));
        if (self.widgets[@intFromEnum(policy.Item.title)]) |v| v.setVisible(@intFromBool(!self.compact and !self.vertical));
        if (self.widgets[@intFromEnum(policy.Item.overview)]) |v| v.setVisible(@intFromBool(!self.compact));
        self.layoutWorkspaces();
        // Primary controls survive; overview also lives in the control center.
    }
    fn openTray(data: *anyopaque) void {
        const self: *Bar = @ptrCast(@alignCast(data));
        self.action(self.context, .{ .pane = .tray });
    }
    pub fn update(self: *Bar) void {
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
            var hash = std.hash.Wyhash.init(0);
            for (list) |ws| {
                hash.update(ws.id);
                hash.update(ws.name);
                hash.update(&.{ @intFromBool(ws.active), @intFromBool(ws.urgent) });
            }
            const value = hash.final();
            if (value != self.workspace_hash) {
                self.workspace_hash = value;
                const box = object.ext.cast(gtk.Grid, host).?;
                while (host.getFirstChild()) |child| box.remove(child);
                freeHandlers(&self.workspace_handlers);
                for (list, 0..) |ws, i| {
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
        if (self.clock) |label| {
            const now = glib.DateTime.newNowLocal() orelse return;
            defer now.unref();
            const text = now.format(if (self.vertical) "%H\n%M" else "%a %d %b · %H:%M") orelse return;
            defer glib.free(text);
            label.setText(text);
            if (self.clock_date) |date| {
                const day_month = now.format("%a\n%d\n%b") orelse return;
                defer glib.free(day_month);
                date.setText(day_month);
            }
            const detail = now.format("%A, %d %B %Y · %H:%M") orelse return;
            defer glib.free(detail);
            const widget = self.widgets[@intFromEnum(policy.Item.clock)].?;
            widget.setTooltipText(detail);
            w.name(widget, detail);
        }
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
        return std.json.Stringify.valueAlloc(alloc, .{ .items = items.items, .keyboard_mode = keyboard_mode }, .{});
    }
    fn clicked(_: *gtk.Button, button: *Button) callconv(.c) void {
        button.owner.action(button.owner.context, button.event);
    }
};
