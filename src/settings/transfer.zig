//! Bounded, connection-owned Pearl document transfer. No partial draft mutation.
const std = @import("std");
const p = @import("editor_protocol.zig");
const limits: @import("protocol.zig").Limits = .{};
pub const Transfer = struct {
    id: u64,
    data: []u8,
    offset: usize = 0,
    hash: [64]u8,
    deadline: i64,
    upload: bool,
    draft_revision: u64 = 0,
    base_revision: u64 = 0,
    domain: p.Domain = .pearl,
    pub fn create(a: std.mem.Allocator, id: u64, size: usize, hash: [64]u8, now: i64, upload: bool) !Transfer {
        return createBounded(a, id, size, hash, now, upload, limits.pearl_document_bytes);
    }
    pub fn createBounded(a: std.mem.Allocator, id: u64, size: usize, hash: [64]u8, now: i64, upload: bool, maximum: usize) !Transfer {
        if (size > maximum) return error.DocumentTooLarge;
        return .{ .id = id, .data = try a.alloc(u8, size), .hash = hash, .deadline = now + limits.transfer_ms, .upload = upload };
    }
    pub fn deinit(self: *Transfer, a: std.mem.Allocator) void {
        a.free(self.data);
    }
    pub fn check(self: Transfer, id: u64, now: i64) !void {
        if (self.id != id) return error.StaleTransfer;
        if (now >= self.deadline) return error.TransferExpired;
    }
    pub fn write(self: *Transfer, id: u64, offset: u64, bytes: []const u8, now: i64) !void {
        try self.check(id, now);
        if (!self.upload or offset != self.offset) return error.InvalidOffset;
        if (bytes.len > limits.document_chunk_bytes or bytes.len > self.data.len - self.offset or (bytes.len == 0 and self.offset < self.data.len)) return error.InvalidChunk;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidText;
        @memcpy(self.data[self.offset..][0..bytes.len], bytes);
        self.offset += bytes.len;
    }
    pub fn read(self: *Transfer, id: u64, offset: u64, now: i64) ![]const u8 {
        try self.check(id, now);
        if (self.upload or offset != self.offset) return error.InvalidOffset;
        var end = @min(self.data.len, self.offset + limits.document_chunk_bytes);
        while (end < self.data.len and end > self.offset and self.data[end] & 0xc0 == 0x80) end -= 1;
        const chunk = self.data[self.offset..end];
        self.offset = end;
        return chunk;
    }
    pub fn finish(self: Transfer, id: u64, now: i64) ![]const u8 {
        try self.check(id, now);
        if (!self.upload or self.offset != self.data.len) return error.IncompleteTransfer;
        if (!std.mem.eql(u8, &self.hash, &p.digest(self.data))) return error.DigestMismatch;
        return self.data;
    }
};
test "document transfer rejects gaps, excess, stale IDs, hash mismatch and expiry" {
    const a = std.testing.allocator;
    var t = try Transfer.create(a, 2, 3, p.digest("abc"), 10, true);
    defer t.deinit(a);
    try std.testing.expectError(error.InvalidOffset, t.write(2, 1, "a", 11));
    try std.testing.expectError(error.IncompleteTransfer, t.finish(2, 11));
    try t.write(2, 0, "a", 11);
    try std.testing.expectError(error.InvalidChunk, t.write(2, 1, "bcd", 11));
    try std.testing.expectError(error.StaleTransfer, t.write(1, 1, "bc", 11));
    try t.write(2, 1, "bc", 11);
    try std.testing.expectEqualStrings("abc", try t.finish(2, 11));
    try std.testing.expectError(error.TransferExpired, t.finish(2, 30010));
    t.data[0] = 'x';
    try std.testing.expectError(error.DigestMismatch, t.finish(2, 11));
}
test "download chunks preserve UTF-8 boundaries" {
    const a = std.testing.allocator;
    var t = try Transfer.create(a, 1, 32772, undefined, 0, false);
    defer t.deinit(a);
    @memset(t.data, 'a');
    @memcpy(t.data[32767..32771], "🐚");
    const first = try t.read(1, 0, 1);
    try std.testing.expectEqual(32767, first.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(first));
    try std.testing.expectEqualStrings("🐚a", try t.read(1, 32767, 1));
}
