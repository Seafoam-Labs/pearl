//! Saved per-image wallpaper crops; no GTK, filesystem or clock dependencies.
const std = @import("std");

/// One image's crop as fractions of that image, so an entry survives the file
/// being resized and round-trips without needing pixel dimensions.
pub const Crop = struct {
    path: []const u8 = "",
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 1,
    height: f32 = 1,
};

/// The share of an image a display-shaped crop covers on each axis.
pub const Frame = struct { width: f32, height: f32 };

pub const Pixels = struct { x: i32, y: i32, width: i32, height: i32 };

/// A slideshow folder's worth of hand-placed crops, each image at most once.
pub const max = 16;
/// How far past the display-shaped cover crop the editor lets you zoom in.
pub const min_zoom: f32 = 0.05;
/// f32 goes through decimal text on every save, so edge-on rectangles need slack.
const slack: f32 = 0.001;

pub fn find(crops: []const Crop, path: []const u8) ?Crop {
    for (crops) |saved| if (std.mem.eql(u8, saved.path, path)) return saved;
    return null;
}

/// The largest rectangle of `aspect` (width / height) that fits inside an image,
/// as the share of that image it covers. Locking the editor to the output's
/// aspect ratio is what makes a crop fill the display exactly instead of being
/// re-cropped by the fit mode at paint time.
pub fn frame(image_width: u32, image_height: u32, aspect: f64) ?Frame {
    if (image_width == 0 or image_height == 0 or !(aspect > 0)) return null;
    const wide: f64 = image_width;
    const tall: f64 = image_height;
    return if (wide / tall > aspect)
        .{ .width = @floatCast(aspect * tall / wide), .height = 1 }
    else
        .{ .width = 1, .height = @floatCast(wide / (tall * aspect)) };
}

/// Pixel rectangle for one image, or null when the crop is the whole frame and
/// sub-setting would only cost a texture copy. Values are clamped: a stale or
/// hand-edited entry must never yield an empty or out-of-bounds rectangle.
pub fn pixels(crop: Crop, width: i32, height: i32) ?Pixels {
    if (width < 2 or height < 2) return null;
    const box_width = span(crop.width, width);
    const box_height = span(crop.height, height);
    if (box_width == width and box_height == height) return null;
    return .{
        .x = offset(crop.x, width, box_width),
        .y = offset(crop.y, height, box_height),
        .width = box_width,
        .height = box_height,
    };
}

pub fn validate(crops: []const Crop) !void {
    if (crops.len > max) return error.TooManyCrops;
    for (crops, 0..) |crop, i| {
        for (crops[0..i]) |previous| if (std.mem.eql(u8, previous.path, crop.path)) return error.DuplicateCrop;
        if (crop.path.len == 0 or crop.path.len > 1024 or crop.path[0] != '/') return error.InvalidCropPath;
        if (!std.unicode.utf8ValidateSlice(crop.path)) return error.InvalidCropPath;
        for (crop.path) |ch| if (ch < 32 or ch == 127) return error.InvalidCropPath;
        // Each comparison is written so a NaN fails it.
        if (!(crop.width > 0) or !(crop.height > 0)) return error.InvalidCropRect;
        if (!(crop.x >= 0) or !(crop.y >= 0)) return error.InvalidCropRect;
        if (crop.width > 1 + slack or crop.height > 1 + slack) return error.InvalidCropRect;
        if (crop.x + crop.width > 1 + slack or crop.y + crop.height > 1 + slack) return error.InvalidCropRect;
    }
}

/// Clamps a fraction to [0,1]. A NaN fails `v > 0` and degrades to zero.
fn share(value: f32) f64 {
    const v: f64 = value;
    if (!(v > 0)) return 0;
    return @min(1, v);
}
fn span(value: f32, total: i32) i32 {
    return @max(1, @min(total, @as(i32, @intFromFloat(@round(share(value) * @as(f64, @floatFromInt(total)))))));
}
fn offset(value: f32, total: i32, used: i32) i32 {
    const at = @max(0, @min(total, @as(i32, @intFromFloat(@round(share(value) * @as(f64, @floatFromInt(total)))))));
    return @min(total - used, at);
}

