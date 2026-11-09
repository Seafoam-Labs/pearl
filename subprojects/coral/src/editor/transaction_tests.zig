const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const tx = @import("transactions.zig");
const testing = std.testing;

test "ordered native trace validates UTF8 character positions exact states and transient limits" {
    const F = @import("history_test_support.zig").Fixture;
    var f: F = .{};
    f.init("aé🌱z");
    defer f.deinit();
    const edits = [_]tx.CharacterEdit{
        .{ .start = 1, .end = 2, .text = "終" },
        .{ .start = 3, .end = 4, .text = "" },
        .{ .start = 0, .end = 0, .text = "!" },
    };
    try testing.expectError(error.SnapshotMismatch, tx.prepareSequence(testing.allocator, f.target(1), "wrong", "!a終🌱", &edits, .{}));
    try testing.expectError(error.SnapshotMismatch, tx.prepareSequence(testing.allocator, f.target(1), "aé🌱z", "wrong", &edits, .{}));
    try testing.expectError(error.OutOfBounds, tx.prepareSequence(testing.allocator, f.target(1), "aé🌱z", "", &.{.{ .start = 3, .end = 5, .text = "" }}, .{}));
    try testing.expectError(error.InvalidUtf8, tx.prepareSequence(testing.allocator, f.target(1), "aé🌱z", "", &.{.{ .start = 0, .end = 0, .text = "\xff" }}, .{}));
    try testing.expectError(error.LimitExceeded, tx.prepareSequence(testing.allocator, f.target(1), "aé🌱z", "!a終🌱", &edits, .{ .max_buffer_bytes = 8 }));
    try testing.expectError(error.LimitExceeded, tx.prepareSequence(testing.allocator, f.target(1), "aé🌱z", "!a終🌱", &edits, .{ .max_replacements = 2 }));
    try f.expect("aé🌱z");
    try testing.expectEqual(@as(u64, 0), f.revision);
    var plan = try tx.prepareSequence(testing.allocator, f.target(1), "aé🌱z", "!a終🌱", &edits, .{});
    defer plan.deinit();
    try plan.commit(&.{f.target(1)});
    try f.expect("!a終🌱");
}

test "bounded transaction source-cost probe (opt in)" {
    if (c.g_getenv("CORAL_TRANSACTION_PROBE") == null) return;
    const Excerpt = @import("excerpt.zig").Excerpt;
    const History = @import("history.zig").History;
    const text = try testing.allocator.alloc(u8, 65536);
    defer testing.allocator.free(text);
    var line: [64]u8 = @splat(' ');
    _ = try std.fmt.bufPrint(line[0..63], "// {d:0>3} const café = \"λ🌱\"; // deterministic", .{0});
    line[63] = '\n';
    for (text, 0..) |*byte, i| byte.* = line[i % line.len];
    var fixtures: [3]Fixture = .{ .{}, .{}, .{} };
    for (&fixtures) |*f| f.initKind(text, true);
    defer for (&fixtures) |*f| f.deinit();
    const language = c.gtk_source_language_manager_get_language(c.gtk_source_language_manager_get_default(), "c");
    for (&fixtures) |*f| c.gtk_source_buffer_set_language(u.cast(c.GtkSourceBuffer, f.buffer), language);
    while (c.g_main_context_iteration(null, 0) != 0) {}
    var excerpts: [3]Excerpt = undefined;
    for (&fixtures, &excerpts, 0..) |*f, *e, i| e.* = try Excerpt.init(testing.allocator, f.target(i + 1), .{ .start = i * 1920, .end = i * 1920 + 1280 }, false, .{});
    defer for (&excerpts) |*e| e.deinit();
    var history = History.init(testing.allocator, .{});
    defer history.deinit();
    var totals: [6]i64 = @splat(0);
    for (0..12) |_| {
        var mapped: [3]@import("excerpt.zig").Mapped = undefined;
        var changes: [3]tx.Change = undefined;
        var targets: [3]tx.Target = undefined;
        var start = c.g_get_monotonic_time();
        for (&fixtures, &excerpts, &mapped, &changes, &targets, 0..) |*f, *e, *m, *change, *target, i| {
            target.* = f.target(i + 1);
            m.* = try e.map(testing.allocator, target.*, &.{replace(20, 20, "Ω")});
            change.* = m.change;
        }
        defer for (&mapped) |*m| m.deinit();
        totals[0] += c.g_get_monotonic_time() - start;
        start = c.g_get_monotonic_time();
        var pending = try history.prepare("probe", &changes);
        defer pending.deinit();
        totals[1] += c.g_get_monotonic_time() - start;
        start = c.g_get_monotonic_time();
        try history.commit(&pending, &targets);
        totals[2] += c.g_get_monotonic_time() - start;
        start = c.g_get_monotonic_time();
        while (c.g_main_context_iteration(null, 0) != 0) {}
        totals[4] += c.g_get_monotonic_time() - start;
        for (&fixtures, &targets, 0..) |*f, *target, i| target.* = f.target(i + 1);
        start = c.g_get_monotonic_time();
        try history.undo(&targets);
        totals[3] += c.g_get_monotonic_time() - start;
        start = c.g_get_monotonic_time();
        while (c.g_main_context_iteration(null, 0) != 0) {}
        totals[5] += c.g_get_monotonic_time() - start;
    }
    std.debug.print("\nTRANSACTION_PROBE three_64KiB_C mean_us map={d} history_prepare={d} commit={d} undo={d} edit_drain={d} undo_drain={d}\n", .{ @divTrunc(totals[0], 12), @divTrunc(totals[1], 12), @divTrunc(totals[2], 12), @divTrunc(totals[3], 12), @divTrunc(totals[4], 12), @divTrunc(totals[5], 12) });
}

