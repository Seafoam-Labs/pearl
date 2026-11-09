const std = @import("std");
const t = std.testing;
const u = @import("../c.zig");
const c = u.c;
const Document = @import("../document.zig").Document;
const View = @import("view.zig").EditorView;
const policy = @import("presentation_policy.zig");
fn drain() void {
    for (0..256) |_| if (c.g_main_context_iteration(null, 0) == 0) break;
}
fn source(buffer: *c.GtkTextBuffer) *c.GtkSourceBuffer {
    return u.cast(c.GtkSourceBuffer, buffer);
}

test "presentation budget restores language after native undo and preserves anonymous annotations across panes" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const d = try Document.create(22000, null);
    defer d.destroy();
    c.gtk_text_buffer_set_text(d.buffer, "int x;\n", -1);
    const language = c.gtk_source_language_manager_get_language(c.gtk_source_language_manager_get_default(), "c");
    c.gtk_source_buffer_set_language(source(d.buffer), language);
    const first = try View.create(d);
    defer first.destroy();
    const second = try View.create(d);
    defer second.destroy();
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_bounds(d.buffer, &start, &end);
    const tag = c.gtk_text_buffer_create_tag(d.buffer, null, "weight", @as(c_int, 700), @as(?*anyopaque, null));
    c.gtk_text_buffer_apply_tag(d.buffer, tag, &start, &end);
    c.gtk_source_buffer_ensure_highlight(source(d.buffer), &start, &end);
    drain();
    const text = try t.allocator.alloc(u8, policy.syntax_char_limit);
    defer t.allocator.free(text);
    @memset(text, 'x');
    for (text, 0..) |*byte, i| if (i % 64 == 63) {
        byte.* = '\n';
    };
    c.gtk_text_buffer_get_end_iter(d.buffer, &end);
    c.gtk_text_buffer_begin_user_action(d.buffer);
    c.gtk_text_buffer_insert(d.buffer, &end, text.ptr, @intCast(text.len));
    c.gtk_text_buffer_end_user_action(d.buffer);
    drain();
    for ([_]*c.GtkTextBuffer{ d.buffer, first.buffer, second.buffer }) |buffer| {
        try t.expect(policy.limited(buffer));
        try t.expect(c.gtk_source_buffer_get_language(source(buffer)) == null);
        c.gtk_text_buffer_get_start_iter(buffer, &start);
        try t.expect(c.gtk_text_iter_has_tag(&start, tag) != 0);
    }
    try t.expect(!first.layout_guard.blocked and !second.layout_guard.blocked);
    c.gtk_text_buffer_undo(d.buffer);
    drain();
    for ([_]*c.GtkTextBuffer{ d.buffer, first.buffer, second.buffer }) |buffer| {
        try t.expect(!policy.limited(buffer));
        try t.expectEqual(language, c.gtk_source_buffer_get_language(source(buffer)));
        c.gtk_text_buffer_get_bounds(buffer, &start, &end);
        c.gtk_source_buffer_ensure_highlight(source(buffer), &start, &end);
        try t.expect(c.gtk_text_iter_has_tag(&start, tag) != 0);
    }
    try t.expect(c.gtk_text_buffer_get_can_redo(d.buffer) != 0);
    c.gtk_text_buffer_redo(d.buffer);
    try t.expect(policy.limited(d.buffer));
}

const Open = struct {
    offset: c_int = -1,
    fn call(context: ?*anyopaque, offset: c_int) void {
        u.cast(Open, context.?).offset = offset;
    }
};
test "oversized long-line source explains and disables an unavailable checked excerpt" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const d = try Document.create(22002, null);
    defer d.destroy();
    // Multibyte text exercises byte limits even with character count below cap.
    const bytes = try t.allocator.alloc(u8, 18 * 1024 * 1024);
    defer t.allocator.free(bytes);
    for (0..bytes.len / 3) |i| @memcpy(bytes[i * 3 ..][0..3], "界");
    c.gtk_text_buffer_set_text(d.buffer, bytes.ptr, @intCast(bytes.len));
    const view = try View.create(d);
    defer view.destroy();
    var opened: Open = .{};
    view.layout_guard.setHandler(&opened, &Open.call);
    try t.expect(view.layout_guard.blocked);
    try t.expect(c.gtk_widget_get_visible(view.layout_guard.limit_notice) != 0);
    try t.expect(c.gtk_widget_get_sensitive(view.layout_guard.button) == 0);
    c.g_signal_emit_by_name(view.layout_guard.button, "clicked");
    try t.expectEqual(@as(c_int, -1), opened.offset);
    c.gtk_text_buffer_set_text(d.buffer, bytes.ptr, 24 * 1024);
    drain();
    try t.expect(c.gtk_widget_get_visible(view.layout_guard.limit_notice) == 0);
    try t.expect(c.gtk_widget_get_sensitive(view.layout_guard.button) != 0);
    c.g_signal_emit_by_name(view.layout_guard.button, "clicked");
    try t.expectEqual(@as(c_int, 0), opened.offset);
}

