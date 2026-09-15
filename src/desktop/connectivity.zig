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
const focus_state = @import("focus_state.zig");
const Connection = struct { object: *object.Object, id: c_ulong };
const Kind = enum { device, ap, saved, adapter, bluetooth };
const Row = struct { view: *View, kind: Kind, path: Text(512), epoch: u64, title: *gtk.Label, primary: *gtk.Button, secondary: *gtk.Button };
const Prompt = struct { box: *gtk.Box, title: *gtk.Label, entry: *gtk.PasswordEntry, accept: *gtk.Button, cancel: *gtk.Button, serial: u64 = 0, reveal_tick: c_uint = 0, reveal_frames: u8 = 0 };
pub const Page = enum { network, bluetooth };
pub const View = struct {
    page: Page,
    owner: @import("../services/view_ownership.zig").Owner,
    network: *Network,
    bluetooth: *Bluetooth,
    status: *gtk.Label,
    radio: ?*gtk.Button = null,
    cancel: *gtk.Button,
    scan_stop: ?*gtk.Button = null,
    items: *gtk.Box,
    expander: *gtk.Expander,
    prompt: Prompt,
    rows: [176]Row = undefined,
    count: usize = 0,
    connections: std.ArrayList(Connection) = .empty,
    row_connections: std.ArrayList(Connection) = .empty,
    probe_focus: ?*gtk.Widget = null,
    pub fn createNetwork(host: *gtk.Box, network: *Network, bluetooth: *Bluetooth) !*View {
        return create(host, .network, network, bluetooth);
    }
    pub fn createBluetooth(host: *gtk.Box, network: *Network, bluetooth: *Bluetooth) !*View {
        return create(host, .bluetooth, network, bluetooth);
    }
    fn create(host: *gtk.Box, page: Page, network: *Network, bluetooth: *Bluetooth) !*View {
        const owner = if (page == .network) try network.acquireView() else try bluetooth.acquireView();
        errdefer if (page == .network) network.releaseView(owner) else bluetooth.releaseView(owner);
        const self = try a.create(View);
        self.* = .{ .page = page, .owner = owner, .network = network, .bluetooth = bluetooth, .status = undefined, .cancel = undefined, .items = undefined, .expander = undefined, .prompt = undefined };
        const card = w.card();
        host.append(card.as(gtk.Widget));
        self.status = w.label("", "pearl-secondary");
        self.status.setWrap(1);
        card.append(self.status.as(gtk.Widget));
        const actions = w.row(8);
        card.append(actions.as(gtk.Widget));
        if (page == .network) {
            self.radio = self.button(actions, "Wi-Fi", radioClicked);
            _ = self.button(actions, "Network editor…", editorClicked);
        } else self.scan_stop = self.button(actions, "Stop discovery", stopClicked);
        self.cancel = self.button(actions, "Cancel request", cancelClicked);
        self.prompt = self.makePrompt(card, page == .network);
        self.items = w.column(12);
        self.expander = gtk.Expander.new(if (page == .network) "Adapters, nearby and saved networks" else "Adapters and devices");
        self.expander.setLabelWidget(w.label(if (page == .network) "Adapters, nearby and saved networks" else "Adapters and devices", null).as(gtk.Widget));
        focus_state.tag(self.expander.as(gtk.Widget), "connectivity-expander", .{});
        self.expander.setChild(self.items.as(gtk.Widget));
        self.expander.setExpanded(1);
        card.append(self.expander.as(gtk.Widget));
        // The page owns the only scrolling viewport. Keep collapsed content out
        // of keyboard traversal (GTK 4.22 unroots collapsed expander children).
        self.remember(self.expander.as(object.Object), object.Object.signals.notify.connect(self.expander.as(object.Object), *gtk.Widget, expandedChanged, self.items.as(gtk.Widget), .{ .detail = "expanded" }), false);
        self.update();
        return self;
    }
    fn expandedChanged(obj: *object.Object, _: *object.ParamSpec, content: *gtk.Widget) callconv(.c) void {
        content.setVisible(object.ext.cast(gtk.Expander, obj).?.getExpanded());
    }
    fn button(self: *View, host: *gtk.Box, title: [:0]const u8, callback: *const fn (*gtk.Button, *View) callconv(.c) void) *gtk.Button {
        const b = w.wrappingButton(title);
        focus_state.tag(b.as(gtk.Widget), "connectivity:{s}", .{title});
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
        if (self.prompt.reveal_tick != 0) self.prompt.box.as(gtk.Widget).removeTickCallback(self.prompt.reveal_tick);
        disconnect(&self.connections);
        disconnect(&self.row_connections);
        self.prompt.entry.as(gtk.Editable).setText("");
        if (self.page == .network) self.network.releaseView(self.owner) else self.bluetooth.releaseView(self.owner);
        self.connections.deinit(a);
        self.row_connections.deinit(a);
        a.destroy(self);
    }
    fn add(self: *View, kind: Kind, path: Text(512), epoch: u64) void {
        const row = &self.rows[self.count];
        self.count += 1;
        const box = w.column(4);
        self.items.append(box.as(gtk.Widget));
        const title = w.label("", null);
        box.append(title.as(gtk.Widget));
        const actions = w.row(8);
        box.append(actions.as(gtk.Widget));
        const primary = w.wrappingButton("");
        const secondary = w.wrappingButton("");
        actions.append(primary.as(gtk.Widget));
        actions.append(secondary.as(gtk.Widget));
        for ([_]*gtk.Button{ primary, secondary }, 0..) |button_, control| focus_state.tag(button_.as(gtk.Widget), "connection:{d}:{s}:{s}:{d}", .{ epoch, @tagName(kind), path.slice(), control });
        row.* = .{ .view = self, .kind = kind, .path = path, .epoch = epoch, .title = title, .primary = primary, .secondary = secondary };
        for ([_]*gtk.Button{ primary, secondary }) |b| self.remember(b.as(object.Object), gtk.Button.signals.clicked.connect(b, *Row, rowClicked, row, .{}), true);
    }
    fn identitiesMatch(self: *View) bool {
        const n = self.network;
        const b = self.bluetooth;
        if (self.count != (if (self.page == .network) n.device_count + n.ap_count + n.saved_count else b.adapter_count + b.device_count)) return false;
        var index: usize = 0;
        inline for (.{ .{ n.devices[0..n.device_count], Kind.device, n.peer.epoch }, .{ n.aps[0..n.ap_count], Kind.ap, n.peer.epoch }, .{ n.saved[0..n.saved_count], Kind.saved, n.peer.epoch }, .{ b.adapters[0..b.adapter_count], Kind.adapter, b.peer.epoch }, .{ b.devices[0..b.device_count], Kind.bluetooth, b.peer.epoch } }) |group| {
            if ((self.page == .bluetooth) == (group[1] == .adapter or group[1] == .bluetooth)) for (group[0]) |*item| {
                const row = &self.rows[index];
                index += 1;
                if (row.kind != group[1] or row.epoch != group[2] or !std.mem.eql(u8, row.path.slice(), item.path.slice())) return false;
            };
        }
        return true;
    }
    pub fn update(self: *View) void {
        const n = self.network;
        const b = self.bluetooth;
        var buffer: [1024]u8 = undefined;
        var t: Text(1024) = .{};
        if (self.page == .network) {
            const net_text = n.err orelse n.peer.err orelse if (n.peer.owner.len == 0) "NetworkManager unavailable" else if (!n.hardware_enabled) "Wi-Fi blocked by hardware" else if (n.pending) (if (n.cancelled) "Cancelling connection…" else "Connecting…") else if (n.scan_pending) "Scanning for networks…" else if (!n.enabled) "Wi-Fi off" else switch (n.connectivity) {
                4 => "Online",
                2 => "Captive portal · sign in using your browser",
                3 => "Limited connectivity",
                else => "Wi-Fi ready",
            };
            t.set(net_text);
            self.status.setText(t.z());
            self.radio.?.setLabel(if (n.enabled) "Turn Wi-Fi off" else "Turn Wi-Fi on");
            self.radio.?.as(gtk.Widget).setSensitive(@intFromBool(n.peer.owner.len != 0 and n.hardware_enabled and !n.pending));
            self.cancel.as(gtk.Widget).setVisible(@intFromBool(n.ownsPrompt(self.owner) and n.pending and n.device.len != 0));
        } else {
            t.set(b.err orelse b.peer.err orelse if (b.peer.owner.len == 0) "BlueZ unavailable" else if (b.pending) (if (b.cancelling) "Cancelling…" else "Waiting for device…") else if (b.discovery_path.len != 0) "Discovering nearby devices · up to 30 seconds" else if (b.device_count == 0) "No devices yet · start discovery" else "Ready to connect");
            self.status.setText(t.z());
            self.cancel.as(gtk.Widget).setVisible(@intFromBool(b.ownsPrompt(self.owner) and b.pending));
            self.scan_stop.?.as(gtk.Widget).setVisible(@intFromBool(b.discovery_owner == self.owner and b.discovery_path.len != 0));
        }
        if (!self.identitiesMatch()) {
            disconnect(&self.row_connections);
            while (self.items.as(gtk.Widget).getFirstChild()) |child| self.items.remove(child);
            self.count = 0;
            if (self.page == .network) {
                for (n.devices[0..n.device_count]) |dev| self.add(.device, dev.path, n.peer.epoch);
                for (n.aps[0..n.ap_count]) |ap| self.add(.ap, ap.path, n.peer.epoch);
                for (n.saved[0..n.saved_count]) |saved| self.add(.saved, saved.path, n.peer.epoch);
            } else {
                for (b.adapters[0..b.adapter_count]) |adapter| self.add(.adapter, adapter.path, b.peer.epoch);
                for (b.devices[0..b.device_count]) |dev| self.add(.bluetooth, dev.path, b.peer.epoch);
            }
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
                    const available = if (n.findDevice(ap.device.slice())) |dev| n.canConnectDevice(dev) else false;
                    row.primary.as(gtk.Widget).setSensitive(@intFromBool(!n.pending and (ap.security == .advanced or available)));
                    row.secondary.as(gtk.Widget).setVisible(0);
                },
                .saved => for (n.saved[0..n.saved_count]) |*saved| {
                    if (!std.mem.eql(u8, saved.path.slice(), row.path.slice())) continue;
                    row.title.setText(std.fmt.bufPrintZ(&buffer, "{s} · Saved", .{saved.label.slice()}) catch "Saved network");
                    row.primary.setLabel(if (saved.security == .advanced) "Use network editor…" else "Connect saved");
                    const available = if (n.findDevice(saved.device.slice())) |dev| n.canConnectDevice(dev) else false;
                    row.primary.as(gtk.Widget).setSensitive(@intFromBool(saved.loaded and !n.pending and (available or saved.security == .advanced)));
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
                    const powered = if (b.findAdapter(dev.adapter.slice())) |adapter| adapter.powered else false;
                    row.primary.as(gtk.Widget).setSensitive(@intFromBool(!b.pending and !dev.blocked and powered));
                    row.secondary.setLabel(if (dev.trusted) "Remove trust" else "Trust device");
                    row.secondary.as(gtk.Widget).setSensitive(@intFromBool(!b.pending and dev.paired and !dev.blocked and powered));
                },
            }
        }
        if (self.page == .network) {
            self.updatePrompt(&self.prompt, n.prompt_serial, n.ownsPrompt(self.owner) and n.prompt != null, true);
            self.prompt.title.setText(if (!n.ownsPrompt(self.owner)) "" else std.fmt.bufPrintZ(&buffer, "Password for {s}\n{s}", .{ n.title.slice(), if (n.selected_profile.len == 0) "Used for this connection only." else "Sent to NetworkManager. Pearl does not store it." }) catch "Wi-Fi password");
        } else {
            self.updatePrompt(&self.prompt, b.prompt_serial, b.ownsPrompt(self.owner) and b.prompt_kind != .none, b.prompt_kind == .pin or b.prompt_kind == .passkey);
            self.prompt.title.setText(if (!b.ownsPrompt(self.owner)) "" else std.fmt.bufPrintZ(&buffer, "{s}\n{s}", .{ b.title.slice(), b.prompt_text.slice() }) catch "Bluetooth authentication");
            self.prompt.accept.as(gtk.Widget).setVisible(@intFromBool(b.prompt != null));
        }
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
                n.scan(self.owner, row.epoch, row.path.slice()) catch {};
            },
            .ap => {
                if (n.findAP(row.path.slice())) |ap| if (ap.security == .advanced) {
                    editorClicked(button_, self);
                    return;
                };
                n.connectAP(self.owner, row.epoch, row.path.slice()) catch {};
            },
            .saved => {
                for (n.saved[0..n.saved_count]) |*saved| if (std.mem.eql(u8, saved.path.slice(), row.path.slice()) and saved.security == .advanced) {
                    editorClicked(button_, self);
                    return;
                };
                n.connectSaved(self.owner, row.epoch, row.path.slice()) catch {};
            },
            .adapter => if (button_ == row.secondary) {
                b.discover(self.owner, row.epoch, row.path.slice()) catch {};
            } else if (b.findAdapter(row.path.slice())) |adapter| {
                b.request(self.owner, row.epoch, row.path.slice(), if (adapter.powered) .power_off else .power_on) catch {};
            },
            .bluetooth => if (b.findDevice(row.path.slice())) |dev| {
                b.request(self.owner, row.epoch, row.path.slice(), if (button_ == row.secondary) (if (dev.trusted) .untrust else .trust) else if (dev.connected) .disconnect else if (dev.paired) .connect else .pair) catch {};
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
            const display = self.radio.?.as(gtk.Widget).getDisplay();
            const context = display.getAppLaunchContext();
            defer context.unref();
            if (app.as(gio.AppInfo).launch(null, context.as(gio.AppLaunchContext), &err) != 0) return;
            if (err) |e| e.free();
        }
        self.network.err = "Install nm-connection-editor to configure enterprise, VPN or hidden networks.";
        self.update();
    }
    fn stopClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.bluetooth.stopDiscoveryOwned(self.owner);
    }
    fn cancelClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        if (self.page == .network) self.network.cancelOwned(self.owner) else self.bluetooth.cancelOwned(self.owner);
        self.prompt.entry.as(gtk.Editable).setText("");
    }
    fn answerClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.answer();
    }
    fn entryActivated(_: *gtk.PasswordEntry, self: *View) callconv(.c) void {
        self.answer();
    }
    fn answer(self: *View) void {
        const prompt = &self.prompt;
        const text = std.mem.span(prompt.entry.as(gtk.Editable).getText());
        if (self.page == .network) self.network.answer(self.owner, prompt.serial, text) catch {} else self.bluetooth.answer(self.owner, prompt.serial, true, text) catch {
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
        const target: []const u8 = if (widget == self.prompt.entry.as(gtk.Widget) or widget.isAncestor(self.prompt.entry.as(gtk.Widget)) != 0) (if (self.page == .network) "wifi-password" else "bluetooth-input") else if (widget == self.prompt.accept.as(gtk.Widget)) (if (self.page == .network) "wifi-confirm" else "bluetooth-confirm") else if (widget == self.expander.as(gtk.Widget)) (if (self.page == .network) "net-expander" else "bt-expander") else "other";
        std.log.info("event=connectivity-focus target={s}", .{target});
    }
};
