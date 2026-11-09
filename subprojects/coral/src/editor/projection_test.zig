//! Headless tests exercise real GTK buffers; display-backed rendering/focus lives
//! in widget_tests.zig. No fake editor state or saved-mark-only assertions.
const std = @import("std");
const testing = std.testing;
const u = @import("../c.zig");
const c = u.c;
const Document = @import("../document.zig").Document;
const Projection = @import("projection.zig").Projection;

fn select(buffer: *c.GtkTextBuffer, insertion: c_int, bound: c_int) void {
    var a: c.GtkTextIter = undefined;
    var b: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(buffer, &a, insertion);
    c.gtk_text_buffer_get_iter_at_offset(buffer, &b, bound);
    c.gtk_text_buffer_select_range(buffer, &a, &b);
}

fn expectSelection(buffer: *c.GtkTextBuffer, insertion: c_int, bound: c_int) !void {
    var a: c.GtkTextIter = undefined;
    var b: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_mark(buffer, &a, c.gtk_text_buffer_get_insert(buffer));
    c.gtk_text_buffer_get_iter_at_mark(buffer, &b, c.gtk_text_buffer_get_selection_bound(buffer));
    try testing.expectEqual(insertion, c.gtk_text_iter_get_offset(&a));
    try testing.expectEqual(bound, c.gtk_text_iter_get_offset(&b));
}

fn insert(buffer: *c.GtkTextBuffer, at: c_int, text: [:0]const u8) void {
    var iter: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(buffer, &iter, at);
    c.gtk_text_buffer_insert(buffer, &iter, text, -1);
}

fn expectText(buffer: *c.GtkTextBuffer, text: []const u8) !void {
    const actual = u.bufferText(buffer);
    defer u.a.free(actual);
    try testing.expectEqualStrings(text, actual);
}

fn expectAll(document: *Document, first: *Projection, second: *Projection, text: []const u8) !void {
    for ([_]*c.GtkTextBuffer{ document.buffer, first.buffer, second.buffer }) |buffer| try expectText(buffer, text);
    for ([_]*c.GtkTextBuffer{ first.buffer, second.buffer }) |buffer| {
        try testing.expectEqual(@as(c_int, 0), c.gtk_text_buffer_get_enable_undo(buffer));
        try testing.expectEqual(@as(c_int, 0), c.gtk_text_buffer_get_can_undo(buffer));
        try testing.expectEqual(@as(c_int, 0), c.gtk_text_buffer_get_modified(buffer));
    }
}

test "projections own visible Unicode selections and incrementally echo either editor" {
    const document = try Document.create(901, null);
    defer document.destroy();
    c.gtk_text_buffer_set_text(document.buffer, "aé🌱xyz", -1);
    c.gtk_text_buffer_set_modified(document.buffer, 0);
    const first = try Projection.create(document);
    defer first.destroy();
    const second = try Projection.create(document);
    defer second.destroy();
    try testing.expect(first.buffer != second.buffer and first.buffer != document.buffer);
    select(first.buffer, 1, 4);
    select(second.buffer, 6, 6);
    const revision = document.revision;
    c.gtk_text_buffer_begin_user_action(first.buffer);
    insert(first.buffer, 0, "Ω");
    c.gtk_text_buffer_end_user_action(first.buffer);
    try expectAll(document, first, second, "Ωaé🌱xyz");
    try testing.expectEqual(revision + 1, document.revision);
    try testing.expect(document.dirty());
    try expectSelection(first.buffer, 2, 5);
    try expectSelection(second.buffer, 7, 7);
    var a: c.GtkTextIter = undefined;
    var b: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(second.buffer, &a, 1);
    c.gtk_text_buffer_get_iter_at_offset(second.buffer, &b, 4);
    c.gtk_text_buffer_begin_user_action(second.buffer);
    c.gtk_text_buffer_delete(second.buffer, &a, &b);
    c.gtk_text_buffer_end_user_action(second.buffer);
    try testing.expectEqual(@as(c_int, 1), c.gtk_text_iter_get_offset(&a));
    try testing.expectEqual(@as(c_int, 1), c.gtk_text_iter_get_offset(&b));
    try expectAll(document, first, second, "Ωxyz");
    try expectSelection(first.buffer, 1, 2);
    try expectSelection(second.buffer, 4, 4);
    // Canonical cursor movement (including undo's cursor restoration) is not
    // another pane's cursor movement. Only edits adjust their native marks.
    select(document.buffer, 0, 0);
    try expectSelection(first.buffer, 1, 2);
    c.gtk_text_buffer_undo(document.buffer);
    try expectAll(document, first, second, "Ωaé🌱xyz");
    c.gtk_text_buffer_redo(document.buffer);
    try expectAll(document, first, second, "Ωxyz");
}

