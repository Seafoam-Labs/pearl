//! Bounded interactive stdio for Linux, using terminal/ownership.zig's private
//! process-group supervisor. No shell, PATH lookup, inherited environment,
//! application callbacks, GLib dependency, or automatic restart.
//!
//! All public methods belong to ONE submitting thread (normally the GTK main
//! context). start pins the request and allocates fixed queues, then starts one
//! worker. The worker alone spawns, polls nonblocking parent pipe ends, cancels
//! the Owner and waits/reaps. It does not allocate through the caller allocator.
//! The worker thread detaches, NOT the child: its final release-store relinquishes
//! all access to Transport, after Owner.wait/deinit and descriptor cleanup.
//!
//! On each main-context tick, read into a reusable buffer with a bounded per-tick
//! work budget, then check result(). A non-null result is stable, not an event:
//! deliver the application's closed notification ONCE, remove the tick source,
//! and destroy. There are no worker-to-App callbacks. isComplete/result become
//! available only after queued stdout is consumed AND the worker has finished.
//! stop is idempotent and nonblocking, including during spawn/backpressure.
//! Keep polling and retain the Transport after stop; destroy requires completion.
//!
//! send copies the ENTIRE slice or returns Backpressure; retry only that unsent
//! slice later. MessageTooLarge means it can never fit. read returns raw bytes
//! (chunk boundaries have no framing significance); zero means nothing queued,
//! not EOF. isOutputClosed reports observed stdout EOF only after queued bytes
//! are consumed, independently of process exit. A client can then call stop to
//! terminate a server that closed stdout but stayed alive. Keep polling for
//! completion before destroy: EOF alone does not mean the group is reaped.
//! closeInput drains accepted writes before sending stdin EOF.
//!
//! A slow stdout consumer that exhausts the queue terminates with output_limit,
//! retaining the queued prefix. Subsequent stdout is discarded during cleanup.
//! stderr is drained independently, never stored/logged, and only a saturating
//! byte count plus a capped flag survives. Queue limits bound memory, not lifetime
//! traffic. Request strings total <=1 MiB; queues are powers of two <=16 MiB each;
//! worker staging is 4096 bytes. The std.Thread default stack (16 MiB on Zig
//! 0.17.1), caller read buffers and kernel pipes are outside the queue bound.
//!
//! timeout_ms is a total lifetime deadline from start (0 disables it). Deadlines
//! and stop are checked every worker iteration; poll waits are capped at 5ms,
//! independently of main-context ticks. Owner's 150ms TERM grace and reaping add latency;
//! kernel-uninterruptible spawn/children cannot have a hard completion deadline.
//! Owner's deliberate setsid/setpgid escape limitation also applies here. The
//! host must not ignore SIGCHLD, use SA_NOCLDWAIT, or reap this Owner's children.
//! Admission/concurrent transport count is the caller's responsibility.
const std = @import("std");
const ownership = @import("../terminal/ownership.zig");
const os = ownership.os;
const Atomic = std.atomic.Value;

pub const Environment = struct { name: []const u8, value: []const u8 };
pub const Config = struct {
    authorization: enum { denied, approved } = .denied,
    /// argv[0] is absolute; other arguments are literal, not necessarily paths.
    argv: []const []const u8,
    cwd: []const u8,
    /// The complete child environment allowlist. Nothing is inherited.
    environment: []const Environment = &.{},
    input_limit: usize = 64 * 1024,
    output_limit: usize = 256 * 1024,
    stderr_limit: usize = 64 * 1024,
    timeout_ms: u32 = 0,
};
pub const Outcome = enum { success, nonzero, signaled, spawn_failed, cancelled, timed_out, output_limit, io_failed };
pub const Stderr = struct {
    /// min(actual bytes drained, configured limit); no content is retained.
    bytes: usize = 0,
    capped: bool = false,
};
pub const Result = struct {
    outcome: Outcome = .spawn_failed,
    exit_code: ?u8 = null,
    term_signal: ?u8 = null,
    /// Owner's guarantee for a successfully execed command and its group.
    /// False if spawn was skipped/failed or the supervisor report was lost.
    reaped: bool = false,
    /// Numeric setup/exec error only; never contains server content.
    spawn_errno: c_int = 0,
    stderr: Stderr = .{},
    stdout_discarded: bool = false,
};
pub const StartError = std.mem.Allocator.Error || std.Thread.SpawnError || error{ Unauthorized, InvalidConfig };
pub const SendError = error{ Closed, MessageTooLarge, Backpressure };

