//! Scheduling profiles applied through scx.service. Pearl watches the unit over
//! systemd's D-Bus API, so state changes arrive without polling, and changes it
//! only through pearl-scheduling-helper.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const p = @import("sched_profiles.zig");
const store = @import("sched_profiles_store.zig");
const Kernel = p.Kernel;
const log = std.log.scoped(.services);
const a = std.heap.c_allocator;
const systemd = "org.freedesktop.systemd1";

pub const Service = struct {
    app: *gio.Application,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    /// Changes are allowed only while the session is unlocked and ready.
    enabled: bool = false,
    /// Only the shell reports failures, so Settings does not duplicate them.
    notify: bool = true,
    running: bool = false,
    cancel: ?*gio.Cancellable = null,
    manager: ?*gio.DBusProxy = null,
    unit: ?*gio.DBusProxy = null,
    unit_signal: c_ulong = 0,
    /// The same unit's Service interface, for how its process last ended.
    process: ?*gio.DBusProxy = null,
    arena: std.heap.ArenaAllocator = .init(a),
    /// Null when no profile file is installed or it is invalid.
    config: ?p.Config = null,
    /// Why the profile file could not be used.
    problem: ?[:0]const u8 = null,
    env: p.Env = .{},
    status: p.Status = .{},
    unit_state: p.Unit = .unknown,
    kernel: Kernel = .unavailable,
    /// The attached scheduler's name, from /sys/kernel/sched_ext/root/ops.
    ops: []const u8 = "",
    ops_buffer: [128]u8 = undefined,
    /// When the unit last became active, and last started, in microseconds
    /// since the epoch; 0 when unknown.
    active_since: u64 = 0,
    started: u64 = 0,
    /// Why the selected scheduler stopped, once known.
    reason: ?[:0]const u8 = null,
    reason_buffer: [320]u8 = undefined,
    /// Profile id being applied; the helper is still running.
    applying: ?[]const u8 = null,
    applying_buffer: [32]u8 = undefined,
    err: ?[:0]const u8 = null,
    err_buffer: [512]u8 = undefined,
    /// Rechecks while a scheduler attaches; the kernel side has no signal.
    settle_source: c_uint = 0,
    settle_attempts: u8 = 0,
    /// A failure is reported once, after it outlasts a restart's brief gap.
    failure_source: c_uint = 0,
    notified: bool = false,

    pub fn start(self: *Service) void {
        self.running = true;
        self.cancel = gio.Cancellable.new();
        self.refresh();
        self.app.hold();
        gio.DBusProxy.newForBus(.system, .{ .do_not_load_properties = true }, null, systemd, "/org/freedesktop/systemd1", systemd ++ ".Manager", self.cancel, managerReady, self);
    }

    pub fn stop(self: *Service) void {
        self.running = false;
        if (self.settle_source != 0) _ = glib.Source.remove(self.settle_source);
        if (self.failure_source != 0) _ = glib.Source.remove(self.failure_source);
        self.settle_source = 0;
        self.failure_source = 0;
        if (self.cancel) |cancel| {
            cancel.cancel();
            cancel.unref();
        }
        self.cancel = null;
        if (self.unit) |proxy| {
            object.signalHandlerDisconnect(proxy.as(object.Object), self.unit_signal);
            proxy.unref();
        }
        if (self.process) |proxy| proxy.unref();
        self.process = null;
        if (self.manager) |proxy| proxy.unref();
        self.unit = null;
        self.manager = null;
        self.arena.deinit();
    }

    /// One line on what the scheduler is doing, shared by the flyout and
    /// Settings. A running profile is only reported once the kernel shows its
    /// scheduler attached, with the version it reports and when it started.
    pub fn describe(self: *const Service, buffer: []u8, german: bool) [:0]const u8 {
        const t = struct {
            fn pick(de: bool, en: [:0]const u8, de_text: [:0]const u8) [:0]const u8 {
                return if (de) de_text else en;
            }
        }.pick;
        if (self.problem) |problem| return problem;
        const profile: ?p.Profile = if (self.config) |c| if (self.status.profile) |i| c.profiles[i] else null else null;
        const name = if (profile) |value| value.label else "";
        return switch (self.status.kind) {
            .unavailable => if (self.config == null) t(german, "No scheduler profiles are installed.", "Es sind keine Scheduler-Profile installiert.") else if (self.kernel == .unavailable) t(german, "This kernel does not support sched_ext schedulers.", "Dieser Kernel unterstützt keine sched_ext-Scheduler.") else if (self.unit_state == .missing) t(german, "scx.service is not installed.", "scx.service ist nicht installiert.") else t(german, "Checking the scheduler...", "Scheduler wird geprüft..."),
            .off => std.fmt.bufPrintZ(buffer, "{s} - {s}", .{ name, t(german, "kernel scheduler (EEVDF)", "Kernel-Scheduler (EEVDF)") }) catch "",
            .running => blk: {
                const sched = self.env.sched;
                const version = p.opsVersion(sched, self.ops);
                var time: [48]u8 = undefined;
                const uptime = self.since(&time, german);
                break :blk std.fmt.bufPrintZ(buffer, "{s} - {s}{s}{s}{s}{s}", .{
                    t(german, "Running", "Läuft"),
                    sched,
                    if (version != null) " " else "",
                    version orelse "",
                    if (uptime.len > 0) " - " else "",
                    uptime,
                }) catch "";
            },
            .starting => if (profile != null and profile.?.stop) t(german, "Stopping the scheduler...", "Scheduler wird beendet...") else std.fmt.bufPrintZ(buffer, "{s} {s}...", .{ t(german, "Starting", "Starte"), name }) catch "",
            .failed => if (self.reason) |reason| std.fmt.bufPrintZ(buffer, "{s} {s}: {s}. {s}", .{ name, t(german, "stopped", "wurde beendet"), reason, t(german, "The kernel's default scheduler is running.", "Der Standard-Scheduler des Kernels läuft.") }) catch "" else std.fmt.bufPrintZ(buffer, "{s} {s}", .{ name, t(german, "stopped unexpectedly; the kernel's default scheduler is running.", "wurde unerwartet beendet; der Standard-Scheduler des Kernels läuft.") }) catch "",
            .custom => if (self.ops.len > 0) std.fmt.bufPrintZ(buffer, "{s} - scx_{s} {s}", .{ t(german, "Custom", "Benutzerdefiniert"), opsName(self.ops), t(german, "is running outside these profiles.", "läuft außerhalb dieser Profile.") }) catch "" else t(german, "Custom - a scheduler configured outside these profiles is running.", "Benutzerdefiniert - ein Scheduler außerhalb dieser Profile läuft."),
        };
    }

    /// A profile was chosen in the last few seconds and the running instance
    /// predates it, so the previous scheduler may still be on its way out.
    fn switching(self: *const Service) bool {
        var stat: std.os.linux.Statx = std.mem.zeroes(std.os.linux.Statx);
        if (std.os.linux.statx(std.os.linux.AT.FDCWD, p.env_path, 0, .{ .MTIME = true }, &stat) != 0) return false;
        const written: i64 = stat.mtime.sec * std.time.us_per_s + @divTrunc(stat.mtime.nsec, std.time.ns_per_us);
        const now = glib.getRealTime();
        return written > @as(i64, @intCast(self.active_since)) and now - written < 15 * std.time.us_per_s;
    }

    /// "since 10:28", with the date when it started on another day.
    fn since(self: *const Service, buffer: []u8, german: bool) []const u8 {
        if (self.active_since == 0) return "";
        const started = glib.DateTime.newFromUnixLocal(@intCast(self.active_since / std.time.us_per_s)) orelse return "";
        defer started.unref();
        const now = glib.DateTime.newNowLocal() orelse return "";
        defer now.unref();
        const today = started.getYear() == now.getYear() and started.getDayOfYear() == now.getDayOfYear();
        const text = started.format(if (today) "%H:%M" else "%e %b, %H:%M") orelse return "";
        defer glib.free(text);
        return std.fmt.bufPrint(buffer, "{s} {s}", .{ if (german) "seit" else "since", std.mem.trim(u8, std.mem.span(text), " ") }) catch "";
    }

    pub fn configured(self: *const Service) bool {
        return self.config != null or self.problem != null;
    }

    /// Reread the profile file, /etc/default/scx and sched_ext state, and
    /// combine them with the unit state last reported by systemd.
    pub fn refresh(self: *Service) void {
        _ = self.arena.reset(.retain_capacity);
        const alloc = self.arena.allocator();
        self.config = null;
        self.problem = null;
        if (store.load(alloc)) |loaded| {
            if (loaded) |file| self.config = file.config;
        } else |err| {
            self.problem = std.fmt.allocPrintSentinel(alloc, "Scheduler profiles could not be read ({s}).", .{@errorName(err)}, 0) catch "Scheduler profiles could not be read.";
        }
        self.env = store.readEnv(alloc) catch .{};
        self.kernel = kernelState();
        self.ops = readOps(&self.ops_buffer);
        self.status = if (self.config) |config| p.status(config, self.env, self.unit_state, self.kernel, self.ops, self.switching()) else .{};
        // A restart passes through inactive, and the file is written before
        // the unit restarts; report a failure only if it persists.
        if (self.status.kind != .failed) {
            self.notified = false;
            self.reason = null;
            if (self.failure_source != 0) _ = glib.Source.remove(self.failure_source);
            self.failure_source = 0;
        } else if (!self.notified and self.applying == null and self.failure_source == 0) {
            self.failure_source = glib.timeoutAdd(3000, failureCheck, self);
        }
        if (self.status.kind == .starting) self.settle() else self.settle_attempts = 0;
        self.changed(self.context);
    }

    fn failureCheck(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data.?));
        self.failure_source = 0;
        // Every unit change already refreshed the status.
        if (self.status.kind == .failed and !self.notified and self.applying == null) {
            self.notified = true;
            self.readReason();
        }
        return 0;
    }

    /// Read why the scheduler stopped from the log of its latest start, then
    /// report the failure. Without journal access, systemd's exit status is
    /// used instead.
    fn readReason(self: *Service) void {
        var from_buffer: [32]u8 = undefined;
        const from = std.fmt.bufPrintZ(&from_buffer, "@{d}", .{self.started / std.time.us_per_s}) catch unreachable;
        var argv = [_:null]?[*:0]const u8{ "/usr/bin/journalctl", "--quiet", "--no-pager", "--output=cat", "--unit=scx.service", "--lines=200", "--since", from };
        if (self.started == 0) argv[6] = null;
        var err: ?*glib.Error = null;
        const process = gio.Subprocess.newv(@ptrCast(&argv), .{ .stdout_pipe = true, .stderr_silence = true }, &err) orelse {
            if (err) |e| e.free();
            return self.reasonRead(null);
        };
        self.app.hold();
        process.communicateUtf8Async(null, self.cancel, journalRead, self);
    }

    fn journalRead(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        const process = object.ext.cast(gio.Subprocess, source.?).?;
        defer process.unref();
        var stdout_buffer: [*:0]u8 = undefined;
        var err: ?*glib.Error = null;
        const finished = process.communicateUtf8Finish(result, &stdout_buffer, null, &err) != 0;
        const stdout: ?[*:0]u8 = if (finished) stdout_buffer else null;
        defer if (stdout) |text| glib.free(text);
        defer if (err) |e| e.free();
        if (!self.running) return;
        self.reasonRead(if (stdout) |text| p.exitReason(std.mem.span(text)) else null);
    }

    fn reasonRead(self: *Service, logged: ?[]const u8) void {
        // A profile applied meanwhile replaces the failure.
        if (self.status.kind != .failed) return;
        var buffer: [64]u8 = undefined;
        const reason = logged orelse self.processReason(&buffer);
        self.reason = if (reason) |text| std.fmt.bufPrintZ(&self.reason_buffer, "{s}", .{text[0..@min(text.len, self.reason_buffer.len - 1)]}) catch null else null;
        // Only the shell reports failures; Settings would duplicate them.
        if (self.notify) if (self.config) |config| if (self.status.profile) |i| log.warn("event=sched-profile-failed profile={s} reason=\"{s}\"", .{ config.profiles[i].label, self.reason orelse "unknown" });
        self.notifyFailure();
        self.changed(self.context);
    }

    fn processReason(self: *Service, buffer: []u8) ?[]const u8 {
        const proxy = self.process orelse return null;
        const result = proxy.getCachedProperty("Result") orelse return null;
        defer result.unref();
        const code = proxy.getCachedProperty("ExecMainCode") orelse return null;
        defer code.unref();
        const status = proxy.getCachedProperty("ExecMainStatus") orelse return null;
        defer status.unref();
        return p.processReason(buffer, std.mem.span(result.getString(null)), code.getInt32(), status.getInt32());
    }

    fn settle(self: *Service) void {
        // Long enough to outlast the switching window below.
        if (self.settle_source != 0 or !self.running or self.settle_attempts >= 40) return;
        self.settle_attempts += 1;
        self.settle_source = glib.timeoutAdd(500, settled, self);
    }

    fn settled(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data.?));
        self.settle_source = 0;
        self.refresh();
        return 0;
    }

    pub fn apply(self: *Service, id: []const u8) !void {
        if (!self.running or !self.enabled) return error.Unavailable;
        if (self.applying != null) return error.Busy;
        const config = self.config orelse return error.Unavailable;
        _ = config.find(id) orelse return error.InvalidProfile;
        if (id.len > self.applying_buffer.len) return error.InvalidProfile;
        @memcpy(self.applying_buffer[0..id.len], id);
        const owned = try a.dupeZ(u8, id);
        defer a.free(owned);
        var argv = [_:null]?[*:0]const u8{ "/usr/bin/pkexec", store.helperPath(), "apply", owned };
        var err: ?*glib.Error = null;
        const process = gio.Subprocess.newv(@ptrCast(&argv), .{ .stdout_silence = true, .stderr_pipe = true }, &err) orelse {
            if (err) |e| e.free();
            return error.HelperUnavailable;
        };
        self.applying = self.applying_buffer[0..id.len];
        self.err = null;
        self.app.hold();
        process.communicateUtf8Async(null, self.cancel, applied, self);
        self.changed(self.context);
    }

    fn applied(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        const process = object.ext.cast(gio.Subprocess, source.?).?;
        defer process.unref();
        var stderr_buffer: [*:0]u8 = undefined;
        var err: ?*glib.Error = null;
        const finished = process.communicateUtf8Finish(result, null, &stderr_buffer, &err) != 0;
        const stderr: ?[*:0]u8 = if (finished) stderr_buffer else null;
        defer if (stderr) |text| glib.free(text);
        defer if (err) |e| e.free();
        if (!self.running) return;
        const id = self.applying orelse return;
        const succeeded = finished and process.getSuccessful() != 0;
        log.info("event=sched-profile-select profile={s} result={s}", .{ id, if (succeeded) "ok" else "failed" });
        if (!succeeded) {
            const detail = if (stderr) |text| std.mem.trim(u8, std.mem.span(text), " \r\n\t") else "";
            self.err = std.fmt.bufPrintZ(&self.err_buffer, "The profile could not be applied{s}{s}", .{ if (detail.len > 0) ": " else ".", detail[0..@min(detail.len, 400)] }) catch "The profile could not be applied.";
        }
        self.applying = null;
        self.refresh();
    }

    fn managerReady(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        var err: ?*glib.Error = null;
        const proxy = gio.DBusProxy.newForBusFinish(result, &err);
        defer if (err) |e| e.free();
        if (!self.running) {
            if (proxy) |value| value.unref();
            return;
        }
        self.manager = proxy orelse return log.warn("event=sched-profile-systemd result=unavailable", .{});
        // Unit property changes are only broadcast to subscribed clients.
        self.manager.?.call("Subscribe", null, .{}, -1, null, null, null);
        self.app.hold();
        self.manager.?.call("LoadUnit", tuple(&.{glib.Variant.newString("scx.service")}), .{}, 5000, self.cancel, unitLoaded, self);
    }

    fn unitLoaded(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        var err: ?*glib.Error = null;
        const reply = object.ext.cast(gio.DBusProxy, source.?).?.callFinish(result, &err);
        defer if (reply) |value| value.unref();
        defer if (err) |e| e.free();
        if (!self.running) return;
        const value = reply orelse return log.warn("event=sched-profile-systemd result=load-failed", .{});
        const child = value.getChildValue(0);
        defer child.unref();
        self.app.hold();
        gio.DBusProxy.newForBus(.system, .{ .get_invalidated_properties = true }, null, systemd, child.getString(null), systemd ++ ".Unit", self.cancel, unitReady, self);
        self.app.hold();
        gio.DBusProxy.newForBus(.system, .{ .get_invalidated_properties = true }, null, systemd, child.getString(null), systemd ++ ".Service", self.cancel, processReady, self);
    }

    fn unitReady(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        var err: ?*glib.Error = null;
        const proxy = gio.DBusProxy.newForBusFinish(result, &err);
        defer if (err) |e| e.free();
        if (!self.running) {
            if (proxy) |value| value.unref();
            return;
        }
        self.unit = proxy orelse return log.warn("event=sched-profile-systemd result=unit-unavailable", .{});
        self.unit_signal = gio.DBusProxy.signals.g_properties_changed.connect(self.unit.?, *Service, unitChanged, self, .{});
        self.readUnit();
        self.refresh();
    }

    fn processReady(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        var err: ?*glib.Error = null;
        const proxy = gio.DBusProxy.newForBusFinish(result, &err);
        defer if (err) |e| e.free();
        if (!self.running) {
            if (proxy) |value| value.unref();
            return;
        }
        self.process = proxy;
    }

    fn unitChanged(_: *gio.DBusProxy, _: *glib.Variant, _: [*][*:0]u8, self: *Service) callconv(.c) void {
        self.readUnit();
        self.refresh();
    }

    fn readUnit(self: *Service) void {
        const proxy = self.unit orelse return;
        const load = proxy.getCachedProperty("LoadState");
        defer if (load) |value| value.unref();
        const active = proxy.getCachedProperty("ActiveState");
        defer if (active) |value| value.unref();
        self.unit_state = p.unitFrom(if (load) |value| std.mem.span(value.getString(null)) else "", if (active) |value| std.mem.span(value.getString(null)) else "");
        self.active_since = timestamp(proxy, "ActiveEnterTimestamp");
        self.started = timestamp(proxy, "InactiveExitTimestamp");
    }

    fn notifyFailure(self: *Service) void {
        if (!self.notify) return;
        const config = self.config orelse return;
        const label = config.profiles[self.status.profile orelse return].label;
        var body: [512]u8 = undefined;
        const text = (if (self.reason) |reason| std.fmt.bufPrintZ(&body, "{s} stopped: {s}. The kernel's default scheduler is running; choose a profile to try again.", .{ label, reason }) else std.fmt.bufPrintZ(&body, "{s} stopped unexpectedly. The kernel's default scheduler is running; choose a profile to try again.", .{label})) catch return;
        const connection = self.app.getDbusConnection() orelse return;
        const strings = glib.VariantType.new("s");
        defer strings.free();
        const hints = glib.VariantType.new("{sv}");
        defer hints.free();
        connection.call("org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify", tuple(&.{
            glib.Variant.newString("Pearl"),
            glib.Variant.newUint32(0),
            glib.Variant.newString("pearl-scheduler-symbolic"),
            glib.Variant.newString("CPU scheduler profile stopped"),
            glib.Variant.newString(text),
            glib.Variant.newArray(strings, null, 0),
            glib.Variant.newArray(hints, null, 0),
            glib.Variant.newInt32(-1),
        }), null, .{}, 3000, null, null, null);
    }
};

