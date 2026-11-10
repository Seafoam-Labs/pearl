//! GTK-main-thread-only picker for owner-supplied project/window/buffer snapshots.
//! No application, storage, or live document pointers are retained. IDs must be
//! unique within a snapshot; the owner must revalidate them when dispatching.
//!
//! Assign the returned pointer before show(); style its public window externally.
//! on_closed runs exactly once, after modality is released/window destruction,
//! and must synchronously clear the owner's pointer and optionally restore focus.
//! close() frees Picker; never use it afterwards. Reentrant close in on_closed
//! is safe and cancels pending activation. If on_closed frees the context, it
//! must first reenter close() or destroy the parent to cancel dispatch.
//! Activation frees Picker BEFORE on_activate, which may reopen or free the owner.
//! Close before freeing the callback context or tearing down the parent.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const i18n = @import("i18n");

pub const max_items = 512;
pub const max_visible = 50;
pub const Item = struct {
    id: usize,
    label: []const u8,
    /// Full project path, or buffer group/path qualifier; rendered without markup.
    detail: []const u8,
    dirty: bool = false,
    unavailable: bool = false,
};
pub const OnActivate = *const fn (context: *anyopaque, id: usize) void;
pub const OnClosed = *const fn (context: *anyopaque) void;

const OwnedItem = struct {
    id: usize,
    label: [:0]const u8,
    detail: [:0]const u8,
    folded_label: [:0]const u8,
    folded_detail: [:0]const u8,
    dirty: bool,
    unavailable: bool,
};
const Row = struct {
    widget: *c.GtkListBoxRow,
    label: u.W,
    detail: u.W,
    status: u.W,
};

