const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const unix = @import("giounix2");
const policy = @import("model.zig");
const persistence = @import("state.zig");
const io = @import("../../config/io.zig");
const a = std.heap.c_allocator;
pub const attrs = "standard::name,standard::display-name,standard::type,standard::icon,standard::is-hidden,standard::is-symlink,etag::value,id::file";
pub const Item = struct { uri: [:0]const u8, path: [:0]const u8, name: [:0]const u8, info: *gio.FileInfo, launcher: bool, digest: ?[64]u8 = null, command: [:0]const u8 = "", launch_name: [:0]const u8 = "" };
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Item) = .empty,
    path: ?[:0]const u8 = null,
    message: [:0]const u8 = "",
    missing: bool = false,
    state: ?persistence.State = null,
    pub fn destroy(self: *Snapshot) void {
        for (self.items.items) |item| item.info.unref();
        if (self.state) |*s| s.deinit();
        self.arena.deinit();
        a.destroy(self);
    }
};
pub const Store = struct {
    app: *gio.Application,
    refs: usize = 1,
    stopped: bool = false,
    enabled: bool = false,
    snapshot: ?*Snapshot = null,
    state: persistence.State,
    state_loaded: bool = false,
    state_dir: [:0]u8,
    config: [:0]u8,
    home: [:0]u8,
    context: ?*anyopaque = null,
    changed: ?*const fn (*anyopaque) void = null,
    monitors: [3]?*gio.FileMonitor = @splat(null),
    cancel: ?*gio.Cancellable = null,
    pending: bool = false,
    dirty: bool = false,
    generation: u64 = 0,
    debounce: c_uint = 0,
    poll: c_uint = 0,
    save_timer: c_uint = 0,
    saving: bool = false,
    save_again: bool = false,
    save_error: bool = false,
    pub fn create(app: *gio.Application) !*Store {
        const self = try a.create(Store);
        self.* = .{ .app = app, .state = .init(a), .state_dir = try std.fmt.allocPrintSentinel(a, "{s}/pearl", .{std.mem.span(glib.getUserStateDir())}, 0), .config = try std.fmt.allocPrintSentinel(a, "{s}/user-dirs.dirs", .{std.mem.span(glib.getUserConfigDir())}, 0), .home = try a.dupeSentinel(u8, std.mem.span(glib.getHomeDir()), 0) };
        return self;
    }
    fn retain(self: *Store) void {
        self.refs += 1;
    }
    fn release(self: *Store) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        if (self.snapshot) |s| s.destroy();
        self.state.deinit();
        a.free(self.state_dir);
        a.free(self.config);
        a.free(self.home);
        a.destroy(self);
    }
    pub fn destroy(self: *Store) void {
        self.stopped = true;
        self.context = null;
        self.changed = null;
        self.enable(false);
        if (self.save_timer != 0) {
            _ = glib.Source.remove(self.save_timer);
            self.save_timer = 0;
            self.save();
        }
        self.release();
    }
    pub fn enable(self: *Store, enabled: bool) void {
        if (self.enabled == enabled) return;
        self.enabled = enabled;
        if (enabled) {
            self.watch(0, std.fs.path.dirname(self.config).?);
            self.poll = glib.timeoutAddSeconds(5, pollChanged, self);
            self.refresh();
        } else {
            self.generation += 1;
            for (&self.monitors) |*m| if (m.*) |v| {
                _ = v.cancel();
                v.unref();
                m.* = null;
            };
            if (self.debounce != 0) _ = glib.Source.remove(self.debounce);
            if (self.poll != 0) _ = glib.Source.remove(self.poll);
            self.debounce = 0;
            self.poll = 0;
            if (self.cancel) |c| c.cancel();
        }
    }
    fn watch(self: *Store, index: usize, path: []const u8) void {
        if (self.monitors[index]) |m| {
            _ = m.cancel();
            m.unref();
        }
        const z = a.dupeSentinel(u8, path, 0) catch return;
        defer a.free(z);
        const file = gio.File.newForPath(z);
        defer file.unref();
        self.monitors[index] = file.monitorDirectory(.{ .watch_moves = true }, null, null);
        if (self.monitors[index]) |m| _ = gio.FileMonitor.signals.changed.connect(m, *Store, monitorChanged, self, .{});
    }
    fn monitorChanged(_: *gio.FileMonitor, file: *gio.File, other: ?*gio.File, event: gio.FileMonitorEvent, self: *Store) callconv(.c) void {
        if (event == .renamed or event == .moved) if (other) |dest| {
            const old = file.getUri();
            defer glib.free(old);
            const new = dest.getUri();
            defer glib.free(new);
            self.state.rename(std.mem.span(old), std.mem.span(new));
            self.persist();
        };
        self.schedule();
    }
    fn pollChanged(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Store = @ptrCast(@alignCast(data.?));
        // Healthy monitors do not rescan an idle desktop every five seconds.
        if (self.snapshot == null or self.monitors[0] == null or self.monitors[1] == null or self.monitors[2] == null) self.schedule();
        return 1;
    }
    pub fn schedule(self: *Store) void {
        if (self.enabled and self.debounce == 0) {
            self.generation += 1;
            if (self.cancel) |cancel| cancel.cancel();
            self.debounce = glib.timeoutAdd(160, later, self);
        }
    }
    fn later(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Store = @ptrCast(@alignCast(data.?));
        self.debounce = 0;
        self.refresh();
        return 0;
    }
    pub fn refresh(self: *Store) void {
        if (!self.enabled or self.stopped) return;
        if (self.pending) {
            self.dirty = true;
            return;
        }
        self.pending = true;
        self.cancel = gio.Cancellable.new();
        self.retain();
        self.app.hold();
        const job = a.create(Scan) catch unreachable;
        job.* = .{ .store = self, .generation = self.generation, .load_state = !self.state_loaded };
        const task = gio.Task.new(null, self.cancel, completed, job);
        task.setTaskData(job, null);
        task.setCheckCancellable(0);
        _ = task.setReturnOnCancel(0);
        task.runInThread(scan);
        task.unref();
    }
    const Scan = struct { store: *Store, generation: u64, load_state: bool };
    fn scan(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, cancel: ?*gio.Cancellable) callconv(.c) void {
        const job: *Scan = @ptrCast(@alignCast(data.?));
        task.returnPointer(collect(job, cancel.?) catch null, null);
    }
    fn collect(job: *Scan, cancel: *gio.Cancellable) !*Snapshot {
        const self = job.store;
        const result = try a.create(Snapshot);
        result.* = .{ .arena = .init(a) };
        errdefer result.destroy();
        const alloc = result.arena.allocator();
        if (job.load_state) {
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            result.state = .init(a);
            const path = try std.fmt.allocPrintSentinel(alloc, "{s}/desktop-icons.json", .{self.state_dir}, 0);
            const approval_path = try std.fmt.allocPrintSentinel(alloc, "{s}/desktop-launchers.json", .{self.state_dir}, 0);
            const layout = io.read(scratch.allocator(), path, 16 * 1024 * 1024, cancel) catch null;
            const approvals = io.read(scratch.allocator(), approval_path, 4 * 1024 * 1024, cancel) catch null;
            result.state.?.load(if (layout) |v| v.bytes else "invalid", if (approvals) |v| v.bytes else "invalid");
        }
        const config = io.read(alloc, self.config, 65536, cancel) catch {
            result.message = "Cannot read Desktop directory settings. Retry after correcting user-dirs.dirs.";
            return result;
        };
        result.path = try policy.desktopPath(alloc, config.bytes, self.home);
        const path = result.path orelse {
            result.message = "No Desktop folder is configured. Set XDG_DESKTOP_DIR in user-dirs.dirs, then Retry.";
            return result;
        };
        const dir = gio.File.newForPath(path);
        defer dir.unref();
        var err: ?*glib.Error = null;
        const enumerator = dir.enumerateChildren(attrs, .{ .nofollow_symlinks = true }, cancel, &err) orelse {
            if (err) |e| {
                result.missing = e.matches(gio.ioErrorQuark(), @backingInt(gio.IOErrorEnum.not_found)) != 0;
                e.free();
            }
            result.message = if (result.missing) "The configured Desktop folder does not exist. Create folder or Retry." else "Cannot read the Desktop folder. Check permissions, then Retry.";
            return result;
        };
        defer enumerator.unref();
        while (true) {
            if (cancel.isCancelled() != 0) return error.Cancelled;
            const info = enumerator.nextFile(cancel, &err) orelse break;
            errdefer info.unref();
            const file = dir.getChild(info.getName());
            defer file.unref();
            const uri = file.getUri();
            defer glib.free(uri);
            const local = file.getPath() orelse {
                info.unref();
                continue;
            };
            defer glib.free(local);
            var item: Item = .{ .uri = try alloc.dupeSentinel(u8, std.mem.span(uri), 0), .path = try alloc.dupeSentinel(u8, std.mem.span(local), 0), .name = try policy.displayText(alloc, std.mem.span(info.getDisplayName())), .info = info, .launcher = std.mem.endsWith(u8, std.mem.span(info.getName()), ".desktop") };
            if (item.launcher and info.getIsSymlink() == 0 and info.getFileType() == .regular) {
                var scratch = std.heap.ArenaAllocator.init(a);
                defer scratch.deinit();
                const read = io.read(scratch.allocator(), item.path, 131072, cancel) catch null;
                if (read) |r| if (!r.missing) {
                    const key = glib.KeyFile.new();
                    defer key.unref();
                    if (key.loadFromData((try scratch.allocator().dupeSentinel(u8, r.bytes, 0)).ptr, r.bytes.len, .{}, null) != 0) if (unix.DesktopAppInfo.newFromKeyfile(key)) |app| {
                        defer app.unref();
                        item.digest = r.hash;
                        item.command = try policy.displayText(alloc, std.mem.span(app.as(gio.AppInfo).getCommandline() orelse "D-Bus application activation"));
                        item.launch_name = try policy.displayText(alloc, std.mem.span(app.as(gio.AppInfo).getDisplayName()));
                        if (app.as(gio.AppInfo).getIcon()) |icon| if (object.ext.cast(gio.ThemedIcon, icon) != null) info.setIcon(icon);
                    };
                };
            }
            try result.items.append(alloc, item);
        }
        if (err) |e| {
            e.free();
            for (result.items.items) |item| item.info.unref();
            result.items.clearRetainingCapacity();
            result.message = "Cannot finish reading the Desktop folder. Check permissions, then Retry.";
            return result;
        }
        std.mem.sort(Item, result.items.items, {}, less);
        return result;
    }
    fn less(_: void, x: Item, y: Item) bool {
        const xd = x.info.getFileType() == .directory;
        const yd = y.info.getFileType() == .directory;
        if (xd != yd) return xd;
        const order = glib.utf8Collate(x.name, y.name);
        return if (order == 0) std.mem.order(u8, x.uri, y.uri) == .lt else order < 0;
    }
    fn same(x: *Snapshot, y: *Snapshot) bool {
        if (!std.mem.eql(u8, x.path orelse "", y.path orelse "") or !std.mem.eql(u8, x.message, y.message) or x.items.items.len != y.items.items.len) return false;
        for (x.items.items, y.items.items) |first, second| {
            if (!std.mem.eql(u8, first.uri, second.uri) or !std.mem.eql(u8, first.name, second.name) or !std.meta.eql(first.digest, second.digest) or first.info.getFileType() != second.info.getFileType() or first.info.getIsHidden() != second.info.getIsHidden() or !std.mem.eql(u8, std.mem.span(first.info.getEtag() orelse ""), std.mem.span(second.info.getEtag() orelse ""))) return false;
        }
        return true;
    }
    fn completed(_: ?*object.Object, reply: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const job: *Scan = @ptrCast(@alignCast(data.?));
        const self = job.store;
        defer {
            a.destroy(job);
            self.app.release();
            self.release();
        }
        const result: ?*Snapshot = @ptrCast(@alignCast(object.ext.cast(gio.Task, reply).?.propagatePointer(null)));
        self.pending = false;
        self.cancel.?.unref();
        self.cancel = null;
        if (self.stopped or !self.enabled or job.generation != self.generation) {
            if (result) |s| s.destroy();
        } else if (result) |s| {
            if (self.snapshot) |previous| if (s.state == null and same(previous, s)) {
                s.destroy();
                if (self.dirty) {
                    self.dirty = false;
                    self.refresh();
                }
                return;
            };
            if (s.state) |state| {
                self.state.deinit();
                self.state = state;
                s.state = null;
                self.state_loaded = true;
            }
            const old = self.snapshot;
            self.snapshot = s;
            if (s.path) |path| {
                self.watch(1, path);
                self.watch(2, std.fs.path.dirname(path) orelse "/");
            }
            if (self.changed) |notify| notify(self.context.?);
            if (old) |previous| previous.destroy();
        }
        if (self.dirty) {
            self.dirty = false;
            self.refresh();
        }
    }
    pub fn persist(self: *Store) void {
        if (self.save_timer == 0) self.save_timer = glib.timeoutAdd(250, saveLater, self);
    }
    fn saveLater(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Store = @ptrCast(@alignCast(data.?));
        self.save_timer = 0;
        self.save();
        return 0;
    }
    const Save = struct { store: *Store, layout: []u8, approvals: []u8, preserve_layout: bool, preserve_approvals: bool, failed: bool = false };
    fn save(self: *Store) void {
        if (self.saving) {
            self.save_again = true;
            return;
        }
        const job = a.create(Save) catch return;
        job.* = .{ .store = self, .layout = std.json.Stringify.valueAlloc(a, persistence.Document{ .placements = self.state.placements.items }, .{}) catch {
            a.destroy(job);
            return;
        }, .approvals = std.json.Stringify.valueAlloc(a, persistence.Approvals{ .approvals = self.state.approvals.items }, .{}) catch {
            a.free(job.layout);
            a.destroy(job);
            return;
        }, .preserve_layout = self.state.corrupt, .preserve_approvals = self.state.approvals_corrupt };
        self.saving = true;
        self.retain();
        self.app.hold();
        const task = gio.Task.new(null, null, saved, job);
        task.setTaskData(job, null);
        task.runInThread(write);
        task.unref();
    }
    fn write(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
        const job: *Save = @ptrCast(@alignCast(data.?));
        writeFiles(job) catch {
            job.failed = true;
        };
        task.returnBoolean(1);
    }
    fn writeFiles(job: *Save) !void {
        try io.mkdir(job.store.state_dir);
        for ([_][]const u8{ "desktop-icons.json", "desktop-launchers.json" }, [_][]const u8{ job.layout, job.approvals }, [_]bool{ job.preserve_layout, job.preserve_approvals }) |name, bytes, preserve| {
            const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ job.store.state_dir, name }, 0);
            defer a.free(path);
            if (preserve) {
                const backup = try std.fmt.allocPrintSentinel(a, "{s}.corrupt-{d}", .{ path, glib.getRealTime() }, 0);
                defer a.free(backup);
                if (std.c.rename(path, backup) != 0 and std.posix.errno(-1) != .NOENT) return error.BackupFailed;
            }
            try io.atomic(path, bytes, false);
        }
    }
    fn saved(_: ?*object.Object, _: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const job: *Save = @ptrCast(@alignCast(data.?));
        const self = job.store;
        self.save_error = job.failed;
        self.saving = false;
        if (!job.failed) {
            self.state.corrupt = false;
            self.state.approvals_corrupt = false;
        }
        a.free(job.layout);
        a.free(job.approvals);
        a.destroy(job);
        if (self.save_again) {
            self.save_again = false;
            self.save();
        }
        if (!self.stopped) if (self.changed) |notify| notify(self.context.?);
        self.app.release();
        self.release();
    }
};
