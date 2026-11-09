//! Import separately from the parent's display-backed widget test root.
const std = @import("std");
const t = std.testing;
const u = @import("../c.zig");
const c = u.c;
const ex = @import("excerpt.zig");
const ui = @import("excerpt_editor.zig");
const tx = @import("transactions.zig");
const History = @import("history.zig").History;
const F = @import("history_test_support.zig").Fixture;
const r = @import("history_test_support.zig").r;
test {
    _ = @import("hotpath_probe.zig");
    _ = @import("presentation_policy_tests.zig");
    _ = @import("advanced_feasibility_tests.zig");
}
const Context = struct {
    fixture: *F,
    open: bool = true,
    commits: usize = 0,
    fn resolve(data: ?*anyopaque, id: u64) ?tx.Target {
        const self = u.cast(Context, data.?);
        return if (self.open and id == 1) self.fixture.target(id) else null;
    }
    fn committed(data: ?*anyopaque) void {
        u.cast(Context, data.?).commits += 1;
    }
};
fn display(editor: *ui.Editor, expected: []const u8) !void {
    const text = u.bufferText(editor.display);
    defer u.a.free(text);
    try t.expectEqualStrings(expected, text);
}
fn drain() void {
    while (c.g_main_context_iteration(null, 0) != 0) {}
}

test "full widgets isolate adjacent typing from grouped commit and inverse replay" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const Document = @import("../document.zig").Document;
    const View = @import("view.zig").EditorView;
    for ([_]bool{ false, true }) |inverse| {
        const document = try Document.create(7701, null);
        defer document.destroy();
        c.gtk_text_buffer_set_text(document.buffer, if (inverse) "baseX" else "base", -1);
        var other: F = .{};
        other.init(if (inverse) "baseX" else "base");
        defer other.deinit();
        const first = try View.create(document);
        defer first.destroy();
        const second = try View.create(document);
        defer second.destroy();
        var history = History.init(t.allocator, .{});
        defer history.deinit();
        var target = tx.Target{ .id = document.id, .buffer = document.buffer, .revision = &document.revision, .expected_revision = document.revision };
        try history.perform("both", &.{
            .{ .target = target, .replacements = &.{r(4, if (inverse) 5 else 4, if (inverse) "" else "X")} },
            .{ .target = other.target(7702), .replacements = &.{r(4, if (inverse) 5 else 4, if (inverse) "" else "X")} },
        });
        target.expected_revision = document.revision;
        if (inverse) try history.undo(&.{ target, other.target(7702) });
        var iter: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_offset(second.buffer, &iter, 2);
        c.gtk_text_buffer_place_cursor(second.buffer, &iter);
        c.gtk_text_buffer_get_end_iter(first.buffer, &iter);
        c.gtk_text_buffer_place_cursor(first.buffer, &iter);
        const other_revision = other.revision;
        c.g_signal_emit_by_name(first.widget, "insert-at-cursor", @as([*:0]const u8, "y"));
        target.expected_revision = document.revision;
        first.syncSelectionToDocument();
        try t.expect(try history.replayNative(target, false));
        first.syncSelectionFromDocument();
        for ([_]*c.GtkTextBuffer{ document.buffer, first.buffer, second.buffer }) |buffer| {
            const actual = u.bufferText(buffer);
            defer u.a.free(actual);
            try t.expectEqualStrings("baseX", actual);
        }
        try other.expect("baseX");
        try t.expectEqual(other_revision, other.revision);
        c.gtk_text_buffer_get_iter_at_mark(second.buffer, &iter, c.gtk_text_buffer_get_insert(second.buffer));
        try t.expectEqual(@as(c_int, 2), c.gtk_text_iter_get_offset(&iter));
        target.expected_revision = document.revision;
        try t.expectError(error.GroupedBoundary, history.replayNative(target, false));
        try t.expect(try history.replayNative(target, true));
        const actual = u.bufferText(first.buffer);
        defer u.a.free(actual);
        try t.expectEqualStrings("baseXy", actual);
        drain();
    }
}