/// Single producer/single consumer byte ring. Power-of-two capacity also makes
/// wrapping counters correct after usize overflow. Each side owns one cursor;
/// release/acquire publishes bytes and protects them from premature reuse.
const Ring = struct {
    bytes: []u8,
    head: Atomic(usize) = .init(0),
    tail: Atomic(usize) = .init(0),

    fn push(self: *Ring, bytes: []const u8) bool {
        const head = self.head.load(.monotonic);
        const used = head -% self.tail.load(.acquire);
        if (bytes.len > self.bytes.len - used) return false;
        const offset = head & (self.bytes.len - 1);
        const first = @min(bytes.len, self.bytes.len - offset);
        @memcpy(self.bytes[offset..][0..first], bytes[0..first]);
        @memcpy(self.bytes[0 .. bytes.len - first], bytes[first..]);
        self.head.store(head +% bytes.len, .release);
        return true;
    }

    fn peek(self: *Ring) []const u8 {
        const tail = self.tail.load(.monotonic);
        const used = self.head.load(.acquire) -% tail;
        const offset = tail & (self.bytes.len - 1);
        return self.bytes[offset..][0..@min(used, self.bytes.len - offset)];
    }

    fn consume(self: *Ring, count: usize) void {
        self.tail.store(self.tail.load(.monotonic) +% count, .release);
    }

    fn pop(self: *Ring, buffer: []u8) usize {
        const bytes = self.peek();
        const count = @min(bytes.len, buffer.len);
        @memcpy(buffer[0..count], bytes[0..count]);
        self.consume(count);
        return count;
    }
};

pub const Transport = struct {
    allocator: std.mem.Allocator,
    argv: [:null]?[*:0]const u8,
    cwd: [:0]u8,
    environment: [:null]?[*:0]const u8,
    input: Ring,
    output: Ring,
    stderr_limit: usize,
    deadline: ?i64,
    stopping: Atomic(bool) = .init(false),
    input_closed: Atomic(bool) = .init(false),
    output_eof: Atomic(bool) = .init(false),
    done: Atomic(bool) = .init(false),
    // Written only by worker; read only after acquiring done.
    final: Result = .{},

    pub fn send(self: *Transport, bytes: []const u8) SendError!void {
        if (self.stopping.load(.acquire) or self.input_closed.load(.acquire) or self.done.load(.acquire)) return error.Closed;
        if (bytes.len > self.input.bytes.len) return error.MessageTooLarge;
        if (!self.input.push(bytes)) return error.Backpressure;
    }

    /// A copy into caller-owned memory; no allocation, lock, wait or syscall.
    pub fn read(self: *Transport, buffer: []u8) usize {
        return self.output.pop(buffer);
    }

    /// Observed stdout EOF AND no queued stdout remains. Nonblocking, sticky
    /// once true, and independent of process completion. Call on the submitting
    /// thread, like read. This does not stop/reap the child or permit destroy.
    /// Errors/forced closure are not EOF; continue checking result separately.
    pub fn isOutputClosed(self: *Transport) bool {
        // Acquire EOF before inspecting the queue: the worker publishes EOF
        // after its final stdout push, so an earlier empty snapshot cannot hide
        // the last bytes. No further stdout pushes are possible after EOF.
        return self.output_eof.load(.acquire) and self.output.peek().len == 0;
    }

    pub fn closeInput(self: *Transport) void {
        self.input_closed.store(true, .release);
    }

    pub fn stop(self: *Transport) void {
        self.stopping.store(true, .release);
    }

    pub fn isComplete(self: *Transport) bool {
        return self.done.load(.acquire) and self.output.peek().len == 0;
    }

    pub fn result(self: *Transport) ?Result {
        if (!self.isComplete()) return null;
        return self.final;
    }

    /// No join/wait: worker has relinquished this allocation before completion.
    /// Must run on the submitting thread, after isComplete returns true.
    pub fn destroy(self: *Transport) void {
        std.debug.assert(self.isComplete());
        const allocator = self.allocator;
        freeVector(allocator, self.argv);
        freeVector(allocator, self.environment);
        allocator.free(self.cwd);
        allocator.free(self.input.bytes);
        allocator.free(self.output.bytes);
        allocator.destroy(self);
    }
};

