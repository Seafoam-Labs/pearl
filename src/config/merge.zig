//! Three-way JSON merge. Objects merge by field; lists/scalars stay atomic.
const std = @import("std");
const V = std.json.Value;
fn equal(a: V, b: V) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .number_string, .string => |v| std.mem.eql(u8, v, if (b == .string) b.string else b.number_string),
        .array => blk: {
            if (a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |x, y| if (!equal(x, y)) break :blk false;
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var it = a.object.iterator();
            while (it.next()) |field| if (!equal(field.value_ptr.*, b.object.get(field.key_ptr.*) orelse break :blk false)) break :blk false;
            break :blk true;
        },
    };
}
fn merge(a: std.mem.Allocator, base: V, ours: V, theirs: V) !V {
    if (equal(ours, base)) return theirs;
    if (equal(theirs, base) or equal(ours, theirs)) return ours;
    if (base != .object or ours != .object or theirs != .object) return error.MergeConflict;
    // All inputs are canonical schema output, so they contain the same keys.
    var result: V = .{ .object = .empty };
    var it = ours.object.iterator();
    while (it.next()) |field| try result.object.put(a, field.key_ptr.*, try merge(a, base.object.get(field.key_ptr.*) orelse return error.MergeConflict, field.value_ptr.*, theirs.object.get(field.key_ptr.*) orelse return error.MergeConflict));
    return result;
}
pub fn json(a: std.mem.Allocator, base: []const u8, ours: []const u8, theirs: []const u8) ![]const u8 {
    const model = @import("preferences.zig");
    var values: [3]V = undefined;
    for ([_][]const u8{ base, ours, theirs }, &values) |bytes, *value| {
        const p = try model.parse(a, bytes);
        value.* = try std.json.parseFromSliceLeaky(V, a, try std.json.Stringify.valueAlloc(a, p, .{}), .{});
    }
    const result = try std.json.Stringify.valueAlloc(a, try merge(a, values[0], values[1], values[2]), .{ .whitespace = .indent_2 });
    _ = try model.parse(a, result);
    return result;
}
test "disjoint external edits merge; overlapping edits and invalid combined groups retain drafts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try @import("preferences.zig").parse(a, try json(a, "{}", "{\"theme\":{\"variant\":\"light\"}}", "{\"density\":\"compact\"}"));
    try std.testing.expectEqual(.light, result.theme.variant);
    try std.testing.expectEqual(.compact, result.density);
    try std.testing.expectError(error.MergeConflict, json(a, "{}", "{\"font_size\":16}", "{\"font_size\":18}"));
    try std.testing.expectError(error.InvalidGroups, json(a, "{}", "{\"bar\":{\"groups\":{\"left\":\"launcher,title,overview\"}}}", "{\"bar\":{\"groups\":{\"right\":\"control,overview\"}}}"));
}