test "nested native user actions produce one canonical undo and no mirror undo" {
    const document = try Document.create(902, null);
    defer document.destroy();
    c.gtk_text_buffer_set_text(document.buffer, "abc", -1);
    c.gtk_text_buffer_set_enable_undo(document.buffer, 0);
    c.gtk_text_buffer_set_enable_undo(document.buffer, 1);
    const first = try Projection.create(document);
    defer first.destroy();
    const second = try Projection.create(document);
    defer second.destroy();
    select(first.buffer, 2, 1);
    c.gtk_text_buffer_begin_user_action(first.buffer);
    c.gtk_text_buffer_begin_user_action(first.buffer);
    _ = c.gtk_text_buffer_delete_selection(first.buffer, 1, 1);
    c.gtk_text_buffer_insert_at_cursor(first.buffer, "é🌱", -1);
    c.gtk_text_buffer_end_user_action(first.buffer);
    c.gtk_text_buffer_end_user_action(first.buffer);
    try expectAll(document, first, second, "aé🌱c");
    c.gtk_text_buffer_undo(document.buffer);
    try expectAll(document, first, second, "abc");
    try testing.expectEqual(@as(c_int, 0), c.gtk_text_buffer_get_can_undo(document.buffer));
    c.gtk_text_buffer_redo(document.buffer);
    try expectAll(document, first, second, "aé🌱c");
    // Isolate the next history entry: GTK may coalesce adjacent native actions.
    c.gtk_text_buffer_set_enable_undo(document.buffer, 0);
    c.gtk_text_buffer_set_enable_undo(document.buffer, 1);
    // A transactional producer uses the canonical buffer, without any view bridge.
    c.gtk_text_buffer_begin_user_action(document.buffer);
    insert(document.buffer, 0, "[");
    insert(document.buffer, 5, "]");
    c.gtk_text_buffer_end_user_action(document.buffer);
    try expectAll(document, first, second, "[aé🌱c]");
    c.gtk_text_buffer_undo(document.buffer);
    try expectAll(document, first, second, "aé🌱c");
}

test "prepared canonical transactions and their undo update every projection" {
    const transactions = @import("transactions.zig");
    const document = try Document.create(906, null);
    defer document.destroy();
    c.gtk_text_buffer_set_text(document.buffer, "one é two", -1);
    c.gtk_text_buffer_set_enable_undo(document.buffer, 0);
    c.gtk_text_buffer_set_enable_undo(document.buffer, 1);
    const first = try Projection.create(document);
    defer first.destroy();
    const second = try Projection.create(document);
    defer second.destroy();
    const target: transactions.Target = .{
        .id = document.id,
        .buffer = document.buffer,
        .revision = &document.revision,
        .expected_revision = document.revision,
    };
    var prepared = try transactions.prepare(testing.allocator, &.{.{
        .target = target,
        .replacements = &.{
            .{ .start = 0, .end = 3, .text = "ONE" },
            .{ .start = 7, .end = 10, .text = "TWO" },
        },
    }}, .{});
    defer prepared.deinit();
    try prepared.commit(&.{target});
    try expectAll(document, first, second, "ONE é TWO");
    c.gtk_text_buffer_undo(document.buffer);
    try expectAll(document, first, second, "one é two");
    c.gtk_text_buffer_redo(document.buffer);
    try expectAll(document, first, second, "ONE é TWO");
}

test "loading and explicit read-only reject mirror edits but accept canonical load" {
    const document = try Document.create(903, null);
    defer document.destroy();
    const first = try Projection.create(document);
    defer first.destroy();
    const second = try Projection.create(document);
    defer second.destroy();
    document.loading = true;
    insert(first.buffer, 0, "bad");
    insert(second.buffer, 0, "bad");
    c.gtk_text_buffer_set_text(document.buffer, "loaded", -1);
    try expectAll(document, first, second, "loaded");
    document.loading = false;
    first.editable = false;
    insert(first.buffer, 0, "bad");
    try expectAll(document, first, second, "loaded");
    insert(second.buffer, 0, "ok ");
    try expectAll(document, first, second, "ok loaded");
}

test "shared tag properties and initial incremental canonical annotations survive edits" {
    const document = try Document.create(904, null);
    defer document.destroy();
    c.gtk_text_buffer_set_text(document.buffer, "abc def", -1);
    var a: c.GtkTextIter = undefined;
    var b: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(document.buffer, &a, 1);
    c.gtk_text_buffer_get_iter_at_offset(document.buffer, &b, 3);
    c.gtk_text_buffer_apply_tag(document.buffer, document.tag, &a, &b);
    const first = try Projection.create(document);
    defer first.destroy();
    const second = try Projection.create(document);
    defer second.destroy();
    for ([_]*c.GtkTextBuffer{ first.buffer, second.buffer }) |buffer| {
        try testing.expectEqual(c.gtk_text_buffer_get_tag_table(document.buffer), c.gtk_text_buffer_get_tag_table(buffer));
        c.gtk_text_buffer_get_iter_at_offset(buffer, &a, 1);
        try testing.expect(c.gtk_text_iter_has_tag(&a, document.tag) != 0);
    }
    insert(first.buffer, 0, "Ω");
    c.gtk_text_buffer_get_iter_at_offset(document.buffer, &a, 2);
    c.gtk_text_buffer_get_iter_at_offset(document.buffer, &b, 3);
    c.gtk_text_buffer_remove_tag(document.buffer, document.tag, &a, &b);
    // Anonymous annotations must work too, including tags created after mirrors.
    const tag = c.gtk_text_buffer_create_tag(document.buffer, null, "weight", @as(c_int, 700), @as(?*anyopaque, null)).?;
    c.gtk_text_buffer_apply_tag(document.buffer, tag, &a, &b);
    for ([_]*c.GtkTextBuffer{ first.buffer, second.buffer }) |buffer| {
        c.gtk_text_buffer_get_iter_at_offset(buffer, &a, 2);
        try testing.expect(c.gtk_text_iter_has_tag(&a, document.tag) == 0);
        try testing.expect(c.gtk_text_iter_has_tag(&a, tag) != 0);
        c.gtk_text_buffer_get_iter_at_offset(buffer, &a, 3);
        try testing.expect(c.gtk_text_iter_has_tag(&a, document.tag) != 0);
    }
}

