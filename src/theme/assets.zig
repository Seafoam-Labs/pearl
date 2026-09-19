//! Static PNG validation and memory-only GResource providers. Package paths are
//! never handed to GTK, and supplied GResource containers are never accepted.
const std = @import("std");
const model = @import("package_model.zig");
pub const c = @cImport({
    @cInclude("png.h");
});
const Resource = opaque {};
const Bytes = opaque {};
extern fn g_bytes_new(?*const anyopaque, usize) *Bytes;
extern fn g_bytes_unref(*Bytes) void;
extern fn g_bytes_get_data(*Bytes, *usize) ?*const anyopaque;
extern fn g_resource_new_from_data(*Bytes, ?*anyopaque) ?*Resource;
extern fn g_resource_unref(*Resource) void;
extern fn g_resources_register(*Resource) void;
extern fn g_resources_unregister(*Resource) void;
extern fn g_resources_lookup_data([*:0]const u8, c_uint, ?*anyopaque) ?*Bytes;
pub const max_image = 2 * 1024 * 1024;
pub const max_encoded = 8 * 1024 * 1024;
pub const max_decoded = 32 * 1024 * 1024;
pub const Declaration = @import("asset_model.zig").Declaration;
pub const Image = @import("asset_model.zig").Image;
pub const Blob = @import("asset_model.zig").Blob;
pub const Validated = struct { image: Image, blob: Blob };

