//! Bounded command capture with owned Linux process-group lifecycle.
//! Ordinary descendants (including shell background children) are terminated
//! and reaped before completion, even when the command leader exits first.
//! Deliberate setsid/setpgid escape is not contained: this is NOT a sandbox.
//! See ../terminal/ownership.zig for the PID pinning and private reaper boundary.
//!
//! Call start/cancel/destroy on the submitting main-context thread. Keep that
//! context running until completion (including during shutdown). start copies
//! all request data; the caller must keep callback_data alive until completion.
//! Completion is asynchronous and exactly once for each successful start.
//! A start error creates no job and schedules no callback. The callback may
//! destroy the job; otherwise its result stays valid until destroy. Treat Job
//! fields as private; use only its methods while it is pending.
//!
//! Deadlines request termination, not a hard wall-clock completion guarantee:
//! The exec handshake and an uninterruptible kernel wait cannot be aborted.
//! Neither runs on the main loop. A stopped job discards unread output and
//! closes both pipes rather than waiting on descendants holding them open.
//!
//! Authorization is the caller's trust decision for this exact configuration.
//! Environment entries are the complete allowlist of name/value pairs passed
//! to the child: nothing is inherited, not even PATH, HOME or agent sockets.
//! The caller must vet executable, arguments, cwd and environment (including
//! loader variables and tool-specific hooks/config). This is NOT OS isolation.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const ownership = @import("../terminal/ownership.zig");
const os = ownership.os;
extern fn g_unix_input_stream_new(c_int, c_int) *c.GInputStream;

pub const Identity = struct {
    scope: []const u8,
    request: u64,
    generation: u64,
    /// Optional routing token, independent of the descriptive scope string.
    /// Echoed unchanged; callers reject stale results but must still reap/destroy.
    workspace: ?@import("../workspace/identity.zig").Token = null,
};
pub const Environment = struct { name: []const u8, value: []const u8 };
/// Stack- or heap-owned lifetime scope, confined to the submitting context
/// thread. shutdown cancels every pending job and rejects new submissions.
/// Keep this owner AND the main context alive until isIdle; callbacks may
/// destroy jobs. This does not own completed Job result storage.
pub const Supervisor = struct {
    head: ?*Job = null,
    closing: bool = false,

    pub fn shutdown(self: *Supervisor) void {
        self.closing = true;
        var next = self.head;
        while (next) |job| {
            next = job.owner_next;
            job.cancel();
        }
    }

    pub fn isIdle(self: *const Supervisor) bool {
        return self.head == null;
    }
};

pub const Config = struct {
    owner: ?*Supervisor = null,
    authorization: enum { denied, approved } = .denied,
    identity: Identity,
    /// argv[0] and cwd must be absolute. No PATH lookup or shell expansion.
    argv: []const []const u8,
    cwd: []const u8,
    environment: []const Environment = &.{},
    /// Combined stdout/stderr bytes. Exactly this much capture storage is
    /// allocated up front, plus two fixed 8 KiB read buffers. Valid: 0..16 MiB.
    output_limit: usize = 1024 * 1024,
    /// Includes spawn, exit and pipe draining; must be nonzero.
    timeout_ms: u32 = 30_000,
};
pub const Outcome = enum { success, nonzero, signaled, spawn_failed, cancelled, timed_out, output_limit, io_failed };
pub const Result = struct {
    identity: Identity,
    outcome: Outcome,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: ?c_int,
    term_signal: ?c_int,
    reaped: bool,
    /// Borrowed diagnostic, empty when no GLib error was reported. Do not log
    /// command output/diagnostics without appropriate redaction at the caller.
    error_message: []const u8,
};
pub const Completion = *const fn (*Job, Result, ?*anyopaque) void;
pub const StartError = std.mem.Allocator.Error || error{ Unauthorized, InvalidConfig, ShuttingDown };

