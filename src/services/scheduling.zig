//! Scheduling profiles through scx's own tools. scxcli lists the catalog's
//! profiles and what the unit is set to run, starts profiles and saves the
//! catalog; Pearl runs it as the user to read and through pkexec to change
//! anything, under scx's polkit actions. Pearl watches the unit over
//! systemd's D-Bus API and sched_ext through the kernel's uevents, so state
//! changes arrive without polling, and rereads the listing when the catalog
//! or the unit's environment file changes.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const unix = @import("glibunix2");
const object = @import("gobject2");
const p = @import("sched_profiles.zig");
const sd = @import("sched_systemd.zig");
const cw = @import("catalog_watch.zig");
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
    /// Owns the listing.
    listing_arena: std.heap.ArenaAllocator = .init(a),
    /// Owns the listing's current state when `scxcli get` replaced it.
    current_arena: std.heap.ArenaAllocator = .init(a),
    /// scxcli is reading the state; another event meanwhile reads it again.
    current_busy: bool = false,
    current_again: bool = false,
    /// The last read of the state failed, so what is shown is the state
    /// before it: not confirmed, and read again with a growing delay.
    current_stale: bool = false,
    current_retry: p.Retry = .{},
    current_retry_source: c_uint = 0,
    /// `scxcli list --json`: the catalog's profiles, the installed
    /// schedulers and what the unit is set to run. Null until scxcli has
    /// answered, or when it cannot.
    listing: ?p.Listing = null,
    /// scxcli is listing; another change meanwhile lists again after it.
    listing_busy: bool = false,
    listing_again: bool = false,
    /// A listing that failed is asked for again, as the state is.
    listing_retry: p.Retry = .{},
    listing_retry_source: c_uint = 0,
    /// Owns the catalog texts.
    catalog_arena: std.heap.ArenaAllocator = .init(a),
    /// The catalog in use, as `scxcli catalog show` prints it. Saving edited
    /// profiles replaces its recommended list and keeps the rest.
    catalog: ?[]const u8 = null,
    /// The profiles scx ships, which restoring the defaults returns to.
    shipped: ?[]const p.Profile = null,
    catalog_busy: bool = false,
    catalog_again: bool = false,
    /// The catalogs and the unit's environment file, so changes made anywhere
    /// show up at once.
    watches: [3]?cw.Watch = @splat(null),
    /// scxcli is saving or resetting the catalog; it asks for a password
    /// first.
    saving: bool = false,
    /// What saving the catalog sends to scxcli on stdin, once scxcli has
    /// shown that the catalog is still the one it was built from.
    save_input: ?[:0]u8 = null,
    /// The catalog text the edit was built from.
    save_base: ?[]u8 = null,
    /// The profile to start once the catalog is saved, so the running
    /// scheduler keeps matching its profile.
    after_save: ?[]const u8 = null,
    after_save_buffer: [p.max_id]u8 = undefined,
    /// What the unit ran when the edit was prepared. The save may wait on a
    /// password prompt for long; the profile is started again only if that
    /// command still runs then, so a scheduler someone else started or
    /// stopped meanwhile is left alone.
    after_save_arena: std.heap.ArenaAllocator = .init(a),
    after_save_command: ?p.Command = null,
    /// Why the profiles cannot be listed.
    problem: ?[:0]const u8 = null,
    problem_buffer: [400]u8 = undefined,
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
    /// What a refresh may conclude about a failure (`p.Tracker`).
    tracker: p.Tracker = .{},
    /// The profile whose scheduler failed, until another profile is selected.
    failed: ?[]const u8 = null,
    failed_buffer: [p.max_id]u8 = undefined,
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
    /// The profile being started is the fallback to Default.
    reverting: bool = false,
    /// A fallback that could not start yet, for example while locked.
    fallback_pending: bool = false,
    /// Profile id being started; scxcli is still running.
    applying: ?[]const u8 = null,
    applying_buffer: [p.max_id + 1]u8 = undefined,
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
    /// Watches systemd on the system bus, so a restarted or re-executed
    /// systemd gets connected to again.
    systemd_watch: c_uint = 0,
    /// Whether the proxies and the subscription are whole, for systemd's
    /// current owner.
    link: sd.Link = .{},
    /// Cancels the current connection attempt's calls when a new one starts.
    systemd_cancel: ?*gio.Cancellable = null,
    /// Asks scxcli what runs, and tries to connect again, every few seconds
    /// while systemd's signals cannot be relied on.
    systemd_poll_source: c_uint = 0,

    pub const Notice = enum { none, stopped };
    const Watch = enum(u2) { admin, shipped, config };

    pub fn start(self: *Service) void {
        self.running = true;
        self.cancel = gio.Cancellable.new();
        if (!self.watchEvents()) {
            log.warn("event=sched-profile-systemd result=uevents-unavailable", .{});
            self.poll_source = glib.timeoutAddSeconds(3, poll, self);
        }
        self.watch(.admin, p.admin_catalog);
        self.watch(.shipped, p.shipped_catalog);
        self.watch(.config, p.default_config);
        self.reload();
        self.reloadCatalog();
        self.refresh();
        self.systemd_watch = gio.busWatchName(.system, systemd, .{}, systemdAppeared, systemdVanished, self, null);
        self.connectSystemd();
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
        if (self.systemd_poll_source != 0) _ = glib.Source.remove(self.systemd_poll_source);
        if (self.current_retry_source != 0) _ = glib.Source.remove(self.current_retry_source);
        self.current_retry_source = 0;
        if (self.listing_retry_source != 0) _ = glib.Source.remove(self.listing_retry_source);
        self.listing_retry_source = 0;
        if (self.systemd_watch != 0) gio.busUnwatchName(self.systemd_watch);
        self.systemd_poll_source = 0;
        self.systemd_watch = 0;
        for (std.enums.values(Watch)) |which| self.unwatch(which);
        self.failure_source = 0;
        self.poll_source = 0;
        if (self.cancel) |cancel| {
            cancel.cancel();
            cancel.unref();
        }
        self.cancel = null;
        self.dropSystemd();
        if (self.systemd_cancel) |cancel| cancel.unref();
        self.systemd_cancel = null;
        self.listing = null;
        self.catalog = null;
        self.shipped = null;
        self.listing_arena.deinit();
        self.current_arena.deinit();
        self.after_save_arena.deinit();
        self.catalog_arena.deinit();
        if (self.save_input) |value| a.free(value);
        if (self.save_base) |value| a.free(value);
        self.save_input = null;
        self.save_base = null;
    }

    /// How a profile row shows: what runs, or a selection kept while
    /// stopped.
    pub fn mark(self: *const Service, index: usize) p.Mark {
        const listing = self.listing orelse return .none;
        if (index >= listing.profiles.len) return .none;
        return p.mark(listing, self.status, index);
    }

    /// Identifies the listing as views and the editor use it (`p.signature`),
    /// so a view rebuilds its rows when it changes and an editor can tell
    /// that what it was opened on is gone. 0 without a listing.
    pub fn signature(self: *const Service) u64 {
        return if (self.listing) |listing| p.signature(listing) else 0;
    }

    /// The profile a status refers to.
    pub fn profile(self: *const Service, index: ?usize) ?p.Profile {
        const listing = self.listing orelse return null;
        return listing.profiles[index orelse return null];
    }

    /// The catalog in use is the administrator's, which restoring the
    /// defaults removes.
    pub fn customized(self: *const Service) bool {
        const listing = self.listing orelse return false;
        return listing.customized;
    }

    /// The profiles can be edited: scxcli has shown the catalog to edit.
    pub fn editable(self: *const Service) bool {
        return self.listing != null and self.catalog != null;
    }

    /// One line on what the scheduler is doing, shared by the flyout and
    /// Settings. A running profile is only reported once the kernel shows its
    /// scheduler attached, with the version it reports and when it started.
    pub fn describe(self: *const Service, buffer: []u8) [:0]const u8 {
        if (self.status.stale and self.problem == null and self.applying == null) {
            var inner: [512]u8 = undefined;
            const text = self.describeState(&inner);
            // Translators: The last known scheduler state, while scxcli cannot be asked again.
            return @import("i18n").fmt(buffer, "{s} (not confirmed: scxcli could not be asked what runs now)", .{text});
        }
        return self.describeState(buffer);
    }

    fn describeState(self: *const Service, buffer: []u8) [:0]const u8 {
        if (self.problem) |problem| return problem;
        // The profile being started, before systemd reports any change.
        if (self.applying) |id| if (self.listing) |listing| if (listing.find(id)) |i| {
            const target = listing.profiles[i];
            return if (target.isDefault()) @import("i18n").dtr("pearl", "Stopping the scheduler...") else @import("i18n").fmt(buffer, "Starting {s}...", .{target.label});
        };
        const selected = self.profile(self.status.profile);
        const name = if (selected) |value| value.label else "";
        return switch (self.status.kind) {
            .unavailable => if (self.listing == null) @import("i18n").dtr("pearl", "Checking the scheduler...") else if (self.listing.?.current.kernel_state == null) @import("i18n").dtr("pearl", "This kernel does not support sched_ext schedulers.") else if (self.unit_state == .missing) @import("i18n").dtr("pearl", "scx.service is not installed.") else @import("i18n").dtr("pearl", "Checking the scheduler..."),
            .off => if (p.idleNext(self.listing.?, self.status)) |next| blk: {
                const listing = self.listing.?;
                const pick = p.selection(listing);
                const what = if (pick.first) |i| listing.profiles[i].label else p.schedName(next.sched);
                // Translators: The default profile, then the profile or scheduler scx.service is set up to run.
                break :blk @import("i18n").fmt(buffer, "{s} - kernel scheduler (EEVDF). scx.service is set to run {s}, but it is not enabled, so nothing starts it; choose that profile to start it.", .{ name, what });
            } else @import("i18n").fmt(buffer, "{s} - kernel scheduler (EEVDF)", .{name}),
            .running => blk: {
                const sched = if (selected) |value| value.scheduler() orelse "" else "";
                const version = p.opsVersion(sched, self.ops);
                var time: [48]u8 = undefined;
                const uptime = self.since(&time);
                var identity_buffer: [512]u8 = undefined;
                const identity = std.fmt.bufPrint(&identity_buffer, "{s}{s}{s}", .{ sched, if (version != null) " " else "", version orelse "" }) catch sched;
                // The file was changed while the unit runs: the next start
                // runs something else.
                const listing = self.listing.?;
                const pick = p.selection(listing);
                const later: ?[]const u8 = if (p.active(listing)) |runs| (if (pick.first) |i| (if (p.matchRunning(listing.profiles[i], runs)) null else listing.profiles[i].label) else if (listing.current.next != null) @import("i18n").dtr("pearl", "a command outside these profiles") else null) else null;
                var line_buffer: [400]u8 = undefined;
                // Translators: Scheduler identity and a regional date/time, respectively.
                const line = if (uptime.len > 0) @import("i18n").fmt(&line_buffer, "Running - {s} - since {s}", .{ identity, uptime }) else @import("i18n").fmt(&line_buffer, "Running - {s}", .{identity});
                // Translators: A running scheduler, then the profile the unit's file now selects for its next start.
                break :blk if (later) |next| @import("i18n").fmt(buffer, "{s}. The next start runs {s}.", .{ line, next }) else std.mem.printSentinel(buffer, "{s}", .{line}, 0) catch line;
            },
            .starting => if (selected != null and selected.?.isDefault()) @import("i18n").dtr("pearl", "Stopping the scheduler...") else @import("i18n").fmt(buffer, "Starting {s}...", .{name}),
            // Translators: A profile kept selected while scx.service is stopped, for example by scxcli stop.
            .stopped => @import("i18n").fmt(buffer, "{s} is selected but stopped; the kernel's default scheduler is running. Choose it to start it again.", .{name}),
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
        };
    }

    fn defaultLabel(self: *const Service) []const u8 {
        if (self.listing) |listing| if (listing.find(p.default_id)) |i| return listing.profiles[i].label;
        return @import("i18n").dtr("pearl", "Default");
    }

    /// The unit's environment file, as the listing names it.
    fn configPath(self: *const Service) []const u8 {
        return if (self.listing) |listing| listing.configPath() else p.default_config;
    }

    /// A profile was chosen in the last few seconds and the running instance
    /// predates it, so the previous scheduler may still be on its way out.
    fn switching(self: *const Service) bool {
        const written = modified(self.configPath()) orelse return false;
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
        return self.listing != null or self.problem != null;
    }

    /// Combine the listing scxcli gave last with sched_ext's state and the
    /// unit state last reported by systemd.
    pub fn refresh(self: *Service) void {
        const previous = self.kernel;
        self.kernel = kernelState();
        if (previous == .enabled and self.kernel != .enabled and self.unit_state == .active) self.detached_since = glib.getRealTime();
        self.ops = readOps(&self.ops_buffer);
        self.status = if (self.listing) |listing| p.status(listing, self.unit_state, self.switching(), self.stuck()) else .{};
        self.status.stale = self.current_stale and self.status.kind != .unavailable;
        self.track();
        // A profile other than Default chosen anywhere replaces the notice,
        // once the failed one and the fallback are out of the way.
        if (self.notice != .none and self.applying == null and self.failed == null) if (self.selectedId()) |id| if (!std.mem.eql(u8, id, p.default_id)) {
            self.notice = .none;
        };
        if (self.fallback_pending and self.enabled and self.applying == null) self.fallBack();
        self.scheduleRecheck();
        self.changed(self.context);
    }

    /// The id of the profile the unit's environment selects.
    fn selectedId(self: *const Service) ?[]const u8 {
        const listing = self.listing orelse return null;
        return listing.profiles[p.selection(listing).first orelse return null].id;
    }

    /// Notice a failure of the selected scheduler, including one systemd
    /// already restarted, and act on it once its reason can be read.
    fn track(self: *Service) void {
        // Only a confirmed status says which profile a failure is of, and a
        // restart counted while there was none is put on nobody
        // (`p.Restarts`).
        const process = if (self.listing) |listing| listing.current.running else null;
        const crashed = self.tracker.judge(self.status, self.current_stale, process, self.readRestarts());
        if (self.current_stale) return;
        const id = if (self.status.profile) |i| self.listing.?.profiles[i].id else "";
        if (self.failed) |failed| if (!std.mem.eql(u8, failed, id)) self.clearFailure();
        if (self.failed == null and id.len > 0 and id.len <= self.failed_buffer.len and crashed) {
            @memcpy(self.failed_buffer[0..id.len], id);
            self.failed = self.failed_buffer[0..id.len];
            self.failed_since = if (modified(self.configPath())) |written| @divTrunc(written, std.time.us_per_s) else 0;
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
        self.reloadCurrent();
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
        const from = std.mem.printSentinel(&from_buffer, "@{d}", .{self.failed_since}, 0) catch unreachable;
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
        self.reason = if (reason) |text| std.mem.printSentinel(&self.reason_buffer, "{s}", .{text[0..@min(text.len, self.reason_buffer.len - 1)]}, 0) catch null else null;
        const label = if (self.listing) |listing| if (listing.find(failed)) |i| listing.profiles[i].label else failed else failed;
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

    /// Start Default after a failure, so a scheduler that keeps failing is
    /// not started again at the next boot. It waits for the session to allow
    /// changes, such as while it is locked.
    fn fallBack(self: *Service) void {
        self.fallback_pending = false;
        self.startApply(p.default_id, true, true) catch |err| {
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
    /// the status arrives as a systemd, kernel or file event.
    fn scheduleRecheck(self: *Service) void {
        if (self.recheck_source != 0) _ = glib.Source.remove(self.recheck_source);
        self.recheck_source = 0;
        if (!self.running or self.status.kind != .starting) return;
        const now = glib.getRealTime();
        var deadline: i64 = std.math.maxInt(i64);
        if (modified(self.configPath())) |written| if (written + switch_window > now) {
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
        // A scheduler that never attached is a failure only on a state
        // scxcli gives now.
        self.reloadCurrent();
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
        // What runs is scxcli's to say; the event says when to ask.
        if (relevant) self.reloadCurrent();
        return 1;
    }

    /// scx's clients refresh on changes to the two catalogs and to the
    /// unit's environment file, not on a timer. Any of them, and their
    /// directories, may not exist yet: /etc/scx appears with the first
    /// `scxcli catalog save`.
    fn watch(self: *Service, which: Watch, path: []const u8) void {
        self.unwatch(which);
        const slot = &self.watches[@intFromEnum(which)];
        slot.* = .{ .context = self, .changed = switch (which) {
            .admin, .shipped => catalogChanged,
            .config => configChanged,
        } };
        slot.*.?.start(path);
    }

    fn unwatch(self: *Service, which: Watch) void {
        const slot = &self.watches[@intFromEnum(which)];
        if (slot.*) |*value| value.stop();
        slot.* = null;
    }

    fn catalogChanged(data: *anyopaque) void {
        const self: *Service = @ptrCast(@alignCast(data));
        // scxcli replaces the files whole, so every event leaves a complete
        // file.
        if (!self.running) return;
        self.reloadCatalog();
        self.reload();
    }

    fn configChanged(data: *anyopaque) void {
        const self: *Service = @ptrCast(@alignCast(data));
        if (self.running) self.reload();
    }

    /// Ask scxcli for the listing again; the status follows once it answers.
    pub fn reload(self: *Service) void {
        if (!self.running) return;
        if (self.listing_busy) {
            self.listing_again = true;
            return;
        }
        if (std.c.access(p.scxcli, std.c.X_OK) != 0) {
            self.setProblem(@import("i18n").dtr("pearl", "scxcli is not installed, so the scheduler catalog cannot be read."));
            // scx is optional and may be installed later; its catalog's
            // watch notices that too, but a retry does not depend on it.
            self.listingFailed();
            return;
        }
        var argv = [_:null]?[*:0]const u8{ p.scxcli, "list", "--json" };
        if (!self.spawn(&argv, null, listed)) {
            self.setProblem(@import("i18n").dtr("pearl", "scxcli could not be started."));
            self.listingFailed();
            return;
        }
        self.listing_busy = true;
        self.listing_again = false;
    }

    fn listed(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        var output = finish(source, result);
        defer output.deinit();
        if (!self.running) return;
        self.listing_busy = false;
        if (output.ok()) {
            var arena = std.heap.ArenaAllocator.init(a);
            if (arena.allocator().dupe(u8, output.stdout)) |bytes| {
                if (p.parseListing(arena.allocator(), bytes)) |listing| {
                    self.listing_arena.deinit();
                    self.listing_arena = arena;
                    self.listing = listing;
                    self.problem = null;
                    self.currentConfirmed();
                    self.listingRead();
                    // Overtaken by a change while it was asked for: shown,
                    // not judged; the next answer is.
                    self.tracker.answered(self.listing_again or self.current_again);
                    const watched = if (self.watches[@intFromEnum(Watch.config)]) |*value| value.target() else "";
                    if (!std.mem.eql(u8, listing.configPath(), watched)) self.watch(.config, listing.configPath());
                } else |err| {
                    arena.deinit();
                    log.warn("event=sched-profile-list result={s}", .{@errorName(err)});
                    self.setProblem(if (err == error.UnsupportedVersion) @import("i18n").dtr("pearl", "This version of scxcli is not supported; update Pearl.") else @import("i18n").dtr("pearl", "scxcli printed a listing Pearl cannot read."));
                    // Another version will not appear by asking again; the
                    // catalog watch notices scx being updated.
                    if (err != error.UnsupportedVersion) self.listingFailed();
                }
            } else |_| {
                arena.deinit();
                self.listingFailed();
            }
        } else {
            const line = p.errorLine(output.stderr);
            log.warn("event=sched-profile-list result=failed detail=\"{s}\"", .{line});
            var buffer: [400]u8 = undefined;
            self.setProblem(@import("i18n").fmt(&buffer, "The scheduler catalog could not be read: {s}", .{if (line.len > 0) line[0..@min(line.len, 300)] else "scxcli failed"}));
            self.listingFailed();
        }
        if (self.listing_again) self.reload() else if (self.current_again) self.reloadCurrent();
        self.refresh();
    }

    /// Ask scxcli what runs now, after the unit or sched_ext changed. The
    /// unit's main process and the kernel are scxcli's to compare, so Pearl
    /// does not rebuild that verdict from the events themselves.
    fn reloadCurrent(self: *Service) void {
        if (!self.running or self.listing == null) return;
        // A read in flight may predate the event: read again after it.
        if (self.current_busy or self.listing_busy) {
            self.current_again = true;
            return;
        }
        var argv = [_:null]?[*:0]const u8{ p.scxcli, "get", "--json" };
        if (!self.spawn(&argv, null, currentRead)) {
            // Not asked at all is not an answer either.
            self.currentUnconfirmed();
            return self.refresh();
        }
        self.current_busy = true;
        self.current_again = false;
    }

    fn currentRead(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        var output = finish(source, result);
        defer output.deinit();
        if (!self.running) return;
        self.current_busy = false;
        var fresh = false;
        if (output.ok()) if (self.listing) |*listing| {
            var arena = std.heap.ArenaAllocator.init(a);
            const parsed = if (arena.allocator().dupe(u8, output.stdout)) |bytes| p.parseCurrent(arena.allocator(), bytes) else |err| err;
            if (parsed) |state| {
                listing.current = state;
                self.current_arena.deinit();
                self.current_arena = arena;
                fresh = true;
            } else |err| {
                arena.deinit();
                log.warn("event=sched-profile-get result={s}", .{@errorName(err)});
            }
        } else log.warn("event=sched-profile-get result=failed detail=\"{s}\"", .{p.errorLine(output.stderr)});
        if (fresh) self.currentConfirmed() else self.currentUnconfirmed();
        // Overtaken by a change while it was asked for: shown, not judged;
        // the answer to the read asked for next is.
        if (fresh) self.tracker.answered(self.current_again);
        if (self.current_again) self.reloadCurrent();
        self.refresh();
    }

    /// scxcli listed the catalog: no retry is due.
    fn listingRead(self: *Service) void {
        self.listing_retry.reset();
        if (self.listing_retry_source != 0) _ = glib.Source.remove(self.listing_retry_source);
        self.listing_retry_source = 0;
    }

    /// The listing could not be had, and without it nothing else is asked
    /// for: ask again (`p.Retry`) until scxcli answers, besides the catalog
    /// and file watches.
    fn listingFailed(self: *Service) void {
        if (self.listing_retry_source != 0 or !self.running) return;
        self.listing_retry_source = glib.timeoutAddSeconds(self.listing_retry.next(), listingRetry, self);
    }

    fn listingRetry(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data.?));
        self.listing_retry_source = 0;
        self.reload();
        return 0;
    }

    /// The state shown is the one scxcli just gave.
    fn currentConfirmed(self: *Service) void {
        self.current_stale = false;
        self.current_retry.reset();
        if (self.current_retry_source != 0) _ = glib.Source.remove(self.current_retry_source);
        self.current_retry_source = 0;
    }

    /// scxcli could not say what runs, or could not be asked. Keep the last
    /// state on screen as not confirmed, and ask again (`p.Retry`) until it
    /// answers.
    fn currentUnconfirmed(self: *Service) void {
        self.current_stale = true;
        if (self.current_retry_source != 0 or !self.running) return;
        self.current_retry_source = glib.timeoutAddSeconds(self.current_retry.next(), currentRetry, self);
    }

    fn currentRetry(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data.?));
        self.current_retry_source = 0;
        self.reloadCurrent();
        return 0;
    }

    fn setProblem(self: *Service, text: []const u8) void {
        self.problem = std.mem.printSentinel(&self.problem_buffer, "{s}", .{text[0..@min(text.len, self.problem_buffer.len - 1)]}, 0) catch null;
        // Profiles from an earlier listing would no longer be what scx offers.
        self.listing = null;
        // Nor is what ran then known to run when the listing is back.
        self.tracker.invalidate();
        self.changed(self.context);
    }

    /// Ask scxcli for the catalog in use and the shipped one, which editing
    /// and restoring the defaults work from.
    fn reloadCatalog(self: *Service) void {
        if (!self.running) return;
        if (self.catalog_busy) {
            self.catalog_again = true;
            return;
        }
        if (std.c.access(p.scxcli, std.c.X_OK) != 0) return;
        var argv = [_:null]?[*:0]const u8{ p.scxcli, "catalog", "show" };
        if (!self.spawn(&argv, null, catalogShown)) return;
        self.catalog_busy = true;
        self.catalog_again = false;
    }

    fn catalogShown(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        var output = finish(source, result);
        defer output.deinit();
        if (!self.running) return;
        _ = self.catalog_arena.reset(.retain_capacity);
        self.catalog = null;
        self.shipped = null;
        if (output.ok()) {
            self.catalog = self.catalog_arena.allocator().dupe(u8, output.stdout) catch null;
        } else log.warn("event=sched-profile-catalog result=failed detail=\"{s}\"", .{p.errorLine(output.stderr)});
        var argv = [_:null]?[*:0]const u8{ p.scxcli, "catalog", "show", "--shipped" };
        if (!self.spawn(&argv, null, shippedShown)) return self.catalogDone();
    }

    fn shippedShown(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        var output = finish(source, result);
        defer output.deinit();
        if (!self.running) return;
        if (output.ok()) {
            const alloc = self.catalog_arena.allocator();
            if (alloc.dupe(u8, output.stdout)) |bytes| {
                self.shipped = p.parseCatalog(alloc, bytes) catch null;
            } else |_| {}
        }
        self.catalogDone();
    }

    fn catalogDone(self: *Service) void {
        self.catalog_busy = false;
        if (self.catalog_again) self.reloadCatalog();
        self.changed(self.context);
    }

    /// Save the profiles for every user, and start again what the unit runs
    /// if its profile's command changed, or Default if it was deleted; a
    /// stopped or failed selection stays as it is. scxcli asks for an
    /// administrator password. renamed says which profile an edit gave a new
    /// id, so what runs can follow it.
    ///
    /// The list replaces the recommended list of the catalog last shown.
    /// scxcli has no conditional write, so right before saving Pearl asks
    /// for the catalog again and refuses when it changed meanwhile, rather
    /// than overwrite an edit made elsewhere.
    pub fn saveProfiles(self: *Service, profiles: []const p.Profile, renamed: ?p.Rename) !void {
        const before = try self.startEdit();
        const catalog = self.catalog orelse return error.Unavailable;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const bytes = try p.renderCatalog(arena.allocator(), catalog, profiles);
        const reapply = p.reapply(before.profiles, profiles, p.active(before), renamed);
        if (reapply) |id| if (id.len > self.after_save_buffer.len) return error.InvalidProfile;
        const input = try a.dupeSentinel(u8, bytes, 0);
        errdefer a.free(input);
        const base = try a.dupe(u8, catalog);
        errdefer a.free(base);
        try self.setAfterSave(reapply, p.active(before));
        var argv = [_:null]?[*:0]const u8{ p.scxcli, "catalog", "show" };
        if (!self.spawn(&argv, null, saveChecked)) {
            self.after_save = null;
            return error.ScxcliUnavailable;
        }
        self.save_input = input;
        self.save_base = base;
        self.saving = true;
        self.err = null;
        self.changed(self.context);
    }

    fn saveChecked(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        var output = finish(source, result);
        defer output.deinit();
        const base = self.save_base;
        self.save_base = null;
        defer if (base) |value| a.free(value);
        if (!self.running) return;
        const input = self.save_input orelse return;
        const current = output.ok() and base != null and std.mem.eql(u8, output.stdout, base.?);
        if (current) {
            var argv = [_:null]?[*:0]const u8{ "/usr/bin/pkexec", p.scxcli, "catalog", "save" };
            if (self.spawn(&argv, input.ptr, edited)) return;
            self.err = @import("i18n").dtr("pearl", "The profiles could not be saved: scxcli could not be started.");
        } else {
            log.warn("event=sched-profile-edit result=stale", .{});
            self.err = if (output.ok()) @import("i18n").dtr("pearl", "The scheduler catalog was changed elsewhere meanwhile. Nothing was saved; review the profiles and save again.") else @import("i18n").dtr("pearl", "The profiles could not be saved: the scheduler catalog could not be read.");
        }
        a.free(input);
        self.save_input = null;
        self.saving = false;
        self.after_save = null;
        self.reloadCatalog();
        self.reload();
        self.changed(self.context);
    }

    /// Return to the shipped catalog, and keep what the unit runs matching a
    /// profile: the shipped profile for its command, else Default.
    pub fn restoreDefaults(self: *Service) !void {
        const before = try self.startEdit();
        const shipped = self.shipped orelse return error.Unavailable;
        const reapply = p.reapply(before.profiles, shipped, p.active(before), null);
        if (reapply) |id| if (id.len > self.after_save_buffer.len) return error.InvalidProfile;
        try self.setAfterSave(reapply, p.active(before));
        var argv = [_:null]?[*:0]const u8{ "/usr/bin/pkexec", p.scxcli, "catalog", "reset" };
        if (!self.spawn(&argv, null, edited)) {
            self.after_save = null;
            return error.ScxcliUnavailable;
        }
        self.saving = true;
        self.err = null;
        self.changed(self.context);
    }

    /// Remember what to start after the save, and what ran when that was
    /// decided; reapply is only ever set while something ran.
    fn setAfterSave(self: *Service, reapply: ?[]const u8, ran: ?p.Command) !void {
        _ = self.after_save_arena.reset(.retain_capacity);
        self.after_save = null;
        self.after_save_command = null;
        const id = reapply orelse return;
        const command = ran orelse return;
        const alloc = self.after_save_arena.allocator();
        const args = try alloc.alloc([]const u8, command.args.len);
        for (command.args, args) |arg, *copy| copy.* = try alloc.dupe(u8, arg);
        self.after_save_command = .{ .sched = try alloc.dupe(u8, command.sched), .args = args };
        @memcpy(self.after_save_buffer[0..id.len], id);
        self.after_save = self.after_save_buffer[0..id.len];
    }

    fn startEdit(self: *Service) !p.Listing {
        if (!self.running or !self.enabled) return error.Unavailable;
        if (self.applying != null or self.saving) return error.Busy;
        return self.listing orelse error.Unavailable;
    }

    fn edited(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        var output = finish(source, result);
        defer output.deinit();
        if (self.save_input) |value| a.free(value);
        self.save_input = null;
        self.saving = false;
        if (!self.running) return;
        const succeeded = output.ok();
        log.info("event=sched-profile-edit result={s}", .{if (succeeded) "ok" else "failed"});
        // pkexec reports a dismissed or refused authentication as 126 or 127:
        // nothing changed.
        if (!succeeded and !output.dismissed()) {
            const detail = p.errorLine(output.stderr);
            self.err = std.mem.printSentinel(&self.err_buffer, "The profiles could not be saved{s}{s}", .{ if (detail.len > 0) ": " else ".", detail[0..@min(detail.len, 400)] }, 0) catch "The profiles could not be saved.";
        }
        self.reloadCatalog();
        self.reload();
        // Ask what runs now before starting anything: the save may have
        // waited on the password prompt while something else changed it.
        if (succeeded and self.after_save != null) {
            var argv = [_:null]?[*:0]const u8{ p.scxcli, "get", "--json" };
            if (self.spawn(&argv, null, reapplyChecked)) return self.changed(self.context);
            log.warn("event=sched-profile-reapply result=skipped detail=\"scxcli could not be started\"", .{});
        }
        self.after_save = null;
        self.changed(self.context);
    }

    fn reapplyChecked(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        var output = finish(source, result);
        defer output.deinit();
        if (!self.running) return;
        const id = self.after_save orelse return;
        defer self.after_save = null;
        const expected = self.after_save_command orelse return;
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const now = if (output.ok()) p.parseCurrent(scratch.allocator(), output.stdout) catch null else null;
        const still = if (now) |state| p.stillRuns(.{ .profiles = &.{}, .current = state }, expected) else false;
        if (!still) {
            log.info("event=sched-profile-reapply profile={s} result=skipped detail=\"what runs changed during the save\"", .{id});
            return self.changed(self.context);
        }
        // The listing still predates the save, so it may not hold the id yet;
        // scxcli checks it against the catalog it just installed.
        if (self.startApply(id, false, false)) {
            self.notice = .none;
            self.fallback_pending = false;
        } else |e| log.warn("event=sched-profile-select profile={s} result={s}", .{ id, @errorName(e) });
        self.changed(self.context);
    }

    pub fn apply(self: *Service, id: []const u8) !void {
        try self.startApply(id, false, true);
        self.notice = .none;
        self.fallback_pending = false;
    }

    /// listed_only is whether the id must be in the current listing, with
    /// its scheduler installed.
    fn startApply(self: *Service, id: []const u8, reverting: bool, listed_only: bool) !void {
        if (!self.running or !self.enabled) return error.Unavailable;
        if (self.applying != null or self.saving) return error.Busy;
        // Default needs no listing: the kernel's own scheduler is always
        // there to go back to.
        if (listed_only and !std.mem.eql(u8, id, p.default_id)) {
            const listing = self.listing orelse return error.Unavailable;
            const i = listing.find(id) orelse return error.InvalidProfile;
            if (!listing.profiles[i].available) return error.NotInstalled;
        }
        if (id.len >= self.applying_buffer.len) return error.InvalidProfile;
        @memcpy(self.applying_buffer[0..id.len], id);
        self.applying_buffer[id.len] = 0;
        // scxcli takes the id only: the command comes from the installed
        // catalog, so any active user may start a profile without a
        // password.
        var argv = [_:null]?[*:0]const u8{ "/usr/bin/pkexec", p.scxcli, "start", self.applying_buffer[0..id.len :0] };
        if (!self.spawn(&argv, null, applied)) return error.ScxcliUnavailable;
        self.applying = self.applying_buffer[0..id.len];
        self.reverting = reverting;
        self.err = null;
        self.changed(self.context);
    }

    fn applied(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        var output = finish(source, result);
        defer output.deinit();
        if (!self.running) return;
        const id = self.applying orelse return;
        const succeeded = output.ok();
        log.info("event=sched-profile-select profile={s} result={s}", .{ id, if (succeeded) "ok" else "failed" });
        const reverting = self.reverting;
        self.reverting = false;
        self.applying = null;
        // pkexec reports a dismissed or refused authentication as 126 or 127:
        // nothing changed, so there is nothing to fall back from.
        // A refused start is not a failed scheduler: scxcli checks the id,
        // the catalog and the configuration before it touches the unit, so
        // whatever ran before still runs. Say why and read the state again;
        // only a scheduler that actually fails falls back to Default, through
        // the unit's own state.
        if (!succeeded and !output.dismissed()) {
            const detail = p.errorLine(output.stderr);
            log.warn("event=sched-profile-select profile={s} reverting={} detail=\"{s}\"", .{ id, reverting, detail });
            self.err = std.mem.printSentinel(&self.err_buffer, "The profile could not be applied{s}{s}", .{ if (detail.len > 0) ": " else ".", detail[0..@min(detail.len, 400)] }, 0) catch "The profile could not be applied.";
        }
        // The environment file's monitor reloads the listing too; asking
        // here covers a start that changed nothing in it.
        self.reload();
        self.refresh();
    }

    /// Run a command, feeding it input when given, and call done with its
    /// output. Holds the application until done runs.
    fn spawn(self: *Service, argv: [*:null]const ?[*:0]const u8, input: ?[*:0]const u8, done: *const fn (?*object.Object, *gio.AsyncResult, ?*anyopaque) callconv(.c) void) bool {
        var err: ?*glib.Error = null;
        const process = gio.Subprocess.newv(@ptrCast(argv), .{ .stdin_pipe = input != null, .stdout_pipe = true, .stderr_pipe = true }, &err) orelse {
            if (err) |e| {
                log.warn("event=sched-profile-spawn result=failed detail=\"{s}\"", .{if (e.f_message) |m| std.mem.span(m) else ""});
                e.free();
            }
            return false;
        };
        self.app.hold();
        process.communicateUtf8Async(input, self.cancel, done, self);
        return true;
    }

    /// The context of one asynchronous systemd call: a result from a
    /// superseded connection attempt is discarded.
    const Ticket = struct {
        service: *Service,
        attempt: u32,

        fn issue(self: *Service) ?*Ticket {
            const ticket = a.create(Ticket) catch return null;
            ticket.* = .{ .service = self, .attempt = self.link.attempt };
            self.app.hold();
            return ticket;
        }

        /// The service, and whether the result is still wanted. Frees the
        /// ticket.
        fn redeem(data: ?*anyopaque) struct { *Service, bool } {
            const ticket: *Ticket = @ptrCast(@alignCast(data.?));
            const self = ticket.service;
            const wanted = self.running and self.link.current(ticket.attempt);
            a.destroy(ticket);
            self.app.release();
            return .{ self, wanted };
        }
    };

    /// Drop the proxies of an earlier attempt and cancel its calls.
    fn dropSystemd(self: *Service) void {
        if (self.systemd_cancel) |cancel| cancel.cancel();
        if (self.unit) |proxy| {
            object.signalHandlerDisconnect(proxy.as(object.Object), self.unit_signal);
            proxy.unref();
        }
        if (self.process) |proxy| {
            object.signalHandlerDisconnect(proxy.as(object.Object), self.process_signal);
            proxy.unref();
        }
        if (self.manager) |proxy| proxy.unref();
        self.unit = null;
        self.process = null;
        self.manager = null;
    }

    /// Make the manager, unit and service proxies anew and subscribe, for
    /// systemd's current owner. Until both the unit's proxy and the
    /// subscription work, scxcli is polled.
    fn connectSystemd(self: *Service) void {
        if (!self.running or !self.link.begin()) return;
        self.dropSystemd();
        if (self.systemd_cancel) |cancel| cancel.unref();
        self.systemd_cancel = gio.Cancellable.new();
        self.linkChanged();
        const ticket = Ticket.issue(self) orelse return self.systemdStep(.unit, false);
        gio.DBusProxy.newForBus(.system, .{ .do_not_load_properties = true }, null, systemd, "/org/freedesktop/systemd1", systemd ++ ".Manager", self.systemd_cancel, managerReady, ticket);
    }

    const Step = enum { unit, service, subscribe };

    /// Record a step of the current attempt and act on what the link says.
    fn systemdStep(self: *Service, step: Step, ok: bool) void {
        const attempt = self.link.attempt;
        const again = switch (step) {
            .unit => self.link.unitResult(attempt, ok),
            .service => self.link.serviceResult(attempt, ok),
            .subscribe => self.link.subscribeResult(attempt, ok),
        };
        if (!ok) log.warn("event=sched-profile-systemd step={t} result=failed", .{step});
        self.linkChanged();
        if (again) self.connectSystemd();
    }

    /// Poll while the signals cannot be relied on, and only then.
    fn linkChanged(self: *Service) void {
        if (!self.running) return;
        if (self.link.polling()) {
            if (self.systemd_poll_source == 0) {
                log.info("event=sched-profile-systemd result=polling", .{});
                self.systemd_poll_source = glib.timeoutAddSeconds(5, systemdPoll, self);
            }
        } else if (self.systemd_poll_source != 0) {
            _ = glib.Source.remove(self.systemd_poll_source);
            self.systemd_poll_source = 0;
            log.info("event=sched-profile-systemd result=signals", .{});
            // Signals may have been missed meanwhile.
            self.reloadCurrent();
        }
    }

    fn systemdPoll(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data.?));
        self.reloadCurrent();
        if (self.link.retry()) self.connectSystemd();
        return 1;
    }

    /// systemd took its name on the bus: connect again when the connection
    /// is not whole or was made against another owner (systemd
    /// re-executed or restarted, and its subscriptions with it).
    fn systemdAppeared(_: *gio.DBusConnection, _: [*:0]const u8, owner: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        if (!self.running) return;
        if (self.link.appeared(std.mem.span(owner))) {
            log.info("event=sched-profile-systemd result=reconnecting", .{});
            self.connectSystemd();
        }
        self.linkChanged();
    }

    fn systemdVanished(_: *gio.DBusConnection, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        if (!self.running) return;
        self.link.vanished();
        self.linkChanged();
    }

    fn managerReady(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self, const wanted = Ticket.redeem(data);
        var err: ?*glib.Error = null;
        const proxy = gio.DBusProxy.newForBusFinish(result, &err);
        defer if (err) |e| e.free();
        if (!wanted) {
            if (proxy) |value| value.unref();
            return;
        }
        self.manager = proxy orelse return self.systemdStep(.unit, false);
        // Unit property changes are only broadcast to subscribed clients.
        if (Ticket.issue(self)) |ticket| self.manager.?.call("Subscribe", null, .{}, 5000, self.systemd_cancel, subscribed, ticket) else return self.systemdStep(.subscribe, false);
        const ticket = Ticket.issue(self) orelse return self.systemdStep(.unit, false);
        self.manager.?.call("LoadUnit", tuple(&.{glib.Variant.newString("scx.service")}), .{}, 5000, self.systemd_cancel, unitLoaded, ticket);
    }

    fn subscribed(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self, const wanted = Ticket.redeem(data);
        var err: ?*glib.Error = null;
        const reply = object.ext.cast(gio.DBusProxy, source.?).?.callFinish(result, &err);
        defer if (reply) |value| value.unref();
        defer if (err) |e| e.free();
        if (!wanted) return;
        // A client systemd already tracks is subscribed all the same.
        const already = if (err) |e| (if (e.f_message) |m| std.mem.indexOf(u8, std.mem.span(m), "AlreadySubscribed") != null else false) else false;
        self.systemdStep(.subscribe, reply != null or already);
    }

    fn unitLoaded(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self, const wanted = Ticket.redeem(data);
        var err: ?*glib.Error = null;
        const reply = object.ext.cast(gio.DBusProxy, source.?).?.callFinish(result, &err);
        defer if (reply) |value| value.unref();
        defer if (err) |e| e.free();
        if (!wanted) return;
        const value = reply orelse return self.systemdStep(.unit, false);
        const child = value.getChildValue(0);
        defer child.unref();
        const unit_ticket = Ticket.issue(self) orelse return self.systemdStep(.unit, false);
        gio.DBusProxy.newForBus(.system, .{ .get_invalidated_properties = true }, null, systemd, child.getString(null), systemd ++ ".Unit", self.systemd_cancel, unitReady, unit_ticket);
        const process_ticket = Ticket.issue(self) orelse return self.systemdStep(.service, false);
        gio.DBusProxy.newForBus(.system, .{ .get_invalidated_properties = true }, null, systemd, child.getString(null), systemd ++ ".Service", self.systemd_cancel, processReady, process_ticket);
    }

    fn unitReady(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self, const wanted = Ticket.redeem(data);
        var err: ?*glib.Error = null;
        const proxy = gio.DBusProxy.newForBusFinish(result, &err);
        defer if (err) |e| e.free();
        if (!wanted) {
            if (proxy) |value| value.unref();
            return;
        }
        self.unit = proxy orelse return self.systemdStep(.unit, false);
        self.unit_signal = gio.DBusProxy.signals.g_properties_changed.connect(self.unit.?, *Service, unitChanged, self, .{});
        self.readUnit();
        self.refresh();
        self.systemdStep(.unit, true);
    }

    fn processReady(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self, const wanted = Ticket.redeem(data);
        var err: ?*glib.Error = null;
        const proxy = gio.DBusProxy.newForBusFinish(result, &err);
        defer if (err) |e| e.free();
        if (!wanted) {
            if (proxy) |value| value.unref();
            return;
        }
        self.process = proxy orelse return self.systemdStep(.service, false);
        // NRestarts and Result arrive on this interface, not on the Unit one.
        self.process_signal = gio.DBusProxy.signals.g_properties_changed.connect(self.process.?, *Service, unitChanged, self, .{});
        self.refresh();
        self.systemdStep(.service, true);
    }

    fn unitChanged(_: *gio.DBusProxy, _: *glib.Variant, _: [*][*:0]u8, self: *Service) callconv(.c) void {
        self.readUnit();
        self.refresh();
        self.reloadCurrent();
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
        const title = std.mem.printSentinel(&title_buffer, "CPU scheduler switched to {s}", .{self.defaultLabel()}, 0) catch "CPU scheduler switched to Default";
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

/// What a finished scxcli or pkexec run printed and how it ended.
const Output = struct {
    process: *gio.Subprocess,
    finished: bool,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    stdout_raw: ?[*:0]u8 = null,
    stderr_raw: ?[*:0]u8 = null,

    fn ok(self: Output) bool {
        return self.finished and self.process.getSuccessful() != 0;
    }

    /// pkexec reports a dismissed or refused authentication as 126 or 127.
    fn dismissed(self: Output) bool {
        if (!self.finished or self.process.getIfExited() == 0) return false;
        const code = self.process.getExitStatus();
        return code == 126 or code == 127;
    }

    fn deinit(self: *Output) void {
        if (self.stdout_raw) |text| glib.free(text);
        if (self.stderr_raw) |text| glib.free(text);
        self.process.unref();
    }
};

fn finish(source: ?*object.Object, result: *gio.AsyncResult) Output {
    const process = object.ext.cast(gio.Subprocess, source.?).?;
    var stdout_buffer: [*:0]u8 = undefined;
    var stderr_buffer: [*:0]u8 = undefined;
    var err: ?*glib.Error = null;
    const finished = process.communicateUtf8Finish(result, &stdout_buffer, &stderr_buffer, &err) != 0;
    if (err) |e| e.free();
    var output: Output = .{ .process = process, .finished = finished };
    if (finished) {
        output.stdout_raw = stdout_buffer;
        output.stderr_raw = stderr_buffer;
        output.stdout = std.mem.span(stdout_buffer);
        output.stderr = std.mem.span(stderr_buffer);
    }
    return output;
}

/// When a file was last written, in microseconds since the epoch.
fn modified(path: []const u8) ?i64 {
    var buffer: [256]u8 = undefined;
    const name = std.mem.printSentinel(&buffer, "{s}", .{path}, 0) catch return null;
    var stat: std.os.linux.Statx = std.mem.zeroes(std.os.linux.Statx);
    if (std.os.linux.statx(std.os.linux.AT.FDCWD, name, 0, .{ .MTIME = true }, &stat) != 0) return null;
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
