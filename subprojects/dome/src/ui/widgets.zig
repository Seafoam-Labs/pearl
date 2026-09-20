const std = @import("std");
pub const c = @import("../platform/c.zig").c;
pub const a = std.heap.c_allocator;
pub const W = *c.GtkWidget;
pub fn cast(comptime T: type, value: anytype) *T {
    return @ptrCast(@alignCast(value));
}
pub fn connect(widget: anytype, signal: [*:0]const u8, callback: anytype, data: ?*anyopaque) void {
    _ = c.g_signal_connect_data(@ptrCast(widget), signal, @ptrCast(callback), data, null, 0);
}
pub fn class(widget: W, name: [*:0]const u8) void {
    c.gtk_widget_add_css_class(widget, name);
}
pub fn box(orientation: c.GtkOrientation, space: c_int, style: ?[*:0]const u8) W {
    const w = c.gtk_box_new(orientation, space).?;
    if (style) |s| class(w, s);
    return w;
}
pub fn append(parent: W, child: W) void {
    c.gtk_box_append(cast(c.GtkBox, parent), child);
}
pub fn clear(parent: W) void {
    while (c.gtk_widget_get_first_child(parent)) |child| c.gtk_box_remove(cast(c.GtkBox, parent), child);
}
pub fn label(text: []const u8, style: ?[*:0]const u8) W {
    const z = a.dupeZ(u8, text) catch unreachable;
    defer a.free(z);
    const w = c.gtk_label_new(z).?;
    c.gtk_label_set_xalign(cast(c.GtkLabel, w), 0);
    if (style) |s| class(w, s);
    return w;
}
pub fn setLabel(widget: W, text: []const u8) void {
    if (std.mem.eql(u8, std.mem.span(c.gtk_label_get_text(cast(c.GtkLabel, widget))), text)) return;
    const z = a.dupeZ(u8, text) catch unreachable;
    defer a.free(z);
    c.gtk_label_set_text(cast(c.GtkLabel, widget), z);
}
pub fn wrap(widget: W) void {
    c.gtk_label_set_wrap(cast(c.GtkLabel, widget), 1);
    c.gtk_label_set_wrap_mode(cast(c.GtkLabel, widget), c.PANGO_WRAP_WORD_CHAR);
}
pub fn ellipsize(widget: W) void {
    c.gtk_label_set_ellipsize(cast(c.GtkLabel, widget), c.PANGO_ELLIPSIZE_END);
}
pub fn button(text: []const u8) W {
    const z = a.dupeZ(u8, text) catch unreachable;
    defer a.free(z);
    return c.gtk_button_new_with_label(z).?;
}
pub fn image(name: [*:0]const u8, size: c_int) W {
    const w = c.gtk_image_new_from_icon_name(name).?;
    c.gtk_image_set_pixel_size(cast(c.GtkImage, w), size);
    return w;
}
pub fn iconButton(name: [*:0]const u8, tooltip: [*:0]const u8) W {
    const w = c.gtk_button_new_from_icon_name(name).?;
    class(w, "icon-button");
    c.gtk_widget_set_tooltip_text(w, tooltip);
    c.gtk_accessible_update_property(cast(c.GtkAccessible, w), @as(c_int, c.GTK_ACCESSIBLE_PROPERTY_LABEL), tooltip, @as(c_int, -1));
    return w;
}
pub fn scroll(child: W) W {
    const w = c.gtk_scrolled_window_new().?;
    c.gtk_scrolled_window_set_policy(cast(c.GtkScrolledWindow, w), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_child(cast(c.GtkScrolledWindow, w), child);
    c.gtk_widget_set_vexpand(w, 1);
    c.gtk_widget_set_hexpand(w, 1);
    return w;
}
pub fn expand(widget: W) void {
    c.gtk_widget_set_hexpand(widget, 1);
}
pub fn margin(widget: W, n: c_int) void {
    c.gtk_widget_set_margin_top(widget, n);
    c.gtk_widget_set_margin_bottom(widget, n);
    c.gtk_widget_set_margin_start(widget, n);
    c.gtk_widget_set_margin_end(widget, n);
}
pub fn fmt(comptime format: []const u8, args: anytype) [:0]u8 {
    return std.fmt.allocPrintSentinel(a, format, args, 0) catch unreachable;
}
pub fn bytes(value: f64) @import("../core/model.zig").Name {
    var buffer: [128]u8 = undefined;
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var n = value;
    var index: usize = 0;
    while (n >= 1024 and index < units.len - 1) : (index += 1) n /= 1024;
    const text = std.fmt.bufPrint(&buffer, "{d:.1} {s}", .{ n, units[index] }) catch "—";
    return @import("../core/model.zig").Name.init(text);
}
