//! Measurement-only entry point. Runs the same workspace module as the installed binary.
const coral = @import("coral");
const c = @import("pearl_app_c");
const std = @import("std");
pub const std_options = coral.std_options;

var previous: i64 = 0;
var batch_start: i64 = 0;
var gaps: [100]i64 = undefined;
var count: usize = 0;
var frame_clock: ?*c.GdkFrameClock = null;
var first_frame: i64 = -1;
var key_start: i64 = 0;
var typing: std.ArrayList(struct { key: i64, changed: i64, frame: i64 }) = .empty;

pub fn main(init: std.process.Init) void {
    std.debug.print("PROFILE build {s} {s}\n", .{ @tagName(@import("builtin").mode), @import("builtin").zig_version_string });
    previous = c.g_get_monotonic_time();
    batch_start = previous;
    const timer = c.g_timeout_add_full(c.G_PRIORITY_HIGH, 5, &heartbeat, null, null);
    coral.run(init, true);
    _ = c.g_source_remove(timer);
    flush();
    if (frame_clock) |clock| c.g_object_unref(clock);
    typing.deinit(std.heap.c_allocator);
}
fn flush() void {
    if (count == 0) return;
    var buf: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    out.print("PROFILE gaps {d}", .{batch_start}) catch unreachable;
    for (gaps[0..count]) |gap| out.print(" {d}", .{gap}) catch unreachable;
    std.debug.print("{s}\n", .{out.buffered()});
    batch_start = previous;
    count = 0;
}
fn heartbeat(_: ?*anyopaque) callconv(.c) c_int {
    const now = c.g_get_monotonic_time();
    gaps[count] = now - previous;
    previous = now;
    count += 1;
    if (count == gaps.len) flush();
    if (frame_clock == null) {
        const windows = c.gtk_window_get_toplevels();
        for (0..c.g_list_model_get_n_items(windows)) |i| {
            const window = c.g_list_model_get_item(windows, @intCast(i)) orelse continue;
            defer c.g_object_unref(window);
            const view = findSource(@ptrCast(@alignCast(window))) orelse continue;
            const clock = c.gtk_widget_get_frame_clock(view) orelse continue;
            frame_clock = @ptrCast(c.g_object_ref(clock));
            first_frame = c.gdk_frame_clock_get_frame_counter(clock) + 1;
            const keys = c.gtk_event_controller_key_new().?;
            c.gtk_event_controller_set_propagation_phase(keys, c.GTK_PHASE_CAPTURE);
            _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&keyPressed), null, null, 0);
            c.gtk_widget_add_controller(view, keys);
            const buffer = c.gtk_text_view_get_buffer(@ptrCast(view));
            _ = c.g_signal_connect_data(buffer, "changed", @ptrCast(&changed), null, null, 0);
            c.gtk_widget_queue_draw(view);
            break;
        }
    }
    if (frame_clock) |clock| {
        if (first_frame >= 0) if (feedback(clock, first_frame)) |presented| {
            std.debug.print("PROFILE first {d} {d}\n", .{ now, presented });
            first_frame = -1;
        };
        var i: usize = 0;
        while (i < typing.items.len) {
            const sample = typing.items[i];
            if (feedback(clock, sample.frame)) |presented| {
                std.debug.print("PROFILE key {d} {d} {d} {d}\n", .{ sample.key, sample.changed, now, presented });
                _ = typing.orderedRemove(i);
            } else i += 1;
        }
    }
    return 1;
}
fn feedback(clock: *c.GdkFrameClock, frame: i64) ?i64 {
    const timing = c.gdk_frame_clock_get_timings(clock, frame) orelse return null;
    if (c.gdk_frame_timings_get_complete(timing) == 0) return null;
    return c.gdk_frame_timings_get_presentation_time(timing);
}
fn findSource(widget: *c.GtkWidget) ?*c.GtkWidget {
    if (c.gtk_widget_get_mapped(widget) == 0) return null;
    if (c.g_type_check_instance_is_a(@ptrCast(widget), c.gtk_source_view_get_type()) != 0) {
        const buffer = c.gtk_text_view_get_buffer(@ptrCast(widget));
        var start: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_start_iter(buffer, &start);
        var end = start;
        _ = c.gtk_text_iter_forward_to_line_end(&end);
        const prefix = c.gtk_text_buffer_get_text(buffer, &start, &end, 0);
        defer c.g_free(prefix);
        if (std.mem.eql(u8, std.mem.span(prefix), "Coral profile document")) return widget;
    }
    var child = c.gtk_widget_get_first_child(widget);
    while (child) |w| : (child = c.gtk_widget_get_next_sibling(w)) if (findSource(w)) |source| return source;
    return null;
}
fn keyPressed(_: ?*c.GtkEventControllerKey, key: c_uint, _: c_uint, modifiers: c.GdkModifierType, _: ?*anyopaque) callconv(.c) c_int {
    if (modifiers & (c.GDK_ALT_MASK | c.GDK_CONTROL_MASK) == 0 and key >= 'a' and key <= 'z') key_start = c.g_get_monotonic_time();
    return 0;
}
fn changed(_: ?*c.GtkTextBuffer, _: ?*anyopaque) callconv(.c) void {
    if (key_start == 0) return;
    typing.append(std.heap.c_allocator, .{ .key = key_start, .changed = c.g_get_monotonic_time(), .frame = c.gdk_frame_clock_get_frame_counter(frame_clock.?) + 1 }) catch unreachable;
    key_start = 0;
}
