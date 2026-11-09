//! Mark-backed bounded regions of canonical buffers. GTK main thread only.
//! Offsets are UTF-8 bytes, never concatenated-widget offsets. Marks include edits
//! at BOTH boundaries (left-gravity start, right-gravity end); deletion collapses
//! them naturally. Retains the buffer, never the document/revision pointer.
//! Always resolve a fresh Target before reading/mapping. Historical snapshots
//! need no Target and reject every edit with ReadOnly. Move-only; deinit required.
const std = @import("std");
const c = @import("../c.zig").c;
const tx = @import("transactions.zig");
pub const Error = tx.PrepareError || error{InvalidAnchor};
pub const Range = struct { start: usize, end: usize };
pub const Mapped = struct {
    allocator: std.mem.Allocator,
    change: tx.Change,
    pub fn deinit(self: *Mapped) void {
        self.allocator.free(self.change.replacements);
        self.* = undefined;
    }
};
pub const Excerpt = struct {
    allocator: std.mem.Allocator,
    id: u64,
    source: ?Source = null,
    historical: ?[]u8 = null,
    read_only: bool = false,
    limits: tx.Limits,
    const Source = struct {
        buffer: *c.GtkTextBuffer,
        revision_identity: usize,
        start: *c.GtkTextMark,
        end: *c.GtkTextMark,
    };
    pub fn init(a: std.mem.Allocator, target: tx.Target, range: Range, read_only: bool, limits: tx.Limits) Error!Excerpt {
        var plan = try readPlan(a, target, limits);
        defer plan.deinit();
        const bytes = plan.before(0);
        try checkRange(bytes, range);
        var start: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_offset(target.buffer, &start, @intCast(std.unicode.utf8CountCodepoints(bytes[0..range.start]) catch unreachable));
        c.gtk_text_buffer_get_iter_at_offset(target.buffer, &end, @intCast(std.unicode.utf8CountCodepoints(bytes[0..range.end]) catch unreachable));
        _ = c.g_object_ref(target.buffer);
        const start_mark = c.gtk_text_buffer_create_mark(target.buffer, null, &start, 1).?;
        const end_mark = c.gtk_text_buffer_create_mark(target.buffer, null, &end, 0).?;
        _ = c.g_object_ref(start_mark);
        _ = c.g_object_ref(end_mark);
        return .{ .allocator = a, .id = target.id, .limits = limits, .read_only = read_only, .source = .{
            .buffer = target.buffer,
            .revision_identity = @intFromPtr(target.revision),
            .start = start_mark,
            .end = end_mark,
        } };
    }
    pub fn snapshot(a: std.mem.Allocator, id: u64, bytes: []const u8, limits: tx.Limits) Error!Excerpt {
        if (bytes.len > @min(@as(usize, std.math.maxInt(c_int)), @min(limits.max_buffer_bytes, limits.max_total_bytes))) return error.LimitExceeded;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.EmbeddedNul;
        return .{ .allocator = a, .id = id, .historical = try a.dupe(u8, bytes), .read_only = true, .limits = limits };
    }
    pub fn deinit(self: *Excerpt) void {
        if (self.source) |source| {
            if (c.gtk_text_mark_get_deleted(source.start) == 0) c.gtk_text_buffer_delete_mark(source.buffer, source.start);
            if (c.gtk_text_mark_get_deleted(source.end) == 0) c.gtk_text_buffer_delete_mark(source.buffer, source.end);
            c.g_object_unref(source.start);
            c.g_object_unref(source.end);
            c.g_object_unref(source.buffer);
        }
        if (self.historical) |bytes| self.allocator.free(bytes);
        self.* = undefined;
    }
    /// Owned bounded presentation bytes, including invisible text. Objects inside
    /// the region are rejected. Reading a region does not validate unrelated text;
    /// mapping/committing edits still validates the entire canonical document.
    pub fn text(self: *const Excerpt, a: std.mem.Allocator, target: ?tx.Target) Error![]u8 {
        if (self.historical) |bytes| return a.dupe(u8, bytes);
        try self.validateRead(target);
        const source = self.source.?;
        var start: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_mark(source.buffer, &start, source.start);
        c.gtk_text_buffer_get_iter_at_mark(source.buffer, &end, source.end);
        const cap = @min(@as(usize, std.math.maxInt(c_int)), @min(self.limits.max_buffer_bytes, self.limits.max_total_bytes));
        return tx.readRange(a, source.buffer, start, end, cap);
    }
    /// Cheap freshness/policy/anchor checks, also required for cached UI reads.
    pub fn validateRead(self: *const Excerpt, target: ?tx.Target) Error!void {
        if (self.historical != null) return;
        const current = try self.checkedTarget(target);
        if (tx.isApplying() or current.busy) return error.Busy;
        if (current.expected_revision != current.revision.*) return error.StaleRevision;
        if (self.limits.max_targets == 0) return error.LimitExceeded;
        const source = self.source.?;
        if (c.gtk_text_mark_get_buffer(source.start) != source.buffer or c.gtk_text_mark_get_buffer(source.end) != source.buffer) return error.InvalidAnchor;
        var start: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_mark(source.buffer, &start, source.start);
        c.gtk_text_buffer_get_iter_at_mark(source.buffer, &end, source.end);
        if (c.gtk_text_iter_compare(&start, &end) > 0) return error.InvalidAnchor;
    }
    /// Produces an owned range array with BORROWED replacement text. Feed change
    /// to history.prepare/perform or transactions.prepare synchronously, then free.
    pub fn map(self: *const Excerpt, a: std.mem.Allocator, target: ?tx.Target, replacements: []const tx.Replacement) Error!Mapped {
        if (self.read_only or self.historical != null) return error.ReadOnly;
        const current = try self.checkedTarget(target);
        if (!current.writable) return error.ReadOnly;
        var plan = try readPlan(a, current, self.limits);
        defer plan.deinit();
        const range = try self.region(plan.before(0));
        const bytes = plan.before(0)[range.start..range.end];
        if (replacements.len > self.limits.max_replacements) return error.LimitExceeded;
        const mapped = try a.alloc(tx.Replacement, replacements.len);
        errdefer a.free(mapped);
        for (replacements, mapped) |r, *out| {
            try checkRange(bytes, .{ .start = r.start, .end = r.end });
            out.* = .{ .start = range.start + r.start, .end = range.start + r.end, .text = r.text };
        }
        return .{ .allocator = a, .change = .{ .target = current, .replacements = mapped } };
    }
    pub fn prepare(self: *const Excerpt, a: std.mem.Allocator, target: ?tx.Target, replacements: []const tx.Replacement) Error!tx.Prepared {
        var mapped = try self.map(a, target, replacements);
        defer mapped.deinit();
        return tx.prepare(a, &.{mapped.change}, self.limits);
    }
    pub fn replace(self: *const Excerpt, a: std.mem.Allocator, target: ?tx.Target, replacement: tx.Replacement) Error!void {
        var plan = try self.prepare(a, target, &.{replacement});
        defer plan.deinit();
        try plan.commit(&.{target.?});
    }
    fn checkedTarget(self: *const Excerpt, target: ?tx.Target) Error!tx.Target {
        const current = target orelse return error.TargetMismatch;
        const source = self.source orelse return error.ReadOnly;
        if (current.id != self.id or current.buffer != source.buffer or @intFromPtr(current.revision) != source.revision_identity) return error.TargetMismatch;
        return current;
    }
    fn region(self: *const Excerpt, bytes: []const u8) Error!Range {
        const source = self.source.?;
        if (c.gtk_text_mark_get_buffer(source.start) != source.buffer or c.gtk_text_mark_get_buffer(source.end) != source.buffer) return error.InvalidAnchor;
        var start: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_mark(source.buffer, &start, source.start);
        c.gtk_text_buffer_get_iter_at_mark(source.buffer, &end, source.end);
        const a = c.gtk_text_iter_get_offset(&start);
        const b = c.gtk_text_iter_get_offset(&end);
        if (a > b) return error.InvalidAnchor;
        return .{ .start = byteAtChar(bytes, @intCast(a)), .end = byteAtChar(bytes, @intCast(b)) };
    }
};
fn readPlan(a: std.mem.Allocator, target: tx.Target, limits: tx.Limits) Error!tx.Prepared {
    var readable = target;
    // Snapshotting is not an edit; preserve busy/revision checks, allow read-only.
    readable.writable = true;
    return tx.prepare(a, &.{.{ .target = readable, .replacements = &.{} }}, limits);
}
fn checkRange(text: []const u8, range: Range) Error!void {
    if (range.start > range.end or range.end > text.len) return error.OutOfBounds;
    for ([_]usize{ range.start, range.end }) |n| if (n < text.len and text[n] & 0xc0 == 0x80) return error.InvalidBoundary;
}
pub fn byteAtChar(text: []const u8, count: usize) usize {
    var n: usize = 0;
    var offset: usize = 0;
    while (n < count and offset < text.len) : (n += 1) offset += std.unicode.utf8ByteSequenceLength(text[offset]) catch unreachable;
    return offset;
}
/// Ordered project-diff foundation: each item retains its own document identity
/// and bounded text. There is deliberately NO concatenated editable offset space.
pub const Item = struct { id: u64, text: []u8, read_only: bool };
pub fn orderedText(a: std.mem.Allocator, excerpts: []const *const Excerpt, targets: []const tx.Target) Error![]Item {
    const items = try a.alloc(Item, excerpts.len);
    var initialized: usize = 0;
    errdefer freeOrderedText(a, items, initialized);
    for (excerpts, items) |excerpt, *item| {
        var target: ?tx.Target = null;
        for (targets) |candidate| if (candidate.id == excerpt.id) {
            target = candidate;
            break;
        };
        item.* = .{ .id = excerpt.id, .text = try excerpt.text(a, target), .read_only = excerpt.read_only or (if (target) |t| !t.writable else true) };
        initialized += 1;
    }
    return items;
}
/// Pass items.len on success; partial count is used only by allocation cleanup.
pub fn freeOrderedText(a: std.mem.Allocator, items: []Item, count: usize) void {
    for (items[0..count]) |item| a.free(item.text);
    a.free(items);
}

test {
    _ = @import("excerpt_tests.zig");
}