pub const Picker = struct {
    window: u.W,
    entry: u.W,
    list: u.W,
    empty: u.W,
    scroll: u.W,
    keys: *c.GtkEventController,
    parent: u.W,
    more: u.W,
    arena: std.heap.ArenaAllocator,
    items: []const OwnedItem,
    rows: [max_visible]Row = undefined,
    row_count: usize,
    visible: [max_visible]usize = undefined,
    visible_count: usize = 0,
    match_count: usize = 0,
    context: *anyopaque,
    on_activate: OnActivate,
    on_closed: OnClosed,
    closing: bool = false,
    pending: ?usize = null,

    /// Copies all input text. Rejects >512 entries, duplicate IDs, invalid UTF-8
    /// and embedded NULs instead of silently truncating or misrouting activation.
    /// All fallible snapshot allocations precede GTK creation/signal hookup.
    pub fn create(parent: u.W, context: *anyopaque, title: []const u8, empty_text: []const u8, items: []const Item, on_activate: OnActivate, on_closed: OnClosed) !*Picker {
        if (items.len > max_items) return error.TooManyItems;
        var arena = std.heap.ArenaAllocator.init(u.a);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned_title = try copyText(a, title);
        const owned_empty = try copyText(a, empty_text);
        const owned = try a.alloc(OwnedItem, items.len);
        for (items, 0..) |item, index| {
            for (items[0..index]) |previous| if (previous.id == item.id) return error.DuplicateId;
            const label = try copyText(a, item.label);
            const detail = try copyText(a, item.detail);
            owned[index] = .{
                .id = item.id,
                .label = label,
                .detail = detail,
                .folded_label = try foldText(a, label),
                .folded_detail = try foldText(a, detail),
                .dirty = item.dirty,
                .unavailable = item.unavailable,
            };
        }
        const self = try u.a.create(Picker);
        const window = c.gtk_window_new().?;
        const win = u.cast(c.GtkWindow, window);
        c.gtk_window_set_title(win, owned_title.ptr);
        c.gtk_window_set_transient_for(win, u.cast(c.GtkWindow, parent));
        c.gtk_window_set_destroy_with_parent(win, 1);
        c.gtk_window_set_modal(win, 1);
        c.gtk_window_set_default_size(win, 620, 480);
        c.gtk_widget_add_css_class(window, "coral");
        const root = u.box(false, 8);
        u.margin(root, 12);
        c.gtk_window_set_child(win, root);
        const entry = c.gtk_search_entry_new().?;
        accessibleLabel(entry, i18n.dtr("coral", "Filter items"));
        c.g_object_set(entry, "placeholder-text", @as([*:0]const u8, i18n.dtr("coral", "Filter items…")), @as(?*anyopaque, null));
        u.append(root, entry);
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_scrolled_window_set_policy(u.cast(c.GtkScrolledWindow, scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_widget_set_vexpand(scroll, 1);
        u.append(root, scroll);
        const list = c.gtk_list_box_new().?;
        c.gtk_list_box_set_selection_mode(u.cast(c.GtkListBox, list), c.GTK_SELECTION_SINGLE);
        c.gtk_list_box_set_activate_on_single_click(u.cast(c.GtkListBox, list), 1);
        accessibleLabel(list, owned_title);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), list);
        const empty = u.label(owned_empty);
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, empty), 1);
        u.margin(empty, 16);
        u.append(root, empty);
        const more = u.label(i18n.dtr("coral", "Showing the first 50 matches. Refine your filter to see more."));
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, more), 1);
        c.gtk_widget_add_css_class(more, "dim-label");
        u.append(root, more);
        const keys = c.gtk_event_controller_key_new().?;
        // Bubble so native entry/IME composition gets first refusal.
        c.gtk_event_controller_set_propagation_phase(keys, c.GTK_PHASE_BUBBLE);
        c.gtk_widget_add_controller(window, keys);
        self.* = .{
            .window = window,
            .entry = entry,
            .list = list,
            .empty = empty,
            .scroll = scroll,
            .keys = keys,
            .parent = parent,
            .more = more,
            .arena = arena,
            .items = owned,
            .row_count = @min(items.len, max_visible),
            .context = context,
            .on_activate = on_activate,
            .on_closed = on_closed,
        };
        for (self.rows[0..self.row_count]) |*row| {
            const widget = c.gtk_list_box_row_new().?;
            const content = u.box(false, 3);
            u.margin(content, 8);
            const heading = u.box(true, 12);
            const label = u.label("");
            c.gtk_widget_set_hexpand(label, 1);
            c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, label), c.PANGO_ELLIPSIZE_END);
            const status = u.label("");
            c.gtk_widget_add_css_class(status, "dim-label");
            u.append(heading, label);
            u.append(heading, status);
            u.append(content, heading);
            const detail = u.label("");
            // Wrap rather than hiding the distinguishing portion of a full path.
            c.gtk_label_set_wrap(u.cast(c.GtkLabel, detail), 1);
            c.gtk_label_set_wrap_mode(u.cast(c.GtkLabel, detail), c.PANGO_WRAP_WORD_CHAR);
            c.gtk_widget_add_css_class(detail, "dim-label");
            u.append(content, detail);
            row.* = .{ .widget = u.cast(c.GtkListBoxRow, widget), .label = label, .detail = detail, .status = status };
            c.gtk_list_box_row_set_child(row.widget, content);
            c.gtk_list_box_append(u.cast(c.GtkListBox, list), widget);
        }
        self.refilter();
        u.connect(entry, "changed", &changed, self);
        u.connect(entry, "activate", &activated, self);
        u.connect(entry, "stop-search", &stopSearch, self);
        u.connect(list, "row-activated", &rowActivated, self);
        u.connect(keys, "key-pressed", &keyPressed, self);
        u.connect(window, "close-request", &closeRequested, self);
        u.connect(window, "unrealize", &windowGone, self);
        u.connect(window, "destroy", &windowGone, self);
        u.connect(parent, "unrealize", &parentGone, self);
        u.connect(parent, "destroy", &parentGone, self);
        return self;
    }

    pub fn show(self: *Picker) void {
        if (self.closing) return;
        c.gtk_window_present(u.cast(c.GtkWindow, self.window));
        _ = c.gtk_widget_grab_focus(self.entry);
    }

    /// Synchronous cancellation and on_closed notification. Invalidates self.
    pub fn close(self: *Picker) void {
        self.finish(null, true);
    }

    pub fn setFilter(self: *Picker, text: []const u8) !void {
        if (self.closing) return;
        const value = try copyText(u.a, text);
        defer u.a.free(value);
        c.gtk_editable_set_text(u.cast(c.GtkEditable, self.entry), value.ptr);
    }

    /// Borrowed until the next entry edit or close.
    pub fn query(self: *const Picker) []const u8 {
        return u.entryText(self.entry);
    }

    /// Total matches, including those beyond the bounded displayed prefix.
    pub fn matchCount(self: *const Picker) usize {
        return self.match_count;
    }

    pub fn visibleCount(self: *const Picker) usize {
        return self.visible_count;
    }

    pub fn visibleId(self: *const Picker, index: usize) ?usize {
        if (index >= self.visible_count) return null;
        return self.items[self.visible[index]].id;
    }

    pub fn selectedId(self: *const Picker) ?usize {
        const index = self.selectedIndex() orelse return null;
        return self.visibleId(index);
    }

    /// Select a displayed stable ID. null clears selection; an absent ID leaves
    /// selection unchanged and returns false. Selection alone never activates.
    pub fn select(self: *Picker, id: ?usize) bool {
        if (self.closing) return false;
        if (id) |wanted| {
            for (0..self.visible_count) |index| {
                if (self.visibleId(index).? == wanted) {
                    c.gtk_list_box_select_row(u.cast(c.GtkListBox, self.list), self.rows[index].widget);
                    return true;
                }
            }
            return false;
        }
        c.gtk_list_box_unselect_all(u.cast(c.GtkListBox, self.list));
        return true;
    }

    /// No-op with no selection or an unavailable item; otherwise invalidates self.
    pub fn activate(self: *Picker) void {
        if (self.closing) return;
        const index = self.selectedIndex() orelse return;
        const item = self.items[self.visible[index]];
        if (item.unavailable) return;
        self.finish(item.id, true);
    }

    fn selectedIndex(self: *const Picker) ?usize {
        const row = c.gtk_list_box_get_selected_row(u.cast(c.GtkListBox, self.list)) orelse return null;
        const index = c.gtk_list_box_row_get_index(row);
        if (index < 0 or index >= self.visible_count) return null;
        return @intCast(index);
    }

    fn refilter(self: *Picker) void {
        if (self.closing) return;
        const folded = c.g_utf8_casefold(c.gtk_editable_get_text(u.cast(c.GtkEditable, self.entry)), -1);
        defer c.g_free(folded);
        const needle = std.mem.trim(u8, std.mem.span(folded), " \t\r\n");
        c.gtk_list_box_unselect_all(u.cast(c.GtkListBox, self.list));
        self.visible_count = 0;
        self.match_count = 0;
        for (self.items, 0..) |item, index| {
            if (std.mem.indexOf(u8, item.folded_label, needle) == null and
                std.mem.indexOf(u8, item.folded_detail, needle) == null) continue;
            self.match_count += 1;
            if (self.visible_count == max_visible) continue;
            self.visible[self.visible_count] = index;
            const row = self.rows[self.visible_count];
            self.visible_count += 1;
            c.gtk_label_set_text(u.cast(c.GtkLabel, row.label), item.label.ptr);
            c.gtk_label_set_text(u.cast(c.GtkLabel, row.detail), item.detail.ptr);
            const status = if (item.dirty and item.unavailable)
                i18n.dtr("coral", "Modified · Unavailable")
            else if (item.dirty)
                i18n.dtr("coral", "Modified")
            else if (item.unavailable)
                i18n.dtr("coral", "Unavailable")
            else
                "";
            c.gtk_label_set_text(u.cast(c.GtkLabel, row.status), status);
            c.gtk_widget_set_visible(row.status, @intFromBool(item.dirty or item.unavailable));
            c.gtk_list_box_row_set_activatable(row.widget, @intFromBool(!item.unavailable));
            // Keep full qualifiers and status in the accessible description.
            const description = u.fmt("{s}\n{s}", .{ item.detail, status });
            defer u.a.free(description);
            const widget = u.cast(c.GtkWidget, row.widget);
            accessibleLabel(widget, item.label);
            c.gtk_accessible_update_property(u.cast(c.GtkAccessible, widget), @as(c_int, c.GTK_ACCESSIBLE_PROPERTY_DESCRIPTION), description.ptr, @as(c_int, -1));
            c.gtk_widget_set_tooltip_text(widget, item.detail.ptr);
        }
        for (self.rows[0..self.row_count], 0..) |row, index| {
            c.gtk_widget_set_visible(u.cast(c.GtkWidget, row.widget), @intFromBool(index < self.visible_count));
        }
        c.gtk_list_box_select_row(u.cast(c.GtkListBox, self.list), if (self.visible_count != 0) self.rows[0].widget else null);
        c.gtk_widget_set_visible(self.empty, @intFromBool(self.visible_count == 0));
        c.gtk_widget_set_visible(self.scroll, @intFromBool(self.visible_count != 0));
        c.gtk_widget_set_visible(self.more, @intFromBool(self.match_count > max_visible));
        c.gtk_adjustment_set_value(c.gtk_scrolled_window_get_vadjustment(u.cast(c.GtkScrolledWindow, self.scroll)), 0);
    }

    fn move(self: *Picker, backwards: bool) void {
        if (self.closing or self.visible_count == 0) return;
        const current = self.selectedIndex();
        const next = if (current) |index|
            (index + (if (backwards) self.visible_count - 1 else @as(usize, 1))) % self.visible_count
        else if (backwards) self.visible_count - 1 else 0;
        c.gtk_list_box_select_row(u.cast(c.GtkListBox, self.list), self.rows[next].widget);
        _ = c.gtk_widget_grab_focus(u.cast(c.GtkWidget, self.rows[next].widget));
        _ = c.gtk_widget_grab_focus(self.entry);
    }

    fn finish(self: *Picker, id: ?usize, destroy_window: bool) void {
        if (self.closing) {
            self.pending = null;
            return;
        }
        self.closing = true;
        self.pending = id;
        // Retain through on_closed: the owner may disconnect its own callbacks
        // from the destroyed window, or destroy the parent to cancel dispatch.
        const parent = c.g_object_ref(self.parent).?;
        const window = c.g_object_ref(self.window).?;
        disconnect(self.entry, self);
        disconnect(self.list, self);
        disconnect(self.keys, self);
        disconnect(self.window, self);
        c.gtk_window_set_modal(u.cast(c.GtkWindow, self.window), 0);
        if (destroy_window) c.gtk_window_destroy(u.cast(c.GtkWindow, self.window));
        self.on_closed(self.context);
        disconnect(self.parent, self);
        c.g_object_unref(window);
        c.g_object_unref(parent);
        const pending = self.pending;
        const context = self.context;
        const callback = self.on_activate;
        self.arena.deinit();
        u.a.destroy(self);
        if (pending) |selected| callback(context, selected);
    }
};

