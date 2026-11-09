//! Worker-only regressions, imported by src/tests.zig; no display required.
const std = @import("std");
const search = @import("search.zig");
const browser = @import("browser_fs.zig");
const fs = @import("search_fs.zig");
const c = @import("pearl_app_c");
const Fixture = @import("manifest_test_support.zig").Fixture;
const a = std.testing.allocator;
const root_id: search.RootId = @fromBackingInt(1);

fn repeated(comptime bytes: []const u8, comptime n: usize) [bytes.len * n]u8 {
    @setEvalBranchQuota(100_000);
    var output: [bytes.len * n]u8 = undefined;
    for (0..n) |i| @memcpy(output[i * bytes.len ..][0..bytes.len], bytes);
    return output;
}

fn finish(session: *search.Session, batch: *search.Batch) !void {
    var turns: usize = 0;
    while (true) {
        try session.next(batch);
        turns += 1;
        try std.testing.expect(turns < 200_000);
        if (batch.status != .running) return;
    }
}

test "search literal Unicode scalar positions and owned batches" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("unicode.txt", "α😀 CAFÉ\nsecond café\n");
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    var session = try search.Session.init(a, .{ .mode = .text, .query = "café", .roots = &roots }, cancel);
    var batch = search.Batch.init(a);
    defer batch.deinit();
    var count: usize = 0;
    while (true) {
        try session.next(&batch);
        for (batch.results) |result| {
            try std.testing.expectEqual(root_id, result.root_id);
            try std.testing.expectEqualStrings("unicode.txt", result.relative_path);
            try std.testing.expectEqual(@as(u32, @intCast(count)), result.line);
            try std.testing.expectEqual(@as(u32, if (count == 0) 3 else 7), result.column);
            try std.testing.expectEqual(result.column + 4, result.end_column);
            try std.testing.expectEqual(@as(usize, 5), result.byte_length);
            count += 1;
        }
        if (count == 2) break;
    }
    session.deinit();
    try std.testing.expectEqual(@as(usize, 2), batch.results.len);
    try std.testing.expectEqualStrings("unicode.txt", batch.results[0].relative_path);
}

test "search quick open replaces deterministic top candidates" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("abc.txt", "");
    try f.write("a-long-b-long-c.txt", "");
    try f.write("zabc.txt", "");
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    var session = try search.Session.init(a, .{ .mode = .quick_open, .query = "ABC", .roots = &roots, .limits = .{ .fuzzy_candidates = 2 } }, cancel);
    defer session.deinit();
    var batch = search.Batch.init(a);
    defer batch.deinit();
    try finish(&session, &batch);
    try std.testing.expectEqual(search.Status.incomplete, batch.status);
    try std.testing.expectEqual(search.Delivery.replace, batch.delivery);
    try std.testing.expect(batch.reasons.contains(.result_limit));
    try std.testing.expectEqual(@as(usize, 2), batch.results.len);
    try std.testing.expectEqualStrings("abc.txt", batch.results[0].relative_path);
    try std.testing.expectEqualStrings("zabc.txt", batch.results[1].relative_path);
}

fn countAll(session: *search.Session, batch: *search.Batch) !usize {
    var count: usize = 0;
    var turns: usize = 0;
    while (true) {
        try session.next(batch);
        try std.testing.expect(batch.results.len <= 128);
        count += batch.results.len;
        turns += 1;
        try std.testing.expect(turns < 200_000);
        if (batch.status != .running) return count;
    }
}

test "search overlays suppress disk even oversized and include policy allowed missing leaves" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("dirty.txt", "disk needle");
    try f.write("oversized.txt", "disk needle");
    try f.write(".gitignore", "ignored*\nblocked/\n");
    try f.mkdir("blocked");
    try f.fifo("blocked/.gitignore");
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    const overlays = [_]search.Overlay{
        .{ .root_id = root_id, .relative_path = "dirty.txt", .document_id = 11, .revision = 21, .text = "no match" },
        .{ .root_id = root_id, .relative_path = "oversized.txt", .document_id = 12, .revision = 22, .text = &repeated("needle", 20) },
        .{ .root_id = root_id, .relative_path = "deleted.txt", .document_id = 13, .revision = 23, .text = "😀 NEEDLE" },
        .{ .root_id = root_id, .relative_path = "ignored-new", .document_id = 14, .revision = 24, .text = "needle" },
        .{ .root_id = root_id, .relative_path = "blocked/new", .document_id = 15, .revision = 25, .text = "needle" },
    };
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var session = try search.Session.init(a, .{ .mode = .text, .query = "needle", .roots = &roots, .overlays = &overlays, .limits = .{ .file_bytes = 64 } }, cancel);
    defer session.deinit();
    var batch = search.Batch.init(a);
    defer batch.deinit();
    var count: usize = 0;
    while (true) {
        try session.next(&batch);
        for (batch.results) |result| {
            count += 1;
            try std.testing.expectEqualStrings("deleted.txt", result.relative_path);
            try std.testing.expectEqual(@as(u64, 13), result.source.overlay.document_id);
            try std.testing.expectEqual(@as(u64, 23), result.source.overlay.revision);
            try std.testing.expectEqual(@as(u32, 2), result.column);
        }
        if (batch.status != .running) break;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(search.Status.incomplete, batch.status);
    try std.testing.expect(batch.reasons.contains(.overlay_too_large));
    try std.testing.expect(!batch.reasons.contains(.unsafe_overlay));
}

