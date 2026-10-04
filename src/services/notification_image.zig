//! Icons are bounded at receive time: raw hints and local files decode down to the
//! size a card retains, so neither the wire payload nor the source image decides cost.
const std = @import("std");
const glib = @import("glib2");
const pixbuf = @import("gdkpixbuf2");
const Text = @import("policy.zig").Text;
const a = std.heap.c_allocator;
/// Both bounds are needed: the byte cap alone still admits 1.4 M pixels at three
/// channels, which is milliseconds of bilinear scaling on the GTK main thread.
const max_input_edge = 1024;
const max_input_bytes = 4 * 1024 * 1024;
const retained_edge = 128;
pub const Resolved = union(enum) {
    pixels: *pixbuf.Pixbuf,
    themed: Text(160),
    none,
};
fn integer(hint: *glib.Variant, index: usize) i32 {
    const v = hint.getChildValue(index);
    defer v.unref();
    return v.getInt32();
}
fn truth(hint: *glib.Variant, index: usize) bool {
    const v = hint.getChildValue(index);
    defer v.unref();
    return v.getBoolean() != 0;
}
fn shrink(image: *pixbuf.Pixbuf) ?*pixbuf.Pixbuf {
    const width = image.getWidth();
    const height = image.getHeight();
    if (width <= retained_edge and height <= retained_edge) return image;
    const longest = @max(width, height);
    const scaled = image.scaleSimple(@max(1, @divTrunc(width * retained_edge, longest)), @max(1, @divTrunc(height * retained_edge, longest)), .bilinear);
    image.unref();
    return scaled;
}
/// Decode an `(iiibiiay)` hint. Every bound is checked before the payload is copied.
pub fn fromHint(hint: *glib.Variant) ?*pixbuf.Pixbuf {
    if (hint.nChildren() != 7) return null;
    const width = integer(hint, 0);
    const height = integer(hint, 1);
    const rowstride = integer(hint, 2);
    const alpha = truth(hint, 3);
    const channels = integer(hint, 5);
    if (width < 1 or height < 1 or width > max_input_edge or height > max_input_edge) return null;
    if (integer(hint, 4) != 8 or channels != @as(i32, if (alpha) 4 else 3)) return null;
    const w: u64 = @intCast(width);
    const h: u64 = @intCast(height);
    const stride: u64 = if (rowstride < 0) 0 else @intCast(rowstride);
    if (stride < w * @as(u64, @intCast(channels))) return null;
    const expected: u64 = (h - 1) * stride + w * @as(u64, @intCast(channels));
    if (expected > max_input_bytes) return null;
    const array = hint.getChildValue(6);
    defer array.unref();
    var count: usize = 0;
    const fixed: *const fn (*glib.Variant, *usize, usize) callconv(.c) ?[*]const u8 = @ptrCast(&glib.Variant.getFixedArray);
    const data = fixed(array, &count, 1) orelse return null;
    // Accept trailing row padding; only `expected` bytes are ever read.
    if (@as(u64, count) < expected) return null;
    const length: usize = @intCast(expected);
    const scratch = a.alloc(u8, length) catch return null;
    defer a.free(scratch);
    @memcpy(scratch, data[0..length]);
    const bytes = glib.Bytes.new(scratch.ptr, scratch.len);
    defer bytes.unref();
    const full: ?*pixbuf.Pixbuf = pixbuf.Pixbuf.newFromBytes(bytes, .rgb, @intFromBool(alpha), 8, width, height, @intCast(stride));
    return if (full) |image| shrink(image) else null;
}
/// The loader downsamples while decoding, so a large source cannot allocate one.
pub fn fromPath(path: [*:0]const u8) ?*pixbuf.Pixbuf {
    return pixbuf.Pixbuf.newFromFileAtScale(path, retained_edge, retained_edge, 1, null);
}
/// Absolute paths and `file://` become pixels; anything else must be a themed name.
pub fn resolve(ref: [:0]const u8) Resolved {
    if (ref.len == 0) return .none;
    if (std.mem.startsWith(u8, ref, "file://")) {
        const local = glib.filenameFromUri(ref.ptr, null, null) orelse return .none;
        defer glib.free(local);
        return if (fromPath(local)) |image| .{ .pixels = image } else .none;
    }
    if (ref[0] == '/') return if (fromPath(ref.ptr)) |image| .{ .pixels = image } else .none;
    if (ref.len > 160) return .none;
    for (ref) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return .none;
    var out: Text(160) = .{};
    out.set(ref);
    return .{ .themed = out };
}

