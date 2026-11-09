//! Bounded diagnostic probes, not replacements for the M0 qualification workloads.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const Document = @import("../document.zig").Document;
const View = @import("view.zig").EditorView;
const Excerpt = @import("excerpt.zig").Excerpt;
const a = std.heap.c_allocator;
test "bounded diagnostic: huge paragraph layout without language engines" {
    if (c.g_getenv("CORAL_HOTPATH_PROBE") == null) return;
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    for ([_]usize{ 64 * 1024, 1024 * 1024 }) |size| {
        const text = try bytes(size);
        defer a.free(text);
        for (text) |*byte| if (byte.* == '\n') {
            byte.* = ' ';
        };
        for ([_]bool{ false, true }) |wrap| {
            const d = try Document.create(20000, null);
            defer d.destroy();
            c.gtk_text_buffer_set_text(d.buffer, text.ptr, @intCast(text.len));
            // Raw native control intentionally bypasses Coral's layout guard:
            // measure the toolkit limitation, not a hidden presentation widget.
            const widget = c.gtk_source_view_new_with_buffer(u.cast(c.GtkSourceBuffer, d.buffer)).?;
            c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, widget), 1);
            const page = c.gtk_scrolled_window_new().?;
            _ = c.g_object_ref_sink(page);
            defer c.g_object_unref(page);
            c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, page), widget);
            const view = .{ .buffer = d.buffer, .widget = widget, .page = page };
            c.gtk_text_view_set_wrap_mode(u.cast(c.GtkTextView, view.widget), if (wrap) c.GTK_WRAP_WORD_CHAR else c.GTK_WRAP_NONE);
            const window = c.gtk_window_new().?;
            defer c.gtk_window_destroy(u.cast(c.GtkWindow, window));
            c.gtk_window_set_default_size(u.cast(c.GtkWindow, window), 1000, 700);
            c.gtk_window_set_child(u.cast(c.GtkWindow, window), view.page);
            const load_start = c.g_get_monotonic_time();
            c.gtk_window_present(u.cast(c.GtkWindow, window));
            for (0..20) |_| {
                try drain();
                c.g_usleep(1000);
            }
            std.debug.print("\nHUGE size={d} wrap={} map_us={d}\n", .{ size, wrap, c.g_get_monotonic_time() - load_start });
            for (0..3) |i| {
                var iter: c.GtkTextIter = undefined;
                const start = c.g_get_monotonic_time();
                c.gtk_text_buffer_get_iter_at_offset(view.buffer, &iter, if (i == 0) 20 else if (i == 1) @divTrunc(c.gtk_text_buffer_get_char_count(view.buffer), 2) else c.gtk_text_buffer_get_char_count(view.buffer) - 1);
                c.gtk_text_buffer_insert(view.buffer, &iter, "Ω", 2);
                const sync = c.g_get_monotonic_time() - start;
                try drain();
                // Force the actual layout, not merely idle dispatch.
                var rect: c.GdkRectangle = undefined;
                c.gtk_text_view_get_iter_location(u.cast(c.GtkTextView, view.widget), &iter, &rect);
                std.debug.print("HUGE offset={d} sync_us={d} layout_drain_us={d}\n", .{ i, sync, c.g_get_monotonic_time() - start - sync });
            }
        }
    }
}
const Counts = struct {
    apply: usize = 0,
    remove: usize = 0,
    fn applied(_: ?*c.GtkTextBuffer, _: ?*c.GtkTextTag, _: ?*c.GtkTextIter, _: ?*c.GtkTextIter, data: ?*anyopaque) callconv(.c) void {
        u.cast(Counts, data.?).apply += 1;
    }
    fn removed(_: ?*c.GtkTextBuffer, _: ?*c.GtkTextTag, _: ?*c.GtkTextIter, _: ?*c.GtkTextIter, data: ?*anyopaque) callconv(.c) void {
        u.cast(Counts, data.?).remove += 1;
    }
};
fn drain() !void {
    const deadline = c.g_get_monotonic_time() + 5_000_000;
    while (c.g_main_context_iteration(null, 0) != 0) if (c.g_get_monotonic_time() > deadline) return error.ProbeDrainTimeout;
}
fn bytes(size: usize) ![]u8 {
    const result = try a.alloc(u8, size);
    var line: [64]u8 = @splat(' ');
    _ = try std.fmt.bufPrint(line[0..63], "// 000 const café = \"λ🌱\"; // deterministic", .{});
    line[63] = '\n';
    for (result, 0..) |*byte, i| byte.* = line[i % 64];
    return result;
}
test "bounded diagnostic: projection syntax controls and excerpt snapshot cost" {
    if (c.g_getenv("CORAL_HOTPATH_PROBE") == null) return;
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    c.gtk_source_init();
    // Below the explicit automatic budget: these controls must actually run
    // the requested engines. Qualification at 1/10 MiB uses the normal policy.
    const text = try bytes(256 * 1024);
    defer a.free(text);
    const language = c.gtk_source_language_manager_get_language(c.gtk_source_language_manager_get_default(), "c");
    for (0..7) |mode| {
        const d = try Document.create(10000 + mode, null);
        defer d.destroy();
        c.gtk_text_buffer_set_text(d.buffer, text.ptr, @intCast(text.len));
        c.gtk_source_buffer_set_language(u.cast(c.GtkSourceBuffer, d.buffer), language);
        const view = try View.create(d);
        defer view.destroy();
        // 0: both engines, 1: neither, 2: canonical only, 3: presentation only.
        if (mode == 1 or mode == 3) c.gtk_source_buffer_set_language(u.cast(c.GtkSourceBuffer, d.buffer), null);
        if (mode == 1 or mode == 2) c.gtk_source_buffer_set_language(u.cast(c.GtkSourceBuffer, view.buffer), null);
        if (mode == 3) c.gtk_source_buffer_set_language(u.cast(c.GtkSourceBuffer, view.buffer), language);
        if (mode == 4 or mode == 5) c.gtk_source_buffer_set_highlight_syntax(u.cast(c.GtkSourceBuffer, d.buffer), 0);
        if (mode == 4) c.gtk_source_buffer_set_highlight_syntax(u.cast(c.GtkSourceBuffer, view.buffer), 1);
        // Do not rebind EditorView.widget: its guard/selection borrow the
        // presentation buffer under that API's lifetime contract.
        const native_page: ?u.W = if (mode == 6) blk: {
            view.projection.detach();
            const widget = c.gtk_source_view_new_with_buffer(u.cast(c.GtkSourceBuffer, d.buffer)).?;
            const page = c.gtk_scrolled_window_new().?;
            _ = c.g_object_ref_sink(page);
            c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, page), widget);
            break :blk page;
        } else null;
        defer if (native_page) |page| c.g_object_unref(page);
        const edit_buffer = if (mode == 6) d.buffer else view.buffer;
        var counts: Counts = .{};
        u.connect(d.buffer, "apply-tag", &Counts.applied, &counts);
        u.connect(d.buffer, "remove-tag", &Counts.removed, &counts);
        defer _ = c.g_signal_handlers_disconnect_matched(d.buffer, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, &counts);
        const window = c.gtk_window_new().?;
        defer c.gtk_window_destroy(u.cast(c.GtkWindow, window));
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, window), 1000, 700);
        c.gtk_window_set_child(u.cast(c.GtkWindow, window), native_page orelse view.page);
        c.gtk_window_present(u.cast(c.GtkWindow, window));
        for (0..20) |_| {
            try drain();
            c.g_usleep(1000);
        }
        for (0..3) |i| {
            counts = .{};
            var iter: c.GtkTextIter = undefined;
            const start = c.g_get_monotonic_time();
            c.gtk_text_buffer_get_iter_at_offset(edit_buffer, &iter, if (i == 0) 20 else if (i == 1) @divTrunc(c.gtk_text_buffer_get_char_count(edit_buffer), 2) else c.gtk_text_buffer_get_char_count(edit_buffer) - 1);
            c.gtk_text_buffer_begin_user_action(edit_buffer);
            c.gtk_text_buffer_insert(edit_buffer, &iter, "Ω", 2);
            c.gtk_text_buffer_end_user_action(edit_buffer);
            const sync = c.g_get_monotonic_time() - start;
            try drain();
            std.debug.print("\nHOTPATH bytes={d} mode={d} offset={d} sync_us={d} drain_us={d} canonical_apply={d} canonical_remove={d}\n", .{ text.len, mode, i, sync, c.g_get_monotonic_time() - start - sync, counts.apply, counts.remove });
            c.gtk_text_buffer_undo(d.buffer);
            try drain();
        }
        const target = @import("transactions.zig").Target{ .id = d.id, .buffer = d.buffer, .revision = &d.revision, .expected_revision = d.revision };
        var excerpt = try Excerpt.init(a, target, .{ .start = 0, .end = 1280 }, false, .{});
        defer excerpt.deinit();
        const start = c.g_get_monotonic_time();
        for (0..10) |_| {
            const part = try excerpt.text(a, target);
            a.free(part);
        }
        std.debug.print("HOTPATH excerpt_1280_source_bytes={d} ten_reads_us={d}\n", .{ text.len, c.g_get_monotonic_time() - start });
    }
}
