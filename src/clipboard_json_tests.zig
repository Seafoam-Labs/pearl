//! History, paging and PNG regressions without a compositor or clipboard ownership.
const std = @import("std");
const service = @import("services/clipboard.zig");
const history = @import("services/clipboard_history.zig");
const t = std.testing;
test {
    _ = history;
    _ = @import("clipboard_history_tests.zig");
    _ = @import("desktop/clipboard_capture.zig");
}

const Fixture = @import("testing/clipboard.zig").Fixture;

test "duplicate promotion preserves identity and refreshes activity-driven expiry" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    for (0..3) |index| {
        var buffer: [32]u8 = undefined;
        try f.clipboard.add(.text, try std.fmt.bufPrint(&buffer, "entry-{d}", .{index}));
    }
    const id = f.clipboard.rows[1].id;
    f.clipboard.test_time = 200;
    try f.clipboard.add(.text, "entry-1");
    try t.expectEqual(@as(usize, 3), f.clipboard.len);
    try t.expectEqual(id, f.clipboard.rows[0].id);
    try t.expectEqual(@as(i64, 200), f.clipboard.rows[0].last_used);
    f.clipboard.device = @ptrFromInt(1); // availability only; never dispatched
    f.clipboard.test_time = 100 + service.policy.retention_seconds;
    const before = f.notifications;
    try t.expectEqual(@as(usize, 1), f.clipboard.entries().len);
    try t.expectEqual(before + 1, f.notifications);
    try t.expectEqual(id, f.clipboard.entries()[0].id);
}

test "failed saves preserve availability and removals report memory disk divergence" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    f.fail = true;
    try f.clipboard.add(.text, "still captured");
    f.clipboard.device = @ptrFromInt(1);
    try t.expect(f.clipboard.accessible() and f.clipboard.dirty);
    try t.expectError(error.SaveFailed, f.clipboard.delete(f.clipboard.rows[0].id));
    try t.expectEqual(@as(usize, 0), f.clipboard.len);
    try t.expect(f.clipboard.removal_failed and f.clipboard.dirty);
    const before = f.writes;
    try t.expectError(error.SaveFailed, f.clipboard.clear());
    try t.expectEqual(before + 1, f.writes);
    f.fail = false;
    try f.clipboard.clear();
    try t.expect(!f.clipboard.dirty and f.clipboard.persistence_error == null and !f.clipboard.removal_failed);
}

test "lock retains text without refreshing it and discards PNG without saving" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.clipboard.add(.text, "private retained text");
    // Synthetic PNG metadata exercises suspension, not the image decoder.
    const png = try std.heap.c_allocator.dupe(u8, "synthetic-image");
    f.clipboard.rows[1] = .{ .id = 2, .kind = .png, .bytes = png, .last_used = 100 };
    f.clipboard.len += 1;
    f.clipboard.total_bytes += png.len;
    const writes = f.writes;
    f.clipboard.setLocked(true);
    try t.expectEqual(@as(usize, 1), f.clipboard.len);
    try t.expectEqual(@as(usize, 0), f.clipboard.entries().len);
    try t.expectEqual(writes, f.writes);
    try t.expectError(error.Locked, f.clipboard.add(.text, "locked selection"));
    f.clipboard.test_time = 200;
    f.clipboard.setLocked(false);
    try t.expectEqual(@as(usize, 1), f.clipboard.len);
    try t.expectEqual(service.policy.Kind.text, f.clipboard.rows[0].kind);
    try t.expectEqual(@as(i64, 100), f.clipboard.rows[0].last_used);
    try t.expectEqual(writes, f.writes);
}

test "status pages bound escaped frames and reject stale instances and revisions" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    for (0..100) |index| {
        var text: [128]u8 = @splat('"');
        text[127] = @intCast(33 + index % 90);
        text[126] = @intCast(33 + index / 90);
        try f.clipboard.add(.text, &text);
    }
    f.clipboard.device = @ptrFromInt(1);
    var offset: u16 = 0;
    while (offset < 100) {
        const json = try f.clipboard.pageStatus(t.allocator, .{ .offset = offset, .revision = f.clipboard.revision, .instance = &f.clipboard.instance });
        defer t.allocator.free(json);
        try t.expect(@import("cli/frame.zig").successLength("18446744073709551615", json) <= 8192);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, json, .{});
        defer parsed.deinit();
        const count: u16 = @intCast(parsed.value.object.get("returned").?.integer);
        try t.expect(count > 0);
        offset += count;
    }
    try t.expectEqual(@as(u16, 100), offset);
    try t.expectError(error.StaleInstance, f.clipboard.pageStatus(t.allocator, .{ .instance = "wrong" }));
    try t.expectError(error.StaleRevision, f.clipboard.pageStatus(t.allocator, .{ .revision = f.clipboard.revision - 1 }));
}

