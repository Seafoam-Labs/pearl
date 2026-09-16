//! Read-only committed appearance, shared by backend and frontend. No draft/file IO.
const prefs = @import("../config/preferences.zig");
const theme = @import("../theme/theme.zig");
const std = @import("std");
const e = @import("../aqueous/entities.zig");
pub const Snapshot = struct {
    revision: u64 = 0,
    mode: @FieldType(prefs.Theme, "mode") = .static,
    variant: @FieldType(prefs.Theme, "variant") = .dark,
    gtk_name: []const u8 = "",
    font: []const u8 = "",
    font_size: u8 = 14,
    density: @FieldType(prefs.Preferences, "density") = .normal,
    reduced_motion: bool = false,
    palette: theme.Palette = theme.dark,
    pub fn jsonStringify(self: Snapshot, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        inline for (@typeInfo(Snapshot).@"struct".fields) |field| {
            try writer.objectField(field.name);
            if (comptime std.mem.eql(u8, field.name, "revision")) {
                var buf: [20]u8 = undefined;
                try writer.write(std.fmt.bufPrint(&buf, "{d}", .{self.revision}) catch unreachable);
            } else try writer.write(@field(self, field.name));
        }
        try writer.endObject();
    }
    pub fn read(alloc: std.mem.Allocator, value: std.json.Value) !Snapshot {
        var result: Snapshot = undefined;
        inline for (@typeInfo(Snapshot).@"struct".fields) |field| {
            const v = try e.field(value, field.name);
            if (comptime std.mem.eql(u8, field.name, "revision")) {
                const text = try e.read([]const u8, alloc, v);
                try e.decimal(text);
                result.revision = try std.fmt.parseInt(u64, text, 10);
            } else @field(result, field.name) = try e.read(field.type, alloc, v);
        }
        return result;
    }
};

test "committed appearance preserves full-width revision on the wire" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const original: Snapshot = .{ .revision = std.math.maxInt(u64), .font_size = 24 };
    const json = try std.json.Stringify.valueAlloc(alloc, original, .{});
    const value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    try std.testing.expectEqualStrings("18446744073709551615", value.object.get("revision").?.string);
    const decoded = try Snapshot.read(alloc, value);
    try std.testing.expectEqual(original.revision, decoded.revision);
    try std.testing.expectEqual(original.font_size, decoded.font_size);
}
