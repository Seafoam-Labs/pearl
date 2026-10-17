//! Native saved-device controls shared by Places and the Network page.
const std = @import("std");
const u = @import("ui.zig");
const a = u.a;
const gtk = u.gtk;
const gio = u.gio;
const glib = u.glib;
const object = u.object;
const Window = @import("window.zig").Window;
const c = @import("platform/connections.zig");
const net = @import("platform/network_mounts.zig");
pub const overview_uri = "phyto-network:///";
const Action = enum { connect, cancel, disconnect, settings, forget, add, discover };
const Target = struct { owner: *Window, id: [:0]u8, action: Action, tab: ?u64 };
const Editor = struct { ui: *UI, dialog: *gtk.Dialog, id: ?[:0]u8, revision: u64, name: ?*gtk.Entry = null, address: ?*gtk.Entry = null, startup: ?*gtk.CheckButton = null, error_label: *gtk.Label, forgetting: bool = false, tab: u64, generation: u64 };
pub const UI = struct {
    owner: *Window,
    editor: ?*Editor = null,
    pub fn close(self: *UI) void {
        if (self.editor) |e| {
            self.editor = null;
            e.dialog.as(gtk.Window).destroy();
            if (e.id) |id| a.free(id);
            a.destroy(e);
        }
    }
    pub fn fillPlaces(self: *UI, box: *gtk.Box) void {
        const manager = net.shared orelse return;
        box.append(u.label("NETWORK DEVICES", "section-label").as(gtk.Widget));
        if (manager.store.warning) |warning| {
            const l = u.label(warning, "error");
            l.setWrap(1);
            l.setMaxWidthChars(24);
            box.append(l.as(gtk.Widget));
        }
        for (manager.store.profiles.items) |p| {
            const row = u.box(.horizontal, 2, null);
            const button = self.actionButton(p.name, .connect, p.id, null);
            button.as(gtk.Widget).addCssClass("place");
            button.as(gtk.Widget).setHexpand(1);
            const content = u.box(.horizontal, 8, null);
            content.append(u.image("network-server-symbolic", 18).as(gtk.Widget));
            const labels = u.box(.vertical, 3, null);
            const title = u.label(p.name, null);
            title.setEllipsize(.end);
            title.setMaxWidthChars(18);
            labels.append(title.as(gtk.Widget));
            const state = if (manager.entry(p.id)) |e| e.state else .disconnected;
            labels.append(u.label(net.label(state), "secondary").as(gtk.Widget));
            content.append(labels.as(gtk.Widget));
            button.setChild(content.as(gtk.Widget));
            const tip = u.format("{s}\n{s}\n{s}", .{ p.name, p.uri, policyText(p.policy) });
            defer a.free(tip);
            button.as(gtk.Widget).setTooltipText(tip);
            row.append(button.as(gtk.Widget));
            const settings = self.actionButton("⋮", .settings, p.id, null);
            u.name(settings.as(gtk.Widget), "Connection settings");
            settings.as(gtk.Widget).setTooltipText("Connection settings…");
            row.append(settings.as(gtk.Widget));
            box.append(row.as(gtk.Widget));
        }
        box.append(self.actionButton("Add connection…", .add, "", null).as(gtk.Widget));
    }
    pub fn fillNetwork(self: *UI, box: *gtk.Box, tab: u64) void {
        u.clear(box);
        const manager = net.shared orelse return;
        const heading = u.box(.horizontal, 8, null);
        const title = u.label("Saved connections", null);
        title.setWrap(1);
        title.as(gtk.Widget).setHexpand(1);
        heading.append(title.as(gtk.Widget));
        const add = self.actionButton("Add connection…", .add, "", tab);
        add.as(gtk.Widget).addCssClass("suggested-action");
        heading.append(add.as(gtk.Widget));
        box.append(heading.as(gtk.Widget));
        if (manager.store.warning) |warning| appendText(box, warning, "error");
        if (manager.store.profiles.items.len == 0) appendText(box, "Save an SMB, SFTP or WebDAV connection, then choose when it reconnects.", "secondary");
        for (manager.store.profiles.items) |p| {
            const card = u.box(.vertical, 8, "network-card");
            const head = u.box(.horizontal, 8, null);
            head.append(u.image("network-server-symbolic", 24).as(gtk.Widget));
            const name = u.label(p.name, null);
            name.setEllipsize(.end);
            name.as(gtk.Widget).setHexpand(1);
            head.append(name.as(gtk.Widget));
            const e = manager.entry(p.id).?;
            head.append(u.label(net.label(e.state), "secondary").as(gtk.Widget));
            card.append(head.as(gtk.Widget));
            const uri = u.label(p.uri, "secondary");
            uri.setEllipsize(.middle);
            uri.setMaxWidthChars(60);
            card.append(uri.as(gtk.Widget));
            appendText(card, policyText(p.policy), "secondary");
            if (e.detail.len != 0) appendText(card, e.detail, "error");
            const actions = gtk.FlowBox.new();
            actions.setSelectionMode(.none);
            actions.setMinChildrenPerLine(1);
            actions.setMaxChildrenPerLine(4);
            const running = e.state == .connecting or e.state == .queued;
            const connect = self.actionButton(if (running) "Cancel" else if (e.state == .connected) "Open" else if (e.state == .needs_auth) "Sign in…" else if (e.state == .review) "Review…" else if (e.state == .failed) "Retry" else "Connect", if (running) .cancel else .connect, p.id, tab);
            connect.as(gtk.Widget).addCssClass("suggested-action");
            actions.insert(connect.as(gtk.Widget), -1);
            if (e.state == .connected) actions.insert(self.actionButton("Disconnect", .disconnect, p.id, tab).as(gtk.Widget), -1);
            actions.insert(self.actionButton("Settings…", .settings, p.id, tab).as(gtk.Widget), -1);
            actions.insert(self.actionButton("Forget…", .forget, p.id, tab).as(gtk.Widget), -1);
            card.append(actions.as(gtk.Widget));
            box.append(card.as(gtk.Widget));
        }
        box.append(self.actionButton("Browse discovered servers", .discover, "", tab).as(gtk.Widget));
    }
    fn actionButton(self: *UI, label: [:0]const u8, action: Action, id: []const u8, tab: ?u64) *gtk.Button {
        const b = gtk.Button.newWithLabel(label);
        const target = a.create(Target) catch unreachable;
        target.* = .{ .owner = self.owner, .id = c.dup(id), .action = action, .tab = tab };
        b.as(object.Object).setDataFull("phyto-network-target", target, freeTarget);
        if (action == .connect) {
            b.as(object.Object).setData("phyto-network-device", target);
            const gesture = gtk.GestureClick.new();
            gesture.as(gtk.GestureSingle).setButton(3);
            _ = gtk.GestureClick.signals.pressed.connect(gesture, *Target, secondary, target, .{});
            b.as(gtk.Widget).addController(gesture.as(gtk.EventController));
        }
        _ = gtk.Button.signals.clicked.connect(b, *Target, clicked, target, .{});
        return b;
    }
    pub fn edit(self: *UI, id: ?[:0]const u8, initial: ?[:0]const u8) void {
        self.close();
        const manager = net.shared.?;
        const profile = if (id) |v| manager.store.get(v) else null;
        if (id != null and profile == null) return;
        const e = self.dialog(if (profile != null) "Connection settings" else "Add connection", id);
        const body = e.dialog.getContentArea();
        appendText(body, "Save a network location in Places.", "secondary");
        e.name = field(body, "Connection name", if (profile) |p| p.name else "");
        e.name.?.setMaxLength(256);
        e.address = field(body, "Server address", if (profile) |p| p.uri else initial orelse "");
        appendText(body, "smb://server/share · sftp://server/folder\ndavs://server/folder · dav://server/folder", "secondary");
        appendText(body, "Reconnect", null);
        const startup = gtk.CheckButton.newWithLabel("When Phyto opens");
        const click = gtk.CheckButton.newWithLabel("When I click the network device");
        click.setGroup(startup);
        e.startup = startup;
        if (profile != null and profile.?.policy == .on_open) startup.setActive(1) else click.setActive(1);
        body.append(startup.as(gtk.Widget));
        body.append(click.as(gtk.Widget));
        appendText(body, "Saving a connection does not save its password. Credentials are handled separately when signing in.", "secondary");
        if (profile != null) appendText(body, "Startup changes apply next time Phyto opens.", "secondary");
        body.append(e.error_label.as(gtk.Widget));
        _ = e.dialog.addButton("Cancel", 0);
        if (profile == null) _ = e.dialog.addButton("Save for later", 2);
        const save = e.dialog.addButton(if (profile == null) "Save and connect" else "Save changes", 1);
        save.addCssClass("suggested-action");
        // Avoid accidental network requests from Enter in a text field.
        e.dialog.as(gtk.Window).present();
        _ = e.name.?.as(gtk.Widget).grabFocus();
    }
    pub fn forget(self: *UI, id: [:0]const u8) void {
        self.close();
        const p = net.shared.?.store.get(id) orelse return;
        const e = self.dialog("Forget connection?", id);
        e.forgetting = true;
        appendText(e.dialog.getContentArea(), p.name, null);
        appendText(e.dialog.getContentArea(), "Remove this saved device and its reconnect preference? Remote files and existing mounts remain. Disconnect separately if needed.", "secondary");
        e.dialog.getContentArea().append(e.error_label.as(gtk.Widget));
        _ = e.dialog.addButton("Cancel", 0);
        _ = e.dialog.addButton("Forget connection", 1);
        e.dialog.as(gtk.Window).present();
    }
    fn dialog(self: *UI, title: [:0]const u8, id: ?[:0]const u8) *Editor {
        const d = gtk.Dialog.new();
        d.as(gtk.Window).setTitle(title);
        d.as(gtk.Window).setTransientFor(self.owner.window);
        d.as(gtk.Window).setModal(1);
        d.as(gtk.Window).setDefaultSize(@min(520, self.owner.width - 24), -1);
        d.as(gtk.Widget).addCssClass("phyto-root");
        d.as(gtk.Widget).addCssClass(@import("appearance.zig").themeClass());
        d.getContentArea().as(gtk.Widget).addCssClass("dialog-body");
        const e = a.create(Editor) catch unreachable;
        const err = u.label("", "error");
        err.setWrap(1);
        err.setMaxWidthChars(45);
        e.* = .{ .ui = self, .dialog = d, .id = if (id) |v| c.dup(v) else null, .revision = net.shared.?.store.revision, .error_label = err, .tab = self.owner.current().id, .generation = self.owner.current().generation };
        self.editor = e;
        _ = gtk.Dialog.signals.response.connect(d, *Editor, response, e, .{});
        if (@import("build_options").test_hooks) {
            const keys = gtk.EventControllerKey.new();
            _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Window, Window.keyPressed, self.owner, .{});
            d.as(gtk.Widget).addController(keys.as(gtk.EventController));
        }
        return e;
    }
};
fn appendText(box: *gtk.Box, text: [:0]const u8, class: ?[*:0]const u8) void {
    const label = u.label(text, class);
    label.setWrap(1);
    label.setMaxWidthChars(48);
    label.setWrapMode(.word_char);
    box.append(label.as(gtk.Widget));
}
fn field(body: *gtk.Box, label: [:0]const u8, value: [:0]const u8) *gtk.Entry {
    body.append(u.label(label, null).as(gtk.Widget));
    const e = gtk.Entry.new();
    e.as(gtk.Editable).setText(value);
    e.setMaxLength(8192);
    u.name(e.as(gtk.Widget), label);
    body.append(e.as(gtk.Widget));
    return e;
}
pub fn policyText(policy: c.Policy) [:0]const u8 {
    return if (policy == .on_open) "Reconnect when Phyto opens" else "Reconnect when I click the network device";
}
fn freeTarget(raw: ?*anyopaque) callconv(.c) void {
    const t: *Target = @ptrCast(@alignCast(raw.?));
    a.free(t.id);
    a.destroy(t);
}
fn clicked(_: *gtk.Button, t: *Target) callconv(.c) void {
    const owner = t.owner;
    if (owner.closed) return;
    if (t.tab) |id| if (owner.findTab(id)) |tab| owner.activatePane(tab.pane);
    owner.places_popover.popdown();
    const manager = net.shared.?;
    switch (t.action) {
        .connect => manager.connect(t.id, owner),
        .cancel => manager.cancel(t.id),
        .disconnect => manager.disconnect(t.id, owner),
        .settings => owner.network_ui.edit(t.id, null),
        .forget => owner.network_ui.forget(t.id),
        .add => owner.network_ui.edit(null, null),
        .discover => {
            const f = gio.File.newForUri("network:///");
            defer f.unref();
            owner.current().navigate(f, true);
        },
    }
}
fn response(_: *gtk.Dialog, result: c_int, e: *Editor) callconv(.c) void {
    if (result != 1 and result != 2) {
        e.ui.close();
        return;
    }
    const manager = net.shared.?;
    if (e.revision != manager.store.revision) {
        e.error_label.setText(c.errorText(error.Conflict));
        return;
    }
    if (e.forgetting) {
        manager.store.remove(e.id.?) catch |err| {
            e.error_label.setText(c.errorText(err));
            return;
        };
        manager.syncProfiles();
        e.ui.close();
        return;
    }
    const id = manager.store.put(e.id, std.mem.span(e.name.?.as(gtk.Editable).getText()), std.mem.span(e.address.?.as(gtk.Editable).getText()), if (e.startup.?.getActive() != 0) .on_open else .on_click) catch |err| {
        e.error_label.setText(c.errorText(err));
        return;
    };
    defer a.free(id);
    const owner = e.ui.owner;
    const connect = result == 1 and e.id == null;
    const tab = e.tab;
    const generation = e.generation;
    manager.syncProfiles();
    e.ui.close();
    owner.setStatus("Connection saved.");
    if (connect) if (owner.findTab(tab)) |target| {
        if (target.generation == generation and owner.current() == target) manager.connect(id, owner);
    };
}

pub fn showContext(owner: *Window, widget: *gtk.Widget, x: f64, y: f64) bool {
    const raw = widget.as(object.Object).getData("phyto-network-device") orelse return false;
    const target: *Target = @ptrCast(@alignCast(raw));
    var context = @import("context.zig").Context.init(owner.current(), .connection);
    context.connection_id = c.dup(target.id);
    owner.context.show(context, widget, x, y);
    return true;
}
fn secondary(gesture: *gtk.GestureClick, _: c_int, x: f64, y: f64, target: *Target) callconv(.c) void {
    _ = showContext(target.owner, gesture.as(gtk.EventController).getWidget().?, x, y);
    _ = gesture.as(gtk.Gesture).setState(.claimed);
}
