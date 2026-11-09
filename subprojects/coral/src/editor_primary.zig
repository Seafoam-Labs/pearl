//! GTK normally collapses a TextBuffer selection when its PRIMARY content
//! provider loses ownership. Independent editor panes must not share that state.
//! Replace the view's PRIMARY registration while realized, publishing a text
//! snapshot instead. Ordinary clipboard copy/cut/paste remain GTK operations.
const u = @import("c.zig");
const c = u.c;
const Primary = struct {
    widget: u.W,
    buffer: *c.GtkTextBuffer,
    detached: bool = false,
    syncing: bool = false,
};
pub fn attach(widget: u.W, buffer: *c.GtkTextBuffer) !void {
    const self = try u.a.create(Primary);
    self.* = .{ .widget = widget, .buffer = u.cast(c.GtkTextBuffer, c.g_object_ref(buffer).?) };
    c.g_object_set_data_full(u.cast(c.GObject, widget), "coral-primary", self, &destroy);
    _ = c.g_signal_connect_data(widget, "realize", @ptrCast(&realized), self, null, c.G_CONNECT_AFTER);
    u.connect(widget, "unrealize", &unrealizing, self);
    u.connect(buffer, "mark-set", &mark, self);
    u.connect(buffer, "changed", &changed, self);
    if (c.gtk_widget_get_realized(widget) != 0) realized(widget, self);
}
fn realized(_: ?*c.GtkWidget, context: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Primary, context.?);
    if (self.detached) return;
    self.syncing = true;
    defer self.syncing = false;
    var insertion: c.GtkTextIter = undefined;
    var bound: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_mark(self.buffer, &insertion, c.gtk_text_buffer_get_insert(self.buffer));
    c.gtk_text_buffer_get_iter_at_mark(self.buffer, &bound, c.gtk_text_buffer_get_selection_bound(self.buffer));
    c.gtk_text_buffer_remove_selection_clipboard(self.buffer, c.gtk_widget_get_primary_clipboard(self.widget));
    self.detached = true;
    c.gtk_text_buffer_select_range(self.buffer, &insertion, &bound);
}
fn unrealizing(_: ?*c.GtkWidget, context: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Primary, context.?);
    if (!self.detached) return;
    // Balance GtkTextView's upcoming unrealize handler; it owns this registration.
    c.gtk_text_buffer_add_selection_clipboard(self.buffer, c.gtk_widget_get_primary_clipboard(self.widget));
    self.detached = false;
}
fn publish(self: *Primary) void {
    if (self.syncing or !self.detached or c.gtk_widget_has_focus(self.widget) == 0) return;
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    if (c.gtk_text_buffer_get_selection_bounds(self.buffer, &start, &end) == 0) return;
    const text = c.gtk_text_buffer_get_text(self.buffer, &start, &end, 0);
    defer c.g_free(text);
    c.gdk_clipboard_set_text(c.gtk_widget_get_primary_clipboard(self.widget), text);
}
fn mark(_: ?*c.GtkTextBuffer, _: ?*c.GtkTextIter, moved: ?*c.GtkTextMark, context: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Primary, context.?);
    if (moved == c.gtk_text_buffer_get_insert(self.buffer) or moved == c.gtk_text_buffer_get_selection_bound(self.buffer)) publish(self);
}
fn changed(_: ?*c.GtkTextBuffer, context: ?*anyopaque) callconv(.c) void {
    publish(u.cast(Primary, context.?));
}
fn destroy(context: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Primary, context.?);
    _ = c.g_signal_handlers_disconnect_matched(self.buffer, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
    c.g_object_unref(self.buffer);
    u.a.destroy(self);
}
