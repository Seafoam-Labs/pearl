//! Session-scoped login1 orchestration; native lock ownership outlives Pearl.
const std = @import("std");
const db = @import("dbus_peer.zig");
const gio = db.gio;
const glib = db.glib;
const unix = @import("glibunix2");
const object = @import("gobject2");
const policy = @import("idle_policy.zig");
const Idle = @import("../platform/wayland/idle.zig").Idle;
const a = std.heap.c_allocator;
const path = "/org/freedesktop/login1";
const iface = "org.freedesktop.login1.Manager";
pub const Action = enum { logout, @"suspend", hibernate };
const FdJob = struct { service: *Lifecycle, epoch: u64 };
pub const Lifecycle = struct {
    activity_broker: ?*@import("../platform/wayland/input_activity.zig").Broker = null,
    activity_token: @import("../platform/wayland/input_activity.zig").Token = .{},
    app: *gio.Application,
    display: *@import("gdk4").Display,
    client: *@import("../aqueous/client.zig").Client,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    request_logout: *const fn (*anyopaque) void,
    peer: db.Peer = undefined,
    idle: Idle = undefined,
    gate: policy.Gate = .{},
    config: policy.Config = .{},
    on_battery: bool = false,
    idle_held: bool = false,
    session_path: db.Text(512) = .{},
    session_id: db.Text(128) = .{},
    session_error: db.Text(256) = .{},
    session_lookup_pending: bool = false,
    session_source: enum { compositor, compositor_environment, environment, process, display } = .process,
    session_generation: u32 = 0,
    session_client_generation: ?u64 = null,
    user_path: db.Text(512) = .{},
    can_suspend: bool = false,
    can_hibernate: bool = false,
    pending: ?Action = null,
    confirmation: u64 = 0,
    confirmation_timer: c_uint = 0,
    sleep_action: Action = .@"suspend",
    action_busy: bool = false,
    query_busy: bool = false,
    sleep_checked_locked: bool = false,
    automatic_sleep: bool = false,
    query_action: ?enum { lock, sleep, manual_sleep } = null,
    delay_fd: c_int = -1,
    fd_pending: bool = false,
    lock_fd: c_int = -1,
    lock_source: c_uint = 0,
    lock_deadline: c_uint = 0,
    locker: ?*gio.Subprocess = null,
    lock_cancel: *gio.Cancellable = undefined,
    running: bool = false,
    lock_supported: bool = false,
    err: ?[]const u8 = null,
    pub fn start(self: *Lifecycle) !void {
        self.running = true;
        self.lock_supported = @import("gtk4sessionlock1").isSupported() != 0;
        self.lock_cancel = gio.Cancellable.new();
        self.peer = .{ .app = self.app, .context = self, .changed = ownerChanged, .name = "org.freedesktop.login1", .root = path, .managed = false, .signal_received = signal };
        self.idle = .{ .display = self.display, .context = self, .event = idleEvent };
        try self.idle.start();
        self.peer.start();
    }
    pub fn stop(self: *Lifecycle) void {
        self.running = false;
        self.activity_token.cancel();
        self.cancelConfirmation();
        self.idle.stop();
        self.peer.stop();
        self.closeDelay();
        self.closeLockPipe();
        self.lock_cancel.cancel();
        self.lock_cancel.unref();
        // Never terminate the locker when the shell/service stops.
        if (self.locker) |p| p.unref();
        self.locker = null;
    }
    pub fn configure(self: *Lifecycle, config: policy.Config, on_battery: bool) void {
        if (std.meta.eql(self.config, config) and self.on_battery == on_battery) return;
        self.config = config;
        self.on_battery = on_battery;
        self.rearm();
    }
    fn rearm(self: *Lifecycle) void {
        self.idle.configure(if (self.idle_held or !self.gate.available or !self.gate.active or self.gate.preparing) .{} else if (self.on_battery) self.config.battery else self.config.ac);
    }
    pub fn sync(self: *Lifecycle) void {
        const ready = self.client.availability == .ready;
        if (ready and self.peer.owner.len != 0 and self.session_client_generation != self.client.generation) {
            self.invalidateSession();
            self.resolveSession();
        }
        const locked = if (ready) (if (self.client.model.get(.session, "session")) |s| s.locked else false) else false;
        const changed = self.gate.available != ready or self.gate.locked != locked;
        self.gate.available = ready;
        self.gate.locked = locked;
        if (!ready) {
            self.gate.sleep_pending = false;
            self.cancelConfirmation();
        }
        if (changed) self.rearm();
        self.advance();
    }
    fn ownerChanged(data: *anyopaque, _: bool) void {
        const self: *Lifecycle = @ptrCast(@alignCast(data));
        self.closeDelay();
        self.fd_pending = false;
        self.session_id = .{};
        self.session_path = .{};
        self.session_error = .{};
        self.session_lookup_pending = false;
        self.session_generation +%= 1;
        self.session_client_generation = null;
        self.user_path = .{};
        self.gate.active = false;
        self.gate.sleep_pending = false;
        self.gate.preparing = false;
        self.can_suspend = false;
        self.can_hibernate = false;
        self.action_busy = false;
        self.query_busy = false;
        self.query_action = null;
        self.cancelConfirmation();
        self.rearm();
        if (self.peer.owner.len != 0) {
            self.resolveSession();
            self.call(2, "CanSuspend", null, "(s)") catch {};
            self.call(3, "CanHibernate", null, "(s)") catch {};
        }
        if (self.running) self.changed(self.context);
    }
    fn call(self: *Lifecycle, token: u64, method: [:0]const u8, args: ?*glib.Variant, signature: [:0]const u8) !void {
        try self.peer.call(token, path, iface, method, args, signature, 5000, done);
    }
    fn refreshSession(self: *Lifecycle) void {
        if (self.session_path.len == 0) return;
        self.session_lookup_pending = true;
        self.sessionCall(4, self.session_path.z(), "org.freedesktop.DBus.Properties", "GetAll", db.tuple(&.{db.str("org.freedesktop.login1.Session")}), "(a{sv})") catch self.sessionFailed("Could not read the logind session.");
    }
    fn sessionCall(self: *Lifecycle, token: u32, object_path: [:0]const u8, interface: [:0]const u8, method: [:0]const u8, args: ?*glib.Variant, signature: [:0]const u8) !void {
        try self.peer.call((@as(u64, self.session_generation) << 32) | token, object_path, interface, method, args, signature, 5000, done);
    }
    fn resolveSession(self: *Lifecycle) void {
        if (self.session_lookup_pending or self.peer.owner.len == 0 or self.client.availability != .ready) return;
        self.session_generation +%= 1;
        self.session_client_generation = self.client.generation;
        self.session_lookup_pending = true;
        // User.Display can name an older, inactive login on another VT. Bind
        // to the compositor behind our verified IPC connection first.
        const pid = self.client.request.wire.peerPid() orelse {
            self.sessionFailed("Could not identify the connected compositor.");
            return;
        };
        self.session_source = .compositor;
        self.sessionCall(9, path, iface, "GetSessionByPID", db.tuple(&.{glib.Variant.newUint32(pid)}), "(o)") catch self.sessionFailed("Could not query the compositor's login session.");
    }
    fn resolveEnvironmentSession(self: *Lifecycle) void {
        // UWSM may place both compositor and Pearl outside a login scope.
        // Treat the inherited ID only as a hint: GetAll still verifies its UID
        // and login class, and Active still gates every authentication request.
        // UWSM exports session variables to the compositor's unit specifically,
        // so Pearl's user service may not inherit them itself.
        const pid = self.client.request.wire.peerPid() orelse {
            self.sessionFailed("Could not identify the connected compositor.");
            return;
        };
        const compositor_id = @import("session_environment.zig").read(pid) catch {
            self.sessionFailed("Could not read the compositor's login session hint.");
            return;
        };
        if (compositor_id) |id| {
            self.session_source = .compositor_environment;
            self.sessionCall(10, path, iface, "GetSession", db.tuple(&.{db.str(id.z())}), "(o)") catch self.sessionFailed("Could not query the compositor's inherited login session.");
            return;
        }
        const id: [:0]const u8 = if (glib.getenv("XDG_SESSION_ID")) |v| std.mem.span(v) else "";
        if (id.len == 0) {
            self.resolveDisplaySession();
            return;
        }
        if (id.len >= 128) {
            self.sessionFailed("Invalid inherited login session ID.");
            return;
        }
        self.session_source = .environment;
        self.sessionCall(10, path, iface, "GetSession", db.tuple(&.{db.str(id)}), "(o)") catch self.sessionFailed("Could not query the inherited login session.");
    }
    fn resolveProcessSession(self: *Lifecycle) void {
        self.session_source = .process;
        self.sessionCall(1, path, iface, "GetSessionByPID", db.tuple(&.{glib.Variant.newUint32(@intCast(std.c.getpid()))}), "(o)") catch self.sessionFailed("Could not query logind.");
    }
    fn resolveDisplaySession(self: *Lifecycle) void {
        // Compatibility fallback when neither compositor, inherited session,
        // nor Pearl's own process identifies a login session.
        self.session_source = .display;
        self.session_lookup_pending = true;
        self.sessionCall(7, path, iface, "GetUser", db.tuple(&.{glib.Variant.newUint32(std.c.getuid())}), "(o)") catch self.sessionFailed("Could not query the logind user.");
    }
    fn invalidateSession(self: *Lifecycle) void {
        self.session_lookup_pending = false;
        self.session_id = .{};
        self.session_path = .{};
        self.gate.active = false;
        self.closeDelay();
        self.cancelConfirmation();
        self.rearm();
    }
    fn sessionFailed(self: *Lifecycle, reason: []const u8) void {
        self.invalidateSession();
        self.session_error.set(reason);
        std.log.warn("event=logind-session-unavailable reason={s}", .{reason});
    }
    fn done(data: *anyopaque, raw_token: u64, result: ?*glib.Variant, remote_error: ?[]const u8) void {
        const self: *Lifecycle = @ptrCast(@alignCast(data));
        const token: u32 = @truncate(raw_token);
        if (token == 1 or token == 4 or token == 7 or token == 8 or token == 9 or token == 10) {
            if (raw_token >> 32 != self.session_generation or self.session_client_generation != self.client.generation) return;
        }
        defer {
            self.advance();
            self.changed(self.context);
        }
        const v = result orelse {
            if (token == 9) {
                if (std.mem.eql(u8, remote_error orelse "", "org.freedesktop.login1.NoSessionForPID")) self.resolveProcessSession() else self.sessionFailed(remote_error orelse "Compositor session lookup failed.");
                return;
            }
            if (token == 10) {
                self.sessionFailed(remote_error orelse "Inherited session lookup failed.");
                return;
            }
            if (token == 1) {
                if (std.mem.eql(u8, remote_error orelse "", "org.freedesktop.login1.NoSessionForPID")) self.resolveEnvironmentSession() else self.sessionFailed(remote_error orelse "Session lookup failed.");
                return;
            }
            if (token == 4 or token == 7 or token == 8) {
                self.sessionFailed(remote_error orelse "Session lookup failed.");
                return;
            }
            if (token == 5) {
                self.query_busy = false;
                self.query_action = null;
                self.gate.sleep_pending = false;
            }
            if (token == 6) self.action_busy = false;
            self.err = "Session service request failed.";
            return;
        };
        const child = if (v.nChildren() > 0) v.getChildValue(0) else null;
        defer if (child) |c| c.unref();
        switch (token) {
            1, 9, 10 => {
                self.session_path.set(std.mem.span(child.?.getString(null)));
                self.refreshSession();
            },
            2, 3 => {
                const value = std.mem.span(child.?.getString(null));
                const permitted = std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "challenge");
                if (token == 2) self.can_suspend = permitted else self.can_hibernate = permitted;
            },
            4 => {
                self.session_lookup_pending = false;
                const class = db.string(child.?, "Class", "s");
                if (self.session_source != .display and std.mem.eql(u8, class.slice(), "manager")) {
                    switch (self.session_source) {
                        .compositor => self.resolveProcessSession(),
                        .process => self.resolveEnvironmentSession(),
                        .environment, .compositor_environment => self.sessionFailed("Inherited session is a user manager, not a desktop login."),
                        .display => unreachable,
                    }
                    return;
                }
                const user = db.lookup(child.?, "User", "(uo)") orelse {
                    self.sessionFailed("Logind session has no user identity.");
                    return;
                };
                defer user.unref();
                const uid = user.getChildValue(0);
                defer uid.unref();
                if (uid.getUint32() != std.c.getuid() or !(std.mem.eql(u8, class.slice(), "user") or std.mem.eql(u8, class.slice(), "user-early") or std.mem.eql(u8, class.slice(), "user-light"))) {
                    self.sessionFailed("Logind session is not a login session owned by this user.");
                    return;
                }
                self.session_id = narrow(db.string(child.?, "Id", "s"));
                if (self.session_id.len == 0) {
                    self.sessionFailed("Logind session has no ID.");
                    return;
                }
                self.session_error = .{};
                self.gate.active = db.boolean(child.?, "Active");
                if (!self.gate.active) {
                    self.gate.sleep_pending = false;
                    self.cancelConfirmation();
                }
                self.rearm();
                if (self.session_id.len != 0) self.inhibitDelay();
            },
            7 => {
                self.user_path.set(std.mem.span(child.?.getString(null)));
                self.sessionCall(8, self.user_path.z(), "org.freedesktop.DBus.Properties", "Get", db.tuple(&.{ db.str("org.freedesktop.login1.User"), db.str("Display") }), "(v)") catch self.sessionFailed("Could not read the logind display session.");
            },
            8 => {
                const display = child.?.getVariant();
                defer display.unref();
                if (!db.is(display, "(so)")) {
                    self.sessionFailed("Logind returned an invalid display session.");
                    return;
                }
                const id = display.getChildValue(0);
                defer id.unref();
                const session = display.getChildValue(1);
                defer session.unref();
                if (id.getString(null)[0] == 0 or std.mem.eql(u8, std.mem.span(session.getString(null)), "/")) {
                    self.sessionFailed("No logind display session. Start Pearl from an authenticated desktop login.");
                    return;
                }
                self.session_path.set(std.mem.span(session.getString(null)));
                self.refreshSession();
            },
            5 => {
                self.query_busy = false;
                const action = self.query_action;
                self.query_action = null;
                var idle_block = false;
                var sleep_block = false;
                if (child.?.nChildren() > 256 or child.?.getSize() > 131072) {
                    self.err = "Inhibitor list exceeds limits.";
                    self.gate.sleep_pending = false;
                    return;
                }
                for (0..child.?.nChildren()) |i| {
                    const row = child.?.getChildValue(i);
                    defer row.unref();
                    const what = row.getChildValue(0);
                    defer what.unref();
                    const mode = row.getChildValue(3);
                    defer mode.unref();
                    if (!std.mem.eql(u8, std.mem.span(mode.getString(null)), "block")) continue;
                    var parts = std.mem.splitScalar(u8, std.mem.span(what.getString(null)), ':');
                    while (parts.next()) |part| {
                        if (std.mem.eql(u8, part, "idle")) idle_block = true;
                        if (std.mem.eql(u8, part, "sleep")) sleep_block = true;
                    }
                }
                self.gate.inhibited = sleep_block;
                if (action) |op| {
                    if (self.idle_held or (idle_block and op != .manual_sleep) or (sleep_block and op != .lock) or !self.gate.active or !self.gate.available) {
                        self.gate.sleep_pending = false;
                        self.err = "Idle or sleep is inhibited.";
                        return;
                    }
                    if (op == .lock) self.lockNow() catch {
                        self.err = "Could not start Pearl lock.";
                    } else {
                        self.automatic_sleep = op == .sleep;
                        self.sleep_checked_locked = self.gate.acquired();
                        self.gate.sleep_pending = true;
                        if (!self.gate.acquired()) self.lockNow() catch {
                            self.gate.fail();
                            self.err = "Lock failed; suspend cancelled.";
                        };
                    }
                }
            },
            6 => {
                self.action_busy = false;
                self.err = null;
            },
            else => {},
        }
    }
    fn signal(data: *anyopaque, object_path: []const u8, interface: []const u8, member: []const u8, args: *glib.Variant) void {
        const self: *Lifecycle = @ptrCast(@alignCast(data));
        if (self.session_id.len == 0 and ((std.mem.eql(u8, interface, iface) and std.mem.eql(u8, member, "SessionNew")) or (std.mem.eql(u8, object_path, self.user_path.slice()) and std.mem.eql(u8, member, "PropertiesChanged")))) self.resolveSession();
        if (std.mem.eql(u8, interface, iface) and std.mem.eql(u8, member, "PrepareForSleep") and db.is(args, "(b)")) {
            const value = args.getChildValue(0);
            defer value.unref();
            const preparing = value.getBoolean() != 0;
            self.gate.preparing = preparing;
            if (preparing) {
                self.gate.sleep_pending = false;
                self.lockNow() catch {
                    self.err = "Lock failed during suspend preparation. External sleep may still proceed after logind's deadline.";
                };
                self.advance();
            } else {
                self.gate.reset();
                self.inhibitDelay();
                self.rearm();
            }
            self.changed(self.context);
        } else if (std.mem.eql(u8, object_path, self.session_path.slice())) {
            if (std.mem.eql(u8, member, "Lock")) self.lockNow() catch {} else if (std.mem.eql(u8, member, "PropertiesChanged")) self.refreshSession();
        }
    }
    fn closeDelay(self: *Lifecycle) void {
        if (self.delay_fd >= 0) _ = std.c.close(self.delay_fd);
        self.delay_fd = -1;
    }
    fn inhibitDelay(self: *Lifecycle) void {
        if (!self.running or self.peer.owner.len == 0 or self.fd_pending or self.delay_fd >= 0 or self.gate.preparing) return;
        const job = a.create(FdJob) catch return;
        job.* = .{ .service = self, .epoch = self.peer.epoch };
        self.fd_pending = true;
        self.app.hold();
        self.peer.connection().?.callWithUnixFdList(self.peer.owner.z(), path, iface, "Inhibit", db.tuple(&.{ db.str("sleep"), db.str("Pearl"), db.str("Wait for native session lock acquisition"), db.str("delay") }), null, .{ .no_auto_start = true }, 5000, null, self.peer.cancel, inhibited, job);
    }
    fn inhibited(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const job: *FdJob = @ptrCast(@alignCast(data.?));
        const self = job.service;
        defer a.destroy(job);
        defer self.app.release();
        var fds: ?*gio.UnixFDList = null;
        var err: ?*glib.Error = null;
        const value = object.ext.cast(gio.DBusConnection, source.?).?.callWithUnixFdListFinish(@ptrCast(&fds), result, &err);
        defer if (value) |v| v.unref();
        defer if (fds) |f| f.unref();
        defer if (err) |e| e.free();
        if (!self.running or job.epoch != self.peer.epoch) return;
        self.fd_pending = false;
        if (value) |v| if (db.is(v, "(h)") and fds != null and !self.gate.preparing) {
            const handle = v.getChildValue(0);
            defer handle.unref();
            self.delay_fd = fds.?.get(handle.getHandle(), null);
        };
        if (self.delay_fd < 0) self.err = "Suspend delay inhibitor unavailable.";
        self.changed(self.context);
    }
    fn query(self: *Lifecycle, action: @TypeOf(@as(Lifecycle, undefined).query_action)) !void {
        if (self.query_busy) return error.Busy;
        try self.call(5, "ListInhibitors", null, "(a(ssssuu))");
        self.query_busy = true;
        self.query_action = action;
    }
    fn idleEvent(data: *anyopaque, event: @import("../platform/wayland/idle.zig").Event) void {
        const self: *Lifecycle = @ptrCast(@alignCast(data));
        if (!self.running) return;
        switch (event) {
            .unavailable => {
                self.gate.sleep_pending = false;
                self.err = "Compositor idle notifications unavailable.";
            },
            .resumed => {
                if (!self.gate.preparing) self.gate.sleep_pending = false;
            },
            .lock => self.query(.lock) catch {},
            .sleep => {
                if (self.can_suspend and self.delay_fd >= 0) {
                    self.sleep_action = .@"suspend";
                    self.query(.sleep) catch {};
                }
            },
        }
        self.changed(self.context);
    }
    pub fn lockNow(self: *Lifecycle) !void {
        self.syncLockState();
        if (!self.gate.available) return error.Unavailable;
        if (!self.lock_supported) return error.Unsupported;
        if (self.gate.acquired() or self.gate.requesting) return;
        if (self.locker != null) return error.LockFailed;
        self.gate.requesting = true;
        self.activity_token.begin(self.activity_broker, self, activityReady);
        self.changed(self.context);
    }
    fn activityReady(context: *anyopaque) void {
        const self: *Lifecycle = @ptrCast(@alignCast(context));
        if (!self.running) return;
        self.launchLocker() catch {
            self.gate.fail();
            self.gate.requesting = false;
            self.activity_token.cancel();
            self.err = "Could not start Pearl lock.";
            self.changed(self.context);
        };
    }
    fn launchLocker(self: *Lifecycle) !void {
        self.syncLockState();
        if (!self.gate.available or !self.gate.active) return error.Unavailable;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const executable = try self.lockerPath(alloc);
        var pipe: [2]c_int = undefined;
        if (std.c.pipe2(&pipe, .{ .CLOEXEC = true, .NONBLOCK = true }) != 0) return error.PipeFailed;
        const launcher = gio.SubprocessLauncher.new(.{ .stdout_silence = true, .stderr_silence = true });
        defer launcher.unref();
        launcher.takeFd(pipe[1], 3);
        const argv = [_:null]?[*:0]const u8{ executable, "--ready-fd=3" };
        var err: ?*glib.Error = null;
        self.locker = launcher.spawnv(@ptrCast(&argv), &err);
        if (err) |e| e.free();
        const process = self.locker orelse {
            _ = std.c.close(pipe[0]);
            self.gate.fail();
            return error.LockFailed;
        };
        self.gate.ready = false;
        self.gate.failed = false;
        self.gate.requesting = true;
        self.lock_fd = pipe[0];
        self.lock_source = unix.fdAdd(pipe[0], .{ .in = true, .hup = true, .err = true }, lockReady, self);
        self.lock_deadline = glib.timeoutAdd(8000, lockExpired, self);
        self.app.hold();
        process.waitAsync(self.lock_cancel, lockerExited, self);
        self.changed(self.context);
    }
    fn lockerPath(_: *Lifecycle, alloc: std.mem.Allocator) ![:0]const u8 {
        if (@import("build_options").test_hooks) if (glib.getenv("PEARL_TEST_LOCKER")) |value| return alloc.dupeZ(u8, std.mem.span(value));
        var exe: [4096]u8 = undefined;
        const n = std.c.readlink("/proc/self/exe", &exe, exe.len);
        if (n > 0) {
            const candidate = try std.fmt.allocPrintSentinel(alloc, "{s}/pearl-lock", .{std.fs.path.dirname(exe[0..@intCast(n)]).?}, 0);
            if (std.c.access(candidate, std.c.X_OK) == 0) return candidate;
        }
        const path_value = glib.findProgramInPath("pearl-lock") orelse return error.LockerMissing;
        defer glib.free(path_value);
        return alloc.dupeZ(u8, std.mem.span(path_value));
    }
    fn syncLockState(self: *Lifecycle) void {
        self.gate.available = self.client.availability == .ready;
        self.gate.locked = self.gate.available and self.client.model.get(.session, "session").?.locked;
    }
    fn closeLockPipe(self: *Lifecycle) void {
        if (self.lock_source != 0) _ = glib.Source.remove(self.lock_source);
        if (self.lock_deadline != 0) _ = glib.Source.remove(self.lock_deadline);
        self.lock_source = 0;
        self.lock_deadline = 0;
        if (self.lock_fd >= 0) _ = std.c.close(self.lock_fd);
        self.lock_fd = -1;
    }
    fn lockReady(fd: c_int, _: glib.IOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Lifecycle = @ptrCast(@alignCast(data.?));
        var byte: [2]u8 = undefined;
        const n = std.c.read(fd, &byte, byte.len);
        if (n == 1 and byte[0] == 'L') {
            self.gate.ready = true;
            self.err = null;
        } else {
            self.gate.fail();
            self.err = "Lock acquisition failed; suspend cancelled.";
        }
        if (self.lock_source != 0) _ = glib.Source.remove(self.lock_source);
        self.lock_source = 0;
        if (self.lock_fd >= 0) _ = std.c.close(self.lock_fd);
        self.lock_fd = -1;
        self.sync();
        self.changed(self.context);
        return 0;
    }
    fn lockExpired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Lifecycle = @ptrCast(@alignCast(data.?));
        self.lock_deadline = 0;
        self.closeLockPipe();
        self.gate.fail();
        self.err = "Lock acquisition timed out; suspend cancelled.";
        self.changed(self.context);
        return 0;
    }
    fn lockerExited(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Lifecycle = @ptrCast(@alignCast(data.?));
        defer self.app.release();
        var err: ?*glib.Error = null;
        _ = object.ext.cast(gio.Subprocess, source.?).?.waitFinish(result, &err);
        if (err) |e| e.free();
        if (!self.running) return;
        self.closeLockPipe();
        if (self.locker) |p| p.unref();
        self.locker = null;
        self.gate.ready = false;
        self.gate.requesting = false;
        self.activity_token.cancel();
        self.gate.sleep_pending = false;
        self.syncLockState();
        if (self.gate.locked) {
            self.gate.failed = true;
            self.err = "Locker exited while Aqueous remains locked. Recovery requires the compositor's lock recovery procedure.";
        }
        self.rearm();
        self.changed(self.context);
    }
    fn advance(self: *Lifecycle) void {
        if (self.gate.acquired()) {
            self.gate.requesting = false;
            self.closeLockPipe();
        }
        if (self.gate.preparing and self.gate.acquired()) self.closeDelay();
        if (!self.gate.canSuspend() or self.action_busy or self.delay_fd < 0) return;
        if ((self.sleep_action == .@"suspend" and !self.can_suspend) or (self.sleep_action == .hibernate and !self.can_hibernate)) {
            self.gate.sleep_pending = false;
            return;
        }
        if (!self.sleep_checked_locked) {
            if (!self.query_busy) self.query(if (self.automatic_sleep) .sleep else .manual_sleep) catch {
                self.gate.sleep_pending = false;
            };
            return;
        }
        self.gate.sleep_pending = false;
        self.action_busy = true;
        self.call(6, if (self.sleep_action == .hibernate) "Hibernate" else "Suspend", db.tuple(&.{glib.Variant.newBoolean(1)}), "()") catch {
            self.action_busy = false;
            self.err = "Suspend unavailable.";
        };
    }
    pub fn act(self: *Lifecycle, command: []const u8, generation: ?u64) !void {
        self.sync();
        if (std.mem.eql(u8, command, "lock")) return self.lockNow();
        if (std.mem.eql(u8, command, "cancel")) {
            self.cancelConfirmation();
            self.gate.sleep_pending = false;
            self.changed(self.context);
            return;
        }
        if (std.mem.eql(u8, command, "inhibit") or std.mem.eql(u8, command, "uninhibit")) {
            self.idle_held = std.mem.eql(u8, command, "inhibit");
            self.gate.sleep_pending = false;
            self.rearm();
            self.changed(self.context);
            return;
        }
        if (!self.gate.available or !self.gate.active or self.gate.preparing) return error.Unavailable;
        if (std.mem.eql(u8, command, "confirm")) {
            if (generation == null or generation.? != self.confirmation) return error.StaleConfirmation;
            const action = self.pending orelse return error.NoConfirmation;
            self.cancelConfirmation();
            if (action == .logout) {
                try @import("../aqueous/commands.zig").validate(.session_exit, &self.client.model, self.client.capabilities);
                self.request_logout(self.context);
            } else {
                if (self.delay_fd < 0) return error.InhibitorUnavailable;
                self.sleep_action = action;
                try self.query(.manual_sleep);
            }
        } else {
            const action = std.meta.stringToEnum(Action, command) orelse return error.InvalidValue;
            if (action == .logout and (!self.client.capabilities.commands or self.gate.locked)) return error.Unsupported;
            if (action != .logout and !self.lock_supported) return error.Unsupported;
            if ((action == .@"suspend" and !self.can_suspend) or (action == .hibernate and !self.can_hibernate)) return error.Unsupported;
            self.cancelConfirmation();
            self.confirmation += 1;
            self.pending = action;
            self.confirmation_timer = glib.timeoutAddSeconds(20, confirmationExpired, self);
        }
        self.changed(self.context);
    }
    fn cancelConfirmation(self: *Lifecycle) void {
        self.pending = null;
        if (self.confirmation_timer != 0) _ = glib.Source.remove(self.confirmation_timer);
        self.confirmation_timer = 0;
    }
    fn confirmationExpired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Lifecycle = @ptrCast(@alignCast(data.?));
        self.confirmation_timer = 0;
        self.pending = null;
        self.changed(self.context);
        return 0;
    }
    pub fn status(self: *Lifecycle, alloc: std.mem.Allocator, auth: *@import("polkit.zig").Agent) ![]const u8 {
        return std.json.Stringify.valueAlloc(alloc, .{ .locker_pid = if (self.locker) |process| process.getIdentifier() else null, .authentication = .{ .registered = auth.registered, .pending = auth.request != null, .identities = auth.identity_count, .waiting = auth.waiting, .err = auth.err }, .available = self.gate.available, .active = self.gate.active, .session_id = self.session_id.slice(), .session_source = if (self.session_id.len != 0) @tagName(self.session_source) else null, .session_error = if (self.session_error.len != 0) self.session_error.slice() else null, .lock = self.gate, .idle_available = self.idle.notifier != null and self.idle.seat != null, .idle_held = self.idle_held, .on_battery = self.on_battery, .policy = if (self.on_battery) self.config.battery else self.config.ac, .can_lock = self.lock_supported, .can_logout = self.gate.available and self.gate.active and !self.gate.locked and self.client.capabilities.commands, .can_suspend = self.can_suspend and self.delay_fd >= 0 and self.lock_supported, .can_hibernate = self.can_hibernate and self.delay_fd >= 0 and self.lock_supported, .delay_inhibitor = self.delay_fd >= 0, .pending = self.pending, .confirmation = self.confirmation, .busy = self.action_busy or self.query_busy, .err = self.err }, .{});
    }
};
fn narrow(value: db.Text(512)) db.Text(128) {
    var out: db.Text(128) = .{};
    if (value.len <= 128) out.set(value.slice());
    return out;
}
