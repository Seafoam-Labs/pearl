//! Session-owned asynchronous theme operations. No frontend filesystem authority.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const a = std.heap.c_allocator;
pub const Manager = struct {
    job: ?*Job = null,
    result: ?[]u8 = null,
    error_code: ?anyerror = null,
    serial: u64 = 0,
    stopped: bool = false,
    pub fn stop(self: *Manager) void {
        self.stopped = true;
        if (self.job) |job| job.cancel.cancel();
        if (self.result) |bytes| a.free(bytes);
        self.result = null;
    }
    pub fn start(self: *Manager, app: *gio.Application, text: []const u8) !void {
        if (self.stopped) return error.Unavailable;
        if (self.job != null) return error.Busy;
        const job = try a.create(Job);
        job.* = .{ .manager = self, .app = app, .arena = .init(a), .cancel = gio.Cancellable.new(), .request = undefined };
        errdefer job.destroy();
        job.request = try @import("package_model.zig").parse(@import("commands.zig").Request, job.arena.allocator(), text, 16384);
        self.error_code = null;
        if (self.result) |old| a.free(old);
        self.result = null;
        self.job = job;
        job.deadline = glib.timeoutAdd(if (job.request.action == .preview_render) 15000 else 60000, expired, job);
        self.serial +|= 1;
        app.hold();
        const task = gio.Task.new(null, job.cancel, done, job);
        task.setCheckCancellable(0);
        _ = task.setReturnOnCancel(0);
        task.setTaskData(job, null);
        task.runInThread(work);
        task.unref();
    }
    pub fn status(self: *Manager, alloc: std.mem.Allocator) ![]const u8 {
        const p = @import("../settings/editor_protocol.zig");
        const header = try std.json.Stringify.valueAlloc(alloc, .{ .busy = self.job != null, .serial = p.num(self.serial), .phase = if (self.job) |job| @tagName(job.progress.phase.load(.monotonic)) else "complete", .received = p.num(if (self.job) |job| job.progress.received.load(.monotonic) else 0), .total = p.num(if (self.job) |job| job.progress.total.load(.monotonic) else 0), .error_code = if (self.error_code) |err| @errorName(err) else null }, .{});
        return std.fmt.allocPrint(alloc, "{s},\"result\":{s}}}", .{ header[0 .. header.len - 1], self.result orelse "null" });
    }
};
const Job = struct {
    manager: *Manager,
    app: *gio.Application,
    arena: std.heap.ArenaAllocator,
    cancel: *gio.Cancellable,
    request: @import("commands.zig").Request,
    result: ?[]const u8 = null,
    failure: ?anyerror = null,
    progress: @import("progress.zig").Progress = .{},
    deadline: c_uint = 0,
    fn destroy(self: *Job) void {
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.cancel.unref();
        self.arena.deinit();
        a.destroy(self);
    }
};
fn expired(data: ?*anyopaque) callconv(.c) c_int {
    const job: *Job = @ptrCast(@alignCast(data.?));
    job.deadline = 0;
    job.cancel.cancel();
    return 0;
}
fn work(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data.?));
    job.result = @import("commands.zig").run(job.arena.allocator(), job.request, job.cancel, &job.progress) catch |err| blk: {
        job.failure = err;
        break :blk null;
    };
    if (job.result) |bytes| if (bytes.len > 120000) {
        job.result = null;
        job.failure = error.ThemeResultLimit;
    };
    task.returnBoolean(1);
}
fn done(_: ?*object.Object, _: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data.?));
    const self = job.manager;
    self.job = null;
    if (!self.stopped) {
        self.error_code = job.failure;
        if (job.result) |bytes| self.result = a.dupe(u8, bytes) catch blk: {
            self.error_code = error.OutOfMemory;
            break :blk null;
        };
    }
    job.app.release();
    job.destroy();
}