test "search ignores excludes nested roots and duplicate aliases" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("sub");
    try f.write("sub/keep.txt", "needle");
    try f.write("sub/drop.log", "needle");
    try f.write("sub/.gitignore", "*.log\n");
    try f.write("root.txt", "needle");
    try f.write("excluded.txt", "needle");
    try f.mkdir(".git");
    try f.write(".git/hidden", "needle");
    const nested = try f.path("sub");
    defer a.free(nested);
    const roots = [_]search.Root{
        .{ .id = root_id, .canonical_path = f.base },
        .{ .id = @fromBackingInt(2), .canonical_path = nested },
        .{ .id = @fromBackingInt(3), .canonical_path = f.base },
    };
    const overlays = [_]search.Overlay{.{ .root_id = root_id, .relative_path = "sub/keep.txt", .document_id = 99, .revision = 7, .text = "NEEDLE" }};
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var session = try search.Session.init(a, .{ .mode = .text, .query = "needle", .roots = &roots, .excludes = &.{"excluded.txt"}, .overlays = &overlays }, cancel);
    defer session.deinit();
    var batch = search.Batch.init(a);
    defer batch.deinit();
    var count: usize = 0;
    while (true) {
        try session.next(&batch);
        for (batch.results) |result| {
            count += 1;
            if (std.mem.eql(u8, result.relative_path, "keep.txt")) {
                try std.testing.expectEqual(@as(search.RootId, @fromBackingInt(2)), result.root_id);
                try std.testing.expectEqual(@as(u64, 99), result.source.overlay.document_id);
            } else try std.testing.expectEqualStrings("root.txt", result.relative_path);
        }
        if (batch.status != .running) break;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(search.Status.complete, batch.status);
}

test "search skips binary invalid UTF8 and blocked files without prefix matches" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("binary", "needle\x00");
    try f.write("invalid", "needle\xff");
    try f.write("good", "needle");
    try f.symlink("good", "link");
    try f.fifo("pipe");
    try f.mkdir("folder");
    try f.symlink("folder", "linked-folder");
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    const overlays = [_]search.Overlay{
        .{ .root_id = root_id, .relative_path = "link", .document_id = 1, .revision = 1, .text = "needle" },
        .{ .root_id = root_id, .relative_path = "pipe", .document_id = 2, .revision = 1, .text = "needle" },
        .{ .root_id = root_id, .relative_path = "linked-folder/new", .document_id = 3, .revision = 1, .text = "needle" },
        .{ .root_id = root_id, .relative_path = "missing/new", .document_id = 4, .revision = 1, .text = "needle" },
    };
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var session = try search.Session.init(a, .{ .mode = .text, .query = "needle", .roots = &roots, .overlays = &overlays }, cancel);
    defer session.deinit();
    var batch = search.Batch.init(a);
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 1), try countAll(&session, &batch));
    try std.testing.expectEqual(search.Status.incomplete, batch.status);
    try std.testing.expect(batch.reasons.contains(.binary_file));
    try std.testing.expect(batch.reasons.contains(.invalid_utf8));
    try std.testing.expect(batch.reasons.contains(.unsafe_overlay));
}

test "search streaming nonoverlap matches span lines and preserve GTK columns" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("many", &repeated("É\n😀x", 300));
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var session = try search.Session.init(a, .{ .mode = .text, .query = "é\n😀", .roots = &roots }, cancel);
    defer session.deinit();
    var batch = search.Batch.init(a);
    defer batch.deinit();
    var count: usize = 0;
    while (true) {
        try session.next(&batch);
        try std.testing.expect(batch.results.len <= 128);
        for (batch.results) |result| {
            try std.testing.expectEqual(@as(u32, @intCast(count)), result.line);
            try std.testing.expectEqual(@as(u32, if (count == 0) 0 else 2), result.column);
            try std.testing.expectEqual(result.line + 1, result.end_line);
            try std.testing.expectEqual(@as(u32, 1), result.end_column);
            count += 1;
        }
        if (batch.status != .running) break;
    }
    try std.testing.expectEqual(@as(usize, 300), count);
    try std.testing.expectEqual(search.Status.complete, batch.status);
}

