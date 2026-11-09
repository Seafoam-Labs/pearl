//! Keep giant paragraphs out of GTK/Pango's unbounded whole-paragraph layout.
//! The complete presentation/canonical buffers remain intact. This is an explicit
//! fallback, NOT a virtualized full-text editor or a full-feature benchmark pass.
const u = @import("../c.zig");
const c = u.c;
const policy = @import("presentation_policy.zig");
pub const Guard = struct {
    scroll: *c.GtkScrolledWindow,
    widget: u.W,
    notice: u.W,
    limit_notice: u.W,
    offset: *c.GtkSpinButton,
    button: u.W,
    buffer: *c.GtkTextBuffer,
    parked_buffer: *c.GtkTextBuffer,
    state: *policy.Policy,
    blocked: bool = false,
    context: ?*anyopaque = null,
    open: ?*const fn (?*anyopaque, c_int) void = null,

    /// Owned by scroll's GObject lifetime. Both alternative children retain their
    /// own references, so switching never destroys a retained editor/selection.
    pub fn attach(scroll: *c.GtkScrolledWindow, widget: u.W, buffer: *c.GtkTextBuffer) !*Guard {
        const state = try policy.attach(buffer);
        const self = try u.a.create(Guard);
        const notice = u.box(false, 12);
        _ = c.g_object_ref_sink(notice);
        const label = u.label("Long-line mode: full text layout is paused for paragraphs over 16 KiB.\nSource text, selections, save and undo remain intact.\nChoose a character offset to edit a bounded excerpt (up to 2,048 characters).\nSyntax highlighting is disabled; this is not full-document rendering.");
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, label), 1);
        u.append(notice, label);
        const limit_notice = u.label("Bounded editing is unavailable: the complete source exceeds the 16 MiB checked-edit limit. Saving an unchanged copy remains available.");
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, limit_notice), 1);
        c.gtk_widget_set_visible(limit_notice, 0);
        u.append(notice, limit_notice);
        u.append(notice, u.label("Character offset (zero-based)"));
        const offset = c.gtk_spin_button_new_with_range(0, @floatFromInt(c.gtk_text_buffer_get_char_count(buffer)), 1).?;
        u.append(notice, offset);
        const button = c.gtk_button_new_with_label("Edit bounded excerpt").?;
        c.gtk_widget_set_sensitive(button, 0);
        u.append(notice, button);
        _ = c.g_object_ref(widget);
        _ = c.g_object_ref(buffer);
        const parked_buffer = u.cast(c.GtkTextBuffer, c.gtk_source_buffer_new(null).?);
        c.gtk_text_buffer_set_enable_undo(parked_buffer, 0);
        self.* = .{ .scroll = scroll, .widget = widget, .notice = notice, .limit_notice = limit_notice, .offset = u.cast(c.GtkSpinButton, offset), .button = button, .buffer = buffer, .parked_buffer = parked_buffer, .state = state };
        u.connect(buffer, "changed", &changed, self);
        u.connect(button, "clicked", &clicked, self);
        c.g_object_set_data_full(u.cast(c.GObject, scroll), "coral-layout-guard", self, &destroy);
        self.refresh();
        return self;
    }
    pub fn setHandler(self: *Guard, context: ?*anyopaque, open: ?*const fn (?*anyopaque, c_int) void) void {
        self.context = context;
        self.open = open;
        self.refresh();
    }
    pub fn refresh(self: *Guard) void {
        const oversized = self.state.long_line and exceedsEditLimit(self.buffer);
        c.gtk_widget_set_visible(self.limit_notice, @intFromBool(oversized));
        c.gtk_widget_set_sensitive(self.button, @intFromBool(self.open != null and !oversized));
        c.gtk_widget_set_sensitive(u.cast(c.GtkWidget, self.offset), @intFromBool(!oversized));
        if (self.state.long_line) c.gtk_spin_button_set_range(self.offset, 0, @floatFromInt(c.gtk_text_buffer_get_char_count(self.buffer)));
        if (self.blocked == self.state.long_line) return;
        const had_focus = c.gtk_widget_has_focus(self.widget) != 0 or c.gtk_widget_has_focus(self.button) != 0 or c.gtk_widget_has_focus(u.cast(c.GtkWidget, self.offset)) != 0;
        self.blocked = self.state.long_line;
        // GtkTextView unrealize relinquishes PRIMARY and can collapse selection.
        // Changing presentation mode must not change either directed endpoint.
        var insertion: c.GtkTextIter = undefined;
        var bound: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_mark(self.buffer, &insertion, c.gtk_text_buffer_get_insert(self.buffer));
        c.gtk_text_buffer_get_iter_at_mark(self.buffer, &bound, c.gtk_text_buffer_get_selection_bound(self.buffer));
        // Unparenting alone leaves GtkTextView's layout subscribed to buffer
        // edits. Even an unmapped view then spends hundreds of milliseconds on
        // the giant paragraph. Park ONLY the hidden widget, not its authoritative
        // presentation buffer: text, annotations and pane selections stay intact.
        if (self.blocked) {
            c.gtk_scrolled_window_set_child(self.scroll, self.notice);
            c.gtk_text_view_set_buffer(u.cast(c.GtkTextView, self.widget), self.parked_buffer);
        } else {
            c.gtk_text_view_set_buffer(u.cast(c.GtkTextView, self.widget), self.buffer);
            c.gtk_scrolled_window_set_child(self.scroll, self.widget);
        }
        c.gtk_text_buffer_select_range(self.buffer, &insertion, &bound);
        if (had_focus) _ = c.gtk_widget_grab_focus(if (self.blocked) self.button else self.widget);
    }
    fn clicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Guard, data.?);
        if (exceedsEditLimit(self.buffer)) return;
        if (self.open) |open| open(self.context, c.gtk_spin_button_get_value_as_int(self.offset));
    }
    fn changed(_: ?*c.GtkTextBuffer, data: ?*anyopaque) callconv(.c) void {
        u.cast(Guard, data.?).refresh();
    }
    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Guard, data.?);
        _ = c.g_signal_handlers_disconnect_matched(self.buffer, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        _ = c.g_signal_handlers_disconnect_matched(self.button, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.g_object_unref(self.widget);
        c.g_object_unref(self.parked_buffer);
        c.g_object_unref(self.buffer);
        c.g_object_unref(self.notice);
        u.a.destroy(self);
    }
};

/// Inspect line byte metadata without allocating another whole-source snapshot.
fn exceedsEditLimit(buffer: *c.GtkTextBuffer) bool {
    const limit = (@import("transactions.zig").Limits{}).max_buffer_bytes;
    if (c.gtk_text_buffer_get_char_count(buffer) > limit) return true;
    var iter: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_start_iter(buffer, &iter);
    var bytes: usize = 0;
    while (true) {
        bytes += @intCast(c.gtk_text_iter_get_bytes_in_line(&iter));
        if (bytes > limit) return true;
        if (c.gtk_text_iter_forward_line(&iter) == 0) return false;
    }
}
