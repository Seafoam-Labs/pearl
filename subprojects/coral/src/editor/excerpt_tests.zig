const std = @import("std");
const t = std.testing;
const c = @import("../c.zig").c;
const ex = @import("excerpt.zig");
const F = @import("history_test_support.zig").Fixture;
const r = @import("history_test_support.zig").r;
fn expect(excerpt: *const ex.Excerpt, target: ?@import("transactions.zig").Target, text: []const u8) !void {
    const actual = try excerpt.text(t.allocator, target);
    defer t.allocator.free(actual);
    try t.expectEqualStrings(text, actual);
}
test "excerpt Unicode checked relative ranges and canonical undo" {
    var f: F = .{};
    f.init("head:aé🌱z:tail");
    defer f.deinit();
    var excerpt = try ex.Excerpt.init(t.allocator, f.target(1), .{ .start = 5, .end = 13 }, false, .{});
    defer excerpt.deinit();
    try expect(&excerpt, f.target(1), "aé🌱z");
    try t.expectError(error.InvalidBoundary, excerpt.replace(t.allocator, f.target(1), r(2, 3, "x")));
    try t.expectError(error.OutOfBounds, excerpt.replace(t.allocator, f.target(1), r(0, 9, "x")));
    try t.expectError(error.InvalidUtf8, excerpt.replace(t.allocator, f.target(1), r(0, 1, "\xff")));
    try excerpt.replace(t.allocator, f.target(1), r(1, 3, "Éé"));
    try f.expect("head:aÉé🌱z:tail");
    try expect(&excerpt, f.target(1), "aÉé🌱z");
    c.gtk_text_buffer_undo(f.buffer);
    try expect(&excerpt, f.target(1), "aé🌱z");
    try f.expect("head:aé🌱z:tail");
}

test "excerpt stable anchors track external changes at boundaries prefix and native undo" {
    var f: F = .{};
    f.init("pre[é🌱]post");
    defer f.deinit();
    var excerpt = try ex.Excerpt.init(t.allocator, f.target(1), .{ .start = 4, .end = 10 }, false, .{});
    defer excerpt.deinit();
    f.insert(0, "外");
    try expect(&excerpt, f.target(1), "é🌱");
    c.gtk_text_buffer_undo(f.buffer);
    try expect(&excerpt, f.target(1), "é🌱");
    f.insert(4, "<");
    try expect(&excerpt, f.target(1), "<é🌱");
    f.insert(7, ">");
    try expect(&excerpt, f.target(1), "<é🌱>");
    try excerpt.replace(t.allocator, f.target(1), r(1, 3, "E"));
    try f.expect("pre[<E🌱>]post");
    var prepared = try excerpt.prepare(t.allocator, f.target(1), &.{r(0, 0, "x")});
    defer prepared.deinit();
    const old = prepared.expectedRevision(0);
    f.insert(0, "new");
    var fresh = f.target(1);
    fresh.expected_revision = old;
    try t.expectError(error.StaleRevision, prepared.commit(&.{fresh}));
}

test "excerpt read-only live and historical boundaries and ordered multi-document result" {
    var a: F = .{};
    a.init("header AAA footer");
    defer a.deinit();
    var b: F = .{};
    b.init("other ββ end");
    defer b.deinit();
    var first = try ex.Excerpt.init(t.allocator, a.target(10), .{ .start = 7, .end = 10 }, false, .{});
    defer first.deinit();
    var second = try ex.Excerpt.init(t.allocator, b.target(20), .{ .start = 6, .end = 10 }, true, .{});
    defer second.deinit();
    var snapshot = try ex.Excerpt.snapshot(t.allocator, 10, "old AAA", .{});
    defer snapshot.deinit();
    const items = try ex.orderedText(t.allocator, &.{ &second, &first, &snapshot }, &.{ a.target(10), b.target(20) });
    defer ex.freeOrderedText(t.allocator, items, items.len);
    try t.expectEqual(@as(u64, 20), items[0].id);
    try t.expectEqualStrings("ββ", items[0].text);
    try t.expectEqual(@as(u64, 10), items[1].id);
    try t.expectEqualStrings("AAA", items[1].text);
    try t.expectEqualStrings("old AAA", items[2].text);
    try t.expectError(error.ReadOnly, second.replace(t.allocator, b.target(20), r(0, 2, "x")));
    try t.expectError(error.ReadOnly, snapshot.replace(t.allocator, null, r(0, 0, "x")));
    try t.expectError(error.OutOfBounds, first.replace(t.allocator, a.target(10), r(0, 4, "x")));
    var ro = a.target(10);
    ro.writable = false;
    try t.expectError(error.ReadOnly, first.replace(t.allocator, ro, r(0, 1, "x")));
    try expect(&first, ro, "AAA");
    try first.replace(t.allocator, a.target(10), r(0, 3, "new"));
    try a.expect("header new footer");
    try b.expect("other ββ end");
    try expect(&snapshot, null, "old AAA");
    try t.expectError(error.TargetMismatch, first.text(t.allocator, null));
}