test "bounded giant UTF8 snapshot source-cost probe (opt in)" {
    if (c.g_getenv("CORAL_GIANT_PROBE") == null) return;
    const Excerpt = @import("excerpt.zig").Excerpt;
    const History = @import("history.zig").History;
    for ([_]usize{ 65536, 262144, 1048576 }) |size| {
        const text = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(text);
        var line: [64]u8 = @splat(' ');
        _ = try std.fmt.bufPrint(&line, "// 000 const café = \"λ🌱\"; // deterministic", .{});
        for (text, 0..) |*byte, i| byte.* = line[i % line.len];
        var f: Fixture = .{};
        f.initKind(text, true);
        defer f.deinit();
        var excerpt = try Excerpt.init(testing.allocator, f.target(1), .{ .start = size / 2, .end = size / 2 + 2048 }, false, .{});
        defer excerpt.deinit();
        var history = History.init(testing.allocator, .{});
        defer history.deinit();
        var times: [4]i64 = @splat(0);
        for (0..3) |_| {
            var start = c.g_get_monotonic_time();
            var mapped = try excerpt.map(testing.allocator, f.target(1), &.{replace(20, 20, "Ω")});
            defer mapped.deinit();
            times[0] += c.g_get_monotonic_time() - start;
            start = c.g_get_monotonic_time();
            var pending = try history.prepare("giant probe", &.{mapped.change});
            defer pending.deinit();
            times[1] += c.g_get_monotonic_time() - start;
            start = c.g_get_monotonic_time();
            try history.commit(&pending, &.{f.target(1)});
            times[2] += c.g_get_monotonic_time() - start;
            start = c.g_get_monotonic_time();
            try history.undo(&.{f.target(1)});
            times[3] += c.g_get_monotonic_time() - start;
        }
        try f.expect(text);
        std.debug.print("\nGIANT_PROBE bytes={d} mean_us map={d} prepare={d} commit={d} undo={d}\n", .{ size, @divTrunc(times[0], 3), @divTrunc(times[1], 3), @divTrunc(times[2], 3), @divTrunc(times[3], 3) });
    }
}

test "transaction: bulk slices preserve Unicode hidden text limits and late full-target defenses" {
    var storage: [32782]u8 = undefined;
    @memset(storage[0..16383], 'a');
    @memcpy(storage[16383..16392], "🌱\u{fffc}é");
    @memset(storage[16392..32776], 'b');
    @memcpy(storage[32776..], "\u{fffc}終");
    const text: []const u8 = &storage;
    var first: Fixture = .{};
    first.init("untouched");
    defer first.deinit();
    var f: Fixture = .{};
    f.init(text);
    defer f.deinit();
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_bounds(f.buffer, &start, &end);
    const tag = c.gtk_text_buffer_create_tag(f.buffer, null, "invisible", @as(c_int, 1), @as(?*anyopaque, null));
    c.gtk_text_buffer_apply_tag(f.buffer, tag, &start, &end);
    try testing.expectError(error.LimitExceeded, tx.readRange(testing.allocator, f.buffer, start, end, text.len - 1));
    const read = try tx.readRange(testing.allocator, f.buffer, start, end, text.len);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings(text, read);
    try testing.expectError(error.OutOfBounds, tx.readRange(testing.allocator, f.buffer, end, start, text.len));
    try testing.expectError(error.TargetMismatch, tx.readRange(testing.allocator, first.buffer, start, end, text.len));
    var plan = try tx.prepare(testing.allocator, &.{
        .{ .target = first.target(1), .replacements = &.{replace(0, 1, "X")} },
        .{ .target = f.target(2), .replacements = &.{replace(0, 1, "Y")} },
    }, .{});
    defer plan.deinit();
    // Same-length mutation after the second chunk; no revision notification.
    c.gtk_text_buffer_get_iter_at_offset(f.buffer, &start, 32771);
    end = start;
    _ = c.gtk_text_iter_forward_char(&end);
    c.gtk_text_buffer_delete(f.buffer, &start, &end);
    c.gtk_text_buffer_insert(f.buffer, &start, "Z", 1);
    f.revision = 0;
    try testing.expectError(error.SnapshotMismatch, plan.commit(&.{ first.target(1), f.target(2) }));
    try first.expectUntouched("untouched");
    c.gtk_text_buffer_set_text(f.buffer, text.ptr, @intCast(text.len));
    f.revision = 0;
    // An object must not compare equal to literal U+FFFC in the saved snapshot.
    c.gtk_text_buffer_get_iter_at_offset(f.buffer, &start, 16384);
    end = start;
    _ = c.gtk_text_iter_forward_char(&end);
    c.gtk_text_buffer_delete(f.buffer, &start, &end);
    _ = c.gtk_text_buffer_create_child_anchor(f.buffer, &start);
    f.revision = 0;
    try testing.expectError(error.SnapshotMismatch, plan.commit(&.{ first.target(1), f.target(2) }));
    try first.expectUntouched("untouched");
    try testing.expectError(error.UnsupportedBufferContent, tx.prepare(testing.allocator, &.{.{ .target = f.target(2), .replacements = &.{} }}, .{}));
}

