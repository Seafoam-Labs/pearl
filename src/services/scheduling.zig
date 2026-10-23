//! Scheduling profiles applied through scx.service. Pearl watches the unit over
//! systemd's D-Bus API and sched_ext through the kernel's uevents, so state
//! changes arrive without polling, and changes it only through
//! pearl-scheduling-helper.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const unix = @import("glibunix2");
const object = @import("gobject2");
const p = @import("sched_profiles.zig");
const store = @import("sched_profiles_store.zig");
const Kernel = p.Kernel;
const log = std.log.scoped(.services);
const a = std.heap.c_allocator;
const systemd = "org.freedesktop.systemd1";
/// How long a profile counts as still taking over after it was selected.
const switch_window = 15 * std.time.us_per_s;
/// A scheduler that has not attached this long after its unit became active,
/// or after it detached while the unit stayed active, is not going to.
const attach_timeout = 10 * std.time.us_per_s;

pub const Service = struct {
    app: *gio.Application,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    /// Changes are allowed only while the session is unlocked and ready.
    enabled: bool = false,
    /// Only the shell reports failures and falls back to Default, so Settings
    /// does not duplicate them.
    notify: bool = true,
    running: bool = false,
    cancel: ?*gio.Cancellable = null,
    manager: ?*gio.DBusProxy = null,
    unit: ?*gio.DBusProxy = null,
    unit_signal: c_ulong = 0,
    /// The same unit's Service interface, for how its process last ended and
    /// how often systemd restarted it.
    process: ?*gio.DBusProxy = null,
    process_signal: c_ulong = 0,
    arena: std.heap.ArenaAllocator = .init(a),
    /// The profiles to choose from: the administrator's file when there is
    /// one, else the shipped profiles. Null when neither is installed or the
    /// file used is invalid.
    config: ?p.Config = null,
    /// The profiles the package ships, which restoring the defaults returns
    /// to.
    shipped: ?p.Config = null,
    /// config is an edited list that restoring the defaults would replace.
    custom: bool = false,
    /// Watches the administrator's file, so edits show up at once.
    monitor: ?*gio.FileMonitor = null,
    monitor_signal: c_ulong = 0,
    /// The helper is saving or resetting the profiles; it asks for a
    /// password first.
    saving: bool = false,
    /// What saving the profiles stdin carries to the helper.
    save_input: ?[:0]u8 = null,
    /// The profile to apply once the profiles are saved, so the running
    /// scheduler keeps matching its profile.
    after_save: ?[]const u8 = null,
    after_save_buffer: [32]u8 = undefined,
    /// Why the profile file could not be used.
    problem: ?[:0]const u8 = null,
    env: p.Env = .{},
    status: p.Status = .{},
    unit_state: p.Unit = .unknown,
    kernel: Kernel = .unavailable,
    /// The attached scheduler's name, from /sys/kernel/sched_ext/root/ops.
    ops: []const u8 = "",
    ops_buffer: [128]u8 = undefined,
    /// When the unit last became active, in microseconds since the epoch; 0
    /// when unknown.
    active_since: u64 = 0,
    /// When the scheduler last detached while its unit stayed active, in
    /// microseconds since the epoch. A scheduler does that to restart itself,
    /// for example when a CPU goes offline, so it gets time to attach again.
    detached_since: i64 = 0,
    /// systemd's restart count for the unit, as last seen.
    restarts: ?u32 = null,
    /// The profile whose scheduler failed, until another profile is selected.
    failed: ?[]const u8 = null,
    failed_buffer: [32]u8 = undefined,
    /// When that profile was selected, in seconds since the epoch.
    failed_since: i64 = 0,
    /// Why the selected scheduler stopped, once known.
    reason: ?[:0]const u8 = null,
    reason_buffer: [320]u8 = undefined,
    /// What went wrong before falling back to Default, until another profile
    /// is selected.
    notice: Notice = .none,
    notice_label: [64]u8 = undefined,
    notice_label_len: usize = 0,
    notice_detail: [400]u8 = undefined,
    notice_detail_len: usize = 0,
    /// The profile being applied is the fallback to Default.
    reverting: bool = false,
    /// A fallback that could not start yet, for example while locked.
    fallback_pending: bool = false,
    /// Profile id being applied; the helper is still running.
    applying: ?[]const u8 = null,
    applying_buffer: [33]u8 = undefined,
    err: ?[:0]const u8 = null,
    err_buffer: [512]u8 = undefined,
    /// Rechecks once the switching window closes or the attach deadline
    /// passes, the only changes that raise no event.
    recheck_source: c_uint = 0,
    /// A failure is acted on once its exit message has reached the journal.
    failure_source: c_uint = 0,
    notified: bool = false,
    /// The kernel's uevent socket, for schedulers attaching and detaching.
    events_fd: i32 = -1,
    events_source: c_uint = 0,
    /// Rechecks sched_ext periodically only when uevents are unavailable.
    poll_source: c_uint = 0,

    pub const Notice = enum { none, stopped, start_failed };

    pub fn start(self: *Service) void {
        self.running = true;
        self.cancel = gio.Cancellable.new();
        if (!self.watchEvents()) {
            log.warn("event=sched-profile-systemd result=uevents-unavailable", .{});
            self.poll_source = glib.timeoutAddSeconds(3, poll, self);
        }
        self.watchProfiles();
        self.refresh();
        self.app.hold();
        gio.DBusProxy.newForBus(.system, .{ .do_not_load_properties = true }, null, systemd, "/org/freedesktop/systemd1", systemd ++ ".Manager", self.cancel, managerReady, self);
    }

    pub fn stop(self: *Service) void {
        self.running = false;
        if (self.recheck_source != 0) _ = glib.Source.remove(self.recheck_source);
        if (self.events_source != 0) _ = glib.Source.remove(self.events_source);
        if (self.events_fd >= 0) _ = std.os.linux.close(self.events_fd);
        self.recheck_source = 0;
        self.events_source = 0;
        self.events_fd = -1;
        if (self.failure_source != 0) _ = glib.Source.remove(self.failure_source);
        if (self.poll_source != 0) _ = glib.Source.remove(self.poll_source);
        if (self.monitor) |m| {
            object.signalHandlerDisconnect(m.as(object.Object), self.monitor_signal);
            _ = m.cancel();
            m.unref();
        }
        self.monitor = null;
        self.failure_source = 0;
        self.poll_source = 0;
        if (self.cancel) |cancel| {
            cancel.cancel();
            cancel.unref();
        }
        self.cancel = null;
        if (self.unit) |proxy| {
            object.signalHandlerDisconnect(proxy.as(object.Object), self.unit_signal);
            proxy.unref();
        }
        if (self.process) |proxy| {
            object.signalHandlerDisconnect(proxy.as(object.Object), self.process_signal);
            proxy.unref();
        }
        self.process = null;
        if (self.manager) |proxy| proxy.unref();
        self.unit = null;
        self.manager = null;
        self.arena.deinit();
    }

    /// One line on what the scheduler is doing, shared by the flyout and
    /// Settings. A running profile is only reported once the kernel shows its
    /// scheduler attached, with the version it reports and when it started.
    pub fn describe(self: *const Service, buffer: []u8) [:0]const u8 {
        if (self.problem) |problem| return problem;
        // The profile being applied, before systemd reports any change.
        if (self.applying) |id| if (self.config) |config| if (config.find(id)) |i| {
            const target = config.profiles[i];
            return if (target.stop) @import("i18n").dtr("pearl", "Stopping the scheduler...") else @import("i18n").fmt(buffer, "Starting {s}...", .{target.label});
        };
        const profile: ?p.Profile = if (self.config) |c| if (self.status.profile) |i| c.profiles[i] else null else null;
        const name = if (profile) |value| value.label else "";
        return switch (self.status.kind) {
            .unavailable => if (self.config == null) @import("i18n").dtr("pearl", "No scheduler profiles are installed.") else if (self.kernel == .unavailable) @import("i18n").dtr("pearl", "This kernel does not support sched_ext schedulers.") else if (self.unit_state == .missing) @import("i18n").dtr("pearl", "scx.service is not installed.") else @import("i18n").dtr("pearl", "Checking the scheduler..."),
            .off => @import("i18n").fmt(buffer, "{s} - kernel scheduler (EEVDF)", .{name}),
            .running => blk: {
                const sched = p.schedName(self.env.sched);
                const version = p.opsVersion(sched, self.ops);
                var time: [48]u8 = undefined;
                const uptime = self.since(&time);
                var identity_buffer: [512]u8 = undefined;
                const identity = std.fmt.bufPrint(&identity_buffer, "{s}{s}{s}", .{ sched, if (version != null) " " else "", version orelse "" }) catch sched;
                // Translators: Scheduler identity and a regional date/time, respectively.
                break :blk if (uptime.len > 0) @import("i18n").fmt(buffer, "Running - {s} - since {s}", .{ identity, uptime }) else @import("i18n").fmt(buffer, "Running - {s}", .{identity});
            },
            .starting => if (profile != null and profile.?.stop) @import("i18n").dtr("pearl", "Stopping the scheduler...") else @import("i18n").fmt(buffer, "Starting {s}...", .{name}),
            .failed => if (self.reason) |reason| @import("i18n").fmt(buffer, "{s} stopped: {s}. The kernel's default scheduler is running.", .{ name, reason }) else @import("i18n").fmt(buffer, "{s} stopped unexpectedly; the kernel's default scheduler is running.", .{name}),
            .custom => if (self.ops.len > 0) @import("i18n").fmt(buffer, "Custom - scx_{s} is running outside these profiles.", .{opsName(self.ops)}) else @import("i18n").dtr("pearl", "Custom - a scheduler configured outside these profiles is running."),
        };
    }

    /// What went wrong before falling back to Default; empty when nothing did.
    pub fn describeNotice(self: *const Service, buffer: []u8) [:0]const u8 {
        const label = self.notice_label[0..self.notice_label_len];
        const detail = self.notice_detail[0..self.notice_detail_len];
        const default = self.defaultLabel();
        return switch (self.notice) {
            .none => "",
            .stopped => if (detail.len > 0)
                @import("i18n").fmt(buffer, "{s} stopped: {s}. Switched back to {s}.", .{ label, detail, default })
            else
                @import("i18n").fmt(buffer, "{s} stopped unexpectedly. Switched back to {s}.", .{ label, default }),
            .start_failed => @import("i18n").fmt(buffer, "{s} could not start: {s}. Switched back to {s}.", .{ label, detail, default }),
        };
    }

    fn defaultLabel(self: *const Service) []const u8 {
        if (self.config) |config| if (p.firstStop(config)) |i| return config.profiles[i].label;
        return @import("i18n").dtr("pearl", "Default");
    }

    /// A profile was chosen in the last few seconds and the running instance
    /// predates it, so the previous scheduler may still be on its way out.
    fn switching(self: *const Service) bool {
        const written = envWritten() orelse return false;
        return written > @as(i64, @intCast(self.active_since)) and glib.getRealTime() - written < switch_window;
    }

    /// When the scheduler started waiting to attach: when the unit became
    /// active, or later when the scheduler detached to restart itself.
    fn waitingSince(self: *const Service) i64 {
        return @max(@as(i64, @intCast(self.active_since)), self.detached_since);
    }

    /// The scheduler has been waiting longer than it needs to attach.
    fn stuck(self: *const Service) bool {
        if (self.unit_state != .active or self.active_since == 0) return false;
        return glib.getRealTime() - self.waitingSince() > attach_timeout;
    }

    /// "since 10:28", with the date when it started on another day.
    fn since(self: *const Service, buffer: []u8) []const u8 {
        if (self.active_since == 0) return "";
        const started = glib.DateTime.newFromUnixLocal(@intCast(self.active_since / std.time.us_per_s)) orelse return "";
        defer started.unref();
        const now = glib.DateTime.newNowLocal() orelse return "";
        defer now.unref();
        const today = started.getYear() == now.getYear() and started.getDayOfYear() == now.getDayOfYear();
        const text = started.format(if (today) "%H:%M" else "%e %b, %H:%M") orelse return "";
        defer glib.free(text);
        return std.fmt.bufPrint(buffer, "{s}", .{std.mem.trim(u8, std.mem.span(text), " ")}) catch "";
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
        self.shipped = null;
        self.custom = false;
        self.problem = null;
        if (store.load(alloc)) |loaded| {
            if (loaded) |file| {
                self.config = file.config;
                self.custom = file.admin;
            }
        } else |err| {
            self.problem = std.fmt.allocPrintSentinel(alloc, "Scheduler profiles could not be read ({s}).", .{@errorName(err)}, 0) catch "Scheduler profiles could not be read.";
        }
        self.shipped = store.loadShipped(alloc) catch null;
        // Without shipped profiles there is nothing to restore.
        self.custom = self.custom and self.shipped != null;
        self.env = store.readEnv(alloc) catch .{};
        const previous = self.kernel;
        self.kernel = kernelState();
        if (previous == .enabled and self.kernel != .enabled and self.unit_state == .active) self.detached_since = glib.getRealTime();
        self.ops = readOps(&self.ops_buffer);
        self.status = if (self.config) |config| p.status(config, self.env, self.unit_state, self.kernel, self.ops, self.switching(), self.stuck()) else .{};
        self.track();
        // A profile other than Default chosen anywhere replaces the notice,
        // once the failed one and the fallback are out of the way.
        if (self.notice != .none and self.applying == null and self.failed == null) if (self.config) |config| if (self.env.profile) |id| if (config.find(id)) |i| if (!config.profiles[i].stop) {
            self.notice = .none;
        };
        if (self.fallback_pending and self.enabled and self.applying == null) self.fallBack();
        self.scheduleRecheck();
        self.changed(self.context);
    }

    /// Notice a failure of the selected scheduler, including one systemd
    /// already restarted, and act on it once its reason can be read.
    fn track(self: *Service) void {
        const previous = self.restarts;
        self.restarts = self.readRestarts();
        const profile = self.env.profile orelse "";
        if (self.failed) |failed| if (!std.mem.eql(u8, failed, profile)) self.clearFailure();
        const count = self.restarts orelse 0;
        if (self.failed == null and profile.len <= self.failed_buffer.len and p.crashed(self.status, count, if (self.restarts != null) previous else null)) {
            @memcpy(self.failed_buffer[0..profile.len], profile);
            self.failed = self.failed_buffer[0..profile.len];
            self.failed_since = if (envWritten()) |written| @divTrunc(written, std.time.us_per_s) else 0;
            self.notified = false;
            self.reason = null;
        }
        // The exit message reaches the journal just after systemd sees the
        // process end.
        if (self.failed != null and !self.notified and self.applying == null and self.failure_source == 0) {
            self.failure_source = glib.timeoutAdd(1000, failureCheck, self);
        }
    }

    fn clearFailure(self: *Service) void {
        self.failed = null;
        self.notified = false;
        self.reason = null;
        if (self.failure_source != 0) _ = glib.Source.remove(self.failure_source);
        self.failure_source = 0;
    }

    fn readRestarts(self: *Service) ?u32 {
        const proxy = self.process orelse return null;
        const value = proxy.getCachedProperty("NRestarts") orelse return null;
        defer value.unref();
        return value.getUint32();
    }

    fn poll(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data.?));
        self.refresh();
        return 1;
    }

    fn failureCheck(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data.?));
        self.failure_source = 0;
        // Every unit change already refreshed the status.
        if (self.failed != null and !self.notified and self.applying == null) {
            self.notified = true;
            self.readReason();
        }
        return 0;
    }

    /// Read why the scheduler stopped from the log since its profile was
    /// selected, then act on the failure. Without journal access, systemd's
    /// exit status is used instead.
    fn readReason(self: *Service) void {
        var from_buffer: [32]u8 = undefined;
        const from = std.fmt.bufPrintZ(&from_buffer, "@{d}", .{self.failed_since}) catch unreachable;
        // A failure seen now happened in this boot; the file may predate it.
        var argv = [_:null]?[*:0]const u8{ "/usr/bin/journalctl", "--quiet", "--no-pager", "--output=cat", "--unit=scx.service", "--boot", "--lines=200", "--since", from };
        if (self.failed_since == 0) argv[7] = null;
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
        var buffer: [64]u8 = undefined;
        self.reasonRead(if (stdout) |text| p.exitReason(&buffer, std.mem.span(text)) else null);
    }

    fn reasonRead(self: *Service, logged: ?[]const u8) void {
        // A profile applied meanwhile replaces the failure.
        const failed = self.failed orelse return;
        var buffer: [64]u8 = undefined;
        const reason = logged orelse self.processReason(&buffer);
        self.reason = if (reason) |text| std.fmt.bufPrintZ(&self.reason_buffer, "{s}", .{text[0..@min(text.len, self.reason_buffer.len - 1)]}) catch null else null;
        const label = if (self.config) |config| if (config.find(failed)) |i| config.profiles[i].label else failed else failed;
        self.setNotice(.stopped, label, self.reason orelse "");
        // Only the shell reports failures and falls back; Settings would
        // duplicate them.
        if (self.notify) {
            log.warn("event=sched-profile-failed profile={s} reason=\"{s}\"", .{ label, self.reason orelse "unknown" });
            self.notifyFailure();
            self.fallBack();
        }
        self.changed(self.context);
    }

    fn setNotice(self: *Service, kind: Notice, label: []const u8, detail: []const u8) void {
        self.notice = kind;
        self.notice_label_len = @min(label.len, self.notice_label.len);
        @memcpy(self.notice_label[0..self.notice_label_len], label[0..self.notice_label_len]);
        self.notice_detail_len = @min(detail.len, self.notice_detail.len);
        @memcpy(self.notice_detail[0..self.notice_detail_len], detail[0..self.notice_detail_len]);
    }

    /// Apply the Default profile after a failure. It waits for the session to
    /// allow changes, such as while it is locked.
    fn fallBack(self: *Service) void {
        const config = self.config orelse return;
        const index = p.firstStop(config) orelse return;
        self.fallback_pending = false;
        self.startApply(config.profiles[index].id, true) catch |err| {
            log.warn("event=sched-profile-fallback result={s}", .{@errorName(err)});
            if (err == error.Unavailable or err == error.Busy) self.fallback_pending = true;
        };
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

    /// While a profile is starting, recheck once when the switching window
    /// closes or the attach deadline passes. Everything else that can change
    /// the status arrives as a systemd or kernel event.
    fn scheduleRecheck(self: *Service) void {
        if (self.recheck_source != 0) _ = glib.Source.remove(self.recheck_source);
        self.recheck_source = 0;
        if (!self.running or self.status.kind != .starting) return;
        const now = glib.getRealTime();
        var deadline: i64 = std.math.maxInt(i64);
        if (envWritten()) |written| if (written + switch_window > now) {
            deadline = written + switch_window;
        };
        if (self.unit_state == .active and self.active_since > 0) {
            const attach = self.waitingSince() + attach_timeout;
            if (attach > now) deadline = @min(deadline, attach);
        }
        if (deadline == std.math.maxInt(i64)) return;
        // A little past the deadline, so the comparison has flipped.
        self.recheck_source = glib.timeoutAdd(@intCast(@divTrunc(deadline - now, std.time.us_per_ms) + 50), rechecked, self);
    }

    fn rechecked(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data.?));
        self.recheck_source = 0;
        self.refresh();
        return 0;
    }

    /// Listen to the kernel's uevents, which report every sched_ext attach
    /// and detach. Any user may receive them.
    fn watchEvents(self: *Service) bool {
        const linux = std.os.linux;
        const socket = linux.socket(linux.AF.NETLINK, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, linux.NETLINK.KOBJECT_UEVENT);
        if (linux.errno(socket) != .SUCCESS) return false;
        const fd: i32 = @intCast(socket);
        // Group 1 carries the kernel's own events, before udev handles them.
        var address: linux.sockaddr.nl = .{ .pid = 0, .groups = 1 };
        if (linux.errno(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.nl))) != .SUCCESS) {
            _ = linux.close(fd);
            return false;
        }
        self.events_fd = fd;
        self.events_source = unix.fdAdd(fd, .{ .in = true }, eventsReady, self);
        return true;
    }

    fn eventsReady(fd: c_int, _: glib.IOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data.?));
        const linux = std.os.linux;
        var relevant = false;
        var buffer: [8192]u8 = undefined;
        while (true) {
            const n = linux.recvfrom(fd, &buffer, buffer.len, 0, null, null);
            switch (linux.errno(n)) {
                .SUCCESS => if (p.schedExtEvent(buffer[0..n])) {
                    relevant = true;
                },
                // Events were dropped, so one of them may have mattered.
                .NOBUFS => relevant = true,
                .INTR => {},
                else => break,
            }
        }
        if (relevant) self.refresh();
        return 1;
    }

    fn watchProfiles(self: *Service) void {
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const path = (store.paths(scratch.allocator()) catch return)[0];
        // GLib keeps watching for a file whose directory does not exist yet.
        const file = gio.File.newForPath(path);
        defer file.unref();
        self.monitor = file.monitorFile(.{ .watch_moves = true }, self.cancel, null) orelse return log.warn("event=sched-profile-watch result=monitor-unavailable", .{});
        self.monitor_signal = gio.FileMonitor.signals.changed.connect(self.monitor.?, *Service, profilesChanged, self, .{});
    }

    fn profilesChanged(_: *gio.FileMonitor, _: *gio.File, _: ?*gio.File, _: gio.FileMonitorEvent, self: *Service) callconv(.c) void {
        // The file is replaced whole, so every event leaves a complete file.
        if (self.running) self.refresh();
    }

    /// Save the profiles for every user, and apply the selected one again if
    /// its command changed, or Default if it was deleted. The helper asks for
    /// an administrator password.
    pub fn saveProfiles(self: *Service, config: p.Config) !void {
        const before = try self.startEdit();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const bytes = try p.serialize(arena.allocator(), config);
        // Never send a list the helper would reject.
        _ = try p.parse(arena.allocator(), bytes);
        try self.runEdit("save", try a.dupeZ(u8, bytes), p.reapply(before, config, self.env));
    }

    /// Return to the shipped profiles, and switch the running scheduler to
    /// the shipped profile of the same id, or Default when there is none.
    pub fn restoreDefaults(self: *Service) !void {
        const before = try self.startEdit();
        const shipped = self.shipped orelse return error.Unavailable;
        try self.runEdit("reset", null, p.reapply(before, shipped, self.env));
    }

    fn startEdit(self: *Service) !p.Config {
        if (!self.running or !self.enabled) return error.Unavailable;
        if (self.applying != null or self.saving) return error.Busy;
        return self.config orelse error.Unavailable;
    }

    fn runEdit(self: *Service, command: [:0]const u8, input: ?[:0]u8, reapply: ?[]const u8) !void {
        errdefer if (input) |value| a.free(value);
        if (reapply) |id| if (id.len > self.after_save_buffer.len) return error.InvalidProfile;
        var argv = [_:null]?[*:0]const u8{ "/usr/bin/pkexec", store.helperPath(), "profiles", command };
        var err: ?*glib.Error = null;
        const process = gio.Subprocess.newv(@ptrCast(&argv), .{ .stdin_pipe = input != null, .stdout_silence = true, .stderr_pipe = true }, &err) orelse {
            if (err) |e| e.free();
            return error.HelperUnavailable;
        };
        self.after_save = if (reapply) |id| blk: {
            @memcpy(self.after_save_buffer[0..id.len], id);
            break :blk self.after_save_buffer[0..id.len];
        } else null;
        self.save_input = input;
        self.saving = true;
        self.err = null;
        self.app.hold();
        process.communicateUtf8Async(if (input) |value| value.ptr else null, self.cancel, edited, self);
        self.changed(self.context);
    }

    fn edited(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
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
        if (self.save_input) |value| a.free(value);
        self.save_input = null;
        self.saving = false;
        if (!self.running) return;
        const succeeded = finished and process.getSuccessful() != 0;
        log.info("event=sched-profile-edit result={s}", .{if (succeeded) "ok" else "failed"});
        // pkexec reports a dismissed or refused authentication as 126 or 127:
        // nothing changed.
        const status = if (finished) process.getExitStatus() else 0;
        if (!succeeded and status != 126 and status != 127) {
            const raw = if (stderr) |text| std.mem.trim(u8, std.mem.span(text), " \r\n\t") else "";
            const line = raw[if (std.mem.lastIndexOfScalar(u8, raw, '\n')) |i| i + 1 else 0..];
            const detail = if (std.mem.indexOf(u8, line, "helper: ")) |i| line[i + 8 ..] else line;
            self.err = std.fmt.bufPrintZ(&self.err_buffer, "The profiles could not be saved{s}{s}", .{ if (detail.len > 0) ": " else ".", detail[0..@min(detail.len, 400)] }) catch "The profiles could not be saved.";
        }
        self.refresh();
        if (succeeded) if (self.after_save) |id| self.apply(id) catch |e| log.warn("event=sched-profile-select profile={s} result={s}", .{ id, @errorName(e) });
        self.after_save = null;
    }

    pub fn apply(self: *Service, id: []const u8) !void {
        try self.startApply(id, false);
        self.notice = .none;
        self.fallback_pending = false;
    }

    fn startApply(self: *Service, id: []const u8, reverting: bool) !void {
        if (!self.running or !self.enabled) return error.Unavailable;
        if (self.applying != null or self.saving) return error.Busy;
        const config = self.config orelse return error.Unavailable;
        if (config.find(id) == null or id.len >= self.applying_buffer.len) return error.InvalidProfile;
        @memcpy(self.applying_buffer[0..id.len], id);
        self.applying_buffer[id.len] = 0;
        // The helper reads the command line from the profile file itself.
        var argv = [_:null]?[*:0]const u8{ "/usr/bin/pkexec", store.helperPath(), "apply", self.applying_buffer[0..id.len :0] };
        var err: ?*glib.Error = null;
        const process = gio.Subprocess.newv(@ptrCast(&argv), .{ .stdout_silence = true, .stderr_pipe = true }, &err) orelse {
            if (err) |e| e.free();
            return error.HelperUnavailable;
        };
        self.applying = self.applying_buffer[0..id.len];
        self.reverting = reverting;
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
        const reverting = self.reverting;
        self.reverting = false;
        self.applying = null;
        // pkexec reports a dismissed or refused authentication as 126 or 127:
        // nothing changed, so there is nothing to fall back from.
        const status = if (finished) process.getExitStatus() else 0;
        if (!succeeded and status != 126 and status != 127) {
            const raw = if (stderr) |text| std.mem.trim(u8, std.mem.span(text), " \r\n\t") else "";
            const line = raw[if (std.mem.lastIndexOfScalar(u8, raw, '\n')) |i| i + 1 else 0..];
            const detail = if (std.mem.indexOf(u8, line, "helper: ")) |i| line[i + 8 ..] else line;
            const scheduler = if (self.config) |config| if (config.find(id)) |i| !config.profiles[i].stop else false else false;
            if (scheduler and !reverting and self.notify) {
                const label = if (self.config) |config| config.profiles[config.find(id).?].label else id;
                self.setNotice(.start_failed, label, if (detail.len > 0) detail else @import("i18n").dtr("pearl", "the scheduler helper failed"));
                log.warn("event=sched-profile-failed profile={s} reason=\"{s}\"", .{ label, detail });
                self.notifyFailure();
                self.fallBack();
            } else {
                self.err = std.fmt.bufPrintZ(&self.err_buffer, "The profile could not be applied{s}{s}", .{ if (raw.len > 0) ": " else ".", raw[0..@min(raw.len, 400)] }) catch "The profile could not be applied.";
            }
        }
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
        // NRestarts arrives on this interface, not on the Unit one.
        if (proxy) |value| self.process_signal = gio.DBusProxy.signals.g_properties_changed.connect(value, *Service, unitChanged, self, .{});
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
    }

    fn notifyFailure(self: *Service) void {
        if (!self.notify) return;
        var body: [512]u8 = undefined;
        const text = self.describeNotice(&body);
        if (text.len == 0) return;
        var title_buffer: [96]u8 = undefined;
        const title = std.fmt.bufPrintZ(&title_buffer, "CPU scheduler switched to {s}", .{self.defaultLabel()}) catch "CPU scheduler switched to Default";
        const connection = self.app.getDbusConnection() orelse return;
        const strings = glib.VariantType.new("s");
        defer strings.free();
        const hints = glib.VariantType.new("{sv}");
        defer hints.free();
        connection.call("org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify", tuple(&.{
            glib.Variant.newString("Pearl"),
            glib.Variant.newUint32(0),
            glib.Variant.newString("pearl-scheduler-symbolic"),
            glib.Variant.newString(title),
            glib.Variant.newString(text),
            glib.Variant.newArray(strings, null, 0),
            glib.Variant.newArray(hints, null, 0),
            glib.Variant.newInt32(-1),
        }), null, .{}, 3000, null, null, null);
    }
};

/// When a profile was last selected, in microseconds since the epoch.
fn envWritten() ?i64 {
    var stat: std.os.linux.Statx = std.mem.zeroes(std.os.linux.Statx);
    if (std.os.linux.statx(std.os.linux.AT.FDCWD, p.env_path, 0, .{ .MTIME = true }, &stat) != 0) return null;
    return stat.mtime.sec * std.time.us_per_s + @divTrunc(stat.mtime.nsec, std.time.ns_per_us);
}

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