fn cancelRead(cancel: *c.GCancellable) void {
    c.g_cancellable_cancel(cancel);
}
fn cancelRecord(_: c_int, _: usize, cancel: *c.GCancellable) void {
    c.g_cancellable_cancel(cancel);
}

test "search cooperative cancellation before scan during enumeration and read" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("file", &repeated("needle", 2000));
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    for (0..3) |stage| {
        const cancel = c.g_cancellable_new().?;
        defer c.g_object_unref(cancel);
        var session = try search.Session.init(a, .{ .mode = .text, .query = "needle", .roots = &roots }, cancel);
        defer session.deinit();
        var batch = search.Batch.init(a);
        defer batch.deinit();
        if (stage == 0) c.g_cancellable_cancel(cancel);
        if (stage == 1) browser.TestHooks.after_record = cancelRecord;
        if (stage == 2) fs.TestHooks.after_read = cancelRead;
        defer browser.TestHooks.after_record = null;
        defer fs.TestHooks.after_read = null;
        try finish(&session, &batch);
        try std.testing.expectEqual(search.Status.cancelled, batch.status);
        try std.testing.expectEqual(@as(usize, 0), batch.results.len);
        try session.next(&batch);
        try std.testing.expectEqual(search.Status.cancelled, batch.status);
    }
}

test "search stale directory discards previous streamed results" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("many", &repeated("needle ", 300));
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var session = try search.Session.init(a, .{ .mode = .text, .query = "needle", .roots = &roots }, cancel);
    defer session.deinit();
    var batch = search.Batch.init(a);
    defer batch.deinit();
    while (batch.results.len == 0) try session.next(&batch);
    try f.write("new-entry", "needle");
    try session.next(&batch);
    try std.testing.expectEqual(search.Status.reset_required, batch.status);
    try std.testing.expect(batch.discard_previous);
    try std.testing.expectEqual(@as(usize, 0), batch.results.len);
}

test "search resource limits are explicit and never exceed counters" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("many", &repeated("needle ", 300));
    try f.mkdir("deep");
    try f.write("deep/child", "needle");
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    const cases = [_]struct { limits: search.Limits, reason: search.Reason }{
        .{ .limits = .{ .records = 0 }, .reason = .traversal_limit },
        .{ .limits = .{ .pages = 0 }, .reason = .page_limit },
        .{ .limits = .{ .depth = 0 }, .reason = .depth_limit },
        .{ .limits = .{ .path_bytes = 2 }, .reason = .path_limit },
        .{ .limits = .{ .path_memory_bytes = 0 }, .reason = .path_limit },
        .{ .limits = .{ .file_bytes = 3 }, .reason = .file_too_large },
        .{ .limits = .{ .total_bytes = 3 }, .reason = .total_bytes_limit },
        .{ .limits = .{ .query_steps = 3 }, .reason = .query_work_limit },
        .{ .limits = .{ .policy_steps = 3 }, .reason = .policy_work_limit },
        .{ .limits = .{ .policy_bytes = 3 }, .reason = .policy_work_limit },
        .{ .limits = .{ .results = 3 }, .reason = .result_limit },
    };
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    for (cases) |case| {
        var session = try search.Session.init(a, .{ .mode = .text, .query = "needle", .roots = &roots, .limits = case.limits }, cancel);
        defer session.deinit();
        var batch = search.Batch.init(a);
        defer batch.deinit();
        _ = try countAll(&session, &batch);
        try std.testing.expectEqual(search.Status.incomplete, batch.status);
        try std.testing.expect(batch.reasons.contains(case.reason));
        try std.testing.expect(batch.progress.records <= case.limits.records);
        try std.testing.expect(batch.progress.pages <= case.limits.pages);
        try std.testing.expect(batch.progress.scanned_bytes <= case.limits.total_bytes);
        try std.testing.expect(batch.progress.query_steps <= case.limits.query_steps);
        try std.testing.expect(batch.progress.policy_steps <= case.limits.policy_steps);
        try std.testing.expect(batch.progress.policy_bytes <= case.limits.policy_bytes);
    }
}