test "transaction: bounded byte sizing agrees with all multiline Unicode subranges" {
    const text = "é\r\n🌱\u{2029}x\u{fffc}\n終";
    var f: Fixture = .{};
    f.init(text);
    defer f.deinit();
    var start_byte: usize = 0;
    var start_char: c_int = 0;
    while (true) : (start_char += 1) {
        var end_byte = start_byte;
        var end_char = start_char;
        while (true) : (end_char += 1) {
            var start: c.GtkTextIter = undefined;
            var end: c.GtkTextIter = undefined;
            c.gtk_text_buffer_get_iter_at_offset(f.buffer, &start, start_char);
            c.gtk_text_buffer_get_iter_at_offset(f.buffer, &end, end_char);
            const expected = text[start_byte..end_byte];
            const actual = try tx.readRange(testing.allocator, f.buffer, start, end, expected.len);
            defer testing.allocator.free(actual);
            try testing.expectEqualStrings(expected, actual);
            if (expected.len != 0) try testing.expectError(error.LimitExceeded, tx.readRange(testing.allocator, f.buffer, start, end, expected.len - 1));
            if (end_byte == text.len) break;
            end_byte += try std.unicode.utf8ByteSequenceLength(text[end_byte]);
        }
        if (start_byte == text.len) break;
        start_byte += try std.unicode.utf8ByteSequenceLength(text[start_byte]);
    }
}

test "transaction: reverse giant UTF8 reads preserve hidden text and reject head middle tail and object substitutions" {
    const pattern = "aé🌱b\u{fffc}12345";
    const text = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(text);
    for (text, 0..) |*byte, i| byte.* = pattern[i % pattern.len];
    var first: Fixture = .{};
    first.init("untouched");
    defer first.deinit();
    var f: Fixture = .{};
    f.init(text);
    defer f.deinit();
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_bounds(f.buffer, &start, &end);
    const hidden = c.gtk_text_buffer_create_tag(f.buffer, null, "invisible", @as(c_int, 1), @as(?*anyopaque, null));
    c.gtk_text_buffer_apply_tag(f.buffer, hidden, &start, &end);
    // Marks split the underlying UTF-8 segments without changing any bytes.
    c.gtk_text_buffer_get_iter_at_offset(f.buffer, &start, 12345);
    const mark = c.gtk_text_buffer_create_mark(f.buffer, null, &start, 0).?;
    defer c.gtk_text_buffer_delete_mark(f.buffer, mark);
    var plan = try tx.prepare(testing.allocator, &.{
        .{ .target = first.target(1), .replacements = &.{replace(0, 1, "X")} },
        .{ .target = f.target(2), .replacements = &.{replace(0, 1, "B")} },
    }, .{});
    defer plan.deinit();
    try testing.expectEqualStrings(text, plan.before(1));
    for ([_]c_int{ 0, 327680, 655350 }) |position| {
        c.gtk_text_buffer_get_iter_at_offset(f.buffer, &start, position);
        end = start;
        _ = c.gtk_text_iter_forward_char(&end);
        c.gtk_text_buffer_delete(f.buffer, &start, &end);
        c.gtk_text_buffer_insert(f.buffer, &start, "A", 1);
        f.revision = 0;
        try testing.expectError(error.SnapshotMismatch, plan.commit(&.{ first.target(1), f.target(2) }));
        try first.expectUntouched("untouched");
        c.gtk_text_buffer_set_text(f.buffer, text.ptr, @intCast(text.len));
        f.revision = 0;
    }
    for ([_]bool{ false, true }) |paintable| {
        c.gtk_text_buffer_get_iter_at_offset(f.buffer, &start, 327684);
        end = start;
        _ = c.gtk_text_iter_forward_char(&end);
        c.gtk_text_buffer_delete(f.buffer, &start, &end);
        if (paintable) {
            const pixel = [_]u8{ 0, 0, 0, 255 };
            const bytes = c.g_bytes_new(&pixel, pixel.len).?;
            defer c.g_bytes_unref(bytes);
            const texture = c.gdk_memory_texture_new(1, 1, c.GDK_MEMORY_R8G8B8A8, bytes, 4).?;
            defer c.g_object_unref(texture);
            c.gtk_text_buffer_insert_paintable(f.buffer, &start, u.cast(c.GdkPaintable, texture));
        } else _ = c.gtk_text_buffer_create_child_anchor(f.buffer, &start);
        f.revision = 0;
        try testing.expectError(error.SnapshotMismatch, plan.commit(&.{ first.target(1), f.target(2) }));
        try testing.expectError(error.UnsupportedBufferContent, tx.prepare(testing.allocator, &.{.{ .target = f.target(2), .replacements = &.{} }}, .{}));
        try first.expectUntouched("untouched");
        c.gtk_text_buffer_set_text(f.buffer, text.ptr, @intCast(text.len));
        f.revision = 0;
    }
    try plan.commit(&.{ first.target(1), f.target(2) });
    c.gtk_text_buffer_undo(f.buffer);
    try f.expect(text);
}

