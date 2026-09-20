//! Automatic leaves background rendering to the active theme and blur policy.
const std = @import("std");
pub const Config = struct {
    mode: enum { automatic, custom } = .automatic,
    percent: u8 = 86,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Config {
        return jsonParseFromValue(allocator, try std.json.innerParse(std.json.Value, allocator, source, options), options);
    }
    pub fn jsonParseFromValue(_: std.mem.Allocator, value: std.json.Value, _: std.json.ParseOptions) !Config {
        if (value != .object) return error.UnexpectedToken;
        var result: Config = .{};
        var fields = value.object.iterator();
        while (fields.next()) |field| {
            const item = field.value_ptr.*;
            if (std.mem.eql(u8, field.key_ptr.*, "mode")) {
                if (item != .string) return error.UnexpectedToken;
                result.mode = std.meta.stringToEnum(@FieldType(Config, "mode"), item.string) orelse return error.InvalidEnumTag;
            } else if (std.mem.eql(u8, field.key_ptr.*, "percent")) {
                if (item != .integer) return error.UnexpectedToken;
                if (item.integer < 0 or item.integer > 255) return error.Overflow;
                result.percent = @intCast(item.integer);
            } else return error.UnknownField;
        }
        return result;
    }

    pub fn validate(self: Config) !void {
        if (self.percent > 100) return error.InvalidBarOpacity;
    }
    pub fn alpha(self: Config) ?f32 {
        return if (self.mode == .custom) @as(f32, @floatFromInt(self.percent)) / 100 else null;
    }
};

test "automatic is theme owned and custom alpha has exact endpoints" {
    try std.testing.expect((Config{}).alpha() == null);
    for ([_]u8{ 0, 50, 86, 100 }) |percent| {
        const config: Config = .{ .mode = .custom, .percent = percent };
        try config.validate();
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(percent)) / 100, config.alpha().?, 0.00001);
    }
    try std.testing.expectError(error.InvalidBarOpacity, (Config{ .percent = 101 }).validate());
}
