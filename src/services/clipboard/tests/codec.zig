const std = @import("std");
const t = std.testing;
const codec = @import("../codec.zig");
const history = @import("../history.zig");

const Buffer = struct {
    bytes: std.ArrayList(u8) = .empty,
    offset: usize = 0,
    chunk: usize = 7,

    pub fn writeAll(self: *Buffer, bytes: []const u8) !void {
        try self.bytes.appendSlice(t.allocator, bytes);
    }
    pub fn read(self: *Buffer, output: []u8) !usize {
        const size = @min(output.len, self.chunk, self.bytes.items.len - self.offset);
        @memcpy(output[0..size], self.bytes.items[self.offset..][0..size]);
        self.offset += size;
        return size;
    }
    fn deinit(self: *Buffer) void {
        std.crypto.secureZero(u8, self.bytes.items);
        self.bytes.deinit(t.allocator);
    }
    fn decode(self: *Buffer) !codec.Loaded {
        self.offset = 0;
        return codec.decode(t.allocator, self, self.bytes.items.len);
    }
    fn rehash(self: *Buffer) void {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(self.bytes.items[0..64]);
        hash.update(self.bytes.items[96..]);
        hash.final(self.bytes.items[64..96]);
    }
};

const records = [_]codec.Record{
    .{ .bytes = "newest synthetic text", .last_copy = 30, .sequence = 90 },
    .{ .bytes = "older synthetic text", .last_copy = 20, .sequence = 70 },
};
const snapshot: codec.Snapshot = .{ .records = &records, .floor = 40 };

test "codec empty snapshot round trips with its clock floor" {
    var buffer: Buffer = .{};
    defer buffer.deinit();
    try codec.encode(.{ .records = &.{}, .floor = 50 }, &buffer);
    try t.expectEqual(@as(usize, 96), buffer.bytes.items.len);
    try t.expectEqualStrings("PEARLCH\x00", buffer.bytes.items[0..8]);
    var loaded = try buffer.decode();
    defer loaded.deinit();
    try t.expectEqual(@as(usize, 0), loaded.snapshot().records.len);
    try t.expectEqual(@as(i64, 50), loaded.floor);
}

test "codec text ordering timestamps sequence and floor round trip through short reads" {
    var buffer: Buffer = .{};
    defer buffer.deinit();
    try codec.encode(snapshot, &buffer);
    var loaded = try buffer.decode();
    defer loaded.deinit();
    try t.expectEqual(@as(i64, 40), loaded.floor);
    for (records, loaded.snapshot().records) |expected, actual| {
        try t.expectEqualStrings(expected.bytes, actual.bytes);
        try t.expectEqual(expected.last_copy, actual.last_copy);
        try t.expectEqual(expected.sequence, actual.sequence);
    }
}

test "codec one maximum-sized valid text entry round trips" {
    const text = try t.allocator.alloc(u8, 256 * 1024);
    defer t.allocator.free(text);
    @memset(text, 'x');
    var buffer: Buffer = .{};
    defer buffer.deinit();
    try codec.encode(.{ .records = &.{.{ .bytes = text, .last_copy = 0, .sequence = 1 }}, .floor = 0 }, &buffer);
    var loaded = try buffer.decode();
    defer loaded.deinit();
    try t.expectEqualStrings(text, loaded.snapshot().records[0].bytes);
}

test "codec checksum covers header metadata and payload" {
    var buffer: Buffer = .{};
    defer buffer.deinit();
    try codec.encode(snapshot, &buffer);
    buffer.bytes.items[40] += 1;
    try t.expectError(error.Corrupt, buffer.decode());
    buffer.bytes.items[40] -= 1;
    buffer.bytes.items[120] ^= 1;
    try t.expectError(error.Corrupt, buffer.decode());
}

test "codec rejects every truncated prefix and trailing data" {
    var buffer: Buffer = .{};
    defer buffer.deinit();
    try codec.encode(snapshot, &buffer);
    const full = buffer.bytes.items.len;
    for (0..full) |size| {
        buffer.bytes.items.len = size;
        try t.expectError(error.Truncated, buffer.decode());
    }
    buffer.bytes.items.len = full;
    try buffer.bytes.append(t.allocator, 0);
    try t.expectError(error.Corrupt, buffer.decode());
}

test "codec recognizes unsupported versions without interpreting future layout" {
    var buffer: Buffer = .{};
    defer buffer.deinit();
    try codec.encode(snapshot, &buffer);
    std.mem.writeInt(u16, buffer.bytes.items[8..10], 2, .little);
    try t.expectError(error.Unsupported, buffer.decode());
    buffer.bytes.shrinkRetainingCapacity(10);
    try t.expectError(error.Unsupported, buffer.decode());
}

