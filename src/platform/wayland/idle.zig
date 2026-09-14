//! Compositor idle notifications respect ext-idle-inhibit. GTK owns dispatch.
const std = @import("std");
const gdk = @import("gdk4");
const object = @import("gobject2");
const backend = @import("gdkwayland4");
const wl = @import("wayland").client.wl;
const ext = @import("wayland").client.ext;
const Timeouts = @import("../../services/idle_policy.zig").Timeouts;
pub const Event = enum { lock, sleep, resumed, unavailable };
pub const Idle = struct {
    display: *gdk.Display,
    context: *anyopaque,
    event: *const fn (*anyopaque, Event) void,
    registry: ?*wl.Registry = null,
    notifier: ?*ext.IdleNotifierV1 = null,
    seat: ?*wl.Seat = null,
    seat_name: ?u32 = null,
    seats: [16]u32 = undefined,
    seat_count: usize = 0,
    ambiguous: bool = false,
    notifier_name: ?u32 = null,
    notifications: [2]?*ext.IdleNotificationV1 = .{ null, null },
    timeouts: Timeouts = .{},
    pub fn start(self: *Idle) !void {
        const wayland = object.ext.cast(backend.WaylandDisplay, self.display) orelse return error.NotWayland;
        const connection: *wl.Display = @ptrCast(wayland.getWlDisplay().?);
        self.registry = try connection.getRegistry();
        self.registry.?.setListener(*Idle, registryEvent, self);
        self.display.flush();
    }
    pub fn configure(self: *Idle, timeouts: Timeouts) void {
        self.timeouts = timeouts;
        self.clear();
        const notifier = self.notifier orelse return;
        const seat = self.seat orelse return;
        for ([_]u32{ timeouts.lock_seconds, timeouts.suspend_seconds }, 0..) |seconds, i| {
            if (seconds == 0) continue;
            self.notifications[i] = notifier.getIdleNotification(seconds * 1000, seat) catch continue;
            self.notifications[i].?.setListener(*Idle, notify, self);
        }
        self.display.flush();
    }
    fn clear(self: *Idle) void {
        for (&self.notifications) |*n| {
            if (n.*) |p| p.destroy();
            n.* = null;
        }
    }
    pub fn stop(self: *Idle) void {
        self.clear();
        if (self.seat) |s| s.release();
        if (self.notifier) |n| n.destroy();
        if (self.registry) |r| @as(*wl.Proxy, @ptrCast(r)).destroy();
        self.seat = null;
        self.notifier = null;
        self.registry = null;
    }
    fn registryEvent(_: *wl.Registry, event: wl.Registry.Event, self: *Idle) void {
        switch (event) {
            .global => |g| {
                if (std.mem.eql(u8, std.mem.span(g.interface), "ext_idle_notifier_v1") and self.notifier == null) {
                    self.notifier = self.registry.?.bind(g.name, ext.IdleNotifierV1, 1) catch return;
                    self.notifier_name = g.name;
                } else if (std.mem.eql(u8, std.mem.span(g.interface), "wl_seat") and g.version >= 5) {
                    if (self.seat_count == self.seats.len) {
                        self.ambiguous = true;
                    } else {
                        self.seats[self.seat_count] = g.name;
                        self.seat_count += 1;
                    }
                    self.selectSeat();
                }
                self.configure(self.timeouts);
            },
            .global_remove => |g| {
                for (self.seats[0..self.seat_count], 0..) |id, i| if (id == g.name) {
                    self.seat_count -= 1;
                    self.seats[i] = self.seats[self.seat_count];
                    self.selectSeat();
                    break;
                };
                if (self.notifier_name == g.name) {
                    self.clear();
                    self.notifier.?.destroy();
                    self.notifier = null;
                    self.notifier_name = null;
                    self.event(self.context, .unavailable);
                }
            },
        }
    }
    fn selectSeat(self: *Idle) void {
        self.clear();
        if (self.seat) |seat| seat.release();
        self.seat = null;
        self.seat_name = null;
        if (self.seat_count != 1 or self.ambiguous) {
            self.event(self.context, .unavailable);
            return;
        }
        self.seat = self.registry.?.bind(self.seats[0], wl.Seat, 5) catch return;
        self.seat_name = self.seats[0];
        self.seat.?.setListener(*Idle, seatEvent, self);
        self.configure(self.timeouts);
    }
    fn seatEvent(_: *wl.Seat, _: wl.Seat.Event, _: *Idle) void {}
    fn notify(n: *ext.IdleNotificationV1, event: ext.IdleNotificationV1.Event, self: *Idle) void {
        if (event == .resumed) self.event(self.context, .resumed) else self.event(self.context, if (n == self.notifications[0]) .lock else .sleep);
    }
};