const Fixture = struct {
    buffer: *c.GtkTextBuffer = undefined,
    revision: u64 = 0,

    fn init(self: *Fixture, text: []const u8) void {
        self.initKind(text, false);
    }

    fn initKind(self: *Fixture, text: []const u8, source: bool) void {
        // No gtk_init, display, view, or application is needed for buffers.
        c.gtk_source_init();
        self.buffer = if (source) u.cast(c.GtkTextBuffer, c.gtk_source_buffer_new(null).?) else c.gtk_text_buffer_new(null).?;
        c.gtk_text_buffer_set_enable_undo(self.buffer, 0);
        c.gtk_text_buffer_set_text(self.buffer, text.ptr, @intCast(text.len));
        c.gtk_text_buffer_set_enable_undo(self.buffer, 1);
        c.gtk_text_buffer_set_modified(self.buffer, 0);
        u.connect(self.buffer, "changed", &changed, self);
    }

    fn deinit(self: *Fixture) void {
        c.g_object_unref(self.buffer);
    }

    fn changed(_: ?*c.GtkTextBuffer, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Fixture, data.?);
        self.revision += 1;
    }

    fn target(self: *Fixture, id: u64) tx.Target {
        return .{ .id = id, .buffer = self.buffer, .revision = &self.revision, .expected_revision = self.revision };
    }

    fn expect(self: *Fixture, text: []const u8) !void {
        const actual = u.bufferText(self.buffer);
        defer u.a.free(actual);
        try testing.expectEqualStrings(text, actual);
    }

    fn expectUntouched(self: *Fixture, text: []const u8) !void {
        try self.expect(text);
        try testing.expectEqual(@as(u64, 0), self.revision);
        try testing.expectEqual(@as(c_int, 0), c.gtk_text_buffer_get_modified(self.buffer));
        try testing.expectEqual(@as(c_int, 0), c.gtk_text_buffer_get_can_undo(self.buffer));
    }
};

fn replace(start: usize, end: usize, text: []const u8) tx.Replacement {
    return .{ .start = start, .end = end, .text = text };
}

fn expectRejected(expected: anyerror, text: []const u8, replacements: []const tx.Replacement, limits: tx.Limits) !void {
    var first: Fixture = .{};
    first.init("first");
    defer first.deinit();
    var second: Fixture = .{};
    second.init(text);
    defer second.deinit();
    try testing.expectError(expected, tx.prepare(testing.allocator, &.{
        .{ .target = first.target(1), .replacements = &.{replace(0, 5, "would change")} },
        .{ .target = second.target(2), .replacements = replacements },
    }, limits));
    try first.expectUntouched("first");
    try second.expectUntouched(text);
}

test "transaction: all targets validate before mutation, ranges, Unicode boundaries and replacement encoding" {
    try expectRejected(error.OutOfBounds, "abc", &.{replace(2, 1, "")}, .{});
    try expectRejected(error.OutOfBounds, "abc", &.{replace(0, 4, "")}, .{});
    try expectRejected(error.OutOfBounds, "abc", &.{replace(std.math.maxInt(usize), std.math.maxInt(usize), "")}, .{});
    try expectRejected(error.InvalidBoundary, "aé🌱z", &.{replace(2, 3, "")}, .{});
    try expectRejected(error.InvalidBoundary, "aé🌱z", &.{replace(3, 5, "")}, .{});
    for ([_][]const u8{ "\xff", "\xc0\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe2\x82" }) |bad| {
        try expectRejected(error.InvalidUtf8, "abc", &.{replace(0, 1, bad)}, .{});
    }
    try expectRejected(error.EmbeddedNul, "abc", &.{replace(0, 1, "x\x00y")}, .{});
}

test "transaction: duplicates, nested overlaps and same-position inserts are rejected in either order" {
    try expectRejected(error.DuplicateRange, "abcdef", &.{ replace(1, 3, "x"), replace(1, 3, "y") }, .{});
    try expectRejected(error.OverlappingRanges, "abcdef", &.{ replace(2, 4, "x"), replace(1, 3, "y") }, .{});
    try expectRejected(error.OverlappingRanges, "abcdef", &.{ replace(0, 6, "x"), replace(1, 2, "y") }, .{});
    try expectRejected(error.OverlappingRanges, "abcdef", &.{ replace(0, 6, "x"), replace(3, 3, "y") }, .{});
    try expectRejected(error.AmbiguousInsertion, "abcdef", &.{ replace(2, 2, "x"), replace(2, 2, "y") }, .{});
    try expectRejected(error.AmbiguousInsertion, "abcdef", &.{ replace(2, 2, "x"), replace(2, 4, "y") }, .{});
    try expectRejected(error.AmbiguousInsertion, "abcdef", &.{ replace(2, 4, "y"), replace(2, 2, "x") }, .{});
}

test "transaction: duplicate IDs, buffers and revision sources are rejected" {
    var a: Fixture = .{};
    a.init("abc");
    defer a.deinit();
    var b: Fixture = .{};
    b.init("abc");
    defer b.deinit();
    const target = a.target(1);
    const duplicates = [_]tx.Target{
        b.target(1),
        .{ .id = 2, .buffer = a.buffer, .revision = &b.revision, .expected_revision = 0 },
        .{ .id = 2, .buffer = b.buffer, .revision = &a.revision, .expected_revision = 0 },
    };
    for (duplicates) |duplicate| {
        try testing.expectError(error.DuplicateTarget, tx.prepare(testing.allocator, &.{
            .{ .target = target, .replacements = &.{replace(0, 1, "x")} },
            .{ .target = duplicate, .replacements = &.{} },
        }, .{}));
    }
    try a.expectUntouched("abc");
    try b.expectUntouched("abc");
}

