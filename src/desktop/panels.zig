const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const tr = @import("text.zig").tr;
const native = @import("../platform/wayland/layout.zig");
const a = std.heap.c_allocator;
pub const Control = struct {
    connectivity: *@import("connectivity.zig").View,
    services: *@import("services.zig").View,
    layout: *native.Layout,
    label: *gtk.Label,
    buttons: [native.names.len]*gtk.Button,
    context: *anyopaque,
    action: *const fn (*anyopaque, ?[]const u8) void,
    rows: [native.names.len]Choice = undefined,
    const Choice = struct { owner: *Control, name: []const u8 };
    pub fn create(host: *gtk.Box, layout: *native.Layout, context: *anyopaque, action: @FieldType(Control, "action"), audio: *@import("../services/audio.zig").Audio, power: *@import("../services/power.zig").Power, network: *@import("../services/network.zig").Network, bluetooth: *@import("../services/bluetooth.zig").Bluetooth) !*Control {
        const self = try a.create(Control);
        self.* = .{ .layout = layout, .context = context, .action = action, .label = undefined, .buttons = undefined, .services = undefined, .connectivity = undefined };
        host.append(w.label(tr("Control center", "Schnelleinstellungen"), "pearl-card-title").as(gtk.Widget));
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        const content = w.column(16);
        scroll.setChild(content.as(gtk.Widget));
        host.append(scroll.as(gtk.Widget));
        self.connectivity = try @import("connectivity.zig").View.create(content, network, bluetooth);
        self.services = try @import("services.zig").View.create(content, audio, power);
        const section = w.card();
        section.as(gtk.Widget).addCssClass("pearl-layout-card");
        section.append(w.label(tr("Workspace layout", "Anordnung der Arbeitsfläche"), "pearl-card-title").as(gtk.Widget));
        self.label = w.label("", "pearl-secondary");
        section.append(self.label.as(gtk.Widget));
        const layouts = w.flow(3);
        section.append(layouts.as(gtk.Widget));
        for (native.names, 0..) |name, i| {
            const button = gtk.Button.newWithLabel(name);
            self.buttons[i] = button;
            self.rows[i] = .{ .owner = self, .name = name };
            _ = gtk.Button.signals.clicked.connect(button, *Choice, selected, &self.rows[i], .{});
            layouts.insert(button.as(gtk.Widget), -1);
        }
        const refresh = gtk.Button.newWithLabel(tr("Refresh layout", "Anordnung aktualisieren"));
        _ = gtk.Button.signals.clicked.connect(refresh, *Control, refreshed, self, .{});
        section.append(refresh.as(gtk.Widget));
        content.append(section.as(gtk.Widget));
        content.append(w.status(.empty, w.label(tr("No media service", "Kein Mediendienst"), null), w.label(tr("Player controls will appear when media support is connected.", "Die Wiedergabesteuerung erscheint, sobald der Mediendienst verbunden ist."), "pearl-secondary")).as(gtk.Widget));
        self.update();
        return self;
    }
    pub fn destroy(self: *Control) void {
        self.connectivity.destroy();
        self.services.destroy();
        a.destroy(self);
    }
    pub fn update(self: *Control) void {
        self.connectivity.update();
        self.services.update();
        const layout = self.layout;
        var buffer: [100]u8 = undefined;
        const text = if (layout.manager != null) tr("Waiting for Aqueous…", "Warten auf Aqueous…") else if (layout.global == null or layout.err != null) tr("Layout unavailable. Refresh to retry.", "Anordnung nicht verfügbar. Bitte aktualisieren.") else if (layout.value_len == 0) tr("Querying the active workspace", "Aktive Arbeitsfläche wird abgefragt") else std.fmt.bufPrintZ(&buffer, "{s} · {d}", .{ layout.value[0..layout.value_len], layout.workspace }) catch unreachable;
        self.label.setText(text);
        for (self.buttons, native.names) |button, name| {
            button.as(gtk.Widget).setSensitive(@intFromBool(layout.manager == null and layout.global != null));
            if (std.mem.eql(u8, name, layout.value[0..layout.value_len])) button.as(gtk.Widget).addCssClass("pearl-selected") else button.as(gtk.Widget).removeCssClass("pearl-selected");
        }
    }
    fn selected(_: *gtk.Button, choice: *Choice) callconv(.c) void {
        choice.owner.action(choice.owner.context, choice.name);
    }
    fn refreshed(_: *gtk.Button, self: *Control) callconv(.c) void {
        self.action(self.context, null);
    }
};
pub fn calendar(host: *gtk.Box) void {
    const now = glib.DateTime.newNowLocal() orelse return;
    defer now.unref();
    const date = now.format("%A, %d %B %Y") orelse return;
    defer glib.free(date);
    host.append(w.label(date, "pearl-card-title").as(gtk.Widget));
    const scroll = gtk.ScrolledWindow.new();
    scroll.setPolicy(.never, .automatic);
    scroll.as(gtk.Widget).setVexpand(1);
    const content = w.column(16);
    scroll.setChild(content.as(gtk.Widget));
    host.append(scroll.as(gtk.Widget));
    const grid = gtk.Calendar.new();
    grid.setShowDayNames(1);
    grid.setShowHeading(1);
    grid.selectDay(now);
    grid.as(gtk.Widget).setHalign(.center);
    content.append(grid.as(gtk.Widget));
    content.append(w.status(.empty, w.label(tr("Your local calendar", "Dein lokaler Kalender"), null), w.label(tr("Browse months and dates. Calendar accounts and media are not connected.", "Blättere durch Monate und Tage. Kalenderkonten und Medien sind nicht verbunden."), "pearl-secondary")).as(gtk.Widget));
}
