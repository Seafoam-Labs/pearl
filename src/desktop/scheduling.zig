//! The scheduling flyout opened from the bar widget. Each button applies an
//! administrator-defined scx.service command line from the profile file.
const std = @import("std");
const gtk = @import("gtk4");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const tr = @import("text.zig").tr;
const focus_state = @import("focus_state.zig");
const p = @import("../services/sched_profiles.zig");
const Service = @import("../services/scheduling.zig").Service;
const log = std.log.scoped(.desktop);
const a = std.heap.c_allocator;
const Connection = struct { object: *object.Object, id: c_ulong };

pub const View = struct {
    service: *Service,
    arena: std.heap.ArenaAllocator = .init(a),
    /// Ids of the buttons, in order, for the profiles shown when the card opened.
    ids: []const []const u8 = &.{},
    status: *gtk.Label,
    description: *gtk.Label,
    message: *gtk.Label,
    buttons: []*gtk.Button = &.{},
    choices: []Choice = &.{},
    connections: std.ArrayList(Connection) = .empty,
    const Choice = struct { view: *View, index: usize };

    /// Fails with error.NoProfiles when no profile file is installed, so the
    /// flyout only opens on systems that configure it.
    pub fn create(host: *gtk.Box, service: *Service) !*View {
        service.refresh();
        if (!service.configured()) return error.NoProfiles;
        const self = try a.create(View);
        errdefer a.destroy(self);
        self.* = .{ .service = service, .status = undefined, .description = undefined, .message = undefined };
        errdefer self.arena.deinit();
        const alloc = self.arena.allocator();
        const card = w.card();
        host.append(card.as(gtk.Widget));
        card.append(w.label(tr("CPU Scheduler", "CPU-Scheduler"), "pearl-card-title").as(gtk.Widget));
        self.status = w.label("", null);
        self.status.setWrap(1);
        card.append(self.status.as(gtk.Widget));
        // Status first, then the choices, then text about the selection.
        self.description = w.label("", "pearl-secondary");
        self.description.setWrap(1);
        if (service.config) |config| {
            const ids = try alloc.alloc([]const u8, config.profiles.len);
            self.buttons = try alloc.alloc(*gtk.Button, config.profiles.len);
            self.choices = try alloc.alloc(Choice, config.profiles.len);
            const box = w.flow(3);
            card.append(box.as(gtk.Widget));
            for (config.profiles, ids, self.buttons, self.choices, 0..) |profile, *id, *button, *choice, i| {
                id.* = try alloc.dupe(u8, profile.id);
                button.* = w.wrappingButton(try alloc.dupeZ(u8, profile.label));
                button.*.as(gtk.Widget).setHexpand(1);
                button.*.as(gtk.Widget).addCssClass("pearl-pill");
                if (profile.description.len > 0) button.*.as(gtk.Widget).setTooltipText(try alloc.dupeZ(u8, profile.description));
                focus_state.tag(button.*.as(gtk.Widget), "sched-profile:{s}", .{profile.id});
                choice.* = .{ .view = self, .index = i };
                box.append(button.*.as(gtk.Widget));
                try self.connections.append(a, .{ .object = button.*.as(object.Object), .id = gtk.Button.signals.clicked.connect(button.*, *Choice, clicked, choice, .{}) });
            }
            self.ids = ids;
        }
        card.append(self.description.as(gtk.Widget));
        self.message = w.label("", "pearl-secondary");
        self.message.setWrap(1);
        card.append(self.message.as(gtk.Widget));
        self.update();
        return self;
    }

    pub fn destroy(self: *View) void {
        for (self.connections.items) |c| object.signalHandlerDisconnect(c.object, c.id);
        self.connections.deinit(a);
        self.arena.deinit();
        a.destroy(self);
    }

    pub fn update(self: *View) void {
        const service = self.service;
        var buffer: [512]u8 = undefined;
        const config = service.config;
        const profile: ?p.Profile = if (config) |c| if (service.status.profile) |i| c.profiles[i] else null else null;
        self.status.setText(service.describe(&buffer, std.mem.eql(u8, tr("en", "de"), "de")));
        self.description.setText(if (profile) |value| if (service.status.kind == .running or service.status.kind == .off) std.fmt.bufPrintZ(&buffer, "{s}", .{value.description}) catch "" else "" else "");
        self.description.as(gtk.Widget).setVisible(@intFromBool(self.description.getText()[0] != 0));
        const usable = service.enabled and service.applying == null and service.status.kind != .unavailable;
        for (self.buttons, self.ids) |button, id| {
            const current = if (profile) |value| std.mem.eql(u8, value.id, id) and (service.status.kind == .running or service.status.kind == .off) else false;
            if (current) button.as(gtk.Widget).addCssClass("pearl-selected") else button.as(gtk.Widget).removeCssClass("pearl-selected");
            button.as(gtk.Widget).setSensitive(@intFromBool(usable and !current));
        }
        var message: [600]u8 = undefined;
        self.message.setText(if (service.applying != null) tr("Applying profile...", "Profil wird angewendet...") else if (service.err) |err| std.fmt.bufPrintZ(&message, "{s}", .{err}) catch "" else "");
        self.message.as(gtk.Widget).setVisible(@intFromBool(self.message.getText()[0] != 0));
    }

    fn clicked(_: *gtk.Button, choice: *Choice) callconv(.c) void {
        const self = choice.view;
        const id = self.ids[choice.index];
        self.service.apply(id) catch |err| {
            log.warn("event=sched-profile-select profile={s} result={s}", .{ id, @errorName(err) });
            self.message.setText(if (err == error.Busy) tr("Another profile is being applied.", "Ein anderes Profil wird gerade angewendet.") else tr("This profile cannot be applied right now.", "Dieses Profil kann gerade nicht angewendet werden."));
            self.message.as(gtk.Widget).setVisible(1);
            return;
        };
        self.update();
    }
};
