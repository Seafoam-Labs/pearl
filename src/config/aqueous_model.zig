//! Helper JSON is the authority. Pearl never parses or serializes Aqueous TOML.
const std = @import("std");
pub const Value = std.json.Value;
pub const max_request = 4 * 1024 * 1024;
pub const max_response = 16 * 1024 * 1024;
pub const Reload = enum { applied, failed, unknown };
pub fn reloadReport(stderr: []const u8) Reload {
    const text = std.mem.trimEnd(u8, stderr, "\r\n");
    const start = if (std.mem.lastIndexOfScalar(u8, text, '\n')) |n| n + 1 else 0;
    const line = text[start..];
    if (std.mem.eql(u8, line, "reload=applied")) return .applied;
    if (std.mem.eql(u8, line, "reload=failed")) return .failed;
    return .unknown;
}
test "missing or unconfirmed reload acknowledgement remains unknown" {
    try std.testing.expectEqual(Reload.applied, reloadReport("diagnostic\nreload=applied\n"));
    try std.testing.expectEqual(Reload.failed, reloadReport("reload=failed\n"));
    try std.testing.expectEqual(Reload.unknown, reloadReport("reload=accepted\n"));
    try std.testing.expectEqual(Reload.unknown, reloadReport(""));
}
pub fn parse(a: std.mem.Allocator, bytes: []const u8, limit: usize) !Value {
    if (bytes.len > limit or !std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidHelperJson;
    // Bound nesting before allocating the DOM, including raw editor requests.
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |c| {
        if (quoted) {
            if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') quoted = false;
        } else switch (c) {
            '"' => quoted = true,
            '{', '[' => {
                depth += 1;
                if (depth > 32) return error.InvalidHelperJson;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidHelperJson;
                depth -= 1;
            },
            else => {},
        }
    }
    const value = try std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always });
    try strings(value);
    return value;
}
fn strings(v: Value) !void {
    switch (v) {
        .string => |s| if (std.mem.indexOfScalar(u8, s, 0) != null) return error.InvalidHelperJson,
        .array => |items| for (items.items) |item| try strings(item),
        .object => |items| {
            var it = items.iterator();
            while (it.next()) |e| {
                if (std.mem.indexOfScalar(u8, e.key_ptr.*, 0) != null) return error.InvalidHelperJson;
                try strings(e.value_ptr.*);
            }
        },
        else => {},
    }
}
pub fn get(v: Value, key: []const u8) Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
pub fn str(v: Value) []const u8 {
    return if (v == .string) v.string else "";
}
pub fn list(v: Value) []const Value {
    return if (v == .array) v.array.items else &.{};
}
pub fn has(v: Value, capability: []const u8) bool {
    for (list(get(v, "capabilities"))) |c| if (std.mem.eql(u8, str(c), capability)) return true;
    return false;
}
pub fn check(v: Value) !void {
    if (get(v, "ok") != .bool or !get(v, "ok").bool) return error.HelperRejected;
    if (get(v, "protocol") != .integer or get(v, "protocol").integer != 1) return error.UnsupportedHelper;
}
pub fn snapshot(v: Value) !void {
    try check(v);
    const gen = str(get(v, "generation"));
    if (gen.len != 16 or get(v, "fields") != .array or get(v, "raw_files") != .object) return error.InvalidSnapshot;
    for (gen) |c| if (!std.ascii.isHex(c)) return error.InvalidSnapshot;
    if (list(get(v, "fields")).len > 4096) return error.InvalidSnapshot;
    for (list(get(v, "fields"))) |f| {
        for ([_][]const u8{ "id", "category", "label", "type", "file" }) |key| if (str(get(f, key)).len == 0) return error.InvalidSnapshot;
    }
}
pub fn field(v: Value, id: []const u8) ?Value {
    for (list(get(v, "fields"))) |f| if (std.mem.eql(u8, str(get(f, "id")), id)) return f;
    return null;
}
pub fn equal(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .string => std.mem.eql(u8, a.string, b.string),
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .array => blk: {
            if (a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |x, y| if (!equal(x, y)) break :blk false;
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var it = a.object.iterator();
            while (it.next()) |e| if (!equal(e.value_ptr.*, b.object.get(e.key_ptr.*) orelse break :blk false)) break :blk false;
            break :blk true;
        },
    };
}
pub fn request(a: std.mem.Allocator, base: Value, bytes: []const u8, backups: []const u8) !Value {
    var v = try parse(a, bytes, max_request);
    if (v != .object) return error.InvalidRequest;
    if (!equal(get(v, "expected_generation"), get(base, "generation"))) return error.StaleDraft;
    if (!equal(get(v, "protocol"), .{ .integer = 1 })) return error.UnsupportedHelper;
    // Never let advanced edits redirect backups or silently opt into system overrides.
    const allowed = [_][]const u8{ "protocol", "expected_generation", "changes", "raw_files", "monitor_changes", "custom_keybind_changes", "window_rule_changes", "snap_zone_changes", "snap_layouts", "default_snap_layout", "normalize_stacking", "sync_cursor", "sync_typography", "create_user_override", "collection_preconditions", "display_declaration_changes" };
    var it = v.object.iterator();
    while (it.next()) |e| {
        var found = false;
        for (allowed) |key| if (std.mem.eql(u8, key, e.key_ptr.*)) {
            found = true;
            break;
        };
        if (!found) return error.UnknownRequestField;
    }
    const raw = get(v, "raw_files");
    if (raw != .null and raw != .object) return error.InvalidRawFiles;
    for (list(get(v, "changes"))) |change| {
        const f = field(base, str(get(change, "id"))) orelse return error.UnknownField;
        if (get(raw, str(get(f, "file"))) != .null) return error.ConflictingEdits;
    }
    inline for (.{ .{ "monitor_changes", "outputs" }, .{ "custom_keybind_changes", "wm" }, .{ "window_rule_changes", "rules" }, .{ "snap_zone_changes", "layout" }, .{ "snap_layouts", "layout" } }) |pair| {
        if (get(v, pair[0]) != .null and list(get(v, pair[0])).len > 0 and get(raw, pair[1]) != .null) return error.ConflictingEdits;
    }
    try @import("aqueous_display_mutations.zig").check(base, v);
    try v.object.put(a, "backup_dir", .{ .string = backups });
    return v;
}
pub fn displayChanged(base: Value, candidate: Value) bool {
    if (!equal(get(base, "monitors"), get(candidate, "monitors"))) return true;
    for (list(get(base, "fields"))) |f| {
        if (!std.mem.eql(u8, str(get(f, "category")), "displays")) continue;
        const next = field(candidate, str(get(f, "id"))) orelse return true;
        if (!equal(get(f, "value"), get(next, "value"))) return true;
    }
    return false;
}
/// A conservative safety filter, not a TOML parser. The helper does not expose
/// every output/HDR/profile property. Raw output files, and legacy wm files
/// containing display sections, cannot be proven safe from its field snapshot.
pub fn rawDisplayRisk(base: Value, req: Value) bool {
    const raw = get(req, "raw_files");
    for ([_][]const u8{ "wm", "outputs" }) |key| {
        const proposed = get(raw, key);
        if (proposed == .null) continue;
        const original = get(get(base, "raw_files"), key);
        if (equal(proposed, original)) continue;
        if (std.mem.eql(u8, key, "outputs") or displaySections(str(original)) or displaySections(str(proposed))) return true;
    }
    return false;
}
fn displaySections(bytes: []const u8) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] != '[') continue;
        var name: [7]u8 = undefined;
        var used: usize = 0;
        for (trimmed) |c| {
            if (std.mem.indexOfScalar(u8, "[ \t\"'", c) != null) continue;
            if (used == name.len) break;
            name[used] = std.ascii.toLower(c);
            used += 1;
        }
        if (std.mem.startsWith(u8, name[0..used], "output") or std.mem.startsWith(u8, name[0..used], "display")) return true;
    }
    return false;
}
test "raw display filter covers fields absent from helper projection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try parse(a, "{\"raw_files\":{\"wm\":\"[actions]\\nterminal='foot'\",\"outputs\":\"[[output]]\\nname='DP-1'\"}}", 1024);
    try std.testing.expect(rawDisplayRisk(base, try parse(a, "{\"raw_files\":{\"outputs\":\"[[output]]\\nname='DP-1'\\nenabled=false\"}}", 1024)));
    try std.testing.expect(rawDisplayRisk(base, try parse(a, "{\"raw_files\":{\"wm\":\"[[ 'display' . profile ]]\\nname='unsafe'\"}}", 1024)));
    try std.testing.expect(!rawDisplayRisk(base, try parse(a, "{\"raw_files\":{\"wm\":\"[actions]\\nterminal='other'\"}}", 1024)));
}
/// Rebase independent edits, treating collections/raw files as indivisible units.
/// Never merge TOML text or reuse document-index IDs across changed collections.
pub fn rebase(a: std.mem.Allocator, base: Value, live: Value, bytes: []const u8) ![]u8 {
    var v = try request(a, base, bytes, "unused");
    _ = v.object.swapRemove("backup_dir");
    if (get(v, "display_declaration_changes") != .null and !equal(get(base, "generation"), get(live, "generation"))) return error.DisplayDraftRequiresFreshIdentities;
    for (list(get(v, "changes"))) |change| {
        const id = str(get(change, "id"));
        const old = field(base, id) orelse return error.UnknownField;
        const now = field(live, id) orelse return error.UnknownField;
        if (!equal(get(old, "value"), get(now, "value")) and !equal(get(change, "value"), get(now, "value"))) return error.MergeConflict;
    }
    if (get(v, "raw_files") == .object) {
        var it = get(v, "raw_files").object.iterator();
        while (it.next()) |e| {
            const old = get(get(base, "raw_files"), e.key_ptr.*);
            const now = get(get(live, "raw_files"), e.key_ptr.*);
            if (!equal(old, now) and !equal(e.value_ptr.*, now)) return error.MergeConflict;
        }
    }
    inline for (.{ .{ "monitor_changes", "monitors" }, .{ "snap_layouts", "snap_layouts" } }) |pair| {
        if (get(v, pair[0]) != .null and !equal(get(base, pair[1]), get(live, pair[1]))) return error.MergeConflict;
    }
    inline for (.{ .{ "custom_keybind_changes", "wm" }, .{ "window_rule_changes", "rules" }, .{ "snap_zone_changes", "layout" }, .{ "normalize_stacking", "layout" } }) |pair| {
        if (get(v, pair[0]) != .null and !equal(get(get(base, "raw_files"), pair[1]), get(get(live, "raw_files"), pair[1]))) return error.MergeConflict;
    }
    if (get(v, "collection_preconditions") != .null) try v.object.put(a, "collection_preconditions", get(live, "collection_preconditions"));
    try v.object.put(a, "expected_generation", get(live, "generation"));
    return std.json.Stringify.valueAlloc(a, v, .{ .whitespace = .indent_2 });
}
test "rebase merges independent fields, rejects overlap and preserves malformed drafts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try parse(a, "{\"generation\":\"123456789abcdef0\",\"fields\":[{\"id\":\"gap\",\"file\":\"layout\",\"value\":1}]}", 1024);
    const live = try parse(a, "{\"generation\":\"123456789abcdef1\",\"fields\":[{\"id\":\"gap\",\"file\":\"layout\",\"value\":1}]}", 1024);
    const draft = "{\"protocol\":1,\"expected_generation\":\"123456789abcdef0\",\"changes\":[{\"id\":\"gap\",\"value\":2}]}";
    const merged = try parse(a, try rebase(a, base, live, draft), 1024);
    try std.testing.expectEqualStrings("123456789abcdef1", str(get(merged, "expected_generation")));
    const conflict = try parse(a, "{\"generation\":\"123456789abcdef2\",\"fields\":[{\"id\":\"gap\",\"file\":\"layout\",\"value\":3}]}", 1024);
    try std.testing.expectError(error.MergeConflict, rebase(a, base, conflict, draft));
}
test "requests retain generation and reject structured/raw overlap before helper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try parse(a, "{\"generation\":\"123456789abcdef0\",\"fields\":[{\"id\":\"gap\",\"file\":\"layout\"}]}", 1024);
    try std.testing.expectError(error.StaleDraft, request(a, base, "{\"protocol\":1,\"expected_generation\":\"other\"}", "/tmp"));
    try std.testing.expectError(error.ConflictingEdits, request(a, base, "{\"protocol\":1,\"expected_generation\":\"123456789abcdef0\",\"changes\":[{\"id\":\"gap\",\"value\":2}],\"raw_files\":{\"layout\":\"raw\"}}", "/tmp"));
    const v = try request(a, base, "{\"protocol\":1,\"expected_generation\":\"123456789abcdef0\",\"changes\":[{\"id\":\"gap\",\"value\":2}]}", "/tmp/backups");
    try std.testing.expectEqualStrings("123456789abcdef0", str(get(v, "expected_generation")));
}
test "display comparison sees raw-derived monitor changes and ignores unrelated fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x = try parse(a, "{\"monitors\":[{\"scale\":1}],\"fields\":[]}", 1024);
    const y = try parse(a, "{\"monitors\":[{\"scale\":2}],\"fields\":[]}", 1024);
    try std.testing.expect(displayChanged(x, y));
    try std.testing.expect(!displayChanged(x, x));
}
