const std = @import("std");
const t = std.testing;
const model = @import("../history.zig");
const policy = @import("../../clipboard_policy.zig");
const History = model.History;

// Synthetic canonical-boundary fixtures, not decoder inputs. The production
// caller must supply PNG bytes from the existing sanitizer, just as documented
// by History.copy. These exercise policy bounds without importing GTK.
fn png(size: usize, marker: u8) ![]u8 {
    const bytes = try t.allocator.alloc(u8, size);
    @memset(bytes, marker);
    @memcpy(bytes[0..16], "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR");
    std.mem.writeInt(u32, bytes[16..20], 1, .big);
    std.mem.writeInt(u32, bytes[20..24], 1, .big);
    return bytes;
}

fn fill(history: *History) !void {
    for (0..100) |i| {
        var buffer: [24]u8 = undefined;
        _ = try history.copy(.text, try std.fmt.bufPrint(&buffer, "entry {d}", .{i}), @intCast(i));
    }
}

fn expectAccounting(history: *const History) !void {
    var sum: usize = 0;
    try t.expect(history.entries().len <= 100);
    for (history.entries()) |entry| sum += entry.bytes.len;
    try t.expectEqual(sum, history.total_bytes);
    try t.expect(sum <= 16 * 1024 * 1024);
}

test "history inserts independently owned text and memory-only PNG" {
    var history = History.init(t.allocator);
    defer history.deinit();
    var text = [_]u8{ 'h', 'i' };
    const text_id = try history.copy(.text, &text, 10);
    text[0] = 'X';
    const image = try png(33, 1);
    defer t.allocator.free(image);
    const image_id = try history.copy(.png, image, 11);
    image[32] = 2;
    try t.expect(text_id != image_id);
    try t.expectEqual(@as(usize, 2), history.entries().len);
    try t.expectEqual(policy.Kind.png, history.entries()[0].kind);
    try t.expectEqual(@as(u8, 1), history.entries()[0].bytes[32]);
    try t.expectEqualStrings("hi", history.entries()[1].bytes);
    try expectAccounting(&history);
}

test "history retains 100 entries and evicts the oldest on copy 101" {
    var history = History.init(t.allocator);
    defer history.deinit();
    try fill(&history);
    try t.expectEqual(@as(usize, 100), history.entries().len);
    const oldest = history.entries()[99].id;
    const second_oldest = history.entries()[98].id;
    const newest = try history.copy(.text, "entry 100", 100);
    try t.expectEqual(@as(usize, 100), history.entries().len);
    try t.expectEqual(newest, history.entries()[0].id);
    try t.expectEqual(second_oldest, history.entries()[99].id);
    try t.expect(!history.delete(oldest));
    try expectAccounting(&history);
}

test "history text size boundary is 256 KiB" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const bytes = try t.allocator.alloc(u8, 256 * 1024 + 1);
    defer t.allocator.free(bytes);
    @memset(bytes, 'a');
    const id = try history.copy(.text, bytes[0 .. 256 * 1024], 0);
    try t.expectError(error.InvalidPayload, history.copy(.text, bytes, 1));
    try t.expectEqual(id, history.entries()[0].id);
    try expectAccounting(&history);
}

test "history rejects empty text invalid UTF-8 embedded NUL and invalid PNG" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const id = try history.copy(.text, "retained", 0);
    for ([_][]const u8{ "", "\xff", "a\x00b", "\xc0\xaf" }) |bytes| {
        try t.expectError(error.InvalidPayload, history.copy(.text, bytes, 1));
        try t.expectError(error.InvalidPayload, history.restoreText(bytes, 0, 1));
    }
    try t.expectError(error.InvalidPayload, history.copy(.png, "<svg/>", 1));
    try t.expectEqual(@as(usize, 1), history.entries().len);
    try t.expectEqual(id, history.entries()[0].id);
}

