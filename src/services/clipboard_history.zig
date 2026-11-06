//! Text-only disk representation. Callers own returned allocations in their arena.
const std = @import("std");
const policy = @import("clipboard_policy.zig");
pub const file_limit = 128 * 1024 * 1024;
pub const SavedEntry = struct { text: []const u8, last_used: i64 };

fn newestFirst(_: void, left: SavedEntry, right: SavedEntry) bool {
    return left.last_used > right.last_used;
}

pub fn expired(last_used: i64, now: i64) bool {
    return last_used <= now -| policy.retention_seconds;
}

pub fn decode(a: std.mem.Allocator, bytes: []const u8, now: i64) ![]SavedEntry {
    if (bytes.len > file_limit) return error.FileTooLarge;
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    if (input != .array) return error.InvalidHistory;
    var entries: std.ArrayList(SavedEntry) = .empty;
    for (input.array.items) |item| {
        if (item != .object) continue;
        const text = item.object.get("text") orelse continue;
        const time = item.object.get("last_used") orelse continue;
        if (text != .string or time != .integer or time.integer < 0) continue;
        const timestamp = @min(time.integer, now);
        if (!policy.valid(.text, text.string) or expired(timestamp, now)) continue;
        var duplicate = false;
        for (entries.items) |*entry| {
            if (std.mem.eql(u8, entry.text, text.string)) {
                entry.last_used = @max(entry.last_used, timestamp);
                duplicate = true;
                break;
            }
        }
        if (!duplicate) try entries.append(a, .{ .text = text.string, .last_used = timestamp });
        // Bound duplicate searches and sorting even for an oversized record list.
        std.mem.sort(SavedEntry, entries.items, {}, newestFirst);
        if (entries.items.len > policy.entries_limit) _ = entries.pop();
    }
    var total: usize = 0;
    var count: usize = 0;
    for (entries.items) |entry| {
        if (count == policy.entries_limit or total + entry.text.len > policy.total_limit) break;
        total += entry.text.len;
        count += 1;
    }
    return entries.items[0..count];
}

pub fn encode(a: std.mem.Allocator, entries: anytype) ![]u8 {
    var saved: std.ArrayList(SavedEntry) = .empty;
    defer saved.deinit(a);
    for (entries) |entry| {
        if (entry.kind == .text) try saved.append(a, .{ .text = entry.bytes, .last_used = entry.last_used });
    }
    return std.json.Stringify.valueAlloc(a, saved.items, .{});
}

test "history round trip excludes images and expires at seven days" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Entry = struct { kind: policy.Kind, bytes: []const u8, last_used: i64 };
    const now: i64 = 2_000_000;
    const json = try encode(a, &[_]Entry{
        .{ .kind = .text, .bytes = "hello\n\"👋\"", .last_used = now },
        .{ .kind = .png, .bytes = "image-secret", .last_used = now },
        .{ .kind = .text, .bytes = "expired", .last_used = now - policy.retention_seconds },
    });
    try std.testing.expect(std.mem.indexOf(u8, json, "image-secret") == null);
    const entries = try decode(a, json, now);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("hello\n\"👋\"", entries[0].text);
    try std.testing.expect(!expired(now - policy.retention_seconds + 1, now));
}

test "history validates, deduplicates, sorts and caps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try decode(a,
        \\[{"text":"a","last_used":100},{"text":"b","last_used":200},{"text":"a","last_used":300},{"text":"","last_used":300},{"text":"bad\u0000","last_used":300},{"text":"negative","last_used":-1}]
    , 300);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("a", entries[0].text);
    try std.testing.expectEqual(@as(i64, 300), entries[0].last_used);
    var many: std.ArrayList(SavedEntry) = .empty;
    for (0..25) |i| try many.append(a, .{ .text = try std.fmt.allocPrint(a, "entry-{d}", .{i}), .last_used = @intCast(i + 1) });
    const capped = try decode(a, try std.json.Stringify.valueAlloc(a, many.items, .{}), 200);
    try std.testing.expectEqual(@as(usize, 20), capped.len);
    try std.testing.expectEqualStrings("entry-24", capped[0].text);
    try std.testing.expectError(error.InvalidHistory, decode(a, "{}", 200));
    try std.testing.expectError(error.SyntaxError, decode(a, "invalid", 200));
}

test "loaded history clamps future dates and enforces text and aggregate limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const future = try decode(a, "[{\"text\":\"future\",\"last_used\":999999}]", 300);
    try std.testing.expectEqual(@as(i64, 300), future[0].last_used);
    var saved: std.ArrayList(SavedEntry) = .empty;
    const too_large = try a.alloc(u8, policy.text_limit + 1);
    @memset(too_large, 'x');
    try saved.append(a, .{ .text = too_large, .last_used = 300 });
    for (0..70) |i| {
        const text = try a.alloc(u8, policy.text_limit);
        @memset(text, @intCast(33 + i));
        try saved.append(a, .{ .text = text, .last_used = 300 });
    }
    const result = try decode(a, try std.json.Stringify.valueAlloc(a, saved.items, .{}), 300);
    try std.testing.expectEqual(@as(usize, 20), result.len);
    try std.testing.expect(result.len * policy.text_limit <= policy.total_limit);
    for (result) |entry| try std.testing.expectEqual(policy.text_limit, entry.text.len);
}
