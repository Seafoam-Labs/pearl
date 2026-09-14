//! logind controls: only explicit yes capability, no interactive authorization.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
pub const Power = struct {
    bus: ?*gio.DBusConnection = null,
    reboot: bool = false,
    off: bool = false,
    pending: bool = false,
    completed: bool = false,
    failed: bool = false,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    pub fn init(self: *Power) void {
        gio.busGet(.system, null, connected, self);
    }
    fn connected(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Power = @ptrCast(@alignCast(data.?));
        self.bus = gio.busGetFinish(result, null);
        if (self.bus) |bus| {
            bus.call("org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "CanReboot", null, null, .{ .no_auto_start = true }, 2000, null, capabilityReboot, self);
            bus.call("org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "CanPowerOff", null, null, .{ .no_auto_start = true }, 2000, null, capabilityOff, self);
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
    pub fn request(self: *Power, reboot: bool) !void {
        if (self.pending or self.completed or self.bus == null or !(if (reboot) self.reboot else self.off)) return error.PowerDenied;
        self.pending = true;
        self.failed = false;
        const args = [_]*glib.Variant{glib.Variant.newBoolean(0)};
        self.bus.?.call("org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", if (reboot) "Reboot" else "PowerOff", glib.Variant.newTuple(&args, args.len), null, .{ .no_auto_start = true }, 5000, null, finished, self);
    }
    fn finished(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Power = @ptrCast(@alignCast(data.?));
        self.pending = false;
        if (self.bus.?.callFinish(result, null)) |answer| {
            self.completed = std.mem.eql(u8, std.mem.span(answer.getTypeString()), "()");
            answer.unref();
            self.failed = !self.completed;
        } else self.failed = true;
        if (self.failed) {
            self.reboot = false;
            self.off = false;
        }
        self.changed(self.context);
    }
};
