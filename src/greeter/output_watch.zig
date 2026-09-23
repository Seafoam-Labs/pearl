//! Read monitor identities on GTK's Wayland connection; GTK owns dispatch.
//! This observer never creates or applies an output configuration.
const std = @import("std");
const gdk = @import("gdk4");
const backend = @import("gdkwayland4");
const object = @import("gobject2");
const glib = @import("glib2");
const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;
const identity = @import("output_identity.zig");

const Text = struct {
    bytes: [768]u8 = undefined,
    len: ?usize = null,
    invalid: bool = false,
    fn set(self: *Text, value: [*:0]const u8) void {
        const bytes = std.mem.span(value);
        self.invalid = bytes.len > self.bytes.len;
        self.len = if (self.invalid) null else bytes.len;
        if (!self.invalid) @memcpy(self.bytes[0..bytes.len], bytes);
    }
    fn get(self: *const Text) ?[]const u8 {
        return if (self.len) |len| self.bytes[0..len] else null;
    }
};
const Head = struct {
    proxy: ?*zwlr.OutputHeadV1 = null,
    name: Text = .{},
    make: Text = .{},
    model: Text = .{},
    serial: Text = .{},
    enabled: bool = false,
    committed_name: Text = .{},
    digest: ?identity.Digest = null,
};

pub const Watch = struct {
    display: *gdk.Display,
    registry: *wl.Registry,
    manager: ?*zwlr.OutputManagerV1 = null,
    heads: [64]Head = @splat(.{}),
    ready: bool = false,
    timeout: c_uint = 0,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,

    pub fn init(display: *gdk.Display, context: *anyopaque, changed: *const fn (*anyopaque) void) !Watch {
        const wayland = object.ext.cast(backend.WaylandDisplay, display) orelse return error.NotWayland;
        const connection: *wl.Display = @ptrCast(wayland.getWlDisplay() orelse return error.NotWayland);
        return .{ .display = display, .registry = try connection.getRegistry(), .context = context, .changed = changed };
    }
    pub fn start(self: *Watch) void {
        self.registry.setListener(*Watch, registryEvent, self);
        // Never hold the login screen indefinitely for optional identity metadata.
        self.timeout = glib.timeoutAdd(1000, expired, self);
        const wayland = object.ext.cast(backend.WaylandDisplay, self.display).?;
        const connection: *wl.Display = @ptrCast(wayland.getWlDisplay().?);
        if (connection.sync()) |callback| callback.setListener(*Watch, synced, self) else |_| self.finish();
        self.display.flush();
    }
    pub fn digestFor(self: *const Watch, name: []const u8) ?identity.Digest {
        var result: ?identity.Digest = null;
        var found = false;
        for (&self.heads) |*head| {
            const connector = head.committed_name.get() orelse continue;
            if (!std.mem.eql(u8, connector, name)) continue;
            if (found) return null; // Ambiguous connector names must not misidentify a head.
            found = true;
            result = head.digest;
        }
        return result;
    }
    fn finish(self: *Watch) void {
        self.ready = true;
        if (self.timeout != 0) _ = glib.Source.remove(self.timeout);
        self.timeout = 0;
        self.changed(self.context);
    }
    fn expired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Watch = @ptrCast(@alignCast(data.?));
        self.timeout = 0;
        self.finish();
        return 0;
    }
    fn synced(callback: *wl.Callback, _: wl.Callback.Event, self: *Watch) void {
        callback.destroy();
        if (self.manager == null) self.finish();
    }
    fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Watch) void {
        switch (event) {
            .global => |g| {
                if (self.manager != null or g.version < 2 or !std.mem.eql(u8, std.mem.span(g.interface), "zwlr_output_manager_v1")) return;
                self.manager = registry.bind(g.name, zwlr.OutputManagerV1, @min(g.version, 3)) catch return;
                self.manager.?.setListener(*Watch, managerEvent, self);
                self.display.flush();
            },
            .global_remove => {},
        }
    }
    fn managerEvent(manager: *zwlr.OutputManagerV1, event: zwlr.OutputManagerV1.Event, self: *Watch) void {
        switch (event) {
            .head => |created| {
                for (&self.heads) |*head| if (head.proxy == null) {
                    head.* = .{ .proxy = created.head };
                    created.head.setListener(?*Head, headEvent, head);
                    return;
                };
                created.head.setListener(?*Head, headEvent, null);
            },
            .done => {
                for (&self.heads) |*head| {
                    head.committed_name = if (head.proxy != null and head.enabled) head.name else .{};
                    head.digest = if (head.make.invalid or head.model.invalid or head.serial.invalid) null else identity.hash(head.make.get(), head.model.get(), head.serial.get());
                }
                self.finish();
            },
            .finished => {
                @as(*wl.Proxy, @ptrCast(manager)).destroy();
                self.manager = null;
                for (&self.heads) |*head| head.committed_name = .{};
                self.finish();
            },
        }
    }
    fn headEvent(proxy: *zwlr.OutputHeadV1, event: zwlr.OutputHeadV1.Event, data: ?*Head) void {
        // Modes have their own lifetime even though placement does not use them.
        if (event == .mode) event.mode.mode.setListener(?*Head, modeEvent, null);
        if (event == .finished) {
            if (data) |head| head.proxy = null;
            if (proxy.getVersion() >= 3) proxy.release() else @as(*wl.Proxy, @ptrCast(proxy)).destroy();
            return;
        }
        const head = data orelse return;
        switch (event) {
            .name => |v| head.name.set(v.name),
            .make => |v| head.make.set(v.make),
            .model => |v| head.model.set(v.model),
            .serial_number => |v| head.serial.set(v.serial_number),
            .enabled => |v| head.enabled = v.enabled != 0,
            else => {},
        }
    }
    fn modeEvent(proxy: *zwlr.OutputModeV1, event: zwlr.OutputModeV1.Event, _: ?*Head) void {
        if (event == .finished) {
            if (proxy.getVersion() >= 3) proxy.release() else @as(*wl.Proxy, @ptrCast(proxy)).destroy();
        }
    }
};

