//! App-owned notebook groups. IDs are session-local and never recycled.
const std = @import("std");
const u = @import("c.zig");
const c = u.c;
pub const Group = struct {
    id: u64,
    notebook: u.W,
    chrome: @import("workbench/chrome.zig").GroupChrome,
};
pub const Groups = struct {
    root: u.W,
    items: std.ArrayList(Group) = .empty,
    next_id: u64 = 1,

    pub fn init() Groups {
        const root = u.box(true, 6);
        c.gtk_box_set_homogeneous(u.cast(c.GtkBox, root), 1);
        c.gtk_widget_set_vexpand(root, 1);
        return .{ .root = root };
    }
    pub fn add(self: *Groups) !Group {
        try self.items.ensureUnusedCapacity(u.a, 1);
        const id = self.next_id;
        self.next_id = try std.math.add(u64, id, 1);
        const notebook = c.gtk_notebook_new().?;
        _ = c.g_object_ref_sink(notebook);
        c.gtk_notebook_set_scrollable(u.cast(c.GtkNotebook, notebook), 1);
        c.gtk_widget_set_hexpand(notebook, 1);
        c.gtk_widget_set_vexpand(notebook, 1);
        const group = Group{ .id = id, .notebook = notebook, .chrome = .init(notebook) };
        self.items.appendAssumeCapacity(group);
        u.append(self.root, group.chrome.root);
        return group;
    }
    pub fn get(self: *const Groups, id: u64) ?Group {
        for (self.items.items) |group| if (group.id == id) return group;
        return null;
    }
    pub fn forPage(self: *const Groups, page: u.W) ?Group {
        for (self.items.items) |group| if (c.gtk_notebook_page_num(u.cast(c.GtkNotebook, group.notebook), page) >= 0) return group;
        return null;
    }
    pub fn remove(self: *Groups, id: u64) void {
        for (self.items.items, 0..) |group, index| {
            if (group.id != id) continue;
            std.debug.assert(c.gtk_notebook_get_n_pages(u.cast(c.GtkNotebook, group.notebook)) == 0);
            c.gtk_box_remove(u.cast(c.GtkBox, self.root), group.chrome.root);
            c.g_object_unref(group.notebook);
            _ = self.items.orderedRemove(index);
            return;
        }
    }
    pub fn deinit(self: *Groups) void {
        for (self.items.items) |group| c.g_object_unref(group.notebook);
        self.items.deinit(u.a);
    }
};

/// Snapshot offsets are GTK characters, except excerpt_start/end (UTF-8 bytes).
/// group and document IDs must be mapped to fresh IDs during restore.
pub const ViewState = struct {
    id: u64,
    document_id: u64,
    group_id: u64,
    page: c_int,
    active: bool,
    selected: bool,
    insertion: c_int,
    bound: c_int,
    scroll_x: f64,
    scroll_y: f64,
    excerpt_start: ?usize = null,
    excerpt_end: ?usize = null,
};
pub const GroupState = struct { id: u64, active: bool };
