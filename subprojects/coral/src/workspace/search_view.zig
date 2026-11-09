//! Native, virtualized search picker/panel. Row identities live outside widgets.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const explorer = @import("explorer.zig");
const search = @import("search.zig");

pub const View = struct {
    panel: u.W,
    entry: u.W,
    title: u.W,
    status: u.W,
    list: explorer.View,
    refresh_button: u.W,
    close_button: u.W,
    keys: *c.GtkEventController = undefined,
    rows: std.ArrayList(?usize) = .empty,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    activate: *const fn (*anyopaque, usize) void,
    refresh: *const fn (*anyopaque) void,
    close: *const fn (*anyopaque) void,
    quiet: bool = false,

    pub fn init(parent: u.W, context: *anyopaque, changed: *const fn (*anyopaque) void, activate: *const fn (*anyopaque, usize) void, refresh: *const fn (*anyopaque) void, close: *const fn (*anyopaque) void) View {
        const panel = u.box(false, 4);
        u.margin(panel, 6);
        c.gtk_widget_set_vexpand(panel, 1);
        const title = u.label("Workspace search");
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, title), 1);
        u.append(panel, title);
        const bar = u.box(true, 4);
        u.append(panel, bar);
        const entry = c.gtk_entry_new().?;
        c.gtk_entry_set_max_length(u.cast(c.GtkEntry, entry), 1024);
        c.gtk_widget_set_hexpand(entry, 1);
        c.gtk_editable_set_width_chars(u.cast(c.GtkEditable, entry), 6);
        c.gtk_accessible_update_property(u.cast(c.GtkAccessible, entry), @as(c_int, c.GTK_ACCESSIBLE_PROPERTY_LABEL), @as([*:0]const u8, "Workspace search query"), @as(c_int, -1));
        u.append(bar, entry);
        const refresh_button = u.icon("view-refresh-symbolic", "Refresh shared search results");
        u.append(bar, refresh_button);
        const close_button = u.icon("window-close-symbolic", "Close search · Escape");
        u.append(bar, close_button);

        const status = u.label("Open a workspace to search.");
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, status), c.PANGO_ELLIPSIZE_END);
        u.append(panel, status);
        const list = explorer.View.init();
        c.gtk_list_view_set_single_click_activate(u.cast(c.GtkListView, list.widget), 0);
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_scrolled_window_set_policy(u.cast(c.GtkScrolledWindow, scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), list.widget);
        c.gtk_widget_set_vexpand(scroll, 1);
        c.gtk_scrolled_window_set_min_content_height(u.cast(c.GtkScrolledWindow, scroll), 40);
        u.append(panel, scroll);
        u.append(parent, panel);
        c.gtk_widget_set_visible(panel, 0);
        return .{ .panel = panel, .entry = entry, .title = title, .status = status, .list = list, .refresh_button = refresh_button, .close_button = close_button, .context = context, .changed = changed, .activate = activate, .refresh = refresh, .close = close };
    }
    // Called after the containing controller has reached its stable address.
    pub fn attach(self: *View) void {
        self.list.connect();
        u.connect(self.refresh_button, "clicked", &refreshClicked, self);
        u.connect(self.close_button, "clicked", &closeClicked, self);
        u.connect(self.entry, "changed", &queryChanged, self);
        u.connect(self.entry, "activate", &entryActivated, self);
        u.connect(self.list.widget, "activate", &rowActivated, self);
        self.keys = c.gtk_event_controller_key_new().?;
        c.gtk_event_controller_set_propagation_phase(self.keys, c.GTK_PHASE_BUBBLE);
        u.connect(self.keys, "key-pressed", &keyPressed, self);
        c.gtk_widget_add_controller(self.entry, self.keys);
        const list_keys = c.gtk_event_controller_key_new().?;
        c.gtk_event_controller_set_propagation_phase(list_keys, c.GTK_PHASE_BUBBLE);
        u.connect(list_keys, "key-pressed", &keyPressed, self);
        c.gtk_widget_add_controller(self.list.widget, list_keys);
    }
    pub fn deinit(self: *View) void {
        self.rows.deinit(a);
    }
    pub fn setMode(self: *View, mode: search.Mode) void {
        u.setLabel(self.title, if (mode == .quick_open) "Quick Open · query/results shared with Search" else "Text search · query/results shared with Quick Open");
    }
    pub fn show(self: *View, mode: search.Mode) void {
        self.setMode(mode);
        c.gtk_widget_set_visible(self.panel, 1);
        _ = c.gtk_widget_grab_focus(self.entry);
    }
    pub fn setQuery(self: *View, text: []const u8) void {
        self.quiet = true;
        defer self.quiet = false;
        const z = u.z(text);
        defer a.free(z);
        c.gtk_editable_set_text(u.cast(c.GtkEditable, self.entry), z);
    }
    pub fn clear(self: *View) void {
        self.list.clear();
        self.rows.clearRetainingCapacity();
    }
    pub fn append(self: *View, text: []const u8, index: ?usize) void {
        const z = u.z(text);
        defer a.free(z);
        self.rows.append(a, index) catch unreachable;
        self.list.append(z);
    }
    pub fn selectFirst(self: *View) void {
        for (self.rows.items, 0..) |index, row| if (index != null) {
            c.gtk_single_selection_set_selected(self.list.selection, @intCast(row));
            return;
        };
    }
    pub fn selected(self: *View) ?usize {
        const row = c.gtk_single_selection_get_selected(self.list.selection);
        if (row >= self.rows.items.len) return null;
        return self.rows.items[row];
    }
    fn move(self: *View, backward: bool) void {
        if (self.rows.items.len == 0) return;
        const position = c.gtk_single_selection_get_selected(self.list.selection);
        var row: usize = if (position < self.rows.items.len) position else if (backward) 0 else self.rows.items.len - 1;
        for (0..self.rows.items.len) |_| {
            row = if (backward) (row + self.rows.items.len - 1) % self.rows.items.len else (row + 1) % self.rows.items.len;
            if (self.rows.items[row] != null) {
                c.gtk_single_selection_set_selected(self.list.selection, @intCast(row));
                c.gtk_list_view_scroll_to(u.cast(c.GtkListView, self.list.widget), @intCast(row), c.GTK_LIST_SCROLL_NONE, null);
                return;
            }
        }
    }
};
fn queryChanged(_: ?*c.GtkEditable, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(View, data.?);
    if (!self.quiet) self.changed(self.context);
}
fn entryActivated(_: ?*c.GtkEntry, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(View, data.?);
    if (self.selected()) |index| self.activate(self.context, index);
}
fn rowActivated(_: ?*c.GtkListView, row: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(View, data.?);
    if (row < self.rows.items.len) if (self.rows.items[row]) |index| self.activate(self.context, index);
}
fn refreshClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(View, data.?);
    self.refresh(self.context);
}
fn closeClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(View, data.?);
    self.close(self.context);
}
fn keyPressed(_: ?*c.GtkEventControllerKey, key: c_uint, _: c_uint, state: c.GdkModifierType, data: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(View, data.?);
    if (state & (c.GDK_CONTROL_MASK | c.GDK_ALT_MASK | c.GDK_SUPER_MASK) != 0) return 0;
    switch (key) {
        c.GDK_KEY_Down, c.GDK_KEY_Up => self.move(key == c.GDK_KEY_Up),
        c.GDK_KEY_Escape => self.close(self.context),
        else => return 0,
    }
    return 1;
}
