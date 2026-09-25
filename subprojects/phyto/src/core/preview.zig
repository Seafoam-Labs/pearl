//! Pure preview policy and the bounded helper wire format.
const std = @import("std");
pub const memory_limit = 64 * 1024 * 1024;
pub const source_limit = 50 * 1024 * 1024;
pub const text_limit = 64 * 1024;
pub const max_edge = 2048;
pub const max_jobs = 2;
pub const max_queue = 128;
pub const Kind = enum(u8) { image = 1, text = 2, unavailable = 3 };
pub const Header = struct { status: Status, kind: Kind, width: u32, height: u32, length: usize };

pub const Provider = enum(u8) { builtin, pdf, video };
pub const Status = enum(u8) { ok, failed, missing_pdf, missing_video, sandbox, limits, timeout, unsupported, changed };
pub fn message(status: Status) [:0]const u8 {
    return switch (status) {
        .ok => "Preview available.",
        .failed => "Cannot preview this file.",
        .missing_pdf => "PDF preview requires Poppler (pdftoppm).",
        .missing_video => "Video preview requires FFmpeg (ffmpeg and ffprobe).",
        .sandbox => "Preview sandbox unavailable (bubblewrap required).",
        .limits => "File exceeds preview resource limits.",
        .timeout => "Preview timed out.",
        .unsupported => "This document or video format is not supported.",
        .changed => "File changed while generating the preview.",
    };
}
pub fn provider(mime: []const u8) Provider {
    if (std.mem.eql(u8, mime, "application/pdf")) return .pdf;
    for ([_][]const u8{ "video/mp4", "video/quicktime", "video/x-matroska", "video/matroska", "video/webm", "video/x-msvideo", "video/vnd.avi", "video/x-m4v", "video/avi", "video/msvideo", "application/x-matroska" }) |v| if (std.mem.eql(u8, mime, v)) return .video;
    return .builtin;
}
pub fn providerLimit(p: Provider) usize {
    return if (p == .video) 2 * 1024 * 1024 * 1024 else source_limit;
}
pub fn statusHeader(status: Status) [16]u8 {
    var bytes = header(.unavailable, 0, 0);
    bytes[5] = @intFromEnum(status);
    return bytes;
}
pub fn frameTime(duration: f64) f64 {
    return if (std.math.isFinite(duration) and duration > 0) @min(duration * 0.1, 30) else 0;
}

/// Check the complete generated PNG envelope before feeding an image loader.
/// Pixel/chunk CRC validation remains the decoder's responsibility.
pub fn generatedPng(bytes: []const u8, edge: u32) bool {
    if (bytes.len < 33 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return false;
    if (std.mem.readInt(u32, bytes[8..12], .big) != 13 or !std.mem.eql(u8, bytes[12..16], "IHDR")) return false;
    const w = std.mem.readInt(u32, bytes[16..20], .big);
    const h = std.mem.readInt(u32, bytes[20..24], .big);
    if (w == 0 or h == 0 or w > edge or h > edge or edge > max_edge) return false;
    var offset: usize = 8;
    while (bytes.len - offset >= 12) {
        const length: usize = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        if (length > bytes.len - offset - 12) return false;
        if (std.mem.eql(u8, bytes[offset + 4 ..][0..4], "IEND")) return length == 0 and offset + 12 == bytes.len;
        offset += length + 12;
    }
    return false;
}

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
    @memcpy(bytes[0..4], "PHT2");
    bytes[4] = @intFromEnum(kind);
    std.mem.writeInt(u32, bytes[8..12], width, .little);
    std.mem.writeInt(u32, bytes[12..16], height, .little);
    return bytes;
}
pub fn parse(bytes: []const u8) !Header {
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..4], "PHT2")) return error.InvalidOutput;
    const kind = std.enums.fromInt(Kind, bytes[4]) orelse return error.InvalidOutput;
    const status = std.enums.fromInt(Status, bytes[5]) orelse return error.InvalidOutput;
    if (bytes[6] != 0 or bytes[7] != 0 or (kind != .unavailable and status != .ok)) return error.InvalidOutput;
    const w = std.mem.readInt(u32, bytes[8..12], .little);
    const h = std.mem.readInt(u32, bytes[12..16], .little);
    if (kind == .image) {
        if (w == 0 or h == 0 or w > max_edge or h > max_edge or bytes.len - 16 != @as(usize, w) * h * 4) return error.InvalidOutput;
    } else if (w != 0 or h != 0 or bytes.len - 16 > text_limit + 128 or !std.unicode.utf8ValidateSlice(bytes[16..]) or std.mem.indexOfScalar(u8, bytes[16..], 0) != null) return error.InvalidOutput;
    return .{ .status = status, .kind = kind, .width = w, .height = h, .length = bytes.len - 16 };
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

test "provider routing, statuses and deterministic frame policy" {
    try std.testing.expectEqual(Provider.pdf, provider("application/pdf"));
    try std.testing.expectEqual(Provider.video, provider("video/webm"));
    try std.testing.expectEqual(Provider.video, provider("video/matroska"));
    try std.testing.expectEqual(Provider.video, provider("video/vnd.avi"));
    try std.testing.expectEqual(Provider.builtin, provider("application/vnd.apple.mpegurl"));
    try std.testing.expectEqual(@as(f64, 0.05), frameTime(0.5));
    try std.testing.expectEqual(@as(f64, 30), frameTime(600));
    try std.testing.expectEqual(@as(f64, 0), frameTime(std.math.nan(f64)));
    const unavailable = statusHeader(.sandbox);
    try std.testing.expectEqual(Status.sandbox, (try parse(&unavailable)).status);
    var bad = unavailable;
    bad[5] = 255;
    try std.testing.expectError(error.InvalidOutput, parse(&bad));
}

test {
    _ = @import("preview_video_metadata.zig");
}

test "generated PNG envelope rejects oversized, truncated and concatenated output" {
    var png: [45]u8 = @splat(0);
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, png[8..12], 13, .big);
    @memcpy(png[12..16], "IHDR");
    std.mem.writeInt(u32, png[16..20], 128, .big);
    std.mem.writeInt(u32, png[20..24], 64, .big);
    @memcpy(png[37..41], "IEND");
    try std.testing.expect(generatedPng(&png, 128));
    try std.testing.expect(!generatedPng(&png, 64));
    try std.testing.expect(!generatedPng(png[0..44], 128));
    const doubled = png ++ png;
    try std.testing.expect(!generatedPng(&doubled, 128));
}
