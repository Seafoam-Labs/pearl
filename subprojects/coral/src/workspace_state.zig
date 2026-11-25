//! Private, atomic per-session drafts. A change to one session never rewrites another session's state.
const std = @import("std");
const u = @import("c.zig");
const c = u.c;
const a = u.a;
const api = @import("opencode.zig");
pub const Anchor = struct { document: u64 = 0, revision: u64 = 0, start: usize = 0, end: usize = 0 };
pub const Draft = struct {
    anchor: Anchor = .{},
    read: @import("workspace_thread.zig").Anchor = .{},
    text: [:0]u8,
    operation: ?[:0]u8 = null,
    selection: ?[:0]u8,
    tag: ?[:0]u8,
    pub fn deinit(self: Draft) void {
        self.read.deinit();
        a.free(self.text);
        if (self.operation) |s| a.free(s);
        if (self.selection) |s| a.free(s);
        if (self.tag) |s| a.free(s);
    }
};
fn path(root: []const u8, id: []const u8) ![:0]u8 {
    const dir = u.fmt("{s}/coral-workspace/sessions", .{std.mem.span(c.g_get_user_state_dir())});
    defer a.free(dir);
    if (c.g_mkdir_with_parents(dir, 0o700) != 0) return error.StateDirectory;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(root);
    hash.update("\x00");
    hash.update(id);
    return u.fmt("{s}/{s}.json", .{ dir, std.fmt.bytesToHex(hash.finalResult(), .lower) });
}
pub fn write(root: []const u8, id: []const u8, value: anytype) !void {
    const name = try path(root, id);
    defer a.free(name);
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(bytes);
    if (c.g_file_set_contents_full(name, bytes.ptr, @intCast(bytes.len), c.G_FILE_SET_CONTENTS_CONSISTENT | c.G_FILE_SET_CONTENTS_DURABLE, 0o600, null) == 0) return error.StateWrite;
}
pub fn read(root: []const u8, id: []const u8) ?std.json.Parsed(api.Value) {
    const name = path(root, id) catch return null;
    defer a.free(name);
    var raw: [*c]u8 = null;
    var size: usize = 0;
    if (c.g_file_get_contents(name, &raw, &size, null) == 0) return null;
    defer c.g_free(raw);
    return std.json.parseFromSlice(api.Value, a, raw[0..size], .{ .allocate = .alloc_always }) catch null;
}
pub fn loadDraft(root: []const u8, id: []const u8) ?Draft {
    const parsed = read(root, id) orelse return null;
    defer parsed.deinit();
    const value = parsed.value;
    const info = api.get(value, "anchor");
    var anchor: Anchor = .{};
    inline for (.{ "document", "revision", "start", "end" }) |field| {
        const number = api.get(info, field);
        if (number == .integer and number.integer >= 0) @field(anchor, field) = @intCast(number.integer);
    }
    const position = api.get(value, "read");
    const offset = api.get(position, "offset");
    const message = api.string(position, "id");
    return .{ .read = .{ .id = if (message.len > 0) u.z(message) else null, .offset = if (offset == .integer) std.math.cast(c_int, @max(0, offset.integer)) orelse 0 else 0 }, .anchor = anchor, .operation = if (api.get(value, "operation") == .string) u.z(api.string(value, "operation")) else null, .text = u.z(api.string(value, "text")), .selection = if (api.get(value, "selection") == .string) u.z(api.string(value, "selection")) else null, .tag = if (api.get(value, "tag") == .string) u.z(api.string(value, "tag")) else null };
}
pub fn lastSession(root: []const u8) ?[:0]u8 {
    const parsed = read(root, "") orelse return null;
    defer parsed.deinit();
    const id = api.string(parsed.value, "session");
    return if (id.len > 0) u.z(id) else null;
}