test "combined capacity evicts entry 101 and PNG duplicates keep identities without saves" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const png = try @import("testing/clipboard.zig").image(0xabcdefFF);
    defer std.heap.c_allocator.free(png);
    for (0..99) |index| {
        var buffer: [32]u8 = undefined;
        try f.clipboard.add(.text, try std.fmt.bufPrint(&buffer, "mixed-{d}", .{index}));
    }
    const writes = f.writes;
    try f.clipboard.add(.png, png);
    const image_id = f.clipboard.rows[0].id;
    try t.expectEqual(writes, f.writes);
    try t.expectEqual(@as(usize, 100), f.clipboard.len);
    try f.clipboard.add(.text, "entry 101");
    try t.expectEqual(@as(usize, 100), f.clipboard.len);
    try t.expectEqualStrings("mixed-1", f.clipboard.rows[99].bytes);
    const before = f.writes;
    f.clipboard.test_time = 200;
    try f.clipboard.add(.png, png);
    try t.expectEqual(image_id, f.clipboard.rows[0].id);
    try t.expectEqual(@as(i64, 200), f.clipboard.rows[0].last_used);
    try t.expectEqual(before, f.writes);
}

test "PNG byte-budget eviction persists removed text and lazy PNG expiry does not save" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const text = try t.allocator.alloc(u8, service.policy.text_limit);
    defer t.allocator.free(text);
    for (0..64) |index| {
        @memset(text, @intCast(33 + index));
        try f.clipboard.add(.text, text);
    }
    try t.expectEqual(service.policy.total_limit, f.clipboard.total_bytes);
    const png = try @import("testing/clipboard.zig").image(0x123456ff);
    defer std.heap.c_allocator.free(png);
    const writes = f.writes;
    try f.clipboard.add(.png, png);
    try t.expectEqual(writes + 1, f.writes);
    try t.expect(f.clipboard.total_bytes <= service.policy.total_limit);
    try f.clipboard.clear();
    try f.clipboard.add(.png, png);
    const png_writes = f.writes;
    f.clipboard.test_time = 100 + service.policy.retention_seconds;
    try t.expectEqual(@as(usize, 1), f.clipboard.len); // no timer ran
    f.clipboard.device = @ptrFromInt(1);
    try t.expectEqual(@as(usize, 0), f.clipboard.entries().len);
    try t.expectEqual(png_writes, f.writes);
}

test "service rejects invalid and oversized payloads without damaging existing history" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const text = try t.allocator.alloc(u8, service.policy.text_limit + 1);
    defer t.allocator.free(text);
    @memset(text, 'x');
    try f.clipboard.add(.text, text[0..service.policy.text_limit]);
    const id = f.clipboard.rows[0].id;
    for ([_][]const u8{ "", "\xff", "a\x00b", text }) |invalid| try t.expectError(error.InvalidPayload, f.clipboard.add(.text, invalid));
    const png = try t.allocator.alloc(u8, service.policy.image_limit + 1);
    defer t.allocator.free(png);
    @memset(png, 0);
    @memcpy(png[0..16], "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR");
    std.mem.writeInt(u32, png[16..20], 1, .big);
    std.mem.writeInt(u32, png[20..24], 1, .big);
    try t.expect(service.policy.valid(.png, png[0..service.policy.image_limit]));
    try t.expectError(error.InvalidPayload, f.clipboard.add(.png, png));
    try t.expectEqual(@as(usize, 1), f.clipboard.len);
    try t.expectEqual(id, f.clipboard.rows[0].id);
}

test "locked status hides history paging and errors while entry actions fail closed" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.clipboard.add(.text, "hidden retained text");
    const id = f.clipboard.rows[0].id;
    f.clipboard.setLocked(true);
    const bytes = try f.clipboard.pageStatus(t.allocator, .{});
    defer t.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, bytes, .{});
    defer parsed.deinit();
    try t.expectEqual(@as(usize, 0), parsed.value.object.get("entries").?.array.items.len);
    for ([_][]const u8{ "total", "offset", "returned", "next_offset", "revision", "instance", "persistence_error" }) |field| try t.expect(parsed.value.object.get(field).? == .null);
    try t.expectError(error.Locked, f.clipboard.select(id));
    try t.expectError(error.Locked, f.clipboard.delete(id));
    try t.expectError(error.Locked, f.clipboard.clear());
    try t.expectError(error.Locked, f.clipboard.checkInstance(&f.clipboard.instance));
}
