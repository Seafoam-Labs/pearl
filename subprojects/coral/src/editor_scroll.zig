//! Restore scroll after the text view has been mapped and allocated. Hidden
//! notebook pages keep their requested position until their first frame.
const std = @import("std");
const u = @import("c.zig");
const c = u.c;
pub const Position = struct { x: f64, y: f64 };
const Pending = struct { position: Position, frames: u8 = 0, callback: c_uint = 0 };

pub fn capture(widget: u.W) Position {
    if (c.g_object_get_data(u.cast(c.GObject, widget), "coral-scroll-restore")) |data| return u.cast(Pending, data).position;
    const scrollable = u.cast(c.GtkScrollable, widget);
    return .{ .x = c.gtk_adjustment_get_value(c.gtk_scrollable_get_hadjustment(scrollable)), .y = c.gtk_adjustment_get_value(c.gtk_scrollable_get_vadjustment(scrollable)) };
}
pub fn restore(widget: u.W, position: Position) !void {
    if (!std.math.isFinite(position.x) or !std.math.isFinite(position.y) or position.x < 0 or position.y < 0) return error.InvalidScroll;
    const self = try u.a.create(Pending);
    self.* = .{ .position = position };
    if (c.g_object_get_data(u.cast(c.GObject, widget), "coral-scroll-restore")) |data| c.gtk_widget_remove_tick_callback(widget, u.cast(Pending, data).callback);
    c.g_object_set_data(u.cast(c.GObject, widget), "coral-scroll-restore", self);
    self.callback = c.gtk_widget_add_tick_callback(widget, &frame, self, &destroy);
}
fn frame(widget: ?*c.GtkWidget, _: ?*c.GdkFrameClock, data: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(Pending, data.?);
    self.frames += 1;
    if (self.frames < 3) return 1;
    const scrollable = u.cast(c.GtkScrollable, widget.?);
    c.gtk_adjustment_set_value(c.gtk_scrollable_get_hadjustment(scrollable), self.position.x);
    c.gtk_adjustment_set_value(c.gtk_scrollable_get_vadjustment(scrollable), self.position.y);
    c.g_object_set_data(u.cast(c.GObject, widget.?), "coral-scroll-restore", null);
    return 0;
}
fn destroy(data: ?*anyopaque) callconv(.c) void {
    u.a.destroy(u.cast(Pending, data.?));
}
