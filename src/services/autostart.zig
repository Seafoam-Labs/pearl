//! XDG autostart directories: the session launch run and managed edits from
//! Settings. The user directory (~/.config/autostart) is authoritative; a user
//! file with the same base name masks its /etc/xdg/autostart counterpart, and
//! disabling or removing a system entry writes such a mask, the same way
//! gnome-session and Plasma treat these directories.
const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const unix = @import("giounix2");
const object = @import("gobject2");
const policy = @import("autostart_policy.zig");
const log = std.log.scoped(.services);
const a = std.heap.c_allocator;

const Monitor = struct { monitor: ?*gio.FileMonitor = null, signal: c_ulong = 0 };
const Job = struct { service: *Service, display: *gdk.Display, path: [:0]const u8 };

pub const Service = struct {
    app: *gio.Application,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    /// Owns the current entry list.
    arena: std.heap.ArenaAllocator = .init(a),
    entries: []policy.Entry = &.{},
    user_root: ?[:0]const u8 = null,
    system_root: ?[:0]const u8 = null,
    monitors: [2]Monitor = .{ .{}, .{} },
    debounce: c_uint = 0,
    started: bool = false,
    err: ?[:0]const u8 = null,

    pub fn start(self: *Service) !void {
        if (self.started) return;
        self.user_root = try environmentRoot("PEARL_TEST_AUTOSTART_USER", try userDefault());
        self.system_root = try environmentRoot("PEARL_TEST_AUTOSTART_SYSTEM", try a.dupeSentinel(u8, "/etc/xdg/autostart", 0));
        self.started = true;
        // The user directory must exist to be watched; entries are added to it.
        _ = glib.mkdirWithParents(self.user_root.?, 0o755);
        self.scan();
        for ([2]?[:0]const u8{ self.user_root, self.system_root }, 0..) |optional, i| {
            const path = optional orelse continue;
            var err: ?*glib.Error = null;
            const file = gio.File.newForPath(path.ptr);
            defer file.unref();
            const monitor = file.monitorDirectory(.{}, null, &err) orelse {
                if (err) |e| e.free();
                continue;
            };
            self.monitors[i] = .{ .monitor = monitor, .signal = gio.FileMonitor.signals.changed.connect(monitor, *Service, directoryChanged, self, .{}) };
        }
    }

    pub fn stop(self: *Service) void {
        if (!self.started) return;
        self.started = false;
        if (self.debounce != 0) _ = glib.Source.remove(self.debounce);
        self.debounce = 0;
        for (&self.monitors) |*slot| {
            if (slot.monitor) |monitor| {
                object.signalHandlerDisconnect(monitor.as(object.Object), slot.signal);
                monitor.unref();
            }
            slot.* = .{};
        }
        if (self.user_root) |path| a.free(path);
        if (self.system_root) |path| a.free(path);
        self.user_root = null;
        self.system_root = null;
        _ = self.arena.reset(.free_all);
        self.entries = &.{};
    }

    pub fn find(self: *const Service, file: []const u8) ?policy.Entry {
        for (self.entries) |entry| if (std.mem.eql(u8, entry.file, file)) return entry;
        return null;
    }

    /// Creates a managed user entry from an installed application.
    pub fn add(self: *Service, app_id: []const u8) !void {
        if (!policy.desktopId(app_id)) return error.InvalidDesktopId;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const id = try alloc.dupeSentinel(u8, app_id, 0);
        const desktop = unix.DesktopAppInfo.new(id) orelse return error.StaleApplication;
        defer desktop.unref();
        var entry: policy.New = .{ .app_id = app_id, .name = std.mem.span(desktop.as(gio.AppInfo).getDisplayName()), .exec = "" };
        // Copy Exec/Icon/Comment from the installed desktop file so the entry
        // keeps launching what the application itself declares.
        var threaded: std.Io.Threaded = .init_single_threaded;
        const tio = threaded.io();
        if (desktop.getFilename()) |filename| {
            const source = std.Io.Dir.cwd().readFileAlloc(tio, std.mem.span(filename), alloc, .limited(policy.Limits.text)) catch null;
            if (source) |text| if (try policy.parse(alloc, text, .system, app_id)) |parsed| {
                entry.exec = parsed.exec;
                entry.icon = parsed.icon;
                entry.comment = parsed.comment;
            };
        }
        if (entry.exec.len == 0) {
            const command = desktop.as(gio.AppInfo).getCommandline() orelse return error.StaleApplication;
            entry.exec = std.mem.span(command);
        }
        const text = try policy.render(alloc, entry);
        try self.write(try userPath(self, alloc, app_id), text);
        self.refresh();
    }

    /// Toggles `Hidden` on the user copy, masking a system entry when needed.
    pub fn setEnabled(self: *Service, file: []const u8, enabled: bool) !void {
        const entry = self.find(file) orelse return error.Stale;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const source_root = if (entry.source == .user) self.user_root orelse return error.Unavailable else self.system_root orelse return error.Unavailable;
        const source = try self.read(alloc, source_root, file);
        const text = try policy.setHidden(alloc, source, !enabled);
        try self.write(try userPath(self, alloc, file), text);
        self.refresh();
    }

    /// Deletes the user file; system entries are masked with Hidden instead.
    /// Removing a user mask lets the system entry it replaced reappear.
    pub fn remove(self: *Service, file: []const u8) !void {
        const entry = self.find(file) orelse return error.Stale;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const path = try userPath(self, alloc, file);
        if (entry.source == .user) {
            if (std.c.unlink(path) != 0) return error.Unavailable;
        } else {
            const source = try self.read(alloc, self.system_root orelse return error.Unavailable, file);
            try self.write(path, try policy.setHidden(alloc, source, true));
        }
        self.refresh();
    }

    /// Launches every qualifying entry once. The caller guarantees this runs
    /// only for a verified, unlocked session start.
    pub fn launch(self: *Service, display: *gdk.Display) void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const desktops = sessionDesktops(alloc);
        var launched: usize = 0;
        for (self.entries) |entry| {
            if (!policy.launchable(entry, desktops, tryExecFound)) continue;
            const root = if (entry.source == .user) self.user_root orelse continue else self.system_root orelse continue;
            const path = full(alloc, root, entry.file) catch continue;
            if (entry.delay > 0) {
                const job = a.create(Job) catch continue;
                job.* = .{ .service = self, .display = display, .path = a.dupeSentinel(u8, path, 0) catch {
                    a.destroy(job);
                    continue;
                } };
                self.app.hold();
                _ = glib.timeoutAdd(entry.delay * 1000, launchDelayed, job);
            } else launchOne(display, path);
            launched += 1;
        }
        log.info("event=autostart-run entries={d} launched={d}", .{ self.entries.len, launched });
    }

    fn scan(self: *Service) void {
        _ = self.arena.reset(.retain_capacity);
        const alloc = self.arena.allocator();
        var threaded: std.Io.Threaded = .init_single_threaded;
        const tio = threaded.io();
        var list: std.ArrayList(policy.Entry) = .empty;
        var masked: std.ArrayList([]const u8) = .empty;
        scanDir(tio, alloc, self.user_root orelse return, .user, &list, null);
        scanDir(tio, alloc, self.system_root orelse "", .system, &list, &masked);
        for (masked.items) |file| for (list.items) |*entry| {
            if (entry.source == .user and std.mem.eql(u8, entry.file, file)) entry.masks_system = true;
        };
        policy.sort(list.items);
        self.entries = list.toOwnedSlice(alloc) catch &.{};
    }

    fn read(self: *Service, alloc: std.mem.Allocator, root_path: [:0]const u8, file: []const u8) ![]const u8 {
        _ = self;
        const path = try full(alloc, root_path, file);
        var threaded: std.Io.Threaded = .init_single_threaded;
        return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, alloc, .limited(policy.Limits.text)) catch error.Unavailable;
    }

    fn write(self: *Service, path: [:0]const u8, text: []const u8) !void {
        _ = self;
        // Temp-file plus rename so watchers never observe a partial entry.
        const temp = try std.fmt.allocPrintSentinel(a, "{s}.pearl-XXXXXX", .{path}, 0);
        defer a.free(temp);
        const fd = glib.mkstempFull(temp, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CLOEXEC = true }), 0o644);
        if (fd < 0) return error.Unavailable;
        defer _ = std.c.close(fd);
        defer _ = std.c.unlink(temp);
        var offset: usize = 0;
        while (offset < text.len) {
            const n = std.c.write(fd, text[offset..].ptr, text.len - offset);
            if (n <= 0) return error.Unavailable;
            offset += @intCast(n);
        }
        if (std.c.rename(temp, path) != 0) {
            log.warn("event=autostart-write-failed path={s}", .{path});
            return error.Unavailable;
        }
    }

    fn refresh(self: *Service) void {
        self.scan();
        self.changed(self.context);
    }

    fn directoryChanged(_: *gio.FileMonitor, _: *gio.File, _: ?*gio.File, kind: gio.FileMonitorEvent, self: *Service) callconv(.c) void {
        switch (kind) {
            .created, .deleted, .moved_in, .moved_out, .changed => {},
            else => return,
        }
        if (!self.started or self.debounce != 0) return;
        self.debounce = glib.timeoutAdd(200, rescanned, self);
    }

    fn rescanned(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data.?));
        self.debounce = 0;
        if (self.started) self.refresh();
        return 0;
    }

    fn launchDelayed(data: ?*anyopaque) callconv(.c) c_int {
        const job: *Job = @ptrCast(@alignCast(data.?));
        defer {
            a.free(job.path);
            a.destroy(job);
        }
        launchOne(job.display, job.path);
        job.service.app.release();
        return 0;
    }
};

