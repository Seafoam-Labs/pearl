//! Shared pure field editing. Both hosts retain candidates through their client.
const std = @import("std");
const m = @import("aqueous_model.zig");
pub fn empty(a: std.mem.Allocator, snapshot: m.Value) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{ .protocol = @as(u32, 1), .expected_generation = m.str(m.get(snapshot, "generation")), .changes = [_]struct {}{}, .raw_files = struct {}{} }, .{ .whitespace = .indent_2 });
}
pub fn field(a: std.mem.Allocator, snapshot: m.Value, current: ?[]const u8, id: []const u8, value: m.Value) ![]u8 {
    var v = try m.parse(a, current orelse try empty(a, snapshot), m.max_request);
    const spec = m.field(snapshot, id) orelse return error.UnknownField;
    if (m.get(m.get(v, "raw_files"), m.str(m.get(spec, "file"))) != .null) return error.ConflictingEdits;
    if (v != .object) return error.InvalidRequest;
    var changes = m.get(v, "changes");
    if (changes != .array) return error.InvalidRequest;
    var found = false;
    for (changes.array.items) |*change| if (std.mem.eql(u8, m.str(m.get(change.*, "id")), id)) {
        if (change.* != .object) return error.InvalidRequest;
        try change.object.put(a, "value", value);
        found = true;
        break;
    };
    if (!found) {
        var change: m.Value = .{ .object = .empty };
        try change.object.put(a, "id", .{ .string = id });
        try change.object.put(a, "value", value);
        try changes.array.append(change);
    }
    try v.object.put(a, "changes", changes);
    return std.json.Stringify.valueAlloc(a, v, .{ .whitespace = .indent_2 });
}
test "field edits preserve unrelated data and reject raw overlap without mutating the source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const snapshot = try m.parse(a, "{\"generation\":\"abc\",\"fields\":[{\"id\":\"gap\",\"file\":\"layout\"}]}", 1024);
    const first = try field(a, snapshot, null, "gap", .{ .integer = 2 });
    const second = try field(a, snapshot, first, "gap", .{ .integer = 3 });
    try std.testing.expectEqual(@as(i64, 2), m.get(m.list(m.get(try m.parse(a, first, 1024), "changes"))[0], "value").integer);
    try std.testing.expectEqual(@as(i64, 3), m.get(m.list(m.get(try m.parse(a, second, 1024), "changes"))[0], "value").integer);
    const raw = "{\"changes\":[],\"raw_files\":{\"layout\":\"unmodified text\"}}";
    try std.testing.expectError(error.ConflictingEdits, field(a, snapshot, raw, "gap", .{ .integer = 4 }));
    try std.testing.expectError(error.UnknownField, field(a, snapshot, first, "unknown", .null));
    try std.testing.expectError(error.InvalidRequest, field(a, snapshot, "{\"changes\":{}}", "gap", .null));
}
