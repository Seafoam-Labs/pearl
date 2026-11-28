//! Text-only JSON snapshots. Returned slices belong to the caller's arena.
const std = @import("std");
const policy = @import("clipboard_policy.zig");
pub const SavedEntry = struct { text: []const u8, last_used: i64 };
pub const Decoded = struct { entries: []SavedEntry, changed: bool };
// Every payload byte can need six JSON bytes; leave room for record metadata.
pub const file_limit = 6 * policy.total_limit + 128 * policy.entries_limit + 2;

pub fn expired(last_used: i64, now: i64) bool {
    return last_used <= now -| policy.retention_seconds;
}

pub fn decode(alloc: std.mem.Allocator, bytes: []const u8, now: i64) !Decoded {
    if (bytes.len > file_limit or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidHistory;
    // Reject excessive records/nesting before the parser allocates. We accept
    // only our flat array of records, not arbitrary nested JSON documents.
    var quoted = false;
    var escaped = false;
    var depth: usize = 0;
    var records: usize = 0;
    var separators: usize = 0;
    var fields: usize = 0;
    for (bytes) |ch| {
        if (quoted) {
            if (escaped) escaped = false else if (ch == '\\') escaped = true else if (ch == '"') quoted = false;
        } else switch (ch) {
            '"' => quoted = true,
            '[', '{' => {
                if ((ch == '[' and depth != 0) or (ch == '{' and depth != 1)) return error.InvalidHistory;
                depth += 1;
                if (ch == '{') {
                    records += 1;
                    fields = 0;
                }
                if (depth > 2 or records > policy.entries_limit) return error.InvalidHistory;
            },
            ',' => if (depth == 1) {
                separators += 1;
                if (separators >= policy.entries_limit) return error.InvalidHistory;
            },
            ':' => {
                fields += 1;
                if (fields > 2) return error.InvalidHistory;
            },
            ']', '}' => depth -|= 1,
            else => {},
        }
    }
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{ .max_value_len = policy.text_limit });
    if (root != .array) return error.InvalidHistory;
    const input = try alloc.alloc(SavedEntry, root.array.items.len);
    var count: usize = 0;
    var changed = false;
    for (root.array.items) |item| {
        if (item != .object) continue;
        const text = item.object.get("text") orelse continue;
        const time = item.object.get("last_used") orelse continue;
        if (text != .string or time != .integer or time.integer < 0 or !policy.valid(.text, text.string)) continue;
        const timestamp = @min(time.integer, now);
        changed = changed or timestamp != time.integer;
        if (expired(timestamp, now)) continue;
        var duplicate = false;
        for (input[0..count]) |*entry| if (std.mem.eql(u8, entry.text, text.string)) {
            entry.last_used = @max(entry.last_used, timestamp);
            duplicate = true;
            break;
        };
        if (!duplicate) {
            input[count] = .{ .text = text.string, .last_used = timestamp };
            count += 1;
        }
    }
    // Stable sorting preserves saved order for copies within the same second.
    std.mem.sort(SavedEntry, input[0..count], {}, struct {
        fn newer(_: void, left: SavedEntry, right: SavedEntry) bool {
            return left.last_used > right.last_used;
        }
    }.newer);
    var total: usize = 0;
    for (input[0..count], 0..) |entry, index| {
        if (entry.text.len > policy.total_limit - total) return .{ .entries = input[0..index], .changed = true };
        total += entry.text.len;
    }
    return .{ .entries = input[0..count], .changed = changed or count != root.array.items.len };
}

pub fn encode(alloc: std.mem.Allocator, entries: anytype) ![]u8 {
    var saved: [policy.entries_limit]SavedEntry = undefined;
    var count: usize = 0;
    for (entries) |entry| if (entry.kind == .text) {
        if (count == saved.len) return error.InvalidHistory;
        saved[count] = .{ .text = entry.bytes, .last_used = entry.last_used };
        count += 1;
    };
    return std.json.Stringify.valueAlloc(alloc, saved[0..count], .{});
}

