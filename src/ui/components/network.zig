//! Retained network widgets shared by the compact and standalone frontends.
const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const object = @import("gobject2");
const w = @import("widgets.zig");
pub const model = @import("../../services/network_presentation.zig");
const Text = @import("../../services/policy.zig").Text;
const tr = @import("../../desktop/text.zig").tr;
const focus = @import("../../desktop/focus_state.zig");
const a = std.heap.c_allocator;
pub const Request = struct { action: model.Action, generation: u64, path: []const u8 };
const Row = struct {
    view: *View,
    key: Text(128) = .{},
    path: Text(512) = .{},
    box: *gtk.Box,
    title: *gtk.Label,
    detail: *gtk.Label,
    button: *gtk.Button,
    action: model.Action = .none,
    section: model.Section,
    device: usize = 8,
    strength: u8 = 0,
    present: bool = false,
    signal: c_ulong,
};
pub const View = struct {
    context: *anyopaque,
    request: *const fn (*anyopaque, Request) void,
    compact: bool,
    root: *gtk.Box,
    prompt_host: *gtk.Box,
    status_title: *gtk.Label,
    status_icon: *gtk.Image,
    status_detail: *gtk.Label,
    radio: *gtk.Switch,
    radio_detail: *gtk.Label,
    selector: *gtk.DropDown,
    selector_names: *gtk.StringList,
    selected: Text(512) = .{},
    device_paths: [8]Text(512) = @splat(.{}),
    device_ready: [8]bool = @splat(false),
    choices: [8]usize = @splat(0),
    choice_count: usize = 0,
    device_digest: u64 = 0,
    refresh: *gtk.Button,
    nearby_empty: *gtk.Label,
    nearby_header: *gtk.Box,
    sections: [4]*gtk.Box,
    saved: *gtk.Expander,
    saved_empty: *gtk.Label,
    more: *gtk.Button,
    feedback: *gtk.Box,
    feedback_text: *gtk.Label,
    retry: *gtk.Button,
    cancel: *gtk.Button,
    generation: u64 = 0,
    pending: bool = false,
    scanning: bool = false,
    powered: bool = false,
    cooldown: i64 = 0,
    updating: bool = false,
    rows: [104]?*Row = @splat(null),
    last_path: Text(512) = .{},
    last_action: model.Action = .none,
    last_generation: u64 = 0,
    dismissed: u64 = 0,
    error_hash: u64 = 0,
    status: ?model.Status = null,
    resort: bool = true,
    timer: c_uint = 0,
    signals: std.ArrayList(struct { widget: *object.Object, id: c_ulong }) = .empty,

    pub fn create(host: *gtk.Box, compact: bool, context: *anyopaque, request: @FieldType(View, "request")) !*View {
        const self = try a.create(View);
        const root = w.column(16);
        root.as(gtk.Widget).addCssClass("network-view");
        host.append(root.as(gtk.Widget));
        const status_title = w.label("", "pearl-card-title");
        const status_detail = w.label("", "pearl-secondary");
        const status_box = w.status(.empty, status_title, status_detail);
        const status_icon = object.ext.cast(gtk.Image, status_box.as(gtk.Widget).getFirstChild().?).?;
        root.append(status_box.as(gtk.Widget));
        const radio_card = card();
        root.append(radio_card.as(gtk.Widget));
        const radio = gtk.Switch.new();
        radio.as(gtk.Widget).setValign(.center);
        w.name(radio.as(gtk.Widget), tr("Wi-Fi", "WLAN"));
        focus.tag(radio.as(gtk.Widget), "network-radio", .{});
        const radio_detail = w.label("", "pearl-secondary");
        radio_card.append(w.section(heading(tr("Wi-Fi", "WLAN")), radio_detail, radio.as(gtk.Widget)).as(gtk.Widget));
        const names = gtk.StringList.new(null);
        const selector = gtk.DropDown.new(names.as(@import("gio2").ListModel), null);
        w.name(selector.as(gtk.Widget), tr("Wi-Fi adapter", "WLAN-Adapter"));
        focus.tag(selector.as(gtk.Widget), "network-adapter", .{});
        radio_card.append(selector.as(gtk.Widget));
        var sections: [4]*gtk.Box = undefined;
        for (&sections) |*section| section.* = w.column(8);
        radio_card.append(sections[0].as(gtk.Widget));
        const prompt_host = w.column(8);
        prompt_host.as(gtk.Widget).setVisible(0);
        root.append(prompt_host.as(gtk.Widget));
        const feedback = card();
        const feedback_text = w.label("", "pearl-secondary");
        feedback.append(feedback_text.as(gtk.Widget));
        const feedback_actions = w.flow(3);
        feedback_actions.setHomogeneous(0);
        const retry = w.wrappingButton(tr("Try again", "Erneut versuchen"));
        const dismiss = w.wrappingButton(tr("Dismiss", "Schließen"));
        const cancel = w.wrappingButton(tr("Cancel connection", "Verbindung abbrechen"));
        for ([_]*gtk.Button{ retry, dismiss, cancel }) |button| feedback_actions.insert(button.as(gtk.Widget), -1);
        feedback.append(feedback_actions.as(gtk.Widget));
        root.append(feedback.as(gtk.Widget));
        const nearby_header = w.column(6);
        const refresh = w.wrappingButton(tr("Refresh", "Aktualisieren"));
        focus.tag(refresh.as(gtk.Widget), "network-refresh", .{});
        nearby_header.append(w.section(heading(tr("Nearby networks", "Netzwerke in der Nähe")), null, refresh.as(gtk.Widget)).as(gtk.Widget));
        root.append(nearby_header.as(gtk.Widget));
        root.append(sections[1].as(gtk.Widget));
        const nearby_empty = w.label("", "pearl-secondary");
        root.append(nearby_empty.as(gtk.Widget));
        const more = w.wrappingButton(tr("View all nearby networks", "Alle Netzwerke in der Nähe anzeigen"));
        root.append(more.as(gtk.Widget));
        root.append(sections[2].as(gtk.Widget));
        const saved_title = tr("Saved networks", "Gespeicherte Netzwerke");
        const saved = gtk.Expander.new(null);
        saved.as(gtk.Widget).addCssClass("settings-card");
        saved.as(gtk.Widget).addCssClass("settings-section");
        w.tagExpanderArrow(saved, "settings-section-arrow");
        const saved_heading = w.column(5);
        saved_heading.as(gtk.Widget).addCssClass("settings-section-heading");
        saved_heading.append(w.label(saved_title, "pearl-section-title").as(gtk.Widget));
        saved.setLabelWidget(saved_heading.as(gtk.Widget));
        sections[3].as(gtk.Widget).addCssClass("settings-section-body");
        saved.setChild(sections[3].as(gtk.Widget));
        const saved_empty = w.label(tr("No saved networks", "Keine gespeicherten Netzwerke"), "pearl-secondary");
        sections[3].append(saved_empty.as(gtk.Widget));
        saved.setExpanded(0);
        focus.tag(saved.as(gtk.Widget), "network-saved", .{});
        root.append(saved.as(gtk.Widget));
        saved.as(gtk.Widget).setVisible(@intFromBool(!compact));
        const advanced = w.wrappingButton(tr("Advanced network settings…", "Erweiterte Netzwerkeinstellungen…"));
        const advanced_box = card();
        advanced_box.append(advanced.as(gtk.Widget));
        advanced_box.append(w.label(tr("VPN, hidden networks, IP & DNS. Opens the network editor.", "VPN, versteckte Netzwerke, IP & DNS. Öffnet den Netzwerkeditor."), "pearl-secondary").as(gtk.Widget));
        advanced_box.as(gtk.Widget).setVisible(@intFromBool(!compact));
        root.append(advanced_box.as(gtk.Widget));
        self.* = .{ .saved_empty = saved_empty, .status_icon = status_icon, .context = context, .request = request, .compact = compact, .root = root, .prompt_host = prompt_host, .status_title = status_title, .status_detail = status_detail, .radio = radio, .radio_detail = radio_detail, .selector = selector, .selector_names = names, .refresh = refresh, .nearby_empty = nearby_empty, .nearby_header = nearby_header, .sections = sections, .saved = saved, .more = more, .feedback = feedback, .feedback_text = feedback_text, .retry = retry, .cancel = cancel };
        try self.remember(radio.as(object.Object), gtk.Switch.signals.state_set.connect(radio, *View, radioChanged, self, .{}));
        try self.remember(selector.as(object.Object), object.Object.signals.notify.connect(selector.as(object.Object), *View, adapterChanged, self, .{ .detail = "selected" }));
        inline for (.{ .{ refresh, refreshClicked }, .{ more, moreClicked }, .{ advanced, advancedClicked }, .{ retry, retryClicked }, .{ dismiss, dismissClicked }, .{ cancel, cancelClicked } }) |item| try self.remember(item[0].as(object.Object), gtk.Button.signals.clicked.connect(item[0], *View, item[1], self, .{}));
        self.timer = glib.timeoutAdd(1000, tick, self);
        return self;
    }
    fn remember(self: *View, widget: *object.Object, id: c_ulong) !void {
        try self.signals.append(a, .{ .widget = widget, .id = id });
    }
    fn card() *gtk.Box {
        const box = w.column(8);
        box.as(gtk.Widget).addCssClass("network-card");
        return box;
    }
    fn heading(title: [:0]const u8) *gtk.Label {
        const label = w.label(title, "pearl-section-title");
        label.as(object.Object).set("accessible-role", @intFromEnum(gtk.AccessibleRole.heading), @as(?[*:0]const u8, null));
        label.as(gtk.Accessible).updateProperty(.level, @as(c_int, 2), @as(c_int, -1));
        return label;
    }
    pub fn destroy(self: *View) void {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        for (self.signals.items) |s| object.signalHandlerDisconnect(s.widget, s.id);
        self.signals.deinit(a);
        for (self.rows) |maybe| if (maybe) |row| {
            object.signalHandlerDisconnect(row.button.as(object.Object), row.signal);
            a.destroy(row);
        };
        a.destroy(self);
    }
    fn add(self: *View, spec: model.Row) !*Row {
        const row = try a.create(Row);
        const box = w.row(12);
        box.as(gtk.Widget).addCssClass("network-card");
        const title = w.label("", "pearl-card-title");
        const detail = w.label("", "pearl-secondary");
        const labels = w.column(4);
        labels.as(gtk.Widget).setHexpand(1);
        labels.append(title.as(gtk.Widget));
        labels.append(detail.as(gtk.Widget));
        box.append(labels.as(gtk.Widget));
        const button = w.wrappingButton("");
        object.ext.cast(gtk.Label, button.getChild().?).?.setWrapMode(.word);
        button.as(gtk.Widget).setHalign(.start);
        button.as(gtk.Widget).setValign(.center);
        box.append(button.as(gtk.Widget));
        self.sections[@intFromEnum(spec.section)].append(box.as(gtk.Widget));
        row.* = .{ .view = self, .box = box, .title = title, .detail = detail, .button = button, .section = spec.section, .signal = 0 };
        row.key.set(spec.key);
        focus.tag(button.as(gtk.Widget), "network:{d}:{s}", .{ self.generation, spec.key });
        row.signal = gtk.Button.signals.clicked.connect(button, *Row, rowClicked, row, .{});
        return row;
    }
    pub fn update(self: *View, data: model.Snapshot) void {
        self.updating = true;
        defer self.updating = false;
        const epoch = std.fmt.parseInt(u64, data.generation, 10) catch return;
        if (epoch != self.generation) {
            self.last_action = .none;
            self.dismissed = 0;
        }
        self.generation = epoch;
        self.pending = data.pending;
        self.scanning = data.scanning;
        self.powered = data.radio == .on;
        self.cooldown = glib.getMonotonicTime() + @as(i64, data.scan_wait_ms) * 1000;
        self.status_title.setText(statusTitle(data.status));
        self.status_icon.setFromIconName(if (data.status == .online) "pearl-emblem-ok-symbolic" else if (data.status == .loading) "pearl-content-loading-symbolic" else "pearl-dialog-warning-symbolic");
        self.status_detail.setText(statusDetail(data.status));
        if (self.status != data.status) self.status_title.as(gtk.Accessible).announce(statusTitle(data.status), .low);
        self.status = data.status;
        self.radio.setActive(@intFromBool(data.radio == .on));
        self.radio.setState(@intFromBool(data.radio == .on));
        self.radio.as(gtk.Widget).setSensitive(@intFromBool(data.radio_enabled));
        self.radio_detail.setText(switch (data.radio) {
            .absent => tr("No Wi-Fi adapter found", "Kein WLAN-Adapter gefunden"),
            .blocked => tr("Blocked by hardware. Use your device’s wireless switch.", "Hardware-Sperre. Bitte den WLAN-Schalter am Gerät verwenden."),
            .off => tr("Wi-Fi is turned off. Turn it on to find nearby networks.", "WLAN ist aus. Einschalten, um Netzwerke zu finden."),
            .on => tr("On · Wireless connections", "Ein · Drahtlose Verbindungen"),
        });
        var hash = std.hash.Wyhash.init(0);
        self.choice_count = 0;
        self.device_ready = @splat(false);
        for (data.devices[0..@min(data.devices.len, 8)], 0..) |device, i| {
            self.device_paths[i].set(device.path);
            self.device_ready[i] = device.ready;
            hash.update(device.path);
            hash.update(device.name);
            if (device.wireless) {
                self.choices[self.choice_count] = i;
                self.choice_count += 1;
            }
        }
        if (hash.final() != self.device_digest) {
            self.device_digest = hash.final();
            self.selector_names.splice(0, self.selector_names.as(@import("gio2").ListModel).getNItems(), null);
            var selected_index: c_uint = 0;
            for (self.choices[0..self.choice_count], 0..) |i, j| {
                var name: Text(128) = .{};
                name.set(data.devices[i].name);
                self.selector_names.append(name.z());
                if (std.mem.eql(u8, self.selected.slice(), data.devices[i].path)) selected_index = @intCast(j);
            }
            self.selector.setSelected(selected_index);
            if (self.choice_count > 0) self.selected = self.device_paths[self.choices[selected_index]] else self.selected = .{};
        }
        self.selector.as(gtk.Widget).setVisible(@intFromBool(self.choice_count > 1));
        self.selector.as(gtk.Widget).setSensitive(@intFromBool(!data.pending));
        // Reclaim absent identities before allocating replacements at the cap.
        for (&self.rows) |*slot| if (slot.*) |row| {
            var retained = false;
            for (data.rows) |spec| if (row.section == spec.section and std.mem.eql(u8, row.key.slice(), spec.key)) {
                retained = true;
                break;
            };
            if (!retained) {
                object.signalHandlerDisconnect(row.button.as(object.Object), row.signal);
                self.sections[@intFromEnum(row.section)].remove(row.box.as(gtk.Widget));
                a.destroy(row);
                slot.* = null;
            }
        };
        for (self.rows) |maybe| if (maybe) |row| {
            row.present = false;
        };
        for (data.rows[0..@min(data.rows.len, 104)]) |spec| {
            var found: ?*Row = null;
            for (self.rows) |maybe| if (maybe) |row| if (row.section == spec.section and std.mem.eql(u8, row.key.slice(), spec.key)) {
                found = row;
                break;
            };
            const row = found orelse blk: {
                for (&self.rows) |*slot| if (slot.* == null) {
                    slot.* = self.add(spec) catch break :blk null;
                    break :blk slot.*;
                };
                break :blk null;
            } orelse continue;
            row.present = true;
            focus.tag(row.button.as(gtk.Widget), "network:{d}:{s}", .{ self.generation, spec.key });
            row.device = spec.device;
            row.path.set(spec.path);
            row.action = spec.action;
            row.strength = spec.strength;
            var title: Text(128) = .{};
            title.set(spec.title);
            row.title.setText(title.z());
            var buffer: [1024]u8 = undefined;
            const detail = if (spec.section == .nearby or spec.section == .connected) std.fmt.bufPrintZ(&buffer, "{s}{s}{s} · {s}", .{ if (spec.state == .connecting) tr("Connecting…", "Verbindung wird hergestellt…") else if (spec.state == .connected) tr("Connected", "Verbunden") else "", if (spec.state == .connecting or spec.state == .connected) " · " else "", signalTitle(spec.strength), if (spec.profiles > 1) tr("Choose a saved profile", "Gespeichertes Profil wählen") else securityTitle(spec.security) }) catch "" else std.fmt.bufPrintZ(&buffer, "{s}{s}{s}", .{ stateTitle(spec.state), if (spec.section == .ethernet) " · " else "", if (spec.section == .ethernet and spec.device < data.devices.len) data.devices[spec.device].name else "" }) catch "";
            row.detail.setText(detail);
            row.button.setLabel(actionTitle(spec.action));
            row.button.as(gtk.Widget).setSensitive(@intFromBool(spec.enabled));
            row.button.as(gtk.Widget).setVisible(@intFromBool(spec.action != .none));
            w.name(row.button.as(gtk.Widget), std.fmt.bufPrintZ(&buffer, "{s}: {s}", .{ spec.title, actionTitle(spec.action) }) catch actionTitle(spec.action));
        }
        for (&self.rows) |*slot| if (slot.*) |row| if (!row.present) {
            object.signalHandlerDisconnect(row.button.as(object.Object), row.signal);
            self.sections[@intFromEnum(row.section)].remove(row.box.as(gtk.Widget));
            a.destroy(row);
            slot.* = null;
        };
        self.error_hash = std.hash.Wyhash.hash(0, data.error_message);
        const show_error = data.error_message.len > 0 and self.error_hash != self.dismissed;
        self.feedback.as(gtk.Widget).setVisible(@intFromBool(show_error or data.pending or data.truncated));
        var error_text: Text(1024) = .{};
        error_text.set(if (show_error) data.error_message else if (data.pending) tr("Connection change in progress…", "Netzwerkänderung wird ausgeführt…") else tr("This list is incomplete. The service reported more networks than it can expose.", "Diese Liste ist unvollständig. Der Dienst meldet zu viele Netzwerke."));
        self.feedback_text.setText(error_text.z());
        self.retry.as(gtk.Widget).setVisible(@intFromBool(show_error and !data.pending and self.last_action != .none and self.last_generation == epoch));
        self.cancel.as(gtk.Widget).setVisible(@intFromBool(data.pending and data.owned));
        self.more.as(gtk.Widget).setSensitive(@intFromBool(!(data.pending and data.owned)));
        if (self.resort and !data.pending) {
            std.mem.sort(?*Row, &self.rows, {}, struct {
                fn less(_: void, lhs: ?*Row, rhs: ?*Row) bool {
                    const left = lhs orelse return false;
                    const right = rhs orelse return true;
                    if (left.section != right.section) return @intFromEnum(left.section) < @intFromEnum(right.section);
                    if (left.strength != right.strength) return left.strength > right.strength;
                    return std.mem.lessThan(u8, std.mem.span(left.title.getText()), std.mem.span(right.title.getText()));
                }
            }.less);
            var previous: [4]?*gtk.Widget = @splat(null);
            for (data.rows) |spec| for (self.rows) |maybe| if (maybe) |row| if (std.mem.eql(u8, row.key.slice(), spec.key)) {
                const section = @intFromEnum(row.section);
                self.sections[section].reorderChildAfter(row.box.as(gtk.Widget), previous[section]);
                previous[section] = row.box.as(gtk.Widget);
                break;
            };
            self.resort = false;
        }
        self.filter();
    }
    fn filter(self: *View) void {
        var count: usize = 0;
        var connected: usize = 0;
        var wired: usize = 0;
        var saved: usize = 0;
        for (self.rows) |maybe| if (maybe) |row| {
            var visible = row.present;
            if (row.section == .nearby or row.section == .connected) visible = visible and row.device < 8 and std.mem.eql(u8, self.device_paths[row.device].slice(), self.selected.slice());
            if (row.section == .nearby and visible) {
                count += 1;
                if (self.compact and count > 3) visible = false;
            }
            if (row.section == .connected and visible) connected += 1;
            if (self.compact and row.section == .ethernet) visible = visible and row.action == .disconnect;
            if (row.section == .ethernet and visible) wired += 1;
            if (row.section == .saved) saved += 1;
            row.box.as(gtk.Widget).setVisible(@intFromBool(visible));
        };
        self.sections[0].as(gtk.Widget).setVisible(@intFromBool(connected > 0));
        self.sections[2].as(gtk.Widget).setVisible(@intFromBool(wired > 0));
        self.saved_empty.as(gtk.Widget).setVisible(@intFromBool(saved == 0));
        self.nearby_header.as(gtk.Widget).setVisible(@intFromBool(self.powered));
        self.nearby_empty.as(gtk.Widget).setVisible(@intFromBool(self.powered and count == 0));
        self.nearby_empty.setText(tr("Refresh to look for nearby networks.", "Aktualisieren, um nach Netzwerken zu suchen."));
        self.more.as(gtk.Widget).setVisible(@intFromBool(self.compact and count > 3));
        if (self.powered) self.radio_detail.setText(if (connected == 0) tr("On · Not connected", "Ein · Nicht verbunden") else tr("On · Connected", "Ein · Verbunden"));
        self.updateRefresh();
    }
    pub fn restoreFocus(self: *View) void {
        for (self.rows) |maybe| if (maybe) |row| if (std.mem.eql(u8, row.path.slice(), self.last_path.slice()) and row.button.as(gtk.Widget).isSensitive() != 0 and row.box.as(gtk.Widget).getMapped() != 0) {
            _ = row.button.as(gtk.Widget).grabFocus();
            return;
        };
        _ = self.radio.as(gtk.Widget).grabFocus();
    }
    fn updateRefresh(self: *View) void {
        var ready = false;
        for (self.device_paths, self.device_ready) |path, is_ready| if (std.mem.eql(u8, path.slice(), self.selected.slice())) {
            ready = is_ready;
            break;
        };
        const waiting = glib.getMonotonicTime() < self.cooldown;
        self.refresh.setLabel(if (self.scanning) tr("Refreshing…", "Wird aktualisiert…") else tr("Refresh", "Aktualisieren"));
        self.refresh.as(gtk.Widget).setSensitive(@intFromBool(ready and self.powered and !self.scanning and !self.pending and !waiting));
        self.refresh.as(gtk.Widget).setTooltipText(if (waiting) tr("Please wait before refreshing again.", "Bitte vor dem erneuten Aktualisieren kurz warten.") else null);
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(data.?));
        for (self.rows) |maybe| if (maybe) |row| {
            // Adapt to the actual row, including nested connected cards and font scaling.
            var natural: c_int = 0;
            row.button.as(gtk.Widget).measure(.horizontal, -1, null, &natural, null, null);
            const narrow = row.box.as(gtk.Widget).getWidth() < @max(330, natural * 3);
            row.box.as(gtk.Orientable).setOrientation(if (narrow) .vertical else .horizontal);
        };
        self.updateRefresh();
        return 1;
    }
    fn send(self: *View, action: model.Action, path: []const u8) void {
        if (self.updating) return;
        if (action == .profiles) {
            if (self.compact) self.request(self.context, .{ .action = .settings, .generation = self.generation, .path = "" }) else {
                self.saved.setExpanded(1);
                _ = self.saved.as(gtk.Widget).grabFocus();
            }
            return;
        }
        if (action == .connect or action == .connect_saved) {
            self.last_action = action;
            self.last_path.set(path);
            self.last_generation = self.generation;
            self.dismissed = 0;
        }
        self.request(self.context, .{ .action = action, .generation = self.generation, .path = path });
    }
    fn rowClicked(_: *gtk.Button, row: *Row) callconv(.c) void {
        row.view.send(row.action, row.path.slice());
    }
    fn radioChanged(_: *gtk.Switch, state: c_int, self: *View) callconv(.c) c_int {
        if (!self.updating and (state != 0) != self.powered) self.send(if (state != 0) .enable else .disable, "");
        return 1;
    }
    fn adapterChanged(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        if (self.updating) return;
        const i = self.selector.getSelected();
        if (i >= self.choice_count) return;
        self.selected = self.device_paths[self.choices[i]];
        self.filter();
    }
    fn refreshClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.resort = true;
        self.send(.scan, self.selected.slice());
    }
    fn moreClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.send(.settings, "");
    }
    fn advancedClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.send(.editor, "");
    }
    fn retryClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        if (self.last_generation == self.generation) self.send(self.last_action, self.last_path.slice());
    }
    fn dismissClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.dismissed = self.error_hash;
        self.feedback.as(gtk.Widget).setVisible(0);
    }
    fn cancelClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.send(.cancel, "");
    }
};
pub fn statusTitle(value: model.Status) [:0]const u8 {
    return switch (value) {
        .loading => tr("Loading network connections…", "Netzwerkverbindungen werden geladen…"),
        .unavailable => tr("Network service unavailable", "Netzwerkdienst nicht verfügbar"),
        .unknown => tr("Internet status unknown", "Internetstatus unbekannt"),
        .offline => tr("No internet connection", "Keine Internetverbindung"),
        .portal => tr("Sign-in required", "Anmeldung erforderlich"),
        .limited => tr("Limited connection", "Eingeschränkte Verbindung"),
        .online => tr("Internet available", "Internet verfügbar"),
    };
}
fn statusDetail(value: model.Status) [:0]const u8 {
    return switch (value) {
        .unavailable => tr("Waiting for the network service to reconnect.", "Warten auf die Wiederverbindung des Netzwerkdienstes."),
        .portal => tr("Open your browser to sign in to this network.", "Den Browser öffnen, um sich bei diesem Netzwerk anzumelden."),
        .limited => tr("Connected to a network, but internet access may be restricted.", "Mit einem Netzwerk verbunden, aber der Internetzugang kann eingeschränkt sein."),
        .online => tr("Your device has internet access.", "Dein Gerät hat Internetzugang."),
        .offline => tr("Choose a network below to connect.", "Zum Verbinden ein Netzwerk auswählen."),
        else => "",
    };
}
fn signalTitle(value: u8) [:0]const u8 {
    return switch (model.signal(value)) {
        .strong => tr("Strong signal", "Starkes Signal"),
        .good => tr("Good signal", "Gutes Signal"),
        .weak => tr("Weak signal", "Schwaches Signal"),
    };
}
fn securityTitle(value: @import("../../services/connectivity_policy.zig").Security) [:0]const u8 {
    return switch (value) {
        .open => tr("Open network", "Offenes Netzwerk"),
        .psk, .sae => tr("Secured", "Gesichert"),
        .advanced => tr("Additional setup required", "Weitere Einrichtung erforderlich"),
    };
}
fn stateTitle(value: model.State) [:0]const u8 {
    return switch (value) {
        .connected => tr("Connected", "Verbunden"),
        .disconnected => tr("Disconnected", "Nicht verbunden"),
        .unavailable => tr("Adapter unavailable", "Adapter nicht verfügbar"),
        .available => tr("Available", "Verfügbar"),
        .saved => tr("Saved connection", "Gespeicherte Verbindung"),
        .out_of_range => tr("Not in range", "Außer Reichweite"),
        .connecting => tr("Connecting…", "Verbindung wird hergestellt…"),
    };
}
fn actionTitle(value: model.Action) [:0]const u8 {
    return switch (value) {
        .connect, .connect_saved => tr("Connect", "Verbinden"),
        .disconnect => tr("Disconnect", "Trennen"),
        .editor => tr("Set up…", "Einrichten…"),
        .profiles => tr("Choose profile…", "Profil wählen…"),
        else => "",
    };
}
