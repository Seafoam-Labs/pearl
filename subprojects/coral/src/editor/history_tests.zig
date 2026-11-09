const std = @import("std");
const t = std.testing;
const c = @import("../c.zig").c;
const h = @import("history.zig");
const F = @import("history_test_support.zig").Fixture;
const r = @import("history_test_support.zig").r;

fn adjacentTyping(inverse: bool) !void {
    var a: F = .{};
    a.init(if (inverse) "baseX" else "base");
    defer a.deinit();
    var b: F = .{};
    b.init(if (inverse) "baseX" else "base");
    defer b.deinit();
    var history = h.History.init(t.allocator, .{});
    defer history.deinit();
    try history.perform("adjacent group", &.{
        .{ .target = a.target(1), .replacements = &.{r(4, if (inverse) 5 else 4, if (inverse) "" else "X")} },
        .{ .target = b.target(2), .replacements = &.{r(4, if (inverse) 5 else 4, if (inverse) "" else "X")} },
    });
    if (inverse) try history.undo(&.{ a.target(1), b.target(2) });
    const other_revision = b.revision;
    a.insert(5, "y");
    try t.expect(try history.replayNative(a.target(1), false));
    try a.expect("baseX");
    try b.expect("baseX");
    try t.expectEqual(other_revision, b.revision);
    const revision = a.revision;
    try t.expectError(error.GroupedBoundary, history.replayNative(a.target(1), false));
    try t.expectEqual(revision, a.revision);
    try t.expect(try history.replayNative(a.target(1), true));
    try a.expect("baseXy");
    try b.expect("baseX");
    try t.expectEqual(other_revision, b.revision);
}
test "history grouped append cannot merge with following native typing" {
    try adjacentTyping(false);
}
test "history inverse grouped deletion cannot merge with following native typing" {
    try adjacentTyping(true);
}

test "history multi-buffer undo redo and attributable snapshots/deltas" {
    var a: F = .{};
    a.init("aé🌱z");
    defer a.deinit();
    var b: F = .{};
    b.init("abcdef");
    defer b.deinit();
    var history = h.History.init(t.allocator, .{});
    defer history.deinit();
    try history.perform("Project edit", &.{
        .{ .target = a.target(1), .replacements = &.{r(1, 3, "É")} },
        .{ .target = b.target(2), .replacements = &.{ r(0, 2, ""), r(2, 4, ""), r(4, 4, "!") } },
    });
    try a.expect("aÉ🌱z");
    try b.expect("!ef");
    const record = history.undoRecord().?;
    try t.expectEqualStrings("Project edit", record.label);
    try t.expectEqualStrings("abcdef", record.entries[1].before);
    try t.expectEqualStrings("!ef", record.entries[1].after);
    try t.expect(record.entries[0].after_revision > record.entries[0].before_revision);
    try t.expectEqual(@as(usize, 1), record.entries[1].deltas.len);
    try history.undo(&.{ b.target(2), a.target(1) });
    try a.expect("aé🌱z");
    try b.expect("abcdef");
    try history.redo(&.{ a.target(1), b.target(2) });
    try a.expect("aÉ🌱z");
    try b.expect("!ef");
}

test "history repeated sequential undo redo advances only attributable revision chains" {
    var a: F = .{};
    a.init("abc");
    defer a.deinit();
    var history = h.History.init(t.allocator, .{});
    defer history.deinit();
    try history.perform("first", &.{.{ .target = a.target(1), .replacements = &.{r(0, 1, "A")} }});
    try history.perform("second", &.{.{ .target = a.target(1), .replacements = &.{r(1, 2, "B")} }});
    for (0..3) |_| {
        try history.undo(&.{a.target(1)});
        try a.expect("Abc");
        try history.undo(&.{a.target(1)});
        try a.expect("abc");
        try history.redo(&.{a.target(1)});
        try a.expect("Abc");
        try history.redo(&.{a.target(1)});
        try a.expect("ABc");
    }
}

