const std = @import("std");
const u = @import("widgets.zig");
const c = u.c;
const m = @import("../core/model.zig");
const Service = @import("../platform/services.zig").Service;
pub const Row = struct {
    process: m.Process = .{},
    service: Service = .{},
    is_service: bool = false,
    labels: [6]?u.W = @splat(null),
    seen: bool = false,
    pub fn text(self: *const Row, column: usize, per_core: bool, cores: usize) m.Text(512) {
        const io = @import("../platform/io.zig");
        if (self.is_service) return switch (column) {
            0 => m.Text(512).init(self.service.name.slice()),
            1 => m.Text(512).init(self.service.state.slice()),
            2 => m.Text(512).init(self.service.substate.slice()),
            3 => m.Text(512).init(self.service.description.slice()),
            else => .{},
        };
        const p = self.process;
        const formatted = switch (column) {
            0 => if (p.members > 1) io.path("{s} ({d})", .{ p.name.slice(), p.members }) else io.path("{s}", .{p.name.slice()}),
            1 => io.path("{d}", .{p.id.pid}),
            2 => if (p.cpu) |v| io.path("{d:.1}%", .{v * (if (per_core) @as(f64, @floatFromInt(cores)) else 1)}) else io.path("—", .{}),
            3 => io.path("{s}", .{u.bytes(@floatFromInt(p.rss)).slice()}),
            4 => if (p.read_rate) |v| io.path("{s}/s", .{u.bytes(v).slice()}) else io.path("—", .{}),
            5 => if (p.write_rate) |v| io.path("{s}/s", .{u.bytes(v).slice()}) else io.path("—", .{}),
            else => io.path("", .{}),
        };
        return m.Text(512).init(formatted.slice());
    }
};
pub const Table = struct {
    view: u.W,
    store: *c.GListStore,
    filter: *c.GtkCustomFilter,
    filtered: *c.GtkFilterListModel,
    sorted: *c.GtkSortListModel,
    selection: *c.GtkSingleSelection,
    columns: [6]Column = undefined,
    count: usize = 6,
    services: bool = false,
    query: m.Text(256) = .{},
    mine: bool = false,
    grouped: bool = false,
    rows: std.AutoHashMap(u64, *c.GObject),
    context: ?*anyopaque = null,
    changed: *const fn (?*anyopaque) void,
    pending: std.ArrayList(*c.GObject) = .empty,
    column_mask: u32 = 63,
    syncing: bool = false,
    per_core: bool = false,
    cores: usize = 1,
    realized: usize = 0,
    const Column = struct { owner: *Table, index: usize, widget: ?*c.GtkColumnViewColumn = null };
    pub fn create(services: bool, context: ?*anyopaque, changed: *const fn (?*anyopaque) void) *Table {
        const self = u.a.create(Table) catch unreachable;
        const store = c.g_list_store_new(c.g_object_get_type()).?;
        const filter = c.gtk_custom_filter_new(matches, self, null).?;
        const filtered = c.gtk_filter_list_model_new(@ptrCast(@alignCast(c.g_object_ref(store))), @ptrCast(@alignCast(c.g_object_ref(filter)))).?;
        const sorted = c.gtk_sort_list_model_new(@ptrCast(@alignCast(c.g_object_ref(filtered))), null).?;
        const selection = c.gtk_single_selection_new(@ptrCast(@alignCast(c.g_object_ref(sorted)))).?;
        c.gtk_single_selection_set_autoselect(selection, 0);
        c.gtk_single_selection_set_can_unselect(selection, 1);
        const view = c.gtk_column_view_new(@ptrCast(@alignCast(c.g_object_ref(selection)))).?;
        _ = c.g_object_ref_sink(view);
        self.* = .{ .view = view, .store = store, .filter = filter, .filtered = filtered, .sorted = sorted, .selection = selection, .services = services, .count = if (services) 4 else 6, .rows = .init(u.a), .context = context, .changed = changed };
        c.gtk_column_view_set_show_row_separators(u.cast(c.GtkColumnView, view), 1);
        const titles = if (services) [_][*:0]const u8{ "Service", "State", "Substate", "Description", "", "" } else [_][*:0]const u8{ "Name", "PID", "CPU", "Memory", "Read/s", "Write/s" };
        for (0..self.count) |i| {
            self.columns[i] = .{ .owner = self, .index = i };
            const col = &self.columns[i];
            const factory = c.gtk_signal_list_item_factory_new().?;
            u.connect(factory, "setup", &setup, col);
            u.connect(factory, "bind", &bind, col);
            u.connect(factory, "unbind", &unbind, col);
            const column = c.gtk_column_view_column_new(titles[i], factory).?;
            col.widget = column;
            const sorter = c.gtk_custom_sorter_new(compare, col, null).?;
            c.gtk_column_view_column_set_sorter(column, @ptrCast(@alignCast(sorter)));
            c.g_object_unref(sorter);
            c.gtk_column_view_column_set_resizable(column, 1);
            c.gtk_column_view_column_set_expand(column, @intFromBool(i == 0 or (services and i == 3)));
            if (i == 0) c.gtk_column_view_column_set_fixed_width(column, 180);
            c.gtk_column_view_append_column(u.cast(c.GtkColumnView, view), column);
            c.g_object_unref(column);
        }
        c.gtk_sort_list_model_set_sorter(sorted, c.gtk_column_view_get_sorter(u.cast(c.GtkColumnView, view)));
        c.gtk_column_view_sort_by_column(u.cast(c.GtkColumnView, view), self.columns[if (services) 0 else 2].widget, if (services) c.GTK_SORT_ASCENDING else c.GTK_SORT_DESCENDING);
        u.connect(selection, "notify::selected-item", &selectedChanged, self);
        return self;
    }
    pub fn destroy(self: *Table) void {
        self.syncing = true;
        c.g_object_unref(self.view);
        c.g_object_unref(self.selection);
        c.g_object_unref(self.sorted);
        c.g_object_unref(self.filtered);
        c.g_object_unref(self.filter);
        c.g_object_unref(self.store);
        self.rows.deinit();
        self.pending.deinit(u.a);
        u.a.destroy(self);
    }
    fn row(object: anytype) *Row {
        return u.cast(Row, c.g_object_get_data(@ptrCast(@alignCast(object)), "dome-row"));
    }
    pub fn selected(self: *Table) ?*Row {
        return if (c.gtk_single_selection_get_selected_item(self.selection)) |obj| row(obj) else null;
    }
    fn selectedChanged(_: ?*c.GObject, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Table, data);
        if (!self.syncing) self.changed(self.context);
    }
    fn setup(_: ?*c.GtkSignalListItemFactory, item: ?*c.GtkListItem, data: ?*anyopaque) callconv(.c) void {
        const col = u.cast(Column, data);
        const label = u.label("", null);
        u.ellipsize(label);
        c.gtk_label_set_xalign(u.cast(c.GtkLabel, label), if (col.index == 0 or col.owner.services) 0 else 1);
        c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, label), if (col.index == 0) 30 else if (col.owner.services) 40 else 14);
        c.gtk_list_item_set_child(item, label);
    }
    fn bind(_: ?*c.GtkSignalListItemFactory, item: ?*c.GtkListItem, data: ?*anyopaque) callconv(.c) void {
        const col = u.cast(Column, data);
        const object = c.gtk_list_item_get_item(item) orelse return;
        const r = row(object);
        const label = c.gtk_list_item_get_child(item).?;
        r.labels[col.index] = label;
        const value = r.text(col.index, col.owner.per_core, col.owner.cores);
        u.setLabel(label, value.slice());
        c.gtk_widget_set_tooltip_text(label, value.z());
        col.owner.realized += 1;
    }
    fn unbind(_: ?*c.GtkSignalListItemFactory, item: ?*c.GtkListItem, data: ?*anyopaque) callconv(.c) void {
        const col = u.cast(Column, data);
        const object = c.gtk_list_item_get_item(item) orelse return;
        const r = row(object);
        if (r.labels[col.index] == c.gtk_list_item_get_child(item)) r.labels[col.index] = null;
        col.owner.realized -|= 1;
    }
    fn freeRow(data: ?*anyopaque) callconv(.c) void {
        u.a.destroy(u.cast(Row, data));
    }
    fn matches(object: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
        const self = u.cast(Table, data);
        const r = row(object);
        if (!self.services and self.mine and r.process.uid != c.getuid()) return 0;
        if (self.query.len == 0) return 1;
        const text = if (self.services) u.fmt("{s} {s} {s}", .{ r.service.name.slice(), r.service.description.slice(), r.service.state.slice() }) else u.fmt("{s} {d} {d} {s}", .{ r.process.name.slice(), r.process.id.pid, r.process.uid, r.process.group.slice() });
        defer u.a.free(text);
        const folded = c.g_utf8_casefold(text, -1);
        defer c.g_free(folded);
        const query = c.g_utf8_casefold(self.query.z(), -1);
        defer c.g_free(query);
        return @intFromBool(std.mem.indexOf(u8, std.mem.span(folded), std.mem.span(query)) != null);
    }
    fn compare(left: ?*const anyopaque, right: ?*const anyopaque, data: ?*anyopaque) callconv(.c) c_int {
        const col = u.cast(Column, data);
        const x = row(@constCast(left));
        const y = row(@constCast(right));
        if (col.owner.services) {
            const l = x.text(col.index, false, 1);
            const r = y.text(col.index, false, 1);
            return switch (std.mem.order(u8, l.slice(), r.slice())) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
        }
        const l = x.process;
        const r = y.process;
        if (col.index == 0) return switch (std.mem.order(u8, l.name.slice(), r.name.slice())) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
        const lv: f64 = switch (col.index) {
            1 => @floatFromInt(l.id.pid),
            2 => l.cpu orelse -1,
            3 => @floatFromInt(l.rss),
            4 => l.read_rate orelse -1,
            5 => l.write_rate orelse -1,
            else => 0,
        };
        const rv: f64 = switch (col.index) {
            1 => @floatFromInt(r.id.pid),
            2 => r.cpu orelse -1,
            3 => @floatFromInt(r.rss),
            4 => r.read_rate orelse -1,
            5 => r.write_rate orelse -1,
            else => 0,
        };
        return if (lv < rv) -1 else if (lv > rv) 1 else if (l.id.pid < r.id.pid) -1 else if (l.id.pid > r.id.pid) 1 else 0;
    }
    pub fn filterChanged(self: *Table) void {
        c.gtk_filter_changed(@ptrCast(@alignCast(self.filter)), c.GTK_FILTER_CHANGE_DIFFERENT);
    }
    fn key(p: m.Process) u64 {
        if (p.is_group) return std.hash.Wyhash.hash(0x646f6d65, p.group.slice());
        return std.hash.Wyhash.hash(@as(u64, @intCast(p.id.pid)), std.mem.asBytes(&p.id.start));
    }
    fn upsert(self: *Table, k: u64, p: ?m.Process, s: ?Service) void {
        const entry = self.rows.getOrPut(k) catch unreachable;
        if (!entry.found_existing) {
            const obj = c.g_object_new(c.g_object_get_type(), @as(?[*:0]const u8, null)).?;
            const r = u.a.create(Row) catch unreachable;
            r.* = .{ .is_service = self.services };
            c.g_object_set_data_full(@ptrCast(@alignCast(obj)), "dome-row", r, freeRow);
            entry.value_ptr.* = @ptrCast(@alignCast(obj));
            self.pending.append(u.a, @ptrCast(@alignCast(obj))) catch unreachable;
        }
        const r = row(entry.value_ptr.*);
        if (p) |process| r.process = process;
        if (s) |service| r.service = service;
        r.seen = true;
        for (r.labels, 0..) |label, i| if (label) |widget| {
            const value = r.text(i, self.per_core, self.cores);
            u.setLabel(widget, value.slice());
            c.gtk_widget_set_tooltip_text(widget, value.z());
        };
    }
    fn begin(self: *Table) ?u64 {
        self.syncing = true;
        const selected_key = if (self.selected()) |r| if (self.services) std.hash.Wyhash.hash(0, r.service.name.slice()) else key(r.process) else null;
        var it = self.rows.valueIterator();
        while (it.next()) |obj| row(obj.*).seen = false;
        return selected_key;
    }
    fn end(self: *Table, selected_key: ?u64) void {
        if (self.pending.items.len > 0) {
            c.g_list_store_splice(self.store, c.g_list_model_get_n_items(@ptrCast(self.store)), 0, @ptrCast(self.pending.items.ptr), @intCast(self.pending.items.len));
            for (self.pending.items) |object| c.g_object_unref(object);
            self.pending.clearRetainingCapacity();
        }
        var pos = c.g_list_model_get_n_items(@ptrCast(@alignCast(self.store)));
        while (pos > 0) {
            pos -= 1;
            const obj = c.g_list_model_get_item(@ptrCast(@alignCast(self.store)), pos).?;
            defer c.g_object_unref(obj);
            const r = row(obj);
            if (!r.seen) {
                const k = if (self.services) std.hash.Wyhash.hash(0, r.service.name.slice()) else key(r.process);
                _ = self.rows.remove(k);
                c.g_list_store_remove(self.store, pos);
            }
        }
        self.filterChanged();
        c.gtk_sorter_changed(c.gtk_column_view_get_sorter(u.cast(c.GtkColumnView, self.view)), c.GTK_SORTER_CHANGE_DIFFERENT);
        if (selected_key) |k| {
            const wanted = self.rows.get(k);
            const n = c.g_list_model_get_n_items(@ptrCast(@alignCast(self.sorted)));
            var found = false;
            if (wanted) |obj| {
                for (0..n) |i| {
                    const candidate = c.g_list_model_get_item(@ptrCast(@alignCast(self.sorted)), @intCast(i)).?;
                    defer c.g_object_unref(candidate);
                    if (@intFromPtr(candidate) == @intFromPtr(obj)) {
                        c.gtk_single_selection_set_selected(self.selection, @intCast(i));
                        found = true;
                        break;
                    }
                }
            }
            if (!found) c.gtk_single_selection_set_selected(self.selection, c.GTK_INVALID_LIST_POSITION);
        }
        self.syncing = false;
    }
    pub fn updateProcesses(self: *Table, processes: []const m.Process) void {
        const selected_key = self.begin();
        if (self.grouped) {
            var arena = std.heap.ArenaAllocator.init(u.a);
            defer arena.deinit();
            const a = arena.allocator();
            var groups: std.StringHashMap(m.Process) = .init(a);
            for (processes) |p| {
                if (p.group.len == 0) {
                    self.upsert(key(p), p, null);
                    continue;
                }
                const entry = groups.getOrPut(p.group.slice()) catch unreachable;
                if (!entry.found_existing) {
                    entry.key_ptr.* = a.dupe(u8, p.group.slice()) catch unreachable;
                    entry.value_ptr.* = p;
                    entry.value_ptr.is_group = true;
                    entry.value_ptr.name.set(std.fs.path.basename(p.group.slice()));
                } else {
                    const g = entry.value_ptr;
                    g.members += 1;
                    g.rss +|= p.rss;
                    g.threads +|= p.threads;
                    g.cpu = if (g.cpu != null and p.cpu != null) g.cpu.? + p.cpu.? else null;
                    g.read_rate = if (g.read_rate != null and p.read_rate != null) g.read_rate.? + p.read_rate.? else null;
                    g.write_rate = if (g.write_rate != null and p.write_rate != null) g.write_rate.? + p.write_rate.? else null;
                    if (p.id.pid < g.id.pid) g.id = p.id;
                }
            }
            var it = groups.valueIterator();
            while (it.next()) |p| self.upsert(key(p.*), p.*, null);
        } else for (processes) |p| self.upsert(key(p), p, null);
        self.end(selected_key);
    }
    pub fn updateServices(self: *Table, services: []const Service) void {
        const selected_key = self.begin();
        for (services) |s| self.upsert(std.hash.Wyhash.hash(0, s.name.slice()), null, s);
        self.end(selected_key);
    }
    pub fn selectIdentity(self: *Table, id: m.Identity) void {
        const n = self.countVisible();
        for (0..n) |i| {
            const object = c.g_list_model_get_item(@ptrCast(self.sorted), @intCast(i)).?;
            defer c.g_object_unref(object);
            if (row(object).process.id.eql(id)) {
                c.gtk_single_selection_set_selected(self.selection, @intCast(i));
                return;
            }
        }
    }
    pub fn countVisible(self: *Table) u32 {
        return c.g_list_model_get_n_items(@ptrCast(@alignCast(self.sorted)));
    }
    pub fn narrow(self: *Table, narrow_view: bool) void {
        if (!self.services) for (0..6) |i| c.gtk_column_view_column_set_visible(self.columns[i].widget, @intFromBool((!narrow_view or i == 0 or i == 2) and (self.column_mask & (@as(u32, 1) << @intCast(i)) != 0)));
    }
};
