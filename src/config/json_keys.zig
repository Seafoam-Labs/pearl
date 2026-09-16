//! Bounded JSON leaf editing for the shared QtEngine configuration.
//! Values and unrelated members survive; changed documents are reformatted.
const std = @import("std");
const ini = @import("ini.zig");
fn document(a: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    if (bytes.len == 0) return .{ .object = std.json.ObjectMap{} };
    try @import("preferences.zig").boundedJson(bytes, 65536, 16);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .duplicate_field_behavior = .@"error" });
    if (value != .object) return error.InvalidQtEngineConfig;
    return value;
}
pub fn get(a: std.mem.Allocator, bytes: []const u8, group: []const u8, key: []const u8) !?[]const u8 {
    var value = try document(a, bytes);
    var parts = std.mem.splitScalar(u8, group, '.');
    while (parts.next()) |part| {
        if (value != .object) return error.InvalidQtEngineConfig;
        value = value.object.get(part) orelse return null;
    }
    if (value != .object) return error.InvalidQtEngineConfig;
    const leaf = value.object.get(key) orelse return null;
    return try std.json.Stringify.valueAlloc(a, leaf, .{});
}
pub fn patch(a: std.mem.Allocator, bytes: []const u8, field: ini.Key) ![]const u8 {
    const old = try get(a, bytes, field.group, field.key);
    if (ini.equal(old, field.value)) return bytes;
    var root = try document(a, bytes);
    var value = &root;
    var parts = std.mem.splitScalar(u8, field.group, '.');
    while (parts.next()) |part| {
        const entry = try value.object.getOrPut(a, part);
        if (!entry.found_existing) entry.value_ptr.* = .{ .object = std.json.ObjectMap{} };
        if (entry.value_ptr.* != .object) return error.InvalidQtEngineConfig;
        value = entry.value_ptr;
    }
    if (field.value) |next| {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, next, .{});
        try value.object.put(a, field.key, parsed);
    } else _ = value.object.orderedRemove(field.key);
    return std.json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
}
test "QtEngine edits preserve unrelated JSON, distinguish null and missing, and reject ambiguous input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original = "{\"theme\":{\"style\":\"Fusion\",\"font\":{\"weight\":600}},\"misc\":{\"singleClickActivate\":false}}";
    const changed = try patch(a, original, .{ .group = "theme", .key = "style", .value = "\"Darkly\"" });
    try std.testing.expectEqualStrings("600", (try get(a, changed, "theme.font", "weight")).?);
    try std.testing.expectEqualStrings("false", (try get(a, changed, "misc", "singleClickActivate")).?);
    const added = try patch(a, changed, .{ .group = "theme.font", .key = "family", .value = "null" });
    try std.testing.expectEqualStrings("null", (try get(a, added, "theme.font", "family")).?);
    const restored = try patch(a, added, .{ .group = "theme.font", .key = "family", .value = null });
    try std.testing.expect((try get(a, restored, "theme.font", "family")) == null);
    try std.testing.expectError(error.InvalidQtEngineConfig, get(a, "{\"theme\":false}", "theme", "style"));
    try std.testing.expectError(error.DuplicateField, get(a, "{\"theme\":{},\"theme\":{}}", "theme", "style"));
}
