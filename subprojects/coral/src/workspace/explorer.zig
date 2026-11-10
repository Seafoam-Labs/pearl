//! Bounded directory state, independent of recycled GTK row widgets.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const fs = @import("browser_fs.zig");
const RootId = @import("model.zig").RootId;
/// Immutable, shared policy storage outlives cancelled workers. Refcounts are
/// changed only by GTK admission/completion, never by workers.
pub const Policy = struct {
    refs: usize = 1,
    patterns: [][]const u8,
    pub fn create(patterns: []const []const u8) *Policy {
        const self = a.create(Policy) catch unreachable;
        self.* = .{ .patterns = a.alloc([]const u8, patterns.len) catch unreachable };
        for (patterns, 0..) |pattern, i| self.patterns[i] = u.z(pattern);
        return self;
    }
    pub fn ref(self: *Policy) *Policy {
        self.refs += 1;
        return self;
    }
    pub fn unref(self: *Policy) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        for (self.patterns) |pattern| a.free(pattern);
        a.free(self.patterns);
        a.destroy(self);
    }
};
pub const node_limit = 64;
pub const page_limit = 8;
pub const byte_limit = 1024 * 1024;
pub const Node = struct {
    root: RootId,
    relative: [:0]u8,
    expanded: bool = false,
    accessed: bool = false,
    generation: u64 = 0,
    busy: bool = false,
    queued: bool = false,
    navigate_pending: bool = false,
    first_event: i64 = 0,
    last_event: i64 = 0,
    page: ?fs.Page = null,
    continuation: ?fs.Continuation = null,
    complete: bool = false,
    offset: usize = 0,
    next_offset: usize = 0,
    stamp: u64 = 0,
    err: ?[]const u8 = null,
    pub fn clear(self: *Node) void {
        if (self.page) |*page| page.deinit();
        self.page = null;
    }
    pub fn invalidate(self: *Node) void {
        self.generation +%= 1;
        self.clear();
        self.continuation = null;
        self.complete = false;
        self.offset = 0;
        self.next_offset = 0;
        self.queued = self.accessed;
    }
};
pub const Row = struct { node: usize, entry: ?usize = null, more: bool = false };
pub const Tree = struct {
    nodes: std.ArrayList(Node) = .empty,
    rows: std.ArrayList(Row) = .empty,
    clock: u64 = 0,
    selected_root: ?RootId = null,
    selected_path: ?[:0]u8 = null,
    pub fn deinit(self: *Tree) void {
        for (self.nodes.items) |*node| {
            node.clear();
            a.free(node.relative);
        }
        self.nodes.deinit(a);
        self.rows.deinit(a);
        if (self.selected_path) |path| a.free(path);
        self.* = .{};
    }
    pub fn find(self: *const Tree, root: RootId, relative: []const u8) ?usize {
        for (self.nodes.items, 0..) |node, i| if (node.root == root and std.mem.eql(u8, node.relative, relative)) return i;
        return null;
    }
    pub fn ensure(self: *Tree, root: RootId, relative: []const u8) ?usize {
        if (self.find(root, relative)) |i| return i;
        if (self.nodes.items.len == node_limit or relative.len > 4096) return null;
        self.nodes.append(a, .{ .root = root, .relative = u.z(relative) }) catch unreachable;
        return self.nodes.items.len - 1;
    }
    pub fn select(self: *Tree, root: RootId, path: []const u8) void {
        const owned = u.z(path);
        if (self.selected_path) |old| a.free(old);
        self.selected_path = owned;
        self.selected_root = root;
    }
    pub fn bytes(self: *const Tree) usize {
        var total: usize = 0;
        for (self.nodes.items) |node| if (node.page) |page| {
            total += page.arena.queryCapacity();
        };
        return total;
    }
    pub fn pages(self: *const Tree) usize {
        var count: usize = 0;
        for (self.nodes.items) |node| {
            if (node.page != null) count += 1;
        }
        return count;
    }
    pub fn install(self: *Tree, index: usize, page: fs.Page) void {
        self.nodes.items[index].clear();
        while (self.pages() >= page_limit or self.bytes() + page.arena.queryCapacity() > byte_limit) {
            var oldest: ?usize = null;
            for (self.nodes.items, 0..) |node, i| if (node.page != null and (oldest == null or node.stamp < self.nodes.items[oldest.?].stamp)) {
                oldest = i;
            };
            if (oldest) |i| self.nodes.items[i].clear() else break;
        }
        self.clock += 1;
        const node = &self.nodes.items[index];
        node.page = page;
        node.stamp = self.clock;
        node.continuation = page.continuation;
        node.complete = page.complete;
        node.err = null;
    }
};

/// GtkStringList stores only bounded row descriptions; GtkListView's factory
/// creates/recycles the viewport widgets, never a widget for each filesystem entry.
pub const View = struct {
    widget: u.W,
    strings: *c.GtkStringList,
    selection: *c.GtkSingleSelection,
    live_widgets: usize = 0,
    peak_widgets: usize = 0,
    pub fn init() View {
        const strings = c.gtk_string_list_new(null).?;
        const selection = c.gtk_single_selection_new(u.cast(c.GListModel, strings)).?;
        c.gtk_single_selection_set_autoselect(selection, 0);
        c.gtk_single_selection_set_can_unselect(selection, 1);
        const factory = c.gtk_signal_list_item_factory_new().?;
        const widget = c.gtk_list_view_new(u.cast(c.GtkSelectionModel, selection), factory).?;
        c.gtk_widget_add_css_class(widget, "workspace-list");
        c.gtk_list_view_set_single_click_activate(u.cast(c.GtkListView, widget), 1);
        return .{ .widget = widget, .strings = strings, .selection = selection };
    }
    pub fn connect(self: *View) void {
        const factory = c.gtk_list_view_get_factory(u.cast(c.GtkListView, self.widget)).?;
        u.connect(factory, "setup", &setup, self);
        u.connect(factory, "bind", &bind, self);
        u.connect(factory, "teardown", &teardown, self);
    }
    pub fn clear(self: *View) void {
        c.gtk_string_list_splice(self.strings, 0, c.g_list_model_get_n_items(u.cast(c.GListModel, self.strings)), null);
    }
    pub fn append(self: *View, text: [:0]const u8) void {
        c.gtk_string_list_append(self.strings, text);
    }
};
fn setup(_: ?*c.GtkSignalListItemFactory, item: ?*c.GtkListItem, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(View, data.?);
    self.live_widgets += 1;
    self.peak_widgets = @max(self.live_widgets, self.peak_widgets);
    const label = u.label("");
    c.gtk_label_set_xalign(u.cast(c.GtkLabel, label), 0);
    c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, label), c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_widget_add_css_class(label, "workspace-row");
    c.gtk_list_item_set_child(item, label);
}
fn bind(_: ?*c.GtkSignalListItemFactory, item: ?*c.GtkListItem, _: ?*anyopaque) callconv(.c) void {
    const object = c.gtk_list_item_get_item(item).?;
    const label = c.gtk_list_item_get_child(item).?;
    const text = c.gtk_string_object_get_string(u.cast(c.GtkStringObject, object));
    c.gtk_label_set_text(u.cast(c.GtkLabel, label), text);
    c.gtk_widget_set_tooltip_text(label, text);
}
fn teardown(_: ?*c.GtkSignalListItemFactory, _: ?*c.GtkListItem, data: ?*anyopaque) callconv(.c) void {
    u.cast(View, data.?).live_widgets -= 1;
}