test "transaction: stale, busy and read-only prepare reject a whole batch" {
    var a: Fixture = .{};
    a.init("abc");
    defer a.deinit();
    var b: Fixture = .{};
    b.init("def");
    defer b.deinit();
    for (0..3) |case| {
        var target = b.target(2);
        const expected: tx.ValidationError = switch (case) {
            0 => blk: {
                target.expected_revision = 1;
                break :blk error.StaleRevision;
            },
            1 => blk: {
                target.busy = true;
                break :blk error.Busy;
            },
            else => blk: {
                target.writable = false;
                break :blk error.ReadOnly;
            },
        };
        try testing.expectError(expected, tx.prepare(testing.allocator, &.{
            .{ .target = a.target(1), .replacements = &.{replace(0, 1, "x")} },
            .{ .target = target, .replacements = &.{} },
        }, .{}));
    }
    try a.expectUntouched("abc");
    try b.expectUntouched("def");
}

test "transaction: descending unsorted edits use Unicode bytes, not UTF16 or character offsets" {
    var a: Fixture = .{};
    a.init("aé🌱z\ne\u{301}");
    defer a.deinit();
    var b: Fixture = .{};
    b.init("");
    defer b.deinit();
    var plan = try tx.prepare(testing.allocator, &.{
        .{ .target = a.target(7), .replacements = &.{
            replace(7, 8, "終"),
            replace(1, 3, "Éé"),
            replace(9, 10, "E"),
            replace(3, 7, "🚀"),
            replace(12, 12, "!"),
        } },
        .{ .target = b.target(8), .replacements = &.{replace(0, 0, "新\n")} },
    }, .{});
    defer plan.deinit();
    try testing.expectEqual(@as(usize, 2), plan.targetCount());
    try testing.expectEqual(@as(u64, 7), plan.targetId(0));
    try testing.expectEqual(@as(u64, 0), plan.expectedRevision(0));
    try testing.expectEqualStrings("aé🌱z\ne\u{301}", plan.before(0));
    try testing.expectEqual(@as(usize, 5), plan.replacementCount(0));
    try testing.expectEqual(@as(usize, 1), plan.replacement(0, 0).start);
    try a.expectUntouched("aé🌱z\ne\u{301}");
    // Fresh targets need not use the preparation order.
    try plan.commit(&.{ b.target(8), a.target(7) });
    try a.expect("aÉé🚀終\nE\u{301}!");
    try b.expect("新\n");
    try testing.expect(a.revision > 0 and b.revision > 0);
    try testing.expectError(error.AlreadyCommitted, plan.commit(&.{ a.target(7), b.target(8) }));
}

test "transaction: adjacent deletes preserve offsets" {
    var f: Fixture = .{};
    f.init("abcdef");
    defer f.deinit();
    var plan = try tx.prepare(testing.allocator, &.{.{ .target = f.target(1), .replacements = &.{
        replace(2, 4, ""), replace(0, 2, ""),
    } }}, .{});
    defer plan.deinit();
    try plan.commit(&.{f.target(1)});
    try f.expect("ef");
}

test "transaction: insertion at range end is deterministic" {
    var f: Fixture = .{};
    f.init("abcdef");
    defer f.deinit();
    var plan = try tx.prepare(testing.allocator, &.{.{ .target = f.target(1), .replacements = &.{
        replace(2, 2, "X"), replace(0, 2, "Y"), replace(4, 6, ""),
    } }}, .{});
    defer plan.deinit();
    try plan.commit(&.{f.target(1)});
    try f.expect("YXcd");
}

test "transaction: commit rechecks stale revisions even after edit and undo restore identical text" {
    var a: Fixture = .{};
    a.init("abc");
    defer a.deinit();
    var b: Fixture = .{};
    b.init("def");
    defer b.deinit();
    const original_b = b.target(2);
    var plan = try tx.prepare(testing.allocator, &.{
        .{ .target = a.target(1), .replacements = &.{replace(0, 1, "X")} },
        .{ .target = original_b, .replacements = &.{replace(0, 1, "Y")} },
    }, .{});
    defer plan.deinit();
    c.gtk_text_buffer_insert_at_cursor(b.buffer, "!", 1);
    c.gtk_text_buffer_undo(b.buffer);
    try b.expect("def");
    try testing.expect(b.revision > original_b.expected_revision);
    var current_b = b.target(2);
    current_b.expected_revision = original_b.expected_revision;
    try testing.expectError(error.StaleRevision, plan.commit(&.{ a.target(1), current_b }));
    try a.expectUntouched("abc");
    try b.expect("def");
}

test "transaction: commit rechecks policy for ALL buffers and can retry validation failures" {
    var a: Fixture = .{};
    a.init("abc");
    defer a.deinit();
    var b: Fixture = .{};
    b.init("def");
    defer b.deinit();
    var plan = try tx.prepare(testing.allocator, &.{
        .{ .target = a.target(1), .replacements = &.{replace(0, 1, "X")} },
        .{ .target = b.target(2), .replacements = &.{replace(0, 1, "Y")} },
    }, .{});
    defer plan.deinit();
    var target = b.target(2);
    target.busy = true;
    try testing.expectError(error.Busy, plan.commit(&.{ a.target(1), target }));
    target.busy = false;
    target.writable = false;
    try testing.expectError(error.ReadOnly, plan.commit(&.{ a.target(1), target }));
    try a.expectUntouched("abc");
    try b.expectUntouched("def");
    try plan.commit(&.{ a.target(1), b.target(2) });
    try a.expect("Xbc");
    try b.expect("Yef");
}

