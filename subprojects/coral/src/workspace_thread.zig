//! Chronological transcript indexed by OpenCode message IDs. Pages arrive newest first.
const std = @import("std");
const api = @import("opencode.zig");
const u = @import("c.zig");
const c = u.c;
const a = u.a;
const i18n = @import("i18n");

const Message = struct {
    id: [:0]u8,
    text: [:0]u8,
    start: c_int = 0,
    fn deinit(self: Message) void {
        a.free(self.id);
        a.free(self.text);
    }
};

pub const Anchor = struct {
    id: ?[:0]u8 = null,
    offset: c_int = 0,
    pub fn copy(self: Anchor) Anchor {
        return .{ .id = if (self.id) |id| u.z(id) else null, .offset = self.offset };
    }
    pub fn deinit(self: Anchor) void {
        if (self.id) |id| a.free(id);
    }
};

pub const Thread = struct {
    view: u.W,
    scroll: u.W,
    older: u.W,
    messages: std.ArrayList(Message) = .empty,
    cursor: ?[:0]u8 = null,
    restore: Anchor = .{},
    rendered: [:0]u8,
    pub fn init(view: u.W, scroll: u.W, older: u.W) Thread {
        return .{ .view = view, .scroll = scroll, .older = older, .rendered = u.z("") };
    }
    pub fn clear(self: *Thread) void {
        for (self.messages.items) |message| message.deinit();
        self.messages.clearRetainingCapacity();
        if (self.cursor) |id| a.free(id);
        self.cursor = null;
        self.restore.deinit();
        self.restore = .{};
        a.free(self.rendered);
        self.rendered = u.z("");
        c.gtk_text_buffer_set_text(self.buffer(), "", 0);
        c.gtk_widget_set_visible(self.older, 0);
    }
    pub fn deinit(self: *Thread) void {
        for (self.messages.items) |message| message.deinit();
        self.messages.deinit(a);
        self.restore.deinit();
        if (self.cursor) |id| a.free(id);
        a.free(self.rendered);
    }
    fn buffer(self: *Thread) *c.GtkTextBuffer {
        return c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, self.view)).?;
    }
    pub fn position(self: *Thread) Anchor {
        if (self.restore.id) |id| return .{ .id = u.z(id), .offset = self.restore.offset };
        const adj = c.gtk_scrolled_window_get_vadjustment(u.cast(c.GtkScrolledWindow, self.scroll));
        if (c.gtk_adjustment_get_value(adj) + c.gtk_adjustment_get_page_size(adj) >= c.gtk_adjustment_get_upper(adj) - 2) return .{};
        const view = u.cast(c.GtkTextView, self.view);
        var rect: c.GdkRectangle = undefined;
        c.gtk_text_view_get_visible_rect(view, &rect);
        var top: c.GtkTextIter = undefined;
        _ = c.gtk_text_view_get_iter_at_location(view, &top, rect.x, rect.y);
        const offset = c.gtk_text_iter_get_offset(&top);
        var i = self.messages.items.len;
        while (i > 0) {
            i -= 1;
            const msg = self.messages.items[i];
            if (msg.start <= offset) return .{ .id = u.z(msg.id), .offset = offset - msg.start };
        }
        return .{};
    }
    pub fn page(self: *Thread, result: api.Value, older: bool) void {
        const rows = api.items(api.get(result, "data"));
        var anchor = self.position();
        defer anchor.deinit();
        var page_rows: std.ArrayList(Message) = .empty;
        defer page_rows.deinit(a);
        var i = rows.len;
        while (i > 0) {
            i -= 1;
            const row = rows[i];
            const id = api.string(row, "id");
            if (id.len == 0) continue;
            const text = formatMessage(row) orelse continue;
            page_rows.append(a, .{ .id = u.z(id), .text = text }) catch unreachable;
        }
        const before = self.messages.items.len;
        var preserve_cursor = false;
        if (older) {
            // The subsequent page is exclusive. Tolerate an overlapping boundary after a reconnect.
            if (before != 0) for (page_rows.items, 0..) |msg, idx| {
                if (std.mem.eql(u8, msg.id, self.messages.items[0].id)) {
                    for (page_rows.items[idx..]) |overlap| overlap.deinit();
                    page_rows.shrinkRetainingCapacity(idx);
                    break;
                }
            };
            self.messages.insertSlice(a, 0, page_rows.items) catch unreachable;
        } else {
            var start: usize = 0;
            if (page_rows.items.len > 0) for (self.messages.items, 0..) |msg, idx| {
                if (std.mem.eql(u8, msg.id, page_rows.items[0].id)) {
                    start = idx;
                    break;
                }
            };
            preserve_cursor = start > 0;
            for (self.messages.items[start..]) |msg| msg.deinit();
            self.messages.shrinkRetainingCapacity(start);
            self.messages.appendSlice(a, page_rows.items) catch unreachable;
        }
        if (!preserve_cursor) {
            const next = api.string(api.get(result, "cursor"), "next");
            if (self.cursor) |previous| a.free(previous);
            self.cursor = if (next.len != 0) u.z(next) else null;
        }
        c.gtk_widget_set_visible(self.older, @intFromBool(self.cursor != null));
        c.gtk_widget_set_sensitive(self.older, 1);
        var output: std.Io.Writer.Allocating = .init(a);
        defer output.deinit();
        var offset: c_int = 0;
        var target: ?c_int = null;
        for (self.messages.items) |*msg| {
            msg.start = offset;
            output.writer.writeAll(msg.text) catch unreachable;
            const chars: c_int = @intCast(c.g_utf8_strlen(msg.text.ptr, @intCast(msg.text.len)));
            if (anchor.id) |id| if (std.mem.eql(u8, id, msg.id)) {
                target = offset + @min(chars, anchor.offset);
            };
            offset += chars;
        }
        const text = output.written();
        var prefix: usize = 0;
        while (prefix < @min(self.rendered.len, text.len) and self.rendered[prefix] == text[prefix]) : (prefix += 1) {}
        if (prefix == text.len and prefix == self.rendered.len) return;
        while (prefix > 0 and prefix < text.len and text[prefix] & 0xc0 == 0x80) prefix -= 1;
        var start: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_offset(self.buffer(), &start, @intCast(c.g_utf8_strlen(self.rendered.ptr, @intCast(prefix))));
        c.gtk_text_buffer_get_end_iter(self.buffer(), &end);
        c.gtk_text_buffer_delete(self.buffer(), &start, &end);
        if (prefix < text.len) c.gtk_text_buffer_insert(self.buffer(), &start, text[prefix..].ptr, @intCast(text.len - prefix));
        a.free(self.rendered);
        self.rendered = u.z(text);
        if (target != null or self.cursor == null) {
            self.restore.deinit();
            self.restore = .{};
        }
        var iter: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_offset(self.buffer(), &iter, target orelse if (anchor.id == null) offset else 0);
        const mark = c.gtk_text_buffer_get_mark(self.buffer(), "read-position") orelse c.gtk_text_buffer_create_mark(self.buffer(), "read-position", &iter, 0).?;
        c.gtk_text_buffer_move_mark(self.buffer(), mark, &iter);
        c.gtk_text_view_scroll_to_mark(u.cast(c.GtkTextView, self.view), mark, 0, 1, 0, if (anchor.id == null) 1 else 0);
    }
};

fn formatMessage(row: api.Value) ?[:0]u8 {
    const kind = api.string(row, "type");
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    if (std.mem.eql(u8, kind, "user")) {
        text.writer.print("{s}\n{s}\n\n", .{ i18n.dtr("coral", "You"), api.string(row, "text") }) catch unreachable;
    } else if (std.mem.eql(u8, kind, "assistant")) {
        text.writer.writeAll("OpenCode\n") catch unreachable;
        for (api.items(api.get(row, "content"))) |part| {
            if (std.mem.eql(u8, api.string(part, "type"), "text")) text.writer.writeAll(api.string(part, "text")) catch unreachable;
        }
        text.writer.writeAll("\n\n") catch unreachable;
    } else return null;
    return u.z(text.written());
}