test "history overlapping newer edits and edit native undo refuse ALL buffers" {
    for ([_]bool{ false, true }) |native_undo| {
        var a: F = .{};
        a.init("abc");
        defer a.deinit();
        var b: F = .{};
        b.init("def");
        defer b.deinit();
        var history = h.History.init(t.allocator, .{});
        defer history.deinit();
        try history.perform("both", &.{
            .{ .target = a.target(1), .replacements = &.{r(0, 1, "A")} },
            .{ .target = b.target(2), .replacements = &.{r(0, 1, "D")} },
        });
        b.insert(1, "newer");
        if (native_undo) try t.expect(try history.replayNative(b.target(2), false));
        const rev = a.revision;
        try t.expectError(error.StaleRevision, history.undo(&.{ a.target(1), b.target(2) }));
        try a.expect("Abc");
        try b.expect(if (native_undo) "Def" else "Dneweref");
        try t.expectEqual(rev, a.revision);
        try t.expect(history.canUndo() and !history.canRedo());
    }
}

test "history exact state identity closed document and policy validation before mutation" {
    var a: F = .{};
    a.init("abc");
    defer a.deinit();
    var b: F = .{};
    b.init("def");
    var closed = false;
    defer if (!closed) b.deinit();
    var history = h.History.init(t.allocator, .{});
    defer history.deinit();
    try history.perform("both", &.{
        .{ .target = a.target(1), .replacements = &.{r(0, 1, "A")} },
        .{ .target = b.target(2), .replacements = &.{r(0, 1, "D")} },
    });
    var read_only = b.target(2);
    read_only.writable = false;
    try t.expectError(error.ReadOnly, history.undo(&.{ a.target(1), read_only }));
    var other_revision = b.revision;
    var wrong = b.target(2);
    wrong.revision = &other_revision;
    try t.expectError(error.TargetMismatch, history.undo(&.{ a.target(1), wrong }));
    const rev = b.revision;
    b.insert(0, "!");
    b.revision = rev;
    try t.expectError(error.SnapshotMismatch, history.undo(&.{ a.target(1), b.target(2) }));
    b.deinit();
    closed = true;
    try t.expectError(error.TargetMismatch, history.undo(&.{a.target(1)}));
    try a.expect("Abc");
}

test "history pending stale commit and no-op do not discard redo; bounded eviction" {
    var a: F = .{};
    a.init("abc");
    defer a.deinit();
    var history = h.History.init(t.allocator, .{ .max_records = 2 });
    defer history.deinit();
    try history.perform("first", &.{.{ .target = a.target(1), .replacements = &.{r(0, 1, "A")} }});
    try history.undo(&.{a.target(1)});
    try history.perform("noop", &.{.{ .target = a.target(1), .replacements = &.{r(0, 1, "a")} }});
    try t.expect(history.canRedo());
    var pending = try history.prepare("preview", &.{.{ .target = a.target(1), .replacements = &.{r(0, 1, "X")} }});
    defer pending.deinit();
    var busy = a.target(1);
    busy.busy = true;
    try t.expectError(error.Busy, history.commit(&pending, &.{busy}));
    try t.expect(history.canRedo());
    try history.commit(&pending, &.{a.target(1)});
    try t.expect(!history.canRedo());
    try history.perform("two", &.{.{ .target = a.target(1), .replacements = &.{r(0, 1, "Y")} }});
    try history.perform("three", &.{.{ .target = a.target(1), .replacements = &.{r(0, 1, "Z")} }});
    try t.expectEqual(@as(usize, 2), history.records.items.len);
    try history.undo(&.{a.target(1)});
    try history.undo(&.{a.target(1)});
    try a.expect("Xbc");
    try t.expectError(error.NothingToUndo, history.undo(&.{a.target(1)}));
    var small = h.History.init(t.allocator, .{ .max_bytes = 1 });
    defer small.deinit();
    try t.expectError(error.HistoryLimit, small.perform("large", &.{.{ .target = a.target(1), .replacements = &.{r(0, 1, "Q")} }}));
    try a.expect("Xbc");
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var a: F = .{};
    a.init("abc");
    defer a.deinit();
    var b: F = .{};
    b.init("def");
    defer b.deinit();
    var history = h.History.init(allocator, .{});
    defer history.deinit();
    history.perform("both", &.{
        .{ .target = a.target(1), .replacements = &.{r(0, 1, "AAA")} },
        .{ .target = b.target(2), .replacements = &.{r(0, 1, "DDD")} },
    }) catch |err| {
        try a.expect("abc");
        try b.expect("def");
        try t.expectEqual(@as(usize, 0), history.cursor);
        return err;
    };
    history.undo(&.{ a.target(1), b.target(2) }) catch |err| {
        try a.expect("AAAbc");
        try b.expect("DDDef");
        try t.expectEqual(@as(usize, 1), history.cursor);
        return err;
    };
    history.redo(&.{ a.target(1), b.target(2) }) catch |err| {
        try a.expect("abc");
        try b.expect("def");
        try t.expectEqual(@as(usize, 0), history.cursor);
        return err;
    };
}
test "history all Zig allocation failures preserve all targets and cursor" {
    try t.checkAllAllocationFailures(t.allocator, allocationScenario, .{});
}