test "search 100000 nonempty text files complete with actual policy accounting" {
    var f = try Fixture.init();
    defer f.deinit();
    const fd = std.c.open(f.base, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    var created: usize = 0;
    defer {
        for (0..created) |i| {
            var buffer: [32]u8 = undefined;
            const name = std.fmt.bufPrintSentinel(&buffer, "{d}", .{i}, 0) catch unreachable;
            std.debug.assert(std.c.unlinkat(fd, name, 0) == 0);
        }
    }
    for (0..100_000) |i| {
        var buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrintSentinel(&buffer, "{d}", .{i}, 0);
        const file = std.c.openat(fd, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(file >= 0);
        defer _ = std.c.close(file);
        created += 1;
        try std.testing.expectEqual(@as(isize, 1), std.c.write(file, "x", 1));
    }
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var session = try search.Session.init(a, .{ .mode = .text, .query = "absent", .roots = &roots, .limits = .{ .session_memory_bytes = 256 * 1024 } }, cancel);
    defer session.deinit();
    var batch = search.Batch.init(a);
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 0), try countAll(&session, &batch));
    try std.testing.expectEqual(search.Status.complete, batch.status);
    try std.testing.expectEqual(@as(usize, 100_000), batch.progress.files);
    try std.testing.expectEqual(@as(usize, 200_000), batch.progress.scanned_bytes);
    try std.testing.expect(batch.progress.records >= 100_000);
    try std.testing.expect(batch.progress.pages < 2000);
    try std.testing.expect(batch.progress.policy_steps < 1024 * 1024);
}

fn allocationCase(allocator: std.mem.Allocator, root: []const u8, cancel: *c.GCancellable, mode: search.Mode) !void {
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = root }};
    const overlays = [_]search.Overlay{.{ .root_id = root_id, .relative_path = "new", .document_id = 1, .revision = 2, .text = "needle" }};
    var session = try search.Session.init(allocator, .{ .mode = mode, .query = "n", .roots = &roots, .overlays = &overlays }, cancel);
    defer session.deinit();
    var batch = search.Batch.init(allocator);
    defer batch.deinit();
    try finish(&session, &batch);
    try std.testing.expectEqual(search.Status.complete, batch.status);
}

test "search allocation failures release all sessions batches pages and overlays" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("one", "needle");
    try f.mkdir("nested");
    try f.write("nested/two", "needle");
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{ f.base, cancel, search.Mode.text });
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{ f.base, cancel, search.Mode.quick_open });
}

test "search memory cap returns incomplete instead of exceeding storage" {
    var f = try Fixture.init();
    defer f.deinit();
    const bytes = try a.alloc(u8, 128 * 1024);
    defer a.free(bytes);
    @memset(bytes, 'x');
    try f.write("large", bytes);
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var session = try search.Session.init(a, .{ .mode = .text, .query = "x", .roots = &roots, .limits = .{ .session_memory_bytes = 96 * 1024 } }, cancel);
    defer session.deinit();
    var batch = search.Batch.init(a);
    defer batch.deinit();
    try finish(&session, &batch);
    try std.testing.expectEqual(search.Status.incomplete, batch.status);
    try std.testing.expect(batch.reasons.contains(.memory_limit));
}

test "search malformed inputs and duplicate overlays fail at init" {
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = "/tmp" }};
    try std.testing.expectError(error.EmptyQuery, search.Session.init(a, .{ .mode = .text, .query = "", .roots = &roots }, cancel));
    try std.testing.expectError(error.InvalidQuery, search.Session.init(a, .{ .mode = .text, .query = "\xff", .roots = &roots }, cancel));
    for ([_][]const u8{ "../escape", "/absolute", "a//b", "a/./b", "", "a/" }) |path| {
        const overlays = [_]search.Overlay{.{ .root_id = root_id, .relative_path = path, .document_id = 1, .revision = 0, .text = "" }};
        try std.testing.expectError(error.InvalidPath, search.Session.init(a, .{ .mode = .text, .query = "x", .roots = &roots, .overlays = &overlays }, cancel));
    }
    const overlays = [_]search.Overlay{
        .{ .root_id = root_id, .relative_path = "same", .document_id = 1, .revision = 0, .text = "x" },
        .{ .root_id = root_id, .relative_path = "same", .document_id = 2, .revision = 1, .text = "x" },
    };
    try std.testing.expectError(error.DuplicateOverlay, search.Session.init(a, .{ .mode = .text, .query = "x", .roots = &roots, .overlays = &overlays }, cancel));
    try std.testing.expectError(error.InvalidLimits, search.Session.init(a, .{ .mode = .text, .query = "x", .roots = &roots, .limits = .{ .depth = 65 } }, cancel));
}

