//! Pure discovery decisions, independent of GTK, disk access and helper state.
const std = @import("std");
pub const Identity = struct { id: []const u8, path: []const u8, digest: []const u8 };
pub const Change = enum { add, unchanged, replace, remove, unavailable };
pub fn change(old: ?Identity, next: ?Identity, valid: bool) Change {
    if (!valid) return .unavailable;
    const candidate = next orelse return if (old != null) .remove else .unchanged;
    const previous = old orelse return .add;
    return if (std.mem.eql(u8, previous.id, candidate.id) and std.mem.eql(u8, previous.path, candidate.path) and std.mem.eql(u8, previous.digest, candidate.digest)) .unchanged else .replace;
}
/// Input is sorted by ID, then ascending root priority, then path.
pub fn conflict(same_root_count: usize) ?[]const u8 {
    return if (same_root_count > 1) "PluginIdConflict" else null;
}
test "discovery preserves unchanged identity and requires replacement for assets or source changes" {
    const t = std.testing;
    const old: Identity = .{ .id = "cat", .path = "/user/cat", .digest = "approved" };
    try t.expectEqual(Change.add, change(null, old, true));
    try t.expectEqual(Change.unchanged, change(old, old, true));
    try t.expectEqual(Change.remove, change(old, null, true));
    try t.expectEqual(Change.unavailable, change(old, old, false));
    var next = old;
    next.digest = "asset-update";
    try t.expectEqual(Change.replace, change(old, next, true));
    next = old;
    next.path = "/system/cat";
    try t.expectEqual(Change.replace, change(old, next, true));
    next = old;
    next.id = "renamed";
    try t.expectEqual(Change.replace, change(old, next, true));
    try t.expectEqualStrings("PluginIdConflict", conflict(2).?);
    try t.expect(conflict(1) == null);
}

pub fn priority(left_root: usize, left_path: []const u8, right_root: usize, right_path: []const u8) bool {
    return if (left_root != right_root) left_root < right_root else std.mem.lessThan(u8, left_path, right_path);
}
test "user priority and same-root lexical ordering are independent of enumeration and version" {
    const t = std.testing;
    try t.expect(priority(0, "/user/z", 1, "/system/a"));
    try t.expect(!priority(1, "/system/a", 0, "/user/z"));
    try t.expect(priority(0, "/user/a", 0, "/user/z"));
    try t.expect(!priority(0, "/user/z", 0, "/user/a"));
}
