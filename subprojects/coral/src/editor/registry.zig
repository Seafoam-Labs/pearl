const std = @import("std");
const Document = @import("../document.zig").Document;
const u = @import("../c.zig");

// GTK-thread-only identity source, shared by registries so a new window cannot
// accidentally reuse a closed document's ID in a delayed edit/service response.
var next_id: u64 = 1;

pub const DocumentRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(*Document) = .empty,

    pub fn init(allocator: std.mem.Allocator) DocumentRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DocumentRegistry) void {
        for (self.entries.items) |document| document.destroy();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn create(self: *DocumentRegistry, context: ?*anyopaque) !*Document {
        if (next_id == std.math.maxInt(u64)) return error.IdentityExhausted;
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const document = try Document.create(next_id, context);
        next_id += 1;
        self.entries.appendAssumeCapacity(document);
        return document;
    }

    pub fn get(self: *const DocumentRegistry, id: u64) ?*Document {
        for (self.entries.items) |document| if (document.id == id) return document;
        return null;
    }

    /// Paths must already be canonical. The document remains the path owner so
    /// Save As and failed loads cannot leave a separate path index out of sync.
    pub fn findPath(self: *const DocumentRegistry, path: []const u8) ?*Document {
        for (self.entries.items) |document| {
            if (document.path) |existing| if (std.mem.eql(u8, existing, path)) return document;
        }
        return null;
    }

    /// Caller detaches all editor views and completes/cancels document I/O first.
    pub fn remove(self: *DocumentRegistry, id: u64) bool {
        for (self.entries.items, 0..) |document, index| {
            if (document.id != id) continue;
            std.debug.assert(!document.busy);
            _ = self.entries.orderedRemove(index);
            document.destroy();
            return true;
        }
        return false;
    }
};

test "registry owns canonical documents and never recycles IDs across windows" {
    var registry = DocumentRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const first = try registry.create(null);
    const id = first.id;
    first.path = u.z("/example/main.zig");
    try std.testing.expect(registry.get(id) == first);
    try std.testing.expect(registry.findPath("/example/main.zig") == first);
    try std.testing.expect(registry.findPath("/other/main.zig") == null);
    try std.testing.expect(registry.remove(id));
    try std.testing.expect(registry.get(id) == null);
    try std.testing.expect(!registry.remove(id));
    var other = DocumentRegistry.init(std.testing.allocator);
    defer other.deinit();
    const second = try other.create(null);
    try std.testing.expect(second.id > id);
    try std.testing.expect(registry.get(second.id) == null);
}

test "document revisions advance before observers, including undo and redo" {
    const c = u.c;
    var registry = DocumentRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const document = try registry.create(null);
    const initial = document.revision;
    c.gtk_text_buffer_begin_user_action(document.buffer);
    c.gtk_text_buffer_insert_at_cursor(document.buffer, "hello", 5);
    c.gtk_text_buffer_end_user_action(document.buffer);
    try std.testing.expect(document.revision > initial);
    const edited = document.revision;
    c.gtk_text_buffer_undo(document.buffer);
    try std.testing.expect(document.revision > edited);
    const undone = document.revision;
    c.gtk_text_buffer_redo(document.buffer);
    try std.testing.expect(document.revision > undone);
}

test "stale save cannot authorize clean close after undo reaches the previous disk checkpoint" {
    const c = u.c;
    const document = try Document.create(90001, null);
    defer document.destroy();
    c.gtk_text_buffer_set_text(document.buffer, "A", -1);
    document.recordSavedRevision(document.revision);
    c.gtk_text_buffer_begin_user_action(document.buffer);
    c.gtk_text_buffer_insert_at_cursor(document.buffer, "B", 1);
    c.gtk_text_buffer_end_user_action(document.buffer);
    const saving = document.revision;
    c.gtk_text_buffer_undo(document.buffer);
    try std.testing.expect(!document.dirty());
    document.recordSavedRevision(saving);
    try std.testing.expect(document.dirty());
    c.gtk_text_buffer_redo(document.buffer);
    c.gtk_text_buffer_undo(document.buffer);
    // Even a later GTK clean notification cannot restore the old disk baseline.
    c.gtk_text_buffer_set_modified(document.buffer, 0);
    try std.testing.expect(document.dirty());
    document.recordSavedRevision(document.revision);
    try std.testing.expect(!document.dirty());
}

