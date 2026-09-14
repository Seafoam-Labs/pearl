//! Clipboard limits also bound previews and decoder allocation before GTK sees data.
const std = @import("std");
pub const text_limit = 256 * 1024;
pub const image_limit = 8 * 1024 * 1024;
pub const total_limit = 16 * 1024 * 1024;
pub const entries_limit = 20;
pub const Kind = enum { text, png };
pub fn valid(kind: Kind, bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    return switch (kind) {
        .text => bytes.len <= text_limit and std.unicode.utf8ValidateSlice(bytes) and std.mem.indexOfScalar(u8, bytes, 0) == null,
        .png => blk: {
            if (bytes.len < 33 or bytes.len > image_limit or !std.mem.eql(u8, bytes[0..16], "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR")) break :blk false;
            const w = std.mem.readInt(u32, bytes[16..20], .big);
            const h = std.mem.readInt(u32, bytes[20..24], .big);
            break :blk w > 0 and h > 0 and w <= 8192 and h <= 8192 and @as(u64, w) * h <= 8 * 1024 * 1024;
        },
    };
}
pub const Region = struct { x: i32, y: i32, width: i32, height: i32 };
pub fn region(text: []const u8, width: i32, height: i32) !Region {
    var it = std.mem.splitScalar(u8, text, ',');
    var v: [4]i32 = undefined;
    for (&v) |*n| n.* = std.fmt.parseInt(i32, it.next() orelse return error.InvalidRegion, 10) catch return error.InvalidRegion;
    if (it.next() != null or v[0] < 0 or v[1] < 0 or v[2] <= 0 or v[3] <= 0 or @as(i64, v[0]) + v[2] > width or @as(i64, v[1]) + v[3] > height) return error.InvalidRegion;
    return .{ .x = v[0], .y = v[1], .width = v[2], .height = v[3] };
}
test "clipboard rejects invalid UTF-8, NUL, oversized text and decompression bombs" {
    const t = std.testing;
    try t.expect(valid(.text, "hello 👋"));
    try t.expect(!valid(.text, "\xff"));
    try t.expect(!valid(.text, "a\x00b"));
    try t.expect(!valid(.text, "x" ** (text_limit + 1)));
    var png: [33]u8 = @splat(0);
    @memcpy(png[0..16], "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR");
    std.mem.writeInt(u32, png[16..20], 8192, .big);
    std.mem.writeInt(u32, png[20..24], 8192, .big);
    try t.expect(!valid(.png, &png));
    std.mem.writeInt(u32, png[20..24], 1, .big);
    try t.expect(valid(.png, &png));
    try t.expect(!valid(.png, "<svg/>"));
}
test "output crops reject overflow and out-of-output regions" {
    const t = std.testing;
    try t.expectEqual(Region{ .x = 3, .y = 4, .width = 20, .height = 30 }, try region("3,4,20,30", 100, 100));
    for ([_][]const u8{ "-1,0,1,1", "0,0,0,1", "90,0,11,1", "2147483647,0,2147483647,1", "1,2,3", "1,2,3,4,5" }) |s| try t.expectError(error.InvalidRegion, region(s, 100, 100));
}

/// Strip metadata and animation chunks before invoking the PNG decoder. Retained
/// chunks keep their CRCs; libpng validates them. No compressed ICC/text profiles.
pub fn pngPayload(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    if (!valid(.png, input)) return error.InvalidPayload;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);
    try result.appendSlice(alloc, input[0..8]);
    var pos: usize = 8;
    var data = false;
    var header = false;
    var palette = false;
    var transparency = false;
    while (pos + 12 <= input.len) {
        const size = std.mem.readInt(u32, input[pos..][0..4], .big);
        if (size > input.len - pos - 12) return error.InvalidPayload;
        const name = input[pos + 4 ..][0..4];
        const end = pos + 12 + size;
        var keep = false;
        if (std.mem.eql(u8, name, "IHDR")) {
            if (header or pos != 8 or size != 13) return error.InvalidPayload;
            header = true;
            keep = true;
        } else if (std.mem.eql(u8, name, "IDAT")) {
            data = true;
            keep = true;
        } else if (std.mem.eql(u8, name, "PLTE")) {
            if (palette or data or size == 0 or size > 768 or size % 3 != 0) return error.InvalidPayload;
            palette = true;
            keep = true;
        } else if (std.mem.eql(u8, name, "tRNS")) {
            if (transparency or data or size > 256) return error.InvalidPayload;
            transparency = true;
            keep = true;
        } else if (std.mem.eql(u8, name, "IEND")) {
            if (!data or size != 0 or end != input.len) return error.InvalidPayload;
            try result.appendSlice(alloc, input[pos..end]);
            return result.toOwnedSlice(alloc);
        } else if (name[0] & 0x20 == 0) return error.InvalidPayload;
        if (keep) try result.appendSlice(alloc, input[pos..end]);
        pos = end;
    }
    return error.InvalidPayload;
}
/// A bounded, single-line preview; preserve original bytes only in the payload.
pub fn preview(alloc: std.mem.Allocator, input: []const u8) ![:0]u8 {
    var n = @min(input.len, 120);
    while (n > 0 and !std.unicode.utf8ValidateSlice(input[0..n])) n -= 1;
    const text = try alloc.dupeZ(u8, input[0..n]);
    for (text) |*ch| if (ch.* < 32 or ch.* == 127) {
        ch.* = ' ';
    };
    return text;
}
test "PNG prefilter strips compressed metadata and rejects missing end and duplicate headers" {
    const t = std.testing;
    var header: [25]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], 13, .big);
    @memcpy(header[4..8], "IHDR");
    std.mem.writeInt(u32, header[8..12], 2, .big);
    std.mem.writeInt(u32, header[12..16], 2, .big);
    const start = "\x89PNG\r\n\x1a\n";
    const metadata = "\x00\x00\x00\x03zTXtfoo\x00\x00\x00\x00";
    const data = "\x00\x00\x00\x01IDATx\x00\x00\x00\x00";
    const end = "\x00\x00\x00\x00IEND\x00\x00\x00\x00";
    const original = start ++ header ++ metadata ++ data ++ end;
    const result = try pngPayload(t.allocator, original);
    defer t.allocator.free(result);
    try t.expectEqualStrings((start ++ header ++ data ++ end), result);
    try t.expectError(error.InvalidPayload, pngPayload(t.allocator, (start ++ header ++ data)));
    try t.expectError(error.InvalidPayload, pngPayload(t.allocator, (start ++ header ++ header ++ data ++ end)));
    const p = try preview(t.allocator, "hello\n\x1bworld");
    defer t.allocator.free(p);
    try t.expectEqualStrings("hello  world", p);
}
