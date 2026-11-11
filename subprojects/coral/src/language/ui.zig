//! Plain-text native dialogs. No server markup, HTML, or URI is executed here.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
pub const UI = struct {
    window: ?u.W = null,
    list: ?u.W = null,
    body: ?u.W = null,
    input: ?u.W = null,
    context: *anyopaque,
    respond: *const fn (*anyopaque, bool, ?usize, []const u8) void,
    pub fn close(self: *UI) void {
        self.list = null;
        self.body = null;
        self.input = null;
        if (self.window) |w| {
            self.window = null;
            _ = c.g_signal_handlers_disconnect_matched(w, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            c.gtk_window_destroy(u.cast(c.GtkWindow, w));
        }
    }
    pub fn show(self: *UI, app: *@import("../app.zig").App, title: [:0]const u8, body: []const u8, rows: []const []const u8, prompt: bool, accept: ?[:0]const u8) void {
        self.close();
        const w = c.gtk_dialog_new().?;
        self.window = w;
        c.gtk_window_set_title(u.cast(c.GtkWindow, w), title);
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, w), u.cast(c.GtkWindow, app.window));
        c.gtk_window_set_modal(u.cast(c.GtkWindow, w), 1);
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, w), 680, 460);
        const box = u.cast(c.GtkWidget, c.gtk_dialog_get_content_area(u.cast(c.GtkDialog, w)));
        u.margin(box, 12);
        const label = u.label(body);
        self.body = label;
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, label), 1);
        c.gtk_label_set_selectable(u.cast(c.GtkLabel, label), 1);
        c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, label), 90);
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_vexpand(scroll, 1);
        const content = u.box(false, 8);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), content);
        u.append(content, label);
        u.append(box, scroll);
        if (prompt or rows.len != 0) {
            const entry = c.gtk_entry_new().?;
            self.input = entry;
            u.append(box, entry);
            if (!prompt) {
                c.gtk_entry_set_placeholder_text(u.cast(c.GtkEntry, entry), "Filter results…");
                u.connect(entry, "changed", &filterChanged, self);
            }
        }
        if (rows.len != 0) {
            const list = c.gtk_list_box_new().?;
            self.list = list;
            c.gtk_list_box_set_selection_mode(u.cast(c.GtkListBox, list), c.GTK_SELECTION_SINGLE);
            for (rows) |text| {
                const row_label = u.label(text);
                c.gtk_label_set_wrap(u.cast(c.GtkLabel, row_label), 1);
                u.margin(row_label, 6);
                c.gtk_list_box_append(u.cast(c.GtkListBox, list), row_label);
            }
            c.gtk_list_box_set_filter_func(u.cast(c.GtkListBox, list), &filter, self, null);
            c.gtk_list_box_select_row(u.cast(c.GtkListBox, list), c.gtk_list_box_get_row_at_index(u.cast(c.GtkListBox, list), 0));
            u.connect(list, "row-activated", &activated, self);
            u.append(content, list);
        }
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, w), "Cancel / Close", 0);
        if (accept) |text| _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, w), text, 1);
        c.gtk_dialog_set_default_response(u.cast(c.GtkDialog, w), 0);
        u.connect(w, "response", &response, self);
        app.styleWindow(w);
        app.installTestKeys(w);
        c.gtk_window_present(u.cast(c.GtkWindow, w));
    }
    pub fn answer(self: *UI, approved: bool, index: ?usize, text: []const u8) void {
        if (self.window == null) return;
        const owned = u.z(text);
        defer u.a.free(owned);
        self.close();
        self.respond(self.context, approved, index, owned);
    }
    fn response(dialog: ?*c.GtkDialog, id: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(UI, data.?);
        if (self.window == null or self.window != u.cast(c.GtkWidget, dialog.?)) return;
        var index: ?usize = null;
        if (self.list) |list| if (c.gtk_list_box_get_selected_row(u.cast(c.GtkListBox, list))) |row| {
            index = @intCast(c.gtk_list_box_row_get_index(row));
        };
        self.answer(id == 1, index, if (self.input) |input| u.entryText(input) else "");
    }
    fn activated(_: ?*c.GtkListBox, row: ?*c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(UI, data.?);
        self.answer(true, @intCast(c.gtk_list_box_row_get_index(row)), "");
    }
    fn filterChanged(_: ?*c.GtkEditable, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(UI, data.?);
        if (self.list) |list| c.gtk_list_box_invalidate_filter(u.cast(c.GtkListBox, list));
    }
    fn filter(row: ?*c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) c_int {
        const self = u.cast(UI, data.?);
        const query = if (self.input) |input| u.entryText(input) else "";
        const label = c.gtk_list_box_row_get_child(row).?;
        const text = std.mem.span(c.gtk_label_get_text(u.cast(c.GtkLabel, label)));
        if (query.len == 0) return 1;
        if (query.len > text.len) return 0;
        for (0..text.len - query.len + 1) |i| if (std.ascii.eqlIgnoreCase(text[i..][0..query.len], query)) return 1;
        return 0;
    }
};
