const std = @import("std");
const gtk = @import("gtk4");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const Lifecycle = @import("../services/lifecycle.zig").Lifecycle;
const Agent = @import("../services/polkit.zig").Agent;
const a = std.heap.c_allocator;
pub const View = struct {
    service: *Lifecycle,
    auth: *Agent,
    label: *gtk.Label,
    buttons: [7]*gtk.Button,
    signals: [7]c_ulong,
    rows: [7]Row,
    const Row = struct { view: *View, index: usize };
    const labels = [_][:0]const u8{ "Lock", "Suspend", "Hibernate", "Log out", "Pause automatic idle", "Confirm", "Cancel" };
    pub fn create(host: *gtk.Box, service: *Lifecycle, auth: *Agent) !*View {
        const self = try a.create(View);
        const card = w.card();
        host.append(card.as(gtk.Widget));
        card.append(w.label("Session & security", "pearl-card-title").as(gtk.Widget));
        self.* = .{ .service = service, .auth = auth, .label = w.label("", "pearl-secondary"), .buttons = undefined, .signals = undefined, .rows = undefined };
        self.label.setWrap(1);
        card.append(self.label.as(gtk.Widget));
        const flow = w.flow(3);
        card.append(flow.as(gtk.Widget));
        for (labels, 0..) |text, i| {
            const button = gtk.Button.newWithLabel(text);
            button.ref();
            self.buttons[i] = button;
            self.rows[i] = .{ .view = self, .index = i };
            self.signals[i] = gtk.Button.signals.clicked.connect(button, *Row, clicked, &self.rows[i], .{});
            flow.insert(button.as(gtk.Widget), -1);
        }
        self.update();
        return self;
    }
    pub fn destroy(self: *View) void {
        for (self.buttons, self.signals) |button, id| object.signalHandlerDisconnect(button.as(object.Object), id);
        for (self.buttons) |button| button.unref();
        self.service.act("cancel", null) catch {};
        a.destroy(self);
    }
    pub fn update(self: *View) void {
        const s = self.service;
        var buffer: [768]u8 = undefined;
        const text = if (s.pending) |action| std.fmt.bufPrintZ(&buffer, "Confirm {s}? This confirmation expires after 20 seconds.", .{@tagName(action)}) catch "Confirm session action?" else if (s.err) |err| std.fmt.bufPrintZ(&buffer, "{s}", .{err}) catch "Session action failed" else if (self.auth.err) |err| std.fmt.bufPrintZ(&buffer, "{s}", .{err}) catch "Authentication unavailable" else if (s.gate.requesting) "Acquiring native session lock…" else "Pearl lock · Automatic idle follows your AC/battery policy";
        self.label.setText(text);
        self.buttons[0].as(gtk.Widget).setSensitive(@intFromBool(s.gate.available and s.lock_supported and !s.gate.requesting));
        self.buttons[1].as(gtk.Widget).setSensitive(@intFromBool(s.gate.active and s.lock_supported and s.can_suspend and s.delay_fd >= 0 and !s.action_busy));
        self.buttons[2].as(gtk.Widget).setSensitive(@intFromBool(s.gate.active and s.lock_supported and s.can_hibernate and s.delay_fd >= 0 and !s.action_busy));
        self.buttons[3].as(gtk.Widget).setSensitive(@intFromBool(s.gate.active and s.gate.available and s.client.capabilities.commands and !s.gate.locked));
        self.buttons[4].setLabel(if (s.idle_held) "Resume automatic idle" else "Pause automatic idle");
        self.buttons[5].as(gtk.Widget).setVisible(@intFromBool(s.pending != null));
        self.buttons[6].as(gtk.Widget).setVisible(@intFromBool(s.pending != null));
    }
    fn clicked(_: *gtk.Button, row: *Row) callconv(.c) void {
        const s = row.view.service;
        const command = switch (row.index) {
            0 => "lock",
            1 => "suspend",
            2 => "hibernate",
            3 => "logout",
            4 => if (s.idle_held) "uninhibit" else "inhibit",
            5 => "confirm",
            else => "cancel",
        };
        s.act(command, if (row.index == 5) s.confirmation else null) catch {
            s.err = "Session action unavailable.";
        };
        row.view.update();
    }
};