test "excerpt widget insert delete header boundary and workspace undo redo" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    var f: F = .{};
    f.init("header:aé🌱z:footer");
    defer f.deinit();
    var context: Context = .{ .fixture = &f };
    var history = History.init(t.allocator, .{});
    defer history.deinit();
    const excerpt = try ex.Excerpt.init(t.allocator, f.target(1), .{ .start = 7, .end = 15 }, false, .{});
    const editor = try ui.Editor.create(t.allocator, excerpt, "File A — editable region", .{ .resolve = Context.resolve, .context = &context, .history = &history, .committed = Context.committed });
    defer editor.destroy();
    try display(editor, "aé🌱z");
    var iter: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(editor.display, &iter, 2);
    c.gtk_text_buffer_insert(editor.display, &iter, "終", 3);
    try f.expect("header:aé終🌱z:footer");
    try display(editor, "aé終🌱z");
    try t.expectEqual(@as(usize, 1), context.commits);
    try t.expectEqual(@as(c_int, 3), c.gtk_text_iter_get_offset(&iter));
    try t.expectEqual(@as(c_int, 0), c.gtk_text_buffer_get_can_undo(editor.display));
    try history.undo(&.{f.target(1)});
    drain();
    try display(editor, "aé🌱z");
    try history.redo(&.{f.target(1)});
    drain();
    try display(editor, "aé終🌱z");
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(editor.display, &iter, 1);
    c.gtk_text_buffer_get_iter_at_offset(editor.display, &end, 3);
    c.gtk_text_buffer_delete(editor.display, &iter, &end);
    try f.expect("header:a🌱z:footer");
    try display(editor, "a🌱z");
    try t.expectError(error.OutOfBounds, editor.replace(r(0, 99, "")));
    try t.expectEqual(@as(usize, 2), context.commits);
}

test "excerpt widget stale input refuses then external edits native undo and close refresh safely" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    var f: F = .{};
    f.init("[abc]");
    defer f.deinit();
    var context: Context = .{ .fixture = &f };
    const excerpt = try ex.Excerpt.init(t.allocator, f.target(1), .{ .start = 1, .end = 4 }, false, .{});
    const editor = try ui.Editor.create(t.allocator, excerpt, "region", .{ .resolve = Context.resolve, .context = &context });
    defer editor.destroy();
    f.insert(2, "外");
    try t.expectError(error.StaleRevision, editor.replace(r(1, 2, "X")));
    try f.expect("[a外bc]");
    try display(editor, "a外bc");
    c.gtk_text_buffer_undo(f.buffer);
    drain();
    try display(editor, "abc");
    f.insert(0, "prefix");
    drain();
    try display(editor, "abc");
    try editor.replace(r(1, 2, "B"));
    try f.expect("prefix[aBc]");
    context.open = false;
    try t.expectError(error.TargetMismatch, editor.refresh());
    try t.expectError(error.TargetMismatch, editor.replace(r(0, 1, "x")));
    try t.expectEqual(@as(c_int, 0), c.gtk_text_view_get_editable(u.cast(c.GtkTextView, editor.widget)));
}

test "excerpt refresh preserves directed selection and unaffected annotations and cancels redundant idle" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    var f: F = .{};
    f.init("[aé🌱z]");
    defer f.deinit();
    var context: Context = .{ .fixture = &f };
    const excerpt = try ex.Excerpt.init(t.allocator, f.target(1), .{ .start = 1, .end = 9 }, false, .{});
    const editor = try ui.Editor.create(t.allocator, excerpt, "region", .{ .resolve = Context.resolve, .context = &context });
    defer editor.destroy();
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(editor.display, &start, 2);
    c.gtk_text_buffer_get_iter_at_offset(editor.display, &end, 4);
    c.gtk_text_buffer_select_range(editor.display, &start, &end);
    const tag = c.gtk_text_buffer_create_tag(editor.display, null, "weight", @as(c_int, 700), @as(?*anyopaque, null));
    c.gtk_text_buffer_apply_tag(editor.display, tag, &start, &end);
    f.insert(2, "外");
    try t.expect(editor.idle != 0);
    try editor.refresh();
    try t.expectEqual(@as(c_uint, 0), editor.idle);
    try display(editor, "a外é🌱z");
    c.gtk_text_buffer_get_iter_at_mark(editor.display, &start, c.gtk_text_buffer_get_insert(editor.display));
    c.gtk_text_buffer_get_iter_at_mark(editor.display, &end, c.gtk_text_buffer_get_selection_bound(editor.display));
    try t.expectEqual(@as(c_int, 3), c.gtk_text_iter_get_offset(&start));
    try t.expectEqual(@as(c_int, 5), c.gtk_text_iter_get_offset(&end));
    try t.expect(c.gtk_text_iter_has_tag(&start, tag) != 0);
    try editor.refresh();
    try t.expect(c.gtk_text_iter_has_tag(&start, tag) != 0);
    // Same-revision policy and anchor changes must not be hidden by the cache.
    c.gtk_text_buffer_delete_mark(f.buffer, editor.excerpt.source.?.start);
    try t.expectError(error.InvalidAnchor, editor.refresh());
    try t.expectEqual(@as(c_int, 0), c.gtk_text_view_get_editable(u.cast(c.GtkTextView, editor.widget)));
}

