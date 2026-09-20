//! Observe gamma advertisement only. Never acquire exclusive gamma ownership
//! until Aqueous supplies live, generation-bound output color eligibility.
const std = @import("std");
const gdk = @import("gdk4");
const object = @import("gobject2");
const backend = @import("gdkwayland4");
const wl = @import("wayland").client.wl;
pub const Capability = struct {
    display: *gdk.Display,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    registry: ?*wl.Registry = null,
    global: ?u32 = null,
    pub fn start(self: *Capability) !void {
        const wayland = object.ext.cast(backend.WaylandDisplay, self.display) orelse return error.NotWayland;
        const connection: *wl.Display = @ptrCast(wayland.getWlDisplay().?);
        self.registry = try connection.getRegistry();
        self.registry.?.setListener(*Capability, registryEvent, self);
        self.display.flush();
    }
    pub fn stop(self: *Capability) void {
        if (self.registry) |r| @as(*wl.Proxy, @ptrCast(r)).destroy();
        self.registry = null;
        self.global = null;
    }
    fn registryEvent(_: *wl.Registry, event: wl.Registry.Event, self: *Capability) void {
        switch (event) {
            .global => |g| if (std.mem.eql(u8, std.mem.span(g.interface), "zwlr_gamma_control_manager_v1") and self.global == null) {
                self.global = g.name;
                self.changed(self.context);
            },
            .global_remove => |g| if (self.global == g.name) {
                self.global = null;
                self.changed(self.context);
            },
        }
    }
};
