//! Read monitor identities on GTK's Wayland connection; GTK owns dispatch.
//! The greeter account has no Aqueous display configuration, so without a
//! requested mode the compositor falls back to the EDID-preferred timing
//! (often 60 Hz on high-refresh panels). Promote every enabled output to the
//! highest-refresh mode at its preferred resolution through output-management.
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
const Mode = struct {
    proxy: ?*zwlr.OutputModeV1 = null,
    width: i32 = 0,
    height: i32 = 0,
    refresh_mhz: i32 = 0,
    preferred: bool = false,
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
    modes: [64]Mode = @splat(.{}),
    current_mode: ?*zwlr.OutputModeV1 = null,
    x: i32 = 0,
    y: i32 = 0,
    transform: wl.Output.Transform = .normal,
    scale: wl.Fixed = wl.Fixed.fromInt(1),
};

pub const Watch = struct {
    display: *gdk.Display,
    registry: *wl.Registry,
    manager: ?*zwlr.OutputManagerV1 = null,
    heads: [64]Head = @splat(.{}),
    ready: bool = false,
    timeout: c_uint = 0,
    serial: u32 = 0,
    pending: ?*zwlr.OutputConfigurationV1 = null,
    head_overflow: bool = false,
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
                self.head_overflow = true;
                created.head.setListener(?*Head, headEvent, null);
            },
            .done => |v| {
                self.serial = v.serial;
                for (&self.heads) |*head| {
                    head.committed_name = if (head.proxy != null and head.enabled) head.name else .{};
                    head.digest = if (head.make.invalid or head.model.invalid or head.serial.invalid) null else identity.hash(head.make.get(), head.model.get(), head.serial.get());
                }
                self.finish();
                self.applyBestModes();
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
        // Modes have their own lifetime; track them so refresh can be promoted.
        if (event == .mode) {
            const mode = event.mode.mode;
            if (data) |head| {
                for (&head.modes) |*slot| if (slot.proxy == null) {
                    slot.* = .{ .proxy = mode };
                    break;
                };
            }
            mode.setListener(?*Head, modeEvent, data);
        }
        if (event == .finished) {
            if (data) |head| {
                head.proxy = null;
                head.current_mode = null;
                head.modes = @splat(.{});
            }
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
            .current_mode => |v| head.current_mode = v.mode,
            .position => |v| {
                head.x = v.x;
                head.y = v.y;
            },
            .transform => |v| head.transform = v.transform,
            .scale => |v| head.scale = v.scale,
            else => {},
        }
    }
    fn modeEvent(proxy: *zwlr.OutputModeV1, event: zwlr.OutputModeV1.Event, data: ?*Head) void {
        if (event == .finished) {
            if (data) |head| forgetMode(head, proxy);
            if (proxy.getVersion() >= 3) proxy.release() else @as(*wl.Proxy, @ptrCast(proxy)).destroy();
            return;
        }
        const head = data orelse return;
        for (&head.modes) |*slot| {
            if (slot.proxy != proxy) continue;
            switch (event) {
                .size => |v| {
                    slot.width = v.width;
                    slot.height = v.height;
                },
                .refresh => |v| slot.refresh_mhz = v.refresh,
                .preferred => slot.preferred = true,
                else => {},
            }
            return;
        }
    }
    fn forgetMode(head: *Head, proxy: *zwlr.OutputModeV1) void {
        for (&head.modes) |*slot| if (slot.proxy == proxy) {
            slot.* = .{};
        };
        if (head.current_mode == proxy) head.current_mode = null;
    }

    /// Pick the highest-refresh mode at the head's native resolution. The
    /// preferred (EDID) mode defines native; without one, the largest area
    /// wins. This raises refresh without dropping resolution.
    fn bestMode(head: *const Head) ?*const Mode {
        var width: i32 = 0;
        var height: i32 = 0;
        var found = false;
        for (&head.modes) |*mode| {
            if (mode.proxy == null or !mode.preferred) continue;
            width = mode.width;
            height = mode.height;
            found = true;
            break;
        }
        if (!found) {
            var area: i64 = 0;
            for (&head.modes) |*mode| {
                if (mode.proxy == null) continue;
                const next = @as(i64, mode.width) * mode.height;
                if (next > area) {
                    area = next;
                    width = mode.width;
                    height = mode.height;
                    found = true;
                }
            }
        }
        if (!found) return null;
        var best: ?*const Mode = null;
        for (&head.modes) |*mode| {
            if (mode.proxy == null or mode.width != width or mode.height != height) continue;
            const current = best orelse {
                best = mode;
                continue;
            };
            if (mode.refresh_mhz > current.refresh_mhz or
                (mode.refresh_mhz == current.refresh_mhz and mode.preferred and !current.preferred)) best = mode;
        }
        return best;
    }

    fn targetMode(head: *const Head) ?*zwlr.OutputModeV1 {
        if (bestMode(head)) |mode| return mode.proxy;
        return head.current_mode;
    }

    fn applyBestModes(self: *Watch) void {
        const manager = self.manager orelse return;
        if (self.pending != null or self.head_overflow) return;
        var needed = false;
        for (&self.heads) |*head| {
            if (head.proxy == null or !head.enabled) continue;
            // A modeless enabled head cannot be reconfigured safely; leave the
            // whole layout alone rather than risk a 0x0 custom mode.
            const mode = targetMode(head) orelse return;
            if (mode != head.current_mode) needed = true;
        }
        if (!needed) return;
        const config = manager.createConfiguration(self.serial) catch return;
        for (&self.heads) |*head| {
            const proxy = head.proxy orelse continue;
            if (!head.enabled) {
                config.disableHead(proxy);
                continue;
            }
            const target = config.enableHead(proxy) catch {
                config.destroy();
                self.display.flush();
                return;
            };
            target.setMode(targetMode(head).?);
            target.setPosition(head.x, head.y);
            target.setTransform(head.transform);
            target.setScale(head.scale);
        }
        config.setListener(*Watch, configEvent, self);
        self.pending = config;
        config.apply();
        self.display.flush();
    }
    fn configEvent(config: *zwlr.OutputConfigurationV1, _: zwlr.OutputConfigurationV1.Event, self: *Watch) void {
        config.destroy();
        if (self.pending == config) self.pending = null;
        self.display.flush();
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
    Watch.headEvent(proxy, .{ .serial_number = .{ .serial_number = @import("test_strings").string("x", 769) } }, head);
    Watch.managerEvent(undefined, .{ .done = .{ .serial = 4 } }, &watch);
    try std.testing.expect(watch.digestFor("DP-9") == null);
}

