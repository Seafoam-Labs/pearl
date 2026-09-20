//! Session-owned policy with generation-bound native output warming.
const std = @import("std");
const glib = @import("glib2");
const gdk = @import("gdk4");
const warming = @import("../platform/wayland/warming_control.zig");
const gamma = @import("../platform/wayland/gamma_control.zig");
pub const policy = @import("night_light_policy.zig");
pub const NightLight = struct {
    display: *gdk.Display,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    model: policy.Policy = .{},
    capability: gamma.Capability = undefined,
    warming: warming.Control = undefined,
    running: bool = false,
    source: c_uint = 0,
    generation: u64 = 1,
    requested: bool = false,
    interactive: bool = false,
    last_now: ?i64 = null,
    last_monotonic: i64 = 0,
    zone: @import("policy.zig").Text(128) = .{},
    pub fn start(self: *NightLight) void {
        self.capability = .{ .display = self.display, .context = self, .changed = capabilityChanged };
        self.warming = .{ .display = self.display, .context = self, .changed = capabilityChanged };
        self.running = true;
        self.warming.start() catch {};
        self.capability.start() catch {};
        // One timer per session. Civil time is resampled after clock/timezone
        // changes and sleep; no view-owned polling or repeated display writes.
        self.source = glib.timeoutAdd(1000, tick, self);
        self.refresh();
    }
    pub fn stop(self: *NightLight) void {
        if (!self.running) return;
        self.running = false;
        if (self.source != 0) _ = glib.Source.remove(self.source);
        self.source = 0;
        self.warming.stop();
        self.capability.stop();
    }
    pub fn configure(self: *NightLight, config: policy.Config) void {
        if (std.meta.eql(self.model.config, config)) return;
        self.model.configure(config);
        self.refresh();
        self.notify();
    }
    fn notify(self: *NightLight) void {
        self.generation +|= 1;
        self.changed(self.context);
    }
    fn capabilityChanged(context: *anyopaque) void {
        const self: *NightLight = @ptrCast(@alignCast(context));
        self.notify();
    }
    fn minute(now: *glib.DateTime) u16 {
        return @intCast(now.getHour() * 60 + now.getMinute());
    }
    pub fn refresh(self: *NightLight) void {
        defer self.warming.sync(self.requested, self.model.config.temperature_kelvin);
        const now = glib.DateTime.newNowLocal() orelse return;
        defer now.unref();
        const before = self.model.override;
        const zone = std.mem.span(now.getTimezone().getIdentifier());
        const monotonic = glib.getMonotonicTime();
        const clock_changed = if (self.last_now) |last| @abs((now.toUnix() - last) - @divTrunc(monotonic - self.last_monotonic, 1000000)) > 2 else false;
        if (self.last_now != null and (clock_changed or !std.mem.eql(u8, zone, self.zone.slice())) and self.model.override != null) {
            self.model.clockChanged(now.toUnix(), @import("night_light_clock.zig").nextBoundary(self.model.config, now));
        }
        self.zone.set(zone);
        self.last_now = now.toUnix();
        self.last_monotonic = monotonic;
        const desired = self.model.desired(now.toUnix(), minute(now));
        if (desired != self.requested or !std.meta.eql(before, self.model.override)) {
            self.requested = desired;
            self.notify();
        }
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *NightLight = @ptrCast(@alignCast(data.?));
        self.refresh();
        return @intFromBool(self.running);
    }
    pub fn act(self: *NightLight, action: policy.Action) !void {
        if (!self.interactive) return error.SessionInactive;
        self.refresh();
        // Off and resume are always safe. Never claim that an on request took
        // effect, or silently retain an override for a rejected operation.
        if ((action == .on or action == .retry or (action == .toggle and !self.requested)) and !self.warming.available()) return error.OutputColorEligibilityUnavailable;
        if (action == .retry) self.warming.retry();
        const now = glib.DateTime.newNowLocal() orelse return error.ClockUnavailable;
        defer now.unref();
        self.model.act(action, now.toUnix(), minute(now), @import("night_light_clock.zig").nextBoundary(self.model.config, now));
        self.refresh();
        self.notify();
    }
    pub fn reason(self: *const NightLight) []const u8 {
        if (self.warming.manager != null) return if (self.warming.available()) "NativeOutputWarming" else "OutputPathUnqualified";
        return if (self.capability.global == null) "GammaControlUnavailable" else "OutputColorEligibilityUnavailable";
    }
    pub fn state(self: *const NightLight) @FieldType(policy.Snapshot, "state") {
        var committed: usize = 0;
        const total: usize = self.display.getMonitors().getNItems();
        var pending = false;
        var restoring = false;
        var failed = false;
        for (self.warming.outputs) |slot| if (slot) |output| {
            if (output.state == .committed) committed += 1;
            pending = pending or output.state == .pending;
            restoring = restoring or output.state == .restoring;
            failed = failed or output.state == .failed;
        };
        if (restoring) return .restoring;
        if (failed and !self.requested) return .failed;
        if (self.requested) {
            if (committed > 0) return if (committed == total) .active else .partial;
            if (pending) return .pending;
            if (failed) return .failed;
            return .unavailable;
        }
        return if (self.model.override == null and self.model.config.enabled and self.model.config.schedule == .custom) .scheduled else .off;
    }
    pub fn snapshot(self: *NightLight, alloc: std.mem.Allocator) !policy.Snapshot {
        var outputs: std.ArrayList(policy.OutputStatus) = .empty;
        const monitors = self.display.getMonitors();
        for (0..monitors.getNItems()) |i| {
            const item = monitors.getItem(@intCast(i)) orelse continue;
            const monitor: *gdk.Monitor = @ptrCast(@alignCast(item));
            defer monitor.unref();
            const raw_connector = if (monitor.getConnector()) |name| std.mem.span(name) else "Unknown output";
            const connector = if (raw_connector.len <= 128 and std.unicode.utf8ValidateSlice(raw_connector)) raw_connector else "Invalid output identity";
            const native = self.warming.find(monitor);
            try outputs.append(alloc, .{
                .connector = try alloc.dupe(u8, connector),
                .available = if (native) |o| o.available() else false,
                .reason = if (native) |o| o.reason() else self.reason(),
                .state = if (native) |o| @tagName(o.state) else "unavailable",
                .committed_kelvin = if (native) |o| o.committed_kelvin else 0,
            });
        }
        return .{ .generation = try std.fmt.allocPrint(alloc, "{d}", .{self.generation}), .state = self.state(), .available = self.warming.available(), .requested = self.requested, .temperature_kelvin = self.model.config.temperature_kelvin, .override = self.model.override, .gamma_protocol = self.capability.global != null, .reason = self.reason(), .outputs = try outputs.toOwnedSlice(alloc) };
    }
};
