const std = @import("std");
pub const c = @import("pearl_app_c");
pub const a = std.heap.c_allocator;
pub const W = *c.GtkWidget;
pub fn cast(comptime T: type, p: anytype) *T {
    return @ptrCast(@alignCast(p));
}
pub fn connect(p: anytype, signal: [*:0]const u8, callback: anytype, data: ?*anyopaque) void {
    _ = c.g_signal_connect_data(@ptrCast(p), signal, @ptrCast(callback), data, null, 0);
}
pub fn z(s: []const u8) [:0]u8 {
    return a.dupeSentinel(u8, s, 0) catch unreachable;
}
pub fn fmt(comptime f: []const u8, args: anytype) [:0]u8 {
    return std.fmt.allocPrintSentinel(a, f, args, 0) catch unreachable;
}
pub fn box(horizontal: bool, space: c_int) W {
    return c.gtk_box_new(if (horizontal) c.GTK_ORIENTATION_HORIZONTAL else c.GTK_ORIENTATION_VERTICAL, space).?;
}
pub fn append(parent: W, child: W) void {
    c.gtk_box_append(cast(c.GtkBox, parent), child);
}
pub fn label(text: []const u8) W {
    const s = z(text);
    defer a.free(s);
    const w = c.gtk_label_new(s).?;
    c.gtk_label_set_xalign(cast(c.GtkLabel, w), 0);
    return w;
}
pub fn setLabel(w: W, text: []const u8) void {
    if (std.mem.eql(u8, std.mem.span(c.gtk_label_get_text(cast(c.GtkLabel, w))), text)) return;
    const s = z(text);
    defer a.free(s);
    c.gtk_label_set_text(cast(c.GtkLabel, w), s);
}
pub fn button(text: [*:0]const u8) W {
    return c.gtk_button_new_with_label(text).?;
}
pub fn icon(name: [*:0]const u8, title: [*:0]const u8) W {
    const w = c.gtk_button_new_from_icon_name(name).?;
    c.gtk_widget_set_tooltip_text(w, title);
    c.gtk_accessible_update_property(cast(c.GtkAccessible, w), @as(c_int, c.GTK_ACCESSIBLE_PROPERTY_LABEL), title, @as(c_int, -1));
    return w;
}
pub fn margin(w: W, n: c_int) void {
    c.gtk_widget_set_margin_start(w, n);
    c.gtk_widget_set_margin_end(w, n);
    c.gtk_widget_set_margin_top(w, n);
    c.gtk_widget_set_margin_bottom(w, n);
}
pub fn entryText(w: W) []const u8 {
    return std.mem.span(c.gtk_editable_get_text(cast(c.GtkEditable, w)));
}
pub fn bufferText(buffer: *c.GtkTextBuffer) [:0]u8 {
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_bounds(buffer, &start, &end);
    const p = c.gtk_text_buffer_get_text(buffer, &start, &end, 1);
    defer c.g_free(p);
    return z(std.mem.span(p));
}
/// Resolve existing targets and symlinked parent directories before tab identity
/// comparisons. A missing target remains valid for Save As.
pub fn canonicalPath(path: []const u8) [:0]u8 {
    const input = z(path);
    defer a.free(input);
    const real = c.realpath(input, null);
    if (real != null) {
        defer c.free(real);
        return z(std.mem.span(real));
    }
    const parent = z(std.fs.path.dirname(path) orelse ".");
    defer a.free(parent);
    const real_parent = c.realpath(parent, null);
    if (real_parent != null) {
        defer c.free(real_parent);
        return fmt("{s}/{s}", .{ std.mem.span(real_parent), std.fs.path.basename(path) });
    }
    const absolute = c.g_canonicalize_filename(input, null);
    defer c.g_free(absolute);
    return z(std.mem.span(absolute));
}