test "codec rejects excessive count payload lengths file size and integer overflow" {
    var buffer: Buffer = .{};
    defer buffer.deinit();
    try codec.encode(snapshot, &buffer);
    std.mem.writeInt(u32, buffer.bytes.items[16..20], 101, .little);
    try t.expectError(error.TooLarge, buffer.decode());
    std.mem.writeInt(u32, buffer.bytes.items[16..20], 2, .little);
    std.mem.writeInt(u64, buffer.bytes.items[24..32], std.math.maxInt(u64), .little);
    try t.expectError(error.TooLarge, buffer.decode());
    std.mem.writeInt(u64, buffer.bytes.items[24..32], records[0].bytes.len + records[1].bytes.len, .little);
    std.mem.writeInt(u64, buffer.bytes.items[32..40], std.math.maxInt(u64), .little);
    try t.expectError(error.Corrupt, buffer.decode());
    std.mem.writeInt(u64, buffer.bytes.items[32..40], buffer.bytes.items.len - 96, .little);
    std.mem.writeInt(u32, buffer.bytes.items[96..100], 256 * 1024 + 1, .little);
    try t.expectError(error.TooLarge, buffer.decode());
    buffer.offset = 0;
    try t.expectError(error.TooLarge, codec.decode(t.allocator, &buffer, 16842753));
}

test "codec validates text even with an otherwise correct checksum" {
    var buffer: Buffer = .{};
    defer buffer.deinit();
    try codec.encode(snapshot, &buffer);
    for ([_]u8{ 0, 0xff }) |invalid| {
        buffer.bytes.items[120] = invalid;
        buffer.rehash();
        try t.expectError(error.Corrupt, buffer.decode());
    }
}

test "codec rejects duplicate records impossible times sequences and reserved fields" {
    const rows = [_]codec.Record{
        .{ .bytes = "aaa", .last_copy = 30, .sequence = 2 },
        .{ .bytes = "bbb", .last_copy = 20, .sequence = 1 },
    };
    var buffer: Buffer = .{};
    defer buffer.deinit();
    try codec.encode(.{ .records = &rows, .floor = 40 }, &buffer);
    @memcpy(buffer.bytes.items[147..150], "aaa");
    buffer.rehash();
    try t.expectError(error.Corrupt, buffer.decode());
    @memcpy(buffer.bytes.items[147..150], "bbb");
    std.mem.writeInt(i64, buffer.bytes.items[131..139], 31, .little);
    buffer.rehash();
    try t.expectError(error.Corrupt, buffer.decode());
    std.mem.writeInt(i64, buffer.bytes.items[131..139], 20, .little);
    std.mem.writeInt(u64, buffer.bytes.items[139..147], 2, .little);
    buffer.rehash();
    try t.expectError(error.Corrupt, buffer.decode());
    std.mem.writeInt(u64, buffer.bytes.items[139..147], 1, .little);
    buffer.bytes.items[100] = 1;
    buffer.rehash();
    try t.expectError(error.Corrupt, buffer.decode());
}

test "codec validates snapshots before writing any bytes" {
    var buffer: Buffer = .{};
    defer buffer.deinit();
    for ([_][]const u8{ "", "\xff", "a\x00b" }) |invalid| {
        try t.expectError(error.Corrupt, codec.encode(.{ .records = &.{.{ .bytes = invalid, .last_copy = 0, .sequence = 1 }}, .floor = 0 }, &buffer));
    }
    try t.expectError(error.Corrupt, codec.encode(.{ .records = &records, .floor = 10 }, &buffer));
    try t.expectError(error.Corrupt, codec.encode(.{ .records = &.{ records[0], records[0] }, .floor = 40 }, &buffer));
    try t.expectEqual(@as(usize, 0), buffer.bytes.items.len);
}

test "codec projection never serializes PNG bytes or runtime IDs" {
    var source = history.History.init(t.allocator);
    defer source.deinit();
    source.next_id = 0x1122334455667788;
    _ = try source.copy(.text, "synthetic saved text", 10);
    var png: [64]u8 = @splat(0);
    @memcpy(png[0..16], "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR");
    std.mem.writeInt(u32, png[16..20], 1, .big);
    std.mem.writeInt(u32, png[20..24], 1, .big);
    @memcpy(png[32..48], "PNG-SECRET-BYTES");
    _ = try source.copy(.png, &png, 20);
    const projection = try codec.Projection.fromHistory(&source, 30, &.{ 8, 7 });
    var buffer: Buffer = .{};
    defer buffer.deinit();
    try codec.encode(projection.snapshot(), &buffer);
    try t.expect(std.mem.indexOf(u8, buffer.bytes.items, "PNG-SECRET-BYTES") == null);
    try t.expect(std.mem.indexOf(u8, buffer.bytes.items, "\x88\x77\x66\x55\x44\x33\x22\x11") == null);
    var loaded = try buffer.decode();
    defer loaded.deinit();
    var restored = history.History.init(t.allocator);
    defer restored.deinit();
    for (loaded.snapshot().records) |record| {
        const id = (try restored.restoreText(record.bytes, record.last_copy, 30)).?;
        try t.expect(id != source.entries()[1].id);
        try t.expectEqual(@as(u64, 7), record.sequence);
        try t.expectEqual(@as(i64, 10), restored.entries()[0].last_copy);
    }
    try t.expectEqual(@as(usize, 1), restored.entries().len);
}

