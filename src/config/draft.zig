//! One retained Pearl draft. Invalid UTF-8/oversize text is rejected; invalid
//! preferences JSON is deliberately retained for the Advanced editor.
const std = @import("std");
const model = @import("preferences.zig");
pub const Draft = struct {
    text: ?[]u8 = null,
    base: ?[]u8 = null,
    revision: u64 = 0,
    base_revision: u64 = 0,

    pub fn deinit(self: *Draft, a: std.mem.Allocator) void {
        if (self.text) |s| a.free(s);
        if (self.base) |s| a.free(s);
        self.text = null;
        self.base = null;
    }
    pub fn check(self: Draft, expected: u64) !void {
        if (self.revision != expected) return error.StaleDraft;
    }
    pub fn keep(self: *Draft, a: std.mem.Allocator, text: []const u8, expected: u64, base_revision: u64, current_revision: u64, current: []const u8) !u64 {
        try self.check(expected);
        if (text.len > model.max_bytes) return error.DocumentTooLarge;
        if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidText;
        if (base_revision != (if (self.text != null) self.base_revision else current_revision)) return error.Conflict;
        if (self.text) |old| if (std.mem.eql(u8, old, text)) return self.revision;
        if (self.revision == std.math.maxInt(u64)) return error.ResourceLimit;
        const copy = try a.dupe(u8, text);
        errdefer a.free(copy);
        const base = if (self.base == null) try a.dupe(u8, current) else self.base.?;
        if (self.text) |old| a.free(old);
        self.text = copy;
        self.base = base;
        self.base_revision = base_revision;
        self.revision += 1;
        return self.revision;
    }
    pub fn discard(self: *Draft, a: std.mem.Allocator, expected: u64) !void {
        try self.check(expected);
        if (self.text == null) return;
        if (self.revision == std.math.maxInt(u64)) return error.ResourceLimit;
        self.deinit(a);
        self.revision += 1;
    }
    pub fn merge(self: *Draft, a: std.mem.Allocator, expected: u64, current_revision: u64, current: []const u8) !void {
        try self.check(expected);
        if (self.revision == std.math.maxInt(u64)) return error.ResourceLimit;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const merged = try @import("merge.zig").json(arena.allocator(), self.base orelse return error.NoDraft, self.text orelse return error.NoDraft, current);
        const next = try a.dupe(u8, merged);
        errdefer a.free(next);
        const base = try a.dupe(u8, current);
        self.deinit(a);
        self.text = next;
        self.base = base;
        self.base_revision = current_revision;
        self.revision += 1;
    }
};

test "draft CAS preserves invalid text and rejects stale overwrite/discard" {
    const a = std.testing.allocator;
    var d: Draft = .{};
    defer d.deinit(a);
    try std.testing.expectEqual(1, try d.keep(a, "{broken", 0, 4, 4, "{}"));
    try std.testing.expectError(error.StaleDraft, d.keep(a, "{}", 0, 4, 4, "{}"));
    try std.testing.expectError(error.StaleDraft, d.discard(a, 0));
    try std.testing.expectEqual(2, try d.keep(a, "", 1, 4, 5, "{}"));
    try std.testing.expectEqualStrings("", d.text.?);
    try std.testing.expectEqual(4, d.base_revision);
    try d.discard(a, 2);
    try std.testing.expectEqual(3, d.revision);
    try std.testing.expectError(error.Conflict, d.keep(a, "{}", 3, 4, 5, "{}"));
}

fn allocationCase(a: std.mem.Allocator) !void {
    var d: Draft = .{};
    defer d.deinit(a);
    _ = d.keep(a, "{broken", 0, 0, 0, "{}") catch |err| {
        try std.testing.expect(d.text == null and d.base == null and d.revision == 0);
        return err;
    };
    _ = d.keep(a, "{\"font_size\":16}", 1, 0, 0, "{}") catch |err| {
        try std.testing.expectEqualStrings("{broken", d.text.?);
        try std.testing.expectEqual(1, d.revision);
        return err;
    };
    d.merge(a, 2, 1, "{\"density\":\"compact\"}") catch |err| {
        try std.testing.expectEqualStrings("{\"font_size\":16}", d.text.?);
        try std.testing.expectEqualStrings("{}", d.base.?);
        try std.testing.expectEqual(2, d.revision);
        return err;
    };
    try std.testing.expectEqual(3, d.revision);
}
test "draft retention and merge are atomic at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
