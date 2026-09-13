//! Aqueous one-shot layout requests on GTK's verified connection. No polling.
const std = @import("std");
const glib = @import("glib2");
const gdk = @import("gdk4");
const backend = @import("gdkwayland4");
const object = @import("gobject2");
const wl = @import("wayland").client.wl;
const aq = @import("wayland").client.aqueous;
pub const names = [_][:0]const u8{ "tile", "monocle", "grid", "rows", "dwindle", "reverse-dwindle", "scrolling", "float", "game-mode", "composable" };
pub fn valid(name: []const u8) bool {
    for (names) |v| if (std.mem.eql(u8, v, name)) return true;
    return false;
}
pub const Layout = struct {
    display: *gdk.Display,
    registry: *wl.Registry,
    global: ?u32 = null,
    manager: ?*aq.WindowInfoManagerV1 = null,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    deadline: c_uint = 0,
    output: [1025]u8 = @splat(0),
    output_len: usize = 0,
    value: [32]u8 = @splat(0),
    value_len: usize = 0,
    workspace: u32 = 0,
    err: ?[]const u8 = null,
    pub fn init(display: *gdk.Display, context: *anyopaque, changed: @FieldType(Layout, "changed")) !Layout {
        const wayland = object.ext.cast(backend.WaylandDisplay, display) orelse return error.NotWayland;
        const connection: *wl.Display = @ptrCast(wayland.getWlDisplay().?);
        return .{ .display = display, .registry = try connection.getRegistry(), .context = context, .changed = changed };
    }
    pub fn start(self: *Layout) void {
        self.registry.setListener(*Layout, registryEvent, self);
        self.display.flush();
    }
    pub fn deinit(self: *Layout) void {
        self.cancel();
        @as(*wl.Proxy, @ptrCast(self.registry)).destroy();
    }
    pub fn cancel(self: *Layout) void {
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = 0;
        if (self.manager) |m| m.destroy();
        self.manager = null;
        self.value_len = 0;
        self.output_len = 0;
        self.workspace = 0;
    }
    pub fn request(self: *Layout, output: []const u8, value: ?[]const u8) !void {
        if (self.manager != null) return error.Busy;
        const global = self.global orelse return error.Unsupported;
        if (output.len == 0 or output.len > 1024) return error.Invalid;
        if (value) |v| if (!valid(v)) return error.Invalid;
        const manager = try self.registry.bind(global, aq.WindowInfoManagerV1, 3);
        self.manager = manager;
        manager.setListener(*Layout, reply, self);
        @memcpy(self.output[0..output.len], output);
        self.output[output.len] = 0;
        self.output_len = output.len;
        self.value_len = 0;
        self.err = null;
        if (value) |v| {
            var buffer: [32:0]u8 = @splat(0);
            @memcpy(buffer[0..v.len], v);
            manager.setActiveWorkspaceLayout(@ptrCast(&self.output), @ptrCast(&buffer));
        } else manager.getActiveWorkspaceLayout(@ptrCast(&self.output));
        self.deadline = glib.timeoutAdd(5000, expired, self);
        self.display.flush();
        self.changed(self.context);
    }
    fn registryEvent(_: *wl.Registry, event: wl.Registry.Event, self: *Layout) void {
        switch (event) {
            .global => |g| if (g.version >= 3 and std.mem.eql(u8, std.mem.span(g.interface), "aqueous_window_info_manager_v1")) {
                self.global = g.name;
            },
            .global_remove => |g| if (self.global == g.name) {
                self.global = null;
                self.cancel();
                self.err = "Unavailable";
                self.changed(self.context);
            },
        }
    }
    fn reply(manager: *aq.WindowInfoManagerV1, event: aq.WindowInfoManagerV1.Event, self: *Layout) void {
        if (event != .active_workspace_layout or manager != self.manager) return;
        const r = event.active_workspace_layout;
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = 0;
        self.manager = null;
        manager.destroy();
        const value = std.mem.span(r.layout);
        if (r.status != .success or !std.mem.eql(u8, std.mem.span(r.output), self.output[0..self.output_len]) or value.len >= self.value.len or !valid(value)) {
            self.err = "Unavailable";
            self.value_len = 0;
        } else {
            @memcpy(self.value[0..value.len], value);
            self.value_len = value.len;
            self.workspace = r.workspace;
            self.err = null;
        }
        self.changed(self.context);
    }
    fn expired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Layout = @ptrCast(@alignCast(data.?));
        self.deadline = 0;
        self.cancel();
        self.err = "UnknownCompletion";
        self.changed(self.context);
        return 0;
    }
};