test "best mode keeps native resolution and maximizes refresh" {
    var head: Head = .{};
    const low: *zwlr.OutputModeV1 = @ptrFromInt(0x2000);
    const high: *zwlr.OutputModeV1 = @ptrFromInt(0x2008);
    const small: *zwlr.OutputModeV1 = @ptrFromInt(0x2010);
    head.modes[0] = .{ .proxy = low, .width = 2560, .height = 1440, .refresh_mhz = 59_940, .preferred = true };
    head.modes[1] = .{ .proxy = high, .width = 2560, .height = 1440, .refresh_mhz = 143_856 };
    head.modes[2] = .{ .proxy = small, .width = 1920, .height = 1080, .refresh_mhz = 239_760 };
    // Native 1440p is retained; the faster 1080p mode must not win.
    try std.testing.expectEqual(high, Watch.targetMode(&head).?);
    // Without a preferred mode the largest area still defines native.
    head.modes[0].preferred = false;
    try std.testing.expectEqual(high, Watch.targetMode(&head).?);
    // A finished (cleared) mode is ignored.
    Watch.forgetMode(&head, high);
    try std.testing.expectEqual(low, Watch.targetMode(&head).?);
}

test "target mode falls back to current when no modes are advertised" {
    var head: Head = .{};
    const current: *zwlr.OutputModeV1 = @ptrFromInt(0x3000);
    head.current_mode = current;
    try std.testing.expectEqual(current, Watch.targetMode(&head).?);
    head.current_mode = null;
    try std.testing.expect(Watch.targetMode(&head) == null);
}

test "mode events record timings and finished clears references" {
    var head: Head = .{};
    const proxy: *zwlr.OutputModeV1 = @ptrFromInt(0x4000);
    head.modes[0] = .{ .proxy = proxy };
    Watch.modeEvent(proxy, .{ .size = .{ .width = 2560, .height = 1440 } }, &head);
    Watch.modeEvent(proxy, .{ .refresh = .{ .refresh = 143_856 } }, &head);
    Watch.modeEvent(proxy, .preferred, &head);
    try std.testing.expectEqual(@as(i32, 2560), head.modes[0].width);
    try std.testing.expectEqual(@as(i32, 143_856), head.modes[0].refresh_mhz);
    try std.testing.expect(head.modes[0].preferred);
    head.current_mode = proxy;
    Watch.forgetMode(&head, proxy);
    try std.testing.expect(head.modes[0].proxy == null);
    try std.testing.expect(head.current_mode == null);
}

test "head events capture layout needed to preserve placement" {
    var head: Head = .{};
    const proxy: *zwlr.OutputHeadV1 = @ptrFromInt(0x5000);
    const mode: *zwlr.OutputModeV1 = @ptrFromInt(0x5008);
    head.proxy = proxy;
    Watch.headEvent(proxy, .{ .current_mode = .{ .mode = mode } }, &head);
    Watch.headEvent(proxy, .{ .position = .{ .x = 1920, .y = 0 } }, &head);
    Watch.headEvent(proxy, .{ .scale = .{ .scale = wl.Fixed.fromInt(2) } }, &head);
    Watch.headEvent(proxy, .{ .transform = .{ .transform = .normal } }, &head);
    try std.testing.expectEqual(mode, head.current_mode.?);
    try std.testing.expectEqual(@as(i32, 1920), head.x);
    try std.testing.expectEqual(wl.Fixed.fromInt(2), head.scale);
}