test "history redo conflict and later workspace edits cannot legitimize an external revision" {
    var a: F = .{};
    a.init("abc");
    defer a.deinit();
    var history = h.History.init(t.allocator, .{});
    defer history.deinit();
    try history.perform("first", &.{.{ .target = a.target(1), .replacements = &.{r(0, 1, "A")} }});
    try history.undo(&.{a.target(1)});
    a.insert(0, "!");
    try t.expect(try history.replayNative(a.target(1), false));
    try a.expect("abc");
    try t.expectError(error.StaleRevision, history.redo(&.{a.target(1)}));
    try t.expect(history.canRedo());
    try history.perform("new branch", &.{.{ .target = a.target(1), .replacements = &.{r(0, 1, "A")} }});
    a.insert(3, "!");
    try history.perform("after external edit", &.{.{ .target = a.target(1), .replacements = &.{r(1, 2, "B")} }});
    try history.undo(&.{a.target(1)});
    try a.expect("Abc!");
    try t.expectError(error.StaleRevision, history.undo(&.{a.target(1)}));
    try a.expect("Abc!");
}

fn branchAllocations(allocator: std.mem.Allocator) !void {
    var a: F = .{};
    a.init("abc");
    defer a.deinit();
    var history = h.History.init(allocator, .{});
    defer history.deinit();
    try history.perform("first", &.{.{ .target = a.target(1), .replacements = &.{r(0, 1, "A")} }});
    try history.undo(&.{a.target(1)});
    history.perform("branch", &.{.{ .target = a.target(1), .replacements = &.{r(1, 2, "B")} }}) catch |err| {
        try a.expect("abc");
        try t.expect(history.canRedo());
        try t.expectEqualStrings("first", history.redoRecord().?.label);
        return err;
    };
    try t.expect(!history.canRedo());
    try a.expect("aBc");
}
test "history failed new branch preserves redo at every allocation point" {
    try t.checkAllAllocationFailures(t.allocator, branchAllocations, .{});
}

test "guarded typing coalesces and later group undo restores earlier typing interval" {
    var a: F = .{};
    a.init("base");
    defer a.deinit();
    var history = h.History.init(t.allocator, .{});
    defer history.deinit();
    try history.perform("first", &.{.{ .target = a.target(1), .replacements = &.{r(4, 4, "X")} }});
    a.insert(5, "y");
    a.insert(6, "z");
    try history.perform("second", &.{.{ .target = a.target(1), .replacements = &.{r(7, 7, "Q")} }});
    try history.undo(&.{a.target(1)});
    try a.expect("baseXyz");
    try t.expect(try history.replayNative(a.target(1), false));
    try a.expect("baseX");
    try t.expectError(error.StaleRevision, history.undo(&.{a.target(1)}));
    try t.expectError(error.GroupedBoundary, history.replayNative(a.target(1), false));
    try t.expect(try history.replayNative(a.target(1), true));
    try a.expect("baseXyz");
    try t.expectError(error.StaleRevision, history.redo(&.{a.target(1)}));
}

