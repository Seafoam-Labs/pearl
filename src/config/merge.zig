//! Three-way JSON merge. Plugin records merge by identity; other lists remain atomic.
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
const Scope = enum { normal, plugins, entries, entry, settings, launcher_icon };
fn merge(a: std.mem.Allocator, base: V, ours: V, theirs: V, scope: Scope) anyerror!V {
    if (equal(ours, base)) return theirs;
    if (equal(theirs, base) or equal(ours, theirs)) return ours;
    if (scope == .launcher_icon) return error.MergeConflict;
    if (scope == .entries or scope == .settings) return keyed(a, base, ours, theirs, if (scope == .entries) "id" else "key", if (scope == .entries) .entry else .normal);
    if (scope == .entry and (!equal(base.object.get("digest").?, ours.object.get("digest").?) or !equal(base.object.get("digest").?, theirs.object.get("digest").?))) return error.MergeConflict;
    if (base != .object or ours != .object or theirs != .object) return error.MergeConflict;
    // All inputs are canonical schema output, so they contain the same keys.
    var result: V = .{ .object = .empty };
    var it = ours.object.iterator();
    while (it.next()) |field| {
        const key = field.key_ptr.*;
        const next: Scope = if (std.mem.eql(u8, key, "launcher_icon")) .launcher_icon else if (scope == .normal and std.mem.eql(u8, key, "plugins")) .plugins else if (scope == .plugins and std.mem.eql(u8, key, "entries")) .entries else if (scope == .entry and std.mem.eql(u8, key, "settings")) .settings else .normal;
        try result.object.put(a, key, try merge(a, base.object.get(key) orelse return error.MergeConflict, field.value_ptr.*, theirs.object.get(key) orelse return error.MergeConflict, next));
    }
    return result;
}
fn find(values: V, field: []const u8, key: []const u8) ?V {
    for (values.array.items) |value| if (std.mem.eql(u8, value.object.get(field).?.string, key)) return value;
    return null;
}
fn optionalEqual(x: ?V, y: ?V) bool {
    return if (x) |value| if (y) |other| equal(value, other) else false else y == null;
}
fn keyed(a: std.mem.Allocator, base: V, ours: V, theirs: V, field: []const u8, scope: Scope) anyerror!V {
    var keys: std.StringHashMap(void) = .init(a);
    defer keys.deinit();
    var result: V = .{ .array = std.array_list.Managed(V).init(a) };
    for ([_]V{ ours, theirs, base }) |values| for (values.array.items) |entry| {
        const key = entry.object.get(field).?.string;
        const visited = try keys.getOrPut(key);
        if (visited.found_existing) continue;
        const b = find(base, field, key);
        const o = find(ours, field, key);
        const t = find(theirs, field, key);
        const value = if (optionalEqual(o, b)) t else if (optionalEqual(t, b) or optionalEqual(o, t)) o else if (b != null and o != null and t != null) try merge(a, b.?, o.?, t.?, scope) else return error.MergeConflict;
        if (value) |v| try result.array.append(v);
    };
    return result;
}
pub fn json(a: std.mem.Allocator, base: []const u8, ours: []const u8, theirs: []const u8) ![]const u8 {
    const model = @import("preferences.zig");
    var values: [3]V = undefined;
    for ([_][]const u8{ base, ours, theirs }, &values) |bytes, *value| {
        const p = try model.parse(a, bytes);
        value.* = try std.json.parseFromSliceLeaky(V, a, try std.json.Stringify.valueAlloc(a, p, .{}), .{});
    }
    const result = try std.json.Stringify.valueAlloc(a, try merge(a, values[0], values[1], values[2], .normal), .{ .whitespace = .indent_2 });
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

test "plugin drafts merge disjoint identities and settings but reject conflicting approval" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try @import("preferences.zig").parse(a, try json(a, "{}", "{\"plugins\":{\"entries\":[{\"id\":\"one\"}]}}", "{\"plugins\":{\"entries\":[{\"id\":\"two\"}]}}"));
    try std.testing.expectEqual(@as(usize, 2), result.plugins.entries.len);
    const base = "{\"plugins\":{\"entries\":[{\"id\":\"one\"}]}}";
    const ours = "{\"plugins\":{\"entries\":[{\"id\":\"one\",\"settings\":[{\"key\":\"speed\",\"value\":\"2\"}]}]}}";
    const theirs = "{\"plugins\":{\"entries\":[{\"id\":\"one\",\"settings\":[{\"key\":\"color\",\"value\":\"blue\"}]}]}}";
    const settings = try @import("preferences.zig").parse(a, try json(a, base, ours, theirs));
    try std.testing.expectEqual(@as(usize, 2), settings.plugins.entries[0].settings.len);
    const changed = "{\"plugins\":{\"entries\":[{\"id\":\"one\",\"digest\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}]}}";
    try std.testing.expectError(error.MergeConflict, json(a, base, ours, changed));
}

test "launcher choices merge with unrelated changes but conflicting lists retain the draft" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ours = "{\"application_launchers\":[{\"backend\":\"xdg\",\"identity\":\"App\",\"desktop_id\":\"Custom.desktop\"}]}";
    const theirs = "{\"application_launchers\":[{\"backend\":\"xdg\",\"identity\":\"App\",\"desktop_id\":\"Other.desktop\"}]}";
    const merged = try @import("preferences.zig").parse(a, try json(a, "{}", ours, "{\"font_size\":18}"));
    try std.testing.expectEqual(@as(u8, 18), merged.font_size);
    try std.testing.expectEqualStrings("Custom.desktop", merged.application_launchers[0].desktop_id);
    try std.testing.expectError(error.MergeConflict, json(a, "{}", ours, theirs));
}

test "launcher icon selections merge atomically and preserve disjoint changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base =
        \\{"bar":{"launcher_icon":{"kind":"theme","value":"old-icon"}}}
    ;
    const ours =
        \\{"bar":{"launcher_icon":{"kind":"file","value":"/tmp/icon.png"}}}
    ;
    const theirs =
        \\{"bar":{"launcher_icon":{"kind":"theme","value":"new-icon"}}}
    ;
    try std.testing.expectError(error.MergeConflict, json(a, base, ours, theirs));
    const merged = try @import("preferences.zig").parse(a, try json(a, "{}", ours, "{\"font_size\":18}"));
    try std.testing.expectEqual(@as(u8, 18), merged.font_size);
    try std.testing.expectEqualStrings("/tmp/icon.png", merged.bar.launcher_icon.value);
}

test "bar opacity merges with unrelated changes and conflicts on competing percentages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "{\"bar\":{\"background_opacity\":{\"mode\":\"custom\",\"percent\":86}}}";
    const ours = "{\"bar\":{\"background_opacity\":{\"mode\":\"custom\",\"percent\":50}}}";
    const theirs = "{\"font_size\":18,\"bar\":{\"background_opacity\":{\"mode\":\"custom\",\"percent\":86}}}";
    const result = try @import("preferences.zig").parse(a, try json(a, base, ours, theirs));
    try std.testing.expectEqual(@as(u8, 18), result.font_size);
    try std.testing.expectEqual(@as(u8, 50), result.bar.background_opacity.percent);
    try std.testing.expectError(error.MergeConflict, json(a, base, ours, "{\"bar\":{\"background_opacity\":{\"mode\":\"custom\",\"percent\":75}}}"));
}
