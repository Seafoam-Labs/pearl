//! Directory monitors for semantic freshness. GFileMonitor on folder roots
//! plus walk-discovered subdirectories (capped); events mark paths dirty for
//! the idle scheduler instead of indexing immediately. Monitor failures and
//! cap overflow degrade to the periodic idle rescan, reported in status.
//! All monitor lifecycle happens on the main thread; workers only queue paths.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const indexer = @import("indexer.zig");
const a = std.heap.c_allocator;
pub const cap = 256;
const Entry = struct { dir: [:0]const u8, monitor: *gio.FileMonitor, signal: c_ulong };
pub const Watch = struct {
    entries: std.ArrayList(Entry) = .empty,
    degraded: bool = false,
    index_dir: []const u8 = "",
    context: *anyopaque,
    mark: *const fn (*anyopaque, []const u8) void,
    promote: *const fn (*anyopaque) void,

    pub fn init(context: *anyopaque, mark: *const fn (*anyopaque, []const u8) void, promote: *const fn (*anyopaque) void) Watch {
        return .{ .context = context, .mark = mark, .promote = promote };
    }
    pub fn deinit(self: *Watch) void {
        for (self.entries.items) |entry| remove(entry);
        self.entries.deinit(a);
    }
    fn remove(entry: Entry) void {
        object.signalHandlerDisconnect(entry.monitor.as(object.Object), entry.signal);
        _ = entry.monitor.cancel();
        entry.monitor.unref();
        a.free(entry.dir);
    }
    pub fn syncRoots(self: *Watch, folders: []const []const u8, index_dir: []const u8) void {
        self.index_dir = index_dir;
        // Drop monitors no longer under any configured root.
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            var keep = false;
            for (folders) |folder_raw| {
                const folder = std.mem.trimEnd(u8, folder_raw, "/");
                const root = if (folder.len == 0) "/" else folder;
                if (std.mem.eql(u8, entry.dir, root) or (std.mem.startsWith(u8, entry.dir, root) and entry.dir.len > root.len and entry.dir[root.len] == '/')) {
                    keep = true;
                    break;
                }
            }
            if (keep) i += 1 else {
                remove(entry);
                _ = self.entries.orderedRemove(i);
            }
        }
        for (folders) |folder_raw| {
            const folder = std.mem.trimEnd(u8, folder_raw, "/");
            self.addDir(if (folder.len == 0) "/" else folder);
        }
    }
    pub fn addDir(self: *Watch, path: []const u8) void {
        if (path.len == 0) return;
        if (self.index_dir.len > 0 and (std.mem.eql(u8, path, self.index_dir) or std.mem.startsWith(u8, path, self.index_dir))) return;
        const name = std.fs.path.basename(path);
        if (name.len == 0 or name[0] == '.') return;
        for (indexer.exclude_dirs) |ex| if (std.mem.eql(u8, name, ex)) return;
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.dir, path)) return;
        if (self.entries.items.len >= cap) {
            self.degraded = true;
            return;
        }
        const dir_z = a.dupeSentinel(u8, path, 0) catch return;
        const file = gio.File.newForPath(dir_z);
        defer file.unref();
        var err: ?*glib.Error = null;
        defer if (err) |e| e.free();
        const monitor = file.monitorDirectory(.{}, null, &err) orelse {
            a.free(dir_z);
            self.degraded = true;
            return;
        };
        const signal = gio.FileMonitor.signals.changed.connect(monitor, *Watch, changed, self, .{});
        self.entries.append(a, .{ .dir = dir_z, .monitor = monitor, .signal = signal }) catch {
            object.signalHandlerDisconnect(monitor.as(object.Object), signal);
            _ = monitor.cancel();
            monitor.unref();
            a.free(dir_z);
        };
    }
    fn changed(_: *gio.FileMonitor, file: *gio.File, other: ?*gio.File, event: gio.FileMonitorEvent, self: *Watch) callconv(.c) void {
        switch (event) {
            .pre_unmount, .unmounted => {
                self.promote(self.context);
                return;
            },
            .changed, .changes_done_hint, .created, .deleted, .attribute_changed, .moved, .renamed, .moved_in, .moved_out => {},
            else => return,
        }
        if (file.getPath()) |path| {
            defer glib.free(path);
            self.mark(self.context, std.mem.span(path));
        }
        if (other) |moved| if (moved.getPath()) |path| {
            defer glib.free(path);
            self.mark(self.context, std.mem.span(path));
        };
    }
};
