//! logind controls for the locked session: only explicit yes capability, no
//! interactive authorization. Same policy as the greeter's power service,
//! plus suspend; a completed suspend must not lock out later requests.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const options = @import("build_options");
pub const Action = enum { reboot, off, sleep };
pub const Power = struct {
    bus: ?*gio.DBusConnection = null,
    reboot: bool = false,
    off: bool = false,
    sleep: bool = false,
    on_battery: bool = false,
    pending: bool = false,
    failed: bool = false,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    pub fn init(self: *Power) void {
        // A private fixture session is not a logind session, so every capability
        // resolves to "no" and the cluster is inert there. Advertise them on
        // request, but stay off the bus: request() must keep failing so a suite
        // can never reboot or power off the machine it runs on.
        if (options.test_hooks and glib.getenv("PEARL_TEST_LOCK_POWER") != null) {
            self.reboot = true;
            self.off = true;
            self.sleep = true;
            self.changed(self.context);
            return;
        }
        gio.busGet(.system, null, connected, self);
    }
    fn connected(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Power = @ptrCast(@alignCast(data.?));
        self.bus = gio.busGetFinish(result, null);
        if (self.bus) |bus| {
            bus.call("org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "CanReboot", null, null, .{ .no_auto_start = true }, 2000, null, capabilityReboot, self);
            bus.call("org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "CanPowerOff", null, null, .{ .no_auto_start = true }, 2000, null, capabilityOff, self);
            bus.call("org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "CanSuspend", null, null, .{ .no_auto_start = true }, 2000, null, capabilitySuspend, self);
            // The lock owns screen blanking while held, so it must know which
            // idle profile applies; UPower's OnBattery is the same source the
            // shell's power service uses.
            const get = [_]*glib.Variant{ glib.Variant.newString("org.freedesktop.UPower"), glib.Variant.newString("OnBattery") };
            bus.call("org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.DBus.Properties", "Get", glib.Variant.newTuple(&get, get.len), null, .{ .no_auto_start = true }, 2000, null, batteryReply, self);
        }
    }
    fn yes(self: *Power, result: *gio.AsyncResult) bool {
        const answer = self.bus.?.callFinish(result, null) orelse return false;
        defer answer.unref();
        if (!std.mem.eql(u8, std.mem.span(answer.getTypeString()), "(s)")) return false;
        const value = answer.getChildValue(0);
        defer value.unref();
        return std.mem.eql(u8, std.mem.span(value.getString(null)), "yes");
    }
    fn capabilityReboot(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const s: *Power = @ptrCast(@alignCast(data.?));
        s.reboot = s.yes(result);
        s.changed(s.context);
    }
    fn capabilityOff(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const s: *Power = @ptrCast(@alignCast(data.?));
        s.off = s.yes(result);
        s.changed(s.context);
    }
    fn capabilitySuspend(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const s: *Power = @ptrCast(@alignCast(data.?));
        s.sleep = s.yes(result);
        s.changed(s.context);
    }
    fn batteryReply(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const s: *Power = @ptrCast(@alignCast(data.?));
        const answer = s.bus.?.callFinish(result, null) orelse return;
        defer answer.unref();
        if (!std.mem.eql(u8, std.mem.span(answer.getTypeString()), "(v)")) return;
        const boxed = answer.getChildValue(0);
        defer boxed.unref();
        const value = boxed.getVariant();
        defer value.unref();
        if (!std.mem.eql(u8, std.mem.span(value.getTypeString()), "b")) return;
        const on_battery = value.getBoolean() != 0;
        if (on_battery == s.on_battery) return;
        s.on_battery = on_battery;
        s.changed(s.context);
    }
    pub fn request(self: *Power, action: Action) !void {
        const allowed = switch (action) {
            .reboot => self.reboot,
            .off => self.off,
            .sleep => self.sleep,
        };
        if (self.pending or self.bus == null or !allowed) return error.PowerDenied;
        self.pending = true;
        self.failed = false;
        const method = switch (action) {
            .reboot => "Reboot",
            .off => "PowerOff",
            .sleep => "Suspend",
        };
        const args = [_]*glib.Variant{glib.Variant.newBoolean(0)};
        self.bus.?.call("org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", method, glib.Variant.newTuple(&args, args.len), null, .{ .no_auto_start = true }, 5000, null, finished, self);
    }
    fn finished(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Power = @ptrCast(@alignCast(data.?));
        self.pending = false;
        var completed = false;
        if (self.bus.?.callFinish(result, null)) |answer| {
            completed = std.mem.eql(u8, std.mem.span(answer.getTypeString()), "()");
            answer.unref();
        }
        self.failed = !completed;
        if (self.failed) {
            self.reboot = false;
            self.off = false;
            self.sleep = false;
        }
        self.changed(self.context);
    }
};
