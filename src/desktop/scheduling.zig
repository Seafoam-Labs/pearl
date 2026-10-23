//! The scheduling flyout opened from the bar widget: a list of profiles with
//! their descriptions, the selected one checked. Each row applies an
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
    /// What went wrong, under the status: a fallback to Default or an error.
    note: *gtk.Label,
    buttons: []*gtk.Button = &.{},
    checks: []*gtk.Image = &.{},
    choices: []Choice = &.{},
    connections: std.ArrayList(Connection) = .empty,
    context: *anyopaque,
    /// Opens the profiles in Settings.
    edit: *const fn (*anyopaque) void,
    const Choice = struct { view: *View, index: usize };

    /// Fails with error.NoProfiles when no profile file is installed, so the
    /// flyout only opens on systems that configure it.
    pub fn create(host: *gtk.Box, service: *Service, context: *anyopaque, edit: @FieldType(View, "edit")) !*View {
        service.refresh();
        if (!service.configured()) return error.NoProfiles;
        const self = try a.create(View);
        errdefer a.destroy(self);
        self.* = .{ .service = service, .context = context, .edit = edit, .status = undefined, .note = undefined };
        errdefer self.arena.deinit();
        const alloc = self.arena.allocator();
        const card = w.card();
        host.append(card.as(gtk.Widget));
        card.append(w.label(@import("i18n").dtr("pearl", "CPU Scheduler"), "pearl-card-title").as(gtk.Widget));
        self.status = w.label("", null);
        self.status.setWrap(1);
        card.append(self.status.as(gtk.Widget));
        self.note = w.label("", "pearl-secondary");
        card.append(self.note.as(gtk.Widget));
        // Everything about the state goes above the profiles.
        if (service.config) |config| {
            const ids = try alloc.alloc([]const u8, config.profiles.len);
            self.buttons = try alloc.alloc(*gtk.Button, config.profiles.len);
            self.checks = try alloc.alloc(*gtk.Image, config.profiles.len);
            self.choices = try alloc.alloc(Choice, config.profiles.len);
            const list = w.column(2);
            card.append(list.as(gtk.Widget));
            for (config.profiles, ids, self.buttons, self.checks, self.choices, 0..) |profile, *id, *button, *check, *choice, i| {
                id.* = try alloc.dupe(u8, profile.id);
                const labels = w.column(2);
                labels.append(w.label(try alloc.dupeZ(u8, profile.label), "pearl-sched-name").as(gtk.Widget));
                if (profile.description.len > 0) labels.append(w.label(try alloc.dupeZ(u8, profile.description), "pearl-secondary").as(gtk.Widget));
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
                w.name(button.*.as(gtk.Widget), try alloc.dupeZ(u8, profile.label));
                focus_state.tag(button.*.as(gtk.Widget), "sched-profile:{s}", .{profile.id});
                choice.* = .{ .view = self, .index = i };
                list.append(button.*.as(gtk.Widget));
                try self.connections.append(a, .{ .object = button.*.as(object.Object), .id = gtk.Button.signals.clicked.connect(button.*, *Choice, clicked, choice, .{}) });
            }
            self.ids = ids;
        }
        if (service.config != null) {
            const edit_button = gtk.Button.new();
            const label = w.label(@import("i18n").dtr("pearl", "Edit profiles..."), null);
            label.setXalign(0);
            edit_button.setChild(label.as(gtk.Widget));
            edit_button.as(gtk.Widget).addCssClass("pearl-menu-item");
            focus_state.tag(edit_button.as(gtk.Widget), "sched-profile-edit", .{});
            card.append(edit_button.as(gtk.Widget));
            try self.connections.append(a, .{ .object = edit_button.as(object.Object), .id = gtk.Button.signals.clicked.connect(edit_button, *View, editClicked, self, .{}) });
        }
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
        self.status.setText(service.describe(&buffer));
        const usable = service.enabled and service.applying == null and service.status.kind != .unavailable;
        for (self.buttons, self.checks, self.ids) |button, check, id| {
            // Default stays selected while a scheduler outside the profiles runs.
            const current = if (profile) |value| std.mem.eql(u8, value.id, id) and (service.status.kind == .running or service.status.kind == .off or service.status.kind == .custom) else false;
            if (current) button.as(gtk.Widget).addCssClass("pearl-sched-current") else button.as(gtk.Widget).removeCssClass("pearl-sched-current");
            check.as(gtk.Widget).setOpacity(if (current) 1 else 0);
            button.as(gtk.Widget).setSensitive(@intFromBool(usable));
        }
        var note: [600]u8 = undefined;
        self.note.setText(if (service.applying != null) "" else if (service.err) |err| std.fmt.bufPrintZ(&note, "{s}", .{err}) catch "" else service.describeNotice(&note));
        self.note.as(gtk.Widget).setVisible(@intFromBool(self.note.getText()[0] != 0));
    }

    fn editClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.edit(self.context);
    }

    fn clicked(_: *gtk.Button, choice: *Choice) callconv(.c) void {
        const self = choice.view;
        const id = self.ids[choice.index];
        // Choosing the profile already in effect does not restart it.
        if (choice.view.checks[choice.index].as(gtk.Widget).getOpacity() > 0) return;
        self.service.apply(id) catch |err| {
            log.warn("event=sched-profile-select profile={s} result={s}", .{ id, @errorName(err) });
            self.note.setText(if (err == error.Busy) @import("i18n").dtr("pearl", "Another profile is being applied.") else @import("i18n").dtr("pearl", "This profile cannot be applied right now."));
            self.note.as(gtk.Widget).setVisible(1);
            return;
        };
        self.update();
    }
};
