//! Manager-owned keyboard popup for an explicit, persistent launcher choice.
const std = @import("std");
const gtk = @import("gtk4");
const gio = @import("gio2");
const unix = @import("giounix2");
const glib = @import("glib2");
const object = @import("gobject2");
const identity = @import("app_identity.zig");
const Apps = @import("apps.zig");
const widgets = @import("../ui/components/widgets.zig");
const tr = @import("text.zig").tr;
const a = std.heap.c_allocator;
pub const Request = struct {
    key: identity.Key,
    window_id: ?[]const u8 = null,
    source_pin: ?[]const u8 = null,
    current_desktop: ?[]const u8 = null,
};
pub const View = struct {
    host: *gtk.Box,
    index: *Apps.Index,
    preferences: *@import("../config/service.zig").Service,
    client: *@import("../aqueous/client.zig").Client,
    arena: std.heap.ArenaAllocator,
    rows_arena: std.heap.ArenaAllocator = .init(a),
    request: Request,
    search: *gtk.SearchEntry,
    list: *gtk.ListBox,
    message: *gtk.Label,
    apply_button: *gtk.Button,
    reset_button: *gtk.Button,
    more: *gtk.Button,
    selected_id: ?[:0]u8 = null,
    rows: std.ArrayList([:0]const u8) = .empty,
    generation: u64 = 0,
    revision: u64,
    limit: usize = 50,
    filling: bool = false,
    pending: ?u64 = null,
    idle: c_uint = 0,
    signals: [5]c_ulong = @splat(0),
    pub fn create(host: *gtk.Box, index: *Apps.Index, preferences: *@import("../config/service.zig").Service, client: *@import("../aqueous/client.zig").Client, request: Request) !*View {
        const self = try a.create(View);
        errdefer a.destroy(self);
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const owned: Request = .{ .key = .{ .backend = request.key.backend, .identity = try alloc.dupe(u8, request.key.identity) }, .window_id = if (request.window_id) |id| try alloc.dupe(u8, id) else null, .source_pin = if (request.source_pin) |id| try alloc.dupe(u8, id) else null, .current_desktop = if (request.current_desktop) |id| try alloc.dupe(u8, id) else null };
        host.append(widgets.label(tr("Use launcher", "Starter verwenden"), "pearl-title").as(gtk.Widget));
        const description = widgets.label(try std.fmt.allocPrintSentinel(alloc, "{s}\n{s}{s}", .{ owned.key.identity, tr("Use this launcher for all windows of this application.", "Diesen Starter für alle Fenster dieser Anwendung verwenden."), if (owned.source_pin != null) tr(" Its dock pin will also be updated.", " Der Dock-Eintrag wird ebenfalls aktualisiert.") else "" }, 0), "pearl-secondary");
        description.setWrap(1);
        description.setMaxWidthChars(48);
        host.append(description.as(gtk.Widget));
        const search = gtk.SearchEntry.new();
        search.setPlaceholderText(tr("Search applications or desktop IDs", "Anwendungen oder Desktop-IDs suchen"));
        widgets.name(search.as(gtk.Widget), "Launcher search");
        host.append(search.as(gtk.Widget));
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.setMinContentHeight(160);
        scroll.setMaxContentHeight(280);
        scroll.setPropagateNaturalHeight(1);
        const list = gtk.ListBox.new();
        list.as(gtk.Widget).addCssClass("pearl-launcher-choices");
        list.setSelectionMode(.single);
        list.setActivateOnSingleClick(0);
        scroll.setChild(list.as(gtk.Widget));
        host.append(scroll.as(gtk.Widget));
        const more = gtk.Button.newWithLabel(tr("Show more", "Mehr anzeigen"));
        host.append(more.as(gtk.Widget));
        const message = widgets.label("", "pearl-secondary");
        message.setWrap(1);
        message.setMaxWidthChars(48);
        host.append(message.as(gtk.Widget));
        const buttons = gtk.Box.new(.horizontal, 8);
        const apply_button = gtk.Button.newWithLabel(tr("Use launcher", "Starter verwenden"));
        widgets.name(apply_button.as(gtk.Widget), "Use selected launcher");
        const reset_button = gtk.Button.newWithLabel(tr("Reset to automatic", "Automatische Zuordnung"));
        widgets.name(reset_button.as(gtk.Widget), "Reset launcher to automatic");
        buttons.append(apply_button.as(gtk.Widget));
        buttons.append(reset_button.as(gtk.Widget));
        host.append(buttons.as(gtk.Widget));
        self.* = .{ .host = host, .index = index, .preferences = preferences, .client = client, .arena = arena, .request = owned, .search = search, .list = list, .message = message, .apply_button = apply_button, .reset_button = reset_button, .more = more, .revision = preferences.revision, .generation = index.generation };
        errdefer {
            if (self.selected_id) |id| a.free(id);
            self.rows_arena.deinit();
            self.disconnect();
        }
        self.selected_id = if (owned.current_desktop) |id| try a.dupeZ(u8, id) else null;
        self.signals[0] = gtk.SearchEntry.signals.search_changed.connect(search, *View, searchChanged, self, .{});
        self.signals[1] = gtk.ListBox.signals.row_selected.connect(list, *View, selected, self, .{});
        self.signals[2] = gtk.Button.signals.clicked.connect(apply_button, *View, applyClicked, self, .{});
        self.signals[3] = gtk.Button.signals.clicked.connect(reset_button, *View, resetClicked, self, .{});
        self.signals[4] = gtk.Button.signals.clicked.connect(more, *View, moreClicked, self, .{});
        try self.rebuild();
        return self;
    }
    pub fn destroy(self: *View) void {
        self.disconnect();
        if (self.idle != 0) _ = glib.Source.remove(self.idle);
        if (self.selected_id) |id| a.free(id);
        self.rows_arena.deinit();
        self.arena.deinit();
        a.destroy(self);
    }
    fn disconnect(self: *View) void {
        for ([_]*object.Object{ self.search.as(object.Object), self.list.as(object.Object), self.apply_button.as(object.Object), self.reset_button.as(object.Object), self.more.as(object.Object) }, self.signals) |obj, signal| {
            if (signal != 0) object.signalHandlerDisconnect(obj, signal);
        }
    }
    fn queue(self: *View) void {
        if (self.idle == 0) self.idle = glib.idleAdd(refresh, self);
    }
    fn refresh(data: ?*anyopaque) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(data.?));
        self.idle = 0;
        self.rebuild() catch self.message.setText(tr("Application list unavailable.", "Anwendungsliste nicht verfügbar."));
        return 0;
    }
    fn searchChanged(_: *gtk.SearchEntry, self: *View) callconv(.c) void {
        self.limit = 50;
        self.queue();
    }
    fn moreClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.limit += 50;
        self.queue();
    }
    fn selected(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *View) callconv(.c) void {
        if (self.filling) return;
        const index: usize = @intCast((row orelse return).getIndex());
        if (index >= self.rows.items.len) return;
        const copy = a.dupeZ(u8, self.rows.items[index]) catch return;
        if (self.selected_id) |old| a.free(old);
        self.selected_id = copy;
        self.sensitivity();
    }
    fn available(self: *View, id: []const u8) bool {
        if (self.index.catalog) |catalog| for (catalog.entries.items) |entry| {
            if (entry.action == null and std.mem.eql(u8, id, entry.id)) return true;
        };
        return false;
    }
    fn sensitivity(self: *View) void {
        const ready = self.pending == null and self.preferences.job == null;
        self.apply_button.as(gtk.Widget).setSensitive(@intFromBool(ready and self.selected_id != null and self.available(self.selected_id.?)));
        self.reset_button.as(gtk.Widget).setSensitive(@intFromBool(ready and identity.lookup(self.preferences.prefs().application_launchers, self.request.key) != null));
        self.search.as(gtk.Widget).setSensitive(@intFromBool(self.pending == null));
        self.list.as(gtk.Widget).setSensitive(@intFromBool(self.pending == null));
    }
    fn rebuild(self: *View) !void {
        self.filling = true;
        defer self.filling = false;
        while (self.list.as(gtk.Widget).getFirstChild()) |child| self.list.remove(child);
        _ = self.rows_arena.reset(.retain_capacity);
        self.rows = .empty;
        const alloc = self.rows_arena.allocator();
        const query = try Apps.fold(alloc, std.mem.span(self.search.as(gtk.Editable).getText()));
        var matches: usize = 0;
        if (self.index.catalog) |catalog| for (catalog.entries.items) |entry| {
            if (entry.action != null or !@import("dock_policy.zig").desktopId(entry.id)) continue;
            if (query.len != 0 and std.mem.indexOf(u8, entry.folded, query) == null and std.mem.indexOf(u8, try Apps.fold(alloc, entry.id), query) == null) continue;
            matches += 1;
            if (self.rows.items.len >= self.limit) continue;
            try self.rows.append(alloc, try alloc.dupeZ(u8, entry.id));
            const box = gtk.Box.new(.horizontal, 8);
            const icon = if (entry.info.getIcon()) |gicon| gtk.Image.newFromGicon(gicon) else gtk.Image.newFromIconName("pearl-application-x-executable-symbolic");
            icon.setPixelSize(28);
            box.append(icon.as(gtk.Widget));
            const labels = gtk.Box.new(.vertical, 2);
            for ([_][:0]const u8{ entry.name, entry.id }, 0..) |text, i| {
                const label = widgets.label(text, if (i == 0) null else "pearl-secondary");
                label.setEllipsize(.end);
                label.setMaxWidthChars(42);
                labels.append(label.as(gtk.Widget));
            }
            box.append(labels.as(gtk.Widget));
            self.list.append(box.as(gtk.Widget));
            const row = self.list.getRowAtIndex(@intCast(self.rows.items.len - 1)).?;
            widgets.name(row.as(gtk.Widget), entry.id);
            if (self.selected_id) |id| if (std.mem.eql(u8, id, entry.id)) self.list.selectRow(row);
        };
        self.more.as(gtk.Widget).setVisible(@intFromBool(matches > self.rows.items.len));
        self.sensitivity();
    }
    /// Called by manager reconciliation, never from a widget callback. True closes the popup.
    pub fn update(self: *View) bool {
        if (self.pending) |job| {
            if (self.preferences.completed_job >= job) {
                self.pending = null;
                if (self.preferences.completed_job == job and self.preferences.completed_error == null) return true;
                self.message.setText(tr("Could not save the launcher choice. Try again.", "Starter-Auswahl konnte nicht gespeichert werden. Erneut versuchen."));
                self.revision = self.preferences.revision;
            }
        }
        if (self.generation != self.index.generation) {
            self.generation = self.index.generation;
            self.queue();
        }
        self.sensitivity();
        return false;
    }
    fn applyClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.commit(self.selected_id orelse return) catch |err| self.failed(err);
    }
    fn resetClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.commit(null) catch |err| self.failed(err);
    }
    fn failed(self: *View, err: anyerror) void {
        self.message.setText(if (err == error.Conflict) tr("Preferences changed. Reopen the picker to review the current choice.", "Einstellungen geändert. Auswahl erneut öffnen und prüfen.") else tr("Launcher choice unavailable. Reopen the picker and try again.", "Starter-Auswahl nicht verfügbar. Erneut öffnen und versuchen."));
    }
    fn commit(self: *View, desktop_id: ?[:0]const u8) !void {
        if (self.pending != null or self.client.availability != .ready) return error.Unavailable;
        const session = self.client.model.get(.session, "session") orelse return error.Unavailable;
        if (session.locked) return error.Locked;
        if (self.preferences.revision != self.revision) return error.Conflict;
        if (self.request.window_id) |id| {
            const win = self.client.model.get(.window, id) orelse return error.StaleWindow;
            if (!self.request.key.eql(identity.key(win.*) orelse return error.StaleWindow)) return error.StaleWindow;
        }
        if (desktop_id) |id| {
            if (!self.available(id)) return error.StaleApplication;
            const desktop = unix.DesktopAppInfo.new(id) orelse return error.StaleApplication;
            defer desktop.unref();
            if (desktop.as(gio.AppInfo).shouldShow() == 0) return error.StaleApplication;
        }
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var prefs = self.preferences.prefs();
        prefs.application_launchers = try identity.change(arena.allocator(), prefs.application_launchers, self.request.key, desktop_id);
        prefs.pinned_apps = try identity.replacePin(arena.allocator(), prefs.pinned_apps, self.request.source_pin, desktop_id);
        try prefs.validate();
        const json = try std.json.Stringify.valueAlloc(arena.allocator(), prefs, .{});
        try self.preferences.apply(json, self.revision);
        self.pending = self.preferences.jobs;
        self.message.setText(tr("Saving launcher choice…", "Starter-Auswahl wird gespeichert…"));
        self.sensitivity();
    }
    pub fn report(self: *View, alloc: std.mem.Allocator, root: *gtk.Widget) ![]const @import("running_apps.zig").ProbeRow {
        const Row = @import("running_apps.zig").ProbeRow;
        var result: std.ArrayList(Row) = .empty;
        for (self.rows.items, 0..) |id, i| {
            const widget = self.list.getRowAtIndex(@intCast(i)).?.as(gtk.Widget);
            try result.append(alloc, probeRow(id, "launcher", widget, root));
        }
        try result.append(alloc, probeRow("apply", "button", self.apply_button.as(gtk.Widget), root));
        try result.append(alloc, probeRow("reset", "button", self.reset_button.as(gtk.Widget), root));
        return result.toOwnedSlice(alloc);
    }
    fn probeRow(id: []const u8, kind: []const u8, widget: *gtk.Widget, root: *gtk.Widget) @import("running_apps.zig").ProbeRow {
        var x: f64 = 0;
        var y: f64 = 0;
        _ = widget.translateCoordinates(root, 0, 0, &x, &y);
        return .{ .id = id, .kind = kind, .rect = .{ .x = x, .y = y, .width = widget.getWidth(), .height = widget.getHeight() }, .enabled = widget.getSensitive() != 0, .focused = widget.hasFocus() != 0 };
    }
};
