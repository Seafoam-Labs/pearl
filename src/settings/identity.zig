//! Read native session identity on GTK's connection. No shell surfaces, service
//! registrations, second display connection or manual Wayland dispatch.
const std = @import("std");
const gdk = @import("gdk4");
const backend = @import("gdkwayland4");
const object = @import("gobject2");
const wl = @import("wayland").client.wl;
const aq = @import("wayland").client.aqueous;
pub const Identity = struct {
    display: *gdk.Display,
    registry: *wl.Registry,
    shell: ?*aq.ShellManagerV1 = null,
    name: u32 = 0,
    session: ?[32]u8 = null,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    pub fn init(display: *gdk.Display, context: *anyopaque, changed: @FieldType(Identity, "changed")) !Identity {
        const wayland = object.ext.cast(backend.WaylandDisplay, display) orelse return error.NotWayland;
        const connection: *wl.Display = @ptrCast(wayland.getWlDisplay() orelse return error.NotWayland);
        return .{ .display = display, .registry = try connection.getRegistry(), .context = context, .changed = changed };
    }
    pub fn start(self: *Identity) void {
        self.registry.setListener(*Identity, registryEvent, self);
        self.display.flush();
    }
    pub fn deinit(self: *Identity) void {
        if (self.shell) |shell| shell.destroy();
        @as(*wl.Proxy, @ptrCast(self.registry)).destroy();
    }
    fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Identity) void {
        switch (event) {
            .global => |g| if (std.mem.eql(u8, std.mem.span(g.interface), "aqueous_shell_manager_v1") and self.name == 0) {
                self.name = g.name;
                self.shell = registry.bind(g.name, aq.ShellManagerV1, @min(g.version, 2)) catch return;
                self.shell.?.setListener(*Identity, received, self);
                self.display.flush();
            },
            .global_remove => |g| if (g.name == self.name) {
                self.session = null;
                self.name = 0;
                if (self.shell) |shell| shell.destroy();
                self.shell = null;
                self.changed(self.context);
            },
        }
    }
    fn received(shell: *aq.ShellManagerV1, event: aq.ShellManagerV1.Event, self: *Identity) void {
        if (event != .capabilities) return;
        const bytes = std.mem.span(event.capabilities.json);
        @import("../config/preferences.zig").boundedJson(bytes, 65536, 16) catch return;
        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, bytes, .{}) catch return;
        defer parsed.deinit();
        const e = @import("../aqueous/entities.zig");
        const session = e.read([]const u8, std.heap.c_allocator, e.field(parsed.value, "session") catch return) catch return;
        e.sessionToken(session) catch return;
        self.session = session[0..32].*;
        self.shell = null;
        shell.destroy();
        self.changed(self.context);
    }
};
