//! Event-only directory watch: rename-over saves must survive inode replacement.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const a = std.heap.c_allocator;

pub const Watch = struct {
    monitor: ?*gio.FileMonitor = null,
    path: ?[:0]u8 = null,
    directory: ?[:0]u8 = null,
    context: ?*anyopaque = null,
    changed: ?*const fn (*anyopaque, bool) void = null,

    pub fn stop(self: *Watch) void {
        if (self.monitor) |m| {
            _ = m.cancel();
            m.unref();
        }
        if (self.path) |v| a.free(v);
        if (self.directory) |v| a.free(v);
        self.monitor = null;
        self.path = null;
        self.directory = null;
    }

    pub fn bind(self: *Watch, path: []const u8) !void {
        if (self.path) |old| if (std.mem.eql(u8, old, path) and self.monitor != null and self.monitor.?.isCancelled() == 0) return;
        self.stop();
        if (path.len == 0) return;
        self.path = try a.dupeZ(u8, path);
        errdefer self.stop();
        self.directory = try a.dupeZ(u8, std.fs.path.dirname(path) orelse return error.InvalidImage);
        const file = gio.File.newForPath(self.directory.?);
        defer file.unref();
        self.monitor = file.monitorDirectory(.{ .watch_moves = true }, null, null) orelse return error.WallpaperMonitorUnavailable;
        self.monitor.?.setRateLimit(50);
        _ = gio.FileMonitor.signals.changed.connect(self.monitor.?, *Watch, event, self, .{});
    }

    fn matches(file: *gio.File, path: []const u8) bool {
        const name = file.getPath() orelse return false;
        defer glib.free(name);
        return std.mem.eql(u8, std.mem.span(name), path);
    }
    fn event(_: *gio.FileMonitor, file: *gio.File, other: ?*gio.File, kind: gio.FileMonitorEvent, self: *Watch) callconv(.c) void {
        const path = self.path orelse return;
        const invalid = (kind == .deleted or kind == .moved_out or kind == .unmounted) and matches(file, self.directory.?);
        if (invalid or matches(file, path) or (if (other) |next| matches(next, path) else false)) {
            if (self.changed) |callback| callback(self.context.?, invalid);
        }
    }
};
