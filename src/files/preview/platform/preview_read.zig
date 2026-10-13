//! Bounded asynchronous subprocess output; callbacks run after the child is reaped.
const std = @import("std");
const u = @import("../ui.zig");
const gio = u.gio;
const glib = u.glib;
const a = u.a;
pub const Read = struct {
    process: *gio.Subprocess,
    cancel_io: *gio.Cancellable,
    bytes: std.ArrayList(u8) = .empty,
    limit: usize,
    timer: c_uint = 0,
    failed: bool = false,
    timeout: bool = false,
    callback: *const fn (*Read, bool, ?*anyopaque) void,
    data: ?*anyopaque,
    pub fn start(argv: [*:null]const ?[*:0]const u8, limit: usize, timeout: u32, callback: *const fn (*Read, bool, ?*anyopaque) void, data: ?*anyopaque) ?*Read {
        const process = gio.Subprocess.newv(@ptrCast(argv), .{ .stdout_pipe = true, .stderr_silence = !@import("build_options").test_hooks }, null) orelse return null;
        const self = a.create(Read) catch unreachable;
        self.* = .{ .process = process, .cancel_io = gio.Cancellable.new(), .limit = limit, .callback = callback, .data = data };
        self.timer = glib.timeoutAdd(timeout, expired, self);
        process.getStdoutPipe().?.readBytesAsync(16384, 0, self.cancel_io, chunk, self);
        return self;
    }
    pub fn cancel(self: *Read) void {
        self.failed = true;
        self.process.forceExit();
        self.cancel_io.cancel();
    }
    fn expired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Read = @ptrCast(@alignCast(data.?));
        self.timer = 0;
        self.timeout = true;
        self.cancel();
        return 0;
    }
    fn chunk(_: ?*u.object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Read = @ptrCast(@alignCast(data.?));
        var err: ?*glib.Error = null;
        const bytes = self.process.getStdoutPipe().?.readBytesFinish(result, &err);
        if (err) |e| e.free();
        var count: usize = 0;
        if (bytes) |b| {
            defer b.unref();
            const ptr = b.getData(&count);
            if (count > self.limit - self.bytes.items.len) {
                self.cancel();
            } else if (count > 0) {
                self.bytes.appendSlice(a, ptr.?[0..count]) catch {
                    self.cancel();
                };
            }
        } else self.cancel();
        if (self.failed or count == 0) {
            self.process.waitAsync(null, waited, self);
        } else self.process.getStdoutPipe().?.readBytesAsync(16384, 0, self.cancel_io, chunk, self);
    }
    fn waited(_: ?*u.object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Read = @ptrCast(@alignCast(data.?));
        var err: ?*glib.Error = null;
        const ok = self.process.waitFinish(result, &err) != 0;
        if (err) |e| e.free();
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.callback(self, ok and !self.failed and self.process.getSuccessful() != 0, self.data);
        self.bytes.deinit(a);
        self.cancel_io.unref();
        self.process.unref();
        a.destroy(self);
    }
};
