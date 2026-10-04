const std = @import("std");
const transport = @import("session_bus.zig");
const db = transport.db;
const gio = db.gio;
const glib = db.glib;
const pixbuf = @import("gdkpixbuf2");
const icon_image = @import("notification_image.zig");
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
    filters: ?@import("notification_filter_policy.zig").Compiled = null,
    /// Pixels live outside the pure model: it is imported by the GObject-free test root.
    /// One slot per retained record, pruned against the model on every mutation.
    images: [64]struct { id: u32 = 0, pixels: ?*pixbuf.Pixbuf = null } = @splat(.{}),
    pub fn configure(self: *Notifications, config: @import("notification_filter_policy.zig").Config) !void {
        const next = try @import("notification_filter_policy.zig").Compiled.init(std.heap.c_allocator, config);
        if (self.filters) |*old| old.deinit();
        self.filters = next;
        if (self.name_id == 0 and self.bus.conn != null) self.start();
    }
    pub fn deinitFilters(self: *Notifications) void {
        if (self.filters) |*old| old.deinit();
        self.filters = null;
    }

    pub fn start(self: *Notifications) void {
        if (self.filters == null or self.name_id != 0) return;
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
        for (&self.model.records) |*r| if (r.active) {
            _ = self.model.close(r.id);
        };
        self.pruneImages();
        self.changed(self.context);
    }
    fn acquired(_: *gio.DBusConnection, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Notifications = @ptrCast(@alignCast(data.?));
        self.available = true;
        self.changed(self.context);
    }
    fn lost(_: *gio.DBusConnection, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Notifications = @ptrCast(@alignCast(data.?));
        self.available = false;
        self.model.suppress();
        self.changed(self.context);
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
        self.bus.emit(owner.z(), path, name, "NotificationClosed", db.tuple(&.{ glib.Variant.newUint32(id), glib.Variant.newUint32(reason) }));
        self.update();
        return true;
    }
    pub fn invoke(self: *Notifications, id: u32, key: []const u8) !void {
        if (!self.available or self.model.locked) return error.Unavailable;
        const r = self.model.find(id) orelse return error.InvalidValue;
        if (!r.active) return error.InvalidValue;
        const stored = for (r.actions[0..r.action_count]) |action| {
            if (std.mem.eql(u8, key, action.key.slice())) break action.key.z();
        } else if (r.default_key.len != 0 and std.mem.eql(u8, key, r.default_key.slice())) r.default_key.z() else return error.InvalidValue;
        self.bus.emit(r.owner.z(), path, name, "ActionInvoked", db.tuple(&.{ glib.Variant.newUint32(id), db.str(stored) }));
        if (!r.resident) _ = self.close(id, 2);
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
        self.pruneImages();
        self.changed(self.context);
    }
    pub fn imageFor(self: *Notifications, id: u32) ?*pixbuf.Pixbuf {
        if (id == 0) return null;
        for (&self.images) |slot| if (slot.id == id) return slot.pixels;
        return null;
    }
    /// Replacement reuses the id, so an insert overwrites the slot instead of appending.
    fn putImage(self: *Notifications, id: u32, pixels: ?*pixbuf.Pixbuf) void {
        for (&self.images) |*slot| if (slot.id == id) {
            if (slot.pixels) |old| old.unref();
            slot.pixels = pixels;
            return;
        };
        const kept = pixels orelse return;
        for (&self.images) |*slot| if (slot.id == 0) {
            slot.* = .{ .id = id, .pixels = kept };
            return;
        };
        kept.unref();
    }
    fn pruneImages(self: *Notifications) void {
        for (&self.images) |*slot| if (slot.id != 0 and self.model.find(slot.id) == null) {
            if (slot.pixels) |old| old.unref();
            slot.* = .{};
        };
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Notifications = @ptrCast(@alignCast(data.?));
        self.timer = 0;
        const now = glib.getMonotonicTime();
        for (&self.model.records) |*r| {
            if (r.active and r.deadline > 0 and r.deadline <= now) {
                _ = self.close(r.id, 1);
                continue;
            }
            if (r.toast_until > 0 and r.toast_until <= now) {
                r.toast_until = 0;
                self.model.serial += 1;
            }
        }
        self.update();
        return 0;
    }
    const vtable: gio.DBusInterfaceVTable = .{ .f_method_call = method, .f_get_property = null, .f_set_property = null, .f_padding = @splat(undefined) };
    fn method(_: *gio.DBusConnection, sender: ?[*:0]const u8, _: [*:0]const u8, _: ?[*:0]const u8, member: [*:0]const u8, params: *glib.Variant, invocation: *gio.DBusMethodInvocation, data: ?*anyopaque) callconv(.c) void {
        const self: *Notifications = @ptrCast(@alignCast(data.?));
        if (!self.available) {
            invocation.returnDbusError("org.freedesktop.DBus.Error.NotSupported", "Another notification service owns the name.");
            return;
        }
        const m = std.mem.span(member);
        if (std.mem.eql(u8, m, "GetCapabilities")) {
            invocation.returnValue(db.tuple(&.{db.array("s", &.{ db.str("body"), db.str("actions"), db.str("persistence"), db.str("icon-static") })}));
        } else if (std.mem.eql(u8, m, "GetServerInformation")) {
            invocation.returnValue(db.tuple(&.{ db.str("Pearl"), db.str("Aqueous"), db.str(@import("../version.zig").string), db.str("1.2") }));
        } else if (std.mem.eql(u8, m, "CloseNotification")) {
            const v = params.getChildValue(0);
            defer v.unref();
            const r = self.model.find(v.getUint32());
            if (r == null or !std.mem.eql(u8, r.?.owner.slice(), if (sender) |s| std.mem.span(s) else "") or !self.close(v.getUint32(), 3)) {
                invocation.returnDbusError("org.freedesktop.DBus.Error.InvalidArgs", "No active notification for this sender.");
                return;
            }
            invocation.returnValue(null);
        } else if (std.mem.eql(u8, m, "Notify")) {
            var r: policy.Record = .{};
            r.owner.set(if (sender) |s| std.mem.span(s) else "");
            inline for (.{ .{ 0, "app", 160 }, .{ 3, "summary", 256 }, .{ 4, "body", 2048 } }) |field| {
                const v = params.getChildValue(field[0]);
                defer v.unref();
                @field(r, field[1]) = policy.sanitize(field[2], std.mem.span(v.getString(null)));
            }
            // Read raw: resolution below admits only [0-9A-Za-z._-] for a themed name,
            // a strict subset of what sanitize passes through unchanged.
            const app_icon = params.getChildValue(2);
            defer app_icon.unref();
            const actions = params.getChildValue(5);
            defer actions.unref();
            if (actions.nChildren() % 2 != 0 or actions.nChildren() > 16) {
                invocation.returnDbusError("org.freedesktop.DBus.Error.InvalidArgs", "At most eight action pairs are supported.");
                return;
            }
            var i: usize = 0;
            while (i < actions.nChildren()) : (i += 2) {
                const raw_label = transport.childText(160, actions, i + 1);
                const caption = policy.sanitize(160, raw_label.slice());
                const raw_key = actions.getChildValue(i);
                defer raw_key.unref();
                const key_slice = std.mem.span(raw_key.getString(null));
                const kind = policy.pairAction(key_slice, caption.slice());
                // Classified before the key bounds: those reject the whole notification, and a
                // pair that is about to be discarded must not be able to fail it.
                if (kind == .skip) continue;
                if (key_slice.len == 0 or key_slice.len > 96) {
                    invocation.returnDbusError("org.freedesktop.DBus.Error.InvalidArgs", "Action keys must contain 1–96 bytes.");
                    return;
                }
                const key = transport.childText(96, actions, i);
                if (kind == .render) {
                    for (r.actions[0..r.action_count]) |old| if (std.mem.eql(u8, old.key.slice(), key_slice)) {
                        invocation.returnDbusError("org.freedesktop.DBus.Error.InvalidArgs", "Action keys must be unique.");
                        return;
                    };
                    r.actions[r.action_count] = .{ .key = key, .label = caption };
                    r.action_count += 1;
                }
                // One owner for the reserved key, whether or not its caption rendered.
                if (std.mem.eql(u8, key_slice, "default")) {
                    if (r.default_key.len != 0) {
                        invocation.returnDbusError("org.freedesktop.DBus.Error.InvalidArgs", "Action keys must be unique.");
                        return;
                    }
                    r.default_key = key;
                }
            }
            const hints = params.getChildValue(6);
            defer hints.unref();
            r.transient = db.boolean(hints, "transient");
            r.resident = db.boolean(hints, "resident");
            if (db.lookup(hints, "urgency", "y")) |v| {
                defer v.unref();
                r.urgency = @min(2, v.getByte());
            }
            if (db.lookup(hints, "desktop-entry", "s")) |v| {
                defer v.unref();
                const id = std.mem.span(v.getString(null));
                const filters = @import("notification_filter_policy.zig");
                if (filters.desktopId(id)) r.desktop_entry.set(filters.withoutSuffix(id));
            }
            const decision = if (self.filters) |*filters| (filters.evaluate(r) catch {
                invocation.returnDbusError("org.freedesktop.DBus.Error.Failed", "Notification filter evaluation failed.");
                return;
            }).decision else .normal;
            const replace = params.getChildValue(1);
            defer replace.unref();
            const timeout = params.getChildValue(7);
            defer timeout.unref();
            if (decision == .block) {
                const id = self.model.block(r.owner.slice(), replace.getUint32());
                invocation.returnValue(db.tuple(&.{glib.Variant.newUint32(id)}));
                self.bus.emit(r.owner.z(), path, name, "NotificationClosed", db.tuple(&.{ glib.Variant.newUint32(id), glib.Variant.newUint32(4) }));
                self.update();
                return;
            }
            r.history_only = decision == .history_only;
            const icon = resolveIcon(hints, std.mem.span(app_icon.getString(null)), &r);
            const record = self.model.add(r, replace.getUint32(), timeout.getInt32(), glib.getMonotonicTime()) catch {
                if (icon) |pixels| pixels.unref();
                invocation.returnDbusError("org.freedesktop.DBus.Error.LimitsExceeded", "Active notification limit reached.");
                return;
            };
            self.putImage(record.id, icon);
            invocation.returnValue(db.tuple(&.{glib.Variant.newUint32(record.id)}));
            self.update();
        } else invocation.returnDbusError("org.freedesktop.DBus.Error.UnknownMethod", "Unknown method.");
    }
    /// First usable candidate wins; a rejected one falls through to the next.
    fn resolveIcon(hints: *glib.Variant, app_icon: [:0]const u8, r: *policy.Record) ?*pixbuf.Pixbuf {
        if (db.lookup(hints, "image-data", "(iiibiiay)")) |v| {
            defer v.unref();
            if (icon_image.fromHint(v)) |pixels| return pixels;
        }
        for ([_][:0]const u8{ "image-path", "image_path" }) |key| {
            if (db.lookup(hints, key, "s")) |v| {
                defer v.unref();
                if (claim(icon_image.resolve(std.mem.span(v.getString(null))), r)) |pixels| return pixels;
                if (r.icon.len != 0) return null;
            }
        }
        if (db.lookup(hints, "icon_data", "(iiibiiay)")) |v| {
            defer v.unref();
            if (icon_image.fromHint(v)) |pixels| return pixels;
        }
        return claim(icon_image.resolve(app_icon), r);
    }
    fn claim(value: icon_image.Resolved, r: *policy.Record) ?*pixbuf.Pixbuf {
        return switch (value) {
            .pixels => |pixels| pixels,
            .themed => |themed| {
                r.icon = themed;
                return null;
            },
            .none => null,
        };
    }
};