pub const Job = struct {
    allocator: std.mem.Allocator,
    identity: Identity,
    argv: [:null]?[*:0]const u8,
    cwd: [:0]u8,
    environment: [:null]?[*:0]const u8,
    storage: []u8,
    stdout_len: usize = 0,
    stderr_len: usize = 0,
    context: *c.GMainContext,
    deadline: ?*c.GSource = null,
    io_cancel: *c.GCancellable,
    process: ?ownership.Owner = null,
    owner: ?*Supervisor = null,
    owner_next: ?*Job = null,
    // Written only by workers; read only after their GTask completes.
    spawned: ?ownership.Owner = null,
    spawned_out: c_int = -1,
    spawned_err: c_int = -1,
    report: ownership.Report = .{},
    spawn_error: ?*c.GError = null,
    failure: ?*c.GError = null,
    stop_reason: ?Outcome = null,
    wait_done: bool = false,
    reaped: bool = false,
    completed: bool = false,
    exit_code: ?c_int = null,
    term_signal: ?c_int = null,
    out: Pipe = undefined,
    err: Pipe = undefined,
    callback: Completion,
    callback_data: ?*anyopaque,

    /// TERM followed by KILL after a 150ms grace, including descendants.
    /// The first observed stop reason wins; wait/reap is never cancelled.
    /// May race with spawn: the ownership channel is closed on handoff.
    pub fn cancel(self: *Job) void {
        self.stop(.cancelled);
    }

    pub fn isComplete(self: *const Job) bool {
        return self.completed;
    }

    pub fn result(self: *const Job) Result {
        std.debug.assert(self.completed);
        return .{
            .identity = self.identity,
            .outcome = self.stop_reason orelse if (self.term_signal != null) .signaled else if (self.exit_code == 0) .success else .nonzero,
            .stdout = self.storage[0..self.stdout_len],
            .stderr = self.storage[self.storage.len - self.stderr_len ..],
            .exit_code = self.exit_code,
            .term_signal = self.term_signal,
            .reaped = self.reaped,
            .error_message = if (self.failure) |err| std.mem.span(err.message) else "",
        };
    }

    /// Only after completion, including from inside the callback. Never free
    /// a pending job: cancel it and continue iterating its context instead.
    pub fn destroy(self: *Job) void {
        std.debug.assert(self.completed);
        if (self.process) |*p| p.deinit();
        if (self.out.stream) |stream| c.g_object_unref(stream);
        if (self.err.stream) |stream| c.g_object_unref(stream);
        if (self.failure) |err| c.g_error_free(err);
        c.g_object_unref(self.io_cancel);
        c.g_main_context_unref(self.context);
        freeVector(self.allocator, self.argv);
        freeVector(self.allocator, self.environment);
        self.allocator.free(self.identity.scope);
        self.allocator.free(self.cwd);
        self.allocator.free(self.storage);
        self.allocator.destroy(self);
    }

    fn stop(self: *Job, reason: Outcome) void {
        if (self.completed or self.stop_reason != null) return;
        self.stop_reason = reason;
        c.g_cancellable_cancel(self.io_cancel);
        if (self.process) |*p| p.cancel();
    }

    fn rememberError(self: *Job, err: ?*c.GError) void {
        if (err) |e| {
            if (self.failure == null) self.failure = e else c.g_error_free(e);
        }
    }

    fn finish(self: *Job) void {
        if (self.completed or !self.wait_done or !self.out.done or !self.err.done) return;
        self.completed = true;
        if (self.owner) |owner| {
            var link = &owner.head;
            while (link.*) |job| {
                if (job == self) {
                    link.* = self.owner_next;
                    break;
                }
                link = &job.owner_next;
            }
            self.owner = null;
        }
        if (self.deadline) |source| {
            c.g_source_destroy(source);
            c.g_source_unref(source);
            self.deadline = null;
        }
        // stderr grows backwards in the shared budget, so neither stream can
        // reserve space the other needs. Reverse once to restore byte order.
        std.mem.reverse(u8, self.storage[self.storage.len - self.stderr_len ..]);
        self.callback(self, self.result(), self.callback_data);
        // The callback is allowed to destroy self.
    }
};

const Pipe = struct {
    job: *Job,
    stream: ?*c.GInputStream = null,
    stderr: bool,
    done: bool = false,
    buffer: [8192]u8 = undefined,

    fn read(self: *Pipe) void {
        c.g_main_context_push_thread_default(self.job.context);
        defer c.g_main_context_pop_thread_default(self.job.context);
        c.g_input_stream_read_async(self.stream, &self.buffer, self.buffer.len, c.G_PRIORITY_DEFAULT, self.job.io_cancel, readReady, self);
    }

    fn close(self: *Pipe) void {
        // Do not wait for EOF after stopping: a descendant may still own the
        // write end. Close only after the outstanding read has finished.
        c.g_main_context_push_thread_default(self.job.context);
        defer c.g_main_context_pop_thread_default(self.job.context);
        c.g_input_stream_close_async(self.stream, c.G_PRIORITY_DEFAULT, null, closeReady, self);
    }
};

