//! Scheduling profiles applied through scx.service. Pearl watches the unit over
//! systemd's D-Bus API, so state changes arrive without polling, and changes it
//! only through pearl-scheduling-helper.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const p = @import("sched_profiles.zig");
const store = @import("sched_profiles_store.zig");
const Kernel = p.Kernel;
const log = std.log.scoped(.services);
const a = std.heap.c_allocator;
const systemd = "org.freedesktop.systemd1";

pub const Service = struct {
    app: *gio.Application,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    /// Changes are allowed only while the session is unlocked and ready.
    enabled: bool = false,
    /// Only the shell reports failures, so Settings does not duplicate them.
    notify: bool = true,
    running: bool = false,
    cancel: ?*gio.Cancellable = null,
    manager: ?*gio.DBusProxy = null,
    unit: ?*gio.DBusProxy = null,
    unit_signal: c_ulong = 0,
    arena: std.heap.ArenaAllocator = .init(a),
    /// Null when no profile file is installed or it is invalid.
    config: ?p.Config = null,
    /// Why the profile file could not be used.
    problem: ?[:0]const u8 = null,
    env: p.Env = .{},
    status: p.Status = .{},
    unit_state: p.Unit = .unknown,
    kernel: Kernel = .unavailable,
    /// Profile id being applied; the helper is still running.
    applying: ?[]const u8 = null,
    applying_buffer: [32]u8 = undefined,
    err: ?[:0]const u8 = null,
    err_buffer: [512]u8 = undefined,
    /// Rechecks while a scheduler attaches; the kernel side has no signal.
    settle_source: c_uint = 0,
    settle_attempts: u8 = 0,
    /// A failure is reported once, after it outlasts a restart's brief gap.
    failure_source: c_uint = 0,
    notified: bool = false,

    pub fn start(self: *Service) void {
        self.running = true;
        self.cancel = gio.Cancellable.new();
        self.refresh();
        self.app.hold();
        gio.DBusProxy.newForBus(.system, .{ .do_not_load_properties = true }, null, systemd, "/org/freedesktop/systemd1", systemd ++ ".Manager", self.cancel, managerReady, self);
    }

    pub fn stop(self: *Service) void {
        self.running = false;
        if (self.settle_source != 0) _ = glib.Source.remove(self.settle_source);
        if (self.failure_source != 0) _ = glib.Source.remove(self.failure_source);
        self.settle_source = 0;
        self.failure_source = 0;
        if (self.cancel) |cancel| {
            cancel.cancel();
            cancel.unref();
        }
        self.cancel = null;
        if (self.unit) |proxy| {
            object.signalHandlerDisconnect(proxy.as(object.Object), self.unit_signal);
            proxy.unref();
        }
        if (self.manager) |proxy| proxy.unref();
        self.unit = null;
        self.manager = null;
        self.arena.deinit();
    }

    pub fn configured(self: *const Service) bool {
        return self.config != null or self.problem != null;
    }

    /// Reread the profile file, /etc/default/scx and sched_ext state, and
    /// combine them with the unit state last reported by systemd.
    pub fn refresh(self: *Service) void {
        _ = self.arena.reset(.retain_capacity);
        const alloc = self.arena.allocator();
        self.config = null;
        self.problem = null;
        if (store.load(alloc)) |loaded| {
            if (loaded) |file| self.config = file.config;
        } else |err| {
            self.problem = std.fmt.allocPrintSentinel(alloc, "Scheduler profiles could not be read ({s}).", .{@errorName(err)}, 0) catch "Scheduler profiles could not be read.";
        }
        self.env = store.readEnv(alloc) catch .{};
        self.kernel = kernelState();
        self.status = if (self.config) |config| p.status(config, self.env, self.unit_state, self.kernel) else .{};
        // A restart passes through inactive, and the file is written before
        // the unit restarts; report a failure only if it persists.
        if (self.status.kind != .failed) {
            self.notified = false;
            if (self.failure_source != 0) _ = glib.Source.remove(self.failure_source);
            self.failure_source = 0;
        } else if (!self.notified and self.applying == null and self.failure_source == 0) {
            self.failure_source = glib.timeoutAdd(3000, failureCheck, self);
        }
        if (self.status.kind == .starting) self.settle() else self.settle_attempts = 0;
        self.changed(self.context);
    }

    fn failureCheck(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data.?));
        self.failure_source = 0;
        // Every unit change already refreshed the status.
        if (self.status.kind == .failed and !self.notified and self.applying == null) {
            self.notified = true;
            self.notifyFailure();
        }
        return 0;
    }

    fn settle(self: *Service) void {
        if (self.settle_source != 0 or !self.running or self.settle_attempts >= 20) return;
        self.settle_attempts += 1;
        self.settle_source = glib.timeoutAdd(500, settled, self);
    }

    fn settled(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data.?));
        self.settle_source = 0;
        self.refresh();
        return 0;
    }

    pub fn apply(self: *Service, id: []const u8) !void {
        if (!self.running or !self.enabled) return error.Unavailable;
        if (self.applying != null) return error.Busy;
        const config = self.config orelse return error.Unavailable;
        _ = config.find(id) orelse return error.InvalidProfile;
        if (id.len > self.applying_buffer.len) return error.InvalidProfile;
        @memcpy(self.applying_buffer[0..id.len], id);
        const owned = try a.dupeZ(u8, id);
        defer a.free(owned);
        var argv = [_:null]?[*:0]const u8{ "/usr/bin/pkexec", store.helperPath(), "apply", owned };
        var err: ?*glib.Error = null;
        const process = gio.Subprocess.newv(@ptrCast(&argv), .{ .stdout_silence = true, .stderr_pipe = true }, &err) orelse {
            if (err) |e| e.free();
            return error.HelperUnavailable;
        };
        self.applying = self.applying_buffer[0..id.len];
        self.err = null;
        self.app.hold();
        process.communicateUtf8Async(null, self.cancel, applied, self);
        self.changed(self.context);
    }

    fn applied(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        const process = object.ext.cast(gio.Subprocess, source.?).?;
        defer process.unref();
        var stderr_buffer: [*:0]u8 = undefined;
        var err: ?*glib.Error = null;
        const finished = process.communicateUtf8Finish(result, null, &stderr_buffer, &err) != 0;
        const stderr: ?[*:0]u8 = if (finished) stderr_buffer else null;
        defer if (stderr) |text| glib.free(text);
        defer if (err) |e| e.free();
        if (!self.running) return;
        const id = self.applying orelse return;
        const succeeded = finished and process.getSuccessful() != 0;
        log.info("event=sched-profile-select profile={s} result={s}", .{ id, if (succeeded) "ok" else "failed" });
        if (!succeeded) {
            const detail = if (stderr) |text| std.mem.trim(u8, std.mem.span(text), " \r\n\t") else "";
            self.err = std.fmt.bufPrintZ(&self.err_buffer, "The profile could not be applied{s}{s}", .{ if (detail.len > 0) ": " else ".", detail[0..@min(detail.len, 400)] }) catch "The profile could not be applied.";
        }
        self.applying = null;
        self.refresh();
    }

    fn managerReady(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        var err: ?*glib.Error = null;
        const proxy = gio.DBusProxy.newForBusFinish(result, &err);
        defer if (err) |e| e.free();
        if (!self.running) {
            if (proxy) |value| value.unref();
            return;
        }
        self.manager = proxy orelse return log.warn("event=sched-profile-systemd result=unavailable", .{});
        // Unit property changes are only broadcast to subscribed clients.
        self.manager.?.call("Subscribe", null, .{}, -1, null, null, null);
        self.app.hold();
        self.manager.?.call("LoadUnit", tuple(&.{glib.Variant.newString("scx.service")}), .{}, 5000, self.cancel, unitLoaded, self);
    }

    fn unitLoaded(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        var err: ?*glib.Error = null;
        const reply = object.ext.cast(gio.DBusProxy, source.?).?.callFinish(result, &err);
        defer if (reply) |value| value.unref();
        defer if (err) |e| e.free();
        if (!self.running) return;
        const value = reply orelse return log.warn("event=sched-profile-systemd result=load-failed", .{});
        const child = value.getChildValue(0);
        defer child.unref();
        self.app.hold();
        gio.DBusProxy.newForBus(.system, .{ .get_invalidated_properties = true }, null, systemd, child.getString(null), systemd ++ ".Unit", self.cancel, unitReady, self);
    }

    fn unitReady(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        var err: ?*glib.Error = null;
        const proxy = gio.DBusProxy.newForBusFinish(result, &err);
        defer if (err) |e| e.free();
        if (!self.running) {
            if (proxy) |value| value.unref();
            return;
        }
        self.unit = proxy orelse return log.warn("event=sched-profile-systemd result=unit-unavailable", .{});
        self.unit_signal = gio.DBusProxy.signals.g_properties_changed.connect(self.unit.?, *Service, unitChanged, self, .{});
        self.readUnit();
        self.refresh();
    }

    fn unitChanged(_: *gio.DBusProxy, _: *glib.Variant, _: [*][*:0]u8, self: *Service) callconv(.c) void {
        self.readUnit();
        self.refresh();
    }

    fn readUnit(self: *Service) void {
        const proxy = self.unit orelse return;
        const load = proxy.getCachedProperty("LoadState");
        defer if (load) |value| value.unref();
        const active = proxy.getCachedProperty("ActiveState");
        defer if (active) |value| value.unref();
        self.unit_state = p.unitFrom(if (load) |value| std.mem.span(value.getString(null)) else "", if (active) |value| std.mem.span(value.getString(null)) else "");
    }

    fn notifyFailure(self: *Service) void {
        if (!self.notify) return;
        const config = self.config orelse return;
        const label = config.profiles[self.status.profile orelse return].label;
        var body: [256]u8 = undefined;
        const text = std.fmt.bufPrintZ(&body, "{s} stopped unexpectedly. The kernel's default scheduler is running; choose a profile to try again.", .{label}) catch return;
        log.warn("event=sched-profile-failed profile={s}", .{label});
        const connection = self.app.getDbusConnection() orelse return;
        const strings = glib.VariantType.new("s");
        defer strings.free();
        const hints = glib.VariantType.new("{sv}");
        defer hints.free();
        connection.call("org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify", tuple(&.{
            glib.Variant.newString("Pearl"),
            glib.Variant.newUint32(0),
            glib.Variant.newString("pearl-scheduler-symbolic"),
            glib.Variant.newString("CPU scheduler profile stopped"),
            glib.Variant.newString(text),
            glib.Variant.newArray(strings, null, 0),
            glib.Variant.newArray(hints, null, 0),
            glib.Variant.newInt32(-1),
        }), null, .{}, 3000, null, null, null);
    }
};

fn kernelState() Kernel {
    const fd = std.c.open("/sys/kernel/sched_ext/state", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return .unavailable;
    defer _ = std.c.close(fd);
    var buffer: [64]u8 = undefined;
    const n = std.c.read(fd, &buffer, buffer.len);
    if (n <= 0 or n == buffer.len) return .unknown;
    return std.meta.stringToEnum(Kernel, std.mem.trim(u8, buffer[0..@intCast(n)], "\r\n ")) orelse .unknown;
}

fn tuple(values: []const *glib.Variant) *glib.Variant {
    return glib.Variant.newTuple(values.ptr, values.len);
}
