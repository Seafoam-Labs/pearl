//! Bounded, non-interactive command capture, not a shell, PTY, LSP transport,
//! sandbox, or process-tree supervisor. Only the direct child is killed/reaped.
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
//! GLib's spawn handshake and an uninterruptible kernel wait cannot be aborted.
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

pub const Identity = struct {
    scope: []const u8,
    request: u64,
    generation: u64,
};
pub const Environment = struct { name: []const u8, value: []const u8 };
pub const Config = struct {
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
pub const StartError = std.mem.Allocator.Error || error{ Unauthorized, InvalidConfig };

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
    process: ?*c.GSubprocess = null,
    // Written only by the spawn worker; read only after its GTask completes.
    spawned: ?*c.GSubprocess = null,
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

    /// Immediate hard cancellation, not graceful SIGTERM. The first observed
    /// stop reason wins. Cancellation never cancels the child wait/reap.
    /// May race with spawn: a child created in that race is killed on handoff.
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
        if (self.process) |p| c.g_object_unref(p);
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
        if (self.process) |p| if (!self.reaped) c.g_subprocess_force_exit(p);
    }

    fn rememberError(self: *Job, err: ?*c.GError) void {
        if (err) |e| {
            if (self.failure == null) self.failure = e else c.g_error_free(e);
        }
    }

    fn finish(self: *Job) void {
        if (self.completed or !self.wait_done or !self.out.done or !self.err.done) return;
        self.completed = true;
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
/// Synchronous work is bounded validation/copying only. GSubprocess's blocking
/// spawn handshake runs in GTask's worker pool, never on the main loop. No stdin
/// pipe is requested, so GSubprocess supplies /dev/null. Concurrent job count is
/// the caller's responsibility; there is no global queue or admission policy.
pub fn start(allocator: std.mem.Allocator, config: Config, callback: Completion, callback_data: ?*anyopaque) StartError!*Job {
    if (config.authorization != .approved) return error.Unauthorized;
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
        .identity = .{ .scope = scope, .request = config.identity.request, .generation = config.identity.generation },
        .argv = argv,
        .cwd = cwd,
        .environment = environment,
        .storage = storage,
        .context = c.g_main_context_ref_thread_default().?,
        .io_cancel = c.g_cancellable_new().?,
        .callback = callback,
        .callback_data = callback_data,
    };
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
        const launcher = c.g_subprocess_launcher_new(c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_PIPE).?;
        defer c.g_object_unref(launcher);
        c.g_subprocess_launcher_set_cwd(launcher, self.cwd);
        c.g_subprocess_launcher_set_environ(launcher, @ptrCast(self.environment.ptr));
        self.spawned = c.g_subprocess_launcher_spawnv(launcher, @ptrCast(self.argv.ptr), &self.spawn_error);
    }
    c.g_task_return_boolean(task, 1);
}

fn spawnReady(_: ?*c.GObject, res: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Job, data.?);
    _ = c.g_task_propagate_boolean(u.cast(c.GTask, res.?), null);
    self.process = self.spawned;
    self.rememberError(self.spawn_error);
    self.spawn_error = null;
    const p = self.process orelse {
        if (self.stop_reason == null) self.stop_reason = .spawn_failed;
        self.wait_done = true;
        self.out.done = true;
        self.err.done = true;
        self.finish();
        return;
    };
    self.out.stream = c.g_subprocess_get_stdout_pipe(p).?;
    self.err.stream = c.g_subprocess_get_stderr_pipe(p).?;
    if (self.stop_reason != null) c.g_subprocess_force_exit(p);
    self.out.read();
    self.err.read();
    c.g_main_context_push_thread_default(self.context);
    defer c.g_main_context_pop_thread_default(self.context);
    c.g_subprocess_wait_async(p, null, waitReady, self);
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

fn waitReady(_: ?*c.GObject, res: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Job, data.?);
    var err: ?*c.GError = null;
    self.reaped = c.g_subprocess_wait_finish(self.process, res, &err) != 0;
    if (!self.reaped) {
        self.rememberError(err);
        self.stop(.io_failed);
    } else if (c.g_subprocess_get_if_exited(self.process) != 0) {
        self.exit_code = c.g_subprocess_get_exit_status(self.process);
    } else if (c.g_subprocess_get_if_signaled(self.process) != 0) {
        self.term_signal = c.g_subprocess_get_term_sig(self.process);
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
