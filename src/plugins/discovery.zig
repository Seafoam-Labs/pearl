//! Bounded GIO watches. The supervisor serializes and throttles scan requests.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const a = std.heap.c_allocator;
const Watch = struct { path: [:0]u8, monitor: *gio.FileMonitor, signal: c_ulong };
pub const Discovery = struct {
    context: *anyopaque,
    request: *const fn (*anyopaque) void,
    watches: std.ArrayList(Watch) = .empty,
    degraded: bool = false,
    roots: []const [:0]const u8 = &.{},
    fallback: c_uint = 0,
    pub fn deinit(self: *Discovery) void {
        self.clear();
        self.watches.deinit(a);
        if (self.fallback != 0) _ = glib.Source.remove(self.fallback);
    }
    fn clear(self: *Discovery) void {
        for (self.watches.items) |item| {
            object.signalHandlerDisconnect(item.monitor.as(object.Object), item.signal);
            _ = item.monitor.cancel();
            item.monitor.unref();
            a.free(item.path);
        }
        self.watches.clearRetainingCapacity();
    }
    fn related(self: *Discovery, file: *gio.File) bool {
        const path = file.getPath() orelse return true;
        defer glib.free(path);
        const value = std.mem.span(path);
        for (self.roots) |root| {
            if (below(value, root) or below(root, value)) return true;
        }
        return false;
    }
    fn below(path: []const u8, parent: []const u8) bool {
        return std.mem.eql(u8, path, parent) or (std.mem.startsWith(u8, path, parent) and path.len > parent.len and path[parent.len] == '/');
    }
    fn event(_: *gio.FileMonitor, file: *gio.File, other: ?*gio.File, _: gio.FileMonitorEvent, self: *Discovery) callconv(.c) void {
        if (self.related(file) or (if (other) |value| self.related(value) else false)) self.request(self.context);
    }
    fn poll(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Discovery = @ptrCast(@alignCast(data.?));
        self.request(self.context);
        return 1;
    }
    fn watch(self: *Discovery, path: []const u8, ancestor: bool) void {
        for (self.watches.items) |item| if (std.mem.eql(u8, item.path, path)) return;
        if (self.watches.items.len >= 520) {
            self.degraded = true;
            return;
        }
        const z = a.dupeZ(u8, path) catch {
            self.degraded = true;
            return;
        };
        const file = gio.File.newForPath(z);
        defer file.unref();
        if (file.queryFileType(.{ .nofollow_symlinks = true }, null) != .directory) {
            a.free(z);
            if (ancestor) if (std.fs.path.dirname(path)) |parent| {
                self.watch(parent, true);
                return;
            };
            self.degraded = true;
            return;
        }
        const monitor = file.monitorDirectory(.{ .watch_moves = true }, null, null) orelse {
            a.free(z);
            self.degraded = true;
            return;
        };
        const signal = gio.FileMonitor.signals.changed.connect(monitor, *Discovery, event, self, .{});
        self.watches.append(a, .{ .path = z, .monitor = monitor, .signal = signal }) catch {
            object.signalHandlerDisconnect(monitor.as(object.Object), signal);
            _ = monitor.cancel();
            monitor.unref();
            a.free(z);
            self.degraded = true;
        };
    }
    pub fn rebuild(self: *Discovery, roots: []const [:0]const u8, dirs: []const [:0]u8, incomplete: bool) void {
        self.clear();
        self.roots = roots;
        self.degraded = incomplete;
        if (@import("build_options").test_hooks and glib.getenv("PEARL_TEST_PLUGIN_NO_MONITORS") != null) {
            self.degraded = true;
        } else {
            for (roots) |root| {
                self.watch(root, true);
                if (std.fs.path.dirname(root)) |parent| self.watch(parent, true);
            }
            for (dirs) |path| self.watch(path, false);
        }
        if (self.degraded and self.fallback == 0) self.fallback = glib.timeoutAddSeconds(30, poll, self);
        if (!self.degraded and self.fallback != 0) {
            _ = glib.Source.remove(self.fallback);
            self.fallback = 0;
        }
    }
};
