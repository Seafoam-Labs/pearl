//! Collection mutations retain source identities within one generation only.
const std = @import("std");
const m = @import("aqueous_model.zig");
const c = @import("aqueous_contract.zig");
pub fn stage(a: std.mem.Allocator, base: m.Value, draft: []const u8, key: []const u8, change: m.Value) ![]u8 {
    if (!c.Capabilities.read(base).collections) return error.CollectionCapabilityUnavailable;
    var request = try m.request(a, base, draft, "unused");
    _ = request.object.swapRemove("backup_dir");
    const file = if (std.mem.eql(u8, key, "window_rule_changes")) "rules" else if (std.mem.eql(u8, key, "custom_keybind_changes")) "wm" else if (std.mem.eql(u8, key, "snap_zone_changes")) "layout" else return error.UnknownCollection;
    if (m.get(m.get(request, "raw_files"), file) != .null) return error.ConflictingEdits;
    var changes = m.get(request, key);
    if (changes == .null) changes = .{ .array = .init(a) };
    if (changes != .array or changes.array.items.len >= 2048 or change != .object) return error.InvalidCollection;
    const move = std.mem.eql(u8, m.str(m.get(change, "op")), "move");
    for (changes.array.items) |old| if (move or std.mem.eql(u8, m.str(m.get(old, "op")), "move")) return error.SaveRuleMoveFirst;
    const id = m.get(change, "id");
    var replaced = false;
    if (id != .null) for (changes.array.items) |*old| {
        if (m.equal(m.get(old.*, "id"), id)) {
            var merged = change;
            if (std.mem.eql(u8, key, "window_rule_changes") and std.mem.eql(u8, m.str(m.get(old.*, "op")), "update") and std.mem.eql(u8, m.str(m.get(change, "op")), "update")) {
                var values = m.get(old.*, "values");
                const patch = m.get(change, "values");
                if (values != .object or patch != .object) return error.InvalidCollection;
                values.object = try values.object.clone(a);
                var it = patch.object.iterator();
                while (it.next()) |e| try values.object.put(a, e.key_ptr.*, e.value_ptr.*);
                merged.object = try change.object.clone(a);
                try merged.object.put(a, "values", values);
            }
            old.* = merged;
            replaced = true;
            break;
        }
    };
    if (!replaced) try changes.array.append(change);
    try request.object.put(a, key, changes);
    try @import("aqueous_rule_editor.zig").checkMove(request);
    try request.object.put(a, "collection_preconditions", m.get(base, "collection_preconditions"));
    return std.json.Stringify.valueAlloc(a, request, .{ .whitespace = .indent_2 });
}
pub fn geometry(x: f64, y: f64, width: f64, height: f64) !void {
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(width) or !std.math.isFinite(height) or x < 0 or y < 0 or width <= 0 or height <= 0 or x + width > 1 or y + height > 1) return error.InvalidSnapGeometry;
}
/// An unsaved addition has a local draft index, never a fabricated backend ID.
pub fn editPending(a: std.mem.Allocator, draft: []const u8, key: []const u8, index: usize, change: m.Value) ![]u8 {
    var request = try m.parse(a, draft, m.max_request);
    var changes = m.get(request, key);
    if (changes != .array or index >= changes.array.items.len or !std.mem.eql(u8, m.str(m.get(changes.array.items[index], "op")), "add")) return error.StaleDraft;
    const op = m.str(m.get(change, "op"));
    if (std.mem.eql(u8, op, "delete")) {
        _ = changes.array.orderedRemove(index);
    } else if (std.mem.eql(u8, op, "move")) {
        const direction = m.get(change, "direction");
        if (direction != .integer or (direction.integer != -1 and direction.integer != 1)) return error.InvalidCollection;
        const target: i64 = @as(i64, @intCast(index)) + direction.integer;
        if (target < 0 or target >= changes.array.items.len) return error.CannotMoveFurther;
        const other: usize = @intCast(target);
        if (!std.mem.eql(u8, m.str(m.get(changes.array.items[other], "op")), "add")) return error.SaveRuleMoveFirst;
        std.mem.swap(m.Value, &changes.array.items[index], &changes.array.items[other]);
    } else if (std.mem.eql(u8, op, "add")) {
        changes.array.items[index] = change;
    } else return error.InvalidCollection;
    try request.object.put(a, key, changes);
    return std.json.Stringify.valueAlloc(a, request, .{ .whitespace = .indent_2 });
}
pub fn scalar(spec: m.Value, value: m.Value) !void {
    if (value == .null) return;
    const kind = m.str(m.get(spec, "type"));
    if (std.mem.eql(u8, kind, "boolean")) {
        if (value != .bool) return error.InvalidRuleValue;
    } else if (std.mem.eql(u8, kind, "string")) {
        if (value != .string or value.string.len > 8192) return error.InvalidRuleValue;
    } else if (std.mem.eql(u8, kind, "integer") or std.mem.eql(u8, kind, "number")) {
        if (value != .integer and value != .float) return error.InvalidRuleValue;
        if (std.mem.eql(u8, kind, "integer") and value != .integer) return error.InvalidRuleValue;
        const n = number(value);
        if (!std.math.isFinite(n)) return error.InvalidRuleValue;
        const range = m.list(m.get(spec, "range"));
        if (range.len == 2) {
            if (n < number(range[0]) or n > number(range[1])) return error.InvalidRuleValue;
            if (m.equal(m.get(spec, "exclusive_minimum"), .{ .bool = true }) and n == number(range[0])) return error.InvalidRuleValue;
        }
    } else return error.UnsupportedRuleType;
    const options = m.list(m.get(spec, "options"));
    if (options.len > 0) {
        for (options) |option| if (m.equal(option, value)) return;
        return error.InvalidRuleOption;
    }
}
fn number(v: m.Value) f64 {
    return switch (v) {
        .integer => @floatFromInt(v.integer),
        .float => v.float,
        else => 0,
    };
}
test "snap geometry rejects zero, escaping and nonfinite dimensions" {
    try geometry(0, 0, 0.5, 1);
    try std.testing.expectError(error.InvalidSnapGeometry, geometry(0, 0, 0, 1));
    try std.testing.expectError(error.InvalidSnapGeometry, geometry(0.9, 0, 0.2, 1));
    try std.testing.expectError(error.InvalidSnapGeometry, geometry(0, 0, std.math.nan(f64), 1));
}
test "unsaved collection edits replace and delete additions without backend identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const draft = "{\"window_rule_changes\":[{\"op\":\"add\",\"values\":{\"app_id\":\"one\"}},{\"op\":\"add\",\"values\":{\"app_id\":\"two\"}}]}";
    const replacement = try m.parse(a, "{\"op\":\"add\",\"values\":{\"app_id\":\"edited\",\"floating\":false}}", 4096);
    const edited = try editPending(a, draft, "window_rule_changes", 0, replacement);
    const parsed = try m.parse(a, edited, 4096);
    try std.testing.expectEqual(@as(usize, 2), m.list(m.get(parsed, "window_rule_changes")).len);
    try std.testing.expect(m.equal(m.list(m.get(parsed, "window_rule_changes"))[0], replacement));
    const removed = try editPending(a, edited, "window_rule_changes", 0, try m.parse(a, "{\"op\":\"delete\"}", 4096));
    try std.testing.expectEqual(@as(usize, 1), m.list(m.get(try m.parse(a, removed, 4096), "window_rule_changes")).len);
    try std.testing.expectError(error.StaleDraft, editPending(a, removed, "window_rule_changes", 1, replacement));
}