fn scanDir(tio: std.Io, alloc: std.mem.Allocator, path: [:0]const u8, source: policy.Source, list: *std.ArrayList(policy.Entry), masked: ?*std.ArrayList([]const u8)) void {
    if (list.items.len >= policy.Limits.entries) return;
    var dir = std.Io.Dir.openDirAbsolute(tio, path, .{ .iterate = true }) catch return;
    defer dir.close(tio);
    var it = dir.iterate();
    while (it.next(tio) catch null) |item| {
        if (item.kind != .file) continue;
        if (!std.mem.endsWith(u8, item.name, ".desktop") or item.name.len > 1024) continue;
        var shadowed = false;
        for (list.items) |existing| if (std.mem.eql(u8, existing.file, item.name)) {
            shadowed = true;
            break;
        };
        if (shadowed) {
            // The user file of the same name replaces this system entry.
            if (masked) |m| m.append(alloc, alloc.dupe(u8, item.name) catch continue) catch {};
            continue;
        }
        const text = dir.readFileAlloc(tio, item.name, alloc, .limited(policy.Limits.text)) catch continue;
        const name = alloc.dupe(u8, item.name) catch continue;
        const entry = (policy.parse(alloc, text, source, name) catch null) orelse continue;
        list.append(alloc, entry) catch break;
        if (list.items.len >= policy.Limits.entries) break;
    }
}