test "frame locks a crop to the display aspect ratio" {
    const t = std.testing;
    // A 16:9 image on a 16:10 display loses width, not height.
    const narrow = frame(3840, 2160, 16.0 / 10.0).?;
    try t.expectApproxEqAbs(@as(f32, 0.9), narrow.width, 0.0001);
    try t.expectEqual(@as(f32, 1), narrow.height);
    const drawn = @as(f64, narrow.width) * 3840 / (@as(f64, narrow.height) * 2160);
    try t.expectApproxEqAbs(16.0 / 10.0, drawn, 0.0001);
    // A 16:9 image on a 21:9 display loses height, not width.
    const wide = frame(3840, 2160, 21.0 / 9.0).?;
    try t.expectEqual(@as(f32, 1), wide.width);
    try t.expectApproxEqAbs(16.0 / 21.0, wide.height, 0.0001);
    // A matching aspect covers everything.
    const exact = frame(1920, 1080, 16.0 / 9.0).?;
    try t.expectApproxEqAbs(@as(f32, 1), exact.width, 0.0001);
    try t.expectApproxEqAbs(@as(f32, 1), exact.height, 0.0001);
    try t.expect(frame(0, 1080, 1.6) == null);
    try t.expect(frame(1920, 1080, 0) == null);
}

test "pixels clamps a saved rectangle into the image" {
    const t = std.testing;
    // A quarter of the image, offset to the bottom right corner.
    try t.expectEqual(Pixels{ .x = 960, .y = 540, .width = 960, .height = 540 }, pixels(.{ .x = 0.5, .y = 0.5, .width = 0.5, .height = 0.5 }, 1920, 1080).?);
    // The whole frame needs no sub-pixbuf.
    try t.expect(pixels(.{}, 1920, 1080) == null);
    // An oversized rectangle is trimmed and its offset pulled back inside.
    try t.expectEqual(Pixels{ .x = 0, .y = 0, .width = 1920, .height = 1079 }, pixels(.{ .x = 4, .y = -1, .width = 9, .height = 0.99907 }, 1920, 1080).?);
    // A one pixel source has nothing to crop.
    try t.expect(pixels(.{ .width = 0.5, .height = 0.5 }, 1, 1080) == null);
}

test "crop validation rejects duplicates, relative paths and bad rectangles" {
    const t = std.testing;
    try validate(&.{});
    try validate(&.{.{ .path = "/p/a.png", .x = 0.25, .y = 0, .width = 0.5, .height = 1 }});
    try t.expectError(error.TooManyCrops, validate(&[_]Crop{.{ .path = "/p/a.png" }} ** (max + 1)));
    try t.expectError(error.DuplicateCrop, validate(&.{ .{ .path = "/p/a.png" }, .{ .path = "/p/a.png" } }));
    for ([_]Crop{ .{ .path = "" }, .{ .path = "p/a.png" }, .{ .path = "/p/a\npng" } }) |bad|
        try t.expectError(error.InvalidCropPath, validate(&.{bad}));
    const path = "/p/a.png";
    for ([_]Crop{
        .{ .path = path, .width = 0 },
        .{ .path = path, .height = -1 },
        .{ .path = path, .width = 1.5 },
        .{ .path = path, .x = -0.5 },
        .{ .path = path, .x = 0.75, .width = 0.5 },
        .{ .path = path, .y = 1, .height = 0.5 },
        .{ .path = path, .width = std.math.nan(f32) },
    }) |bad| try t.expectError(error.InvalidCropRect, validate(&.{bad}));
    // A rectangle exactly filling the image still saves after a float round-trip.
    try validate(&.{.{ .path = path, .width = 1.0000001, .height = 1 }});
}
