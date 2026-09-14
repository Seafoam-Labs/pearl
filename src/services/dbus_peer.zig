//! Owner-scoped, asynchronous ObjectManager transport shared by connectivity services.
const std = @import("std");
pub const gio = @import("gio2");
pub const glib = @import("glib2");
const object = @import("gobject2");
pub const Text = @import("policy.zig").Text;
const a = std.heap.c_allocator;
pub const Done = *const fn (*anyopaque, u64, ?*glib.Variant, ?[]const u8) void;
const Job = struct { peer: *Peer, epoch: u64, token: u64, done: Done };
pub const Peer = struct {
    app: *gio.Application,
    context: *anyopaque,
    changed: *const fn (*anyopaque, bool) void,
    invalidated: ?*const fn (*anyopaque, []const u8, []const u8, []const u8) void = null,
    name: [:0]const u8,
    root: [:0]const u8,
    managed: bool = true,
    signal_received: ?*const fn (*anyopaque, []const u8, []const u8, []const u8, *glib.Variant) void = null,
    proxy: ?*gio.DBusProxy = null,
    owner: Text(256) = .{},
    epoch: u64 = 0,
    cancel: *gio.Cancellable = undefined,
    running: bool = false,
    creating: bool = false,
    signals: [2]c_ulong = .{ 0, 0 },
    subscription: c_uint = 0,
    timer: c_uint = 0,
    loading: bool = false,
    dirty: bool = false,
    snapshot: ?*glib.Variant = null,
    err: ?[]const u8 = null,
    pub fn start(self: *Peer) void {
        self.running = true;
        self.cancel = gio.Cancellable.new();
        self.create();
    }
    fn create(self: *Peer) void {
        if (!self.running or self.creating or self.proxy != null) return;
        self.creating = true;
        self.app.hold();
        gio.DBusProxy.newForBus(.system, .{ .do_not_auto_start = true, .do_not_load_properties = true }, null, self.name, self.root, "org.freedesktop.DBus.ObjectManager", self.cancel, created, self);
    }
    fn created(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Peer = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        self.creating = false;
        var err: ?*glib.Error = null;
        const proxy = gio.DBusProxy.newForBusFinish(result, &err);
        if (err) |e| e.free();
        if (!self.running) {
            if (proxy) |p| p.unref();
            return;
        }
        self.proxy = proxy;
        if (proxy) |p| {
            p.getConnection().setExitOnClose(0);
            self.signals[0] = object.Object.signals.notify.connect(p.as(object.Object), *Peer, ownerChanged, self, .{ .detail = "g-name-owner" });
            self.signals[1] = gio.DBusConnection.signals.closed.connect(p.getConnection(), *Peer, closed, self, .{});
            self.ownerUpdate();
        } else self.arm(3000);
    }
    pub fn connection(self: *Peer) ?*gio.DBusConnection {
        return if (self.proxy) |p| p.getConnection() else null;
    }
    fn clear(self: *Peer) void {
        self.epoch += 1;
        // Cancel obsolete calls now; owner churn must not retain 90-second jobs.
        if (self.running) {
            self.cancel.cancel();
            self.cancel.unref();
            self.cancel = gio.Cancellable.new();
        }
        self.err = null;
        self.owner = .{};
        self.loading = false;
        if (self.snapshot) |v| v.unref();
        self.snapshot = null;
        if (self.subscription != 0) self.connection().?.signalUnsubscribe(self.subscription);
        self.subscription = 0;
        self.changed(self.context, true);
    }
    fn close(self: *Peer) void {
        self.clear();
        if (self.proxy) |p| {
            object.signalHandlerDisconnect(p.as(object.Object), self.signals[0]);
            object.signalHandlerDisconnect(p.getConnection().as(object.Object), self.signals[1]);
            p.unref();
        }
        self.proxy = null;
    }
    pub fn stop(self: *Peer) void {
        self.running = false;
        self.cancel.cancel();
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.timer = 0;
        self.close();
        self.cancel.unref();
    }
    fn closed(_: *gio.DBusConnection, _: c_int, _: ?*glib.Error, self: *Peer) callconv(.c) void {
        self.close();
        if (self.running) self.arm(3000);
    }
    fn ownerChanged(_: *object.Object, _: *object.ParamSpec, self: *Peer) callconv(.c) void {
        self.ownerUpdate();
    }
    fn ownerUpdate(self: *Peer) void {
        const raw = self.proxy.?.getNameOwner();
        defer if (raw) |s| glib.free(s);
        const name = if (raw) |s| std.mem.span(s) else "";
        if (std.mem.eql(u8, name, self.owner.slice())) return;
        self.clear();
        self.owner.set(name);
        if (name.len != 0) {
            self.subscription = self.connection().?.signalSubscribe(self.owner.z(), null, null, null, null, .{}, signal, self, null);
            self.changed(self.context, true);
            if (self.managed) self.refresh();
        }
    }
    fn signal(_: *gio.DBusConnection, _: ?[*:0]const u8, object_path: [*:0]const u8, iface: [*:0]const u8, method: [*:0]const u8, params: *glib.Variant, data: ?*anyopaque) callconv(.c) void {
        const self: *Peer = @ptrCast(@alignCast(data.?));
        if (self.invalidated) |notify| notify(self.context, std.mem.span(object_path), std.mem.span(iface), std.mem.span(method));
        if (self.signal_received) |notify| notify(self.context, std.mem.span(object_path), std.mem.span(iface), std.mem.span(method), params);
        if (self.managed) self.refresh();
    }
    pub fn refresh(self: *Peer) void {
        self.dirty = true;
        self.arm(100);
    }
    fn arm(self: *Peer, delay: c_uint) void {
        if (self.running and self.timer == 0) self.timer = glib.timeoutAdd(delay, tick, self);
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Peer = @ptrCast(@alignCast(data.?));
        self.timer = 0;
        if (self.proxy == null) {
            self.create();
        } else if (self.owner.len != 0 and !self.loading and self.dirty) {
            self.dirty = false;
            self.loading = true;
            self.call(0, self.root, "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", null, "(a{oa{sa{sv}}})", 5000, snapshotDone) catch {
                self.loading = false;
                self.err = "Could not read the service state.";
                self.dirty = true;
                self.arm(3000);
            };
        }
        return 0;
    }
    fn snapshotDone(data: *anyopaque, _: u64, result: ?*glib.Variant, err: ?[]const u8) void {
        const self: *Peer = @ptrCast(@alignCast(data));
        self.loading = false;
        if (result) |v| {
            const items = v.getChildValue(0);
            if (items.getSize() > 2 * 1024 * 1024 or items.nChildren() > 512) {
                items.unref();
                self.err = "Service object limit exceeded.";
                if (self.snapshot) |old| old.unref();
                self.snapshot = null;
            } else {
                if (self.snapshot) |old| old.unref();
                self.snapshot = items;
                self.err = null;
            }
        } else {
            _ = err;
            if (self.snapshot) |old| old.unref();
            self.snapshot = null;
            self.err = "Service state unavailable; retrying.";
            self.dirty = true;
            self.arm(3000);
        }
        self.changed(self.context, false);
        if (self.dirty) self.arm(100);
    }
    pub fn call(self: *Peer, token: u64, object_path: [:0]const u8, iface: [:0]const u8, method: [:0]const u8, params: ?*glib.Variant, signature: [:0]const u8, timeout: c_int, done: Done) !void {
        if (params) |v| _ = v.refSink();
        defer if (params) |v| v.unref();
        if (!self.running or self.owner.len == 0) return error.Unavailable;
        const job = try a.create(Job);
        job.* = .{ .peer = self, .epoch = self.epoch, .token = token, .done = done };
        self.app.hold();
        const t = glib.VariantType.new(signature);
        defer t.free();
        self.connection().?.call(self.owner.z(), object_path, iface, method, params, t, .{ .no_auto_start = true }, timeout, self.cancel, called, job);
    }
    fn called(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(data.?));
        const self = job.peer;
        defer a.destroy(job);
        defer self.app.release();
        var err: ?*glib.Error = null;
        const value = object.ext.cast(gio.DBusConnection, source.?).?.callFinish(result, &err);
        defer if (value) |v| v.unref();
        defer if (err) |e| e.free();
        if (!self.running or job.epoch != self.epoch) return;
        const remote = if (err) |e| (if (gio.DBusError.isRemoteError(e) != 0) gio.DBusError.getRemoteError(e) else null) else null;
        defer if (remote) |name| glib.free(name);
        job.done(if (job.done == snapshotDone) self else self.context, job.token, value, if (err != null) (if (remote) |name| std.mem.span(name) else "transport") else null);
    }
};
pub fn is(v: *glib.Variant, signature: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(v.getTypeString()), signature);
}
pub fn lookup(v: *glib.Variant, key: [:0]const u8, signature: []const u8) ?*glib.Variant {
    const f: *const fn (*glib.Variant, [*:0]const u8, ?*const glib.VariantType) callconv(.c) ?*glib.Variant = @ptrCast(&glib.Variant.lookupValue);
    const result = f(v, key, null) orelse return null;
    if (is(result, signature)) return result;
    result.unref();
    return null;
}
pub fn string(v: *glib.Variant, key: [:0]const u8, signature: []const u8) Text(512) {
    var out: Text(512) = .{};
    const child = lookup(v, key, signature) orelse return out;
    defer child.unref();
    const s = std.mem.span(child.getString(null));
    if (s.len <= 512) out.set(s);
    return out;
}
pub fn number(v: *glib.Variant, key: [:0]const u8) u32 {
    const child = lookup(v, key, "u") orelse return 0;
    defer child.unref();
    return child.getUint32();
}
pub fn boolean(v: *glib.Variant, key: [:0]const u8) bool {
    const child = lookup(v, key, "b") orelse return false;
    defer child.unref();
    return child.getBoolean() != 0;
}
pub fn tuple(values: []const *glib.Variant) *glib.Variant {
    return glib.Variant.newTuple(values.ptr, values.len);
}
pub fn array(signature: [:0]const u8, values: []const *glib.Variant) *glib.Variant {
    const t = glib.VariantType.new(signature);
    defer t.free();
    return glib.Variant.newArray(t, values.ptr, values.len);
}
pub fn entry(key: [:0]const u8, value: *glib.Variant) *glib.Variant {
    return glib.Variant.newDictEntry(glib.Variant.newString(key), glib.Variant.newVariant(value));
}
pub fn section(key: [:0]const u8, values: []const *glib.Variant) *glib.Variant {
    return glib.Variant.newDictEntry(glib.Variant.newString(key), array("{sv}", values));
}
pub fn path(value: [:0]const u8) *glib.Variant {
    return glib.Variant.newObjectPath(value);
}
pub fn str(value: [:0]const u8) *glib.Variant {
    return glib.Variant.newString(value);
}
pub const Export = struct {
    connection: ?*gio.DBusConnection = null,
    node: ?*gio.DBusNodeInfo = null,
    id: c_uint = 0,
    pub fn start(self: *Export, peer: *Peer, object_path: [:0]const u8, xml: [:0]const u8, vtable: *const gio.DBusInterfaceVTable, data: *anyopaque) bool {
        return self.startConnection(peer.connection() orelse return false, object_path, xml, vtable, data);
    }
    pub fn startConnection(self: *Export, conn: *gio.DBusConnection, object_path: [:0]const u8, xml: [:0]const u8, vtable: *const gio.DBusInterfaceVTable, data: *anyopaque) bool {
        self.stop();
        const node = gio.DBusNodeInfo.newForXml(xml, null) orelse return false;
        self.node = node;
        conn.ref();
        self.connection = conn;
        self.id = conn.registerObject(object_path, node.f_interfaces.?[0].?, vtable, data, noFree, null);
        return self.id != 0;
    }
    fn noFree(_: ?*anyopaque) callconv(.c) void {}
    pub fn stop(self: *Export) void {
        if (self.connection) |conn| {
            if (self.id != 0) _ = conn.unregisterObject(self.id);
            conn.unref();
        }
        if (self.node) |node| node.unref();
        self.* = .{};
    }
};
