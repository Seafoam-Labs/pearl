//! Bounded asynchronous system-bus proxies. Mutations target a captured unique owner.
const std = @import("std");
const ownership = @import("view_ownership.zig");
pub const Owner = ownership.Owner;
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const policy = @import("policy.zig");
const Text = policy.Text;
const brightness_feedback = @import("brightness_feedback.zig");
const presentation = @import("power_presentation.zig");
const a = std.heap.c_allocator;
pub const Event = @import("audio.zig").Event;
const Tag = enum { battery, upower, login, session, profiles, legacy_profiles };
const names = [_][:0]const u8{ "org.freedesktop.UPower", "org.freedesktop.UPower", "org.freedesktop.login1", "org.freedesktop.login1", "org.freedesktop.UPower.PowerProfiles", "net.hadess.PowerProfiles" };
const paths = [_][:0]const u8{ "/org/freedesktop/UPower/devices/DisplayDevice", "/org/freedesktop/UPower", "/org/freedesktop/login1", "", "/org/freedesktop/UPower/PowerProfiles", "/net/hadess/PowerProfiles" };
const interfaces = [_][:0]const u8{ "org.freedesktop.UPower.Device", "org.freedesktop.UPower", "org.freedesktop.login1.Manager", "org.freedesktop.login1.Session", "org.freedesktop.UPower.PowerProfiles", "net.hadess.PowerProfiles" };
const Slot = struct { service: *Power, tag: Tag, proxy: ?*gio.DBusProxy = null, creating: bool = false, generation: u64 = 0, owner: Text(256) = .{}, bus_signal: c_ulong = 0, signals: [3]c_ulong = .{ 0, 0, 0 } };
const Creation = struct { slot: *Slot, generation: u64 };
const Purpose = enum { can_off, can_reboot, brightness, profile, power_off, reboot };
const Call = struct { service: *Power, tag: Tag, generation: u64, purpose: Purpose };
pub const brightness_model = @import("brightness_model.zig");
const brightness_io = @import("brightness_io.zig");
pub const Backlight = brightness_model.Device;
const Scan = struct { service: *Power, root: Text(512), drm: Text(512), result: brightness_model.List = .{} };
const BrightnessWrite = struct {
    service: *Power,
    device: Backlight,
    percent: u8,
    session_generation: u64,
    connection: ?*gio.DBusConnection = null,
    owner: Text(256) = .{},
    path: Text(512) = .{},
    root: Text(512),
    drm: Text(512),
    reason: ?[]const u8 = null,
};
pub const Power = struct {
    app: *gio.Application,
    context: *anyopaque,
    changed: *const fn (*anyopaque, Event) void,
    slots: [6]Slot = undefined,
    cancel: *gio.Cancellable = undefined,
    running: bool = false,
    retry_source: c_uint = 0,
    battery_present: bool = false,
    battery_available: bool = false,
    /// Last presence confirmed while DisplayDevice was reachable, so a transient
    /// service loss keeps showing the indicator. False until something is observed,
    /// which keeps a machine with no battery from ever growing one.
    battery_observed: bool = false,
    alarm: presentation.Alarm = .{},
    percentage_valid: bool = false,
    health: ?f64 = null,
    history: presentation.History = .{},
    battery_identity: Text(512) = .{},
    saver: presentation.Saver = .{},
    saver_threshold: u8 = 0,
    percentage: f64 = 0,
    battery_state: u32 = 0,
    time_to_empty: i64 = 0,
    time_to_full: i64 = 0,
    on_battery: bool = false,
    capability_pending: [2]bool = .{ false, false },
    can_off: bool = false,
    can_reboot: bool = false,
    session_active: bool = false,
    preparing: bool = false,
    session_path: Text(512) = .{},
    profile: Text(64) = .{},
    profiles: [3]bool = .{ false, false, false },
    degraded: Text(256) = .{},
    backlight: Backlight = .{}, // Selected-device compatibility snapshot for existing views.
    displays: brightness_model.List = .{},
    selected_display: Text(128) = .{},
    preferred_output: Text(128) = .{},
    next_brightness_generation: u64 = 0,
    brightness_io_pending: bool = false,
    write_cancel: ?*gio.Cancellable = null,
    output_states: [32]struct { name: Text(128) = .{}, powered: bool = true } = @splat(.{}),
    drm_root: Text(512) = .{},
    drm_monitor: ?*gio.FileMonitor = null,
    drm_monitor_signal: c_ulong = 0,
    backlight_root: Text(512) = .{},
    scan_pending: bool = false,
    scan_again: bool = false,
    monitor: ?*gio.FileMonitor = null,
    monitor_signal: c_ulong = 0,
    brightness_monitor: ?*gio.FileMonitor = null,
    brightness_monitor_signal: c_ulong = 0,
    monitored: Text(128) = .{},
    observed: brightness_feedback.Observer = .{},
    brightness_change: ?brightness_feedback.Change = null,
    interest: ownership.Interest = .{},
    panel_open: bool = false,
    poll_source: c_uint = 0,
    brightness_wanted: ?u8 = null,
    brightness_pending: bool = false,
    profile_wanted: ?u8 = null,
    profile_pending: bool = false,
    action_pending: bool = false,
    write_source: c_uint = 0,
    err: ?[]const u8 = null,
    feedback: ?Purpose = null,
    pub const profile_names = [_][:0]const u8{ "power-saver", "balanced", "performance" };
    pub fn start(self: *Power) void {
        self.running = true;
        self.cancel = gio.Cancellable.new();
        if (self.backlight_root.len == 0) self.backlight_root.set("/sys/class/backlight");
        for (&self.slots, 0..) |*slot, i| slot.* = .{ .service = self, .tag = @enumFromInt(i) };
        for (&self.slots) |*slot| if (slot.tag != .session) self.create(slot);
        const file = gio.File.newForPath(self.backlight_root.z());
        defer file.unref();
        self.monitor = file.monitorDirectory(.{}, self.cancel, null);
        if (self.monitor) |m| self.monitor_signal = gio.FileMonitor.signals.changed.connect(m, *Power, backlightChanged, self, .{});
        if (std.mem.eql(u8, self.backlight_root.slice(), "/sys/class/backlight")) self.drm_root.set("/sys/class/drm");
        if (self.drm_root.len != 0) {
            const drm_file = gio.File.newForPath(self.drm_root.z());
            defer drm_file.unref();
            self.drm_monitor = drm_file.monitorDirectory(.{}, self.cancel, null);
            if (self.drm_monitor) |m| self.drm_monitor_signal = gio.FileMonitor.signals.changed.connect(m, *Power, backlightChanged, self, .{});
        }
        self.scan();
        self.poll_source = glib.timeoutAdd(5000, poll, self);
    }
    fn closeSlot(slot: *Slot) void {
        slot.generation += 1;
        slot.owner = .{};
        if (slot.proxy) |proxy| {
            for (slot.signals) |id| if (id != 0) object.signalHandlerDisconnect(proxy.as(object.Object), id);
            if (slot.bus_signal != 0) object.signalHandlerDisconnect(proxy.getConnection().as(object.Object), slot.bus_signal);
            slot.bus_signal = 0;
            proxy.unref();
        }
        slot.proxy = null;
        slot.signals = .{ 0, 0, 0 };
    }
    pub fn stop(self: *Power) void {
        // Best-effort restoration of confirmed idle dimming. These tasks have
        // their own cancellation lifetime and cannot callback into stopped UI.
        for (self.displays.slice()) |d| if (d.dim_restore) |before| {
            if (d.pending or d.percent() != 20 or !self.deviceAvailable(&d)) continue;
            const slot = self.available(.session) orelse continue;
            const job = a.create(BrightnessWrite) catch continue;
            job.* = .{ .service = self, .device = d, .percent = before, .session_generation = slot.generation, .root = self.backlight_root, .drm = self.drm_root, .owner = slot.owner, .path = self.session_path };
            if (d.backend == .backlight) {
                job.connection = slot.proxy.?.getConnection();
                job.connection.?.ref();
            }
            self.app.hold();
            const cancel = gio.Cancellable.new();
            defer cancel.unref();
            const task = gio.Task.new(self.app.as(object.Object), cancel, detachedBrightnessWritten, job);
            task.setTaskData(job, null);
            _ = task.setReturnOnCancel(0);
            task.runInThread(brightnessThread);
            task.unref();
        };
        self.running = false;
        self.interest.revoke();
        self.panel_open = false;
        self.cancel.cancel();
        if (self.write_cancel) |c| c.cancel();
        for ([_]c_uint{ self.retry_source, self.poll_source, self.write_source }) |id| if (id != 0) {
            _ = glib.Source.remove(id);
        };
        self.retry_source = 0;
        self.poll_source = 0;
        self.write_source = 0;
        if (self.monitor) |m| {
            object.signalHandlerDisconnect(m.as(object.Object), self.monitor_signal);
            _ = m.cancel();
            m.unref();
        }
        self.monitor = null;
        if (self.drm_monitor) |m| {
            object.signalHandlerDisconnect(m.as(object.Object), self.drm_monitor_signal);
            _ = m.cancel();
            m.unref();
        }
        self.drm_monitor = null;
        self.unwatchBrightness();
        self.observed = .{};
        self.brightness_change = null;
        for (&self.slots) |*slot| closeSlot(slot);
        self.cancel.unref();
    }
    fn create(self: *Power, slot: *Slot) void {
        if (slot.creating or slot.proxy != null) return;
        if (slot.tag == .session and self.session_path.len == 0) return;
        const job = a.create(Creation) catch return;
        job.* = .{ .slot = slot, .generation = slot.generation };
        slot.creating = true;
        self.app.hold();
        const i = @intFromEnum(slot.tag);
        gio.DBusProxy.newForBus(.system, .{ .do_not_auto_start = true, .get_invalidated_properties = true }, null, names[i], if (slot.tag == .session) self.session_path.z() else paths[i], interfaces[i], self.cancel, created, job);
    }
    fn created(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const job: *Creation = @ptrCast(@alignCast(data.?));
        const slot = job.slot;
        defer a.destroy(job);
        const self = slot.service;
        defer self.app.release();
        slot.creating = false;
        var err: ?*glib.Error = null;
        const proxy = gio.DBusProxy.newForBusFinish(result, &err);
        if (err) |e| e.free();
        if (!self.running) {
            if (proxy) |p| p.unref();
            return;
        }
        if (slot.generation != job.generation) {
            if (proxy) |p| p.unref();
            self.create(slot);
            return;
        }
        slot.proxy = proxy;
        if (proxy) |p| {
            p.getConnection().setExitOnClose(0);
            slot.signals[0] = gio.DBusProxy.signals.g_properties_changed.connect(p, *Slot, propertiesChanged, slot, .{});
            slot.signals[1] = object.Object.signals.notify.connect(p.as(object.Object), *Slot, ownerChanged, slot, .{ .detail = "g-name-owner" });
            slot.signals[2] = gio.DBusProxy.signals.g_signal.connect(p, *Slot, signalChanged, slot, .{});
            slot.bus_signal = gio.DBusConnection.signals.closed.connect(p.getConnection(), *Slot, busClosed, slot, .{});
            self.owner(slot);
        } else if (self.retry_source == 0) self.retry_source = glib.timeoutAdd(5000, retry, self);
    }
    fn busClosed(_: *gio.DBusConnection, _: c_int, _: ?*glib.Error, slot: *Slot) callconv(.c) void {
        const self = slot.service;
        closeSlot(slot);
        if (!self.running) return;
        self.capability_pending = .{ false, false };
        self.can_off = false;
        self.can_reboot = false;
        self.brightness_pending = false;
        self.brightness_wanted = null;
        self.observed = .{};
        self.brightness_change = null;
        self.profile_pending = false;
        self.profile_wanted = null;
        self.action_pending = false;
        self.err = "System bus disconnected; pending changes were discarded.";
        self.refresh();
        if (self.retry_source == 0) self.retry_source = glib.timeoutAdd(5000, retry, self);
    }
    fn capabilities(self: *Power) void {
        const slot = self.available(.login) orelse return;
        if (!self.capability_pending[0]) {
            self.call(slot, .can_off, "CanPowerOff", null, null) catch return;
            self.capability_pending[0] = true;
        }
        if (!self.capability_pending[1]) {
            self.call(slot, .can_reboot, "CanReboot", null, null) catch return;
            self.capability_pending[1] = true;
        }
    }
    fn retry(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Power = @ptrCast(@alignCast(data.?));
        self.retry_source = 0;
        for (&self.slots) |*slot| self.create(slot);
        return 0;
    }
    fn ownerChanged(_: *object.Object, _: *object.ParamSpec, slot: *Slot) callconv(.c) void {
        slot.service.owner(slot);
    }
    fn owner(self: *Power, slot: *Slot) void {
        const owner_name = slot.proxy.?.getNameOwner();
        defer if (owner_name) |name| glib.free(name);
        const name = if (owner_name) |n| std.mem.span(n) else "";
        if (!std.mem.eql(u8, slot.owner.slice(), name)) {
            slot.generation += 1;
            slot.owner.set(name);
            if (name.len != 0) self.err = null;
            switch (slot.tag) {
                .battery => self.history.len = 0,
                .login => {
                    self.capability_pending = .{ false, false };
                    self.can_off = false;
                    self.can_reboot = false;
                    self.preparing = false;
                    self.action_pending = false;
                    self.session_path = .{};
                    self.session_active = false;
                    closeSlot(&self.slots[@intFromEnum(Tag.session)]);
                    self.brightness_wanted = null;
                    self.brightness_pending = false;
                    if (name.len != 0) self.capabilities();
                },
                .profiles, .legacy_profiles => {
                    if (self.saver.owned or self.saver.awaiting) self.saver.failed();
                    self.profile_pending = false;
                    self.profile_wanted = null;
                },
                .session => {
                    self.brightness_pending = false;
                    self.brightness_wanted = null;
                },
                else => {},
            }
            if (name.len == 0) self.err = "Service unavailable; pending changes were discarded.";
        }
        self.refresh();
    }
    fn propertiesChanged(_: *gio.DBusProxy, _: *glib.Variant, _: [*][*:0]u8, slot: *Slot) callconv(.c) void {
        slot.service.refresh();
    }
    fn signalChanged(_: *gio.DBusProxy, _: ?[*:0]u8, name: [*:0]u8, args: *glib.Variant, slot: *Slot) callconv(.c) void {
        if (slot.tag != .login) return;
        if (std.mem.eql(u8, std.mem.span(name), "PrepareForShutdown") or std.mem.eql(u8, std.mem.span(name), "PrepareForSleep")) {
            if (!is(args, "(b)")) return;
            const value = args.getChildValue(0);
            defer value.unref();
            slot.service.preparing = value.getBoolean() != 0;
            slot.service.refresh();
        }
    }
    fn available(self: *Power, tag: Tag) ?*Slot {
        const slot = &self.slots[@intFromEnum(tag)];
        return if (slot.proxy != null and slot.owner.len != 0) slot else null;
    }
    fn profilesSlot(self: *Power) ?*Slot {
        return self.available(.profiles) orelse self.available(.legacy_profiles);
    }
    fn prop(self: *Power, tag: Tag, name: [:0]const u8, signature: [:0]const u8) ?*glib.Variant {
        const slot = self.available(tag) orelse return null;
        const v = slot.proxy.?.getCachedProperty(name) orelse return null;
        if (!is(v, signature)) {
            v.unref();
            return null;
        }
        return v;
    }
    fn boolean(self: *Power, tag: Tag, name: [:0]const u8) bool {
        const v = self.prop(tag, name, "b") orelse return false;
        defer v.unref();
        return v.getBoolean() != 0;
    }
    fn refresh(self: *Power) void {
        const was_present = self.battery_present;
        self.battery_available = self.available(.battery) != null;
        self.battery_present = self.boolean(.battery, "IsPresent");
        // DisplayDevice is UPower's aggregate system supply, never a peripheral.
        // Type 2 is a battery; UPS (3) is deliberately not a laptop battery.
        if (self.prop(.battery, "Type", "u")) |v| {
            defer v.unref();
            self.battery_present = self.battery_present and v.getUint32() == 2;
        }
        // Presence is only ever confirmed by an available DisplayDevice. A UPower
        // restart, reactivation, or bus drop leaves the last confirmed answer in
        // place instead of collapsing it to "no battery" and hiding the indicator.
        if (self.battery_available) self.battery_observed = self.battery_present;
        if (self.prop(.battery, "NativePath", "s")) |v| {
            defer v.unref();
            const identity = std.mem.span(v.getString(null));
            if (!std.mem.eql(u8, identity, self.battery_identity.slice())) self.history.len = 0;
            self.battery_identity.set(identity);
        }
        if (!self.battery_present or !was_present) self.history.len = 0;
        self.on_battery = self.boolean(.upower, "OnBattery");
        self.percentage = 0;
        self.percentage_valid = false;
        self.health = null;
        self.battery_state = 0;
        self.time_to_empty = 0;
        self.time_to_full = 0;
        if (self.prop(.battery, "Percentage", "d")) |v| {
            defer v.unref();
            const n = v.getDouble();
            if (presentation.validPercent(n)) |valid| {
                self.percentage = valid;
                self.percentage_valid = true;
            }
        }
        if (self.prop(.battery, "Capacity", "d")) |v| {
            defer v.unref();
            // UPower uses 0 for unknown capacity. Never infer health from charge.
            const capacity = presentation.validPercent(v.getDouble());
            if (capacity != null and capacity.? > 0) self.health = capacity;
        }
        if (self.battery_present) self.history.add(@divFloor(glib.getRealTime(), 1_000_000), if (self.percentage_valid) self.percentage else null);
        if (self.prop(.battery, "State", "u")) |v| {
            defer v.unref();
            self.battery_state = v.getUint32();
        }
        if (self.prop(.battery, "TimeToEmpty", "x")) |v| {
            defer v.unref();
            self.time_to_empty = @max(0, v.getInt64());
        }
        if (self.prop(.battery, "TimeToFull", "x")) |v| {
            defer v.unref();
            self.time_to_full = @max(0, v.getInt64());
        }
        // Only a reachable DisplayDevice can confirm charge state. An outage must
        // neither warn nor silently clear an in-progress low-battery episode.
        if (self.battery_available) self.alarm.update(self.battery_present and self.on_battery and self.battery_state == 2, if (self.percentage_valid) self.percentage else null);
        self.session_active = self.boolean(.session, "Active");
        if (!self.session_active or self.preparing) self.invalidateBrightness();
        self.profiles = .{ false, false, false };
        self.profile = .{};
        self.degraded = .{};
        if (self.profilesSlot()) |slot| {
            if (self.prop(slot.tag, "ActiveProfile", "s")) |v| {
                defer v.unref();
                self.profile.set(std.mem.span(v.getString(null)));
            }
            if (self.prop(slot.tag, "PerformanceDegraded", "s")) |v| {
                defer v.unref();
                self.degraded.set(std.mem.span(v.getString(null)));
            }
            if (self.prop(slot.tag, "Profiles", "aa{sv}")) |v| {
                defer v.unref();
                for (0..@min(v.nChildren(), 16)) |i| {
                    const item = v.getChildValue(i);
                    defer item.unref();
                    const lookup: *const fn (*glib.Variant, [*:0]const u8, ?*const glib.VariantType) callconv(.c) ?*glib.Variant = @ptrCast(&glib.Variant.lookupValue);
                    const val = lookup(item, "Profile", null) orelse continue;
                    defer val.unref();
                    if (is(val, "s")) for (profile_names, 0..) |name, j| {
                        if (std.mem.eql(u8, name, std.mem.span(val.getString(null)))) self.profiles[j] = true;
                    };
                }
            }
        }
        self.updateSaver();
        self.changed(self.context, .state);
    }
    pub fn configureSaver(self: *Power, threshold: u8) void {
        if (self.saver_threshold == threshold) return;
        self.saver_threshold = threshold;
        self.updateSaver();
    }
    /// Drains the low-battery level crossed since the last drain, if any.
    pub fn takeAlarm(self: *Power) ?presentation.Alarm.Level {
        return self.alarm.take();
    }
    pub fn plugged(self: *Power) bool {
        return presentation.Charge.of(self.battery_state).plugged();
    }
    fn updateSaver(self: *Power) void {
        var current: ?u8 = null;
        for (profile_names, 0..) |name, i| if (std.mem.eql(u8, self.profile.slice(), name)) {
            current = @intCast(i);
        };
        if (self.saver.update(self.saver_threshold, self.battery_present, self.on_battery and self.battery_state == 2, if (self.percentage_valid) self.percentage else null, current, self.profiles, self.profile_pending or self.profile_wanted != null)) |index| {
            self.profile_wanted = index;
            if (self.write_source == 0) self.write_source = glib.timeoutAdd(40, pump, self);
        }
    }
    pub fn dim(self: *Power, active: bool) void {
        for (self.displays.slice()) |*d| {
            if (active) {
                if (d.dim_restore != null or !self.deviceAvailable(d) or d.pending or d.wanted != null or d.percent() <= 20) continue;
                d.dim_restore = d.percent();
                d.wanted = 20;
            } else if (d.dim_restore != null) {
                if (!d.pending and d.wanted == 20) {
                    d.wanted = null;
                    d.dim_restore = null;
                } else d.dim_restoring = true;
            }
        }
        if (!active) self.scan();
        self.syncBrightness();
        self.arm();
    }
    pub fn selectedDisplay(self: *Power) ?*Backlight {
        return self.displays.find(self.selected_display.slice());
    }
    pub fn deviceAvailable(self: *Power, d: *const Backlight) bool {
        return self.session_active and !self.preparing and d.powered and d.maximum > 0 and d.reason == null and self.available(.session) != null;
    }
    pub fn brightnessAvailable(self: *Power) bool {
        return if (self.selectedDisplay()) |d| self.deviceAvailable(d) else false;
    }
    pub fn selectDisplay(self: *Power, id: []const u8) !void {
        const d = self.displays.resolve(id) orelse return error.Unavailable;
        self.selected_display = d.id;
        self.err = null;
        self.syncBrightness();
        self.changed(self.context, .state);
    }
    pub fn preferOutput(self: *Power, output: []const u8) void {
        if (!std.mem.eql(u8, self.preferred_output.slice(), output)) self.preferred_output.set(output);
        if (self.displays.resolve(output)) |d| {
            if (self.deviceAvailable(d)) self.selected_display = d.id;
        }
        self.syncBrightness();
    }
    pub fn setBrightness(self: *Power, percent: u8) !void {
        try self.setDisplayBrightness(null, percent);
    }
    pub fn adjustBrightness(self: *Power, target: ?[]const u8, delta: i16) !void {
        if (delta == 0 or delta < -100 or delta > 100) return error.InvalidValue;
        const d = (if (target) |id| self.displays.resolve(id) else self.selectedDisplay()) orelse return error.Unavailable;
        const base: i16 = d.wanted orelse d.requested orelse d.percent();
        try self.setDisplayBrightness(target, @intCast(std.math.clamp(base + delta, 0, 100)));
    }
    pub fn setDisplayBrightness(self: *Power, target: ?[]const u8, percent: u8) !void {
        const d = (if (target) |id| self.displays.resolve(id) else self.selectedDisplay()) orelse return error.Unavailable;
        _ = try d.raw(percent);
        if (!self.deviceAvailable(d)) return error.Unavailable;
        d.dim_restore = null;
        d.dim_restoring = false;
        d.write_error = null;
        d.wanted = percent;
        self.err = null;
        self.syncBrightness();
        self.arm();
    }
    pub fn displaySnapshot(self: *Power, alloc: std.mem.Allocator) ![]const presentation.DisplayBrightness {
        const list = try alloc.alloc(presentation.DisplayBrightness, self.displays.len);
        for (self.displays.slice(), list) |*d, *out| out.* = .{
            .id = try alloc.dupe(u8, d.id.slice()),
            .name = try alloc.dupe(u8, d.name.slice()),
            .output = try alloc.dupe(u8, d.output.slice()),
            .backend = d.backend,
            .available = self.deviceAvailable(d),
            .percent = d.percent(),
            .pending = d.pending or d.wanted != null,
            .reason = d.write_error orelse d.reason orelse "",
        };
        return list;
    }
    fn invalidateBrightness(self: *Power) void {
        if (self.write_cancel) |c| c.cancel();
        for (self.displays.slice()) |*d| {
            d.wanted = null;
            d.dim_restore = null;
            d.dim_restoring = false;
        }
        self.syncBrightness();
    }
    pub fn updateOutputPower(self: *Power, idle: anytype) void {
        self.output_states = @splat(.{});
        for (idle.outputs, 0..) |output, i| {
            if (output.proxy != null) self.output_states[i] = .{ .name = output.name, .powered = output.mode != .off };
        }
        self.mergeOutputs();
        self.syncBrightness();
        self.scan();
    }
    fn mergeOutputs(self: *Power) void {
        for (self.output_states) |output| {
            if (output.name.len == 0) continue;
            var matches: usize = 0;
            for (self.displays.slice()) |*d| if (std.mem.eql(u8, d.output.slice(), output.name.slice())) {
                d.powered = output.powered;
                matches += 1;
            };
            if (matches == 0) {
                var d: Backlight = .{ .name = output.name, .output = output.name, .powered = output.powered, .reason = "Brightness control is unavailable for this display." };
                var buf: [128]u8 = undefined;
                d.id.set(std.fmt.bufPrint(&buf, "output:{s}", .{output.name.slice()}) catch continue);
                if (self.displays.find(d.id.slice()) == null) self.displays.add(d);
            }
        }
    }
    pub fn brightnessBusy(self: *Power) bool {
        for (self.displays.slice()) |d| if (d.pending or d.wanted != null) return true;
        return false;
    }
    fn syncBrightness(self: *Power) void {
        if (self.selectedDisplay()) |d| {
            self.backlight = d.*;
            self.brightness_pending = d.pending;
            self.brightness_wanted = d.wanted;
        } else {
            self.backlight = .{};
            self.brightness_pending = false;
            self.brightness_wanted = null;
        }
    }
    pub fn setProfile(self: *Power, index: u8) !void {
        if (index >= 3 or !self.profiles[index] or self.profilesSlot() == null) return error.Unavailable;
        self.saver.manual();
        self.profile_wanted = index;
        self.err = null;
        self.arm();
    }
    pub fn brightnessGeneration(self: *Power) u64 {
        var hash = std.hash.Wyhash.init(self.slots[@intFromEnum(Tag.session)].generation);
        hash.update(self.selected_display.slice());
        if (self.selectedDisplay()) |d| hash.update(std.mem.asBytes(&d.generation));
        return hash.final();
    }
    pub fn profileGeneration(self: *Power) u64 {
        const slot = self.profilesSlot() orelse return 0;
        var hash = std.hash.Wyhash.init(slot.generation);
        hash.update(@tagName(slot.tag));
        return hash.final();
    }
    pub fn epoch(self: *Power) u64 {
        return self.slots[@intFromEnum(Tag.login)].generation;
    }
    pub fn powerAction(self: *Power, reboot: bool) !void {
        if (self.action_pending) return error.Busy;
        if (self.preparing or !(if (reboot) self.can_reboot else self.can_off)) return error.Unavailable;
        const slot = self.available(.login) orelse return error.Unavailable;
        try self.call(slot, if (reboot) .reboot else .power_off, if (reboot) "Reboot" else "PowerOff", tuple(&.{glib.Variant.newBoolean(0)}), null);
        self.action_pending = true;
        self.err = null;
        self.changed(self.context, .state);
    }
    // The session identity is not resolved here: the verified lifecycle result
    // is pushed in, and an unchanged path is a no-op so notification storms do
    // not thrash the proxy. Closing the slot first drops in-flight writes via
    // the generation check in called().
    pub fn useSession(self: *Power, path: [:0]const u8) void {
        if (std.mem.eql(u8, self.session_path.slice(), path)) return;
        self.invalidateBrightness();
        self.session_path.set(path);
        self.session_active = false;
        self.brightness_wanted = null;
        self.brightness_pending = false;
        const slot = &self.slots[@intFromEnum(Tag.session)];
        closeSlot(slot);
        if (path.len != 0) self.create(slot);
        self.refresh();
    }
    fn arm(self: *Power) void {
        if (self.write_source == 0) self.write_source = glib.timeoutAdd(40, pump, self);
        self.changed(self.context, .state);
    }
    fn pump(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Power = @ptrCast(@alignCast(data.?));
        self.write_source = 0;
        if (!self.brightness_io_pending and !self.scan_pending) {
            for (self.displays.slice()) |*d| if (d.wanted) |percent| {
                d.wanted = null;
                if (!self.deviceAvailable(d)) {
                    d.dim_restore = null;
                    continue;
                }
                self.startBrightnessWrite(d, percent) catch {
                    self.err = "Brightness request failed.";
                    self.changed(self.context, .failure);
                };
                break;
            };
            self.syncBrightness();
        }
        if (!self.profile_pending) if (self.profile_wanted) |index| {
            self.profile_wanted = null;
            if (self.profilesSlot()) |slot| {
                if (!self.profiles[index]) return 0;
                self.call(slot, .profile, "Set", tuple(&.{ glib.Variant.newString(interfaces[@intFromEnum(slot.tag)]), glib.Variant.newString("ActiveProfile"), glib.Variant.newVariant(glib.Variant.newString(profile_names[index])) }), "org.freedesktop.DBus.Properties") catch {
                    self.err = "Power profile request failed.";
                    self.changed(self.context, .failure);
                    return 0;
                };
                self.profile_pending = true;
            }
        };
        return 0;
    }
    fn call(self: *Power, slot: *Slot, purpose: Purpose, method: [:0]const u8, parameters: ?*glib.Variant, interface: ?[:0]const u8) !void {
        // Sink parameters locally too, so an allocation failure does not leak them.
        if (parameters) |v| _ = v.refSink();
        defer if (parameters) |v| v.unref();
        if (slot.owner.len == 0 or slot.proxy == null) return error.Unavailable;
        const job = try a.create(Call);
        job.* = .{ .service = self, .tag = slot.tag, .generation = slot.generation, .purpose = purpose };
        self.app.hold();
        const reply_type = glib.VariantType.new(switch (purpose) {
            .can_off, .can_reboot => "(s)",
            else => "()",
        });
        defer reply_type.free();
        slot.proxy.?.getConnection().call(slot.owner.z(), if (slot.tag == .session) self.session_path.z() else paths[@intFromEnum(slot.tag)], interface orelse interfaces[@intFromEnum(slot.tag)], method, parameters, reply_type, .{ .no_auto_start = true }, 3000, self.cancel, called, job);
    }
    fn called(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const job: *Call = @ptrCast(@alignCast(data.?));
        const self = job.service;
        defer self.app.release();
        defer a.destroy(job);
        var err: ?*glib.Error = null;
        const value = object.ext.cast(gio.DBusConnection, source.?).?.callFinish(result, &err);
        defer if (value) |v| v.unref();
        defer if (err) |e| e.free();
        if (!self.running or self.slots[@intFromEnum(job.tag)].generation != job.generation) return;
        if (job.purpose == .can_off) self.capability_pending[0] = false;
        if (job.purpose == .can_reboot) self.capability_pending[1] = false;
        const mutation = job.purpose == .brightness or job.purpose == .profile or job.purpose == .power_off or job.purpose == .reboot;
        switch (job.purpose) {
            .brightness => self.brightness_pending = false,
            .profile => self.profile_pending = false,
            .power_off, .reboot => self.action_pending = false,
            else => {},
        }
        if (value) |v| {
            switch (job.purpose) {
                .can_off, .can_reboot => if (is(v, "(s)")) {
                    const text = v.getChildValue(0);
                    defer text.unref();
                    const yes = std.mem.eql(u8, std.mem.span(text.getString(null)), "yes");
                    if (job.purpose == .can_off) self.can_off = yes else self.can_reboot = yes;
                },
                .brightness => {
                    self.feedback = .brightness;
                    self.scan();
                },
                else => {},
            }
            if (mutation) {
                self.err = null;
                if (job.purpose != .brightness) self.changed(self.context, .applied);
            }
        } else if (mutation) {
            self.err = if (err) |e| blk: {
                if (gio.DBusError.isRemoteError(e) != 0) {
                    const name = gio.DBusError.getRemoteError(e);
                    defer if (name) |n| glib.free(n);
                    if (name) |n| if (std.mem.indexOf(u8, std.mem.span(n), "AccessDenied") != null or std.mem.indexOf(u8, std.mem.span(n), "NotAuthorized") != null or std.mem.indexOf(u8, std.mem.span(n), "InteractiveAuthorizationRequired") != null) break :blk "Permission denied. No change was applied.";
                }
                break :blk "Service did not confirm the change. Refresh before retrying.";
            } else "Service did not confirm the change.";
            switch (job.purpose) {
                .brightness => self.brightness_wanted = null,
                .profile => {
                    self.profile_wanted = null;
                    self.saver.failed();
                },
                else => {},
            }
            self.changed(self.context, .failure);
        }
        self.refresh();
        if (self.brightness_wanted != null or self.profile_wanted != null) self.arm();
    }
    pub fn acquireView(self: *Power) !Owner {
        const token = try self.interest.acquire();
        if (!self.panel_open) self.panel(true);
        return token;
    }
    pub fn releaseView(self: *Power, token: Owner) void {
        if (self.interest.release(token) and self.interest.count() == 0) self.panel(false);
    }
    pub fn revokeViews(self: *Power) void {
        self.interest.revoke();
        self.panel(false);
    }
    fn panel(self: *Power, open: bool) void {
        if (open and !self.panel_open) self.capabilities();
        self.panel_open = open;
        if (open) self.scan();
    }
    fn poll(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Power = @ptrCast(@alignCast(data.?));
        if (!self.running) return 0;
        self.scan();
        return 1;
    }
    fn backlightChanged(_: *gio.FileMonitor, _: *gio.File, _: ?*gio.File, _: gio.FileMonitorEvent, self: *Power) callconv(.c) void {
        self.scan();
    }
    // The directory monitor only reports device add/remove; a single-file monitor on the
    // selected backlight's brightness attribute reports writes by any external writer.
    fn watchBrightness(self: *Power) void {
        if (self.brightness_monitor != null and self.backlight.backend == .backlight and self.backlight.maximum > 0 and std.mem.eql(u8, self.monitored.slice(), self.backlight.name.slice())) return;
        self.unwatchBrightness();
        if (self.backlight.maximum == 0 or self.backlight.backend != .backlight) return;
        var buffer: [768]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buffer, "{s}/{s}/brightness", .{ self.backlight_root.slice(), self.backlight.name.slice() }) catch return;
        const file = gio.File.newForPath(path.ptr);
        defer file.unref();
        const monitor = file.monitor(.{}, self.cancel, null) orelse return;
        self.brightness_monitor = monitor;
        self.brightness_monitor_signal = gio.FileMonitor.signals.changed.connect(monitor, *Power, backlightChanged, self, .{});
        self.monitored.set(self.backlight.name.slice());
    }
    fn unwatchBrightness(self: *Power) void {
        if (self.brightness_monitor) |m| {
            object.signalHandlerDisconnect(m.as(object.Object), self.brightness_monitor_signal);
            _ = m.cancel();
            m.unref();
        }
        self.brightness_monitor = null;
        self.brightness_monitor_signal = 0;
        self.monitored = .{};
    }
    pub fn scan(self: *Power) void {
        if (!self.running) return;
        if (self.scan_pending or self.brightness_io_pending) {
            self.scan_again = true;
            return;
        }
        const job = a.create(Scan) catch return;
        job.* = .{ .service = self, .root = self.backlight_root, .drm = self.drm_root };
        self.scan_pending = true;
        self.app.hold();
        const task = gio.Task.new(self.app.as(object.Object), self.cancel, scanned, job);
        task.setTaskData(job, null);
        _ = task.setReturnOnCancel(0);
        task.runInThread(scanThread);
        task.unref();
    }
    fn scanThread(task: *gio.Task, _: *object.Object, data: ?*anyopaque, cancel: ?*gio.Cancellable) callconv(.c) void {
        const job: *Scan = @ptrCast(@alignCast(data.?));
        job.result = brightness_io.scan(job.root.z(), job.drm.z(), cancel.?);
        task.returnBoolean(1);
    }
    fn scanned(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const job: *Scan = @ptrCast(@alignCast(data.?));
        const self = job.service;
        defer self.app.release();
        defer a.destroy(job);
        var err: ?*glib.Error = null;
        _ = object.ext.cast(gio.Task, result).?.propagateBoolean(&err);
        defer if (err) |e| e.free();
        self.scan_pending = false;
        if (!self.running) return;
        for (job.result.slice()) |*d| {
            if (self.displays.find(d.id.slice())) |old| {
                d.generation = old.generation;
                d.write_error = if (d.reason == null and d.value != old.value) null else old.write_error;
                // Sleeping or temporarily inaccessible DDC displays keep the
                // last confirmed value; availability is reported separately.
                if (d.backend == .ddc and d.reason != null) {
                    d.maximum = old.maximum;
                    d.value = old.value;
                }
                d.powered = old.powered;
                d.wanted = old.wanted;
                d.observed = old.observed;
                d.dim_restore = old.dim_restore;
                d.dim_restoring = old.dim_restoring;
                if (d.backend != old.backend or d.maximum != old.maximum) {
                    self.next_brightness_generation += 1;
                    d.generation = self.next_brightness_generation;
                    d.wanted = null;
                    d.dim_restore = null;
                    d.observed = .{};
                }
                if (d.dim_restore) |before| {
                    if (!self.session_active or self.preparing) {
                        d.dim_restore = null;
                        d.dim_restoring = false;
                    } else if (d.powered and d.reason == null and d.wanted == null) {
                        if (d.dim_restoring) {
                            d.dim_restoring = false;
                            d.dim_restore = null;
                            if (d.percent() == 20) d.wanted = before;
                        } else if (d.percent() != 20) d.dim_restore = null;
                    }
                }
            } else {
                self.next_brightness_generation += 1;
                d.generation = self.next_brightness_generation;
            }
        }
        self.displays = job.result;
        self.mergeOutputs();
        if (self.selectedDisplay() == null) {
            self.selected_display = .{};
            for (self.displays.slice()) |d| if (d.maximum > 0 and d.reason == null) {
                self.selected_display = d.id;
                break;
            };
            if (self.selected_display.len == 0 and self.displays.len > 0) self.selected_display = self.displays.items[0].id;
            if (self.preferred_output.len != 0) self.preferOutput(self.preferred_output.slice());
        }
        self.syncBrightness();
        self.watchBrightness();
        for (self.displays.slice()) |*d| self.observeBrightness(d);
        self.changed(self.context, .state);
        if (self.scan_again) {
            self.scan_again = false;
            self.scan();
        }
        self.arm();
    }
    fn observeBrightness(self: *Power, d: *Backlight) void {
        self.brightness_change = d.observed.observe(if (d.maximum > 0 and d.reason == null) d.snapshot() else null);
        self.observed = d.observed;
        if (self.brightness_change == .brightness) {
            self.feedback = .brightness;
            self.changed(self.context, .applied);
            self.feedback = null;
        }
        self.brightness_change = null;
    }
    fn startBrightnessWrite(self: *Power, d: *Backlight, percent: u8) !void {
        const slot = self.available(.session) orelse return error.Unavailable;
        const job = try a.create(BrightnessWrite);
        job.* = .{ .service = self, .device = d.*, .percent = percent, .session_generation = slot.generation, .root = self.backlight_root, .drm = self.drm_root, .owner = slot.owner, .path = self.session_path };
        if (d.backend == .backlight) {
            job.connection = slot.proxy.?.getConnection();
            job.connection.?.ref();
        }
        d.pending = true;
        d.requested = percent;
        self.brightness_io_pending = true;
        self.app.hold();
        self.write_cancel = gio.Cancellable.new();
        const task = gio.Task.new(self.app.as(object.Object), self.write_cancel, brightnessWritten, job);
        task.setTaskData(job, null);
        _ = task.setReturnOnCancel(0);
        task.runInThread(brightnessThread);
        task.unref();
    }
    fn brightnessThread(task: *gio.Task, _: *object.Object, data: ?*anyopaque, cancel: ?*gio.Cancellable) callconv(.c) void {
        const job: *BrightnessWrite = @ptrCast(@alignCast(data.?));
        if (job.device.backend == .ddc) {
            job.reason = brightness_io.writeDdc(&job.device, job.percent, job.drm.z(), cancel.?);
        } else {
            const raw = job.device.raw(job.percent) catch {
                task.returnBoolean(0);
                return;
            };
            const args = tuple(&.{ glib.Variant.newString("backlight"), glib.Variant.newString(job.device.name.z()), glib.Variant.newUint32(raw) });
            _ = args.refSink();
            defer args.unref();
            var err: ?*glib.Error = null;
            const result = job.connection.?.callSync(job.owner.z(), job.path.z(), interfaces[@intFromEnum(Tag.session)], "SetBrightness", args, null, .{ .no_auto_start = true }, 3000, cancel, &err);
            defer if (err) |e| e.free();
            if (result) |r| {
                r.unref();
                var fresh = brightness_io.scan(job.root.z(), "", cancel.?);
                if (fresh.find(job.device.id.slice())) |d| {
                    job.device.value = d.value;
                    job.device.maximum = d.maximum;
                } else job.reason = "Backlight disappeared; final brightness was not confirmed.";
            } else {
                job.reason = "Brightness request failed. Check active session and device permissions.";
                if (err) |e| if (gio.DBusError.isRemoteError(e) != 0) {
                    const name = gio.DBusError.getRemoteError(e);
                    defer if (name) |n| glib.free(n);
                    if (name) |n| if (std.mem.indexOf(u8, std.mem.span(n), "AccessDenied") != null or std.mem.indexOf(u8, std.mem.span(n), "NotAuthorized") != null) {
                        job.reason = "Permission denied. No change was applied.";
                    };
                };
            }
        }
        task.returnBoolean(1);
    }
    fn detachedBrightnessWritten(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const job: *BrightnessWrite = @ptrCast(@alignCast(data.?));
        defer a.destroy(job);
        defer job.service.app.release();
        if (job.connection) |connection| connection.unref();
        var err: ?*glib.Error = null;
        _ = object.ext.cast(gio.Task, result).?.propagateBoolean(&err);
        if (err) |e| e.free();
    }
    fn brightnessWritten(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const job: *BrightnessWrite = @ptrCast(@alignCast(data.?));
        const self = job.service;
        defer self.app.release();
        defer a.destroy(job);
        defer if (job.connection) |c| c.unref();
        var err: ?*glib.Error = null;
        _ = object.ext.cast(gio.Task, result).?.propagateBoolean(&err);
        defer if (err) |e| e.free();
        self.brightness_io_pending = false;
        if (self.write_cancel) |c| c.unref();
        self.write_cancel = null;
        if (!self.running) return;
        if (self.displays.find(job.device.id.slice())) |d| {
            d.pending = false;
            d.requested = null;
            if (err == null and self.slots[@intFromEnum(Tag.session)].generation == job.session_generation and d.generation == job.device.generation) {
                if (job.reason) |reason| {
                    d.wanted = null;
                    d.dim_restore = null;
                    d.dim_restoring = false;
                    d.write_error = reason;
                    self.err = reason;
                    self.syncBrightness();
                    self.changed(self.context, .failure);
                } else {
                    d.value = job.device.value;
                    self.syncBrightness();
                    self.observeBrightness(d);
                }
            } else {
                d.wanted = null;
                d.dim_restore = null;
            }
        }
        self.syncBrightness();
        self.changed(self.context, .state);
        if (self.scan_again) {
            self.scan_again = false;
            self.scan();
        }
        self.arm();
    }
};
fn tuple(values: []const *glib.Variant) *glib.Variant {
    return glib.Variant.newTuple(values.ptr, values.len);
}
fn is(value: *glib.Variant, signature: [:0]const u8) bool {
    return std.mem.eql(u8, std.mem.span(value.getTypeString()), signature);
}
