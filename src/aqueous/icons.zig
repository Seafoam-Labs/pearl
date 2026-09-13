//! Session-local cache: 32 entries, at most 8 MiB decoded pixels, 16 queued fetches.
const std = @import("std");
const glib = @import("glib2");
const pixbuf = @import("gdkpixbuf2");
const codec = @import("codec.zig");
const Model = @import("reducer.zig").Model;
const a = std.heap.c_allocator;
pub const Key = struct {
    id: []const u8,
    revision: []const u8,
    size: u16,
    scale: u16,
    pub fn valid(self: Key, model: *const Model) bool {
        if (self.size == 0 or self.scale == 0 or self.scale > 8 or @as(u32, self.size) * self.scale > 256) return false;
        const w = model.get(.window, self.id) orelse return false;
        const icon = w.icon orelse return false;
        return icon.has_pixels and std.mem.eql(u8, self.revision, icon.revision);
    }
    pub fn eql(self: Key, other: Key) bool {
        return self.size == other.size and self.scale == other.scale and std.mem.eql(u8, self.id, other.id) and std.mem.eql(u8, self.revision, other.revision);
    }
};
pub const Entry = struct {
    key: Key,
    pixels: ?*pixbuf.Pixbuf = null,
    pending: bool = true,
    pub fn init(key: Key) !Entry {
        const id = try a.dupe(u8, key.id);
        errdefer a.free(id);
        const revision = try a.dupe(u8, key.revision);
        return .{ .key = .{ .id = id, .revision = revision, .size = key.size, .scale = key.scale } };
    }
    pub fn deinit(self: *Entry) void {
        a.free(self.key.id);
        a.free(self.key.revision);
        if (self.pixels) |p| p.unref();
    }
};
pub const Cache = struct {
    entries: std.ArrayList(Entry) = .empty,
    pub fn clear(self: *Cache) void {
        for (self.entries.items) |*v| v.deinit();
        self.entries.deinit(a);
        self.entries = .empty;
    }
    pub fn prune(self: *Cache, model: *const Model) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (!self.entries.items[i].key.valid(model)) {
                var v = self.entries.orderedRemove(i);
                v.deinit();
            } else i += 1;
        }
    }
    pub fn find(self: *Cache, key: Key) ?*Entry {
        for (self.entries.items) |*v| if (v.key.eql(key)) return v;
        return null;
    }
    pub fn request(self: *Cache, key: Key) !?*pixbuf.Pixbuf {
        if (self.find(key)) |v| return v.pixels;
        var pending: usize = 0;
        for (self.entries.items) |v| {
            if (v.pending) pending += 1;
        }
        if (pending >= 16) return error.QueueFull;
        if (self.entries.items.len == 32) {
            for (self.entries.items, 0..) |v, i| if (!v.pending) {
                var old = self.entries.orderedRemove(i);
                old.deinit();
                break;
            };
        }
        var entry = try Entry.init(key);
        errdefer entry.deinit();
        try self.entries.append(a, entry);
        return null;
    }
};
/// Aqueous emits non-interlaced, eight-bit straight RGBA. Decode only that
/// format, with fixed output bounds; ancillary chunks are CRC-checked and skipped
/// without decompressing profiles or metadata. No filesystem or image helper.
pub fn decode(key: Key, result: codec.IconResult) !*pixbuf.Pixbuf {
    const dimension = @as(u32, key.size) * key.scale;
    if (dimension == 0 or dimension > 256 or key.scale == 0 or key.scale > 8 or result.data.len > 512 * 1024 or
        !std.mem.eql(u8, key.revision, result.revision) or result.width != dimension or result.height != dimension) return error.InvalidIcon;
    const decoder = std.base64.standard.Decoder;
    const bytes = try a.alloc(u8, try decoder.calcSizeForSlice(result.data));
    defer a.free(bytes);
    try decoder.decode(bytes, result.data);
    if (bytes.len < 33 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return error.InvalidIcon;
    if (std.mem.readInt(u32, bytes[8..12], .big) != 13 or !std.mem.eql(u8, bytes[12..16], "IHDR") or
        std.mem.readInt(u32, bytes[16..20], .big) != dimension or std.mem.readInt(u32, bytes[20..24], .big) != dimension or
        !std.mem.eql(u8, bytes[24..29], &.{ 8, 6, 0, 0, 0 })) return error.InvalidIcon;
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(a);
    var offset: usize = 8;
    var ended = false;
    var data_ended = false;
    while (offset < bytes.len) {
        if (bytes.len - offset < 12 or ended) return error.InvalidIcon;
        const length = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        if (length > bytes.len - offset - 12) return error.InvalidIcon;
        const kind = bytes[offset + 4 ..][0..4];
        const payload = bytes[offset + 8 ..][0..length];
        const crc = std.mem.readInt(u32, bytes[offset + 8 + length ..][0..4], .big);
        if (std.hash.Crc32.hash(bytes[offset + 4 ..][0 .. 4 + length]) != crc) return error.InvalidIcon;
        if (offset == 8) {
            // IHDR already validated above.
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            if (data_ended) return error.InvalidIcon;
            try compressed.appendSlice(a, payload);
        } else {
            if (compressed.items.len > 0) data_ended = true;
            if (std.mem.eql(u8, kind, "IEND")) {
                if (length != 0 or compressed.items.len == 0) return error.InvalidIcon;
                ended = true;
            } else if (kind[0] & 0x20 == 0) return error.InvalidIcon;
        }
        offset += @as(usize, length) + 12;
    }
    if (!ended) return error.InvalidIcon;
    const stride = dimension * 4;
    const scanlines = try a.alloc(u8, (stride + 1) * dimension);
    defer a.free(scanlines);
    var input = std.Io.Reader.fixed(compressed.items);
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var zlib = std.compress.flate.Decompress.init(&input, .zlib, &history);
    zlib.reader.readSliceAll(scanlines) catch return error.InvalidIcon;
    if (zlib.reader.takeByte()) |_| return error.InvalidIcon else |err| if (err != error.EndOfStream) return error.InvalidIcon;
    if (input.seek != compressed.items.len or zlib.container_metadata.zlib.adler != std.hash.Adler32.hash(scanlines)) return error.InvalidIcon;
    const rgba = try a.alloc(u8, stride * dimension);
    defer a.free(rgba);
    for (0..dimension) |y| {
        const row = scanlines[y * (stride + 1) ..][0 .. stride + 1];
        for (0..stride) |x| {
            const left: u8 = if (x >= 4) rgba[y * stride + x - 4] else 0;
            const up: u8 = if (y > 0) rgba[(y - 1) * stride + x] else 0;
            const corner: u8 = if (x >= 4 and y > 0) rgba[(y - 1) * stride + x - 4] else 0;
            const prediction: u8 = switch (row[0]) {
                0 => 0,
                1 => left,
                2 => up,
                3 => @intCast((@as(u16, left) + up) / 2),
                4 => paeth(left, up, corner),
                else => return error.InvalidIcon,
            };
            rgba[y * stride + x] = row[x + 1] +% prediction;
        }
    }
    const storage = glib.Bytes.new(rgba.ptr, rgba.len);
    defer storage.unref();
    return pixbuf.Pixbuf.newFromBytes(storage, .rgb, 1, 8, @intCast(dimension), @intCast(dimension), @intCast(stride));
}
fn paeth(left: u8, up: u8, corner: u8) u8 {
    const p = @as(i32, left) + up - corner;
    const dl = @abs(p - left);
    const du = @abs(p - up);
    const dc = @abs(p - corner);
    return if (dl <= du and dl <= dc) left else if (du <= dc) up else corner;
}

test "PNG decode bounds precede allocation and reject invalid chunks and revision mismatch" {
    const t = std.testing;
    const key: Key = .{ .id = "w", .revision = "2", .size = 1, .scale = 1 };
    var result: codec.IconResult = .{ .revision = "2", .width = 1, .height = 1, .format = .png, .data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==" };
    const p = try decode(key, result);
    defer p.unref();
    try t.expectEqual(@as(c_int, 1), p.getWidth());
    result.revision = "3";
    try t.expectError(error.InvalidIcon, decode(key, result));
    result.revision = "2";
    var bytes: [70]u8 = undefined;
    const length = try std.base64.standard.Decoder.calcSizeForSlice(result.data);
    try std.base64.standard.Decoder.decode(bytes[0..length], result.data);
    var encoded: [128]u8 = undefined;
    std.mem.writeInt(u32, bytes[16..20], 0x7fffffff, .big);
    result.data = std.base64.standard.Encoder.encode(&encoded, bytes[0..length]);
    try t.expectError(error.InvalidIcon, decode(key, result));
    std.mem.writeInt(u32, bytes[16..20], 1, .big);
    @memcpy(bytes[37..41], "iCCP");
    result.data = std.base64.standard.Encoder.encode(&encoded, bytes[0..length]);
    try t.expectError(error.InvalidIcon, decode(key, result));
}

test "icon queue deduplicates and cache bounds include negative results" {
    const t = std.testing;
    var cache: Cache = .{};
    defer cache.clear();
    for (1..17) |size| {
        _ = try cache.request(.{ .id = "w", .revision = "1", .size = @intCast(size), .scale = 1 });
    }
    _ = try cache.request(.{ .id = "w", .revision = "1", .size = 1, .scale = 1 });
    try t.expectEqual(@as(usize, 16), cache.entries.items.len);
    try t.expectError(error.QueueFull, cache.request(.{ .id = "w", .revision = "1", .size = 17, .scale = 1 }));
    for (cache.entries.items) |*v| v.pending = false;
    for (17..50) |size| {
        const key: Key = .{ .id = "w", .revision = "1", .size = @intCast(size), .scale = 1 };
        _ = try cache.request(key);
        cache.find(key).?.pending = false;
        try t.expect(cache.entries.items.len <= 32);
    }
}