test "history enforces the 16 MiB combined text and PNG payload boundary" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const image = try png(policy.image_limit, 1);
    defer t.allocator.free(image);
    const text = try t.allocator.alloc(u8, policy.text_limit);
    defer t.allocator.free(text);
    @memset(text, 'a');
    var oldest: u64 = 0;
    for (0..32) |i| {
        text[0] = @intCast(33 + i);
        const id = try history.copy(.text, text, 0);
        if (i == 0) oldest = id;
    }
    _ = try history.copy(.png, image, 0);
    try t.expectEqual(@as(usize, 16 * 1024 * 1024), history.total_bytes);
    _ = try history.copy(.text, "x", 0);
    try t.expect(!history.delete(oldest));
    try t.expectEqual(@as(usize, 33), history.entries().len);
    try expectAccounting(&history);
}

test "history PNG evicts text and the oldest PNG by byte budget" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const image = try png(policy.image_limit, 1);
    defer t.allocator.free(image);
    const text_id = try history.copy(.text, "old text", 0);
    const first_image = try history.copy(.png, image, 1);
    image[32] = 2;
    const second_image = try history.copy(.png, image, 2);
    try t.expect(!history.delete(text_id));
    try t.expectEqual(@as(usize, 16 * 1024 * 1024), history.total_bytes);
    image[32] = 3;
    _ = try history.copy(.png, image, 3);
    try t.expect(!history.delete(first_image));
    try t.expectEqual(second_image, history.entries()[1].id);
    try expectAccounting(&history);
}

test "history exact duplicates retain IDs move to front and refresh time" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const a = try history.copy(.text, "a", 1);
    const b = try history.copy(.text, "b", 2);
    try t.expectEqual(a, try history.copy(.text, "a", 3));
    try t.expectEqual(@as(usize, 2), history.entries().len);
    try t.expectEqual(a, history.entries()[0].id);
    try t.expectEqual(b, history.entries()[1].id);
    try t.expectEqual(@as(i64, 3), history.entries()[0].last_copy);
    try t.expectEqual(a, try history.copy(.text, "a", 4));
    try t.expectEqual(@as(i64, 4), history.entries()[0].last_copy);
    try t.expectEqual(@as(usize, 2), history.total_bytes);
}

test "history deduplication uses kind and full bytes without normalization" {
    var history = History.init(t.allocator);
    defer history.deinit();
    for ([_][]const u8{ "a", "a ", "A", "é", "e\xcc\x81" }) |bytes| _ = try history.copy(.text, bytes, 0);
    const image = try png(33, 1);
    defer t.allocator.free(image);
    const id = try history.copy(.png, image, 1);
    _ = try history.copy(.text, "another", 1);
    try t.expectEqual(id, try history.copy(.png, image, 2));
    image[32] = 2;
    _ = try history.copy(.png, image, 2);
    try t.expectEqual(@as(usize, 8), history.entries().len);
    var first: [122]u8 = @splat('x');
    _ = try history.copy(.text, &first, 2);
    first[121] = 'y';
    _ = try history.copy(.text, &first, 2);
    try t.expectEqual(@as(usize, 10), history.entries().len);
}

test "history same-second copies preserve event ordering" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const a = try history.copy(.text, "a", 0);
    _ = try history.copy(.text, "b", 0);
    try t.expectEqual(a, try history.copy(.text, "a", 0));
    try t.expectEqual(a, history.entries()[0].id);
}

test "history expires at exactly seven days for text and PNG" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const image = try png(33, 1);
    defer t.allocator.free(image);
    _ = try history.copy(.text, "a", 10);
    _ = try history.copy(.png, image, 11);
    try t.expectEqual(@as(usize, 0), try history.prune(10 + 604799));
    try t.expectEqual(@as(usize, 1), try history.prune(10 + 604800));
    try t.expectEqual(policy.Kind.png, history.entries()[0].kind);
    try t.expectEqual(@as(usize, 1), try history.prune(11 + 604800));
    try expectAccounting(&history);
}