fn copyText(a: std.mem.Allocator, text: []const u8) ![:0]const u8 {
    if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidText;
    return a.dupeSentinel(u8, text, 0);
}
fn foldText(a: std.mem.Allocator, text: [:0]const u8) ![:0]const u8 {
    const folded = c.g_utf8_casefold(text.ptr, -1);
    defer c.g_free(folded);
    return a.dupeSentinel(u8, std.mem.span(folded), 0);
}
fn accessibleLabel(widget: u.W, text: [:0]const u8) void {
    c.gtk_accessible_update_property(u.cast(c.GtkAccessible, widget), @as(c_int, c.GTK_ACCESSIBLE_PROPERTY_LABEL), text.ptr, @as(c_int, -1));
}
fn disconnect(object: anytype, self: *Picker) void {
    _ = c.g_signal_handlers_disconnect_matched(@ptrCast(object), c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
}
fn changed(_: ?*c.GtkEditable, data: ?*anyopaque) callconv(.c) void {
    u.cast(Picker, data.?).refilter();
}
fn activated(_: ?*c.GtkSearchEntry, data: ?*anyopaque) callconv(.c) void {
    u.cast(Picker, data.?).activate();
}
fn stopSearch(_: ?*c.GtkSearchEntry, data: ?*anyopaque) callconv(.c) void {
    u.cast(Picker, data.?).close();
}
fn rowActivated(_: ?*c.GtkListBox, row: ?*c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Picker, data.?);
    const selected = row orelse return;
    const index = c.gtk_list_box_row_get_index(selected);
    if (index < 0 or index >= self.visible_count) return;
    const n: usize = @intCast(index);
    if (self.rows[n].widget != selected) return;
    c.gtk_list_box_select_row(u.cast(c.GtkListBox, self.list), selected);
    self.activate();
}
fn closeRequested(_: ?*c.GtkWindow, data: ?*anyopaque) callconv(.c) c_int {
    u.cast(Picker, data.?).close();
    return 1;
}
fn windowGone(_: ?*c.GtkWidget, data: ?*anyopaque) callconv(.c) void {
    u.cast(Picker, data.?).finish(null, false);
}
fn parentGone(_: ?*c.GtkWidget, data: ?*anyopaque) callconv(.c) void {
    u.cast(Picker, data.?).close();
}
fn keyPressed(_: ?*c.GtkEventControllerKey, key: c_uint, _: c_uint, state: c.GdkModifierType, data: ?*anyopaque) callconv(.c) c_int {
    if (state & c.gtk_accelerator_get_default_mod_mask() != 0) return 0;
    const self = u.cast(Picker, data.?);
    switch (key) {
        c.GDK_KEY_Escape => self.close(),
        c.GDK_KEY_Up, c.GDK_KEY_KP_Up => self.move(true),
        c.GDK_KEY_Down, c.GDK_KEY_KP_Down => self.move(false),
        // Native entry/list activation handles Enter after IME processing.
        else => return 0,
    }
    return 1;
}
