//! C ABI: callbacks borrow textures; watches must be detached before their UI dies.
const std = @import("std");
const gio = @import("gio2");
const gdk = @import("gdk4");
const glib = @import("glib2");
const scheduler = @import("platform/thumbnails.zig");
pub const Watch = struct {
    listener: scheduler.Listener,
    entry: ?*scheduler.Entry = null,
    callback: *const fn (?*gdk.Texture, ?[*:0]const u8, ?*anyopaque) callconv(.c) void,
    data: ?*anyopaque,
    idle: c_uint = 0,
    fn ready(context: *anyopaque, entry: *scheduler.Entry) void {
        const self: *Watch = @ptrCast(@alignCast(context));
        self.callback(entry.texture, if (entry.caption) |s| s.ptr else null, self.data);
    }
    fn cached(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Watch = @ptrCast(@alignCast(data.?));
        self.idle = 0;
        if (self.entry) |entry| ready(self, entry);
        return 0;
    }
};
var helper: ?[:0]u8 = null;
pub export fn pearl_preview_set_helper(path: [*:0]const u8) void {
    // Paths are chosen by the host, never by the portal request.
    if (helper != null) return;
    helper = std.heap.c_allocator.dupeSentinel(u8, std.mem.span(path), 0) catch return;
    scheduler.helper_executable = helper.?.ptr;
}
pub export fn pearl_preview_watch(info: *gio.FileInfo, edge: u32, callback: @FieldType(Watch, "callback"), data: ?*anyopaque) ?*Watch {
    const self = std.heap.c_allocator.create(Watch) catch return null;
    self.* = .{ .listener = .{ .data = self, .ready = Watch.ready }, .callback = callback, .data = data };
    self.entry = scheduler.request(info, @min(1024, @max(128, edge)), 64 * 1024 * 1024, false, 1, &self.listener);
    if (self.entry == null) {
        std.heap.c_allocator.destroy(self);
        return null;
    }
    if (self.entry.?.state == .ready) self.idle = glib.idleAdd(Watch.cached, self);
    return self;
}
pub export fn pearl_preview_unwatch(self: ?*Watch) void {
    const w = self orelse return;
    if (w.idle != 0) _ = glib.Source.remove(w.idle);
    if (w.entry) |entry| scheduler.detach(entry, &w.listener);
    std.heap.c_allocator.destroy(w);
}