test "transaction: equal text and revision do not substitute for document and buffer identity" {
    var original: Fixture = .{};
    original.init("abc");
    defer original.deinit();
    var other: Fixture = .{};
    other.init("abc");
    defer other.deinit();
    var plan = try tx.prepare(testing.allocator, &.{.{ .target = original.target(1), .replacements = &.{replace(0, 1, "X")} }}, .{});
    defer plan.deinit();
    try testing.expectError(error.TargetMismatch, plan.commit(&.{}));
    try testing.expectError(error.TargetMismatch, plan.commit(&.{other.target(1)}));
    var target = original.target(2);
    try testing.expectError(error.TargetMismatch, plan.commit(&.{target}));
    target = original.target(1);
    target.revision = &other.revision;
    try testing.expectError(error.TargetMismatch, plan.commit(&.{target}));
    target = original.target(1);
    target.expected_revision = 1;
    try testing.expectError(error.TargetMismatch, plan.commit(&.{target}));
    try original.expectUntouched("abc");
    try other.expectUntouched("abc");
}

test "transaction: duplicate or extra live targets cannot hide a missing target" {
    var a: Fixture = .{};
    a.init("abc");
    defer a.deinit();
    var b: Fixture = .{};
    b.init("def");
    defer b.deinit();
    var plan = try tx.prepare(testing.allocator, &.{
        .{ .target = a.target(1), .replacements = &.{replace(0, 1, "X")} },
        .{ .target = b.target(2), .replacements = &.{} },
    }, .{});
    defer plan.deinit();
    try testing.expectError(error.DuplicateTarget, plan.commit(&.{ a.target(1), a.target(1) }));
    try testing.expectError(error.TargetMismatch, plan.commit(&.{ a.target(1), b.target(3) }));
    try testing.expectError(error.TargetMismatch, plan.commit(&.{ a.target(1), b.target(2), b.target(3) }));
    try a.expectUntouched("abc");
    try b.expectUntouched("def");
}

test "transaction: commit snapshot defense detects missed revision notifications" {
    var f: Fixture = .{};
    f.init("abc");
    defer f.deinit();
    var plan = try tx.prepare(testing.allocator, &.{.{ .target = f.target(1), .replacements = &.{replace(0, 1, "X")} }}, .{});
    defer plan.deinit();
    c.gtk_text_buffer_insert_at_cursor(f.buffer, "!", 1);
    f.revision = 0; // Deliberately simulate a broken owner.
    try testing.expectError(error.SnapshotMismatch, plan.commit(&.{f.target(1)}));
    try f.expect("abc!");
}

test "transaction: per-buffer single-step undo redo preserve existing undo history, marks and tags" {
    for ([_]bool{ false, true }) |source| {
        var a: Fixture = .{};
        a.initKind("abcdef", source);
        defer a.deinit();
        var b: Fixture = .{};
        b.initKind("1234", source);
        defer b.deinit();
        c.gtk_text_buffer_begin_user_action(a.buffer);
        c.gtk_text_buffer_insert_at_cursor(a.buffer, "!", 1);
        c.gtk_text_buffer_end_user_action(a.buffer);
        var iter: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_offset(a.buffer, &iter, 3);
        const mark = c.gtk_text_buffer_create_mark(a.buffer, "transaction-survivor", &iter, 1).?;
        const tag = c.gtk_text_buffer_create_tag(a.buffer, "transaction-tag", @as(?[*:0]const u8, null)).?;
        c.gtk_text_buffer_get_iter_at_offset(a.buffer, &end, 4);
        c.gtk_text_buffer_apply_tag(a.buffer, tag, &iter, &end);
        var plan = try tx.prepare(testing.allocator, &.{
            .{ .target = a.target(1), .replacements = &.{ replace(0, 1, "XX"), replace(5, 6, "Z") } },
            .{ .target = b.target(2), .replacements = &.{ replace(0, 1, "A"), replace(3, 4, "B") } },
        }, .{});
        defer plan.deinit();
        try plan.commit(&.{ a.target(1), b.target(2) });
        try a.expect("XXbcdeZ!");
        try b.expect("A23B");
        try testing.expectEqual(@as(c_int, 0), c.gtk_text_mark_get_deleted(mark));
        c.gtk_text_buffer_get_iter_at_mark(a.buffer, &iter, mark);
        try testing.expectEqual(@as(c_int, 4), c.gtk_text_iter_get_offset(&iter));
        try testing.expect(c.gtk_text_iter_has_tag(&iter, tag) != 0);
        c.gtk_text_buffer_undo(a.buffer);
        try a.expect("abcdef!");
        try b.expect("A23B"); // Not a global undo stack.
        c.gtk_text_buffer_undo(b.buffer);
        try b.expect("1234");
        c.gtk_text_buffer_redo(a.buffer);
        c.gtk_text_buffer_redo(b.buffer);
        try a.expect("XXbcdeZ!");
        try b.expect("A23B");
        c.gtk_text_buffer_undo(a.buffer);
        c.gtk_text_buffer_undo(a.buffer);
        try a.expect("abcdef");
    }
}

