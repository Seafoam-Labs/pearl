//! Headless buffer/mark tests only: deliberately no gtk_init or widget creation.
//! Widget lifetime/focus/scroll checks belong in a separate display-backed harness,
//! not tests that silently skip when no display is available.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const Selection = @import("view.zig").Selection;
const testing = std.testing;

fn bufferWithText(text: [:0]const u8) *c.GtkTextBuffer {
    const buffer = c.gtk_text_buffer_new(null).?;
    c.gtk_text_buffer_set_text(buffer, text, -1);
    c.gtk_text_buffer_set_modified(buffer, 0);
    c.gtk_text_buffer_set_enable_undo(buffer, 1);
    return buffer;
}

fn select(buffer: *c.GtkTextBuffer, insertion: c_int, bound: c_int) void {
    var i: c.GtkTextIter = undefined;
    var b: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(buffer, &i, insertion);
    c.gtk_text_buffer_get_iter_at_offset(buffer, &b, bound);
    c.gtk_text_buffer_select_range(buffer, &i, &b);
}

fn expectSelection(buffer: *c.GtkTextBuffer, insertion: c_int, bound: c_int) !void {
    var i: c.GtkTextIter = undefined;
    var b: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_mark(buffer, &i, c.gtk_text_buffer_get_insert(buffer));
    c.gtk_text_buffer_get_iter_at_mark(buffer, &b, c.gtk_text_buffer_get_selection_bound(buffer));
    try testing.expectEqual(insertion, c.gtk_text_iter_get_offset(&i));
    try testing.expectEqual(bound, c.gtk_text_iter_get_offset(&b));
}

fn insert(buffer: *c.GtkTextBuffer, at: c_int, text: [:0]const u8) void {
    var iter: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(buffer, &iter, at);
    c.gtk_text_buffer_insert(buffer, &iter, text, -1);
}

fn delete(buffer: *c.GtkTextBuffer, start: c_int, end: c_int) void {
    var i: c.GtkTextIter = undefined;
    var b: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(buffer, &i, start);
    c.gtk_text_buffer_get_iter_at_offset(buffer, &b, end);
    c.gtk_text_buffer_delete(buffer, &i, &b);
}

test "selection captures current cursor and preserves reversed Unicode selection" {
    const buffer = bufferWithText("aé🌱xyz");
    defer c.g_object_unref(buffer);
    select(buffer, 1, 4);
    var saved = Selection.init(buffer);
    defer saved.deinit();
    try expectSelection(buffer, 1, 4);
    select(buffer, 6, 6);
    saved.restore();
    try expectSelection(buffer, 1, 4);
    select(buffer, 5, 2);
    saved.save();
    select(buffer, 0, 0);
    saved.restore();
    try expectSelection(buffer, 5, 2);
    try testing.expectEqual(@as(c_int, 0), c.gtk_text_buffer_get_modified(buffer));
    try testing.expectEqual(@as(c_int, 0), c.gtk_text_buffer_get_can_undo(buffer));
}

test "two saved views track concurrent insertions and overlapping deletions" {
    const buffer = bufferWithText("aé🌱xyz");
    defer c.g_object_unref(buffer);
    select(buffer, 1, 4);
    var first = Selection.init(buffer);
    defer first.deinit();
    select(buffer, 6, 6);
    var second = Selection.init(buffer);
    defer second.deinit();
    insert(buffer, 0, "Ω");
    first.restore();
    try expectSelection(buffer, 2, 5);
    second.restore();
    try expectSelection(buffer, 7, 7);
    delete(buffer, 1, 4);
    first.restore();
    try expectSelection(buffer, 1, 2);
    second.restore();
    try expectSelection(buffer, 4, 4);
    delete(buffer, 0, 4);
    first.restore();
    try expectSelection(buffer, 0, 0);
    second.restore();
    try expectSelection(buffer, 0, 0);
}

test "right gravity keeps collapsed carets collapsed and tracks both range endpoints" {
    const buffer = bufferWithText("abcdef");
    defer c.g_object_unref(buffer);
    select(buffer, 2, 2);
    var caret = Selection.init(buffer);
    defer caret.deinit();
    select(buffer, 4, 2);
    var range = Selection.init(buffer);
    defer range.deinit();
    insert(buffer, 2, "é🌱");
    caret.restore();
    try expectSelection(buffer, 4, 4);
    range.restore();
    try expectSelection(buffer, 6, 4);
    insert(buffer, 6, "Z");
    range.restore();
    try expectSelection(buffer, 7, 4);
}

test "saved marks follow undo redo without creating undo records" {
    const buffer = bufferWithText("abc");
    defer c.g_object_unref(buffer);
    select(buffer, 2, 2);
    var saved = Selection.init(buffer);
    defer saved.deinit();
    c.gtk_text_buffer_begin_user_action(buffer);
    insert(buffer, 0, "🌱");
    c.gtk_text_buffer_end_user_action(buffer);
    c.gtk_text_buffer_undo(buffer);
    saved.restore();
    try expectSelection(buffer, 2, 2);
    c.gtk_text_buffer_redo(buffer);
    saved.restore();
    try expectSelection(buffer, 3, 3);
}

test "explicit capture adopts a programmatic goto before focus restoration" {
    const buffer = bufferWithText("abcdef");
    defer c.g_object_unref(buffer);
    select(buffer, 1, 1);
    var saved = Selection.init(buffer);
    defer saved.deinit();
    select(buffer, 5, 5);
    saved.save(); // Controller navigated while editor was not focused.
    saved.restore(); // The opt-in focus enter must not undo that navigation.
    try expectSelection(buffer, 5, 5);
}

test "deinit deletes only owned anonymous marks and leaves the buffer usable" {
    const buffer = bufferWithText("abc");
    defer c.g_object_unref(buffer);
    var first = Selection.init(buffer);
    var second = Selection.init(buffer);
    defer second.deinit();
    const insertion = first.insertion;
    const bound = first.bound;
    _ = c.g_object_ref(insertion);
    defer c.g_object_unref(insertion);
    _ = c.g_object_ref(bound);
    defer c.g_object_unref(bound);
    try testing.expect(c.gtk_text_mark_get_name(insertion) == null);
    try testing.expectEqual(@as(c_int, 0), c.gtk_text_mark_get_visible(insertion));
    first.deinit();
    try testing.expect(c.gtk_text_mark_get_deleted(insertion) != 0);
    try testing.expect(c.gtk_text_mark_get_deleted(bound) != 0);
    try testing.expectEqual(@as(c_int, 0), c.gtk_text_mark_get_deleted(second.insertion));
    second.restore();
    insert(buffer, 0, "still alive");
}