test "history recopy including front entry extends expiration" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const id = try history.copy(.text, "a", 0);
    try t.expectEqual(id, try history.copy(.text, "a", 604799));
    try t.expectEqual(@as(usize, 0), try history.prune(604800));
    try t.expectEqual(@as(usize, 0), try history.prune(604799 + 604799));
    try t.expectEqual(@as(usize, 1), try history.prune(604799 + 604800));
}

test "history expires before deduplication and admission" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const id = try history.copy(.text, "expired", 0);
    const next = try history.copy(.text, "expired", 604800);
    try t.expect(next != id);
    try t.expectEqual(@as(usize, 1), history.entries().len);
    try t.expectEqual(@as(i64, 604800), history.entries()[0].last_copy);
    try expectAccounting(&history);
}

test "history delete and clear release payloads and never reuse IDs" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const a = try history.copy(.text, "a", 0);
    const b = try history.copy(.text, "bb", 0);
    const c = try history.copy(.text, "ccc", 0);
    try t.expect(history.delete(b));
    try t.expect(!history.delete(b));
    try t.expectEqual(c, history.entries()[0].id);
    try t.expectEqual(a, history.entries()[1].id);
    try t.expectEqual(@as(usize, 4), history.total_bytes);
    history.clear();
    history.clear();
    try t.expectEqual(@as(usize, 0), history.entries().len);
    try t.expectEqual(@as(usize, 0), history.total_bytes);
    try t.expect(try history.copy(.text, "a", 0) > c);
}

test "history restores text at original timestamp in newest-first order" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const old = (try history.restoreText("old", 10, 30)).?;
    const newest = (try history.restoreText("newest", 30, 30)).?;
    const middle = (try history.restoreText("middle", 20, 30)).?;
    try t.expectEqual(newest, history.entries()[0].id);
    try t.expectEqual(middle, history.entries()[1].id);
    try t.expectEqual(old, history.entries()[2].id);
    try t.expectEqual(@as(i64, 10), history.entries()[2].last_copy);
    try t.expectEqual(@as(usize, 1), try history.prune(10 + 604800));
}

test "history restore never refreshes duplicate lifetime to load time" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const id = (try history.restoreText("a", 20, 100)).?;
    try t.expectEqual(id, (try history.restoreText("a", 10, 100)).?);
    try t.expectEqual(@as(i64, 20), history.entries()[0].last_copy);
    try t.expectEqual(id, (try history.restoreText("a", 30, 100)).?);
    try t.expectEqual(@as(i64, 30), history.entries()[0].last_copy);
    try t.expectEqual(@as(usize, 1), history.entries().len);
}

test "history restore excludes expired records including exact boundary" {
    var history = History.init(t.allocator);
    defer history.deinit();
    try t.expectEqual(@as(?u64, null), try history.restoreText("expired", 0, 604800));
    try t.expect((try history.restoreText("alive", 1, 604800)) != null);
    try t.expectEqual(@as(usize, 1), history.entries().len);
}

test "history restoring an older full-capacity record preserves newer entries" {
    var history = History.init(t.allocator);
    defer history.deinit();
    try fill(&history);
    const tail = history.entries()[99].id;
    try t.expectEqual(@as(?u64, null), try history.restoreText("older", 0, 100));
    try t.expectEqual(tail, history.entries()[99].id);
    try t.expectEqual(@as(usize, 100), history.entries().len);
    try expectAccounting(&history);
}

test "history persistent record iterator excludes PNG and preserves text times" {
    var history = History.init(t.allocator);
    defer history.deinit();
    _ = try history.copy(.text, "a", 10);
    const image = try png(33, 1);
    defer t.allocator.free(image);
    _ = try history.copy(.png, image, 20);
    _ = try history.copy(.text, "b", 30);
    var records = history.textRecords();
    const b = records.next().?;
    try t.expectEqualStrings("b", b.bytes);
    try t.expectEqual(@as(i64, 30), b.last_copy);
    const a = records.next().?;
    try t.expectEqualStrings("a", a.bytes);
    try t.expectEqual(@as(i64, 10), a.last_copy);
    try t.expectEqual(@as(?model.TextRecord, null), records.next());
}

