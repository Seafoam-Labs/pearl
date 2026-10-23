//! Scheduler profiles in Settings. It drives the same scheduler service and
//! helper as the bar flyout, laid out like the Power page's power modes.
const std = @import("std");
const gtk = @import("gtk4");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const p = @import("../services/sched_profiles.zig");
const Service = @import("../services/scheduling.zig").Service;
const log = std.log.scoped(.settings);
const a = std.heap.c_allocator;
const Connection = struct { obj: *object.Object, id: c_ulong };

pub const View = struct {
    service: *Service,
    arena: std.heap.ArenaAllocator = .init(a),
    ids: []const []const u8 = &.{},
    buttons: []*gtk.CheckButton = &.{},
    bindings: []Binding = &.{},
    status: *gtk.Label,
    message: *gtk.Label,
    connections: std.ArrayList(Connection) = .empty,
    updating: bool = false,
    const Binding = struct { view: *View, index: usize };

    pub fn create(host: *gtk.Box, service: *Service) !*View {
        const self = try a.create(View);
        errdefer a.destroy(self);
        self.* = .{ .service = service, .status = undefined, .message = undefined };
        errdefer self.arena.deinit();
        const alloc = self.arena.allocator();
        const root = w.column(16);
        root.as(gtk.Widget).addCssClass("power-view");
        host.append(root.as(gtk.Widget));
        const section = w.column(8);
        section.append(w.label(@import("i18n").dtr("pearl", "CPU Scheduler"), "pearl-section-title").as(gtk.Widget));
        root.append(section.as(gtk.Widget));
        self.status = w.label("", "pearl-secondary");
        self.status.setWrap(1);
        section.append(self.status.as(gtk.Widget));
        // What went wrong goes under the status, above the profiles.
        self.message = w.label("", "pearl-secondary");
        self.message.setWrap(1);
        section.append(self.message.as(gtk.Widget));
        if (service.config) |config| {
            const ids = try alloc.alloc([]const u8, config.profiles.len);
            self.buttons = try alloc.alloc(*gtk.CheckButton, config.profiles.len);
            self.bindings = try alloc.alloc(Binding, config.profiles.len);
            const flow = w.flow(3);
            flow.setHomogeneous(1);
            for (config.profiles, ids, self.buttons, self.bindings, 0..) |profile, *id, *button, *binding, i| {
                id.* = try alloc.dupe(u8, profile.id);
                button.* = gtk.CheckButton.new();
                if (i > 0) button.*.setGroup(self.buttons[0]);
                const labels = w.column(5);
                labels.append(w.label(try alloc.dupeZ(u8, profile.label), "settings-row-title").as(gtk.Widget));
                if (profile.description.len > 0) {
                    const detail = w.label(try alloc.dupeZ(u8, profile.description), "pearl-secondary");
                    detail.setWrap(1);
                    labels.append(detail.as(gtk.Widget));
                }
                button.*.setChild(labels.as(gtk.Widget));
                button.*.as(gtk.Widget).addCssClass("power-mode");
                w.name(button.*.as(gtk.Widget), try alloc.dupeZ(u8, profile.label));
                binding.* = .{ .view = self, .index = i };
                flow.insert(button.*.as(gtk.Widget), -1);
                try self.connections.append(a, .{ .obj = button.*.as(object.Object), .id = gtk.CheckButton.signals.toggled.connect(button.*, *Binding, toggled, binding, .{}) });
            }
            self.ids = ids;
            section.append(flow.as(gtk.Widget));
        }
        self.update();
        return self;
    }

    pub fn destroy(self: *View) void {
        for (self.connections.items) |c| object.signalHandlerDisconnect(c.obj, c.id);
        self.connections.deinit(a);
        self.arena.deinit();
        a.destroy(self);
    }

    pub fn update(self: *View) void {
        self.updating = true;
        defer self.updating = false;
        const service = self.service;
        var buffer: [512]u8 = undefined;
        const profile: ?p.Profile = if (service.config) |c| if (service.status.profile) |i| c.profiles[i] else null else null;
        self.status.setText(service.describe(&buffer));
        const usable = service.enabled and service.applying == null and service.status.kind != .unavailable;
        for (self.buttons, self.ids) |button, id| {
            // Default stays selected while a scheduler outside the profiles runs.
            const current = if (profile) |value| std.mem.eql(u8, value.id, id) and (service.status.kind == .running or service.status.kind == .off or service.status.kind == .custom) else false;
            button.setActive(@intFromBool(current));
            if (current) button.as(gtk.Widget).addCssClass("power-selected") else button.as(gtk.Widget).removeCssClass("power-selected");
            button.as(gtk.Widget).setSensitive(@intFromBool(usable));
        }
        var message: [600]u8 = undefined;
        self.message.setText(if (service.applying != null) "" else if (service.err) |err| std.fmt.bufPrintZ(&message, "{s}", .{err}) catch "" else service.describeNotice(&message));
        self.message.as(gtk.Widget).setVisible(@intFromBool(self.message.getText()[0] != 0));
    }

    fn toggled(button: *gtk.CheckButton, binding: *Binding) callconv(.c) void {
        const self = binding.view;
        // Programmatic updates and the button being unset do not select anything.
        if (self.updating or button.getActive() == 0) return;
        const id = self.ids[binding.index];
        self.service.apply(id) catch |err| {
            log.warn("event=sched-profile-select profile={s} result={s}", .{ id, @errorName(err) });
            self.update();
            self.message.setText(if (err == error.Busy) @import("i18n").dtr("pearl", "Another profile is being applied.") else @import("i18n").dtr("pearl", "This profile cannot be applied right now."));
            self.message.as(gtk.Widget).setVisible(1);
            return;
        };
        self.update();
    }
};