fn allocations(a: std.mem.Allocator) !void {
    var f: F = .{};
    f.init("aé🌱z");
    defer f.deinit();
    var excerpt = try ex.Excerpt.init(a, f.target(1), .{ .start = 1, .end = 7 }, false, .{});
    defer excerpt.deinit();
    var snapshot = try ex.Excerpt.snapshot(a, 2, "old", .{});
    defer snapshot.deinit();
    const items = try ex.orderedText(a, &.{ &excerpt, &snapshot }, &.{f.target(1)});
    defer ex.freeOrderedText(a, items, items.len);
    excerpt.replace(a, f.target(1), r(0, 2, "E")) catch |err| {
        try f.expect("aé🌱z");
        return err;
    };
}
test "excerpt allocation failure cleanup never mutates canonical source" {
    try t.checkAllAllocationFailures(t.allocator, allocations, .{});
}

test "bounded excerpt reads validate freshness limits and actual objects without inspecting unrelated text" {
    var f: F = .{};
    f.init("[é\u{fffc}z]tail");
    defer f.deinit();
    var excerpt = try ex.Excerpt.init(t.allocator, f.target(1), .{ .start = 1, .end = 7 }, false, .{});
    defer excerpt.deinit();
    try expect(&excerpt, f.target(1), "é\u{fffc}z");
    var target = f.target(1);
    target.busy = true;
    try t.expectError(error.Busy, excerpt.text(t.allocator, target));
    target = f.target(1);
    target.expected_revision += 1;
    try t.expectError(error.StaleRevision, excerpt.text(t.allocator, target));
    excerpt.limits.max_buffer_bytes = 5;
    try t.expectError(error.LimitExceeded, excerpt.text(t.allocator, f.target(1)));
    excerpt.limits = .{};
    var at: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_end_iter(f.buffer, &at);
    _ = c.gtk_text_buffer_create_child_anchor(f.buffer, &at);
    try expect(&excerpt, f.target(1), "é\u{fffc}z");
    // Reads are bounded, but edits retain whole-document validation.
    try t.expectError(error.UnsupportedBufferContent, excerpt.map(t.allocator, f.target(1), &.{r(0, 0, "x")}));
    c.gtk_text_buffer_get_iter_at_offset(f.buffer, &at, 2);
    _ = c.gtk_text_buffer_create_child_anchor(f.buffer, &at);
    try t.expectError(error.UnsupportedBufferContent, excerpt.text(t.allocator, f.target(1)));
}

test "excerpt deleted anchors and closed source refuse safely with retained buffers" {
    var f: F = .{};
    f.init("[abc]");
    var excerpt = try ex.Excerpt.init(t.allocator, f.target(1), .{ .start = 1, .end = 4 }, false, .{});
    defer excerpt.deinit();
    c.gtk_text_buffer_delete_mark(f.buffer, excerpt.source.?.start);
    try t.expectError(error.InvalidAnchor, excerpt.text(t.allocator, f.target(1)));
    f.deinit();
    try t.expectError(error.TargetMismatch, excerpt.text(t.allocator, null));
}