test "history rejects negative future and inconsistent timestamps without mutation" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const id = try history.copy(.text, "a", 10);
    try t.expectError(error.InvalidTime, history.copy(.text, "b", -1));
    try t.expectError(error.InvalidTime, history.copy(.text, "b", 9));
    try t.expectError(error.InvalidTime, history.prune(9));
    try t.expectError(error.InvalidTime, history.restoreText("b", -1, 10));
    try t.expectError(error.InvalidTime, history.restoreText("b", 11, 10));
    try t.expectEqual(id, history.entries()[0].id);
    try t.expectEqual(@as(usize, 1), history.entries().len);
}

test "history timestamp arithmetic is safe at i64 maximum" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const end = std.math.maxInt(i64);
    _ = try history.copy(.text, "boundary", end - 604800);
    try t.expectEqual(@as(usize, 0), try history.prune(end - 1));
    try t.expectEqual(@as(usize, 1), try history.prune(end));
    _ = try history.copy(.text, "max", end);
    try t.expectEqual(@as(usize, 0), try history.prune(end));
}

test "history counter exhaustion is atomic and duplicate refresh needs no new ID" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const id = try history.copy(.text, "a", 0);
    history.next_id = std.math.maxInt(u64);
    try t.expectError(error.CounterExhausted, history.copy(.text, "b", 1));
    try t.expectError(error.CounterExhausted, history.restoreText("b", 0, 1));
    try t.expectEqual(id, try history.copy(.text, "a", 2));
    try t.expectEqual(@as(usize, 1), history.entries().len);
    try t.expectEqual(@as(i64, 2), history.entries()[0].last_copy);
    history.clear();
    try t.expectError(error.CounterExhausted, history.copy(.text, "b", 2));
}

test "history allocation failure cannot evict a full history or consume an ID" {
    var failing = std.testing.FailingAllocator.init(t.allocator, .{});
    var history = History.init(failing.allocator());
    defer history.deinit();
    try fill(&history);
    const next_id = history.next_id;
    const total = history.total_bytes;
    const tail = history.entries()[99].id;
    failing.fail_index = failing.alloc_index;
    try t.expectError(error.OutOfMemory, history.copy(.text, "new", 100));
    try t.expectError(error.OutOfMemory, history.restoreText("restore", 100, 100));
    try t.expectEqual(next_id, history.next_id);
    try t.expectEqual(total, history.total_bytes);
    try t.expectEqual(tail, history.entries()[99].id);
    try t.expectEqual(@as(usize, 100), history.entries().len);
    const id = history.entries()[0].id;
    try t.expectEqual(id, try history.copy(.text, "entry 99", 100));
    try t.expectEqual(@as(i64, 100), history.entries()[0].last_copy);
}

fn allocationLifecycle(allocator: std.mem.Allocator) !void {
    var history = History.init(allocator);
    defer history.deinit();
    const a = try history.copy(.text, "a", 0);
    _ = try history.copy(.text, "b", 1);
    _ = try history.restoreText("c", 2, 2);
    _ = try history.copy(.text, "a", 3);
    try t.expect(history.delete(a));
    _ = try history.prune(604802);
    history.clear();
    _ = try history.copy(.text, "after clear", 604803);
}

test "history cleans up every allocation failure point and normal lifetime" {
    try t.checkAllAllocationFailures(t.allocator, allocationLifecycle, .{});
}

test "history one PNG evicts multiple oldest text entries" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const text = try t.allocator.alloc(u8, policy.text_limit);
    defer t.allocator.free(text);
    @memset(text, 'x');
    var ids: [64]u64 = undefined;
    for (&ids, 0..) |*id, i| {
        text[0] = @intCast(33 + i);
        id.* = try history.copy(.text, text, 0);
    }
    const image = try png(policy.image_limit, 1);
    defer t.allocator.free(image);
    _ = try history.copy(.png, image, 1);
    try t.expectEqual(@as(usize, 33), history.entries().len);
    try t.expectEqual(ids[32], history.entries()[32].id);
    for (ids[0..32]) |id| try t.expect(!history.delete(id));
    try t.expectEqual(@as(usize, 16 * 1024 * 1024), history.total_bytes);
    try expectAccounting(&history);
}