test "long paragraph guard handles late load without changing text selection or native undo" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const d = try Document.create(22001, null);
    defer d.destroy();
    c.gtk_text_buffer_set_text(d.buffer, "small", -1);
    const view = try View.create(d);
    defer view.destroy();
    const window = c.gtk_window_new().?;
    defer c.gtk_window_destroy(u.cast(c.GtkWindow, window));
    c.gtk_window_set_child(u.cast(c.GtkWindow, window), view.page);
    c.gtk_window_present(u.cast(c.GtkWindow, window));
    drain();
    var at: c.GtkTextIter = undefined;
    var bound: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(view.buffer, &at, 1);
    c.gtk_text_buffer_get_iter_at_offset(view.buffer, &bound, 4);
    c.gtk_text_buffer_select_range(view.buffer, &at, &bound);
    const tag = c.gtk_text_buffer_create_tag(view.buffer, null, "weight", @as(c_int, 700), @as(?*anyopaque, null));
    c.gtk_text_buffer_apply_tag(view.buffer, tag, &at, &bound);
    const text = try t.allocator.alloc(u8, 1024 * 1024);
    defer t.allocator.free(text);
    @memset(text, 'x');
    c.gtk_text_buffer_get_end_iter(d.buffer, &at);
    c.gtk_text_buffer_begin_user_action(d.buffer);
    c.gtk_text_buffer_insert(d.buffer, &at, text.ptr, @intCast(text.len));
    c.gtk_text_buffer_end_user_action(d.buffer);
    drain();
    try t.expect(view.layout_guard.blocked);
    try t.expect(c.gtk_widget_get_parent(view.widget) == null);
    try t.expect(c.gtk_widget_get_mapped(view.widget) == 0);
    const parked = c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, view.widget));
    try t.expect(parked != view.buffer);
    try t.expectEqual(@as(c_int, 0), c.gtk_text_buffer_get_char_count(parked));
    try t.expectEqual(@as(c_int, 1024 * 1024 + 5), c.gtk_text_buffer_get_char_count(view.buffer));
    c.gtk_text_buffer_get_iter_at_mark(view.buffer, &at, c.gtk_text_buffer_get_insert(view.buffer));
    c.gtk_text_buffer_get_iter_at_mark(view.buffer, &bound, c.gtk_text_buffer_get_selection_bound(view.buffer));
    try t.expectEqual(@as(c_int, 1), c.gtk_text_iter_get_offset(&at));
    try t.expectEqual(@as(c_int, 4), c.gtk_text_iter_get_offset(&bound));
    try t.expect(c.gtk_text_iter_has_tag(&at, tag) != 0);
    var opened: Open = .{};
    view.layout_guard.setHandler(&opened, &Open.call);
    c.gtk_spin_button_set_value(view.layout_guard.offset, 12345);
    c.g_signal_emit_by_name(view.layout_guard.button, "clicked");
    try t.expectEqual(@as(c_int, 12345), opened.offset);
    c.gtk_text_buffer_undo(d.buffer);
    drain();
    try t.expect(!view.layout_guard.blocked);
    try t.expectEqual(view.buffer, c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, view.widget)));
    c.gtk_text_buffer_get_iter_at_mark(view.buffer, &at, c.gtk_text_buffer_get_insert(view.buffer));
    c.gtk_text_buffer_get_iter_at_mark(view.buffer, &bound, c.gtk_text_buffer_get_selection_bound(view.buffer));
    try t.expectEqual(@as(c_int, 1), c.gtk_text_iter_get_offset(&at));
    try t.expectEqual(@as(c_int, 4), c.gtk_text_iter_get_offset(&bound));
    try t.expect(c.gtk_text_iter_has_tag(&at, tag) != 0);
    try t.expectEqual(view.widget, c.gtk_scrolled_window_get_child(u.cast(c.GtkScrolledWindow, view.page)).?);
    try t.expectEqual(@as(c_int, 5), c.gtk_text_buffer_get_char_count(d.buffer));
    view.disconnectDocumentCallbacks();
    c.g_signal_emit_by_name(view.layout_guard.button, "clicked");
    try t.expect(view.layout_guard.open == null);
}