pub fn validate(a: std.mem.Allocator, id: []const u8, bytes: []const u8) !Validated {
    try model.identifier(id);
    if (bytes.len > max_image or bytes.len < 33 or !std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return error.InvalidThemeImage;
    // Strip ancillary chunks before the decoder sees compressed metadata. Check
    // CRCs and all framing first, including ignored chunks, and disallow APNG.
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(a);
    try clean.appendSlice(a, bytes[0..8]);
    var pos: usize = 8;
    var ended = false;
    var data = false;
    var after_data = false;
    var width: u32 = 0;
    var height: u32 = 0;
    while (pos < bytes.len) {
        if (ended or bytes.len - pos < 12) return error.InvalidThemeImage;
        const size = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        if (size > bytes.len - pos - 12) return error.InvalidThemeImage;
        const kind = bytes[pos + 4 ..][0..4];
        const chunk = bytes[pos .. pos + 12 + size];
        for (kind) |ch| if (!std.ascii.isAlphabetic(ch)) return error.InvalidThemeImage;
        if (std.hash.Crc32.hash(chunk[4 .. 8 + size]) != std.mem.readInt(u32, chunk[8 + size ..][0..4], .big)) return error.InvalidThemeImage;
        if (std.mem.eql(u8, kind, "acTL") or std.mem.eql(u8, kind, "fcTL") or std.mem.eql(u8, kind, "fdAT")) return error.AnimatedThemeImage;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (pos != 8 or size != 13) return error.InvalidThemeImage;
            width = std.mem.readInt(u32, chunk[8..][0..4], .big);
            height = std.mem.readInt(u32, chunk[12..][0..4], .big);
            if (width == 0 or height == 0 or width > 2048 or height > 2048) return error.ThemeImageDimensions;
        } else if (pos == 8) return error.InvalidThemeImage;
        if (std.mem.eql(u8, kind, "IDAT")) {
            if (after_data) return error.InvalidThemeImage;
            data = true;
        } else if (data) after_data = true;
        const retain = std.mem.eql(u8, kind, "IHDR") or std.mem.eql(u8, kind, "PLTE") or std.mem.eql(u8, kind, "tRNS") or std.mem.eql(u8, kind, "IDAT") or std.mem.eql(u8, kind, "IEND");
        if (!retain and std.ascii.isUpper(kind[0])) return error.InvalidThemeImage;
        if (std.mem.eql(u8, kind, "IEND")) {
            if (size != 0 or !data) return error.InvalidThemeImage;
            ended = true;
        }
        if (retain) try clean.appendSlice(a, chunk);
        pos += chunk.len;
    }
    if (!ended) return error.InvalidThemeImage;
    var png: c.png_image = std.mem.zeroes(c.png_image);
    png.version = c.PNG_IMAGE_VERSION;
    defer c.png_image_free(&png);
    if (c.png_image_begin_read_from_memory(&png, clean.items.ptr, clean.items.len) == 0) return error.InvalidThemeImage;
    if (png.width != width or png.height != height) return error.InvalidThemeImage;
    png.format = c.PNG_FORMAT_RGBA;
    // Decoding is transient even when the caller uses an arena for captured data.
    const pixels = try std.heap.c_allocator.alloc(u8, @as(usize, width) * height * 4);
    defer std.heap.c_allocator.free(pixels);
    if (c.png_image_finish_read(&png, null, pixels.ptr, 0, null) == 0) return error.InvalidThemeImage;
    // Encode a canonical metadata-free PNG. GTK only receives these bytes.
    var length: c.png_alloc_size_t = 0;
    if (c.png_image_write_to_memory(&png, null, &length, 0, pixels.ptr, 0, null) == 0 or length > max_image) return error.ThemeImageSize;
    const normalized = try a.alloc(u8, length);
    if (c.png_image_write_to_memory(&png, normalized.ptr, &length, 0, pixels.ptr, 0, null) == 0) return error.InvalidThemeImage;
    const payload = normalized[0..length];
    const digest = try a.dupe(u8, &model.hash(payload));
    return .{ .image = .{ .id = try a.dupe(u8, id), .digest = digest, .size = length, .width = width, .height = height }, .blob = .{ .digest = digest, .bytes = payload } };
}
pub fn bounds(images: []const Image) !void {
    if (images.len > 32) return error.ThemeImageLimit;
    var encoded: usize = 0;
    var decoded: usize = 0;
    for (images, 0..) |image, i| {
        try model.identifier(image.id);
        try model.digest(image.digest);
        if (image.size == 0 or image.size > max_image or image.width == 0 or image.height == 0 or image.width > 2048 or image.height > 2048) return error.ThemeImageDimensions;
        for (images[0..i]) |old| if (std.mem.eql(u8, old.id, image.id)) return error.DuplicateThemeAsset;
        encoded += image.size;
        decoded += @as(usize, image.width) * image.height * 4;
    }
    if (encoded > max_encoded or decoded > max_decoded) return error.ThemeImageLimit;
}
pub fn uri(a: std.mem.Allocator, digest: []const u8) ![]const u8 {
    try model.digest(digest);
    return std.fmt.allocPrint(a, "resource:///org/aqueous/Pearl/theme-assets/{s}.png", .{digest});
}