test "new grouped branch cannot revive abandoned native redo" {
    var a: F = .{};
    a.init("base");
    defer a.deinit();
    var history = h.History.init(t.allocator, .{});
    defer history.deinit();
    try history.perform("first", &.{.{ .target = a.target(1), .replacements = &.{r(4, 4, "X")} }});
    a.insert(5, "y");
    try t.expect(try history.replayNative(a.target(1), false));
    try history.perform("branch", &.{.{ .target = a.target(1), .replacements = &.{r(5, 5, "Q")} }});
    try history.undo(&.{a.target(1)});
    try t.expectError(error.GroupedBoundary, history.replayNative(a.target(1), true));
    try a.expect("baseX");
    a.insert(5, "z");
    try t.expect(try history.replayNative(a.target(1), false));
    try t.expect(try history.replayNative(a.target(1), true));
    try a.expect("baseXz");
    try t.expectError(error.GroupedBoundary, history.replayNative(a.target(1), true));
}

test "guard survives record eviction and history destruction without clearing canonical undo" {
    var a: F = .{};
    a.init("base");
    defer a.deinit();
    a.insert(4, "old");
    {
        var history = h.History.init(t.allocator, .{ .max_records = 1 });
        defer history.deinit();
        try history.perform("first", &.{.{ .target = a.target(1), .replacements = &.{r(7, 7, "X")} }});
        try history.perform("evict", &.{.{ .target = a.target(1), .replacements = &.{r(8, 8, "Q")} }});
    }
    try t.expect(c.gtk_text_buffer_get_enable_undo(a.buffer) != 0);
    try t.expect(c.gtk_text_buffer_get_can_undo(a.buffer) != 0);
    var next = h.History.init(t.allocator, .{});
    defer next.deinit();
    a.insert(9, "y");
    try t.expect(try next.replayNative(a.target(1), false));
    try a.expect("baseoldXQ");
    try t.expectError(error.GroupedBoundary, next.replayNative(a.target(1), false));
}

test "unprotected native history and failed previews never install a guard" {
    var a: F = .{};
    a.init("base");
    defer a.deinit();
    var history = h.History.init(t.allocator, .{});
    defer history.deinit();
    a.insert(4, "y");
    var pending = try history.prepare("preview", &.{.{ .target = a.target(1), .replacements = &.{r(5, 5, "X")} }});
    defer pending.deinit();
    var busy = a.target(1);
    busy.busy = true;
    try t.expectError(error.Busy, history.commit(&pending, &.{busy}));
    try t.expect(!try history.replayNative(a.target(1), false));
    c.gtk_text_buffer_undo(a.buffer);
    try a.expect("base");
}

fn nativeAllocations(allocator: std.mem.Allocator, forward: bool) !void {
    var a: F = .{};
    a.init("base");
    defer a.deinit();
    var b: F = .{};
    b.init("base");
    defer b.deinit();
    var history = h.History.init(t.allocator, .{});
    defer history.deinit();
    try history.perform("both", &.{
        .{ .target = a.target(1), .replacements = &.{r(4, 4, "X")} },
        .{ .target = b.target(2), .replacements = &.{r(4, 4, "X")} },
    });
    a.insert(5, "é🌱");
    c.gtk_text_buffer_set_modified(a.buffer, 0);
    @import("native_history.zig").recordSavedCheckpoint(a.buffer, true);
    if (forward) try t.expect(try history.replayNative(a.target(1), false));
    const revision = a.revision;
    const other_revision = b.revision;
    const old_modified = c.gtk_text_buffer_get_modified(a.buffer);
    const native = @import("native_history.zig");
    _ = native.replay(allocator, a.target(1), forward, .{}) catch |err| {
        try a.expect(if (forward) "baseX" else "baseXé🌱");
        try b.expect("baseX");
        try t.expectEqual(revision, a.revision);
        try t.expectEqual(other_revision, b.revision);
        try t.expectEqual(@as(usize, 1), history.cursor);
        try t.expectEqual(old_modified, c.gtk_text_buffer_get_modified(a.buffer));
        // The private undo cursor must have rolled back too: retry exactly once.
        try t.expect(try history.replayNative(a.target(1), forward));
        try a.expect(if (forward) "baseXé🌱" else "baseX");
        try t.expectEqual(!forward, c.gtk_text_buffer_get_modified(a.buffer) != 0);
        return err;
    };
    try a.expect(if (forward) "baseXé🌱" else "baseX");
    try t.expectEqual(!forward, c.gtk_text_buffer_get_modified(a.buffer) != 0);
    try b.expect("baseX");
    try t.expectEqual(other_revision, b.revision);
}
test "guarded native undo redo allocation failures preserve canonical and private history" {
    try t.checkAllAllocationFailures(t.allocator, nativeAllocations, .{false});
    try t.checkAllAllocationFailures(t.allocator, nativeAllocations, .{true});
}

