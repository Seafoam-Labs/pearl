//! Pure preview policy and the bounded helper wire format.
const std = @import("std");
pub const memory_limit = 64 * 1024 * 1024;
pub const source_limit = 50 * 1024 * 1024;
pub const text_limit = 64 * 1024;
pub const max_edge = 2048;
pub const max_jobs = 2;
pub const max_queue = 128;
pub const Kind = enum(u8) { image = 1, text = 2, unavailable = 3 };
pub const Header = struct { kind: Kind, width: u32, height: u32, length: usize };

pub fn bucket(logical: u32, scale: u32) u32 {
    const pixels = @as(u32, @min(logical, max_edge)) * @as(u32, @min(scale, 8));
    for ([_]u32{ 128, 256, 512, 1024, 2048 }) |size| if (pixels <= size) return size;
    return max_edge;
}
pub fn raster(mime: []const u8) bool {
    for ([_][]const u8{ "image/png", "image/jpeg", "image/gif", "image/webp" }) |t| if (std.mem.eql(u8, t, mime)) return true;
    return false;
}
pub fn textType(mime: []const u8) bool {
    return std.mem.startsWith(u8, mime, "text/") or std.mem.eql(u8, mime, "application/json") or std.mem.eql(u8, mime, "application/xml") or std.mem.eql(u8, mime, "application/javascript") or std.mem.eql(u8, mime, "application/x-shellscript");
}
pub fn cacheName(uri: []const u8) [32]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(uri, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
pub fn header(kind: Kind, width: u32, height: u32) [16]u8 {
    var bytes: [16]u8 = @splat(0);
    @memcpy(bytes[0..4], "PHT1");
    bytes[4] = @intFromEnum(kind);
    std.mem.writeInt(u32, bytes[8..12], width, .little);
    std.mem.writeInt(u32, bytes[12..16], height, .little);
    return bytes;
}
pub fn parse(bytes: []const u8) !Header {
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..4], "PHT1")) return error.InvalidOutput;
    const kind = std.enums.fromInt(Kind, bytes[4]) orelse return error.InvalidOutput;
    const w = std.mem.readInt(u32, bytes[8..12], .little);
    const h = std.mem.readInt(u32, bytes[12..16], .little);
    if (kind == .image) {
        if (w == 0 or h == 0 or w > max_edge or h > max_edge or bytes.len - 16 != @as(usize, w) * h * 4) return error.InvalidOutput;
    } else if (w != 0 or h != 0 or bytes.len - 16 > text_limit + 128 or !std.unicode.utf8ValidateSlice(bytes[16..]) or std.mem.indexOfScalar(u8, bytes[16..], 0) != null) return error.InvalidOutput;
    return .{ .kind = kind, .width = w, .height = h, .length = bytes.len - 16 };
}

test "cache identity is the escaped URI, not a display name" {
    try std.testing.expectEqualStrings("d41d8cd98f00b204e9800998ecf8427e", &cacheName(""));
    try std.testing.expect(!std.mem.eql(u8, &cacheName("file:///a%20b.png"), &cacheName("file:///a b.png")));
}
test "size buckets honor display scale and cap output" {
    try std.testing.expectEqual(@as(u32, 128), bucket(80, 1));
    try std.testing.expectEqual(@as(u32, 256), bucket(80, 2));
    try std.testing.expectEqual(@as(u32, 2048), bucket(4000, 8));
}
test "wire rejects dimensions and length before allocation" {
    try std.testing.expectError(error.InvalidOutput, parse(""));
    const bad = header(.image, 0xffffffff, 2);
    try std.testing.expectError(error.InvalidOutput, parse(&bad));
    var good: [20]u8 = @splat(0);
    @memcpy(good[0..16], &header(.image, 1, 1));
    try std.testing.expectEqual(@as(usize, 4), (try parse(&good)).length);
    try std.testing.expectError(error.InvalidOutput, parse(good[0..19]));
    try std.testing.expect(!raster("image/svg+xml"));
    try std.testing.expect(textType("text/html"));
}
