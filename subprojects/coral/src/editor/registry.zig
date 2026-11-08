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