/// Requests are limited to 4096 argv elements, 4096 environment entries and
/// 1 MiB of combined request strings (including their terminators).
/// Synchronous work is bounded validation/copying only. Fork/exec and reaping
/// run in GTask's worker pool, never on the main loop. Stdin is /dev/null.
/// Concurrent job count is
/// the caller's responsibility; there is no global queue or admission policy.
pub fn start(allocator: std.mem.Allocator, config: Config, callback: Completion, callback_data: ?*anyopaque) StartError!*Job {
    if (config.authorization != .approved) return error.Unauthorized;
    if (config.owner) |owner| if (owner.closing) return error.ShuttingDown;
    try validate(config);
    const self = try allocator.create(Job);
    errdefer allocator.destroy(self);
    const scope = try allocator.dupe(u8, config.identity.scope);
    errdefer allocator.free(scope);
    const cwd = try allocator.dupeSentinel(u8, config.cwd, 0);
    errdefer allocator.free(cwd);
    const argv = try allocator.allocSentinel(?[*:0]const u8, config.argv.len, null);
    @memset(argv, null);
    errdefer freeVector(allocator, argv);
    for (config.argv, 0..) |arg, i| argv[i] = (try allocator.dupeSentinel(u8, arg, 0)).ptr;
    const environment = try allocator.allocSentinel(?[*:0]const u8, config.environment.len, null);
    @memset(environment, null);
    errdefer freeVector(allocator, environment);
    for (config.environment, 0..) |entry, i| environment[i] = (try std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ entry.name, entry.value }, 0)).ptr;
    const storage = try allocator.alloc(u8, config.output_limit);
    self.* = .{
        .allocator = allocator,
        .identity = .{ .scope = scope, .request = config.identity.request, .generation = config.identity.generation, .workspace = config.identity.workspace },
        .argv = argv,
        .cwd = cwd,
        .environment = environment,
        .storage = storage,
        .context = c.g_main_context_ref_thread_default().?,
        .io_cancel = c.g_cancellable_new().?,
        .callback = callback,
        .callback_data = callback_data,
    };
    if (config.owner) |owner| {
        self.owner = owner;
        self.owner_next = owner.head;
        owner.head = self;
    }
    self.out = .{ .job = self, .stderr = false };
    self.err = .{ .job = self, .stderr = true };
    self.deadline = c.g_timeout_source_new(config.timeout_ms).?;
    c.g_source_set_callback(self.deadline, expired, self, null);
    _ = c.g_source_attach(self.deadline, self.context);
    // No GTask cancellable: its callback must always receive the spawn result,
    // even if cancellation arrives while the worker is in the spawn handshake.
    const task = c.g_task_new(null, null, spawnReady, self).?;
    c.g_task_set_task_data(task, self, null);
    c.g_task_run_in_thread(task, spawnWorker);
    c.g_object_unref(task);
    return self;
}

fn freeVector(allocator: std.mem.Allocator, vector: [:null]?[*:0]const u8) void {
    for (vector) |entry| if (entry) |s| allocator.free(std.mem.span(s));
    allocator.free(vector);
}

fn validate(config: Config) StartError!void {
    if (config.argv.len == 0 or config.argv.len > 4096 or config.environment.len > 4096 or
        config.cwd.len == 0 or config.cwd[0] != '/' or config.argv[0].len == 0 or config.argv[0][0] != '/' or
        config.timeout_ms == 0 or config.output_limit > 16 * 1024 * 1024) return error.InvalidConfig;
    var budget: usize = 1024 * 1024;
    try charge(&budget, config.identity.scope);
    try charge(&budget, config.cwd);
    for (config.argv) |arg| try charge(&budget, arg);
    for (config.environment, 0..) |entry, i| {
        try charge(&budget, entry.name);
        try charge(&budget, entry.value);
        if (entry.name.len == 0 or std.mem.indexOfScalar(u8, entry.name, '=') != null) return error.InvalidConfig;
        for (config.environment[0..i]) |previous| {
            if (std.mem.eql(u8, entry.name, previous.name)) return error.InvalidConfig;
        }
    }
}

fn charge(budget: *usize, text: []const u8) StartError!void {
    if (text.len >= budget.* or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidConfig;
    budget.* -= text.len + 1;
}

fn spawnWorker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: ?*c.GCancellable) callconv(.c) void {
    const self = u.cast(Job, data.?);
    if (c.g_cancellable_is_cancelled(self.io_cancel) == 0) {
        spawn(self) catch {
            self.spawn_error = c.g_error_new_literal(c.g_io_error_quark(), os.errno(), "Unable to create owned process supervisor");
        };
    }
    c.g_task_return_boolean(task, 1);
}

