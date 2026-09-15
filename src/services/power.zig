//! Bounded asynchronous system-bus proxies. Mutations target a captured unique owner.
const std = @import("std");
const ownership = @import("view_ownership.zig");
pub const Owner = ownership.Owner;
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const policy = @import("policy.zig");
const Text = policy.Text;
const a = std.heap.c_allocator;
pub const Event = @import("audio.zig").Event;
const Tag = enum { battery, upower, login, session, profiles, legacy_profiles };
const names = [_][:0]const u8{ "org.freedesktop.UPower", "org.freedesktop.UPower", "org.freedesktop.login1", "org.freedesktop.login1", "org.freedesktop.UPower.PowerProfiles", "net.hadess.PowerProfiles" };
const paths = [_][:0]const u8{ "/org/freedesktop/UPower/devices/DisplayDevice", "/org/freedesktop/UPower", "/org/freedesktop/login1", "", "/org/freedesktop/UPower/PowerProfiles", "/net/hadess/PowerProfiles" };
const interfaces = [_][:0]const u8{ "org.freedesktop.UPower.Device", "org.freedesktop.UPower", "org.freedesktop.login1.Manager", "org.freedesktop.login1.Session", "org.freedesktop.UPower.PowerProfiles", "net.hadess.PowerProfiles" };
const Slot = struct { service: *Power, tag: Tag, proxy: ?*gio.DBusProxy = null, creating: bool = false, generation: u64 = 0, owner: Text(256) = .{}, bus_signal: c_ulong = 0, signals: [3]c_ulong = .{ 0, 0, 0 } };
const Creation = struct { slot: *Slot, generation: u64 };
const Purpose = enum { can_off, can_reboot, session, brightness, profile, power_off, reboot };
const Call = struct { service: *Power, tag: Tag, generation: u64, purpose: Purpose };
pub const Backlight = struct {
    name: Text(128) = .{},
    maximum: u32 = 0,
    value: u32 = 0,
    pub fn percent(self: Backlight) u8 {
        return if (self.maximum == 0) 0 else @intCast(@min(100, (@as(u64, self.value) * 100 + self.maximum / 2) / self.maximum));
    }
};
const Scan = struct { service: *Power, root: Text(512), preferred: Text(128), result: Backlight = .{} };
pub const Power = struct {
    app: *gio.Application,
    context: *anyopaque,
    changed: *const fn (*anyopaque, Event) void,
    slots: [6]Slot = undefined,
    cancel: *gio.Cancellable = undefined,
    running: bool = false,
    retry_source: c_uint = 0,
    battery_present: bool = false,
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
    backlight: Backlight = .{},
    backlight_root: Text(512) = .{},
    scan_pending: bool = false,
    scan_again: bool = false,
    monitor: ?*gio.FileMonitor = null,
    monitor_signal: c_ulong = 0,
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
        self.scan();
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
        self.running = false;
        self.interest.revoke();
        self.panel_open = false;
        self.cancel.cancel();
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
                    if (name.len != 0) {
                        self.capabilities();
                        self.call(slot, .session, "GetSessionByPID", tuple(&.{glib.Variant.newUint32(@intCast(std.c.getpid()))}), null) catch {};
                    }
                },
                .profiles, .legacy_profiles => {
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
        self.battery_present = self.boolean(.battery, "IsPresent");
        self.on_battery = self.boolean(.upower, "OnBattery");
        self.percentage = 0;
        self.battery_state = 0;
        self.time_to_empty = 0;
        self.time_to_full = 0;
        if (self.prop(.battery, "Percentage", "d")) |v| {
            defer v.unref();
            const n = v.getDouble();
            if (std.math.isFinite(n) and n >= 0 and n <= 100) self.percentage = n else self.battery_present = false;
        }
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
        self.session_active = self.boolean(.session, "Active");
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
        self.changed(self.context, .state);
    }
    pub fn brightnessAvailable(self: *Power) bool {
        return self.session_active and !self.preparing and self.backlight.maximum > 0 and self.available(.session) != null;
    }
    pub fn setBrightness(self: *Power, percent: u8) !void {
        _ = try policy.brightness(percent, self.backlight.maximum);
        if (!self.brightnessAvailable()) return error.Unavailable;
        self.brightness_wanted = percent;
        self.err = null;
        self.arm();
    }
    pub fn setProfile(self: *Power, index: u8) !void {
        if (index >= 3 or !self.profiles[index] or self.profilesSlot() == null) return error.Unavailable;
        self.profile_wanted = index;
        self.err = null;
        self.arm();
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
    fn arm(self: *Power) void {
        if (self.write_source == 0) self.write_source = glib.timeoutAdd(40, pump, self);
        self.changed(self.context, .state);
    }
    fn pump(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Power = @ptrCast(@alignCast(data.?));
        self.write_source = 0;
        if (!self.brightness_pending) if (self.brightness_wanted) |percent| {
            self.brightness_wanted = null;
            if (self.brightnessAvailable()) {
                const value = policy.brightness(percent, self.backlight.maximum) catch return 0;
                self.call(self.available(.session).?, .brightness, "SetBrightness", tuple(&.{ glib.Variant.newString("backlight"), glib.Variant.newString(self.backlight.name.z()), glib.Variant.newUint32(value) }), null) catch {
                    self.err = "Brightness request failed.";
                    self.changed(self.context, .failure);
                    return 0;
                };
                self.brightness_pending = true;
            } else {
                self.err = "Backlight or active session disappeared.";
                self.changed(self.context, .failure);
            }
        };
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
            .session => "(o)",
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
                .session => if (is(v, "(o)")) {
                    const path = v.getChildValue(0);
                    defer path.unref();
                    const text = std.mem.span(path.getString(null));
                    if (std.mem.startsWith(u8, text, "/org/freedesktop/login1/session/") and text.len < 512) {
                        self.session_path.set(text);
                        self.create(&self.slots[@intFromEnum(Tag.session)]);
                    }
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
                .profile => self.profile_wanted = null,
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
        if (self.poll_source != 0) _ = glib.Source.remove(self.poll_source);
        self.poll_source = 0;
        if (open) {
            self.scan();
            if (self.backlight.maximum > 0) self.poll_source = glib.timeoutAdd(2000, poll, self);
        }
    }
    fn poll(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Power = @ptrCast(@alignCast(data.?));
        self.poll_source = 0;
        if (self.panel_open) self.panel(true);
        return 0;
    }
    fn backlightChanged(_: *gio.FileMonitor, _: *gio.File, _: ?*gio.File, _: gio.FileMonitorEvent, self: *Power) callconv(.c) void {
        self.scan();
    }
    pub fn scan(self: *Power) void {
        if (!self.running) return;
        if (self.scan_pending) {
            self.scan_again = true;
            return;
        }
        const job = a.create(Scan) catch return;
        job.* = .{ .service = self, .root = self.backlight_root, .preferred = self.backlight.name };
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
        const dir = glib.Dir.open(job.root.z(), 0, null) orelse {
            task.returnBoolean(1);
            return;
        };
        defer dir.close();
        // GIR misses g_dir_read_name's nullable end-of-directory return.
        const read: *const fn (*glib.Dir) callconv(.c) ?[*:0]const u8 = @ptrCast(&glib.Dir.readName);
        var count: usize = 0;
        while (read(dir)) |name| : (count += 1) {
            if (count >= 64 or (cancel != null and cancel.?.isCancelled() != 0)) break;
            const text = std.mem.span(name);
            if (!policy.deviceName(text)) continue;
            var buffer: [768]u8 = undefined;
            const maxpath = std.fmt.bufPrintZ(&buffer, "{s}/{s}/max_brightness", .{ job.root.slice(), text }) catch continue;
            const max = readNumber(maxpath) orelse continue;
            if (max == 0 or max > std.math.maxInt(i32)) continue;
            const path = std.fmt.bufPrintZ(&buffer, "{s}/{s}/brightness", .{ job.root.slice(), text }) catch continue;
            const value = readNumber(path) orelse continue;
            if (value > max) continue;
            if (job.result.maximum == 0 or std.mem.eql(u8, text, job.preferred.slice()) or (!std.mem.eql(u8, job.result.name.slice(), job.preferred.slice()) and std.mem.order(u8, text, job.result.name.slice()) == .lt)) {
                job.result = .{ .maximum = max, .value = value };
                job.result.name.set(text);
            }
        }
        task.returnBoolean(1);
    }
    fn readNumber(path: [:0]const u8) ?u32 {
        var data: [*]u8 = undefined;
        var len: usize = 0;
        if (glib.fileGetContents(path, &data, &len, null) == 0) return null;
        defer glib.free(data);
        if (len > 32) return null;
        return std.fmt.parseInt(u32, std.mem.trim(u8, data[0..len], " \t\r\n"), 10) catch null;
    }
    fn scanned(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const job: *Scan = @ptrCast(@alignCast(data.?));
        const self = job.service;
        defer self.app.release();
        defer a.destroy(job);
        const task = object.ext.cast(gio.Task, result).?;
        var err: ?*glib.Error = null;
        _ = task.propagateBoolean(&err);
        if (err) |e| e.free();
        self.scan_pending = false;
        if (!self.running) return;
        if (!std.mem.eql(u8, self.backlight.name.slice(), job.result.name.slice())) self.brightness_wanted = null;
        self.backlight = job.result;
        if (self.feedback != null and self.backlight.maximum == 0) {
            self.err = "Backlight unavailable after the change; final brightness was not confirmed.";
            self.changed(self.context, .failure);
        } else self.changed(self.context, if (self.feedback != null) .applied else .state);
        self.feedback = null;
        if (self.scan_again) {
            self.scan_again = false;
            self.scan();
        }
    }
};
fn tuple(values: []const *glib.Variant) *glib.Variant {
    return glib.Variant.newTuple(values.ptr, values.len);
}
fn is(value: *glib.Variant, signature: [:0]const u8) bool {
    return std.mem.eql(u8, std.mem.span(value.getTypeString()), signature);
}