test "search empty quick open and Unicode simple folding are explicit" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("a", "K k K ss ß aaaaa");
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    const cases = [_]struct { query: []const u8, count: usize }{
        .{ .query = "k", .count = 3 },
        .{ .query = "ss", .count = 1 },
        .{ .query = "aa", .count = 2 },
    };
    for (cases) |case| {
        var session = try search.Session.init(a, .{ .mode = .text, .query = case.query, .roots = &roots }, cancel);
        defer session.deinit();
        var batch = search.Batch.init(a);
        defer batch.deinit();
        try std.testing.expectEqual(case.count, try countAll(&session, &batch));
        try std.testing.expectEqual(search.Status.complete, batch.status);
    }
    var session = try search.Session.init(a, .{ .mode = .quick_open, .query = "", .roots = &roots }, cancel);
    defer session.deinit();
    var batch = search.Batch.init(a);
    defer batch.deinit();
    try finish(&session, &batch);
    try std.testing.expectEqual(@as(usize, 1), batch.results.len);
}

fn cancelMatch(steps: usize, cancel: *c.GCancellable) void {
    if (steps > 4 * 1024 * 1024 + 5000) c.g_cancellable_cancel(cancel);
}

test "search matcher cancellation and incremental large source validation" {
    var f = try Fixture.init();
    defer f.deinit();
    const bytes = try a.alloc(u8, 1024 * 1024);
    defer a.free(bytes);
    @memset(bytes, 'x');
    try f.write("large", bytes);
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var session = try search.Session.init(a, .{ .mode = .text, .query = "not found", .roots = &roots }, cancel);
    defer session.deinit();
    var batch = search.Batch.init(a);
    defer batch.deinit();
    search.TestHooks.before_query = cancelMatch;
    defer search.TestHooks.before_query = null;
    try finish(&session, &batch);
    try std.testing.expectEqual(search.Status.cancelled, batch.status);
    try std.testing.expect(batch.progress.query_steps <= 4 * 1024 * 1024 + 5008);
    search.TestHooks.before_query = null;
    c.g_cancellable_reset(cancel);
    var resumed = try search.Session.init(a, .{ .mode = .text, .query = "not found", .roots = &roots }, cancel);
    defer resumed.deinit();
    var previous: search.Progress = .{};
    var turns: usize = 0;
    while (true) {
        try resumed.next(&batch);
        try std.testing.expect(batch.progress.query_steps - previous.query_steps <= 1024 * 1024);
        try std.testing.expect(batch.progress.scanned_bytes - previous.scanned_bytes <= 1024 * 1024 + 1);
        previous = batch.progress;
        turns += 1;
        try std.testing.expect(turns < 30);
        if (batch.status != .running) break;
    }
    try std.testing.expect(turns >= 8);
    try std.testing.expectEqual(search.Status.complete, batch.status);
}

var mutation_fd: c_int = -1;
fn mutateRead(_: *c.GCancellable) void {
    fs.TestHooks.after_read = null;
    std.debug.assert(std.c.write(mutation_fd, "!", 1) == 1);
}

test "search changed file during descriptor read never publishes old prefix" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("file", &repeated("needle", 2000));
    const path = try f.path("file");
    defer a.free(path);
    mutation_fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true });
    try std.testing.expect(mutation_fd >= 0);
    defer _ = std.c.close(mutation_fd);
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var session = try search.Session.init(a, .{ .mode = .text, .query = "needle", .roots = &roots }, cancel);
    defer session.deinit();
    var batch = search.Batch.init(a);
    defer batch.deinit();
    fs.TestHooks.after_read = mutateRead;
    defer fs.TestHooks.after_read = null;
    try finish(&session, &batch);
    try std.testing.expectEqual(search.Status.reset_required, batch.status);
    try std.testing.expect(batch.discard_previous and batch.results.len == 0);
}

test "search fatal ignore errors are visible and bounded" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.fifo(".gitignore");
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var session = try search.Session.init(a, .{ .mode = .text, .query = "needle", .roots = &roots }, cancel);
    defer session.deinit();
    var batch = search.Batch.init(a);
    defer batch.deinit();
    try std.testing.expectError(error.IgnoreNotRegular, finish(&session, &batch));
    try std.testing.expectEqual(search.Status.failed, batch.status);
    try std.testing.expect(batch.failure.? == error.IgnoreNotRegular);
    try std.testing.expect(batch.discard_previous);
    try std.testing.expect(batch.progress.policy_steps > 0);
}

