//! Bounded asynchronous session-bus transport. No service activation or replacement.
const std = @import("std");
pub const db = @import("dbus_peer.zig");
pub const gio = db.gio;
pub const glib = db.glib;
const object = @import("gobject2");
const a = std.heap.c_allocator;
pub const Done = *const fn (*anyopaque, u64, ?*glib.Variant) void;
const Job = struct { bus: *Bus, epoch: u64, context: *anyopaque, token: u64, done: Done };
pub const Bus = struct {
    app: *gio.Application,
    context: *anyopaque,
    changed: *const fn (*anyopaque, bool) void,
    signal: gio.DBusSignalCallback,
    conn: ?*gio.DBusConnection = null,
    cancel: *gio.Cancellable = undefined,
    running: bool = false,
    epoch: u64 = 0,
    jobs: usize = 0,
    subscription: c_uint = 0,
    closed_signal: c_ulong = 0,
    retry: c_uint = 0,
    address: db.Text(4096) = .{},
    pub fn start(self: *Bus) void {
        self.running = true;
        // GApplication can retain GIO's closed shared bus connection. Keep the
        // UI alive and use a separately constructed connection for reconnects.
        if (self.app.getDbusConnection()) |connection| connection.setExitOnClose(0);
        if (glib.getenv("DBUS_SESSION_BUS_ADDRESS")) |address| {
            self.address.set(std.mem.span(address));
        } else if (glib.getenv("XDG_RUNTIME_DIR")) |runtime| {
            var buffer: [4096]u8 = undefined;
            self.address.set(std.fmt.bufPrint(&buffer, "unix:path={s}/bus", .{std.mem.span(runtime)}) catch "");
        }
        self.cancel = gio.Cancellable.new();
        self.open();
    }
    fn open(self: *Bus) void {
        self.app.hold();
        gio.DBusConnection.newForAddress(self.address.z(), .{ .authentication_client = true, .message_bus_connection = true }, null, self.cancel, opened, self);
    }
    fn opened(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Bus = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        var err: ?*glib.Error = null;
        const conn = gio.DBusConnection.newForAddressFinish(result, &err);
        if (err) |e| e.free();
        if (!self.running) {
            if (conn) |c| c.unref();
            return;
        }
        if (conn) |c| {
            if (c.isClosed() != 0) {
                c.unref();
                self.retry = glib.timeoutAdd(3000, retryTick, self);
                return;
            }
            self.conn = c;
            c.setExitOnClose(0);
            self.closed_signal = gio.DBusConnection.signals.closed.connect(c, *Bus, closed, self, .{});
            self.subscription = c.signalSubscribe(null, null, null, null, null, .{}, self.signal, self.context, null);
            self.changed(self.context, true);
        } else self.retry = glib.timeoutAdd(3000, retryTick, self);
    }
    fn retryTick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Bus = @ptrCast(@alignCast(data.?));
        self.retry = 0;
        if (self.running) self.open();
        return 0;
    }
    fn closed(_: *gio.DBusConnection, _: c_int, _: ?*glib.Error, self: *Bus) callconv(.c) void {
        self.clear();
        if (self.running) self.retry = glib.timeoutAdd(3000, retryTick, self);
    }
    fn clear(self: *Bus) void {
        self.epoch +%= 1;
        self.cancel.cancel();
        self.changed(self.context, false);
        if (self.conn) |c| {
            c.signalUnsubscribe(self.subscription);
            object.signalHandlerDisconnect(c.as(object.Object), self.closed_signal);
            c.unref();
        }
        self.conn = null;
        if (self.running) {
            self.cancel.unref();
            self.cancel = gio.Cancellable.new();
        }
    }
    pub fn stop(self: *Bus) void {
        self.running = false;
        if (self.retry != 0) _ = glib.Source.remove(self.retry);
        self.retry = 0;
        self.clear();
        self.cancel.unref();
    }
    pub fn call(self: *Bus, context: *anyopaque, token: u64, dest: [:0]const u8, path: [:0]const u8, iface: [:0]const u8, method: [:0]const u8, params: ?*glib.Variant, signature: [:0]const u8, done: Done) !void {
        if (params) |p| _ = p.refSink();
        defer if (params) |p| p.unref();
        const c = self.conn orelse return error.Unavailable;
        if (!self.running or self.jobs >= 64) return error.Busy;
        const job = try a.create(Job);
        job.* = .{ .bus = self, .epoch = self.epoch, .context = context, .token = token, .done = done };
        self.jobs += 1;
        self.app.hold();
        const t = glib.VariantType.new(signature);
        defer t.free();
        c.call(dest, path, iface, method, params, t, .{ .no_auto_start = true }, 3000, self.cancel, called, job);
    }
    fn called(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(data.?));
        const self = job.bus;
        defer a.destroy(job);
        defer self.app.release();
        self.jobs -= 1;
        var err: ?*glib.Error = null;
        const value = object.ext.cast(gio.DBusConnection, source.?).?.callFinish(result, &err);
        defer if (value) |v| v.unref();
        defer if (err) |e| e.free();
        if (self.running and self.epoch == job.epoch) job.done(job.context, job.token, value);
    }
    pub fn emit(self: *Bus, dest: ?[:0]const u8, path: [:0]const u8, iface: [:0]const u8, member: [:0]const u8, params: *glib.Variant) void {
        _ = params.refSink();
        defer params.unref();
        if (self.conn) |c| _ = c.emitSignal(if (dest) |s| s.ptr else null, path, iface, member, params, null);
    }
};
pub fn childText(comptime n: usize, params: *glib.Variant, index: usize) db.Text(n) {
    const v = params.getChildValue(index);
    defer v.unref();
    var out: db.Text(n) = .{};
    out.set(std.mem.span(v.getString(null)));
    return out;
}
pub fn getAll(bus: *Bus, context: *anyopaque, token: u64, owner: [:0]const u8, path: [:0]const u8, iface: [:0]const u8, done: Done) !void {
    try bus.call(context, token, owner, path, "org.freedesktop.DBus.Properties", "GetAll", db.tuple(&.{db.str(iface)}), "(a{sv})", done);
}
pub fn resolve(bus: *Bus, context: *anyopaque, token: u64, name: [:0]const u8, done: Done) !void {
    try bus.call(context, token, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", db.tuple(&.{db.str(name)}), "(s)", done);
}
