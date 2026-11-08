const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const tx = @import("transactions.zig");
const testing = std.testing;

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
