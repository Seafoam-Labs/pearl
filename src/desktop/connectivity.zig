const std = @import("std");
const gtk = @import("gtk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const Network = @import("../services/network.zig").Network;
const Bluetooth = @import("../services/bluetooth.zig").Bluetooth;
const Text = @import("../services/policy.zig").Text;
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;
const Connection = struct { object: *object.Object, id: c_ulong };
const Kind = enum { device, ap, saved, adapter, bluetooth };
const Row = struct { view: *View, kind: Kind, path: Text(512), epoch: u64, title: *gtk.Label, primary: *gtk.Button, secondary: *gtk.Button };
const Prompt = struct { box: *gtk.Box, title: *gtk.Label, entry: *gtk.PasswordEntry, accept: *gtk.Button, cancel: *gtk.Button, serial: u64 = 0, reveal_tick: c_uint = 0, reveal_frames: u8 = 0 };
pub const View = struct {
    network: *Network,
    bluetooth: *Bluetooth,
    net_status: *gtk.Label,
    bt_status: *gtk.Label,
    radio: *gtk.Button,
    net_cancel: *gtk.Button,
    bt_cancel: *gtk.Button,
    scan_stop: *gtk.Button,
    net_list: *gtk.Box,
    bt_list: *gtk.Box,
    net_expander: *gtk.Expander,
    bt_expander: *gtk.Expander,
    net_prompt: Prompt,
    bt_prompt: Prompt,
    rows: [176]Row = undefined,
    count: usize = 0,
    connections: std.ArrayList(Connection) = .empty,
    row_connections: std.ArrayList(Connection) = .empty,
    probe_focus: ?*gtk.Widget = null,
    pub fn create(host: *gtk.Box, network: *Network, bluetooth: *Bluetooth) !*View {
        const self = try a.create(View);
        self.* = .{ .network = network, .bluetooth = bluetooth, .net_status = undefined, .bt_status = undefined, .radio = undefined, .net_cancel = undefined, .bt_cancel = undefined, .scan_stop = undefined, .net_list = undefined, .bt_list = undefined, .net_expander = undefined, .bt_expander = undefined, .net_prompt = undefined, .bt_prompt = undefined };
        const net = w.card();
        host.append(net.as(gtk.Widget));
        const heading = w.row(10);
        net.append(heading.as(gtk.Widget));
        heading.append(w.icon("pearl-network-wireless-symbolic").as(gtk.Widget));
        heading.append(w.label("Network", "pearl-card-title").as(gtk.Widget));
        self.net_status = w.label("", "pearl-secondary");
        net.append(self.net_status.as(gtk.Widget));
        const actions = w.row(8);
        net.append(actions.as(gtk.Widget));
        self.radio = self.button(actions, "Wi-Fi", radioClicked);
        _ = self.button(actions, "Network editor…", editorClicked);
        self.net_cancel = self.button(actions, "Cancel connection", cancelClicked);
        self.net_prompt = self.makePrompt(net, true);
        self.net_list = w.column(12);
        self.net_expander = self.list(net, self.net_list, "Adapters, nearby and saved networks");
        const bt = w.card();
        host.append(bt.as(gtk.Widget));
        const bt_heading = w.row(10);
        bt.append(bt_heading.as(gtk.Widget));
        bt_heading.append(w.icon("pearl-bluetooth-active-symbolic").as(gtk.Widget));
        bt_heading.append(w.label("Bluetooth", "pearl-card-title").as(gtk.Widget));
        self.bt_status = w.label("", "pearl-secondary");
        bt.append(self.bt_status.as(gtk.Widget));
        const bt_actions = w.row(8);
        bt.append(bt_actions.as(gtk.Widget));
        self.scan_stop = self.button(bt_actions, "Stop discovery", stopClicked);
        self.bt_cancel = self.button(bt_actions, "Cancel request", cancelClicked);
        self.bt_prompt = self.makePrompt(bt, false);
        self.bt_list = w.column(12);
        self.bt_expander = self.list(bt, self.bt_list, "Adapters and devices");
        network.panel(true);
        bluetooth.panel(true);
        self.update();
        return self;
    }
    fn list(self: *View, host: *gtk.Box, content: *gtk.Box, title: [:0]const u8) *gtk.Expander {
        const expander = gtk.Expander.new(title);
        host.append(expander.as(gtk.Widget));
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.setMinContentHeight(220);
        scroll.setMaxContentHeight(240);
        scroll.setPropagateNaturalHeight(1);
        scroll.setChild(content.as(gtk.Widget));
        expander.setChild(scroll.as(gtk.Widget));
        // GTK 4.22 detaches a collapsed expander child from its root. Explicitly
        // hide it so keyboard traversal cannot enter an unrooted ScrolledWindow.
        scroll.as(gtk.Widget).setVisible(0);
        self.remember(expander.as(object.Object), object.Object.signals.notify.connect(expander.as(object.Object), *gtk.ScrolledWindow, expandedChanged, scroll, .{ .detail = "expanded" }), false);
        return expander;
    }
    fn expandedChanged(obj: *object.Object, _: *object.ParamSpec, scroll: *gtk.ScrolledWindow) callconv(.c) void {
        const expander = object.ext.cast(gtk.Expander, obj).?;
        scroll.as(gtk.Widget).setVisible(expander.getExpanded());
    }
    fn button(self: *View, host: *gtk.Box, title: [:0]const u8, callback: *const fn (*gtk.Button, *View) callconv(.c) void) *gtk.Button {
        const b = gtk.Button.newWithLabel(title);
        host.append(b.as(gtk.Widget));
        self.remember(b.as(object.Object), gtk.Button.signals.clicked.connect(b, *View, callback, self, .{}), false);
        return b;
    }
    fn makePrompt(self: *View, host: *gtk.Box, network: bool) Prompt {
        const box = w.column(8);
        host.append(box.as(gtk.Widget));
        box.as(gtk.Widget).addCssClass("pearl-authentication");
        const title = w.label("", null);
        box.append(title.as(gtk.Widget));
        const entry = gtk.PasswordEntry.new();
        entry.setShowPeekIcon(0);
        w.name(entry.as(gtk.Widget), if (network) "Wi-Fi password" else "Bluetooth PIN or passkey");
        box.append(entry.as(gtk.Widget));
        self.remember(entry.as(object.Object), gtk.PasswordEntry.signals.activate.connect(entry, *View, entryActivated, self, .{}), false);
        const actions = w.row(8);
        box.append(actions.as(gtk.Widget));
        return .{ .box = box, .title = title, .entry = entry, .accept = self.button(actions, if (network) "Connect securely" else "Confirm", answerClicked), .cancel = self.button(actions, "Cancel", cancelClicked) };
    }
    fn remember(self: *View, obj: *object.Object, id: c_ulong, row: bool) void {
        (if (row) &self.row_connections else &self.connections).append(a, .{ .object = obj, .id = id }) catch @panic("OOM");
    }
    fn disconnect(connections: *std.ArrayList(Connection)) void {
        for (connections.items) |c| object.signalHandlerDisconnect(c.object, c.id);
        connections.clearRetainingCapacity();
    }
    pub fn destroy(self: *View) void {
        for ([_]*Prompt{ &self.net_prompt, &self.bt_prompt }) |prompt| if (prompt.reveal_tick != 0) prompt.box.as(gtk.Widget).removeTickCallback(prompt.reveal_tick);
        self.net_prompt.entry.as(gtk.Editable).setText("");
        self.bt_prompt.entry.as(gtk.Editable).setText("");
        self.network.panel(false);
        self.bluetooth.panel(false);
        disconnect(&self.connections);
        disconnect(&self.row_connections);
        self.connections.deinit(a);
        self.row_connections.deinit(a);
        a.destroy(self);
    }
    fn add(self: *View, kind: Kind, path: Text(512), epoch: u64) void {
        const row = &self.rows[self.count];
        self.count += 1;
        const box = w.column(4);
        (if (kind == .adapter or kind == .bluetooth) self.bt_list else self.net_list).append(box.as(gtk.Widget));
        const title = w.label("", null);
        box.append(title.as(gtk.Widget));
        const actions = w.row(8);
        box.append(actions.as(gtk.Widget));
        const primary = gtk.Button.newWithLabel("");
        const secondary = gtk.Button.newWithLabel("");
        actions.append(primary.as(gtk.Widget));
        actions.append(secondary.as(gtk.Widget));
        row.* = .{ .view = self, .kind = kind, .path = path, .epoch = epoch, .title = title, .primary = primary, .secondary = secondary };
        for ([_]*gtk.Button{ primary, secondary }) |b| self.remember(b.as(object.Object), gtk.Button.signals.clicked.connect(b, *Row, rowClicked, row, .{}), true);
    }
    fn identitiesMatch(self: *View) bool {
        const n = self.network;
        const b = self.bluetooth;
        if (self.count != n.device_count + n.ap_count + n.saved_count + b.adapter_count + b.device_count) return false;
        var index: usize = 0;
        inline for (.{ .{ n.devices[0..n.device_count], Kind.device, n.peer.epoch }, .{ n.aps[0..n.ap_count], Kind.ap, n.peer.epoch }, .{ n.saved[0..n.saved_count], Kind.saved, n.peer.epoch }, .{ b.adapters[0..b.adapter_count], Kind.adapter, b.peer.epoch }, .{ b.devices[0..b.device_count], Kind.bluetooth, b.peer.epoch } }) |group| {
            for (group[0]) |*item| {
                const row = &self.rows[index];
                index += 1;
                if (row.kind != group[1] or row.epoch != group[2] or !std.mem.eql(u8, row.path.slice(), item.path.slice())) return false;
            }
        }
        return true;
    }
    pub fn update(self: *View) void {
        const n = self.network;
        const b = self.bluetooth;
        var buffer: [1024]u8 = undefined;
        const net_text = n.err orelse n.peer.err orelse if (n.peer.owner.len == 0) "NetworkManager unavailable" else if (!n.hardware_enabled) "Wi-Fi blocked by hardware" else if (n.pending) (if (n.cancelled) "Cancelling connection…" else "Connecting…") else if (n.scan_pending) "Scanning for networks…" else if (!n.enabled) "Wi-Fi off" else switch (n.connectivity) {
            4 => "Online",
            2 => "Captive portal · sign in using your browser",
            3 => "Limited connectivity",
            else => "Wi-Fi ready",
        };
        var t: Text(1024) = .{};
        t.set(net_text);
        self.net_status.setText(t.z());
        self.radio.setLabel(if (n.enabled) "Turn Wi-Fi off" else "Turn Wi-Fi on");
        self.radio.as(gtk.Widget).setSensitive(@intFromBool(n.peer.owner.len != 0 and n.hardware_enabled and !n.pending));
        self.net_cancel.as(gtk.Widget).setVisible(@intFromBool(n.pending and n.device.len != 0));
        t.set(b.err orelse b.peer.err orelse if (b.peer.owner.len == 0) "BlueZ unavailable" else if (b.pending) (if (b.cancelling) "Cancelling…" else "Waiting for device…") else if (b.discovery_path.len != 0) "Discovering nearby devices · up to 30 seconds" else if (b.device_count == 0) "No devices yet · start discovery" else "Ready to connect");
        self.bt_status.setText(t.z());
        self.bt_cancel.as(gtk.Widget).setVisible(@intFromBool(b.pending));
        self.scan_stop.as(gtk.Widget).setVisible(@intFromBool(b.discovery_path.len != 0));
        if (!self.identitiesMatch()) {
            disconnect(&self.row_connections);
            while (self.net_list.as(gtk.Widget).getFirstChild()) |child| self.net_list.remove(child);
            while (self.bt_list.as(gtk.Widget).getFirstChild()) |child| self.bt_list.remove(child);
            self.count = 0;
            for (n.devices[0..n.device_count]) |dev| self.add(.device, dev.path, n.peer.epoch);
            for (n.aps[0..n.ap_count]) |ap| self.add(.ap, ap.path, n.peer.epoch);
            for (n.saved[0..n.saved_count]) |saved| self.add(.saved, saved.path, n.peer.epoch);
            for (b.adapters[0..b.adapter_count]) |adapter| self.add(.adapter, adapter.path, b.peer.epoch);
            for (b.devices[0..b.device_count]) |dev| self.add(.bluetooth, dev.path, b.peer.epoch);
        }
        for (self.rows[0..self.count]) |*row| {
            row.secondary.as(gtk.Widget).setVisible(1);
            row.primary.as(gtk.Widget).setSensitive(@intFromBool(if (row.kind == .adapter or row.kind == .bluetooth) !b.pending else !n.pending));
            row.secondary.as(gtk.Widget).setSensitive(1);
            switch (row.kind) {
                .device => if (n.findDevice(row.path.slice())) |dev| {
                    row.title.setText(std.fmt.bufPrintZ(&buffer, "{s} · {s}", .{ dev.name.slice(), if (dev.state == 100) "Connected" else if (dev.state < 30) "Unavailable" else "Disconnected" }) catch "Network adapter");
                    row.primary.setLabel("Disconnect");
                    row.primary.as(gtk.Widget).setSensitive(@intFromBool(!n.pending and dev.state >= 40));
                    row.secondary.setLabel("Scan Wi-Fi");
                    row.secondary.as(gtk.Widget).setVisible(@intFromBool(dev.kind == 2));
                    row.secondary.as(gtk.Widget).setSensitive(@intFromBool(n.enabled and n.hardware_enabled and !n.scan_pending));
                },
                .ap => if (n.findAP(row.path.slice())) |ap| {
                    row.title.setText(std.fmt.bufPrintZ(&buffer, "{s} · {d}% · {s}", .{ ap.label.slice(), ap.strength, @tagName(ap.security) }) catch "Wi-Fi network");
                    row.primary.setLabel(if (ap.security == .advanced) "Use network editor…" else "Connect");
                    row.primary.as(gtk.Widget).setSensitive(@intFromBool(!n.pending and n.enabled));
                    row.secondary.as(gtk.Widget).setVisible(0);
                },
                .saved => for (n.saved[0..n.saved_count]) |*saved| {
                    if (!std.mem.eql(u8, saved.path.slice(), row.path.slice())) continue;
                    row.title.setText(std.fmt.bufPrintZ(&buffer, "{s} · Saved", .{saved.label.slice()}) catch "Saved network");
                    row.primary.setLabel(if (saved.security == .advanced) "Use network editor…" else "Connect saved");
                    row.primary.as(gtk.Widget).setSensitive(@intFromBool(saved.loaded and !n.pending and (saved.device.len != 0 or saved.security == .advanced)));
                    row.secondary.as(gtk.Widget).setVisible(0);
                    break;
                },
                .adapter => if (b.findAdapter(row.path.slice())) |adapter| {
                    row.title.setText(std.fmt.bufPrintZ(&buffer, "{s} · {s}", .{ adapter.label.slice(), if (adapter.powered) "On" else "Off" }) catch "Bluetooth adapter");
                    row.primary.setLabel(if (adapter.powered) "Turn off" else "Turn on");
                    row.secondary.setLabel("Discover");
                    row.secondary.as(gtk.Widget).setSensitive(@intFromBool(adapter.powered and b.discovery_path.len == 0));
                },
                .bluetooth => if (b.findDevice(row.path.slice())) |dev| {
                    row.title.setText(std.fmt.bufPrintZ(&buffer, "{s} · {s}{s}\n{s}", .{ dev.label.slice(), if (dev.connected) "Connected" else if (dev.paired) "Paired" else "Not paired", if (dev.trusted) " · Trusted" else "", dev.address.slice() }) catch "Bluetooth device");
                    row.primary.setLabel(if (dev.connected) "Disconnect" else if (dev.paired) "Connect" else "Pair…");
                    row.primary.as(gtk.Widget).setSensitive(@intFromBool(!b.pending and !dev.blocked));
                    row.secondary.setLabel(if (dev.trusted) "Remove trust" else "Trust device");
                    row.secondary.as(gtk.Widget).setSensitive(@intFromBool(!b.pending and dev.paired));
                },
            }
        }
        self.updatePrompt(&self.net_prompt, n.prompt_serial, n.prompt != null, true);
        self.net_prompt.title.setText(std.fmt.bufPrintZ(&buffer, "Password for {s}\n{s}", .{ n.title.slice(), if (n.selected_profile.len == 0) "Used for this connection only." else "Sent to NetworkManager. Pearl does not store it." }) catch "Wi-Fi password");
        self.updatePrompt(&self.bt_prompt, b.prompt_serial, b.prompt_kind != .none, b.prompt_kind == .pin or b.prompt_kind == .passkey);
        self.bt_prompt.title.setText(std.fmt.bufPrintZ(&buffer, "{s}\n{s}", .{ b.title.slice(), b.prompt_text.slice() }) catch "Bluetooth authentication");
        self.bt_prompt.accept.as(gtk.Widget).setVisible(@intFromBool(b.prompt != null));
    }
    fn updatePrompt(_: *View, prompt: *Prompt, serial: u64, visible: bool, entry: bool) void {
        const fresh = prompt.serial != serial;
        if (fresh or !visible) prompt.entry.as(gtk.Editable).setText("");
        prompt.serial = serial;
        prompt.box.as(gtk.Widget).setVisible(@intFromBool(visible));
        prompt.entry.as(gtk.Widget).setVisible(@intFromBool(entry));
        if (fresh or !visible) {
            if (prompt.reveal_tick != 0) prompt.box.as(gtk.Widget).removeTickCallback(prompt.reveal_tick);
            prompt.reveal_tick = 0;
        }
        if (fresh and visible) {
            prompt.reveal_frames = 0;
            prompt.reveal_tick = prompt.box.as(gtk.Widget).addTickCallback(revealPrompt, prompt, null);
        }
        if (fresh and visible) _ = (if (entry) prompt.entry.as(gtk.Widget) else prompt.accept.as(gtk.Widget)).grabFocus();
    }
    fn revealPrompt(widget: *gtk.Widget, _: *@import("gdk4").FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const prompt: *Prompt = @ptrCast(@alignCast(data.?));
        prompt.reveal_frames += 1;
        // The first tick precedes allocation of a newly visible prompt.
        if (prompt.reveal_frames == 1) return 1;
        if (widget.getMapped() != 0 and widget.getHeight() > 0) {
            if (widget.getAncestor(gtk.Viewport.getGObjectType())) |ancestor| object.ext.cast(gtk.Viewport, ancestor).?.scrollTo(widget, null);
        } else if (prompt.reveal_frames < 4) return 1;
        prompt.reveal_tick = 0;
        return 0;
    }
    fn rowClicked(button_: *gtk.Button, row: *Row) callconv(.c) void {
        const self = row.view;
        const n = self.network;
        const b = self.bluetooth;
        switch (row.kind) {
            .device => if (button_ == row.primary) {
                n.disconnect(row.epoch, row.path.slice()) catch {};
            } else {
                n.scan(row.epoch, row.path.slice()) catch {};
            },
            .ap => {
                if (n.findAP(row.path.slice())) |ap| if (ap.security == .advanced) {
                    editorClicked(button_, self);
                    return;
                };
                n.connectAP(row.epoch, row.path.slice()) catch {};
            },
            .saved => {
                for (n.saved[0..n.saved_count]) |*saved| if (std.mem.eql(u8, saved.path.slice(), row.path.slice()) and saved.security == .advanced) {
                    editorClicked(button_, self);
                    return;
                };
                n.connectSaved(row.epoch, row.path.slice()) catch {};
            },
            .adapter => if (button_ == row.secondary) {
                b.discover(row.epoch, row.path.slice()) catch {};
            } else if (b.findAdapter(row.path.slice())) |adapter| {
                b.request(row.epoch, row.path.slice(), if (adapter.powered) .power_off else .power_on) catch {};
            },
            .bluetooth => if (b.findDevice(row.path.slice())) |dev| {
                b.request(row.epoch, row.path.slice(), if (button_ == row.secondary) (if (dev.trusted) .untrust else .trust) else if (dev.connected) .disconnect else if (dev.paired) .connect else .pair) catch {};
            },
        }
    }
    fn radioClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.network.setEnabled(!self.network.enabled) catch {};
    }
    fn editorClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        const editor = @import("giounix2").DesktopAppInfo.new("nm-connection-editor.desktop");
        if (editor) |app| {
            defer app.unref();
            var err: ?*glib.Error = null;
            const display = self.radio.as(gtk.Widget).getDisplay();
            const context = display.getAppLaunchContext();
            defer context.unref();
            if (app.as(gio.AppInfo).launch(null, context.as(gio.AppLaunchContext), &err) != 0) return;
            if (err) |e| e.free();
        }
        self.network.err = "Install nm-connection-editor to configure enterprise, VPN or hidden networks.";
        self.update();
    }
    fn stopClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.bluetooth.stopDiscovery();
    }
    fn cancelClicked(button_: *gtk.Button, self: *View) callconv(.c) void {
        if (button_ == self.net_cancel or button_ == self.net_prompt.cancel) self.network.cancelOperation() else self.bluetooth.cancelOperation();
        self.net_prompt.entry.as(gtk.Editable).setText("");
        self.bt_prompt.entry.as(gtk.Editable).setText("");
    }
    fn answerClicked(button_: *gtk.Button, self: *View) callconv(.c) void {
        self.answer(button_ == self.net_prompt.accept);
    }
    fn entryActivated(entry: *gtk.PasswordEntry, self: *View) callconv(.c) void {
        self.answer(entry == self.net_prompt.entry);
    }
    fn answer(self: *View, network: bool) void {
        const prompt = if (network) &self.net_prompt else &self.bt_prompt;
        const text = std.mem.span(prompt.entry.as(gtk.Editable).getText());
        if (network) self.network.answer(prompt.serial, text) catch {} else self.bluetooth.answer(prompt.serial, true, text) catch {
            self.bluetooth.err = "Enter a valid PIN or a passkey from 000000 to 999999.";
        };
        prompt.entry.as(gtk.Editable).setText("");
        self.update();
    }
    // Read-only focus metadata for private keyboard tests. Never includes typed text or codes.
    pub fn probe(self: *View, window: *gtk.Window) void {
        const focus = window.getFocus();
        if (focus == self.probe_focus) return;
        self.probe_focus = focus;
        const widget = focus orelse return;
        const target: []const u8 = if (widget == self.net_prompt.entry.as(gtk.Widget) or widget.isAncestor(self.net_prompt.entry.as(gtk.Widget)) != 0) "wifi-password" else if (widget == self.bt_prompt.entry.as(gtk.Widget) or widget.isAncestor(self.bt_prompt.entry.as(gtk.Widget)) != 0) "bluetooth-input" else if (widget == self.bt_prompt.accept.as(gtk.Widget)) "bluetooth-confirm" else if (widget == self.net_expander.as(gtk.Widget)) "net-expander" else if (widget == self.bt_expander.as(gtk.Widget)) "bt-expander" else "other";
        std.log.info("event=connectivity-focus target={s}", .{target});
    }
};
