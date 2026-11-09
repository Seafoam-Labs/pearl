//! Recovery persists logical lines, not pixels tied to a font or allocation.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
pub const Position = struct { line: u64, x: f64 };
const Pending = struct { position: Position, frames: u8 = 0, callback: c_uint = 0 };
const key = "coral-recovery-scroll-line";

pub fn capture(widget: u.W, x: f64, y: f64) Position {
    if (c.g_object_get_data(u.cast(c.GObject, widget), key)) |data| return u.cast(Pending, data).position;
    var iter: c.GtkTextIter = undefined;
    c.gtk_text_view_get_line_at_y(u.cast(c.GtkTextView, widget), &iter, @intFromFloat(@min(@max(0, y), std.math.maxInt(c_int))), null);
    return .{ .line = @intCast(@max(0, c.gtk_text_iter_get_line(&iter))), .x = x };
}

pub fn restore(widget: u.W, position: Position) !void {
    const pending = try u.a.create(Pending);
    pending.* = .{ .position = position };
    if (c.g_object_get_data(u.cast(c.GObject, widget), key)) |data| c.gtk_widget_remove_tick_callback(widget, u.cast(Pending, data).callback);
    c.g_object_set_data(u.cast(c.GObject, widget), key, pending);
    pending.callback = c.gtk_widget_add_tick_callback(widget, &frame, pending, &destroy);
}
fn frame(widget: ?*c.GtkWidget, _: ?*c.GdkFrameClock, data: ?*anyopaque) callconv(.c) c_int {
    const pending = u.cast(Pending, data.?);
    pending.frames += 1;
    // App.restoreView also schedules pixel restoration. Wait for that and the
    // initial cursor visibility adjustment before applying the logical anchor.
    if (pending.frames < 5) return 1;
    const view = u.cast(c.GtkTextView, widget.?);
    const buffer = c.gtk_text_view_get_buffer(view);
    var iter: c.GtkTextIter = undefined;
    _ = c.gtk_text_buffer_get_iter_at_line(buffer, &iter, @intCast(@min(pending.position.line, @as(u64, @intCast(c.gtk_text_buffer_get_line_count(buffer) - 1)))));
    var y: c_int = 0;
    c.gtk_text_view_get_line_yrange(view, &iter, &y, null);
    c.gtk_adjustment_set_value(c.gtk_scrollable_get_vadjustment(u.cast(c.GtkScrollable, widget.?)), @floatFromInt(@max(0, y)));
    c.gtk_adjustment_set_value(c.gtk_scrollable_get_hadjustment(u.cast(c.GtkScrollable, widget.?)), pending.position.x);
    c.g_object_set_data(u.cast(c.GObject, widget.?), key, null);
    return 0;
}
fn destroy(data: ?*anyopaque) callconv(.c) void {
    u.a.destroy(u.cast(Pending, data.?));
}