test "guarded native replay keeps exact repeated-text locations and disjoint annotations" {
    var a: F = .{};
    a.init("aaaa");
    defer a.deinit();
    var history = h.History.init(t.allocator, .{});
    defer history.deinit();
    try history.perform("protect", &.{.{ .target = a.target(1), .replacements = &.{r(4, 4, "X")} }});
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(a.buffer, &start, 2);
    const mark = c.gtk_text_buffer_create_mark(a.buffer, null, &start, 1);
    c.gtk_text_buffer_get_iter_at_offset(a.buffer, &end, 3);
    const tag = c.gtk_text_buffer_create_tag(a.buffer, null, "weight", @as(c_int, 700), @as(?*anyopaque, null));
    c.gtk_text_buffer_apply_tag(a.buffer, tag, &start, &end);
    c.gtk_text_buffer_begin_user_action(a.buffer);
    a.insert(0, "a");
    a.insert(5, "a");
    c.gtk_text_buffer_end_user_action(a.buffer);
    try a.expect("aaaaaaX");
    try t.expect(try history.replayNative(a.target(1), false));
    try a.expect("aaaaX");
    c.gtk_text_buffer_get_iter_at_mark(a.buffer, &start, mark);
    try t.expectEqual(@as(c_int, 2), c.gtk_text_iter_get_offset(&start));
    try t.expect(c.gtk_text_iter_has_tag(&start, tag) != 0);
    try t.expect(try history.replayNative(a.target(1), true));
    c.gtk_text_buffer_get_iter_at_mark(a.buffer, &start, mark);
    try t.expectEqual(@as(c_int, 3), c.gtk_text_iter_get_offset(&start));
    try t.expect(c.gtk_text_iter_has_tag(&start, tag) != 0);
}

test "programmatic replacement is an explicit protected baseline not native typing" {
    var a: F = .{};
    a.init("base");
    defer a.deinit();
    var history = h.History.init(t.allocator, .{});
    defer history.deinit();
    try history.perform("protect", &.{.{ .target = a.target(1), .replacements = &.{r(4, 4, "X")} }});
    c.gtk_text_buffer_set_text(a.buffer, "reload", -1);
    try t.expectError(error.NativeHistoryUnavailable, history.replayNative(a.target(1), false));
    c.gtk_text_buffer_set_modified(a.buffer, 0);
    @import("native_history.zig").recordSavedCheckpoint(a.buffer, true);
    a.insert(6, "y");
    try t.expect(try history.replayNative(a.target(1), false));
    try a.expect("reload");
    try t.expectEqual(@as(c_int, 0), c.gtk_text_buffer_get_modified(a.buffer));
    try t.expectError(error.GroupedBoundary, history.replayNative(a.target(1), false));
}

test "explicit saved checkpoint is mirrored into guarded typing history" {
    var a: F = .{};
    a.init("base");
    defer a.deinit();
    var history = h.History.init(t.allocator, .{});
    defer history.deinit();
    try history.perform("protect", &.{.{ .target = a.target(1), .replacements = &.{r(4, 4, "X")} }});
    c.gtk_text_buffer_set_modified(a.buffer, 0);
    @import("native_history.zig").recordSavedCheckpoint(a.buffer, true);
    a.insert(5, "y");
    try t.expect(try history.replayNative(a.target(1), false));
    try a.expect("baseX");
    try t.expectEqual(@as(c_int, 0), c.gtk_text_buffer_get_modified(a.buffer));
    try t.expect(try history.replayNative(a.target(1), true));
    try t.expect(c.gtk_text_buffer_get_modified(a.buffer) != 0);
}