fn spawn(self: *Job) !void {
    const input = os.open("/dev/null", os.CLOEXEC);
    if (input < 0) return error.SystemResources;
    defer _ = os.close(input);
    var out: [2]c_int = undefined;
    if (os.pipe2(&out, os.CLOEXEC) < 0) return error.SystemResources;
    defer _ = os.close(out[1]);
    errdefer _ = os.close(out[0]);
    var err: [2]c_int = undefined;
    if (os.pipe2(&err, os.CLOEXEC) < 0) return error.SystemResources;
    defer _ = os.close(err[1]);
    errdefer _ = os.close(err[0]);
    self.spawned = try ownership.start(.{
        .argv = self.argv.ptr,
        .environment = self.environment.ptr,
        .cwd = self.cwd,
        .stdin = input,
        .stdout = out[1],
        .stderr = err[1],
    });
    self.spawned_out = out[0];
    self.spawned_err = err[0];
}

fn spawnReady(_: ?*c.GObject, res: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Job, data.?);
    _ = c.g_task_propagate_boolean(u.cast(c.GTask, res.?), null);
    self.process = self.spawned;
    self.spawned = null; // transfer the live ownership handle to the context thread
    self.rememberError(self.spawn_error);
    self.spawn_error = null;
    if (self.process == null) {
        if (self.stop_reason == null) self.stop_reason = .spawn_failed;
        self.wait_done = true;
        self.out.done = true;
        self.err.done = true;
        self.finish();
        return;
    }
    self.out.stream = g_unix_input_stream_new(self.spawned_out, 1);
    self.err.stream = g_unix_input_stream_new(self.spawned_err, 1);
    if (self.stop_reason != null) self.process.?.cancel();
    self.out.read();
    self.err.read();
    c.g_main_context_push_thread_default(self.context);
    defer c.g_main_context_pop_thread_default(self.context);
    const task = c.g_task_new(null, null, waitReady, self).?;
    c.g_task_set_task_data(task, self, null);
    c.g_task_run_in_thread(task, waitWorker);
    c.g_object_unref(task);
}

fn readReady(_: ?*c.GObject, res: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const pipe = u.cast(Pipe, data.?);
    const self = pipe.job;
    var err: ?*c.GError = null;
    const n = c.g_input_stream_read_finish(pipe.stream, res, &err);
    if (n < 0) {
        if (self.stop_reason == null) {
            self.rememberError(err);
            self.stop(.io_failed);
        } else if (err) |e| c.g_error_free(e);
    } else if (n > 0 and self.stop_reason == null) {
        const count: usize = @intCast(n);
        const keep = @min(count, self.storage.len - self.stdout_len - self.stderr_len);
        if (pipe.stderr) {
            const end = self.storage.len - self.stderr_len;
            @memcpy(self.storage[end - keep .. end], pipe.buffer[0..keep]);
            std.mem.reverse(u8, self.storage[end - keep .. end]);
            self.stderr_len += keep;
        } else {
            @memcpy(self.storage[self.stdout_len..][0..keep], pipe.buffer[0..keep]);
            self.stdout_len += keep;
        }
        if (keep < count) self.stop(.output_limit);
    }
    if (n <= 0 or self.stop_reason != null) pipe.close() else pipe.read();
}

fn closeReady(_: ?*c.GObject, res: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const pipe = u.cast(Pipe, data.?);
    const self = pipe.job;
    var err: ?*c.GError = null;
    if (c.g_input_stream_close_finish(pipe.stream, res, &err) == 0) {
        self.rememberError(err);
        self.stop(.io_failed);
    }
    pipe.done = true;
    self.finish();
}

fn waitWorker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: ?*c.GCancellable) callconv(.c) void {
    const self = u.cast(Job, data.?);
    self.report = self.process.?.wait();
    c.g_task_return_boolean(task, 1);
}

fn waitReady(_: ?*c.GObject, res: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Job, data.?);
    _ = c.g_task_propagate_boolean(u.cast(c.GTask, res.?), null);
    self.reaped = self.report.reaped != 0;
    if (self.report.spawn_errno != 0) {
        self.rememberError(c.g_error_new_literal(c.g_io_error_quark(), self.report.spawn_errno, "Owned command setup, exec or supervisor failed"));
        self.stop(.spawn_failed);
    } else if (self.report.status & 0x7f == 0) {
        self.exit_code = (self.report.status >> 8) & 0xff;
    } else {
        self.term_signal = self.report.status & 0x7f;
    }
    self.wait_done = true;
    self.finish();
}

fn expired(data: ?*anyopaque) callconv(.c) c_int {
    u.cast(Job, data.?).stop(.timed_out);
    return c.G_SOURCE_REMOVE;
}

test {
    _ = @import("process_test.zig");
}
