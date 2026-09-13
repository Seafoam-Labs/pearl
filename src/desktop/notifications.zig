//! Retained notification cards: actions never borrow an evictable model record.
const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const w = @import("../ui/components/widgets.zig");
const service = @import("../services/notifications.zig");
const tr = @import("text.zig").tr;
const a = std.heap.c_allocator;
const Action = struct { view: *View, id: u32 = 0, key: service.policy.Action = .{}, button: *gtk.Button, dismiss: bool = false };
const Card = struct { box: *gtk.Box, header: *gtk.Label, title: *gtk.Label, body: *gtk.Label, actions: [9]Action = undefined, id: u32 = 0 };
pub const View = struct {
    service: *service.Notifications, host: *gtk.Box, toast: bool, revision: u64 = std.math.maxInt(u64),
    rows: [64]Card = undefined, count: usize = 0, dnd: ?*gtk.Button = null, empty: ?*gtk.Label = null,
    pub fn create(host: *gtk.Box, notifications: *service.Notifications, toast: bool) !*View {
        const self = try a.create(View);
        self.* = .{ .host = host, .service = notifications, .toast = toast };
        var content = host;
        if (!toast) {
            host.append(w.label(tr("Notifications", "Benachrichtigungen"), "pearl-card-title").as(gtk.Widget));
            const controls = w.row(8);
            const dnd = gtk.Button.newWithLabel(""); self.dnd = dnd;
            _ = gtk.Button.signals.clicked.connect(dnd, *View, toggleDnd, self, .{}); controls.append(dnd.as(gtk.Widget));
            const clear = gtk.Button.newWithLabel(tr("Clear history", "Verlauf löschen"));
            _ = gtk.Button.signals.clicked.connect(clear, *View, clearHistory, self, .{}); controls.append(clear.as(gtk.Widget)); host.append(controls.as(gtk.Widget));
            self.empty = w.label("", "pearl-secondary"); host.append(self.empty.?.as(gtk.Widget));
            const scroll = gtk.ScrolledWindow.new(); scroll.setPolicy(.never, .automatic); scroll.as(gtk.Widget).setVexpand(1);
            content = w.column(12); scroll.setChild(content.as(gtk.Widget)); host.append(scroll.as(gtk.Widget));
        }
        self.count = if (toast) 3 else 64;
        for (self.rows[0..self.count]) |*row| {
            const box = w.card(); box.setSpacing(8); box.as(gtk.Widget).addCssClass("pearl-notification-card");
            const header = w.label("", "pearl-secondary"); const title = w.label("", "pearl-card-title"); const body = w.label("", null);
            title.setLines(2); title.setEllipsize(.end); body.setLines(if (toast) 3 else 6); body.setEllipsize(.end); body.setMaxWidthChars(48);
            box.append(header.as(gtk.Widget)); box.append(title.as(gtk.Widget)); box.append(body.as(gtk.Widget));
            row.* = .{ .box = box, .header = header, .title = title, .body = body };
            const buttons = w.flow(3);
            for (&row.actions, 0..) |*action, i| {
                const button = gtk.Button.newWithLabel(if (i == 8) tr("Dismiss", "Schließen") else "");
                action.* = .{ .view = self, .button = button, .dismiss = i == 8 };
                _ = gtk.Button.signals.clicked.connect(button, *Action, clicked, action, .{}); buttons.insert(button.as(gtk.Widget), -1);
            }
            box.append(buttons.as(gtk.Widget)); content.append(box.as(gtk.Widget)); box.as(gtk.Widget).setVisible(0);
        }
        self.update(); return self;
    }
    pub fn destroy(self: *View) void { a.destroy(self); }
    pub fn update(self: *View) void {
        const model = &self.service.model;
        if (self.dnd) |button| button.setLabel(if (model.dnd) tr("Do not disturb · On", "Nicht stören · An") else tr("Do not disturb · Off", "Nicht stören · Aus"));
        if (self.empty) |label| label.setText(if (!self.service.available) tr("Another notification service is active.", "Ein anderer Benachrichtigungsdienst ist aktiv.") else "");
        if (self.revision == model.serial) return;
        self.revision = model.serial;
        var records: [64]*service.policy.Record = undefined; var count: usize = 0;
        for (&model.records) |*r| if (r.id != 0 and (!self.toast or r.toast_until > glib.getMonotonicTime()) and !model.locked) { records[count] = r; count += 1; };
        std.mem.sort(*service.policy.Record, records[0..count], {}, newer);
        // Keep application groups adjacent, with the newest group first.
        if (!self.toast) {
            var grouped: [64]*service.policy.Record = undefined; var used: [64]bool = @splat(false); var n: usize = 0;
            for (records[0..count], 0..) |r, i| {
                if (used[i]) continue;
                for (records[0..count], 0..) |other, j| if (!used[j] and std.mem.eql(u8, r.app.slice(), other.app.slice())) { grouped[n] = other; n += 1; used[j] = true; };
            }
            records = grouped;
        }
        for (self.rows[0..self.count], 0..) |*row, i| {
            const visible = i < count;
            row.box.as(gtk.Widget).setVisible(@intFromBool(visible)); if (!visible) continue;
            const r = records[i]; row.id = r.id;
            row.header.setText(if (r.app.len == 0) "Application" else r.app.z()); row.title.setText(r.summary.z()); row.body.setText(r.body.z());
            row.body.as(gtk.Widget).setVisible(@intFromBool(r.body.len != 0));
            for (&row.actions, 0..) |*action, j| {
                action.id = r.id;
                if (j < r.action_count) { action.key = r.actions[j]; action.button.setLabel(action.key.label.z()); }
                action.button.as(gtk.Widget).setVisible(@intFromBool(j == 8 or j < r.action_count));
                action.button.as(gtk.Widget).setSensitive(@intFromBool(r.active));
            }
        }
        if (self.empty) |label| if (count == 0 and self.service.available) label.setText(tr("You're all caught up", "Alles erledigt"));
    }
    fn newer(_: void, l: *service.policy.Record, r: *service.policy.Record) bool { return l.serial > r.serial; }
    fn clicked(_: *gtk.Button, action: *Action) callconv(.c) void {
        if (action.view.service.model.locked) return;
        if (action.dismiss) { _ = action.view.service.close(action.id, 2); }
        else action.view.service.invoke(action.id, action.key.key.slice()) catch {};
    }
    fn toggleDnd(_: *gtk.Button, self: *View) callconv(.c) void { self.service.setDnd(!self.service.model.dnd); }
    fn clearHistory(_: *gtk.Button, self: *View) callconv(.c) void { self.service.model.clearHistory(); self.service.update(); }
};
