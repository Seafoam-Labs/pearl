//! Pure, bounded interpretation of ffprobe metadata.
const std = @import("std");
const policy = @import("preview.zig");
fn number(value: ?std.json.Value) ?f64 {
    return switch (value orelse return null) {
        .integer => |n| @floatFromInt(n),
        .float => |n| if (std.math.isFinite(n)) n else null,
        .string, .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}
fn field(value: std.json.Value, key: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(key) else null;
}
fn equal(value: ?std.json.Value, expected: []const u8) bool {
    const v = value orelse return false;
    return v == .string and std.mem.eql(u8, v.string, expected);
}
pub const Selection = struct { index: u32, time: f64 };
pub fn select(allocator: std.mem.Allocator, bytes: []const u8) !Selection {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always, .max_value_len = 65536 });
    defer parsed.deinit();
    const streams = field(parsed.value, "streams") orelse return error.Unsupported;
    if (streams != .array or streams.array.items.len == 0 or streams.array.items.len > 32) return error.Unsupported;
    var selected: ?std.json.Value = null;
    var index: f64 = 65536;
    for (streams.array.items) |stream| {
        if (!equal(field(stream, "codec_type"), "video")) continue;
        if (field(stream, "disposition")) |d| if ((number(field(d, "attached_pic")) orelse 0) != 0) continue;
        const i = number(field(stream, "index")) orelse continue;
        if (i >= 0 and i < index and @floor(i) == i) {
            selected = stream;
            index = i;
        }
    }
    const stream = selected orelse return error.Unsupported;
    const w = number(field(stream, "width")) orelse return error.Unsupported;
    const h = number(field(stream, "height")) orelse return error.Unsupported;
    if (!std.math.isFinite(w) or !std.math.isFinite(h) or w < 1 or h < 1 or w * h > 64_000_000) return error.Unsupported;
    if (equal(field(stream, "color_transfer"), "smpte2084") or equal(field(stream, "color_transfer"), "arib-std-b67")) return error.Unsupported;
    var duration = number(field(stream, "duration")) orelse 0;
    if (!std.math.isFinite(duration) or duration <= 0) {
        if (field(parsed.value, "format")) |format| duration = number(field(format, "duration")) orelse 0;
    }
    return .{ .index = @intFromFloat(index), .time = policy.frameTime(duration) };
}

test "video metadata selects real stream, caps timestamp and rejects unsafe dimensions" {
    const data =
        \\{"format":{"duration":"600"},"streams":[{"index":0,"codec_type":"video","disposition":{"attached_pic":1}},{"index":2,"codec_type":"video","width":320,"height":160}]}
    ;
    const chosen = try select(std.testing.allocator, data);
    try std.testing.expectEqual(@as(u32, 2), chosen.index);
    try std.testing.expectEqual(@as(f64, 30), chosen.time);
    const unknown =
        \\{"streams":[{"index":0,"codec_type":"video","width":320,"height":160,"duration":"N/A"}]}
    ;
    try std.testing.expectEqual(@as(f64, 0), (try select(std.testing.allocator, unknown)).time);
    const huge =
        \\{"streams":[{"index":0,"codec_type":"video","width":999999,"height":999999}]}
    ;
    try std.testing.expectError(error.Unsupported, select(std.testing.allocator, huge));
    const hdr =
        \\{"streams":[{"index":0,"codec_type":"video","width":320,"height":160,"color_transfer":"smpte2084"}]}
    ;
    try std.testing.expectError(error.Unsupported, select(std.testing.allocator, hdr));
    try std.testing.expectError(error.Unsupported, select(std.testing.allocator, "{}"));
    try std.testing.expectError(error.UnexpectedEndOfInput, select(std.testing.allocator, "{"));
}
