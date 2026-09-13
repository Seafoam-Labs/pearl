//! One monitored, immutable app catalog shared by every launcher/output.
const std = @import("std");
const gio = @import("gio2");
const unix = @import("giounix2");
const glib = @import("glib2");
const object = @import("gobject2");
const a = std.heap.c_allocator;
pub const Entry = struct {
    info: *gio.AppInfo,
    id: [:0]const u8,
    key: [:0]const u8,
    action: ?[:0]const u8,
    name: [:0]const u8,
    detail: [:0]const u8,
    folded: [:0]const u8,
    keywords: [:0]const u8,
};
pub const Catalog = struct {
    refs: std.atomic.Value(usize) = .init(1),
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    truncated: bool = false,
    pub fn retain(self: *Catalog) *Catalog {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }
    pub fn release(self: *Catalog) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        for (self.entries.items) |entry| entry.info.as(object.Object).unref();
        self.arena.deinit();
        a.destroy(self);
    }
    fn add(self: *Catalog, info: *gio.AppInfo, action: ?[*:0]const u8, name: [*:0]const u8) !void {
        const alloc = self.arena.allocator();
        const id = info.getId() orelse return;
        const title = std.mem.span(name);
        if (title.len > 4096 or std.mem.span(id).len > 1024 or !std.unicode.utf8ValidateSlice(title)) return;
        const detail = if (action != null) info.getDisplayName() else info.getDescription() orelse @import("text.zig").tr("Application", "Anwendung").ptr;
        const description = std.mem.span(detail);
        if (description.len > 4096 or !std.unicode.utf8ValidateSlice(description)) return;
        const desktop = object.ext.cast(unix.DesktopAppInfo, info).?;
        var keywords: std.ArrayList(u8) = .empty;
        try keywords.appendSlice(alloc, std.mem.span(id));
        try keywords.appendSlice(alloc, " ");
        try keywords.appendSlice(alloc, description);
        if (desktop.getKeywords()) |raw_words| {
            const words: [*:null]const ?[*:0]const u8 = @ptrCast(raw_words);
            var n: usize = 0;
            while (words[n]) |word| : (n += 1) {
                if (n >= 32 or std.mem.span(word).len > 256) break;
                try keywords.appendSlice(alloc, " ");
                try keywords.appendSlice(alloc, std.mem.span(word));
            }
        }
        const entry: Entry = .{ .info = info, .key = try std.fmt.allocPrintSentinel(alloc, "{d}:{s}{s}", .{ std.mem.span(id).len, std.mem.span(id), if (action) |v| std.mem.span(v) else "" }, 0), .id = try alloc.dupeZ(u8, std.mem.span(id)), .action = if (action) |v| try alloc.dupeZ(u8, std.mem.span(v)) else null, .name = try alloc.dupeZ(u8, title), .detail = try alloc.dupeZ(u8, description), .folded = try fold(alloc, title), .keywords = try fold(alloc, keywords.items) };
        try self.entries.append(alloc, entry);
        _ = info.as(object.Object).ref();
    }
};
pub fn fold(alloc: std.mem.Allocator, value: []const u8) ![:0]u8 {
    const text = glib.utf8Casefold(@ptrCast(value.ptr), @intCast(value.len));
    defer glib.free(text);
    return alloc.dupeZ(u8, std.mem.span(text));
}
pub const Index = struct {
    app: *gio.Application,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    recent: std.ArrayList([]u8) = .empty,
    monitor: ?*gio.AppInfoMonitor = null,
    signal: c_ulong = 0,
    catalog: ?*Catalog = null,
    pending: bool = false,
    searches: usize = 0,
    search_waiter: bool = false,
    dirty: bool = false,
    stopping: bool = false,
    failed: bool = false,
    generation: u64 = 0,
    debounce: c_uint = 0,
    cancel: ?*gio.Cancellable = null,
    pub fn remember(self: *Index, id: []const u8) void {
        const copy = a.dupe(u8, id) catch return;
        for (self.recent.items, 0..) |old, i| if (std.mem.eql(u8, old, id)) {
            a.free(self.recent.orderedRemove(i));
            break;
        };
        if (self.recent.items.len == 32) a.free(self.recent.pop().?);
        self.recent.insert(a, 0, copy) catch a.free(copy);
    }
    pub fn start(self: *Index) void {
        self.monitor = gio.AppInfoMonitor.get();
        self.signal = gio.AppInfoMonitor.signals.changed.connect(self.monitor.?, *Index, monitorChanged, self, .{});
        self.refresh();
    }
    pub fn stop(self: *Index) void {
        if (self.stopping) return;
        self.stopping = true;
        if (self.debounce != 0) _ = glib.Source.remove(self.debounce);
        if (self.monitor) |m| {
            object.signalHandlerDisconnect(m.as(object.Object), self.signal);
            m.unref();
        }
        if (self.cancel) |c| c.cancel();
        if (self.catalog) |c| c.release();
        self.catalog = null;
        for (self.recent.items) |id| a.free(id);
        self.recent.deinit(a);
        self.recent = .empty;
        // Pending GTasks hold the application until the callback has drained.
    }
    fn monitorChanged(_: *gio.AppInfoMonitor, self: *Index) callconv(.c) void {
        if (!self.stopping and self.debounce == 0) self.debounce = glib.timeoutAdd(200, refreshLater, self);
    }
    fn refreshLater(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Index = @ptrCast(@alignCast(data.?));
        self.debounce = 0;
        self.refresh();
        return 0;
    }
    fn refresh(self: *Index) void {
        if (self.pending) {
            self.dirty = true;
            return;
        }
        self.pending = true;
        self.cancel = gio.Cancellable.new();
        self.app.hold();
        const task = gio.Task.new(null, self.cancel, completed, self);
        task.setCheckCancellable(0);
        _ = task.setReturnOnCancel(0);
        task.runInThread(scan);
        task.unref();
    }
    fn scan(task: *gio.Task, _: ?*object.Object, _: ?*anyopaque, cancel: ?*gio.Cancellable) callconv(.c) void {
        const result = collect(cancel.?) catch null;
        task.returnPointer(result, null);
    }
    fn collect(cancel: *gio.Cancellable) !*Catalog {
        const result = try a.create(Catalog);
        result.* = .{ .arena = std.heap.ArenaAllocator.init(a) };
        errdefer result.release();
        // GIR marks this list non-null, but the C API returns NULL for no apps.
        const get: *const fn () callconv(.c) ?*glib.List = @ptrCast(&gio.AppInfo.getAll);
        const all = get();
        defer if (all) |head| {
            var it: ?*glib.List = head;
            while (it) |node| : (it = node.f_next) {
                const info: *gio.AppInfo = @ptrCast(@alignCast(node.f_data.?));
                info.as(object.Object).unref();
            }
            head.free();
        };
        var it = all;
        while (it) |node| : (it = node.f_next) {
            if (cancel.isCancelled() != 0) return error.Canceled;
            if (result.entries.items.len >= 4096) {
                result.truncated = true;
                break;
            }
            const info: *gio.AppInfo = @ptrCast(@alignCast(node.f_data.?));
            if (info.shouldShow() == 0) continue;
            const desktop = object.ext.cast(unix.DesktopAppInfo, info) orelse continue;
            try result.add(info, null, info.getDisplayName());
            const actions: [*:null]const ?[*:0]const u8 = @ptrCast(desktop.listActions());
            var i: usize = 0;
            while (actions[i]) |action| : (i += 1) {
                if (i >= 16 or result.entries.items.len >= 4096) {
                    result.truncated = true;
                    break;
                }
                const name = desktop.getActionName(action);
                defer glib.free(name);
                try result.add(info, action, name);
            }
        }
        return result;
    }
    fn completed(_: ?*object.Object, reply: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Index = @ptrCast(@alignCast(data.?));
        const result: ?*Catalog = @ptrCast(@alignCast(object.ext.cast(gio.Task, reply).?.propagatePointer(null)));
        self.pending = false;
        self.cancel.?.unref();
        self.cancel = null;
        if (self.stopping) {
            if (result) |c| c.release();
        } else {
            self.failed = result == null;
            if (result) |c| {
                if (self.catalog) |old| old.release();
                self.catalog = c;
                self.generation += 1;
                std.log.info("event=app-index-ready entries={d} truncated={}", .{ c.entries.items.len, c.truncated });
            }
            self.changed(self.context);
            if (self.dirty) {
                self.dirty = false;
                self.refresh();
            }
        }
        self.app.release();
    }
};
