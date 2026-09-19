//! Frontend image assembly. Requests bind to one committed appearance or preview
//! revision; no package filesystem access and only one chunk in flight.
const std = @import("std");
const assets = @import("../theme/assets.zig");
const model = @import("../theme/package_model.zig");
pub const Transfer = struct {
    arena: std.heap.ArenaAllocator,
    images: []const assets.Image,
    blobs: std.ArrayList(assets.Blob) = .empty,
    index: usize = 0,
    bytes: std.ArrayList(u8) = .empty,
    revision: u64,
    preview: bool,
    pub fn init(images: []const assets.Image, revision: u64, preview: bool) !Transfer {
        try assets.bounds(images);
        var self: Transfer = .{ .arena = .init(std.heap.c_allocator), .images = undefined, .revision = revision, .preview = preview };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.images = try model.parse([]const assets.Image, a, try std.json.Stringify.valueAlloc(a, images, .{}), 16384);
        return self;
    }
    pub fn deinit(self: *Transfer) void {
        self.arena.deinit();
    }
    pub fn request(self: *Transfer, client: anytype) !void {
        if (self.index >= self.images.len) return;
        try client.request(.@"theme.asset", .{ .preview = self.preview, .revision = @import("editor_protocol.zig").num(self.revision), .digest = self.images[self.index].digest, .offset = self.bytes.items.len });
    }
    pub fn accept(self: *Transfer, value: std.json.Value) !bool {
        if (self.index >= self.images.len) return error.InvalidThemeAssetChunk;
        const a = self.arena.allocator();
        const reply = try @import("../aqueous/entities.zig").read(struct { digest: []const u8, offset: usize, total: usize, data: []const u8 }, a, value);
        const image = self.images[self.index];
        if (!std.mem.eql(u8, reply.digest, image.digest) or reply.offset != self.bytes.items.len or reply.total != image.size or reply.data.len > 65536) return error.InvalidThemeAssetChunk;
        const length = try std.base64.standard.Decoder.calcSizeForSlice(reply.data);
        if (length == 0 or length > 48 * 1024 or length > image.size - self.bytes.items.len) return error.InvalidThemeAssetChunk;
        const decoded = try a.alloc(u8, length);
        try std.base64.standard.Decoder.decode(decoded, reply.data);
        try self.bytes.appendSlice(a, decoded);
        if (self.bytes.items.len == image.size) {
            if (!std.mem.eql(u8, &model.hash(self.bytes.items), image.digest)) return error.ThemeAssetDigestMismatch;
            const checked = try assets.validate(a, image.id, self.bytes.items);
            if (checked.image.width != image.width or checked.image.height != image.height) return error.ThemeImageDimensions;
            try self.blobs.append(a, .{ .digest = image.digest, .bytes = try a.dupe(u8, self.bytes.items) });
            self.bytes.clearRetainingCapacity();
            self.index += 1;
        }
        return self.index == self.images.len;
    }
};

test "asset chunks reject wrong offsets, hashes and completed transfers" {
    const a = std.testing.allocator;
    var transfer = try Transfer.init(&.{.{ .id = "image", .digest = &model.hash("hello"), .size = 5, .width = 1, .height = 1 }}, 1, false);
    defer transfer.deinit();
    const bytes = try std.json.Stringify.valueAlloc(a, .{ .digest = model.hash("hello")[0..], .offset = @as(usize, 1), .total = @as(usize, 5), .data = "d29ybGQ=" }, .{});
    defer a.free(bytes);
    var reply = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer reply.deinit();
    try std.testing.expectError(error.InvalidThemeAssetChunk, transfer.accept(reply.value));
    reply.value.object.getPtr("offset").?.* = .{ .integer = 0 };
    try std.testing.expectError(error.ThemeAssetDigestMismatch, transfer.accept(reply.value));
    transfer.index = 1;
    try std.testing.expectError(error.InvalidThemeAssetChunk, transfer.accept(reply.value));
}