fn payload(width: i32, height: i32, rowstride: i32, alpha: bool, bits: i32, channels: i32, data: []const u8) *glib.Variant {
    const element = glib.VariantType.new("y");
    defer element.free();
    const values = [_]*glib.Variant{
        glib.Variant.newInt32(width),
        glib.Variant.newInt32(height),
        glib.Variant.newInt32(rowstride),
        glib.Variant.newBoolean(@intFromBool(alpha)),
        glib.Variant.newInt32(bits),
        glib.Variant.newInt32(channels),
        glib.Variant.newFixedArray(element, data.ptr, data.len, 1),
    };
    for (values) |v| _ = v.refSink();
    defer for (values) |v| v.unref();
    const value = glib.Variant.newTuple(&values, values.len);
    _ = value.refSink();
    return value;
}
fn solid(width: c_int, height: c_int, fill: u8) !*glib.Variant {
    const bytes = try a.alloc(u8, @intCast(@as(i64, width) * @as(i64, height) * 4));
    defer a.free(bytes);
    @memset(bytes, fill);
    return payload(width, height, width * 4, true, 8, 4, bytes);
}

test "decode keeps gdk-pixbuf channel order and validates the payload before copying" {
    const t = std.testing;
    const value = payload(1, 1, 4, true, 8, 4, &.{ 10, 20, 30, 40 });
    defer value.unref();
    const decoded = fromHint(value) orelse return error.DecodeFailed;
    defer decoded.unref();
    var length: c_uint = 0;
    try t.expectEqualSlices(u8, &.{ 10, 20, 30, 40 }, decoded.getPixelsWithLength(&length)[0..4]);
    const rgb = payload(1, 1, 3, false, 8, 3, &.{ 7, 8, 9 });
    defer rgb.unref();
    const flat = fromHint(rgb) orelse return error.DecodeFailed;
    defer flat.unref();
    try t.expect(flat.getHasAlpha() == 0);
    const padded = payload(2, 1, 16, true, 8, 4, &([_]u8{200} ** 16));
    defer padded.unref();
    const wide = fromHint(padded) orelse return error.DecodeFailed;
    defer wide.unref();
    try t.expectEqual(@as(c_int, 2), wide.getWidth());
    const short = payload(1, 1, 4, true, 8, 4, &.{ 1, 2, 3 });
    defer short.unref();
    try t.expect(fromHint(short) == null);
    const depth = payload(1, 1, 4, true, 16, 4, &.{ 1, 2, 3, 4 });
    defer depth.unref();
    try t.expect(fromHint(depth) == null);
    const mixed = payload(1, 1, 4, true, 8, 3, &.{ 1, 2, 3, 4 });
    defer mixed.unref();
    try t.expect(fromHint(mixed) == null);
    const tight = payload(2, 1, 4, true, 8, 4, &([_]u8{9} ** 8));
    defer tight.unref();
    try t.expect(fromHint(tight) == null);
    // The dimension bound runs before the payload is read or copied.
    const huge = payload(1025, 1025, 4100, true, 8, 4, &.{ 1, 2, 3, 4 });
    defer huge.unref();
    try t.expect(fromHint(huge) == null);
}

test "decode downscales to the retained size and never upscales" {
    const t = std.testing;
    const square = try solid(256, 256, 12);
    defer square.unref();
    const down = fromHint(square) orelse return error.DecodeFailed;
    defer down.unref();
    try t.expectEqual(@as(c_int, 128), down.getWidth());
    try t.expectEqual(@as(c_int, 128), down.getHeight());
    const letterbox = try solid(256, 128, 12);
    defer letterbox.unref();
    const half = fromHint(letterbox) orelse return error.DecodeFailed;
    defer half.unref();
    try t.expectEqual(@as(c_int, 128), half.getWidth());
    try t.expectEqual(@as(c_int, 64), half.getHeight());
    const small = try solid(64, 64, 12);
    defer small.unref();
    const kept = fromHint(small) orelse return error.DecodeFailed;
    defer kept.unref();
    try t.expectEqual(@as(c_int, 64), kept.getWidth());
    try t.expectEqual(@as(c_int, 64), kept.getHeight());
}

test "classify icon references into themed names and rejection" {
    const t = std.testing;
    try t.expect(resolve("file:///does-not-exist/icon.png") == .none);
    try t.expect(resolve("http://example.invalid/icon.png") == .none);
    try t.expect(resolve("icons/logo.png") == .none);
    try t.expect(resolve("../escape.png") == .none);
    try t.expect(resolve("/does-not-exist/icon.png") == .none);
    try t.expect(resolve("/dev/null") == .none);
    try t.expectEqualStrings("pearl-notifications-symbolic", switch (resolve("pearl-notifications-symbolic")) {
        .themed => |name| name.slice(),
        else => return error.TestUnexpectedResult,
    });
    try t.expect(resolve("my icon") == .none);
    try t.expect(resolve("") == .none);
}