fn launchOne(display: *gdk.Display, path: [:0]const u8) void {
    const target = unix.DesktopAppInfo.newFromFilename(path) orelse {
        log.warn("event=autostart-launch-failed file={s} reason=unresolved", .{path});
        return;
    };
    defer target.unref();
    const context = display.getAppLaunchContext();
    defer context.unref();
    context.setTimestamp(0);
    var err: ?*glib.Error = null;
    defer if (err) |e| e.free();
    if (target.as(gio.AppInfo).launch(null, context.as(gio.AppLaunchContext), &err) == 0) {
        const reason: []const u8 = if (err) |e| if (e.f_message) |message| std.mem.span(message) else "launch rejected" else "launch rejected";
        log.warn("event=autostart-launch-failed file={s} reason={s}", .{ path, reason });
        return;
    }
    log.info("event=autostart-launched file={s}", .{path});
}

fn tryExecFound(program: []const u8) bool {
    const path = std.fmt.allocPrintSentinel(a, "{s}", .{program}, 0) catch return false;
    defer a.free(path);
    if (std.mem.startsWith(u8, program, "/")) return glib.fileTest(path, .{ .is_executable = true }) != 0;
    const found = glib.findProgramInPath(path) orelse return false;
    glib.free(found);
    return true;
}

fn sessionDesktops(alloc: std.mem.Allocator) []const []const u8 {
    const value = if (glib.getenv("XDG_CURRENT_DESKTOP")) |raw| std.mem.span(raw) else "";
    var items: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, value, ':');
    while (parts.next()) |part| {
        const text = std.mem.trim(u8, part, " ");
        if (text.len == 0 or text.len > 256) continue;
        items.append(alloc, text) catch break;
        if (items.items.len >= 8) break;
    }
    return items.items;
}

fn full(alloc: std.mem.Allocator, root_path: [:0]const u8, file: []const u8) ![:0]const u8 {
    if (!policy.desktopId(file)) return error.InvalidDesktopId;
    return std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ root_path, file }, 0);
}

fn userPath(self: *const Service, alloc: std.mem.Allocator, file: []const u8) ![:0]const u8 {
    return full(alloc, self.user_root orelse return error.Unavailable, file);
}

fn userDefault() ![:0]const u8 {
    const config = std.mem.span(glib.getUserConfigDir());
    if (config.len == 0 or config.len > 4096) return error.Unavailable;
    return a.dupeSentinel(u8, try std.fmt.allocPrint(a, "{s}/autostart", .{config}), 0);
}

fn environmentRoot(override: [:0]const u8, fallback: [:0]const u8) ![:0]const u8 {
    if (@import("build_options").test_hooks) {
        if (glib.getenv(override)) |raw| {
            const value = try a.dupeSentinel(u8, std.mem.span(raw), 0);
            a.free(fallback);
            return value;
        }
    }
    return fallback;
}
