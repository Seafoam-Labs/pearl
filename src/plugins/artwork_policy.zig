//! Pure user-artwork policy: folder layout, name rules and PNG header bounds.
const std = @import("std");
const m = @import("model.zig");

pub const Size = struct { width: u16, height: u16 };

/// `<root>/<plugin id>/<asset id>`; both names are validated so a hostile
/// manifest or preference cannot address another folder.
pub fn folder(alloc: std.mem.Allocator, root: []const u8, plugin: []const u8, asset: []const u8) ![:0]u8 {
    if (root.len == 0 or !m.identifier(plugin) or !m.identifier(asset)) return error.InvalidPluginArtwork;
    const joined = try std.fs.path.join(alloc, &.{ root, plugin, asset });
    defer alloc.free(joined);
    return try alloc.dupeSentinel(u8, joined, 0);
}

/// PNG signature plus IHDR bounds, mirroring the package loader's checks.
pub fn size(png: []const u8) ?Size {
    if (png.len < 24 or !std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n") or !std.mem.eql(u8, png[12..16], "IHDR")) return null;
    const width = std.mem.readInt(u32, png[16..20], .big);
    const height = std.mem.readInt(u32, png[20..24], .big);
    if (width == 0 or height == 0 or width > 2048 or height > 2048) return null;
    return .{ .width = @intCast(width), .height = @intCast(height) };
}

/// Replacement art must keep the declared sprite geometry, otherwise the
/// package's clip rectangles would sample the wrong frames.
pub fn replaces(header: []const u8, asset: m.Asset) bool {
    const value = size(header) orelse return false;
    return value.width == asset.width and value.height == asset.height;
}

fn pngHeader(width: u32, height: u32) [24]u8 {
    var bytes: [24]u8 = .{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u32, bytes[16..20], width, .big);
    std.mem.writeInt(u32, bytes[20..24], height, .big);
    return bytes;
}

test "artwork folders reject traversal and keep the documented layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/data/pearl/plugin-artwork/pearl.companion/cat", try folder(a, "/data/pearl/plugin-artwork", "pearl.companion", "cat"));
    for ([_]struct { []const u8, []const u8 }{ .{ "../other", "cat" }, .{ "pearl.companion", "../other" }, .{ "pearl.companion", "cat/dog" }, .{ "", "cat" } }) |pair| {
        try std.testing.expectError(error.InvalidPluginArtwork, folder(a, "/data", pair[0], pair[1]));
    }
    try std.testing.expectError(error.InvalidPluginArtwork, folder(a, "", "pearl.companion", "cat"));
}

test "only PNG headers matching the declared sprite size are replaceable" {
    const asset: m.Asset = .{ .id = "cat", .path = "cat.png", .license = "CC0", .width = 384, .height = 96 };
    try std.testing.expect(replaces(&pngHeader(384, 96), asset));
    try std.testing.expect(!replaces(&pngHeader(384, 97), asset));
    try std.testing.expect(!replaces(&pngHeader(0, 96), asset));
    try std.testing.expect(!replaces(&pngHeader(2049, 96), asset));
    try std.testing.expect(size(&pngHeader(128, 96)).?.width == 128);
    const truncated = pngHeader(384, 96);
    try std.testing.expect(size(truncated[0..23]) == null);
    var text = pngHeader(384, 96);
    text[12] = 'X';
    try std.testing.expect(size(&text) == null);
    try std.testing.expect(!replaces("not a png at all, but long enough to read", asset));
}
