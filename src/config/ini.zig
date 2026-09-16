//! Small lossless INI editor for qtct/KConfig appearance keys.
const std = @import("std");
pub const Key = struct { group: []const u8, key: []const u8, value: ?[]const u8 };
fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn equal(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return eq(a.?, b.?);
}
pub fn get(bytes: []const u8, group: []const u8, key: []const u8) !?[]const u8 {
    var current: []const u8 = "";
    var found: ?[]const u8 = null;
    var seen_group = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = trim(raw);
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            if (line[line.len - 1] != ']') return error.InvalidIni;
            current = line[1 .. line.len - 1];
            if (std.mem.startsWith(u8, current, group) and current.len > group.len and current[group.len] == ']') return error.UnsupportedIniFlags;
            if (eq(current, group)) {
                if (seen_group) return error.AmbiguousIni;
                seen_group = true;
            }
            continue;
        }
        if (!eq(current, group)) continue;
        const split = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidIni;
        const name = trim(line[0..split]);
        if (std.mem.startsWith(u8, name, key) and name.len > key.len and name[key.len] == '[') return error.UnsupportedIniFlags;
        if (!eq(name, key)) continue;
        if (found != null) return error.AmbiguousIni;
        const value = trim(line[split + 1 ..]);
        if (std.mem.endsWith(u8, value, "\\")) return error.UnsupportedIniContinuation;
        found = value;
    }
    return found;
}
pub fn patch(a: std.mem.Allocator, bytes: []const u8, field: Key) ![]const u8 {
    const old = try get(bytes, field.group, field.key);
    if (equal(old, field.value)) return a.dupe(u8, bytes);
    if (field.value) |v| if (std.mem.indexOfAny(u8, v, "\n\r\x00") != null) return error.InvalidIniValue;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var current: []const u8 = "";
    var inserted = false;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = if (std.mem.indexOfScalarPos(u8, bytes, offset, '\n')) |i| i + 1 else bytes.len;
        const raw = bytes[offset..end];
        const line = trim(std.mem.trimEnd(u8, raw, "\n"));
        if (line.len > 0 and line[0] == '[') {
            if (eq(current, field.group) and !inserted and field.value != null) {
                try append(a, &out, field);
                inserted = true;
            }
            current = line[1 .. line.len - 1];
        }
        const split = std.mem.indexOfScalar(u8, line, '=');
        if (eq(current, field.group) and split != null and eq(trim(line[0..split.?]), field.key)) {
            if (field.value != null) try append(a, &out, field);
            inserted = true;
        } else try out.appendSlice(a, raw);
        offset = end;
    }
    if (!inserted and field.value != null) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
        if (!eq(current, field.group)) {
            try out.appendSlice(a, "[");
            try out.appendSlice(a, field.group);
            try out.appendSlice(a, "]\n");
        }
        try append(a, &out, field);
    }
    return out.toOwnedSlice(a);
}
fn append(a: std.mem.Allocator, out: *std.ArrayList(u8), field: Key) !void {
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
    try out.appendSlice(a, field.key);
    try out.append(a, '=');
    try out.appendSlice(a, field.value.?);
    try out.append(a, '\n');
}
test "INI preserves unrelated text, restores missing keys and rejects ambiguous keys" {
    const a = std.testing.allocator;
    const original = "# user comment\n[Appearance]\nstyle=Old\ncustom=keep\n[Other]\nx=1\n";
    const updated = try patch(a, original, .{ .group = "Appearance", .key = "style", .value = "Darkly" });
    defer a.free(updated);
    try std.testing.expectEqualStrings("Darkly", (try get(updated, "Appearance", "style")).?);
    const restored = try patch(a, updated, .{ .group = "Appearance", .key = "style", .value = "Old" });
    defer a.free(restored);
    try std.testing.expectEqualStrings(original, restored);
    const extra = try patch(a, updated, .{ .group = "Appearance", .key = "palette", .value = "file" });
    defer a.free(extra);
    const removed = try patch(a, extra, .{ .group = "Appearance", .key = "palette", .value = null });
    defer a.free(removed);
    try std.testing.expectEqualStrings(updated, removed);
    try std.testing.expectError(error.AmbiguousIni, get("[A]\nx=1\nx=2\n", "A", "x"));
    try std.testing.expectError(error.UnsupportedIniFlags, get("[A]\nx[$i]=1\n", "A", "x"));
    try std.testing.expectError(error.UnsupportedIniFlags, get("[A][$i]\nx=1\n", "A", "x"));
}