test "protocol identity is published on done and cleared when disabled or ambiguous" {
    const Changed = struct {
        fn notify(context: *anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(context));
            count.* += 1;
        }
    };
    var notifications: usize = 0;
    var watch: Watch = .{ .display = undefined, .registry = undefined, .context = &notifications, .changed = Changed.notify };
    const proxy: *zwlr.OutputHeadV1 = @ptrFromInt(0x1000);
    const head = &watch.heads[0];
    head.proxy = proxy;
    Watch.headEvent(proxy, .{ .name = .{ .name = "DP-9" } }, head);
    Watch.headEvent(proxy, .{ .make = .{ .make = "Acme" } }, head);
    Watch.headEvent(proxy, .{ .model = .{ .model = "Panel" } }, head);
    Watch.headEvent(proxy, .{ .serial_number = .{ .serial_number = "ABC123" } }, head);
    Watch.headEvent(proxy, .{ .enabled = .{ .enabled = 1 } }, head);
    try std.testing.expect(watch.digestFor("DP-9") == null);
    Watch.managerEvent(undefined, .{ .done = .{ .serial = 1 } }, &watch);
    try std.testing.expect(watch.ready);
    try std.testing.expectEqual(@as(usize, 1), notifications);
    const wanted = try identity.parseHash("sha256:daf5f59252c5a28c00c8f13b516d7ccb8afdce47b8f664ff18f3059e18f3057e");
    try std.testing.expectEqual(wanted, watch.digestFor("DP-9").?);
    const outputs = [_]identity.Output{
        .{ .name = "DP-1" },
        .{ .name = "DP-9", .digest = watch.digestFor("DP-9") },
    };
    try std.testing.expectEqual(@as(?usize, 1), identity.select(&outputs, "DP-1", wanted));
    Watch.headEvent(proxy, .{ .enabled = .{ .enabled = 0 } }, head);
    try std.testing.expect(watch.digestFor("DP-9") != null);
    Watch.managerEvent(undefined, .{ .done = .{ .serial = 2 } }, &watch);
    try std.testing.expect(watch.digestFor("DP-9") == null);
    Watch.headEvent(proxy, .{ .enabled = .{ .enabled = 1 } }, head);
    Watch.managerEvent(undefined, .{ .done = .{ .serial = 3 } }, &watch);
    try std.testing.expectEqual(wanted, watch.digestFor("DP-9").?);
    watch.heads[1] = head.*;
    try std.testing.expect(watch.digestFor("DP-9") == null);
    watch.heads[1] = .{};
    Watch.headEvent(proxy, .{ .serial_number = .{ .serial_number = "x" ** 769 } }, head);
    Watch.managerEvent(undefined, .{ .done = .{ .serial = 4 } }, &watch);
    try std.testing.expect(watch.digestFor("DP-9") == null);
}