test "search positions agree with headless GtkTextBuffer Unicode and line separators" {
    var f = try Fixture.init();
    defer f.deinit();
    const text = "α\r\nβ\rγ\u{2029}δ\u{2028}ε\nneedle";
    try f.write("lines", text);
    const buffer = c.gtk_text_buffer_new(null).?;
    defer c.g_object_unref(buffer);
    c.gtk_text_buffer_set_text(buffer, text, text.len);
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    for ([_][]const u8{ "β", "γ", "δ", "ε", "needle", "\r", "\n", "\u{2029}", "\u{2028}", "β\rγ" }) |query| {
        var session = try search.Session.init(a, .{ .mode = .text, .query = query, .roots = &roots }, cancel);
        defer session.deinit();
        var batch = search.Batch.init(a);
        defer batch.deinit();
        while (batch.results.len == 0 and batch.status == .running) try session.next(&batch);
        try std.testing.expect(batch.results.len > 0);
        for (batch.results) |result| {
            var iter: c.GtkTextIter = undefined;
            c.gtk_text_buffer_get_iter_at_offset(buffer, &iter, @intCast(try std.unicode.utf8CountCodepoints(text[0..result.byte_offset])));
            try std.testing.expectEqual(@as(u32, @intCast(c.gtk_text_iter_get_line(&iter))), result.line);
            try std.testing.expectEqual(@as(u32, @intCast(c.gtk_text_iter_get_line_offset(&iter))), result.column);
            c.gtk_text_buffer_get_iter_at_offset(buffer, &iter, @intCast(try std.unicode.utf8CountCodepoints(text[0 .. result.byte_offset + result.byte_length])));
            try std.testing.expectEqual(@as(u32, @intCast(c.gtk_text_iter_get_line(&iter))), result.end_line);
            try std.testing.expectEqual(@as(u32, @intCast(c.gtk_text_iter_get_line_offset(&iter))), result.end_column);
        }
    }
}

test "search fuzzy top K spans pages and stale continuation is terminal" {
    var f = try Fixture.init();
    defer f.deinit();
    for (0..300) |i| {
        var name: [64]u8 = undefined;
        try f.write(try std.fmt.bufPrint(&name, "a_long_b_long_c_{d}", .{i}), "");
    }
    try f.write("abc", "");
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var session = try search.Session.init(a, .{ .mode = .quick_open, .query = "abc", .roots = &roots, .limits = .{ .fuzzy_candidates = 4 } }, cancel);
    defer session.deinit();
    var batch = search.Batch.init(a);
    defer batch.deinit();
    try finish(&session, &batch);
    try std.testing.expectEqual(@as(usize, 4), batch.results.len);
    try std.testing.expectEqualStrings("abc", batch.results[0].relative_path);
    try std.testing.expect(batch.progress.records >= 301);
    try std.testing.expect(batch.reasons.contains(.result_limit));
    var stale = try search.Session.init(a, .{ .mode = .quick_open, .query = "abc", .roots = &roots, .limits = .{ .fuzzy_candidates = 4 } }, cancel);
    defer stale.deinit();
    try stale.next(&batch);
    while (batch.results.len == 0 and batch.status == .running) try stale.next(&batch);
    try std.testing.expect(batch.progress.records > 0 and batch.progress.records < 301);
    try f.write("changed", "");
    try stale.next(&batch);
    try std.testing.expectEqual(search.Status.reset_required, batch.status);
    try std.testing.expect(batch.discard_previous and batch.results.len == 0);
    try stale.next(&batch);
    try std.testing.expectEqual(search.Status.reset_required, batch.status);
}

test "search regression pending disk batches reject in-place truncation" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("many", &repeated("needle ", 300));
    const path = try f.path("many");
    defer a.free(path);
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var session = try search.Session.init(a, .{ .mode = .text, .query = "needle", .roots = &roots }, cancel);
    defer session.deinit();
    var batch = search.Batch.init(a);
    defer batch.deinit();
    while (batch.results.len == 0 and batch.status == .running) try session.next(&batch);
    try std.testing.expectEqual(@as(usize, 128), batch.results.len);
    // No directory mutation: the retained file, not the parent, must be checked.
    try std.testing.expectEqual(@as(c_int, 0), std.c.ftruncate(fd, 0));
    try session.next(&batch);
    try std.testing.expectEqual(search.Status.reset_required, batch.status);
    try std.testing.expect(batch.discard_previous and batch.results.len == 0);
    try session.next(&batch);
    try std.testing.expectEqual(search.Status.reset_required, batch.status);
}

fn truncateDuringMatch(_: usize, _: *c.GCancellable) void {
    search.TestHooks.before_query = null;
    std.debug.assert(std.c.ftruncate(mutation_fd, 0) == 0);
}

