//! The scheduling flyout opened from the bar widget: the scx catalog's
//! profiles with their descriptions, what runs checked. Each row starts its
//! profile with scxcli. The rows follow the catalog while the flyout is open.
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
    /// Owns everything built from the current profile list.
    arena: std.heap.ArenaAllocator = .init(a),
    /// Ids of the rows, in order.
    ids: []const []const u8 = &.{},
    status: *gtk.Label,
    /// What went wrong, under the status: a fallback to Default or an error.
    note: *gtk.Label,
    /// The profile rows, rebuilt when the list changes.
    list: *gtk.Box,
    edit_button: *gtk.Button,
    buttons: []*gtk.Button = &.{},
    checks: []*gtk.Image = &.{},
    /// Whether each profile's scheduler is installed.
    available: []bool = &.{},
    choices: []Choice = &.{},
    /// Signals of the rows.
    connections: std.ArrayList(Connection) = .empty,
    edit_signal: c_ulong = 0,
    /// The profile list the rows were built from.
    signature: u64 = 0,
    context: *anyopaque,
    /// Opens the profiles in Settings.
    edit: *const fn (*anyopaque) void,
    const Choice = struct { view: *View, index: usize };

    /// The flyout shows what scxcli gave the service: the catalog's
    /// profiles, or why they could not be read. Right after start, before
    /// scxcli has answered either way, there is nothing to show yet, and
    /// this fails with error.NoProfiles instead of opening an empty card.
    pub fn create(host: *gtk.Box, service: *Service, context: *anyopaque, edit: @FieldType(View, "edit")) !*View {
        service.refresh();
        if (!service.configured()) return error.NoProfiles;
        const self = try a.create(View);
        errdefer a.destroy(self);
        self.* = .{ .service = service, .context = context, .edit = edit, .status = undefined, .note = undefined, .list = w.column(2), .edit_button = gtk.Button.new() };
        const card = w.card();
        host.append(card.as(gtk.Widget));
        card.append(w.label(@import("i18n").dtr("pearl", "CPU Scheduler"), "pearl-card-title").as(gtk.Widget));
        self.status = w.label("", null);
        self.status.setWrap(1);
        card.append(self.status.as(gtk.Widget));
        self.note = w.label("", "pearl-secondary");
        card.append(self.note.as(gtk.Widget));
        // Everything about the state goes above the profiles.
        card.append(self.list.as(gtk.Widget));
        const label = w.label(@import("i18n").dtr("pearl", "Edit profiles..."), null);
        label.setXalign(0);
        self.edit_button.setChild(label.as(gtk.Widget));
        self.edit_button.as(gtk.Widget).addCssClass("pearl-menu-item");
        focus_state.tag(self.edit_button.as(gtk.Widget), "sched-profile-edit", .{});
        card.append(self.edit_button.as(gtk.Widget));
        self.edit_signal = gtk.Button.signals.clicked.connect(self.edit_button, *View, editClicked, self, .{});
        self.update();
        return self;
    }

    pub fn destroy(self: *View) void {
        self.disconnect();
        self.connections.deinit(a);
        object.signalHandlerDisconnect(self.edit_button.as(object.Object), self.edit_signal);
        self.arena.deinit();
        a.destroy(self);
    }

    fn disconnect(self: *View) void {
        for (self.connections.items) |c| object.signalHandlerDisconnect(c.object, c.id);
        self.connections.clearRetainingCapacity();
    }

    /// No rows, and nothing that refers to them.
    fn clear(self: *View) void {
        self.disconnect();
        while (self.list.as(gtk.Widget).getFirstChild()) |child| self.list.remove(child);
        self.ids = &.{};
        self.buttons = &.{};
        self.checks = &.{};
        self.available = &.{};
        self.choices = &.{};
        _ = self.arena.reset(.retain_capacity);
    }

    /// One row per listed profile. A recommended scheduler that is not
    /// installed is listed, but cannot be started.
    fn rebuild(self: *View) !void {
        self.clear();
        const listing = self.service.listing orelse return;
        const alloc = self.arena.allocator();
        const n = listing.profiles.len;
        const ids = try alloc.alloc([]const u8, n);
        const buttons = try alloc.alloc(*gtk.Button, n);
        const checks = try alloc.alloc(*gtk.Image, n);
        const availability = try alloc.alloc(bool, n);
        const choices = try alloc.alloc(Choice, n);
        for (listing.profiles, ids, buttons, checks, availability, choices, 0..) |profile, *id, *button, *check, *available, *choice, i| {
            id.* = try alloc.dupe(u8, profile.id);
            available.* = profile.available;
            const labels = w.column(2);
            labels.append(w.label(try alloc.dupeSentinel(u8, profile.label, 0), "pearl-sched-name").as(gtk.Widget));
            if (!profile.available) {
                labels.append(w.label(@import("i18n").dtr("pearl", "Not installed"), "pearl-secondary").as(gtk.Widget));
            } else if (profile.description.len > 0) labels.append(w.label(try alloc.dupeSentinel(u8, profile.description, 0), "pearl-secondary").as(gtk.Widget));
            check.* = w.icon("pearl-emblem-ok-symbolic");
            check.*.setPixelSize(16);
            check.*.as(gtk.Widget).setValign(.center);
            const line = w.row(12);
            line.append(labels.as(gtk.Widget));
            line.append(check.*.as(gtk.Widget));
            button.* = gtk.Button.new();
            button.*.setChild(line.as(gtk.Widget));
            button.*.as(gtk.Widget).addCssClass("pearl-menu-item");
            button.*.as(gtk.Widget).addCssClass("pearl-sched-row");
            w.name(button.*.as(gtk.Widget), try alloc.dupeSentinel(u8, profile.label, 0));
            focus_state.tag(button.*.as(gtk.Widget), "sched-profile:{s}", .{profile.id});
            choice.* = .{ .view = self, .index = i };
            self.list.append(button.*.as(gtk.Widget));
            try self.connections.append(a, .{ .object = button.*.as(object.Object), .id = gtk.Button.signals.clicked.connect(button.*, *Choice, clicked, choice, .{}) });
        }
        self.ids = ids;
        self.buttons = buttons;
        self.checks = checks;
        self.available = availability;
        self.choices = choices;
    }

    pub fn update(self: *View) void {
        const service = self.service;
        const signature = service.signature();
        if (signature != self.signature) {
            // The rows are taken as built only once all of them are; a
            // rebuild that failed part way leaves none, and is tried again
            // at the next update.
            if (self.rebuild()) |_| {
                self.signature = signature;
            } else |err| {
                log.warn("event=sched-profile-flyout result={s}", .{@errorName(err)});
                self.clear();
                self.signature = 0;
            }
        }
        var buffer: [512]u8 = undefined;
        self.status.setText(service.describe(&buffer));
        const usable = service.enabled and service.applying == null and service.status.kind != .unavailable;
        for (self.buttons, self.checks, self.available, 0..) |button, check, available, i| {
            // A profile for what runs is checked; a selection kept while the
            // unit is stopped is shown dimmed, and choosing it starts it.
            const mark = service.mark(i);
            if (mark == .current) button.as(gtk.Widget).addCssClass("pearl-sched-current") else button.as(gtk.Widget).removeCssClass("pearl-sched-current");
            check.as(gtk.Widget).setOpacity(switch (mark) {
                .current => 1,
                .stopped => 0.4,
                .configured => 0,
                .none => 0,
            });
            check.as(gtk.Widget).setTooltipText(if (mark == .stopped) @import("i18n").dtr("pearl", "Selected, stopped") else null);
            button.as(gtk.Widget).setSensitive(@intFromBool(usable and available));
        }
        self.edit_button.as(gtk.Widget).setVisible(@intFromBool(service.listing != null));
        var note: [600]u8 = undefined;
        self.note.setText(if (service.applying != null) "" else if (service.err) |err| std.mem.printSentinel(&note, "{s}", .{err}, 0) catch "" else service.describeNotice(&note));
        self.note.as(gtk.Widget).setVisible(@intFromBool(self.note.getText()[0] != 0));
    }

    fn editClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.edit(self.context);
    }

    fn clicked(_: *gtk.Button, choice: *Choice) callconv(.c) void {
        const self = choice.view;
        const id = self.ids[choice.index];
        // Choosing what already runs does not restart it.
        if (self.service.mark(choice.index) == .current) return;
        self.service.apply(id) catch |err| {
            log.warn("event=sched-profile-select profile={s} result={s}", .{ id, @errorName(err) });
            self.note.setText(switch (err) {
                error.Busy => @import("i18n").dtr("pearl", "Another profile is being applied."),
                error.NotInstalled => @import("i18n").dtr("pearl", "This profile's scheduler is not installed."),
                else => @import("i18n").dtr("pearl", "This profile cannot be applied right now."),
            });
            self.note.as(gtk.Widget).setVisible(1);
            return;
        };
        self.update();
    }
};