/// One full-path GVDB entry avoids directory tables; only direct CSS lookups are
/// needed. Every offset/length is produced here, never copied from a package.
pub fn resourceBytes(a: std.mem.Allocator, blob: Blob) ![]u8 {
    try model.digest(blob.digest);
    if (blob.bytes.len > max_image or !std.mem.eql(u8, &model.hash(blob.bytes), blob.digest)) return error.ThemeAssetDigestMismatch;
    const path = try std.fmt.allocPrint(a, "/org/aqueous/Pearl/theme-assets/{s}.png", .{blob.digest});
    defer a.free(path);
    const key_start = 60;
    const value_start = std.mem.alignForward(usize, key_start + path.len, 8);
    const value_end = value_start + 8 + blob.bytes.len + 1 + 7;
    const bytes = try a.alloc(u8, value_end);
    @memset(bytes, 0);
    @memcpy(bytes[0..8], "GVariant");
    put(bytes, 16, 24);
    put(bytes, 20, 60);
    put(bytes, 28, 1); // no bloom filter, one bucket starting at entry zero
    var hash: u32 = 5381;
    for (path) |ch| hash = hash *% 33 +% ch;
    put(bytes, 36, hash);
    put(bytes, 40, 0xffffffff); // full path; no parent entry
    put(bytes, 44, key_start);
    std.mem.writeInt(u16, bytes[48..50], @intCast(path.len), .little);
    bytes[50] = 'v';
    put(bytes, 52, @intCast(value_start));
    put(bytes, 56, @intCast(value_end));
    @memcpy(bytes[key_start..][0..path.len], path);
    put(bytes, value_start, @intCast(blob.bytes.len));
    @memcpy(bytes[value_start + 8 ..][0..blob.bytes.len], blob.bytes);
    @memcpy(bytes[value_end - 7 ..], "\x00(uuay)");
    return bytes;
}
fn put(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
pub const Provider = struct {
    resources: std.ArrayList(*Resource) = .empty,
    pub fn deinit(self: *Provider) void {
        for (self.resources.items) |r| {
            g_resources_unregister(r);
            g_resource_unref(r);
        }
        self.resources.deinit(std.heap.c_allocator);
        self.* = .{};
    }
    pub fn init(blobs: []const Blob) !Provider {
        var self: Provider = .{};
        errdefer self.deinit();
        const a = std.heap.c_allocator;
        for (blobs) |blob| {
            const encoded = try resourceBytes(a, blob);
            defer a.free(encoded);
            const bytes = g_bytes_new(encoded.ptr, encoded.len);
            defer g_bytes_unref(bytes);
            const r = g_resource_new_from_data(bytes, null) orelse return error.ThemeResourceInvalid;
            self.resources.append(a, r) catch |err| {
                g_resource_unref(r);
                return err;
            };
            g_resources_register(r);
        }
        return self;
    }
};

test "native resource lookup preserves arbitrary bytes and releases registrations" {
    const a = std.testing.allocator;
    const blob: Blob = .{ .digest = &model.hash("hello"), .bytes = "hello" };
    const path = try std.fmt.allocPrintSentinel(a, "/org/aqueous/Pearl/theme-assets/{s}.png", .{blob.digest}, 0);
    defer a.free(path);
    var provider = try Provider.init(&.{blob});
    const bytes = g_resources_lookup_data(path, 0, null) orelse return error.LookupFailed;
    var len: usize = 0;
    const raw: [*]const u8 = @ptrCast(g_bytes_get_data(bytes, &len));
    try std.testing.expectEqualStrings("hello", raw[0..len]);
    g_bytes_unref(bytes);
    provider.deinit();
    try std.testing.expect(g_resources_lookup_data(path, 0, null) == null);
}
test "PNG validation decodes transparent pixels, rejects corruption and dimension bombs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var png: c.png_image = std.mem.zeroes(c.png_image);
    png.version = c.PNG_IMAGE_VERSION;
    png.width = 2;
    png.height = 1;
    png.format = c.PNG_FORMAT_RGBA;
    const pixels = [_]u8{ 20, 30, 40, 255, 50, 60, 70, 0 };
    var length: c.png_alloc_size_t = 0;
    try std.testing.expect(c.png_image_write_to_memory(&png, null, &length, 0, &pixels, 0, null) != 0);
    const encoded = try a.alloc(u8, length);
    try std.testing.expect(c.png_image_write_to_memory(&png, encoded.ptr, &length, 0, &pixels, 0, null) != 0);
    const good = try validate(a, "texture", encoded[0..length]);
    try std.testing.expectEqual(@as(u32, 2), good.image.width);
    try bounds(&.{good.image});
    const again = try validate(a, "texture", good.blob.bytes);
    try std.testing.expectEqualStrings(good.blob.digest, again.blob.digest);
    encoded[encoded.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidThemeImage, validate(a, "texture", encoded));
    encoded[encoded.len - 1] ^= 1;
    std.mem.writeInt(u32, encoded[16..20], 0xffffffff, .big);
    std.mem.writeInt(u32, encoded[29..33], std.hash.Crc32.hash(encoded[12..29]), .big);
    try std.testing.expectError(error.ThemeImageDimensions, validate(a, "texture", encoded));
    try std.testing.expectError(error.DuplicateThemeAsset, bounds(&.{ good.image, good.image }));
}