const history = @import("history.zig");
const tx = @import("transactions.zig");
const r = @import("history_test_support.zig").r;

fn target(document: *Document) tx.Target {
    return .{ .id = document.id, .buffer = document.buffer, .revision = &document.revision, .expected_revision = document.revision };
}
fn typeSuffix(document: *Document, text: []const u8) void {
    var end: u.c.GtkTextIter = undefined;
    u.c.gtk_text_buffer_get_end_iter(document.buffer, &end);
    u.c.gtk_text_buffer_begin_user_action(document.buffer);
    u.c.gtk_text_buffer_insert(document.buffer, &end, text.ptr, @intCast(text.len));
    u.c.gtk_text_buffer_end_user_action(document.buffer);
}
fn expectText(document: *Document, text: []const u8) !void {
    const actual = u.bufferText(document.buffer);
    defer u.a.free(actual);
    try std.testing.expectEqualStrings(text, actual);
}

test "older typing epoch cannot authorize clean after a later epoch save" {
    const t = std.testing;
    var registry = DocumentRegistry.init(t.allocator);
    defer registry.deinit();
    const a = try registry.create(null);
    const b = try registry.create(null);
    for ([_]*Document{ a, b }) |d| {
        u.c.gtk_text_buffer_set_text(d.buffer, "base", -1);
        d.recordSavedRevision(d.revision);
    }
    var log = history.History.init(t.allocator, .{});
    defer log.deinit();
    try log.perform("X", &.{
        .{ .target = target(a), .replacements = &.{r(4, 4, "X")} },
        .{ .target = target(b), .replacements = &.{r(4, 4, "X")} },
    });
    typeSuffix(a, "y");
    a.recordSavedRevision(a.revision);
    try log.perform("Q", &.{
        .{ .target = target(a), .replacements = &.{r(6, 6, "Q")} },
        .{ .target = target(b), .replacements = &.{r(5, 5, "Q")} },
    });
    a.recordSavedRevision(a.revision);
    try t.expect(!a.dirty());
    try log.undo(&.{ target(a), target(b) });
    try expectText(a, "baseXy");
    const other_revision = b.revision;
    const other_dirty = b.dirty();
    typeSuffix(a, "z");
    try t.expect(try log.replayNative(target(a), false));
    // GTK can coalesce y/z in the restored interval. Neither resulting position
    // is the latest disk checkpoint, baseXyQ.
    try expectText(a, "baseX");
    try t.expect(a.dirty());
    try t.expect(try log.replayNative(target(a), true));
    try expectText(a, "baseXyz");
    try t.expect(a.dirty());
    try expectText(b, "baseX");
    try t.expectEqual(other_revision, b.revision);
    try t.expectEqual(other_dirty, b.dirty());
}

test "guarded redo save undo and redo back to current disk checkpoint" {
    const t = std.testing;
    const d = try Document.create(90002, null);
    defer d.destroy();
    var log = history.History.init(t.allocator, .{});
    defer log.deinit();
    try log.perform("baseline", &.{.{ .target = target(d), .replacements = &.{r(0, 0, "X")} }});
    typeSuffix(d, "y");
    try t.expect(try log.replayNative(target(d), false));
    try t.expect(try log.replayNative(target(d), true));
    d.recordSavedRevision(d.revision);
    try t.expect(!d.dirty());
    try t.expect(try log.replayNative(target(d), false));
    try expectText(d, "X");
    try t.expect(d.dirty());
    try t.expect(try log.replayNative(target(d), true));
    try expectText(d, "Xy");
    try t.expect(!d.dirty());
}

