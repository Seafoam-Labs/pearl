//! Compositor idle notifications respect ext-idle-inhibit. GTK owns dispatch.
const std = @import("std");
const gdk = @import("gdk4");
const object = @import("gobject2");
const backend = @import("gdkwayland4");
const wl = @import("wayland").client.wl;
const ext = @import("wayland").client.ext;
const zwlr = @import("wayland").client.zwlr;
const Timeouts = @import("../../services/idle_policy.zig").Timeouts;
pub const Event = enum { lock, sleep, dim, screen_off, display_changed, resumed, unavailable };
pub const Output = struct {
    name: @import("../../services/policy.zig").Text(128) = .{},
    owner: ?*Idle = null,
    id: u32 = 0,
    proxy: ?*wl.Output = null,
    power: ?*zwlr.OutputPowerV1 = null,
    mode: ?zwlr.OutputPowerV1.Mode = null,
    owned: bool = false,
};
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
    notifications: [4]?*ext.IdleNotificationV1 = @splat(null),
    power_manager: ?*zwlr.OutputPowerManagerV1 = null,
    power_name: ?u32 = null,
    outputs: [32]Output = @splat(.{}),
    timeouts: Timeouts = .{},
    manual_wake: ?*ext.IdleNotificationV1 = null,
    pub fn start(self: *Idle) !void {
        const wayland = object.ext.cast(backend.WaylandDisplay, self.display) orelse return error.NotWayland;
        const connection: *wl.Display = @ptrCast(wayland.getWlDisplay().?);
        self.registry = try connection.getRegistry();
        self.registry.?.setListener(*Idle, registryEvent, self);
        self.display.flush();
    }
    pub fn configure(self: *Idle, timeouts: Timeouts) void {
        self.setScreenOff(false);
        self.timeouts = timeouts;
        self.clear();
        const notifier = self.notifier orelse return;
        const seat = self.seat orelse return;
        for ([_]u32{ timeouts.lock_seconds, timeouts.suspend_seconds, timeouts.dimSeconds(), timeouts.screen_off_seconds }, 0..) |seconds, i| {
            if (seconds == 0) continue;
            self.notifications[i] = notifier.getIdleNotification(seconds * 1000, seat) catch continue;
            self.notifications[i].?.setListener(*Idle, notify, self);
        }
        self.display.flush();
    }
    fn clear(self: *Idle) void {
        if (self.manual_wake) |n| n.destroy();
        self.manual_wake = null;
        for (&self.notifications) |*n| {
            if (n.*) |p| p.destroy();
            n.* = null;
        }
    }
    pub fn stop(self: *Idle) void {
        self.setScreenOff(false);
        self.clear();
        for (&self.outputs) |*output| closeOutput(output);
        if (self.power_manager) |manager| manager.destroy();
        self.power_manager = null;
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
                if (std.mem.eql(u8, std.mem.span(g.interface), "zwlr_output_power_manager_v1") and self.power_manager == null) {
                    self.power_manager = self.registry.?.bind(g.name, zwlr.OutputPowerManagerV1, 1) catch return;
                    self.power_name = g.name;
                    self.bindPowers();
                } else if (std.mem.eql(u8, std.mem.span(g.interface), "wl_output") and g.version >= 3) {
                    for (&self.outputs) |*output| if (output.proxy == null) {
                        output.* = .{ .owner = self, .id = g.name, .proxy = self.registry.?.bind(g.name, wl.Output, @min(4, g.version)) catch return };
                        output.proxy.?.setListener(*Output, outputEvent, output);
                        self.bindPowers();
                        break;
                    };
                }
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
                for (&self.outputs) |*output| if (output.id == g.name) closeOutput(output);
                if (self.power_name == g.name) {
                    self.setScreenOff(false);
                    for (&self.outputs) |*output| {
                        if (output.power) |power| power.destroy();
                        output.power = null;
                        output.mode = null;
                    }
                    if (self.power_manager) |manager| manager.destroy();
                    self.power_manager = null;
                    self.power_name = null;
                }
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
                self.event(self.context, .display_changed);
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
        if (event == .resumed) {
            self.setScreenOff(false);
            self.event(self.context, .resumed);
        } else self.event(self.context, if (n == self.notifications[0]) .lock else if (n == self.notifications[1]) .sleep else if (n == self.notifications[2]) .dim else .screen_off);
    }
    fn closeOutput(output: *Output) void {
        if (output.power) |power| power.destroy();
        if (output.proxy) |proxy| proxy.release();
        output.* = .{};
    }
    fn bindPowers(self: *Idle) void {
        const manager = self.power_manager orelse return;
        for (&self.outputs) |*output| if (output.proxy != null and output.power == null) {
            output.power = manager.getOutputPower(output.proxy.?) catch continue;
            output.power.?.setListener(*Output, powerEvent, output);
        };
        self.display.flush();
    }
    fn outputEvent(_: *wl.Output, event: wl.Output.Event, output: *Output) void {
        switch (event) {
            .name => |n| output.name.set(std.mem.span(n.name)),
            .done => if (output.owner) |owner| owner.event(owner.context, .display_changed),
            else => {},
        }
    }
    pub fn findOutput(self: *Idle, name: []const u8) ?*Output {
        if (name.len == 0) return null;
        var found: ?*Output = null;
        for (&self.outputs) |*output| if (output.proxy != null and std.mem.eql(u8, output.name.slice(), name)) {
            if (found != null) return null;
            found = output;
        };
        return found;
    }
    pub fn setOutputOff(self: *Idle, name: []const u8, off: bool) !void {
        const output = self.findOutput(name) orelse return error.Unavailable;
        const power = output.power orelse return error.Unavailable;
        const mode = output.mode orelse return error.Unavailable;
        if (off) {
            if (mode == .off) return;
            const notifier = self.notifier orelse return error.Unavailable;
            const seat = self.seat orelse return error.Unavailable;
            if (self.manual_wake == null) {
                self.manual_wake = try notifier.getIdleNotification(0, seat);
                self.manual_wake.?.setListener(*Idle, manualNotify, self);
            }
            output.owned = true;
            power.setMode(.off);
        } else {
            // Explicit user restore is allowed even if another client blanked it.
            output.owned = false;
            power.setMode(.on);
        }
        self.display.flush();
    }
    fn manualNotify(_: *ext.IdleNotificationV1, event: ext.IdleNotificationV1.Event, self: *Idle) void {
        if (event != .resumed) return;
        self.setScreenOff(false);
        if (self.manual_wake) |n| n.destroy();
        self.manual_wake = null;
        self.event(self.context, .resumed);
    }
    fn powerEvent(power: *zwlr.OutputPowerV1, event: zwlr.OutputPowerV1.Event, output: *Output) void {
        switch (event) {
            .mode => |m| {
                output.mode = m.mode;
                if (m.mode == .on) output.owned = false;
            },
            .failed => {
                power.destroy();
                output.power = null;
                output.mode = null;
                output.owned = false;
            },
        }
        if (output.owner) |owner| owner.event(owner.context, .display_changed);
    }
    pub fn screenAvailable(self: *const Idle) bool {
        for (self.outputs) |output| if (output.power != null and output.mode != null) return true;
        return false;
    }
    pub fn setScreenOff(self: *Idle, off: bool) void {
        for (&self.outputs) |*output| if (output.power) |power| {
            if (off and output.mode == .on) {
                output.owned = true;
                power.setMode(.off);
            } else if (!off and output.owned) {
                output.owned = false;
                power.setMode(.on);
            }
        };
        self.display.flush();
    }
};
