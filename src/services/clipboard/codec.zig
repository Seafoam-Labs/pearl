//! Streaming plaintext snapshot v1. SHA-256 detects corruption, not forgery.
//! No runtime IDs, PNGs, filesystem operations or clock sampling enter the codec.
const std = @import("std");
const history = @import("history.zig");
const policy = @import("../clipboard_policy.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const header_size = 96;
pub const record_size = 24;
pub const file_limit = 16842752;
pub const v1_limit = header_size + record_size * history.entries_limit + history.total_limit;
pub const Error = error{ Corrupt, Unsupported, Truncated, TooLarge, OutOfMemory, ReadFailed, WriteFailed };
pub const Record = struct { bytes: []const u8, last_copy: i64, sequence: u64 };

/// Synchronous borrowed view; its bytes must remain immutable throughout encode.
pub const Snapshot = struct { records: []const Record, floor: i64 };

/// Fixed metadata projection over model-owned text, without copying payloads.
/// Step 1 has no persistent sequence counter: the future coordinator supplies
/// descending, nonzero copy sequences for all mixed rows, including PNG rows.
/// Runtime IDs must never be used as copy sequences (recopy keeps those IDs).
pub const Projection = struct {
    rows: [history.entries_limit]Record = undefined,
    len: usize = 0,
    floor: i64,

    pub fn fromHistory(model: *const history.History, floor: i64, sequences: []const u64) Error!Projection {
        if (sequences.len != model.entries().len) return error.Corrupt;
        var result: Projection = .{ .floor = floor };
        var previous: u64 = std.math.maxInt(u64);
        for (model.entries(), sequences, 0..) |entry, sequence, index| {
            if (sequence == 0 or (index > 0 and sequence >= previous)) return error.Corrupt;
            previous = sequence;
            if (entry.kind != .text) continue;
            result.rows[result.len] = .{ .bytes = entry.bytes, .last_copy = entry.last_copy, .sequence = sequence };
            result.len += 1;
        }
        _ = try makeHeader(result.snapshot());
        return result;
    }

    pub fn snapshot(self: *const Projection) Snapshot {
        return .{ .records = self.rows[0..self.len], .floor = self.floor };
    }
};

/// Owns exact-size text allocations. Do not copy by value; deinit wipes every
/// owned payload, including partial decode failures. Snapshot views are borrowed.
pub const Loaded = struct {
    allocator: std.mem.Allocator,
    rows: [history.entries_limit]Record = undefined,
    len: usize = 0,
    floor: i64,

    pub fn snapshot(self: *const Loaded) Snapshot {
        return .{ .records = self.rows[0..self.len], .floor = self.floor };
    }
    pub fn deinit(self: *Loaded) void {
        for (self.rows[0..self.len]) |record| wipe(self.allocator, record.bytes);
        self.len = 0;
        self.rows = undefined;
    }
};

fn wipe(allocator: std.mem.Allocator, bytes: []const u8) void {
    std.crypto.secureZero(u8, @constCast(bytes));
    allocator.free(bytes);
}

fn recordHeader(record: Record) [record_size]u8 {
    var result: [record_size]u8 = @splat(0);
    std.mem.writeInt(u32, result[0..4], @intCast(record.bytes.len), .little);
    std.mem.writeInt(i64, result[8..16], record.last_copy, .little);
    std.mem.writeInt(u64, result[16..24], record.sequence, .little);
    return result;
}

fn makeHeader(snapshot: Snapshot) Error![header_size]u8 {
    if (snapshot.records.len > history.entries_limit) return error.TooLarge;
    if (snapshot.floor < 0) return error.Corrupt;
    var payload: u64 = 0;
    var previous_time = snapshot.floor;
    var previous_sequence: u64 = std.math.maxInt(u64);
    var hashes: [history.entries_limit][32]u8 = undefined;
    for (snapshot.records, 0..) |record, index| {
        if (record.bytes.len > history.text_limit) return error.TooLarge;
        if (!policy.valid(.text, record.bytes)) return error.Corrupt;
        if (record.last_copy < 0 or record.last_copy > previous_time or record.sequence == 0 or (index > 0 and record.sequence >= previous_sequence)) return error.Corrupt;
        previous_time = record.last_copy;
        previous_sequence = record.sequence;
        // Bounded operands, with subtraction to avoid intermediate overflow.
        if (record.bytes.len > history.total_limit - payload) return error.TooLarge;
        payload += record.bytes.len;
        Sha256.hash(record.bytes, &hashes[index], .{});
        for (snapshot.records[0..index], hashes[0..index]) |other, hash| {
            if (std.mem.eql(u8, &hash, &hashes[index]) and std.mem.eql(u8, other.bytes, record.bytes)) return error.Corrupt;
        }
    }
    var header: [header_size]u8 = @splat(0);
    @memcpy(header[0..8], "PEARLCH\x00");
    std.mem.writeInt(u16, header[8..10], 1, .little);
    std.mem.writeInt(u16, header[10..12], header_size, .little);
    std.mem.writeInt(u32, header[16..20], @intCast(snapshot.records.len), .little);
    std.mem.writeInt(u64, header[24..32], payload, .little);
    std.mem.writeInt(u64, header[32..40], payload + record_size * snapshot.records.len, .little);
    std.mem.writeInt(i64, header[40..48], snapshot.floor, .little);
    std.mem.writeInt(u64, header[48..56], if (snapshot.records.len == 0) 0 else snapshot.records[0].sequence, .little);
    return header;
}

pub fn encodedSize(snapshot: Snapshot) Error!u64 {
    const header = try makeHeader(snapshot);
    return header_size + std.mem.readInt(u64, header[32..40], .little);
}

/// Two streaming passes over immutable input: digest, then write. No file-sized
/// scratch allocation. Writer supplies writeAll; filesystem short-write/EINTR
/// handling is provided by the store adapter.
pub fn encode(snapshot: Snapshot, writer: anytype) Error!void {
    var header = try makeHeader(snapshot);
    var hash = Sha256.init(.{});
    hash.update(header[0..64]);
    for (snapshot.records) |record| {
        hash.update(&recordHeader(record));
        hash.update(record.bytes);
    }
    hash.final(header[64..96]);
    writer.writeAll(&header) catch return error.WriteFailed;
    for (snapshot.records) |record| {
        writer.writeAll(&recordHeader(record)) catch return error.WriteFailed;
        writer.writeAll(record.bytes) catch return error.WriteFailed;
    }
    std.crypto.secureZero(u8, &header);
}

const Header = struct { count: u32, payload: u64, floor: i64, sequence: u64 };
fn validateHeader(bytes: *const [header_size]u8, observed_size: u64) Error!Header {
    if (std.mem.readInt(u16, bytes[10..12], .little) != header_size or
        std.mem.readInt(u32, bytes[12..16], .little) != 0 or
        std.mem.readInt(u32, bytes[20..24], .little) != 0 or
        std.mem.readInt(u64, bytes[56..64], .little) != 0) return error.Corrupt;
    const result: Header = .{
        .count = std.mem.readInt(u32, bytes[16..20], .little),
        .payload = std.mem.readInt(u64, bytes[24..32], .little),
        .floor = std.mem.readInt(i64, bytes[40..48], .little),
        .sequence = std.mem.readInt(u64, bytes[48..56], .little),
    };
    if (result.count > history.entries_limit or result.payload > history.total_limit) return error.TooLarge;
    if (result.floor < 0 or (result.count == 0) != (result.sequence == 0) or result.payload < result.count) return error.Corrupt;
    // Only compute after both operands are bounded; malicious u64 area lengths
    // are compared rather than added to the header size.
    const area = result.payload + @as(u64, result.count) * record_size;
    if (std.mem.readInt(u64, bytes[32..40], .little) != area) return error.Corrupt;
    const expected = header_size + area;
    if (expected > v1_limit) return error.TooLarge;
    if (observed_size < expected) return error.Truncated;
    if (observed_size != expected) return error.Corrupt;
    return result;
}

fn readExact(reader: anytype, output: []u8) Error!void {
    var offset: usize = 0;
    while (offset < output.len) {
        const count = reader.read(output[offset..]) catch return error.ReadFailed;
        if (count == 0) return error.Truncated;
        if (count > output.len - offset) return error.ReadFailed;
        offset += count;
    }
}

/// Reader supplies read([]u8)!usize. Validate observed file size and all declared
/// budgets before each allocation. No partial Loaded is returned on any error.
pub fn decode(allocator: std.mem.Allocator, reader: anytype, observed_size: u64) Error!Loaded {
    if (observed_size > file_limit) return error.TooLarge;
    var header: [header_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &header);
    if (observed_size < 10) return error.Truncated;
    try readExact(reader, header[0..10]);
    if (!std.mem.eql(u8, header[0..8], "PEARLCH\x00")) return error.Corrupt;
    if (std.mem.readInt(u16, header[8..10], .little) != 1) return error.Unsupported;
    if (observed_size < header_size) return error.Truncated;
    try readExact(reader, header[10..]);
    const meta = try validateHeader(&header, observed_size);
    var result: Loaded = .{ .allocator = allocator, .floor = meta.floor };
    errdefer result.deinit();
    var hash = Sha256.init(.{});
    hash.update(header[0..64]);
    var hashes: [history.entries_limit][32]u8 = undefined;
    var remaining = meta.payload;
    var previous_time = meta.floor;
    var previous_sequence = meta.sequence;
    for (0..meta.count) |index| {
        var raw: [record_size]u8 = undefined;
        defer std.crypto.secureZero(u8, &raw);
        try readExact(reader, &raw);
        const size = std.mem.readInt(u32, raw[0..4], .little);
        const last_copy = std.mem.readInt(i64, raw[8..16], .little);
        const sequence = std.mem.readInt(u64, raw[16..24], .little);
        if (size > history.text_limit) return error.TooLarge;
        if (size == 0 or size > remaining or remaining - size < meta.count - index - 1 or std.mem.readInt(u32, raw[4..8], .little) != 0) return error.Corrupt;
        if (last_copy < 0 or last_copy > previous_time or sequence == 0 or
            (index == 0 and sequence != meta.sequence) or (index > 0 and sequence >= previous_sequence)) return error.Corrupt;
        previous_time = last_copy;
        previous_sequence = sequence;
        const bytes = try allocator.alloc(u8, size);
        // Immediately attach ownership so every subsequent error wipes it.
        result.rows[result.len] = .{ .bytes = bytes, .last_copy = last_copy, .sequence = sequence };
        result.len += 1;
        try readExact(reader, bytes);
        if (!policy.valid(.text, bytes)) return error.Corrupt;
        Sha256.hash(bytes, &hashes[index], .{});
        for (result.rows[0..index], hashes[0..index]) |other, other_hash| {
            if (std.mem.eql(u8, &other_hash, &hashes[index]) and std.mem.eql(u8, other.bytes, bytes)) return error.Corrupt;
        }
        remaining -= size;
        hash.update(&raw);
        hash.update(bytes);
    }
    if (remaining != 0) return error.Corrupt;
    var digest: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &digest);
    hash.final(&digest);
    if (!std.mem.eql(u8, &digest, header[64..96])) return error.Corrupt;
    var extra: [1]u8 = undefined;
    if ((reader.read(&extra) catch return error.ReadFailed) != 0) return error.Corrupt;
    return result;
}
