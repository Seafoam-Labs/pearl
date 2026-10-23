const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const Lifecycle = @import("../services/lifecycle.zig").Lifecycle;
const Agent = @import("../services/polkit.zig").Agent;
const a = std.heap.c_allocator;
const focus_state = @import("focus_state.zig");
pub const View = struct {
    service: *Lifecycle,
    power_actions: *@import("services.zig").PowerActions,
    confirmation: ?u64 = null,
    auth: *Agent,
    label: *gtk.Label,
    buttons: [7]*gtk.Button,
    signals: [7]c_ulong,
    rows: [7]Row,
    const Row = struct { view: *View, index: usize };
    const labels = [_][:0]const u8{ "Lock", "Suspend", "Hibernate", "Log out", "Pause automatic idle", "Confirm", "Cancel" };
    pub fn create(host: *gtk.Box, service: *Lifecycle, auth: *Agent, power: *@import("../services/power.zig").Power) !*View {
        const self = try a.create(View);
        errdefer a.destroy(self);
        const card = w.card();
        host.append(card.as(gtk.Widget));
        card.append(w.label(@import("i18n").dtr("pearl", "Session & security"), "pearl-card-title").as(gtk.Widget));
        self.* = .{ .service = service, .auth = auth, .power_actions = undefined, .label = w.label("", "pearl-secondary"), .buttons = undefined, .signals = undefined, .rows = undefined };
        self.label.setWrap(1);
        card.append(self.label.as(gtk.Widget));
        const flow = w.flow(3);
        card.append(flow.as(gtk.Widget));
        for (labels, 0..) |text, i| {
            const button = w.wrappingButton(text);
            button.as(gtk.Widget).addCssClass("pearl-pill");
            focus_state.tag(button.as(gtk.Widget), "lifecycle:{d}", .{i});
            button.ref();
            self.buttons[i] = button;
            self.rows[i] = .{ .view = self, .index = i };
            self.signals[i] = gtk.Button.signals.clicked.connect(button, *Row, clicked, &self.rows[i], .{});
            flow.insert(button.as(gtk.Widget), -1);
        }
        errdefer {
            for (self.buttons, self.signals) |button, id| object.signalHandlerDisconnect(button.as(object.Object), id);
            for (self.buttons) |button| button.unref();
        }
        self.power_actions = try @import("services.zig").PowerActions.create(card, power);
        self.update();
        return self;
    }
    pub fn destroy(self: *View) void {
        self.power_actions.destroy();
        for (self.buttons, self.signals) |button, id| object.signalHandlerDisconnect(button.as(object.Object), id);
        for (self.buttons) |button| button.unref();
        if (self.confirmation == self.service.confirmation and self.service.pending != null) self.service.act("cancel", null) catch {};
        a.destroy(self);
    }
    pub fn update(self: *View) void {
        self.power_actions.update();
        const s = self.service;
        // Adopting the confirmation here (rather than from the click handler)
        // keeps destroy() able to cancel a confirmation the pane showed, even
        // though clicks now run after the emission that may close the pane.
        if (s.pending != null) self.confirmation = s.confirmation;
        var buffer: [768]u8 = undefined;
        const text = if (s.pending) |action| std.fmt.bufPrintZ(&buffer, "Confirm {s}? This confirmation expires after 20 seconds.", .{@tagName(action)}) catch "Confirm session action?" else if (s.err) |err| std.fmt.bufPrintZ(&buffer, "{s}", .{err}) catch "Session action failed" else if (self.auth.err) |err| std.fmt.bufPrintZ(&buffer, "{s}", .{err}) catch "Authentication unavailable" else if (s.gate.requesting) "Acquiring native session lock…" else "Pearl lock · Automatic idle follows your AC/battery policy";
        self.label.setText(text);
        self.buttons[0].as(gtk.Widget).setSensitive(@intFromBool(s.gate.available and s.lock_supported and !s.gate.requesting));
        self.buttons[1].as(gtk.Widget).setSensitive(@intFromBool(s.gate.active and s.lock_supported and s.can_suspend and s.delay_fd >= 0 and !s.action_busy));
        self.buttons[2].as(gtk.Widget).setSensitive(@intFromBool(s.gate.active and s.lock_supported and s.can_hibernate and s.delay_fd >= 0 and !s.action_busy));
        self.buttons[3].as(gtk.Widget).setSensitive(@intFromBool(s.gate.active and s.gate.available and s.client.capabilities.commands and !s.gate.locked));
        self.buttons[4].setLabel(if (s.idle_held) @import("i18n").dtr("pearl", "Resume automatic idle") else @import("i18n").dtr("pearl", "Pause automatic idle"));
        self.buttons[5].as(gtk.Widget).setVisible(@intFromBool(s.pending != null));
        self.buttons[6].as(gtk.Widget).setVisible(@intFromBool(s.pending != null));
    }
    fn clicked(_: *gtk.Button, row: *Row) callconv(.c) void {
        const s = row.view.service;
        // A lifecycle action can synchronously destroy this popup from inside
        // the button's own emission: requesting the lock inhibits the bar, and
        // the manager's reaction closes and frees the pane. Running the action
        // from an idle keeps every widget alive until the emission returns, so
        // the lock trigger can never be lost to a freed view.
        const p = a.create(Pending) catch return;
        p.* = .{
            .service = s,
            .command = switch (row.index) {
                0 => "lock",
                1 => "suspend",
                2 => "hibernate",
                3 => "logout",
                4 => if (s.idle_held) "uninhibit" else "inhibit",
                5 => "confirm",
                else => "cancel",
            },
            .confirmation = if (row.index == 5) s.confirmation else null,
        };
        _ = glib.idleAdd(run, p);
    }
    const Pending = struct { service: *Lifecycle, command: [:0]const u8, confirmation: ?u64 };
    fn run(data: ?*anyopaque) callconv(.c) c_int {
        const p: *Pending = @ptrCast(@alignCast(data.?));
        defer a.destroy(p);
        p.service.act(p.command, p.confirmation) catch {
            p.service.err = "Session action unavailable.";
        };
        p.service.changed(p.service.context);
        return 0;
    }
};
