//! OpenCode stores a step as ordered content blocks. Text deltas stay transient
//! until the corresponding block ends and is committed to message history.
const std = @import("std");
const api = @import("opencode.zig");
const u = @import("c.zig");
const i18n = @import("i18n");
const a = u.a;
const Value = api.Value;
const eql = std.mem.eql;

pub const Live = struct {
    message: ?[:0]u8 = null,
    parts: std.ArrayList(Part) = .empty,

    const Part = struct { ordinal: i64, reasoning: bool, text: std.ArrayList(u8) = .empty };

    pub fn clear(self: *Live) void {
        if (self.message) |id| a.free(id);
        for (self.parts.items) |*p| p.text.deinit(a);
        self.parts.deinit(a);
        self.* = .{};
    }

    pub fn receive(self: *Live, event: []const u8, data: Value) void {
        const reasoning = std.mem.startsWith(u8, event, "session.reasoning.");
        if (!reasoning and !std.mem.startsWith(u8, event, "session.text.")) return;
        const id = api.string(data, "assistantMessageID");
        const ordinal = api.get(data, "ordinal");
        if (id.len == 0 or ordinal != .integer or ordinal.integer < 0) return;
        const delta = std.mem.endsWith(u8, event, ".delta");
        const ended = std.mem.endsWith(u8, event, ".ended");
        if (!delta and !ended and !std.mem.endsWith(u8, event, ".started")) return;
        if (self.message == null or !eql(u8, self.message.?, id)) {
            self.clear();
            self.message = u.z(id);
        }
        const part = for (self.parts.items) |*part| {
            if (part.ordinal == ordinal.integer and part.reasoning == reasoning) break part;
        } else blk: {
            const part = self.parts.addOne(a) catch unreachable;
            part.* = .{ .ordinal = ordinal.integer, .reasoning = reasoning };
            break :blk part;
        };
        if (!delta) part.text.clearRetainingCapacity();
        const chunk = api.string(data, if (delta) "delta" else "text");
        if (part.text.items.len + chunk.len <= 2 * 1024 * 1024) part.text.appendSlice(a, chunk) catch unreachable;
    }

    fn text(self: *const Live, id: []const u8, ordinal: usize, reasoning: bool, stored: []const u8) []const u8 {
        if (self.message) |current| if (eql(u8, current, id)) {
            for (self.parts.items) |part| {
                if (part.ordinal == ordinal and part.reasoning == reasoning and part.text.items.len > stored.len and std.mem.startsWith(u8, part.text.items, stored)) return part.text.items;
            }
        };
        return stored;
    }
};

fn block(out: *std.Io.Writer.Allocating, title: []const u8, body: []const u8) void {
    if (out.written().len > 0) out.writer.writeAll("\n\n") catch unreachable;
    out.writer.writeAll(title) catch unreachable;
    if (body.len != 0) out.writer.print("\n{s}", .{body}) catch unreachable;
}

fn preview(writer: *std.Io.Writer, value: []const u8) void {
    var end: usize = @min(value.len, 1024);
    while (end < value.len and value[end] & 0xc0 == 0x80) end -= 1;
    var lines: usize = 0;
    for (value[0..end], 0..) |ch, i| {
        if (ch == '\n') lines += 1;
        if (lines == 6) {
            end = i;
            break;
        }
    }
    writer.writeAll(value[0..end]) catch unreachable;
    if (end < value.len) writer.writeAll("…") catch unreachable;
}

fn tool(out: *std.Io.Writer.Allocating, part: Value) void {
    const state = api.get(part, "state");
    const status = api.string(state, "status");
    const label = if (eql(u8, status, "streaming")) i18n.dtr("coral", "Preparing tool") else if (eql(u8, status, "running")) i18n.dtr("coral", "Running tool") else if (eql(u8, status, "completed")) i18n.dtr("coral", "Tool completed") else if (eql(u8, status, "error")) i18n.dtr("coral", "Tool failed") else i18n.dtr("coral", "Tool");
    block(out, label, "");
    out.writer.print(" · {s}", .{api.string(part, "name")}) catch unreachable;
    const input = api.get(state, "input");
    const subject = for ([_][]const u8{ "command", "path", "filePath", "pattern", "query", "url", "description" }) |key| {
        const value = api.string(input, key);
        if (value.len != 0) break value;
    } else if (input == .string) input.string else "";
    if (subject.len != 0) {
        out.writer.writeByte('\n') catch unreachable;
        preview(&out.writer, subject);
    }
    const err = api.string(api.get(state, "error"), "message");
    if (err.len > 0) {
        out.writer.writeByte('\n') catch unreachable;
        preview(&out.writer, err);
    }
    for (api.items(api.get(state, "content"))) |item| {
        const value = api.string(item, "text");
        if (value.len > 0) {
            out.writer.writeByte('\n') catch unreachable;
            preview(&out.writer, value);
            break;
        }
    }
}

pub fn format(row: Value, live: *Live) [:0]u8 {
    const kind = api.string(row, "type");
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    if (eql(u8, kind, "user")) {
        block(&out, i18n.dtr("coral", "You"), api.string(row, "text"));
    } else if (eql(u8, kind, "assistant")) {
        const id = api.string(row, "id");
        if (live.message) |current| {
            if (eql(u8, current, id) and api.string(row, "finish").len != 0) live.clear();
        }
        for (api.items(api.get(row, "content")), 0..) |part, ordinal| {
            const t = api.string(part, "type");
            const reasoning = eql(u8, t, "reasoning");
            if (reasoning or eql(u8, t, "text")) {
                const text = live.text(id, ordinal, reasoning, api.string(part, "text"));
                if (std.mem.trim(u8, text, " \n\r\t").len > 0) block(&out, if (reasoning) i18n.dtr("coral", "Thinking") else "OpenCode", text);
            } else if (eql(u8, t, "tool")) tool(&out, part);
        }
        const err = api.string(api.get(row, "error"), "message");
        if (err.len != 0) block(&out, i18n.dtr("coral", "Response failed"), err);
    }
    if (out.written().len > 0) out.writer.writeAll("\n\n") catch unreachable;
    return u.z(out.written());
}
