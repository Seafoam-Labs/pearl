//! Shell-owned scheduler control. Workers own their data; GTK only observes results.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const ownership = @import("view_ownership.zig");
const m = @import("sched_ext_model.zig");
const helper = @import("../config/helper_process.zig");
const a = std.heap.c_allocator;
pub const Action = m.Action;
pub const Service = struct {
    app: *gio.Application,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    interest: ownership.Interest = .{},
    arena: std.heap.ArenaAllocator = .init(a),
    state: m.Snapshot = .{},
    generation: u64 = 1,
    job: ?*Job = null,
    poll_source: c_uint = 0,
    err: ?[]const u8 = null,
    ticks: u8 = 0,
    stopped: bool = false,
    pub fn acquireView(self: *Service) !ownership.Owner {
        if (self.stopped) return error.Unavailable;
        const owner = try self.interest.acquire();
        if (self.poll_source == 0) self.poll_source = glib.timeoutAdd(3000, poll, self);
        if (self.job == null) self.launch(.refresh, null, null, null) catch {};
        return owner;
    }
    pub fn releaseView(self: *Service, owner: ownership.Owner) void {
        _ = self.interest.release(owner);
        if (self.job) |job| if (job.owner == owner) job.cancel.cancel();
        if (self.interest.count() == 0) {
            if (self.poll_source != 0) _ = glib.Source.remove(self.poll_source);
            self.poll_source = 0;
            if (self.job) |job| job.cancel.cancel();
        }
    }
    pub fn revokeViews(self: *Service) void {
        self.interest.revoke();
        if (self.poll_source != 0) _ = glib.Source.remove(self.poll_source);
        self.poll_source = 0;
        if (self.job) |job| job.cancel.cancel();
        self.state.available = false;
        self.state.can_stop = false;
        self.generation +|= 1;
    }
    pub fn stop(self: *Service) void {
        self.stopped = true;
        self.revokeViews();
        if (self.job) |job| job.service = null;
        self.job = null;
        self.arena.deinit();
    }
    pub fn snapshot(self: *Service, alloc: std.mem.Allocator) !m.Snapshot {
        var result = self.state;
        result.generation = try std.fmt.allocPrint(alloc, "{d}", .{self.generation});
        result.pending = self.job != null;
        return result;
    }
    pub fn act(self: *Service, owner: ownership.Owner, generation: u64, action: Action, scheduler: ?[]const u8, mode: ?m.Mode) !void {
        if (!self.interest.contains(owner) or self.stopped) return error.Unavailable;
        if (self.job != null) return error.Busy;
        if (generation != self.generation) return error.Stale;
        if (action == .apply) {
            if (!self.state.available) return error.Unavailable;
            const s = self.state.catalog.find(scheduler orelse return error.InvalidRequest) orelse return error.InvalidScheduler;
            if (!s.installed or s.arguments(mode orelse return error.InvalidRequest) == null) return error.Unavailable;
        } else {
            if (scheduler != null or mode != null) return error.InvalidRequest;
            if (action == .stop and !self.state.can_stop) return error.Unavailable;
        }
        try self.launch(action, owner, scheduler, mode);
    }
    fn launch(self: *Service, action: Action, owner: ?ownership.Owner, scheduler: ?[]const u8, mode: ?m.Mode) !void {
        if (self.job != null) return error.Busy;
        const job = try a.create(Job);
        job.* = .{ .service = self, .app = self.app, .action = action, .owner = owner, .mode = mode, .cancel = gio.Cancellable.new() };
        errdefer job.destroy();
        const alloc = job.arena.allocator();
        if (scheduler) |name| job.scheduler = try alloc.dupeZ(u8, name);
        job.previous = try std.json.Stringify.valueAlloc(alloc, self.state.catalog, .{});
        job.expected_runtime = try std.json.Stringify.valueAlloc(alloc, .{ .status = self.state.status, .kernel = self.state.kernel }, .{});
        if (action == .refresh and owner == null) job.previous_feedback = try alloc.dupe(u8, self.state.feedback);
        job.catalog_only_status = action == .refresh and owner == null and self.ticks % 10 != 0 and self.state.available;
        if (@import("build_options").test_hooks) {
            if (glib.getenv("PEARL_TEST_SCX_ROOT")) |root| job.test_root = try alloc.dupeZ(u8, std.mem.span(root));
        }
        self.err = null;
        self.job = job;
        job.app.hold();
        const task = gio.Task.new(null, job.cancel, done, job);
        task.setCheckCancellable(0);
        _ = task.setReturnOnCancel(0);
        task.setTaskData(job, null);
        task.runInThread(work);
        task.unref();
        self.changed(self.context);
    }
    fn poll(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data.?));
        self.ticks +%= 1;
        if (self.job == null) self.launch(.refresh, null, null, null) catch {};
        return 1;
    }
};
const Job = struct {
    service: ?*Service,
    app: *gio.Application,
    arena: std.heap.ArenaAllocator = .init(a),
    cancel: *gio.Cancellable,
    owner: ?ownership.Owner = null,
    action: Action,
    scheduler: ?[:0]const u8 = null,
    mode: ?m.Mode = null,
    previous: []const u8 = "",
    expected_runtime: []const u8 = "",
    previous_feedback: []const u8 = "",
    catalog_only_status: bool = false,
    test_root: ?[:0]const u8 = null,
    result: m.Snapshot = .{},
    failure: ?anyerror = null,
    diagnostic: []const u8 = "",
    fn destroy(self: *Job) void {
        self.cancel.unref();
        self.arena.deinit();
        a.destroy(self);
    }
    fn executable(self: *Job, name: [:0]const u8) !?[:0]const u8 {
        const alloc = self.arena.allocator();
        if (self.test_root) |root| {
            const path = try std.fmt.allocPrintSentinel(alloc, "{s}/bin/{s}", .{ root, name }, 0);
            return if (glib.fileTest(path, .{ .is_regular = true }) != 0 and glib.fileTest(path, .{ .is_executable = true }) != 0) path else null;
        }
        const path = glib.findProgramInPath(name) orelse return null;
        defer glib.free(path);
        return try alloc.dupeZ(u8, std.mem.span(path));
    }
    fn run(self: *Job, argv: []const [:0]const u8, timeout: i64) !helper.Result {
        if (self.cancel.isCancelled() != 0) return error.Cancelled;
        return helper.runConfigured(self.arena.allocator(), argv, null, self.cancel, timeout, null, .{ .stdout_limit = m.max_bytes, .stderr_limit = 8192, .plain_output = true });
    }
    fn kernel(self: *Job) !m.Kernel {
        const path = if (self.test_root) |root| try std.fmt.allocPrintSentinel(self.arena.allocator(), "{s}/kernel-state", .{root}, 0) else "/sys/kernel/sched_ext/state";
        const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, @as(c_uint, 0));
        if (fd < 0) return .unavailable;
        defer _ = std.c.close(fd);
        var buffer: [64]u8 = undefined;
        const n = std.c.read(fd, &buffer, buffer.len);
        if (n <= 0 or n == buffer.len) return .unknown;
        const text = std.mem.trim(u8, buffer[0..@intCast(n)], "\r\n ");
        return std.meta.stringToEnum(m.Kernel, text) orelse .unknown;
    }
    fn observe(self: *Job, ctl: [:0]const u8) !void {
        self.result.status = .{};
        const result = try self.run(&.{ ctl, "get" }, 2500);
        if (!result.success) {
            self.diagnostic = result.stderr;
            return error.StatusUnavailable;
        }
        self.result.status = try m.parseStatus(self.arena.allocator(), result.stdout, self.result.catalog);
        self.result.kernel = try self.kernel();
    }
    fn execute(self: *Job) !void {
        const alloc = self.arena.allocator();
        const ctl = (try self.executable("scxctl")) orelse return error.ScxctlMissing;
        if (self.catalog_only_status) {
            self.result.catalog = try std.json.parseFromSliceLeaky(m.Catalog, alloc, self.previous, .{});
        } else {
            const config = try self.run(&.{ ctl, "config", "--json" }, 3000);
            if (!config.success) {
                self.diagnostic = config.stderr;
                return error.ConfigUnavailable;
            }
            self.result.catalog = try m.parseCatalog(alloc, config.stdout);
            for (self.result.catalog.schedulers) |*s| s.installed = (try self.executable(try alloc.dupeZ(u8, s.name))) != null;
        }
        try self.observe(ctl);
        if (self.action == .refresh) {
            self.result.feedback = self.previous_feedback;
            return;
        }
        const current = try std.json.Stringify.valueAlloc(alloc, self.result.catalog, .{});
        if (!std.mem.eql(u8, self.previous, current)) return error.ConfigurationChanged;
        const runtime = try std.json.Stringify.valueAlloc(alloc, .{ .status = self.result.status, .kernel = self.result.kernel }, .{});
        if (!std.mem.eql(u8, self.expected_runtime, runtime)) return error.StateChanged;
        if (!m.consistent(self.result.status, self.result.kernel)) return error.StateMismatch;
        var result: helper.Result = undefined;
        if (self.action == .stop) {
            if (self.result.status.kind != .running) return error.StateChanged;
            result = self.run(&.{ ctl, "stop" }, 5000) catch |err| {
                self.observe(ctl) catch {};
                return err;
            };
        } else {
            const scheduler = self.result.catalog.find(self.scheduler.?) orelse return error.InvalidScheduler;
            if (!scheduler.installed or scheduler.arguments(self.mode.?) == null) return error.SchedulerMissing;
            result = self.run(&.{ ctl, try m.command(self.result.status, self.result.kernel), "--sched", self.scheduler.?, "--mode", @tagName(self.mode.?) }, 5000) catch |err| {
                self.observe(ctl) catch {};
                return err;
            };
        }
        self.diagnostic = result.stderr;
        // A successful D-Bus method can precede attachment. Reconcile for at most
        // three seconds; a failed command still needs one fresh observation.
        const deadline = glib.getMonotonicTime() + 3000000;
        while (true) {
            try self.observe(ctl);
            if (!result.success) return error.CommandFailed;
            const matched = if (self.action == .stop) self.result.status.kind == .stopped and self.result.kernel == .disabled else m.matches(self.result.status, self.result.kernel, self.result.catalog.find(self.scheduler.?).?, self.mode.?);
            if (matched) {
                self.result.feedback = if (result.stderr.len > 0) try clean(alloc, result.stderr) else "Scheduler change observed.";
                return;
            }
            if (glib.getMonotonicTime() >= deadline) return error.OutcomeUnconfirmed;
            var wait_fds: [0]std.c.pollfd = .{};
            _ = std.c.poll(&wait_fds, 0, 150);
        }
    }
};
fn work(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data.?));
    job.execute() catch |err| {
        job.failure = err;
    };
    job.result.available = m.consistent(job.result.status, job.result.kernel);
    job.result.can_stop = job.result.available and job.result.status.kind == .running;
    var installed = false;
    for (job.result.catalog.schedulers) |s| if (s.installed) {
        installed = true;
        break;
    };
    job.result.available = job.result.available and installed;
    job.result.summary = if (job.result.kernel == .unavailable) "Kernel sched-ext support is unavailable." else if (!m.consistent(job.result.status, job.result.kernel)) "Scheduler status is unknown or disagrees with the kernel. Refresh before applying." else if (!installed) "No scheduler binaries were found. Install a supported scheduler, then refresh." else "Scheduler service available";
    if (job.failure) |err| {
        const message = switch (err) {
            error.ScxctlMissing => "scxctl was not found. Install scxctl and a scheduler, then refresh.",
            error.ConfigUnavailable => "Cannot read scheduler configuration. Check scx_loader access and support for scxctl config --json.",
            error.StateChanged => "The running scheduler changed elsewhere. Review current status before applying again.",
            error.ConfigurationChanged => "Scheduler configuration changed. Review the refreshed arguments and apply again.",
            error.HelperTimedOut => "scxctl timed out. Refresh to check the current scheduler before retrying.",
            error.Cancelled => "Scheduler request cancelled. Refresh to check the current scheduler.",
            error.OutcomeUnconfirmed => "The requested scheduler state could not be confirmed. Review current status before retrying.",
            else => "Scheduler request failed. Review current status and refresh before retrying.",
        };
        job.result.summary = std.fmt.allocPrint(job.arena.allocator(), "{s} ({s}){s}{s}", .{ message, @errorName(err), if (job.diagnostic.len > 0) "\n" else "", clean(job.arena.allocator(), job.diagnostic) catch "" }) catch message;
        if (job.action != .refresh) job.result.feedback = job.result.summary;
        if (job.action == .refresh or err == error.Cancelled) {
            job.result.available = false;
            job.result.can_stop = false;
        }
    }
    task.returnBoolean(1);
}
fn done(_: ?*object.Object, _: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data.?));
    if (job.service) |self| {
        self.job = null;
        self.arena.deinit();
        self.arena = job.arena;
        job.arena = .init(a);
        self.state = job.result;
        if (!self.interest.enabled or self.interest.count() == 0) {
            self.state.available = false;
            self.state.can_stop = false;
        }
        self.generation +|= 1;
        self.err = if (job.failure != null) self.state.summary else null;
        self.changed(self.context);
    }
    job.app.release();
    job.destroy();
}
fn clean(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    const result = try alloc.dupe(u8, text[0..@min(text.len, 1024)]);
    for (result) |*c| if (c.* < 32 and c.* != '\n' and c.* != '\t') {
        c.* = ' ';
    };
    if (!std.unicode.utf8ValidateSlice(result)) return "Invalid command diagnostic";
    return std.mem.trim(u8, result, " \r\n\t");
}