test "stale save completing after guarded undo invalidates private clean identity" {
    const t = std.testing;
    const d = try Document.create(90003, null);
    defer d.destroy();
    var log = history.History.init(t.allocator, .{});
    defer log.deinit();
    try log.perform("baseline", &.{.{ .target = target(d), .replacements = &.{r(0, 0, "X")} }});
    d.recordSavedRevision(d.revision);
    typeSuffix(d, "y");
    const saving = d.revision;
    try t.expect(try log.replayNative(target(d), false));
    try t.expect(!d.dirty());
    d.recordSavedRevision(saving);
    try t.expect(d.saved_checkpoint_stale);
    try t.expect(try log.replayNative(target(d), true));
    try t.expect(try log.replayNative(target(d), false));
    try expectText(d, "X");
    try t.expect(d.dirty());
    // Verify the native guard itself rejects the obsolete marker, independently
    // of Document's additional stale-save close protection.
    try t.expect(u.c.gtk_text_buffer_get_modified(d.buffer) != 0);
    d.recordSavedRevision(d.revision);
    try t.expect(!d.saved_checkpoint_stale and !d.dirty());
    try t.expect(try log.replayNative(target(d), true));
    try t.expect(d.dirty());
    try t.expect(try log.replayNative(target(d), false));
    try t.expect(!d.dirty());
}

test "first guarded baseline imports a prior save but never imports dirty as clean" {
    const t = std.testing;
    for ([_]bool{ false, true }) |saved| {
        const d = try Document.create(90004, null);
        defer d.destroy();
        u.c.gtk_text_buffer_set_text(d.buffer, "base", -1);
        if (saved) d.recordSavedRevision(d.revision);
        var log = history.History.init(t.allocator, .{});
        defer log.deinit();
        try log.perform("boundary", &.{.{ .target = target(d), .replacements = &.{r(4, 4, "X")} }});
        try log.undo(&.{target(d)});
        typeSuffix(d, "y");
        try t.expect(try log.replayNative(target(d), false));
        try expectText(d, "base");
        try t.expectEqual(!saved, d.dirty());
    }
}

test "guarded load establishes a new clean baseline only with explicit save notification" {
    const t = std.testing;
    for ([_]bool{ false, true }) |notify| {
        const d = try Document.create(90005, null);
        defer d.destroy();
        var log = history.History.init(t.allocator, .{});
        defer log.deinit();
        try log.perform("boundary", &.{.{ .target = target(d), .replacements = &.{r(0, 0, "X")} }});
        u.c.gtk_text_buffer_begin_irreversible_action(d.buffer);
        u.c.gtk_text_buffer_set_text(d.buffer, "reload", -1);
        u.c.gtk_text_buffer_end_irreversible_action(d.buffer);
        if (notify) d.recordSavedRevision(d.revision) else u.c.gtk_text_buffer_set_modified(d.buffer, 0);
        typeSuffix(d, "y");
        try t.expect(try log.replayNative(target(d), false));
        try expectText(d, "reload");
        try t.expectEqual(!notify, d.dirty());
        try t.expectError(error.GroupedBoundary, log.replayNative(target(d), false));
    }
}

test "retained buffer does not retain callbacks to a closed document" {
    const c = u.c;
    var registry = DocumentRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const document = try registry.create(null);
    const buffer = document.buffer;
    _ = c.g_object_ref(buffer);
    defer c.g_object_unref(buffer);
    try std.testing.expect(registry.remove(document.id));
    c.gtk_text_buffer_set_text(buffer, "still owned by a pending preview", -1);
    const text = u.bufferText(buffer);
    defer u.a.free(text);
    try std.testing.expectEqualStrings("still owned by a pending preview", text);
}
