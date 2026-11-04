//! Service regressions run without GTK initialization or a compositor.
const std = @import("std");
const fixture = @import("testing/clipboard.zig");
const t = std.testing;

test {
    _ = @import("desktop/clipboard_capture.zig");
}

test "history access notifies an open consumer once after successful expiry" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.copy("expired preview", 100);
    f.read_on_change = true;
    f.clipboard.test_time = fixture.at(100 + 604800);
    try t.expectEqual(@as(usize, 0), f.clipboard.entries().len);
    try t.expectEqual(@as(usize, 1), f.notifications);
    try t.expectEqual(@as(usize, 0), f.observed_len);
    const token = f.clipboard.session.?.last_token;
    _ = f.clipboard.session.?.worker.?.waitIdle();
    _ = f.clipboard.entries();
    try t.expectEqual(@as(usize, 1), f.notifications);
    try t.expectEqual(token, f.clipboard.session.?.last_token);
    try t.expectEqual(.durable, (try f.clipboard.session.?.removal()).state);
}

test "Busy history access synchronously invalidates an open consumer and does not recurse" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.copy("expired preview", 100);
    try f.blockRemoval();
    const token = f.clipboard.session.?.last_token;
    f.read_on_change = true;
    f.clipboard.test_time = fixture.at(100 + 604800);
    try t.expectEqual(@as(usize, 0), f.clipboard.entries().len);
    try t.expect(!f.preview_visible);
    try t.expectEqual(@as(usize, 1), f.notifications);
    try t.expectEqual(@as(usize, 0), f.observed_len);
    try t.expectError(error.Busy, f.clipboard.select(id));
    try t.expectEqual(@as(usize, 1), f.notifications);
    try t.expectEqual(token, f.clipboard.session.?.last_token);
}

test "allocation failure during history access hides previews without a completion or recursive retry" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.copy("expired preview", 100);
    var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    f.clipboard.session.?.allocator = failing.allocator();
    defer f.clipboard.session.?.allocator = t.allocator;
    f.read_on_change = true;
    f.clipboard.test_time = fixture.at(100 + 604800);
    try t.expectEqual(@as(usize, 0), f.clipboard.entries().len);
    try t.expect(!f.preview_visible);
    try t.expectEqual(@as(usize, 1), f.notifications);
    try t.expectEqual(@as(usize, 1), f.clipboard.session.?.model.len);
    try t.expect(f.clipboard.session.?.last_token == null);
    f.clipboard.session.?.allocator = t.allocator;
    try t.expectEqual(@as(usize, 0), f.clipboard.entries().len);
    try t.expectEqual(@as(usize, 2), f.notifications);
}

test "failed selection preparation notifies for both expired and live selections beside expired rows" {
    for ([_]bool{ false, true }) |live| {
        var f: fixture.Fixture = undefined;
        try f.init();
        defer f.deinit();
        const expired_id = try f.copy("expired preview", 100);
        const live_id = try f.copy("live preview", 200);
        var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
        f.clipboard.session.?.allocator = failing.allocator();
        defer f.clipboard.session.?.allocator = t.allocator;
        f.read_on_change = true;
        f.clipboard.test_time = fixture.at(100 + 604800);
        try t.expectError(error.OutOfMemory, f.clipboard.select(if (live) live_id else expired_id));
        try t.expect(!f.preview_visible);
        try t.expectEqual(@as(usize, 1), f.notifications);
        try t.expectEqual(@as(usize, 0), f.observed_len);
        try t.expectEqual(@as(usize, 2), f.clipboard.session.?.model.len);
    }
}

test "stale selection notifies after admitting its expiry barrier" {
    var f: fixture.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.copy("expired preview", 100);
    f.clipboard.test_time = fixture.at(100 + 604800);
    try t.expectError(error.Stale, f.clipboard.select(id));
    try t.expectEqual(@as(usize, 1), f.notifications);
    try t.expectEqual(@as(usize, 0), f.clipboard.session.?.model.len);
    _ = f.clipboard.session.?.worker.?.waitIdle();
    try t.expectEqual(.durable, (try f.clipboard.session.?.removal()).state);
}

test "failed capture and copy preparation also withhold expired previews" {
    for ([_]bool{ false, true }) |publish| {
        var f: fixture.Fixture = undefined;
        try f.init();
        defer f.deinit();
        _ = try f.copy("expired preview", 100);
        var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
        f.clipboard.session.?.allocator = failing.allocator();
        defer f.clipboard.session.?.allocator = t.allocator;
        f.clipboard.test_time = fixture.at(100 + 604800);
        if (publish) {
            try t.expectError(error.OutOfMemory, f.clipboard.copyText("new copy"));
        } else try t.expectError(error.OutOfMemory, f.clipboard.add(.text, "new capture"));
        try t.expect(!f.preview_visible);
        try t.expectEqual(@as(usize, 1), f.notifications);
        try t.expectEqual(@as(usize, 1), f.clipboard.session.?.model.len);
    }
}
