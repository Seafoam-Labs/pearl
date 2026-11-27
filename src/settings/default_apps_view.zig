//! Default applications page. Choices are written straight to the XDG
//! defaults (mimeapps.list through GIO, xdg-terminals.list for terminals), so
//! they apply immediately and are honored outside Pearl as well.
const std = @import("std");
const gtk = @import("gtk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const unix = @import("giounix2");
const w = @import("../ui/components/widgets.zig");
const policy = @import("../services/default_apps.zig");
const log = std.log.scoped(.settings);
const a = std.heap.c_allocator;
const Connection = struct { obj: *object.Object, id: c_ulong };

pub const View = struct {
    root: *gtk.Box,
    status: *gtk.Label,
    rows: []Row,
    connections: std.ArrayList(Connection) = .empty,
    /// Owns candidate ids and names rebuilt on every update.
    arena: std.heap.ArenaAllocator = .init(a),
    filling: bool = false,

    const Row = struct {
        view: *View,
        spec: *const policy.Spec,
        dropdown: *gtk.DropDown,
        /// Desktop IDs matching the dropdown's current model order.
        ids: std.ArrayList([:0]const u8) = .empty,
    };

    pub fn create(host: *gtk.Box) !*View {
        const self = try a.create(View);
        errdefer a.destroy(self);
        self.* = .{ .root = w.column(16), .status = undefined, .rows = try a.alloc(Row, policy.specs.len) };
        errdefer a.free(self.rows);
        errdefer self.arena.deinit();
        host.append(self.root.as(gtk.Widget));
        // Form rows carry their own padding and flush separators, so the card
        // itself must stay spacing-free like the other preference pages.
        const card = w.column(0);
        card.as(gtk.Widget).addCssClass("settings-card");
        self.root.append(card.as(gtk.Widget));
        // Immediacy and scope are stated once, in the window footer; the card
        // only surfaces failures, so the rows start at the top.
        self.status = w.label("", "pearl-secondary");
        self.status.setWrap(1);
        self.status.as(gtk.Widget).setVisible(0);
        card.append(self.status.as(gtk.Widget));
        for (&policy.specs, self.rows) |*spec, *row| {
            const line = w.flow(2);
            line.setHomogeneous(0);
            line.as(gtk.Widget).addCssClass("settings-form-row");
            const titles = w.column(4);
            const title = w.label(@import("i18n").dtr("pearl", spec.label), "settings-row-title");
            titles.append(title.as(gtk.Widget));
            const detail = w.label(@import("i18n").dtr("pearl", spec.description), "pearl-secondary");
            detail.as(gtk.Widget).setHalign(.start);
            titles.append(detail.as(gtk.Widget));
            line.insert(titles.as(gtk.Widget), -1);
            const dropdown = gtk.DropDown.new(null, null);
            dropdown.as(gtk.Widget).setHalign(.end);
            dropdown.as(gtk.Widget).setValign(.center);
            w.name(dropdown.as(gtk.Widget), title.getText());
            line.insert(dropdown.as(gtk.Widget), -1);
            card.append(line.as(gtk.Widget));
            row.* = .{ .view = self, .spec = spec, .dropdown = dropdown };
            const signal = object.Object.signals.notify.connect(dropdown.as(object.Object), *Row, selectedChanged, row, .{ .detail = "selected" });
            try self.connections.append(a, .{ .obj = dropdown.as(object.Object), .id = signal });
        }
        self.update();
        return self;
    }

    pub fn destroy(self: *View) void {
        for (self.connections.items) |c| object.signalHandlerDisconnect(c.obj, c.id);
        self.connections.deinit(a);
        for (self.rows) |*row| row.ids.deinit(a);
        self.arena.deinit();
        a.free(self.rows);
        a.destroy(self);
    }

    /// Re-read candidates and the current defaults; called when the page is
    /// shown so choices made elsewhere stay visible.
    pub fn update(self: *View) void {
        self.filling = true;
        defer self.filling = false;
        _ = self.arena.reset(.retain_capacity);
        const alloc = self.arena.allocator();
        for (self.rows) |*row| {
            row.ids.clearRetainingCapacity();
            const model = gtk.StringList.new(null);
            defer model.unref();
            self.fillCandidates(alloc, row, model) catch |err| {
                log.warn("event=default-apps-candidates-failed category={s} error={s}", .{ @tagName(row.spec.category), @errorName(err) });
            };
            row.dropdown.setModel(model.as(gio.ListModel));
            const current = self.currentDefault(alloc, row.spec) catch null;
            var index: c_uint = gtk.INVALID_LIST_POSITION;
            if (current) |id| for (row.ids.items, 0..) |candidate, i| {
                if (std.mem.eql(u8, candidate, id)) {
                    index = @intCast(i);
                    break;
                }
            };
            row.dropdown.setSelected(index);
        }
    }

    fn currentDefault(_: *View, alloc: std.mem.Allocator, spec: *const policy.Spec) !?[]const u8 {
        return @import("launch.zig").defaultDesktopId(alloc, spec.category);
    }

    fn fillCandidates(self: *View, alloc: std.mem.Allocator, row: *Row, model: *gtk.StringList) !void {
        if (row.spec.category == .terminal) return self.fillTerminalCandidates(alloc, row, model);
        // GIR marks this list non-null, but the C API returns NULL for no apps.
        const get: *const fn ([*:0]const u8) callconv(.c) ?*glib.List = @ptrCast(&gio.AppInfo.getAllForType);
        const list = get(row.spec.mimes[0]);
        defer if (list) |head| {
            var it: ?*glib.List = head;
            while (it) |node| : (it = node.f_next) {
                const info: *gio.AppInfo = @ptrCast(@alignCast(node.f_data.?));
                info.as(object.Object).unref();
            }
            head.free();
        };
        var it = list;
        while (it) |node| : (it = node.f_next) {
            const info: *gio.AppInfo = @ptrCast(@alignCast(node.f_data.?));
            try self.appendCandidate(alloc, row, model, info);
        }
    }

    fn fillTerminalCandidates(self: *View, alloc: std.mem.Allocator, row: *Row, model: *gtk.StringList) !void {
        const get: *const fn () callconv(.c) ?*glib.List = @ptrCast(&gio.AppInfo.getAll);
        const list = get();
        defer if (list) |head| {
            var it: ?*glib.List = head;
            while (it) |node| : (it = node.f_next) {
                const info: *gio.AppInfo = @ptrCast(@alignCast(node.f_data.?));
                info.as(object.Object).unref();
            }
            head.free();
        };
        var it = list;
        while (it) |node| : (it = node.f_next) {
            const info: *gio.AppInfo = @ptrCast(@alignCast(node.f_data.?));
            const desktop = object.ext.cast(unix.DesktopAppInfo, info) orelse continue;
            const raw = desktop.getCategories() orelse continue;
            if (!policy.hasCategory(std.mem.span(raw), "TerminalEmulator")) continue;
            try self.appendCandidate(alloc, row, model, info);
        }
    }

    fn appendCandidate(self: *View, alloc: std.mem.Allocator, row: *Row, model: *gtk.StringList, info: *gio.AppInfo) !void {
        _ = self;
        if (row.ids.items.len >= 256) return;
        if (info.shouldShow() == 0) return;
        const raw_id = info.getId() orelse return;
        const id = std.mem.span(raw_id);
        for (row.ids.items) |existing| if (std.mem.eql(u8, existing, id)) return;
        const name = std.mem.span(info.getDisplayName());
        const owned_id = try alloc.dupeSentinel(u8, id, 0);
        errdefer alloc.free(owned_id);
        const owned_name = try alloc.dupeSentinel(u8, name, 0);
        defer alloc.free(owned_name);
        try row.ids.append(a, owned_id);
        model.append(owned_name);
    }

    fn selectedChanged(_: *object.Object, _: *object.ParamSpec, row: *Row) callconv(.c) void {
        const self = row.view;
        if (self.filling) return;
        const index = row.dropdown.getSelected();
        if (index == gtk.INVALID_LIST_POSITION or index >= row.ids.items.len) return;
        const id = row.ids.items[index];
        self.apply(row.spec, id) catch |err| {
            log.warn("event=default-apps-apply-failed category={s} app={s} error={s}", .{ @tagName(row.spec.category), id, @errorName(err) });
            self.status.setText(@import("i18n").dtr("pearl", "The default application could not be changed."));
            self.status.as(gtk.Widget).setVisible(1);
            self.update();
            return;
        };
        self.status.as(gtk.Widget).setVisible(0);
    }

    fn apply(_: *View, spec: *const policy.Spec, id: [:0]const u8) !void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        if (spec.category == .terminal) {
            const dir = try @import("launch.zig").configHome(alloc);
            return policy.setTerminalDefault(alloc, dir, id);
        }
        const desktop = unix.DesktopAppInfo.new(id) orelse return error.ApplicationNotFound;
        defer desktop.as(object.Object).unref();
        for (spec.mimes) |mime| {
            var err: ?*glib.Error = null;
            if (gio.AppInfo.setAsDefaultForType(desktop.as(gio.AppInfo), mime, &err) == 0) {
                if (err) |e| {
                    log.warn("event=default-apps-set-failed mime={s} detail={s}", .{ mime, if (e.f_message) |m| std.mem.span(m) else "" });
                    e.free();
                }
                return error.SetDefaultFailed;
            }
        }
    }
};
