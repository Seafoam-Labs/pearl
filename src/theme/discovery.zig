//! Event-driven theme catalogs. One bounded worker, one pending scan, no idle
//! polling and no activation side effects. GTK/GIO watches stay on the main loop.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const catalog = @import("catalog.zig");
const c = @import("package.zig").c;
const a = std.heap.c_allocator;
const Watch = struct { path: [:0]u8, monitor: *gio.FileMonitor, signal: c_ulong };
pub const Discovery = struct {
    app: ?*gio.Application = null,
    context: ?*anyopaque = null,
    changed: ?*const fn (*anyopaque) void = null,
    watches: std.ArrayList(Watch) = .empty,
    roots_arena: std.heap.ArenaAllocator = .init(a),
    roots: []const [:0]const u8 = &.{},
    active: bool = false,
    job: ?*Job = null,
    requested: u64 = 0,
    generation: u64 = 0,
    fingerprint: [64]u8 = @splat(0),
    degraded: bool = false,
    watch_degraded: bool = false,
    debounce: c_uint = 0,
    maximum: c_uint = 0,
    rebuild_required: bool = false,
    pub fn start(self: *Discovery, app: *gio.Application, context: *anyopaque, changed: *const fn (*anyopaque) void) !void {
        self.app = app;
        self.context = context;
        self.changed = changed;
        self.roots = try allRoots(self.roots_arena.allocator());
        self.active = true;
        for (self.roots) |root| self.watch(root, true);
        self.request();
    }
    pub fn stop(self: *Discovery) void {
        self.active = false;
        self.timers();
        self.clear();
        self.watches.deinit(a);
        self.watches = .empty;
        self.roots_arena.deinit();
        self.roots = &.{};
        // Job owns its scan roots and application hold until its completion.
    }
    fn timers(self: *Discovery) void {
        if (self.debounce != 0) _ = glib.Source.remove(self.debounce);
        if (self.maximum != 0) _ = glib.Source.remove(self.maximum);
        self.debounce = 0;
        self.maximum = 0;
    }
    fn clear(self: *Discovery) void {
        for (self.watches.items) |watch_| {
            object.signalHandlerDisconnect(watch_.monitor.as(object.Object), watch_.signal);
            _ = watch_.monitor.cancel();
            watch_.monitor.unref();
            a.free(watch_.path);
        }
        self.watches.clearRetainingCapacity();
    }
    pub fn request(self: *Discovery) void {
        if (!self.active) return;
        self.rebuild_required = true;
        self.requested +|= 1;
        if (self.debounce != 0) _ = glib.Source.remove(self.debounce);
        self.debounce = glib.timeoutAdd(200, elapsed, self);
        if (self.maximum == 0) self.maximum = glib.timeoutAdd(1000, maximumElapsed, self);
    }
    fn elapsed(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Discovery = @ptrCast(@alignCast(data.?));
        self.debounce = 0;
        self.launch();
        return 0;
    }
    fn maximumElapsed(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Discovery = @ptrCast(@alignCast(data.?));
        self.maximum = 0;
        self.launch();
        return 0;
    }
    fn launch(self: *Discovery) void {
        self.timers();
        if (!self.active or self.job != null) return;
        const job = a.create(Job) catch {
            self.degraded = true;
            self.changed.?(self.context.?);
            return;
        };
        job.* = .{ .owner = self, .serial = self.requested };
        self.job = job;
        self.app.?.hold();
        const task = gio.Task.new(null, null, done, job);
        task.setTaskData(job, null);
        task.runInThread(work);
        task.unref();
    }
    fn watch(self: *Discovery, path: []const u8, ancestor: bool) void {
        for (self.watches.items) |old| if (std.mem.eql(u8, old.path, path)) return;
        if (self.watches.items.len >= 4096) {
            self.degraded = true;
            return;
        }
        const z = a.dupeZ(u8, path) catch return;
        const file = gio.File.newForPath(z);
        defer file.unref();
        if (file.queryFileType(.{ .nofollow_symlinks = true }, null) != .directory) {
            a.free(z);
            if (ancestor) if (std.fs.path.dirname(path)) |parent| {
                if (!std.mem.eql(u8, path, parent)) self.watch(parent, true);
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
    fn relevant(self: *Discovery, file: *gio.File) bool {
        const path = file.getPath() orelse return true;
        defer glib.free(path);
        const value = std.mem.span(path);
        for (self.roots) |root| {
            if (below(root, value)) return true;
            if (below(value, root)) {
                const relative = value[@min(value.len, root.len + 1)..];
                // Installer staging/rollback folders are hidden and unpublished.
                return relative.len == 0 or relative[0] != '.';
            }
        }
        return false;
    }
    fn event(_: *gio.FileMonitor, file: *gio.File, other: ?*gio.File, _: gio.FileMonitorEvent, self: *Discovery) callconv(.c) void {
        if (self.relevant(file) or (if (other) |f| self.relevant(f) else false)) self.request();
    }
};
fn below(path: []const u8, root: []const u8) bool {
    return std.mem.eql(u8, path, root) or (std.mem.startsWith(u8, path, root) and path.len > root.len and (root.len == 1 or path[root.len] == '/'));
}
fn allRoots(alloc: std.mem.Allocator) ![]const [:0]const u8 {
    var roots: std.ArrayList([:0]const u8) = .empty;
    try roots.appendSlice(alloc, try catalog.roots(alloc));
    try roots.appendSlice(alloc, try @import("theme_provider.zig").roots(alloc));
    return roots.items;
}
const Job = struct {
    owner: *Discovery,
    serial: u64,
    arena: std.heap.ArenaAllocator = .init(a),
    dirs: std.ArrayList([:0]const u8) = .empty,
    fingerprint: [64]u8 = @splat(0),
    degraded: bool = false,
    entries: usize = 0,
};
fn walk(job: *Job, fd: c_int, path: []const u8, depth: usize) anyerror!void {
    if (depth > 9 or job.dirs.items.len >= 4096 or job.entries >= 32768) {
        job.degraded = true;
        return;
    }
    const alloc = job.arena.allocator();
    try job.dirs.append(alloc, try alloc.dupeZ(u8, path));
    const copy = c.openat(fd, ".", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (copy < 0) return error.ThemeDirectory;
    const dir = c.fdopendir(copy) orelse {
        _ = c.close(copy);
        return error.ThemeDirectory;
    };
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or (depth == 0 and name[0] == '.')) continue;
        job.entries += 1;
        if (job.entries > 32768) {
            job.degraded = true;
            return;
        }
        const child = c.openat(fd, @as([*c]const u8, @ptrCast(&entry.*.d_name)), c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (child < 0) continue;
        defer _ = c.close(child);
        try walk(job, child, try std.fmt.allocPrint(alloc, "{s}/{s}", .{ path, name }), depth + 1);
    }
}
fn scan(job: *Job) !void {
    const alloc = job.arena.allocator();
    for (try allRoots(alloc)) |root| {
        const fd = c.open(root, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (fd < 0) continue;
        defer _ = c.close(fd);
        try walk(job, fd, root, 0);
    }
    const result = try catalog.scan(alloc);
    // Invalid-only changes must notify too. Sort for stable filesystem ordering.
    const diagnostics = try alloc.dupe(catalog.Diagnostic, result.diagnostics);
    std.mem.sort(catalog.Diagnostic, diagnostics, {}, struct {
        fn less(_: void, x: catalog.Diagnostic, y: catalog.Diagnostic) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.less);
    const profiles = try @import("theme_provider.zig").catalog(alloc, result);
    job.fingerprint = @import("package_model.zig").hash(try std.json.Stringify.valueAlloc(alloc, .{ .revision = result.revision, .profiles = profiles.revision, .diagnostics = diagnostics }, .{}));
}
fn work(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data.?));
    scan(job) catch |err| {
        job.degraded = true;
        job.fingerprint = @import("package_model.zig").hash(@errorName(err));
    };
    task.returnBoolean(1);
}
fn done(_: ?*object.Object, _: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data.?));
    const self = job.owner;
    self.job = null;
    if (self.active) {
        const old_degraded = self.degraded;
        if (self.rebuild_required) {
            self.degraded = false;
            self.clear();
            for (self.roots) |root| {
                self.watch(root, true);
                if (std.fs.path.dirname(root)) |parent| self.watch(parent, true);
            }
            for (job.dirs.items) |path| self.watch(path, false);
            self.watch_degraded = self.degraded;
            // One verification scan closes the gap while watches were rebuilt.
            // It keeps the new watches, so verification creates no further gap.
            self.rebuild_required = false;
            self.requested +|= 1;
        }
        self.degraded = job.degraded or self.watch_degraded;
        if (job.serial == self.requested) {
            if (!std.mem.eql(u8, &self.fingerprint, &job.fingerprint) or old_degraded != self.degraded) {
                self.fingerprint = job.fingerprint;
                self.generation +|= 1;
                self.changed.?(self.context.?);
            }
        } else self.launch();
    }
    self.app.?.release();
    job.arena.deinit();
    a.destroy(job);
}
test "local discovery detects missing roots, nested edits and removal without idle rescans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const root = try alloc.dupeZ(u8, "/tmp/pearl-theme-watch-XXXXXX");
    const native = struct {
        extern fn mkdtemp([*:0]u8) ?[*:0]u8;
    };
    try std.testing.expect(native.mkdtemp(root) != null);
    defer @import("install.zig").removeTree(alloc, root) catch {};
    const data_root = try std.fmt.allocPrintSentinel(alloc, "{s}/data", .{root}, 0);
    _ = glib.setenv("XDG_DATA_HOME", data_root, 1);
    _ = glib.setenv("XDG_DATA_DIRS", try std.fmt.allocPrintSentinel(alloc, "{s}/system", .{root}, 0), 1);
    const app = gio.Application.new("org.aqueous.Pearl.DiscoveryTest", .{ .non_unique = true });
    defer app.unref();
    var events: usize = 0;
    const callbacks = struct {
        fn changed(context: *anyopaque) void {
            const n: *usize = @ptrCast(@alignCast(context));
            n.* += 1;
        }
        fn wait(discovery: *Discovery, previous: u64) !void {
            const until = glib.getMonotonicTime() + 5_000_000;
            while (discovery.generation == previous and glib.getMonotonicTime() < until) {
                while (glib.MainContext.default().iteration(0) != 0) {}
                glib.usleep(10000);
            }
            try std.testing.expect(discovery.generation > previous);
        }
    };
    var discovery: Discovery = .{};
    try discovery.start(app, &events, callbacks.changed);
    defer {
        discovery.stop();
        while (discovery.job != null) _ = glib.MainContext.default().iteration(1);
    }
    try callbacks.wait(&discovery, 0);
    const io = @import("../config/io.zig");
    const package_root = try std.fmt.allocPrintSentinel(alloc, "{s}/pearl/themes/original", .{data_root}, 0);
    try io.mkdir(try std.fmt.allocPrintSentinel(alloc, "{s}/css", .{package_root}, 0));
    try io.atomic(try std.fmt.allocPrintSentinel(alloc, "{s}/theme.json", .{package_root}, 0), "{\"schema_version\":1,\"id\":\"original.watch\",\"name\":\"Watch\",\"author\":\"Pearl\",\"license\":\"CC0-1.0\",\"source\":\"https://example.org/watch\",\"asset_version\":\"1.0.0\",\"requires\":{\"style_api\":1},\"style\":{\"css\":\"css/style.css\"}}", true);
    const css = try std.fmt.allocPrintSentinel(alloc, "{s}/css/style.css", .{package_root}, 0);
    try io.atomic(css, "button{border-radius:4px}", true);
    try callbacks.wait(&discovery, discovery.generation);
    try io.atomic(css, "button{border-radius:8px}", false);
    try callbacks.wait(&discovery, discovery.generation);
    const previous = discovery.generation;
    const until = glib.getMonotonicTime() + 400_000;
    while (glib.getMonotonicTime() < until) {
        while (glib.MainContext.default().iteration(0) != 0) {}
        glib.usleep(10000);
    }
    try std.testing.expectEqual(previous, discovery.generation);
    try std.testing.expect(discovery.debounce == 0 and discovery.maximum == 0 and discovery.job == null);
    try @import("install.zig").removeTree(alloc, package_root);
    try callbacks.wait(&discovery, previous);
}