pub fn start(allocator: std.mem.Allocator, config: Config) StartError!*Transport {
    if (config.authorization != .approved) return error.Unauthorized;
    const started_at = os.nowMs();
    try validate(config);
    const self = try allocator.create(Transport);
    errdefer allocator.destroy(self);
    const argv = try allocator.allocSentinel(?[*:0]const u8, config.argv.len, null);
    @memset(argv, null);
    errdefer freeVector(allocator, argv);
    for (config.argv, 0..) |arg, i| argv[i] = (try allocator.dupeSentinel(u8, arg, 0)).ptr;
    const cwd = try allocator.dupeSentinel(u8, config.cwd, 0);
    errdefer allocator.free(cwd);
    const environment = try allocator.allocSentinel(?[*:0]const u8, config.environment.len, null);
    @memset(environment, null);
    errdefer freeVector(allocator, environment);
    for (config.environment, 0..) |entry, i| environment[i] = (try std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ entry.name, entry.value }, 0)).ptr;
    const input = try allocator.alloc(u8, config.input_limit);
    errdefer allocator.free(input);
    const output = try allocator.alloc(u8, config.output_limit);
    errdefer allocator.free(output);
    self.* = .{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .environment = environment,
        .input = .{ .bytes = input },
        .output = .{ .bytes = output },
        .stderr_limit = config.stderr_limit,
        .deadline = if (config.timeout_ms == 0) null else started_at + config.timeout_ms,
    };
    // Keep the runtime default stack: libc rejects stacks smaller than the
    // application's static TLS block, which already exceeds 256 KiB in tests.
    const thread = try std.Thread.spawn(.{}, worker, .{self});
    thread.detach();
    return self;
}

fn freeVector(allocator: std.mem.Allocator, vector: [:null]?[*:0]const u8) void {
    for (vector) |entry| if (entry) |text| allocator.free(std.mem.span(text));
    allocator.free(vector);
}