test "transaction: empty transactions, empty edits and identical replacements leave history untouched" {
    var empty = try tx.prepare(testing.allocator, &.{}, .{});
    defer empty.deinit();
    try empty.commit(&.{});
    var f: Fixture = .{};
    f.init("abc");
    defer f.deinit();
    for ([_][]const tx.Replacement{ &.{}, &.{replace(0, 3, "abc")}, &.{replace(3, 3, "")} }) |edits| {
        var plan = try tx.prepare(testing.allocator, &.{.{ .target = f.target(1), .replacements = edits }}, .{});
        defer plan.deinit();
        try plan.commit(&.{f.target(1)});
        try f.expectUntouched("abc");
    }
}

test "transaction: caps bound targets, operations, bytes, Unicode and transient growth" {
    try expectRejected(error.LimitExceeded, "abc", &.{}, .{ .max_targets = 1 });
    try expectRejected(error.LimitExceeded, "abc", &.{replace(0, 0, "")}, .{ .max_replacements = 1 });
    try expectRejected(error.LimitExceeded, "abcdefghijkl", &.{}, .{ .max_buffer_bytes = 11 });
    try expectRejected(error.LimitExceeded, "🌱🌱🌱", &.{}, .{ .max_buffer_bytes = 11 });
    try expectRejected(error.LimitExceeded, "abc", &.{replace(0, 0, "abcdefghijkl")}, .{ .max_buffer_bytes = 11 });
    try expectRejected(error.LimitExceeded, "abc", &.{}, .{ .max_total_bytes = 18 });
    var f: Fixture = .{};
    f.init("abcdef");
    defer f.deinit();
    // Final size is 6, but descending application temporarily needs 9 bytes.
    try testing.expectError(error.LimitExceeded, tx.prepare(testing.allocator, &.{.{ .target = f.target(1), .replacements = &.{
        replace(0, 3, ""), replace(6, 6, "XYZ"),
    } }}, .{ .max_buffer_bytes = 6 }));
    try f.expectUntouched("abcdef");
    // Exact inclusive limits succeed.
    var plan = try tx.prepare(testing.allocator, &.{.{ .target = f.target(1), .replacements = &.{replace(0, 6, "🌱")} }}, .{
        .max_buffer_bytes = 6,
        .max_total_bytes = 10,
        .max_targets = 1,
        .max_replacements = 1,
    });
    defer plan.deinit();
    try plan.commit(&.{f.target(1)});
    try f.expect("🌱");
}

test "transaction: snapshots include invisible text and reject actual embedded GTK objects" {
    var f: Fixture = .{};
    f.init("aéz\u{fffc}");
    defer f.deinit();
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_bounds(f.buffer, &start, &end);
    const tag = c.gtk_text_buffer_create_tag(f.buffer, "hidden", "invisible", @as(c_int, 1), @as(?[*:0]const u8, null)).?;
    c.gtk_text_buffer_apply_tag(f.buffer, tag, &start, &end);
    var plan = try tx.prepare(testing.allocator, &.{.{ .target = f.target(1), .replacements = &.{replace(1, 3, "X")} }}, .{});
    defer plan.deinit();
    try testing.expectEqualStrings("aéz\u{fffc}", plan.before(0));
    try plan.commit(&.{f.target(1)});
    try f.expect("aXz\u{fffc}");
    c.gtk_text_buffer_get_end_iter(f.buffer, &end);
    _ = c.gtk_text_buffer_create_child_anchor(f.buffer, &end);
    try testing.expectError(error.UnsupportedBufferContent, tx.prepare(testing.allocator, &.{.{ .target = f.target(1), .replacements = &.{} }}, .{}));
}

test "transaction: prepared edits own their replacement inputs" {
    var f: Fixture = .{};
    f.init("abc");
    defer f.deinit();
    var input = [_]u8{'X'};
    var edits = [_]tx.Replacement{replace(0, 1, &input)};
    var plan = try tx.prepare(testing.allocator, &.{.{ .target = f.target(1), .replacements = &edits }}, .{});
    defer plan.deinit();
    input[0] = 'Y';
    edits[0] = replace(1, 2, "Z");
    try plan.commit(&.{f.target(1)});
    try f.expect("Xbc");
}

test "transaction: prepared snapshots retain buffers but cannot commit a closed document" {
    var finalized = false;
    var f: Fixture = .{};
    f.init("abc");
    var owner_held = true;
    defer if (owner_held) f.deinit();
    c.g_object_weak_ref(@ptrCast(f.buffer), &struct {
        fn notify(data: ?*anyopaque, _: ?*c.GObject) callconv(.c) void {
            u.cast(bool, data.?).* = true;
        }
    }.notify, &finalized);
    {
        var plan = try tx.prepare(testing.allocator, &.{.{ .target = f.target(1), .replacements = &.{replace(0, 1, "X")} }}, .{});
        defer plan.deinit();
        f.deinit();
        owner_held = false;
        try testing.expect(!finalized);
        try testing.expectEqualStrings("abc", plan.before(0));
        // The registry no longer resolves this ID, despite the retained buffer.
        try testing.expectError(error.TargetMismatch, plan.commit(&.{}));
    }
    try testing.expect(finalized);
}