test "successive rule updates merge deltas including explicit removals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try m.parse(a, "{\"generation\":\"0123456789abcdef\",\"capabilities\":[\"collection_schema_v1\",\"collection_preconditions_v1\",\"collection_identity_v1\"]}", 4096);
    const first = try stage(a, base, try @import("aqueous_draft.zig").empty(a, base), "window_rule_changes", try m.parse(a, "{\"op\":\"update\",\"id\":\"a\",\"values\":{\"floating\":false,\"opacity\":0}}", 4096));
    const second = try stage(a, base, first, "window_rule_changes", try m.parse(a, "{\"op\":\"update\",\"id\":\"a\",\"values\":{\"title\":\"\",\"opacity\":null}}", 4096));
    const changes = m.list(m.get(try m.parse(a, second, 4096), "window_rule_changes"));
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    const values = m.get(changes[0], "values");
    try std.testing.expect(m.equal(m.get(values, "floating"), .{ .bool = false }));
    try std.testing.expect(m.equal(m.get(values, "title"), .{ .string = "" }));
    try std.testing.expect(values.object.contains("opacity") and m.get(values, "opacity") == .null);
    try std.testing.expectError(error.SaveRuleMoveFirst, stage(a, base, second, "window_rule_changes", try m.parse(a, "{\"op\":\"move\",\"id\":\"b\",\"direction\":1}", 4096)));
    const deleted = try stage(a, base, second, "window_rule_changes", try m.parse(a, "{\"op\":\"delete\",\"id\":\"a\"}", 4096));
    try std.testing.expect(m.get(m.list(m.get(try m.parse(a, deleted, 4096), "window_rule_changes"))[0], "values") == .null);
}