fn charge(budget: *usize, text: []const u8) error{InvalidConfig}!void {
    if (text.len >= budget.* or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidConfig;
    budget.* -= text.len + 1;
}

fn validate(config: Config) error{InvalidConfig}!void {
    if (config.argv.len == 0 or config.argv.len > 4096 or config.environment.len > 4096 or
        config.argv[0].len == 0 or config.argv[0][0] != '/' or config.cwd.len == 0 or config.cwd[0] != '/') return error.InvalidConfig;
    for ([_]usize{ config.input_limit, config.output_limit }) |limit| {
        if (limit == 0 or limit > 16 * 1024 * 1024 or !std.math.isPowerOfTwo(limit)) return error.InvalidConfig;
    }
    if (config.stderr_limit > 16 * 1024 * 1024) return error.InvalidConfig;
    var budget: usize = 1024 * 1024;
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

const Pipe = struct {
    fds: [2]c_int = .{ -1, -1 },

    fn init(parent_end: usize) !Pipe {
        var pipe = Pipe{};
        if (os.pipe2(&pipe.fds, os.CLOEXEC) < 0) return error.SystemResources;
        errdefer pipe.deinit();
        // Do not set NONBLOCK on the child's ends (ordinary stdio semantics).
        if (os.fcntl(pipe.fds[parent_end], 4, @as(c_int, os.NONBLOCK)) < 0) return error.SystemResources;
        return pipe;
    }

    fn close(self: *Pipe, end: usize) void {
        if (self.fds[end] >= 0) _ = os.close(self.fds[end]);
        self.fds[end] = -1;
    }

    fn deinit(self: *Pipe) void {
        self.close(0);
        self.close(1);
    }
};

fn worker(self: *Transport) void {
    run(self) catch {
        self.final.outcome = .spawn_failed;
        self.final.spawn_errno = os.errno();
    };
    // The ONLY completion publication, and the last access to self. All defers
    // in run have finished, including wait/deinit. No detached child can survive
    // an early error: run has no fallible exits after obtaining its Owner.
    self.done.store(true, .release);
}

fn stopReason(self: *Transport) ?Outcome {
    if (self.stopping.load(.acquire)) return .cancelled;
    if (self.deadline) |deadline| if (os.nowMs() >= deadline) return .timed_out;
    return null;
}

fn run(self: *Transport) !void {
    if (stopReason(self)) |reason| {
        self.final.outcome = reason;
        return;
    }
    // SIGPIPE must not kill the application when the child closes stdin. Block
    // it only on this dedicated worker; pending SIGPIPE dies with the thread.
    // Owner resets the command's signal mask/dispositions before exec.
    var mask: [16]c_ulong = @splat(0);
    mask[0] = 1 << (13 - 1);
    if (os.sigprocmask(0, &mask, null) < 0) return error.SystemResources; // SIG_BLOCK
    var input = try Pipe.init(1);
    defer input.deinit();
    var output = try Pipe.init(0);
    defer output.deinit();
    var stderr = try Pipe.init(0);
    defer stderr.deinit();
    var owner = try ownership.start(.{
        .argv = self.argv.ptr,
        .environment = self.environment.ptr,
        .cwd = self.cwd,
        .stdin = input.fds[0],
        .stdout = output.fds[1],
        .stderr = stderr.fds[1],
    });
    defer owner.deinit();
    input.close(0);
    output.close(1);
    stderr.close(1);

    var reason: ?Outcome = null;
    var report: ?ownership.Report = null;
    // Each turn does at most one read per stream and one write. A stderr flood
    // cannot starve stdin, cancellation, the deadline, or supervisor completion.
    while (report == null) {
        if (reason == null) reason = stopReason(self);
        if (reason != null) {
            self.stopping.store(true, .release);
            owner.cancel();
            input.close(1);
        }
        // Observe closeInput BEFORE peeking: its release publishes the final
        // accepted send, so an old empty-queue observation cannot close early.
        const closing_input = self.input_closed.load(.acquire);
        const pending = self.input.peek();
        if (closing_input and pending.len == 0) input.close(1);
        var fds = [_]os.PollFd{
            .{ .fd = owner.report, .events = os.POLLIN },
            .{ .fd = output.fds[0], .events = os.POLLIN },
            .{ .fd = stderr.fds[0], .events = os.POLLIN },
            .{ .fd = if (pending.len > 0) input.fds[1] else -1, .events = os.POLLOUT },
        };
        const rc = os.poll(&fds, fds.len, 5);
        if (rc < 0) {
            if (os.errno() == os.EINTR) continue;
            if (reason == null) reason = .io_failed;
            owner.cancel();
            // Even a poll failure must not bypass the sole Owner waiter.
            report = owner.wait();
            break;
        }
        if (fds[1].revents != 0) _ = drain(self, &output, false, &reason);
        if (fds[2].revents != 0) _ = drain(self, &stderr, true, &reason);
        if (fds[3].revents != 0 and input.fds[1] >= 0) {
            const n = os.write(input.fds[1], pending.ptr, @min(pending.len, 4096));
            if (n > 0) {
                self.input.consume(@intCast(n));
            } else if (n < 0 and os.errno() != os.EAGAIN and os.errno() != os.EINTR) {
                input.close(1);
                self.input_closed.store(true, .release);
                if (reason == null) reason = .io_failed;
            }
        }
        if (fds[0].revents != 0) report = owner.wait();
    }
    // Reaping doesn't imply pipe EOF (an escaped descendant could retain a fd).
    // Drain only what is already available, with an explicit finite bound even
    // if such an escapee writes continuously. Ordinary Linux pipes hold <=1 MiB
    // by default, but use F_GETPIPE_SZ to include a host's actual capacity.
    drainAfterReap(self, &output, false, &reason);
    drainAfterReap(self, &stderr, true, &reason);
    const reaped = report.?;
    self.final.reaped = reaped.reaped != 0;
    self.final.spawn_errno = reaped.spawn_errno;
    if (reaped.reaped != 0) {
        const signal: u8 = @intCast(reaped.status & 0x7f);
        if (signal == 0) self.final.exit_code = @intCast((reaped.status >> 8) & 0xff) else self.final.term_signal = signal;
    }
    self.final.outcome = if (reason) |value| value else if (reaped.spawn_errno != 0 or reaped.reaped == 0)
        .spawn_failed
    else if (self.final.term_signal != null)
        .signaled
    else if (self.final.exit_code.? != 0)
        .nonzero
    else
        .success;
}

/// Returns bytes consumed; zero for EOF/EAGAIN/error. No raw stderr survives.
fn drain(self: *Transport, pipe: *Pipe, is_stderr: bool, reason: *?Outcome) usize {
    if (pipe.fds[0] < 0) return 0;
    var buffer: [4096]u8 = undefined;
    const n = while (true) {
        const n = os.read(pipe.fds[0], &buffer, buffer.len);
        if (n < 0 and os.errno() == os.EINTR) continue;
        break n;
    };
    if (n <= 0) {
        if (n == 0) {
            pipe.close(0);
            if (!is_stderr) self.output_eof.store(true, .release);
        } else if (os.errno() != os.EAGAIN and os.errno() != os.EINTR) {
            pipe.close(0);
            if (reason.* == null) reason.* = .io_failed;
        }
        return 0;
    }
    const count: usize = @intCast(n);
    if (is_stderr) {
        const remaining = self.stderr_limit - self.final.stderr.bytes;
        self.final.stderr.bytes += @min(count, remaining);
        self.final.stderr.capped = self.final.stderr.capped or count > remaining;
    } else if (self.final.stdout_discarded) {
        // Retain the pre-overflow prefix, never resume after a missing byte.
    } else {
        // Preserve as much of this chunk as fits, including tiny configured
        // queues. Only the worker produces output, so this space cannot shrink.
        const used = self.output.head.load(.monotonic) -% self.output.tail.load(.acquire);
        const available = self.output.bytes.len - used;
        const pushed = self.output.push(buffer[0..@min(count, available)]);
        std.debug.assert(pushed);
        if (count > available) {
            self.final.stdout_discarded = true;
            if (reason.* == null) reason.* = .output_limit;
        }
    }
    return count;
}

fn drainAfterReap(self: *Transport, pipe: *Pipe, is_stderr: bool, reason: *?Outcome) void {
    if (pipe.fds[0] < 0) return;
    const capacity = os.fcntl(pipe.fds[0], 1032); // F_GETPIPE_SZ
    var remaining: usize = if (capacity > 0) @intCast(capacity) else 1024 * 1024;
    while (remaining > 0) {
        const count = drain(self, pipe, is_stderr, reason);
        if (count == 0) break;
        remaining -|= count;
    }
}