test "JSON excludes images and identities and preserves equal-time order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const Entry = struct { id: u64 = 42, kind: policy.Kind, bytes: []const u8, last_used: i64 = 100 };
    const json = try encode(alloc, &[_]Entry{
        .{ .kind = .text, .bytes = "first\n\"👋\"" },
        .{ .kind = .png, .bytes = "never-on-disk" },
        .{ .kind = .text, .bytes = "second" },
    });
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    try std.testing.expectEqual(@as(usize, 2), root.array.items.len);
    for (root.array.items) |item| try std.testing.expectEqual(@as(usize, 2), item.object.count());
    const loaded = try decode(alloc, json, 101);
    try std.testing.expect(!loaded.changed);
    try std.testing.expectEqualStrings("first\n\"👋\"", loaded.entries[0].text);
    try std.testing.expectEqualStrings("second", loaded.entries[1].text);
    try std.testing.expectEqual(@as(i64, 100), loaded.entries[0].last_used);
    try std.testing.expect((try decode(alloc, json, 100 + policy.retention_seconds)).entries.len == 0);
}

test "JSON validates schema timestamps deduplication and parser bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const loaded = try decode(alloc,
        \\[{"text":"a","last_used":100},{"text":"b","last_used":200},{"text":"a","last_used":999},
        \\ {"text":"invalid","last_used":"200"},{"text":"negative","last_used":-1},
        \\ {"text":"float","last_used":1.5},{"text":"bad\u0000","last_used":200},
        \\ {"text":"","last_used":100},{"extra":"ignored","last_used":100},null,42,"invalid record"]
    , 300);
    try std.testing.expect(loaded.changed);
    try std.testing.expectEqual(@as(usize, 2), loaded.entries.len);
    try std.testing.expectEqualStrings("a", loaded.entries[0].text);
    try std.testing.expectEqualStrings("b", loaded.entries[1].text);
    try std.testing.expectEqual(@as(i64, 300), loaded.entries[0].last_used);
    try std.testing.expectError(error.InvalidHistory, decode(alloc, "[{\"text\":\"x\",\"last_used\":100,\"id\":42}]", 300));
    try std.testing.expectError(error.InvalidHistory, decode(alloc, "{}", 300));
    try std.testing.expectError(error.InvalidHistory, decode(alloc, "[[[]]]", 300));
    try std.testing.expectError(error.InvalidHistory, decode(alloc, "[{\"text\":\"\xff\",\"last_used\":1}]", 300));
    if (decode(alloc, "{broken", 300)) |_| return error.AcceptedCorruptJSON else |_| {}
    var many: [policy.entries_limit + 1]SavedEntry = undefined;
    for (&many, 0..) |*entry, index| entry.* = .{ .text = try std.fmt.allocPrint(alloc, "entry-{d}", .{index}), .last_used = 300 };
    try std.testing.expectEqual(@as(usize, 100), (try decode(alloc, try std.json.Stringify.valueAlloc(alloc, many[0..100], .{}), 300)).entries.len);
    try std.testing.expectError(error.InvalidHistory, decode(alloc, try std.json.Stringify.valueAlloc(alloc, &many, .{}), 300));
}

test "JSON restoration enforces text and aggregate byte limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var many: [71]SavedEntry = undefined;
    for (&many, 0..) |*entry, index| {
        const text = try alloc.alloc(u8, policy.text_limit + @as(usize, @intFromBool(index == 70)));
        @memset(text, @intCast(33 + index));
        entry.* = .{ .text = text, .last_used = 300 };
    }
    try std.testing.expectError(error.ValueTooLong, decode(alloc, try std.json.Stringify.valueAlloc(alloc, &many, .{}), 300));
    const loaded = try decode(alloc, try std.json.Stringify.valueAlloc(alloc, many[0..70], .{}), 300);
    try std.testing.expect(loaded.changed);
    try std.testing.expectEqual(@as(usize, 64), loaded.entries.len);
    for (loaded.entries) |entry| try std.testing.expectEqual(policy.text_limit, entry.text.len);
}