fn kernelState() Kernel {
    const fd = std.c.open("/sys/kernel/sched_ext/state", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return .unavailable;
    defer _ = std.c.close(fd);
    var buffer: [64]u8 = undefined;
    const n = std.c.read(fd, &buffer, buffer.len);
    if (n <= 0 or n == buffer.len) return .unknown;
    return std.meta.stringToEnum(Kernel, std.mem.trim(u8, buffer[0..@intCast(n)], "\r\n ")) orelse .unknown;
}

/// The scheduler name in an ops name such as cosmos_1.1.7_x86_64_unknown_linux_gnu.
fn opsName(ops: []const u8) []const u8 {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, ops, i, '_')) |j| : (i = j + 1) {
        if (j + 1 < ops.len and std.ascii.isDigit(ops[j + 1])) return ops[0..j];
    }
    return ops;
}

fn readOps(buffer: []u8) []const u8 {
    const fd = std.c.open("/sys/kernel/sched_ext/root/ops", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return "";
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, buffer.ptr, buffer.len);
    if (n <= 0 or n == buffer.len) return "";
    return std.mem.trim(u8, buffer[0..@intCast(n)], "\r\n ");
}

fn timestamp(proxy: *gio.DBusProxy, name: [*:0]const u8) u64 {
    const value = proxy.getCachedProperty(name) orelse return 0;
    defer value.unref();
    return value.getUint64();
}

fn tuple(values: []const *glib.Variant) *glib.Variant {
    return glib.Variant.newTuple(values.ptr, values.len);
}
