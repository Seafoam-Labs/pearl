//! Deterministic, UTF-8-safe passage chunking for semantic indexing. Chunks
//! target roughly 450 tokens with a small overlap so a clause spanning a
//! boundary stays retrievable. Byte budgets are calibrated against the
//! runtime tokenizer; the chunker itself never tokenizes.
const std = @import("std");
pub const version: u32 = 1;
pub const target = 1700;
pub const overlap = 256;
pub const max_passage = 2048;
pub const max_chunks_per_file = 512;

/// Snap a byte position forward to a UTF-8 character boundary.
fn boundary(bytes: []const u8, position: usize) usize {
    var pos = @min(position, bytes.len);
    while (pos < bytes.len and (bytes[pos] & 0xC0) == 0x80) pos += 1;
    return pos;
}
/// Prefer a sentence end, then whitespace, then a character boundary, looking
/// back at most half the budget so pieces never degenerate into tiny slivers.
fn cutPoint(bytes: []const u8, limit: usize) usize {
    if (bytes.len <= limit) return bytes.len;
    const floor = limit / 2;
    var i = limit;
    while (i > floor) : (i -= 1) {
        const ch = bytes[i - 1];
        if ((ch == '.' or ch == '!' or ch == '?') and i < bytes.len and (bytes[i] == ' ' or bytes[i] == '\n' or bytes[i] == '\t')) return i;
    }
    if (std.mem.lastIndexOfAny(u8, bytes[floor..limit], " \t\n")) |ws| return floor + ws;
    return boundary(bytes, limit);
}
pub fn overlapTail(bytes: []const u8) []const u8 {
    if (bytes.len <= overlap) return bytes;
    const start = boundary(bytes, bytes.len - overlap);
    return bytes[start..];
}
pub fn chunk(a: std.mem.Allocator, content: []const u8) ![][]const u8 {
    var chunks: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return &.{};
    // Paragraphs first; oversized paragraphs split at sentence/word boundaries.
    var paragraphs = std.mem.splitSequence(u8, trimmed, "\n\n");
    while (paragraphs.next()) |paragraph_raw| {
        const paragraph = std.mem.trim(u8, paragraph_raw, " \t\r\n");
        if (paragraph.len == 0) continue;
        var rest = paragraph;
        while (rest.len > 0) {
            const piece = rest[0..cutPoint(rest, target)];
            rest = std.mem.trimStart(u8, rest[piece.len..], " \t\r\n");
            try appendPiece(a, &chunks, &current, piece);
            if (chunks.items.len >= max_chunks_per_file) return chunks.items;
        }
    }
    if (std.mem.trim(u8, current.items, " \t\r\n").len > 0) {
        try chunks.append(a, try a.dupe(u8, std.mem.trim(u8, current.items, " \t\r\n")));
    }
    return chunks.items;
}
fn appendPiece(a: std.mem.Allocator, chunks: *std.ArrayList([]const u8), current: *std.ArrayList(u8), piece: []const u8) !void {
    if (current.items.len > 0 and current.items.len + 2 + piece.len > target) {
        const text = std.mem.trim(u8, current.items, " \t\r\n");
        try chunks.append(a, try a.dupe(u8, text));
        // Carry a bounded tail forward so boundary clauses remain retrievable.
        // Dupe before clearing: the tail aliases the list's own buffer.
        const tail = overlapTail(text);
        const carry = piece.len < target and tail.len > 0 and tail.len + 2 + piece.len <= max_passage;
        const owned = if (carry) try a.dupe(u8, tail) else null;
        current.clearRetainingCapacity();
        if (owned) |held| {
            try current.appendSlice(a, held);
            try current.appendSlice(a, "\n\n");
        }
    }
    if (current.items.len > 0) try current.appendSlice(a, "\n\n");
    try current.appendSlice(a, piece);
}
test "short documents stay a single trimmed passage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const chunks = try chunk(arena.allocator(), "  A lease clause about pets.\n\n");
    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqualStrings("A lease clause about pets.", chunks[0]);
    try std.testing.expectEqual(@as(usize, 0), (try chunk(arena.allocator(), " \n\t ")).len);
}
test "long documents split within bounds, overlap and never break UTF-8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (0..200) |i| try text.appendSlice(a, try std.fmt.allocPrint(a, "Sentence {d} about pets, leases and clauses. ", .{i}));
    const chunks = try chunk(a, text.items);
    try std.testing.expect(chunks.len > 1);
    for (chunks) |c| {
        try std.testing.expect(c.len > 0 and c.len <= max_passage);
        try std.testing.expect(std.unicode.utf8ValidateSlice(c));
    }
    // The second passage begins with the carried tail of the first.
    const tail = overlapTail(chunks[0]);
    try std.testing.expect(tail.len > 0 and std.mem.startsWith(u8, chunks[1], tail));
    // Deterministic output.
    const again = try chunk(a, text.items);
    try std.testing.expectEqual(chunks.len, again.len);
    for (chunks, again) |x, y| try std.testing.expectEqualStrings(x, y);
}
test "multibyte text and unbroken runs stay valid and bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (0..400) |_| try text.appendSlice(a, " cláusula sobre mascotas 🐕 ");
    const chunks = try chunk(a, text.items);
    for (chunks) |c| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(c));
        try std.testing.expect(c.len <= max_passage);
    }
    var huge: std.ArrayList(u8) = .empty;
    for (0..max_chunks_per_file * 2) |_| try huge.appendSlice(a, "word ");
    const capped = try chunk(a, huge.items);
    try std.testing.expect(capped.len <= max_chunks_per_file);
}