test "transaction: disabled undo remains disabled and huge configured limits do not overflow" {
    var f: Fixture = .{};
    f.init("abc");
    defer f.deinit();
    c.gtk_text_buffer_set_enable_undo(f.buffer, 0);
    var plan = try tx.prepare(testing.allocator, &.{.{ .target = f.target(1), .replacements = &.{replace(0, 3, "🌱")} }}, .{
        .max_targets = std.math.maxInt(usize),
        .max_replacements = std.math.maxInt(usize),
        .max_buffer_bytes = std.math.maxInt(usize),
        .max_total_bytes = std.math.maxInt(usize),
    });
    defer plan.deinit();
    try plan.commit(&.{f.target(1)});
    try f.expect("🌱");
    try testing.expectEqual(@as(c_int, 0), c.gtk_text_buffer_get_enable_undo(f.buffer));
    try testing.expectEqual(@as(c_int, 0), c.gtk_text_buffer_get_can_undo(f.buffer));
}

test "transaction: every byte endpoint in a Unicode corpus agrees with a byte-slice reference" {
    const text = "aé中🌱e\u{301}\n";
    var f: Fixture = .{};
    f.init(text);
    defer f.deinit();
    for (0..text.len + 1) |start| {
        for (start..text.len + 1) |end| {
            const changes = [_]tx.Change{.{ .target = f.target(1), .replacements = &.{replace(start, end, "Ω")} }};
            const start_boundary = start == text.len or text[start] & 0xc0 != 0x80;
            const end_boundary = end == text.len or text[end] & 0xc0 != 0x80;
            if (!start_boundary or !end_boundary) {
                try testing.expectError(error.InvalidBoundary, tx.prepare(testing.allocator, &changes, .{}));
                try f.expect(text);
                continue;
            }
            var plan = try tx.prepare(testing.allocator, &changes, .{});
            defer plan.deinit();
            const expected = try std.fmt.allocPrint(testing.allocator, "{s}Ω{s}", .{ text[0..start], text[end..] });
            defer testing.allocator.free(expected);
            try plan.commit(&.{f.target(1)});
            try f.expect(expected);
            c.gtk_text_buffer_undo(f.buffer);
            try f.expect(text);
        }
    }
}

test "transaction: accepting one prepared plan invalidates another at the same base revision" {
    var f: Fixture = .{};
    f.init("abc");
    defer f.deinit();
    const changes = [_]tx.Change{.{ .target = f.target(1), .replacements = &.{replace(0, 1, "X")} }};
    var first = try tx.prepare(testing.allocator, &changes, .{});
    defer first.deinit();
    var second = try tx.prepare(testing.allocator, &changes, .{});
    defer second.deinit();
    try first.commit(&.{f.target(1)});
    var current = f.target(1);
    current.expected_revision = second.expectedRevision(0);
    try testing.expectError(error.StaleRevision, second.commit(&.{current}));
    try f.expect("Xbc");
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var a: Fixture = .{};
    a.init("aé🌱z");
    defer a.deinit();
    var b: Fixture = .{};
    b.init("other");
    defer b.deinit();
    var plan = tx.prepare(allocator, &.{
        .{ .target = a.target(1), .replacements = &.{ replace(1, 3, "É"), replace(7, 8, "!") } },
        .{ .target = b.target(2), .replacements = &.{replace(0, 5, "changed")} },
    }, .{}) catch |err| {
        try a.expectUntouched("aé🌱z");
        try b.expectUntouched("other");
        return err;
    };
    defer plan.deinit();
    try plan.commit(&.{ a.target(1), b.target(2) });
    try a.expect("aÉ🌱!");
    try b.expect("changed");
}

test "transaction: every Zig allocation failure is leak-free and leaves all buffers untouched" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationScenario, .{});
}

test "transaction: commit performs no allocator calls after successful prepare" {
    var f: Fixture = .{};
    f.init("abcdef");
    defer f.deinit();
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var plan = try tx.prepare(failing.allocator(), &.{.{ .target = f.target(1), .replacements = &.{ replace(0, 1, "X"), replace(4, 6, "Y") } }}, .{});
    defer plan.deinit();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try plan.commit(&.{f.target(1)});
    try testing.expect(!failing.has_induced_failure);
    try f.expect("XbcdY");
}

const Reentrant = struct {
    plan: *tx.Prepared,
    target: tx.Target,
    commit_busy: bool = false,
    prepare_busy: bool = false,
    observed_gate: bool = false,

    fn changed(_: ?*c.GtkTextBuffer, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Reentrant, data.?);
        self.observed_gate = tx.isApplying();
        self.plan.commit(&.{self.target}) catch |err| {
            self.commit_busy = err == error.Busy;
        };
        if (tx.prepare(testing.allocator, &.{}, .{})) |value| {
            var unexpected = value;
            unexpected.deinit();
        } else |err| {
            self.prepare_busy = err == error.Busy;
        }
    }
};

test "transaction: synchronous signal reentrancy is rejected before any nested mutation" {
    var f: Fixture = .{};
    f.init("abc");
    defer f.deinit();
    var plan = try tx.prepare(testing.allocator, &.{.{ .target = f.target(1), .replacements = &.{replace(0, 1, "X")} }}, .{});
    defer plan.deinit();
    var probe: Reentrant = .{ .plan = &plan, .target = f.target(1) };
    u.connect(f.buffer, "changed", &Reentrant.changed, &probe);
    try plan.commit(&.{f.target(1)});
    try testing.expect(probe.commit_busy and probe.prepare_busy and probe.observed_gate);
    try testing.expect(!tx.isApplying());
    try f.expect("Xbc");
}