test "excerpt directed selection follows actual canonical edits in repeated text" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    var f: F = .{};
    f.init("[aaaa]");
    defer f.deinit();
    var context: Context = .{ .fixture = &f };
    const excerpt = try ex.Excerpt.init(t.allocator, f.target(1), .{ .start = 1, .end = 5 }, false, .{});
    const editor = try ui.Editor.create(t.allocator, excerpt, "region", .{ .resolve = Context.resolve, .context = &context });
    defer editor.destroy();
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(editor.display, &start, 3);
    c.gtk_text_buffer_get_iter_at_offset(editor.display, &end, 1);
    c.gtk_text_buffer_select_range(editor.display, &start, &end);
    f.insert(1, "a");
    try editor.refresh();
    try display(editor, "aaaaa");
    c.gtk_text_buffer_get_iter_at_mark(editor.display, &start, c.gtk_text_buffer_get_insert(editor.display));
    c.gtk_text_buffer_get_iter_at_mark(editor.display, &end, c.gtk_text_buffer_get_selection_bound(editor.display));
    try t.expectEqual(@as(c_int, 4), c.gtk_text_iter_get_offset(&start));
    try t.expectEqual(@as(c_int, 2), c.gtk_text_iter_get_offset(&end));
}

test "excerpt outside edits avoid allocation while coalesced overlap boundary and anchor changes refresh" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    var f: F = .{};
    f.init("[abc]");
    defer f.deinit();
    var context: Context = .{ .fixture = &f };
    const excerpt = try ex.Excerpt.init(t.allocator, f.target(1), .{ .start = 1, .end = 4 }, false, .{});
    const editor = try ui.Editor.create(t.allocator, excerpt, "region", .{ .resolve = Context.resolve, .context = &context });
    defer editor.destroy();
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    f.insert(0, "外");
    f.insert(6, "tail");
    editor.allocator = failing.allocator();
    defer editor.allocator = t.allocator;
    try editor.refresh();
    try display(editor, "abc");
    try t.expect(!failing.has_induced_failure);
    try t.expectEqual(f.revision, editor.revision.?);
    editor.allocator = t.allocator;
    // Two pending changes: the outside edit must not erase the overlapping one.
    f.insert(3, "Ω");
    f.insert(0, "prefix");
    try editor.refresh();
    try display(editor, "aΩbc");
    const source = editor.excerpt.source.?;
    var start: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_mark(f.buffer, &start, source.start);
    c.gtk_text_buffer_insert(f.buffer, &start, "L", 1);
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_mark(f.buffer, &end, source.end);
    c.gtk_text_buffer_insert(f.buffer, &end, "R", 1);
    try editor.refresh();
    try display(editor, "LaΩbcR");
    // Moving anchors before an otherwise outside edit invalidates the proof.
    c.gtk_text_buffer_get_start_iter(f.buffer, &start);
    c.gtk_text_buffer_move_mark(f.buffer, source.start, &start);
    f.insert(c.gtk_text_buffer_get_char_count(f.buffer), "!");
    try editor.refresh();
    try display(editor, "prefix外[LaΩbcR");
    c.gtk_text_buffer_delete_mark(f.buffer, source.start);
    f.insert(0, "!");
    try t.expectError(error.InvalidAnchor, editor.refresh());
}

