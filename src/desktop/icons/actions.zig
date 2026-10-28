//! Owned asynchronous operands; never interpolate filenames into commands.
const std = @import("std");
const gio = @import("gio2");
const gdk = @import("gdk4");
const glib = @import("glib2");
const object = @import("gobject2");
const unix = @import("giounix2");
const io = @import("../../config/io.zig");
const model = @import("model.zig");
const a = std.heap.c_allocator;
pub const Kind = enum { open, approve, rename, trash, mkdir, shortcut };
pub const Request = struct {
    kind: Kind,
    path: []const u8,
    name: []const u8 = "",
    etag: ?[]const u8 = null,
    digest: ?[64]u8 = null,
    launcher: bool = false,
};
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    app: *gio.Application,
    display: *gdk.Display,
    cancel: *gio.Cancellable,
    request: Request,
    context: ?*anyopaque,
    callback: ?*const fn (*anyopaque, *Job) void,
    failure: ?anyerror = null,
    opened: ?*unix.DesktopAppInfo = null,
    uri: ?[:0]const u8 = null,
    digest: ?[64]u8 = null,
    launch_context: *gdk.AppLaunchContext,
    pub fn start(app: *gio.Application, display: *gdk.Display, request: Request, context: *anyopaque, callback: *const fn (*anyopaque, *Job) void) !*Job {
        const self = try a.create(Job);
        self.* = .{ .arena = .init(a), .app = app, .display = display, .cancel = gio.Cancellable.new(), .request = request, .context = context, .callback = callback, .launch_context = display.getAppLaunchContext() };
        errdefer {
            self.launch_context.unref();
            self.cancel.unref();
            self.arena.deinit();
            a.destroy(self);
        }
        const alloc = self.arena.allocator();
        self.request.path = try alloc.dupeSentinel(u8, request.path, 0);
        self.request.name = try alloc.dupeSentinel(u8, request.name, 0);
        self.request.etag = if (request.etag) |v| try alloc.dupeSentinel(u8, v, 0) else null;
        app.hold();
        const task = gio.Task.new(null, self.cancel, completed, self);
        task.setTaskData(self, null);
        task.setCheckCancellable(0);
        _ = task.setReturnOnCancel(0);
        task.runInThread(work);
        task.unref();
        return self;
    }
    pub fn detach(self: *Job) void {
        self.context = null;
        self.callback = null;
        self.cancel.cancel();
    }
    fn work(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(data.?));
        self.run() catch |err| {
            self.failure = err;
        };
        task.returnBoolean(1);
    }
    fn run(self: *Job) !void {
        const alloc = self.arena.allocator();
        const r = self.request;
        const file = gio.File.newForPath(@ptrCast(r.path.ptr));
        defer file.unref();
        const raw_uri = file.getUri();
        defer glib.free(raw_uri);
        self.uri = try alloc.dupeSentinel(u8, std.mem.span(raw_uri), 0);
        if (self.cancel.isCancelled() != 0) return error.Cancelled;
        if (r.kind != .mkdir and r.kind != .shortcut) {
            const info = file.queryInfo("etag::value,standard::type,standard::is-symlink", .{ .nofollow_symlinks = true }, self.cancel, null) orelse return error.ItemUnavailable;
            defer info.unref();
            if (r.etag) |expected| if (!std.mem.eql(u8, expected, std.mem.span(info.getEtag() orelse ""))) return error.ItemChanged;
            if (r.launcher) {
                if (info.getIsSymlink() != 0 or info.getFileType() != .regular) return error.UnsafeLauncher;
                const read = try io.read(alloc, try alloc.dupeSentinel(u8, r.path, 0), 131072, self.cancel);
                const digest = r.digest orelse return error.LauncherNotApproved;
                if (read.missing or !std.mem.eql(u8, &digest, &read.hash)) return error.LauncherChanged;
                const key = glib.KeyFile.new();
                defer key.unref();
                if (key.loadFromData((try alloc.dupeSentinel(u8, read.bytes, 0)).ptr, read.bytes.len, .{}, null) == 0) return error.InvalidLauncher;
                self.opened = unix.DesktopAppInfo.newFromKeyfile(key) orelse return error.InvalidLauncher;
                self.digest = read.hash;
            }
        }
        switch (r.kind) {
            .open, .approve => {},
            .trash => {
                if (file.trash(self.cancel, null) == 0) return error.TrashFailed;
            },
            .rename => {
                if (!model.validName(r.name)) return error.InvalidName;
                const parent = file.getParent() orelse return error.InvalidTarget;
                defer parent.unref();
                const target = parent.getChild(@ptrCast(r.name.ptr));
                defer target.unref();
                if (file.move(target, .{}, self.cancel, null, null, null) == 0) return error.RenameFailed;
            },
            .mkdir => {
                if (r.name.len == 0) {
                    if (file.makeDirectory(self.cancel, null) == 0) return error.CreateFolderFailed;
                } else {
                    if (!model.validName(r.name)) return error.InvalidName;
                    const target = file.getChild(@ptrCast(r.name.ptr));
                    defer target.unref();
                    if (target.makeDirectory(self.cancel, null) == 0) return error.CreateFolderFailed;
                }
            },
            .shortcut => {
                const app = unix.DesktopAppInfo.new(@ptrCast(r.name.ptr)) orelse return error.ApplicationUnavailable;
                defer app.unref();
                if (app.as(gio.AppInfo).shouldShow() == 0) return error.ApplicationUnavailable;
                const source = app.getFilename() orelse return error.ApplicationUnavailable;
                const read = try io.read(alloc, std.mem.span(source), 131072, self.cancel);
                if (read.missing) return error.ApplicationUnavailable;
                for (0..1000) |i| {
                    const name = try std.fmt.allocPrintSentinel(alloc, "Pearl-{d}-{s}", .{ i, std.fs.path.basename(r.name) }, 0);
                    const target = file.getChild(name);
                    defer target.unref();
                    const path = target.getPath() orelse return error.InvalidTarget;
                    defer glib.free(path);
                    io.atomic(std.mem.span(path), read.bytes, true) catch |err| {
                        if (err == error.Conflict) continue;
                        return err;
                    };
                    const uri = target.getUri();
                    defer glib.free(uri);
                    self.uri = try alloc.dupeSentinel(u8, std.mem.span(uri), 0);
                    self.digest = read.hash;
                    return;
                }
                return error.NameConflict;
            },
        }
    }
    fn completed(_: ?*object.Object, _: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(data.?));
        if (self.context != null and self.cancel.isCancelled() == 0 and self.failure == null and self.request.kind == .open) {
            if (self.opened) |app| {
                if (app.as(gio.AppInfo).launch(null, self.launch_context.as(gio.AppLaunchContext), null) == 0) self.failure = error.LaunchFailed;
            } else {
                // GIO opens documents through their registered handler; it does
                // not execute arbitrary executable files as shell commands.
                gio.AppInfo.launchDefaultForUriAsync(self.uri.?, self.launch_context.as(gio.AppLaunchContext), self.cancel, uriOpened, self);
                return;
            }
        }
        self.finish();
    }
    fn uriOpened(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(data.?));
        if (gio.AppInfo.launchDefaultForUriFinish(result, null) == 0) self.failure = error.LaunchFailed;
        self.finish();
    }
    fn finish(self: *Job) void {
        if (self.callback) |callback| callback(self.context.?, self);
        if (self.opened) |app| app.unref();
        self.launch_context.unref();
        self.cancel.unref();
        self.app.release();
        self.arena.deinit();
        a.destroy(self);
    }
};
