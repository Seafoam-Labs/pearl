//! Lossless window-rule projection. Values borrow the caller's arena.
const std = @import("std");
const m = @import("aqueous_model.zig");
pub const key = "window_rule_changes";
pub const Rule = struct { id: m.Value = .null, pending: ?usize = null, values: m.Value };
pub fn matcher(name: []const u8) bool {
    for ([_][]const u8{ "app_id", "class", "title", "tag", "content_type", "window_type" }) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}
/// The v1 compatibility map deliberately does not classify unknown keys.
pub fn known(name: []const u8) bool {
    for ([_][]const u8{ "app_id", "class", "title", "content_type", "layout", "output", "workspace", "floating", "fullscreen", "ignore_struts", "width", "height", "x", "y", "placement_policy", "anchor", "size", "scale", "blur", "opacity", "buffer_scale_policy", "hdr_expand", "overlay_plane", "stack_layer", "focus", "fixed_position", "skip_switcher", "skip_taskbar", "scrolling_full_width", "scrolling_width", "tag", "scope", "window_type" }) |k| if (std.mem.eql(u8, name, k)) return true;
    return false;
}
pub fn overlay(a: std.mem.Allocator, original: m.Value, patch: m.Value) !m.Value {
    if (original != .object or patch != .object) return error.InvalidCollection;
    var values = original;
    values.object = try original.object.clone(a);
    var it = patch.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == .null) {
            _ = values.object.swapRemove(e.key_ptr.*);
        } else try values.object.put(a, e.key_ptr.*, e.value_ptr.*);
    }
    return values;
}
pub fn project(a: std.mem.Allocator, base: m.Value, request: m.Value) ![]Rule {
    var rules: std.ArrayList(Rule) = .empty;
    for (m.list(m.get(base, "window_rules"))) |item| try rules.append(a, .{ .id = m.get(item, "id"), .values = m.get(item, "values") });
    for (m.list(m.get(request, key)), 0..) |change, index| {
        const op = m.str(m.get(change, "op"));
        if (std.mem.eql(u8, op, "add")) {
            try rules.append(a, .{ .pending = index, .values = try overlay(a, .{ .object = .empty }, m.get(change, "values")) });
            continue;
        }
        var found = false;
        for (rules.items, 0..) |*rule, i| {
            if (rule.pending != null or !m.equal(rule.id, m.get(change, "id"))) continue;
            found = true;
            if (std.mem.eql(u8, op, "update")) rule.values = try overlay(a, rule.values, m.get(change, "values")) else if (std.mem.eql(u8, op, "delete")) {
                _ = rules.orderedRemove(i);
            } else if (std.mem.eql(u8, op, "move")) {
                const d = m.get(change, "direction");
                if (d != .integer or (d.integer != -1 and d.integer != 1)) return error.InvalidCollection;
                const target = @as(i64, @intCast(i)) + d.integer;
                if (target < 0 or target >= rules.items.len) return error.CannotMoveFurther;
                std.mem.swap(Rule, &rules.items[i], &rules.items[@intCast(target)]);
            } else return error.InvalidCollection;
            break;
        }
        if (!found) return error.StaleDraft;
    }
    return rules.toOwnedSlice(a);
}
/// Omitted keys mean untouched; null explicitly removes an existing key.
pub fn delta(a: std.mem.Allocator, before: m.Value, after: m.Value) !m.Value {
    var patch: m.Value = .{ .object = .empty };
    if (before != .object or after != .object) return error.InvalidCollection;
    var old = before.object.iterator();
    while (old.next()) |e| if (!after.object.contains(e.key_ptr.*)) try patch.object.put(a, e.key_ptr.*, .null);
    var next = after.object.iterator();
    while (next.next()) |e| if (!m.equal(m.get(before, e.key_ptr.*), e.value_ptr.*)) try patch.object.put(a, e.key_ptr.*, e.value_ptr.*);
    return patch;
}
pub fn hasMove(request: m.Value) bool {
    for (m.list(m.get(request, key))) |c| if (std.mem.eql(u8, m.str(m.get(c, "op")), "move")) return true;
    return false;
}
pub fn checkMove(request: m.Value) !void {
    if (!hasMove(request)) return;
    if (m.list(m.get(request, key)).len != 1) return error.SaveRuleMoveFirst;
    var it = request.object.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        var metadata = false;
        for ([_][]const u8{ "protocol", "expected_generation", "collection_preconditions", "backup_dir", key }) |allowed| if (std.mem.eql(u8, allowed, k)) {
            metadata = true;
            break;
        };
        if (metadata) continue;
        const v = e.value_ptr.*;
        if (v == .null or (v == .array and v.array.items.len == 0) or (v == .object and v.object.count() == 0) or (v == .bool and !v.bool)) continue;
        return error.SaveRuleMoveFirst;
    }
}
/// Advanced can retain malformed JSON for repair, but cannot mix a parsed move.
pub fn checkBytes(a: std.mem.Allocator, bytes: []const u8) !void {
    const parsed = m.parse(a, bytes, m.max_request) catch return;
    try checkMove(parsed);
}
test "projection preserves identity, unknown values, false zero and empty; removals are null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try m.parse(a, "{\"window_rules\":[{\"id\":\"a\",\"values\":{\"app_id\":\"same\",\"floating\":true,\"future\":42}},{\"id\":\"b\",\"values\":{\"app_id\":\"same\"}}]}", 4096);
    const req = try m.parse(a, "{\"window_rule_changes\":[{\"op\":\"update\",\"id\":\"a\",\"values\":{\"floating\":false,\"opacity\":0,\"title\":\"\"}},{\"op\":\"delete\",\"id\":\"b\"},{\"op\":\"add\",\"values\":{\"app_id\":\"new\"}}]}", 4096);
    const rows = try project(a, base, req);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(?usize, 2), rows[1].pending);
    try std.testing.expect(m.equal(m.get(rows[0].values, "future"), .{ .integer = 42 }));
    try std.testing.expect(m.equal(m.get(rows[0].values, "floating"), .{ .bool = false }));
    try std.testing.expect(m.equal(m.get(rows[0].values, "opacity"), .{ .integer = 0 }));
    try std.testing.expect(m.equal(m.get(rows[0].values, "title"), .{ .string = "" }));
    const after = try overlay(a, rows[0].values, try m.parse(a, "{\"title\":null}", 4096));
    const patch = try delta(a, rows[0].values, after);
    try std.testing.expect(patch.object.contains("title"));
    try std.testing.expectEqual(@as(usize, 1), patch.object.count());
    try std.testing.expect(m.equal(try overlay(a, rows[0].values, patch), after));
}
test "isolated move projects order and rejects unrelated changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try m.parse(a, "{\"window_rules\":[{\"id\":\"a\",\"values\":{}},{\"id\":\"b\",\"values\":{}}]}", 4096);
    var req = try m.parse(a, "{\"window_rule_changes\":[{\"op\":\"move\",\"id\":\"b\",\"direction\":-1}]}", 4096);
    try checkMove(req);
    const rows = try project(a, base, req);
    try std.testing.expect(m.equal(rows[0].id, .{ .string = "b" }));
    try req.object.put(a, "sync_cursor", .{ .bool = true });
    try std.testing.expectError(error.SaveRuleMoveFirst, checkMove(req));
}

/// Current collection v1 helpers use empty strings as removals except for tag.
/// Retain existing empty values without emitting an update that would erase them.
pub fn checkEmpty(name: []const u8, before: m.Value, after: m.Value) !void {
    if (after == .string and after.string.len == 0 and !std.mem.eql(u8, name, "tag") and !m.equal(before, after)) return error.EmptyValueUnsupported;
}
test "legacy empty values remain untouched and unsupported new empties cannot become removals" {
    try checkEmpty("title", .{ .string = "" }, .{ .string = "" });
    try checkEmpty("tag", .null, .{ .string = "" });
    try std.testing.expectError(error.EmptyValueUnsupported, checkEmpty("title", .null, .{ .string = "" }));
    try std.testing.expectError(error.EmptyValueUnsupported, checkEmpty("output", .{ .string = "HDMI-A-1" }, .{ .string = "" }));
}