fn invalidateBeforeInsert(buffer: ?*c.GtkTextBuffer, _: ?*c.GtkTextIter, _: [*c]const u8, _: c_int, data: ?*anyopaque) callconv(.c) void {
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_bounds(buffer, &start, &end);
    c.gtk_text_buffer_remove_tag(buffer, u.cast(c.GtkTextTag, data.?), &start, &end);
}

test "canonical pre-edit spelling invalidation uses pre-edit mirror coordinates" {
    const document = try Document.create(907, null);
    defer document.destroy();
    c.gtk_text_buffer_set_text(document.buffer, "wrong", -1);
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_bounds(document.buffer, &start, &end);
    c.gtk_text_buffer_apply_tag(document.buffer, document.tag, &start, &end);
    const first = try Projection.create(document);
    defer first.destroy();
    // Matches App.newDocument's ordering: view, then spelling observers, then
    // additional split views. Both orders must preserve annotation coordinates.
    u.connect(document.buffer, "insert-text", &invalidateBeforeInsert, document.tag);
    defer _ = c.g_signal_handlers_disconnect_matched(document.buffer, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, document.tag);
    const second = try Projection.create(document);
    defer second.destroy();
    insert(first.buffer, 0, "prefix ");
    try expectAll(document, first, second, "prefix wrong");
    for ([_]*c.GtkTextBuffer{ document.buffer, first.buffer, second.buffer }) |buffer| {
        c.gtk_text_buffer_get_iter_at_offset(buffer, &start, 10);
        try testing.expect(c.gtk_text_iter_has_tag(&start, document.tag) == 0);
    }
}

fn annotateChanged(buffer: ?*c.GtkTextBuffer, data: ?*anyopaque) callconv(.c) void {
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_end_iter(buffer, &end);
    var start = end;
    _ = c.gtk_text_iter_backward_char(&start);
    c.gtk_text_buffer_apply_tag(buffer, u.cast(c.GtkTextTag, data.?), &start, &end);
}

fn cancelInsert(buffer: ?*c.GtkTextBuffer, _: ?*c.GtkTextIter, _: [*c]const u8, _: c_int, _: ?*anyopaque) callconv(.c) void {
    c.g_signal_stop_emission_by_name(buffer, "insert-text");
}

test "changed annotations flush pending deltas and cancelled canonical edits never reach mirrors" {
    const document = try Document.create(908, null);
    defer document.destroy();
    // This changed observer runs before either projection's changed observer.
    u.connect(document.buffer, "changed", &annotateChanged, document.tag);
    defer _ = c.g_signal_handlers_disconnect_matched(document.buffer, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, document.tag);
    const first = try Projection.create(document);
    defer first.destroy();
    const cancel_handler = c.g_signal_connect_data(document.buffer, "insert-text", @ptrCast(&cancelInsert), document.tag, null, 0);
    const second = try Projection.create(document);
    defer second.destroy();
    insert(first.buffer, 0, "cancelled");
    try expectAll(document, first, second, "");
    c.g_signal_handler_disconnect(document.buffer, cancel_handler);
    insert(second.buffer, 0, "aé🌱");
    try expectAll(document, first, second, "aé🌱");
    for ([_]*c.GtkTextBuffer{ document.buffer, first.buffer, second.buffer }) |buffer| {
        var at: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_offset(buffer, &at, 2);
        try testing.expect(c.gtk_text_iter_has_tag(&at, document.tag) != 0);
    }
}

test "detached projection buffers outlive document and no longer forward either way" {
    const document = try Document.create(905, null);
    const first = try Projection.create(document);
    const buffer = first.buffer;
    const canonical = document.buffer;
    _ = c.g_object_ref(buffer);
    defer c.g_object_unref(buffer);
    _ = c.g_object_ref(canonical);
    defer c.g_object_unref(canonical);
    c.gtk_text_buffer_begin_user_action(buffer);
    insert(buffer, 0, "before");
    first.detach(); // Also balances an in-flight user action.
    first.detach();
    document.destroy();
    first.destroy();
    c.gtk_text_buffer_end_user_action(buffer);
    insert(buffer, 0, "local ");
    try expectText(canonical, "before");
    insert(canonical, 0, "canonical ");
    try expectText(buffer, "local before");
}