fn allocationDecode(allocator: std.mem.Allocator, buffer: *Buffer) !void {
    buffer.offset = 0;
    var loaded = try codec.decode(allocator, buffer, buffer.bytes.items.len);
    defer loaded.deinit();
}

test "codec releases partially decoded records at every allocation failure" {
    var buffer: Buffer = .{};
    defer buffer.deinit();
    try codec.encode(snapshot, &buffer);
    try t.checkAllAllocationFailures(t.allocator, allocationDecode, .{&buffer});
}

test "codec reaches the exact v1 file limit with 100 records and 16 MiB text" {
    var model = history.History.init(t.allocator);
    defer model.deinit();
    const text = try t.allocator.alloc(u8, history.text_limit);
    defer t.allocator.free(text);
    @memset(text, 'x');
    for (0..64) |index| {
        text[0] = @intCast(33 + index);
        _ = try model.copy(.text, text[0 .. history.text_limit - @as(usize, if (index < 28) 0 else 1)], 0);
    }
    for (0..36) |index| {
        const byte = [_]u8{@intCast(33 + index)};
        _ = try model.copy(.text, &byte, 0);
    }
    var sequences: [100]u64 = undefined;
    for (&sequences, 0..) |*sequence, index| sequence.* = 100 - index;
    const projection = try codec.Projection.fromHistory(&model, 0, &sequences);
    try t.expectEqual(@as(usize, history.total_limit), model.total_bytes);
    try t.expectEqual(@as(u64, 16779712), try codec.encodedSize(projection.snapshot()));
    var buffer: Buffer = .{ .chunk = 65536 };
    defer buffer.deinit();
    try codec.encode(projection.snapshot(), &buffer);
    var loaded = try buffer.decode();
    defer loaded.deinit();
    try t.expectEqual(@as(usize, 100), loaded.snapshot().records.len);
    try t.expectEqual(@as(usize, codec.v1_limit), buffer.bytes.items.len);
}

test "codec encoder rejects excessive count per-entry size and combined payload" {
    var buffer: Buffer = .{};
    defer buffer.deinit();
    const many: [101]codec.Record = @splat(records[0]);
    try t.expectError(error.TooLarge, codec.encode(.{ .records = &many, .floor = 40 }, &buffer));
    const text = try t.allocator.alloc(u8, history.text_limit + 1);
    defer t.allocator.free(text);
    @memset(text, 'x');
    try t.expectError(error.TooLarge, codec.encode(.{ .records = &.{.{ .bytes = text, .last_copy = 0, .sequence = 1 }}, .floor = 0 }, &buffer));
    // Distinct short prefixes allow 65 borrowed 256-KiB records without making
    // 65 duplicate payload allocations in the test fixture.
    const payloads = try t.allocator.alloc(u8, history.text_limit * 65);
    defer t.allocator.free(payloads);
    @memset(payloads, 'x');
    var rows: [65]codec.Record = undefined;
    for (&rows, 0..) |*row, index| {
        const bytes = payloads[index * history.text_limit ..][0..history.text_limit];
        bytes[0] = @intCast(33 + index);
        row.* = .{ .bytes = bytes, .last_copy = 0, .sequence = 65 - index };
    }
    try t.expectError(error.TooLarge, codec.encode(.{ .records = &rows, .floor = 0 }, &buffer));
    try t.expectEqual(@as(usize, 0), buffer.bytes.items.len);
}

test "codec rejects impossible record budgets before attempting allocation" {
    var buffer: Buffer = .{};
    defer buffer.deinit();
    try codec.encode(snapshot, &buffer);
    std.mem.writeInt(u32, buffer.bytes.items[96..100], 1000, .little);
    var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.Corrupt, codec.decode(failing.allocator(), &buffer, buffer.bytes.items.len));
    try t.expectEqual(@as(usize, 0), failing.allocations);
}

test "codec propagates stream errors and handles an early EOF after a valid header" {
    const Broken = struct {
        pub fn read(_: *@This(), _: []u8) error{Broken}!usize {
            return error.Broken;
        }
        pub fn writeAll(_: *@This(), _: []const u8) error{Broken}!void {
            return error.Broken;
        }
    };
    var broken: Broken = .{};
    try t.expectError(error.ReadFailed, codec.decode(t.allocator, &broken, 96));
    try t.expectError(error.WriteFailed, codec.encode(snapshot, &broken));
    var buffer: Buffer = .{};
    defer buffer.deinit();
    try codec.encode(snapshot, &buffer);
    const full = buffer.bytes.items.len;
    buffer.bytes.shrinkRetainingCapacity(full - 1);
    try t.expectError(error.Truncated, codec.decode(t.allocator, &buffer, full));
}
