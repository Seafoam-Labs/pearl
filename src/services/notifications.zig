const std = @import("std");
const transport = @import("session_bus.zig");
const db = transport.db;
const gio = db.gio;
const glib = db.glib;
pub const policy = @import("notification_policy.zig");
const name = "org.freedesktop.Notifications";
const path = "/org/freedesktop/Notifications";
pub const Notifications = struct {
    bus: *transport.Bus,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    model: policy.Model = .{},
    exported: db.Export = .{},
    name_id: c_uint = 0,
    available: bool = false,
    timer: c_uint = 0,
    pub fn start(self: *Notifications) void {
        if (!self.exported.startConnection(self.bus.conn orelse return, path, @embedFile("notifications.xml"), &vtable, self)) return;
        self.name_id = gio.busOwnNameOnConnection(self.bus.conn.?, name, .{}, acquired, lost, self, null);
    }
    pub fn stop(self: *Notifications) void {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.timer = 0;
        if (self.name_id != 0) gio.busUnownName(self.name_id);
        self.name_id = 0;
        self.available = false;
        self.exported.stop();
        for (&self.model.records) |*r| if (r.active) { _ = self.model.close(r.id); };
        self.changed(self.context);
    }
    fn acquired(_: *gio.DBusConnection, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Notifications = @ptrCast(@alignCast(data.?));
        self.available = true; self.changed(self.context);
    }
    fn lost(_: *gio.DBusConnection, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Notifications = @ptrCast(@alignCast(data.?));
        self.available = false; self.model.suppress(); self.changed(self.context);
    }
    pub fn setDnd(self: *Notifications, value: bool) void {
        self.model.dnd = value;
        if (value) self.model.suppress();
        self.update();
    }
    pub fn setLocked(self: *Notifications, value: bool) void {
        if (self.model.locked == value) return;
        self.model.locked = value;
        if (value) self.model.suppress();
        self.update();
    }
    pub fn close(self: *Notifications, id: u32, reason: u32) bool {
        const r = self.model.find(id) orelse return false;
        const owner = r.owner;
        if (!self.model.close(id)) return false;
        self.bus.emit(owner.z(), path, name, "NotificationClosed", db.tuple(&.{glib.Variant.newUint32(id), glib.Variant.newUint32(reason)}));
        self.update();
        return true;
    }
    pub fn invoke(self: *Notifications, id: u32, key: []const u8) !void {
        if (!self.available or self.model.locked) return error.Unavailable;
        const r = self.model.find(id) orelse return error.InvalidValue;
        if (!r.active) return error.InvalidValue;
        for (r.actions[0..r.action_count]) |action| if (std.mem.eql(u8, key, action.key.slice())) {
            self.bus.emit(r.owner.z(), path, name, "ActionInvoked", db.tuple(&.{glib.Variant.newUint32(id), db.str(action.key.z())}));
            if (!r.resident) _ = self.close(id, 2);
            return;
        };
        return error.InvalidValue;
    }
    pub fn update(self: *Notifications) void {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.timer = 0;
        const now = glib.getMonotonicTime();
        var next: i64 = std.math.maxInt(i64);
        for (&self.model.records) |*r| {
            if (r.deadline > 0) next = @min(next, r.deadline);
            if (r.toast_until > 0) next = @min(next, r.toast_until);
        }
        if (next != std.math.maxInt(i64) and self.available) self.timer = glib.timeoutAdd(@intCast(@min(std.math.maxInt(u32), @max(1, @divTrunc(next - now + 999, 1000)))), tick, self);
        self.changed(self.context);
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Notifications = @ptrCast(@alignCast(data.?));
        self.timer = 0;
        const now = glib.getMonotonicTime();
        for (&self.model.records) |*r| {
            if (r.active and r.deadline > 0 and r.deadline <= now) { _ = self.close(r.id, 1); continue; }
            if (r.toast_until > 0 and r.toast_until <= now) { r.toast_until = 0; self.model.serial += 1; }
        }
        self.update(); return 0;
    }
    const vtable: gio.DBusInterfaceVTable = .{ .f_method_call = method, .f_get_property = null, .f_set_property = null, .f_padding = @splat(undefined) };
    fn method(_: *gio.DBusConnection, sender: ?[*:0]const u8, _: [*:0]const u8, _: ?[*:0]const u8, member: [*:0]const u8, params: *glib.Variant, invocation: *gio.DBusMethodInvocation, data: ?*anyopaque) callconv(.c) void {
        const self: *Notifications = @ptrCast(@alignCast(data.?));
        if (!self.available) { invocation.returnDbusError("org.freedesktop.DBus.Error.NotSupported", "Another notification service owns the name."); return; }
        const m = std.mem.span(member);
        if (std.mem.eql(u8, m, "GetCapabilities")) {
            invocation.returnValue(db.tuple(&.{db.array("s", &.{ db.str("body"), db.str("actions"), db.str("persistence") })}));
        } else if (std.mem.eql(u8, m, "GetServerInformation")) {
            invocation.returnValue(db.tuple(&.{ db.str("Pearl"), db.str("Aqueous"), db.str("0.1.0"), db.str("1.2") }));
        } else if (std.mem.eql(u8, m, "CloseNotification")) {
            const v = params.getChildValue(0); defer v.unref();
            const r = self.model.find(v.getUint32());
            if (r == null or !std.mem.eql(u8, r.?.owner.slice(), if (sender) |s| std.mem.span(s) else "") or !self.close(v.getUint32(), 3)) {
                invocation.returnDbusError("org.freedesktop.DBus.Error.InvalidArgs", "No active notification for this sender."); return;
            }
            invocation.returnValue(null);
        } else if (std.mem.eql(u8, m, "Notify")) {
            if (params.getSize() > 64 * 1024) { invocation.returnDbusError("org.freedesktop.DBus.Error.LimitsExceeded", "Notification exceeds 64 KiB."); return; }
            var r: policy.Record = .{};
            r.owner.set(if (sender) |s| std.mem.span(s) else "");
            inline for (.{ .{0, "app", 160}, .{2, "icon", 160}, .{3, "summary", 256}, .{4, "body", 2048} }) |field| {
                const v = params.getChildValue(field[0]); defer v.unref();
                @field(r, field[1]) = policy.sanitize(field[2], std.mem.span(v.getString(null)));
            }
            // Only themed names, never remote URLs or arbitrary paths.
            for (r.icon.slice()) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) { r.icon = .{}; break; };
            const actions = params.getChildValue(5); defer actions.unref();
            if (actions.nChildren() % 2 != 0 or actions.nChildren() > 16) { invocation.returnDbusError("org.freedesktop.DBus.Error.InvalidArgs", "At most eight action pairs are supported."); return; }
            var i: usize = 0;
            while (i < actions.nChildren()) : (i += 2) {
                const key = transport.childText(96, actions, i);
                const label = transport.childText(160, actions, i + 1);
                r.actions[r.action_count] = .{ .key = key, .label = policy.sanitize(160, label.slice()) }; r.action_count += 1;
            }
            const hints = params.getChildValue(6); defer hints.unref();
            r.transient = db.boolean(hints, "transient"); r.resident = db.boolean(hints, "resident");
            if (db.lookup(hints, "urgency", "y")) |v| { defer v.unref(); r.urgency = @min(2, v.getByte()); }
            const replace = params.getChildValue(1); defer replace.unref();
            const timeout = params.getChildValue(7); defer timeout.unref();
            const record = self.model.add(r, replace.getUint32(), timeout.getInt32(), glib.getMonotonicTime()) catch {
                invocation.returnDbusError("org.freedesktop.DBus.Error.LimitsExceeded", "Active notification limit reached."); return;
            };
            invocation.returnValue(db.tuple(&.{glib.Variant.newUint32(record.id)}));
            self.update();
        } else invocation.returnDbusError("org.freedesktop.DBus.Error.UnknownMethod", "Unknown method.");
    }
};