test "excerpt cancelled outside insertion cannot hide object mutation and failed refresh remains invalid" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    var f: F = .{};
    f.init("[abc]");
    defer f.deinit();
    var context: Context = .{ .fixture = &f };
    const excerpt = try ex.Excerpt.init(t.allocator, f.target(1), .{ .start = 1, .end = 4 }, false, .{});
    const editor = try ui.Editor.create(t.allocator, excerpt, "region", .{ .resolve = Context.resolve, .context = &context });
    defer editor.destroy();
    const Stop = struct {
        fn insert(buffer: ?*c.GtkTextBuffer, _: ?*c.GtkTextIter, _: [*c]const u8, _: c_int, _: ?*anyopaque) callconv(.c) void {
            c.g_signal_stop_emission_by_name(buffer, "insert-text");
        }
    };
    var token: u8 = 0;
    u.connect(f.buffer, "insert-text", &Stop.insert, &token);
    f.insert(0, "x");
    _ = c.g_signal_handlers_disconnect_matched(f.buffer, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, &token);
    try f.expect("[abc]");
    var start: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(f.buffer, &start, 2);
    _ = c.gtk_text_buffer_create_child_anchor(f.buffer, &start);
    try t.expectError(error.UnsupportedBufferContent, editor.refresh());
    try t.expect(editor.text_dirty and editor.source_dirty);
    try display(editor, "abc");
    c.gtk_text_buffer_get_iter_at_offset(f.buffer, &start, 2);
    var end = start;
    _ = c.gtk_text_iter_forward_char(&end);
    c.gtk_text_buffer_delete(f.buffer, &start, &end);
    try editor.refresh();
    try display(editor, "abc");
    f.insert(2, "Ω");
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    editor.allocator = failing.allocator();
    defer editor.allocator = t.allocator;
    try t.expectError(error.OutOfMemory, editor.refresh());
    try t.expect(editor.text_dirty and editor.source_dirty);
    try display(editor, "abc");
    editor.allocator = t.allocator;
    try editor.refresh();
    try display(editor, "aΩbc");
}

test "excerpt source signals invalidate same-revision same-bounds cache and reject stale input" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    var f: F = .{};
    f.init("[abc]");
    defer f.deinit();
    var context: Context = .{ .fixture = &f };
    const excerpt = try ex.Excerpt.init(t.allocator, f.target(1), .{ .start = 1, .end = 4 }, false, .{});
    const editor = try ui.Editor.create(t.allocator, excerpt, "region", .{ .resolve = Context.resolve, .context = &context });
    defer editor.destroy();
    const revision = f.revision;
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(f.buffer, &start, 2);
    c.gtk_text_buffer_get_iter_at_offset(f.buffer, &end, 3);
    c.gtk_text_buffer_delete(f.buffer, &start, &end);
    c.gtk_text_buffer_insert(f.buffer, &start, "B", 1);
    f.revision = revision; // Broken owner: changed still invalidates the UI cache.
    try t.expectError(error.StaleRevision, editor.replace(r(0, 1, "X")));
    try display(editor, "aBc");
    try t.expect(!editor.source_dirty);
    try t.expectEqual(@as(c_uint, 0), editor.idle);
    try f.expect("[aBc]");
}

test "excerpt widget read-only snapshot rejects even programmatic display buffer edits" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    var f: F = .{};
    f.init("new");
    defer f.deinit();
    var context: Context = .{ .fixture = &f };
    const excerpt = try ex.Excerpt.snapshot(t.allocator, 1, "historical é", .{});
    const editor = try ui.Editor.create(t.allocator, excerpt, "Historical snapshot", .{ .resolve = Context.resolve, .context = &context });
    defer editor.destroy();
    var iter: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_start_iter(editor.display, &iter);
    c.gtk_text_buffer_insert(editor.display, &iter, "x", 1);
    try t.expectEqual(error.ReadOnly, editor.last_error.?);
    try display(editor, "historical é");
    try f.expect("new");
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_bounds(editor.display, &iter, &end);
    c.gtk_text_buffer_delete(editor.display, &iter, &end);
    try display(editor, "historical é");
}
