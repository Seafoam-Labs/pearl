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
pub const Pane = enum { launcher, calendar, control, notifications, media, tray };
pub const Event = union(enum) { pane: Pane, workspace: []const u8, keyboard, overview };
const Button = struct { owner: *Bar, event: Event, id: ?[]u8 = null };
pub const Bar = struct {
    host: *gtk.Box,
    audio_service: *@import("../services/audio.zig").Audio,
    power_service: *@import("../services/power.zig").Power,
    network_service: *@import("../services/network.zig").Network,
    bluetooth_service: *@import("../services/bluetooth.zig").Bluetooth,
    session_services: *@import("../services/session.zig").Session,
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
    workspace_view: ?*gtk.ScrolledWindow = null,
    active_workspace: ?*gtk.Widget = null,
    reveal_workspace: bool = false,
    title: ?*gtk.Label = null,
    clock: ?*gtk.Label = null,
    keyboard: ?*gtk.Label = null,
    vertical: bool = false,
    compact: bool = false,
    pub fn create(host: *gtk.Box, client: *Client, output: []const u8, context: *anyopaque, action: @FieldType(Bar, "action"), audio: *@import("../services/audio.zig").Audio, power: *@import("../services/power.zig").Power, network: *@import("../services/network.zig").Network, bluetooth: *@import("../services/bluetooth.zig").Bluetooth, session: *@import("../services/session.zig").Session) !*Bar {
        const self = try a.create(Bar);
        self.* = .{ .host = host, .session_services = session, .audio_service = audio, .power_service = power, .network_service = network, .bluetooth_service = bluetooth, .client = client, .output = output, .context = context, .action = action, .groups = undefined };
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
        if (self.tray) |tray| tray.destroy(); self.tray = null; self.notification_label = null; self.media_label = null;
        while (self.host.as(gtk.Widget).getFirstChild()) |child| self.host.remove(child);
        freeHandlers(&self.handlers);
        freeHandlers(&self.workspace_handlers);
        self.widgets = @splat(null);
        self.title = null;
        self.clock = null;
        self.keyboard = null;
        self.audio_label = null;
        self.battery_label = null;
        self.network_label = null;
        self.bluetooth_label = null;
        self.workspace_hash = 0;
        self.workspace_view = null;
        self.active_workspace = null;
        self.reveal_workspace = false;
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
    fn makeButton(self: *Bar, event: Event, icon: ?[*:0]const u8, text: [*:0]const u8, workspace: bool) !*gtk.Button {
        const b = try a.create(Button);
        errdefer a.destroy(b);
        b.* = .{ .owner = self, .event = event };
        if (event == .workspace) {
            b.id = try a.dupe(u8, event.workspace);
            b.event = .{ .workspace = b.id.? };
        }
        try (if (workspace) &self.workspace_handlers else &self.handlers).append(a, b);
        const button = if (icon) |symbol| w.iconButton(symbol, text) else gtk.Button.newWithLabel(text);
        _ = gtk.Button.signals.clicked.connect(button, *Button, clicked, b, .{});
        return button;
    }
    fn build(self: *Bar) !void {
        self.clear();
        self.host.as(gtk.Orientable).setOrientation(if (self.vertical) .vertical else .horizontal);
        self.host.setSpacing(8);
        const center = gtk.CenterBox.new();
        center.as(gtk.Orientable).setOrientation(if (self.vertical) .vertical else .horizontal);
        center.as(gtk.Widget).setHexpand(1);
        center.as(gtk.Widget).setVexpand(1);
        self.host.append(center.as(gtk.Widget));
        for (self.groups, 0..) |group, section| {
            const box = gtk.Box.new(if (self.vertical) .vertical else .horizontal, 4);
            if (self.vertical) box.as(gtk.Widget).setVexpand(@intFromBool(section != 1)) else box.as(gtk.Widget).setHexpand(@intFromBool(section != 1));
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
                const item = std.meta.stringToEnum(policy.Item, part) orelse continue;
                const widget: *gtk.Widget = switch (item) {
                    .tray => blk: {
                        const tray_host = gtk.Box.new(if (self.vertical) .vertical else .horizontal, 2);
                        self.tray = try @import("tray.zig").Bar.create(tray_host, &self.session_services.tray, self, openTray);
                        break :blk tray_host.as(gtk.Widget);
                    },
                    .notifications, .media => blk: {
                        const button = try self.makeButton(.{ .pane = if (item == .media) .media else .notifications }, null, "", false);
                        const content = w.row(4); content.append(w.icon(if (item == .media) "pearl-media-symbolic" else "pearl-notifications-symbolic").as(gtk.Widget));
                        const label = gtk.Label.new(""); label.setEllipsize(.end); label.setMaxWidthChars(if (item == .media) 16 else 4); content.append(label.as(gtk.Widget)); button.setChild(content.as(gtk.Widget));
                        if (item == .media) self.media_label = label else self.notification_label = label;
                        w.name(button.as(gtk.Widget), if (item == .media) "Media" else "Notifications");
                        break :blk button.as(gtk.Widget);
                    },
                    .launcher => (try self.makeButton(.{ .pane = .launcher }, "pearl-application-x-executable-symbolic", tr("Applications", "Programme"), false)).as(gtk.Widget),
                    .overview => (try self.makeButton(.overview, "pearl-view-grid-symbolic", tr("Overview", "Übersicht"), false)).as(gtk.Widget),
                    .control => (try self.makeButton(.{ .pane = .control }, "pearl-emblem-system-symbolic", tr("Control center", "Schnelleinstellungen"), false)).as(gtk.Widget),
                    .clock => blk: {
                        const button = try self.makeButton(.{ .pane = .calendar }, null, "", false);
                        self.clock = gtk.Label.new("");
                        button.setChild(self.clock.?.as(gtk.Widget));
                        break :blk button.as(gtk.Widget);
                    },
                    .audio, .battery, .network, .bluetooth => blk: {
                        const button = try self.makeButton(.{ .pane = .control }, null, "", false);
                        const content = w.row(4);
                        content.append(w.icon(switch (item) {
                            .audio => "pearl-audio-volume-high-symbolic",
                            .battery => "pearl-battery-symbolic",
                            .network => "pearl-network-wireless-symbolic",
                            .bluetooth => "pearl-bluetooth-active-symbolic",
                            else => unreachable,
                        }).as(gtk.Widget));
                        const label = gtk.Label.new("");
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
                        self.keyboard.?.setMaxWidthChars(14);
                        button.setChild(self.keyboard.?.as(gtk.Widget));
                        break :blk button.as(gtk.Widget);
                    },
                    .title => blk: {
                        const title = gtk.Label.new("");
                        title.setXalign(0);
                        title.setEllipsize(.end);
                        title.setMaxWidthChars(28);
                        title.as(gtk.Widget).setHexpand(1);
                        title.as(gtk.Widget).setMarginStart(8);
                        self.title = title;
                        break :blk title.as(gtk.Widget);
                    },
                    .workspaces => gtk.Box.new(if (self.vertical) .vertical else .horizontal, 2).as(gtk.Widget),
                };
                widget.addCssClass("pearl-bar-item");
                self.widgets[@intFromEnum(item)] = widget;
                if (item == .workspaces) {
                    const scroll = gtk.ScrolledWindow.new();
                    self.workspace_view = scroll;
                    scroll.setPolicy(if (self.vertical) .never else .external, if (self.vertical) .external else .never);
                    scroll.setPropagateNaturalWidth(1);
                    scroll.setPropagateNaturalHeight(1);
                    scroll.setMaxContentWidth(if (self.vertical) 120 else 280);
                    scroll.setMaxContentHeight(if (self.vertical) 280 else 40);
                    scroll.setChild(widget);
                    box.append(scroll.as(gtk.Widget));
                } else box.append(widget);
            }
        }
        self.update();
        self.tick();
        self.fit();
    }
    pub fn geometry(self: *Bar, vertical: bool, length: i32) void {
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
    }
    fn fit(self: *Bar) void {
        if (self.widgets[@intFromEnum(policy.Item.title)]) |v| v.setVisible(@intFromBool(!self.compact and !self.vertical));
        if (self.widgets[@intFromEnum(policy.Item.overview)]) |v| v.setVisible(@intFromBool(!self.compact));
        // Primary controls survive; overview also lives in the control center.
    }
    fn openTray(data: *anyopaque) void { const self: *Bar = @ptrCast(@alignCast(data)); self.action(self.context, .{ .pane = .tray }); }
    pub fn update(self: *Bar) void {
        if (self.tray) |tray| tray.update();
        if (self.notification_label) |label| {
            var count: usize = 0; for (&self.session_services.notifications.model.records) |*r| if (r.id != 0) { count += 1; };
            var buf: [20]u8 = undefined; label.setText(std.fmt.bufPrintZ(&buf, "{s}{d}", .{if (self.session_services.notifications.model.dnd) "− " else "", count}) catch "");
        }
        if (self.media_label) |label| label.setText(if (self.session_services.media.current()) |p| p.title.z() else "");
        var service_buffer: [256]u8 = undefined;
        if (self.audio_label) |label| {
            const device = self.audio_service.default(.sink);
            label.setText(if (device) |d| if (d.mute) tr("Muted", "Stumm") else std.fmt.bufPrintZ(&service_buffer, "{d}%", .{d.volume}) catch "" else "—");
            const widget = self.widgets[@intFromEnum(policy.Item.audio)].?;
            widget.setTooltipText(if (device) |d| d.label.z() else tr("Audio unavailable", "Audio nicht verfügbar"));
            w.name(widget, if (device != null) tr("Audio controls", "Audiosteuerung") else tr("Audio unavailable", "Audio nicht verfügbar"));
        }
        if (self.battery_label) |label| {
            label.setText(std.fmt.bufPrintZ(&service_buffer, "{d:.0}%", .{self.power_service.percentage}) catch "");
            const widget = self.widgets[@intFromEnum(policy.Item.battery)].?;
            widget.setVisible(@intFromBool(self.power_service.battery_present));
            widget.setTooltipText(if (self.power_service.battery_state == 1) tr("Battery charging", "Akku lädt") else tr("Battery and power", "Akku und Energie"));
            w.name(widget, tr("Battery and power", "Akku und Energie"));
        }
        if (self.network_label) |label| {
            const n = self.network_service;
            var connected = false;
            for (n.devices[0..n.device_count]) |dev| if (dev.state == 100) {
                connected = true;
            };
            label.setText(if (n.peer.snapshot == null) "—" else if (n.pending) "…" else if (connected) "On" else if (n.enabled) "Wi-Fi" else "Off");
            const widget = self.widgets[@intFromEnum(policy.Item.network)].?;
            widget.setTooltipText(if (n.peer.snapshot == null) "Network unavailable" else if (connected) "Network connected · open network controls" else "Open network controls");
            w.name(widget, "Network controls");
        }
        if (self.bluetooth_label) |label| {
            const b = self.bluetooth_service;
            var connected: usize = 0;
            for (b.devices[0..b.device_count]) |dev| if (dev.connected) {
                connected += 1;
            };
            label.setText(if (b.peer.snapshot == null) "—" else std.fmt.bufPrintZ(&service_buffer, "{d}", .{connected}) catch "");
            const widget = self.widgets[@intFromEnum(policy.Item.bluetooth)].?;
            widget.setTooltipText("Bluetooth controls");
            w.name(widget, "Bluetooth controls");
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
            label.setText(value);
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
                const box = object.ext.cast(gtk.Box, host).?;
                while (host.getFirstChild()) |child| box.remove(child);
                freeHandlers(&self.workspace_handlers);
                self.active_workspace = null;
                self.reveal_workspace = false;
                for (list[0..@min(list.len, 128)]) |ws| {
                    var buffer: [20]u8 = undefined;
                    const number = std.fmt.bufPrintZ(&buffer, "{d}", .{ws.number}) catch unreachable;
                    const button = self.makeButton(.{ .workspace = ws.id }, null, number, true) catch continue;
                    const tooltip = std.fmt.allocPrintSentinel(a, "{s} · {s}", .{ ws.name, ws.id }, 0) catch continue;
                    defer a.free(tooltip);
                    button.as(gtk.Widget).setTooltipText(tooltip);
                    w.name(button.as(gtk.Widget), tooltip);
                    button.as(gtk.Widget).addCssClass(if (ws.active) "pearl-workspace-active" else "pearl-workspace");
                    if (ws.urgent) button.as(gtk.Widget).addCssClass("pearl-urgent");
                    if (ws.active) {
                        self.active_workspace = button.as(gtk.Widget);
                        self.reveal_workspace = true;
                    }
                    box.append(button.as(gtk.Widget));
                }
            }
        }
    }
    pub fn painted(self: *Bar) void {
        if (!self.reveal_workspace) return;
        const active = self.active_workspace orelse return;
        const scroll = self.workspace_view orelse return;
        const adjustment = if (self.vertical) scroll.getVadjustment() else scroll.getHadjustment();
        const page = adjustment.getPageSize();
        var rect: gtk.Allocation = undefined;
        active.getAllocation(&rect);
        const start: f64 = @floatFromInt(if (self.vertical) rect.f_y else rect.f_x);
        const length: f64 = @floatFromInt(if (self.vertical) rect.f_height else rect.f_width);
        if (page <= 0 or length <= 0) return;
        self.reveal_workspace = false;
        const position = adjustment.getValue();
        if (start < position) adjustment.setValue(start) else if (start + length > position + page) adjustment.setValue(start + length - page);
    }
    pub fn tick(self: *Bar) void {
        if (self.clock) |label| {
            const now = glib.DateTime.newNowLocal() orelse return;
            defer now.unref();
            const text = now.format(if (self.vertical) "%H\n%M" else "%a %d · %H:%M") orelse return;
            defer glib.free(text);
            label.setText(text);
            const detail = now.format("%A, %d %B %Y") orelse return;
            defer glib.free(detail);
            label.as(gtk.Widget).setTooltipText(detail);
        }
    }
    fn clicked(_: *gtk.Button, button: *Button) callconv(.c) void {
        button.owner.action(button.owner.context, button.event);
    }
};