test "search regression final pending batch validates before releasing file pin" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("many", &repeated("needle ", 300));
    const path = try f.path("many");
    defer a.free(path);
    mutation_fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
    try std.testing.expect(mutation_fd >= 0);
    defer _ = std.c.close(mutation_fd);
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var session = try search.Session.init(a, .{ .mode = .text, .query = "needle", .roots = &roots }, cancel);
    defer session.deinit();
    var batch = search.Batch.init(a);
    defer batch.deinit();
    while (batch.results.len == 0 and batch.status == .running) try session.next(&batch);
    try std.testing.expectEqual(@as(usize, 128), batch.results.len);
    try session.next(&batch);
    try std.testing.expectEqual(@as(usize, 128), batch.results.len);
    search.TestHooks.before_query = truncateDuringMatch;
    defer search.TestHooks.before_query = null;
    try session.next(&batch); // Mutation occurs after the pre-match stat check.
    try std.testing.expectEqual(search.Status.reset_required, batch.status);
    try std.testing.expect(batch.discard_previous and batch.results.len == 0);
}

test "search regression denied overlay decisions retain generations including hidden parents" {
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    for ([_]bool{ false, true }) |hidden_parent| {
        for ([_]bool{ false, true }) |mutate| {
            var f = try Fixture.init();
            defer f.deinit();
            try f.mkdir("nested");
            try f.write(".gitignore", if (hidden_parent) "nested/\n" else "dirty\n");
            const ignore_path = try f.path(".gitignore");
            defer a.free(ignore_path);
            const fd = std.c.open(ignore_path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
            try std.testing.expect(fd >= 0);
            defer _ = std.c.close(fd);
            const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
            const overlays = [_]search.Overlay{.{ .root_id = root_id, .relative_path = if (hidden_parent) "nested/dirty" else "dirty", .document_id = 1, .revision = 7, .text = "needle" }};
            var session = try search.Session.init(a, .{ .mode = .text, .query = "needle", .roots = &roots, .overlays = &overlays }, cancel);
            defer session.deinit();
            var batch = search.Batch.init(a);
            defer batch.deinit();
            try session.next(&batch);
            try std.testing.expectEqual(@as(usize, 0), batch.results.len);
            try session.next(&batch); // Release the checked overlay directory.
            if (mutate) try std.testing.expectEqual(@as(c_int, 0), std.c.ftruncate(fd, 0));
            try std.testing.expectEqual(@as(usize, 0), try countAll(&session, &batch));
            try std.testing.expectEqual(if (mutate) search.Status.reset_required else search.Status.complete, batch.status);
            try std.testing.expectEqual(mutate, batch.discard_previous);
        }
    }
}

test "search regression overlays honor depth before policy I/O and retain suppression" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("nested");
    try f.write("nested/disk", "needle");
    try f.fifo("nested/.gitignore"); // Must not be opened for an over-depth overlay.
    try f.write("needle", "needle");
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    const overlays = [_]search.Overlay{
        .{ .root_id = root_id, .relative_path = "nested/disk", .document_id = 1, .revision = 1, .text = "needle" },
        .{ .root_id = root_id, .relative_path = "nested/new", .document_id = 2, .revision = 1, .text = "needle" },
    };
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    for ([_]search.Mode{ .text, .quick_open }) |mode| {
        var session = try search.Session.init(a, .{ .mode = mode, .query = "needle", .roots = &roots, .overlays = &overlays, .limits = .{ .depth = 0 } }, cancel);
        defer session.deinit();
        var batch = search.Batch.init(a);
        defer batch.deinit();
        for (0..overlays.len) |_| {
            try session.next(&batch);
            try std.testing.expectEqual(@as(usize, 0), batch.progress.pages);
            try std.testing.expectEqual(@as(usize, 0), batch.results.len);
            try std.testing.expect(batch.reasons.contains(.depth_limit));
        }
        var matches: usize = 0;
        while (batch.status == .running) {
            try session.next(&batch);
            for (batch.results) |result| {
                try std.testing.expectEqualStrings("needle", result.relative_path);
                try std.testing.expect(result.source == .disk);
            }
            if (mode == .text) matches += batch.results.len else matches = batch.results.len;
        }
        try std.testing.expectEqual(@as(usize, 1), matches);
        try std.testing.expectEqual(search.Status.incomplete, batch.status);
        try std.testing.expect(batch.reasons.contains(.depth_limit));
        try std.testing.expect(session.state.overlay_map.count() == overlays.len);
    }
}