test "history prunes expired PNG before admitting a replacement" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const image = try png(policy.image_limit, 1);
    defer t.allocator.free(image);
    const old = try history.copy(.png, image, 0);
    const text = try history.copy(.text, "still alive", 1);
    image[32] = 2;
    _ = try history.copy(.png, image, 604800);
    try t.expect(!history.delete(old));
    try t.expectEqual(@as(usize, 2), history.entries().len);
    try t.expectEqual(text, history.entries()[1].id);
    try expectAccounting(&history);
}

test "history restores into a byte-limited history in saved time order" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const image = try png(policy.image_limit, 1);
    defer t.allocator.free(image);
    const old = try history.copy(.png, image, 10);
    image[32] = 2;
    const recent = try history.copy(.png, image, 11);
    try t.expectEqual(@as(?u64, null), try history.restoreText("too old", 0, 20));
    try t.expectEqual(@as(usize, 2), history.entries().len);
    const restored = (try history.restoreText("newer", 12, 20)).?;
    try t.expectEqual(restored, history.entries()[0].id);
    try t.expectEqual(@as(i64, 12), history.entries()[0].last_copy);
    try t.expectEqual(recent, history.entries()[1].id);
    try t.expect(!history.delete(old));
    try expectAccounting(&history);
}

test "history restore preserves equal-time input order and reorders newer duplicates" {
    var history = History.init(t.allocator);
    defer history.deinit();
    const a = (try history.restoreText("a", 10, 100)).?;
    const b = (try history.restoreText("b", 10, 100)).?;
    try t.expectEqual(a, history.entries()[0].id);
    try t.expectEqual(b, history.entries()[1].id);
    try t.expectEqual(b, (try history.restoreText("b", 20, 100)).?);
    try t.expectEqual(b, history.entries()[0].id);
    try t.expectEqual(@as(i64, 20), history.entries()[0].last_copy);
}

test "history failure preserves expired rows until successful admission" {
    var failing = std.testing.FailingAllocator.init(t.allocator, .{});
    var history = History.init(failing.allocator());
    defer history.deinit();
    const old = try history.copy(.text, "expired", 0);
    failing.fail_index = failing.alloc_index;
    try t.expectError(error.OutOfMemory, history.copy(.text, "replacement", 604800));
    try t.expectEqual(@as(usize, 1), history.entries().len);
    try t.expectEqual(old, history.entries()[0].id);
    try t.expectEqual(@as(i64, 0), history.entries()[0].last_copy);
    failing.fail_index = std.math.maxInt(usize);
    // Caller input may itself be borrowed from the row about to expire.
    const replacement = try history.copy(.text, history.entries()[0].bytes, 604800);
    try t.expect(replacement != old);
    try t.expectEqualStrings("expired", history.entries()[0].bytes);
}

test "history delete expiry clear and deinit release every owned allocation once" {
    var tracking = std.testing.FailingAllocator.init(t.allocator, .{});
    var history = History.init(tracking.allocator());
    defer history.deinit();
    const id = try history.copy(.text, "deletion", 0);
    try t.expect(history.delete(id));
    try t.expectEqual(@as(usize, 1), tracking.deallocations);
    try t.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
    _ = try history.copy(.text, "expiration", 0);
    _ = try history.prune(604800);
    try t.expectEqual(@as(usize, 2), tracking.deallocations);
    try t.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
    _ = try history.copy(.text, "clear", 604800);
    history.clear();
    try t.expectEqual(@as(usize, 3), tracking.deallocations);
    try t.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
    _ = try history.copy(.text, "deinit", 604800);
    history.deinit();
    try t.expectEqual(@as(usize, 4), tracking.deallocations);
    try t.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
}
