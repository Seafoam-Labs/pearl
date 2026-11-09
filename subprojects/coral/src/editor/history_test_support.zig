const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const tx = @import("transactions.zig");
pub const Fixture = struct {
    buffer: *c.GtkTextBuffer = undefined,
    revision: u64 = 0,
    pub fn init(self: *Fixture, text: []const u8) void {
        c.gtk_source_init();
        self.buffer = u.cast(c.GtkTextBuffer, c.gtk_source_buffer_new(null).?);
        c.gtk_text_buffer_set_text(self.buffer, text.ptr, @intCast(text.len));
        c.gtk_text_buffer_set_enable_undo(self.buffer, 1);
        u.connect(self.buffer, "changed", &changed, self);
    }
    pub fn deinit(self: *Fixture) void {
        _ = c.g_signal_handlers_disconnect_matched(self.buffer, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.g_object_unref(self.buffer);
    }
    fn changed(_: ?*c.GtkTextBuffer, data: ?*anyopaque) callconv(.c) void {
        u.cast(Fixture, data.?).revision += 1;
    }
    pub fn target(self: *Fixture, id: u64) tx.Target {
        return .{ .id = id, .buffer = self.buffer, .revision = &self.revision, .expected_revision = self.revision };
    }
    pub fn expect(self: *Fixture, text: []const u8) !void {
        const actual = u.bufferText(self.buffer);
        defer u.a.free(actual);
        try std.testing.expectEqualStrings(text, actual);
    }
    pub fn insert(self: *Fixture, offset: c_int, text: []const u8) void {
        var iter: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_offset(self.buffer, &iter, offset);
        c.gtk_text_buffer_begin_user_action(self.buffer);
        c.gtk_text_buffer_insert(self.buffer, &iter, text.ptr, @intCast(text.len));
        c.gtk_text_buffer_end_user_action(self.buffer);
    }
};
pub fn r(start: usize, end: usize, text: []const u8) tx.Replacement {
    return .{ .start = start, .end = end, .text = text };
}