fn writeAt(directory: c_int, name: [*:0]const u8, text: []const u8) !void {
    const fd = std.c.openat(directory, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.Fixture;
    defer _ = std.c.close(fd);
    errdefer _ = std.c.unlinkat(directory, name, 0);
    var offset: usize = 0;
    while (offset < text.len) {
        const n = std.c.write(fd, text[offset..].ptr, text.len - offset);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) return error.Fixture;
        offset += @intCast(n);
    }
}

test "search regression overlong child omission preserves valid siblings and strict browser API" {
    var f = try Fixture.init();
    defer f.deinit();
    var descriptors: [17]c_int = @splat(-1);
    descriptors[0] = std.c.open(f.base, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    try std.testing.expect(descriptors[0] >= 0);
    defer _ = std.c.close(descriptors[0]);
    var long_name: [255:0]u8 = @splat('d');
    long_name[255] = 0;
    var last_name: [253:0]u8 = @splat('e');
    last_name[253] = 0;
    var created: usize = 0;
    defer {
        while (created > 0) : (created -= 1) {
            if (descriptors[created] >= 0) _ = std.c.close(descriptors[created]);
            const name: [*:0]const u8 = if (created == 16) &last_name else &long_name;
            std.debug.assert(std.c.unlinkat(descriptors[created - 1], name, std.c.AT.REMOVEDIR) == 0);
        }
    }
    var relative_buffer: [4095]u8 = undefined;
    var length: usize = 0;
    for (0..16) |i| {
        const name: [:0]const u8 = if (i == 15) &last_name else &long_name;
        try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(descriptors[i], name, 0o700));
        created += 1;
        descriptors[i + 1] = std.c.openat(descriptors[i], name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
        try std.testing.expect(descriptors[i + 1] >= 0);
        if (i != 0) {
            relative_buffer[length] = '/';
            length += 1;
        }
        @memcpy(relative_buffer[length..][0..name.len], name);
        length += name.len;
    }
    try std.testing.expectEqual(@as(usize, 4093), length);
    try writeAt(descriptors[16], "too-long", "needle");
    defer std.debug.assert(std.c.unlinkat(descriptors[16], "too-long", 0) == 0);
    try writeAt(descriptors[16], "a", "needle"); // Exactly 4095 relative bytes.
    defer std.debug.assert(std.c.unlinkat(descriptors[16], "a", 0) == 0);
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    try std.testing.expectError(error.TooLarge, browser.scanPage(a, f.base, relative_buffer[0..length], &.{}, null, cancel));
    try std.testing.expectError(error.TooLarge, browser.scanSearchPage(a, f.base, &repeated("x", 4096), &.{}, null, cancel));
    var page = try browser.scanSearchPage(a, f.base, relative_buffer[0..length], &.{}, null, cancel);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 1), page.path_omissions);
    try std.testing.expectEqual(@as(usize, 1), page.entries.len);
    try std.testing.expectEqualStrings("a", page.entries[0].name);
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    for ([_]search.Mode{ .text, .quick_open }) |mode| {
        var session = try search.Session.init(a, .{ .mode = mode, .query = if (mode == .text) "needle" else "a", .roots = &roots }, cancel);
        defer session.deinit();
        var batch = search.Batch.init(a);
        defer batch.deinit();
        var matches: usize = 0;
        while (batch.status == .running) {
            try session.next(&batch);
            for (batch.results) |result| try std.testing.expectEqual(@as(usize, 4095), result.relative_path.len);
            if (mode == .text) matches += batch.results.len else matches = batch.results.len;
        }
        try std.testing.expectEqual(@as(usize, 1), matches);
        try std.testing.expectEqual(search.Status.incomplete, batch.status);
        try std.testing.expect(batch.reasons.contains(.path_limit));
        try std.testing.expect(batch.failure == null and !batch.discard_previous);
    }
}

test "search final overlay verification detects parents pruned after overlay delivery" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("nested");
    const roots = [_]search.Root{.{ .id = root_id, .canonical_path = f.base }};
    const overlays = [_]search.Overlay{.{ .root_id = root_id, .relative_path = "nested/deleted", .document_id = 1, .revision = 2, .text = "needle" }};
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var session = try search.Session.init(a, .{ .mode = .text, .query = "needle", .roots = &roots, .overlays = &overlays }, cancel);
    defer session.deinit();
    var batch = search.Batch.init(a);
    defer batch.deinit();
    try session.next(&batch);
    try std.testing.expectEqual(@as(usize, 1), batch.results.len);
    try session.next(&batch); // Finish the overlay's checked-directory lifetime.
    try f.write(".gitignore", "nested/\n");
    try finish(&session, &batch);
    try std.testing.expectEqual(search.Status.reset_required, batch.status);
    try std.testing.expect(batch.discard_previous);
}
