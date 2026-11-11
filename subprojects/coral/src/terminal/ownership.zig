//! Linux process ownership shared by bounded capture and the native PTY spike.
//!
//! A private, non-execing subreaper owns only this job's children. The command
//! gets its own session in async-signal-safe post-fork setup. The supervisor
//! observes the leader with WNOWAIT: its unreaped PID pins the process-group ID
//! through the LAST group signal. Never signal a numeric PID after reaping it.
//! The supervisor is outside that group and can reap adopted descendants after
//! KILL. No application-wide subreaper, SIGCHLD handler or waitpid(-1) is used.
//!
//! Ordinary descendants inheriting the command group are covered, including
//! non-interactive shell background children. A descendant that deliberately
//! escapes with setsid/setpgid is NOT contained. This is NOT a sandbox. Such
//! escapees are neither signaled nor awaited; orphan reaping belongs to init.
//! A kernel-uninterruptible child can delay reaping; the TERM grace, not kernel
//! wait completion, is bounded. Do not install another reaper for these PIDs
//! or set host SIGCHLD to SIG_IGN/SA_NOCLDWAIT. Fields are private; do not copy
//! live Owners. Each start adds one small supervisor process and uses a fixed
//! 150ms cleanup grace (also after normal leader exit).
//!
//! start/wait are worker-thread operations. cancel closes an ownership channel,
//! not a PID; it is safe even after supervisor exit and cannot hit a reused PID.
//! Serialize cancel/destroy at the caller. wait may run concurrently with cancel.
const std = @import("std");
pub const os = @import("posix.zig");
pub const grace_ms = 150;
pub const Report = extern struct {
    /// Raw Linux wait status for the command leader, not the supervisor.
    status: c_int = 0,
    /// Zero on success; errno for setup/exec failure, EIO for lost supervisor.
    spawn_errno: c_int = 0,
    /// Successfully execed command and its ordinary group have been reaped.
    /// Setup/exec failures are also reaped, but have no command result.
    reaped: c_int = 0,
};
pub const Config = struct {
    argv: [*:null]const ?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
    cwd: [*:0]const u8,
    stdin: c_int,
    stdout: c_int,
    stderr: c_int,
    terminal: bool = false,
    /// Borrowed descriptor and approved metadata; null preserves pathname exec
    /// for existing task/PTY callers. No pathname fallback when supplied.
    executable: ?@import("executable.zig").Verified = null,
};
pub const Owner = struct {
    pid: os.pid_t,
    control: c_int,
    report: c_int,

    /// Idempotent, nonblocking. Keep the Owner alive until wait returns.
    pub fn cancel(self: *Owner) void {
        if (self.control >= 0) {
            _ = os.close(self.control);
            self.control = -1;
        }
    }

    /// Exactly one waiter. Only this supervisor PID is reaped in the host.
    /// A successful report guarantees no ordinary descendant remains. A failed
    /// supervisor report cannot certify cleanup; never try to recover by
    /// signaling a numeric PID whose ownership may already have been lost.
    pub fn wait(self: *const Owner) Report {
        var result = Report{ .spawn_errno = os.EIO };
        const bytes = std.mem.asBytes(&result);
        var used: usize = 0;
        while (used < bytes.len) {
            const n = os.read(self.report, bytes[used..].ptr, bytes.len - used);
            if (n < 0 and os.errno() == os.EINTR) continue;
            if (n <= 0) break;
            used += @intCast(n);
        }
        var status: c_int = 0;
        var got: c_int = 0;
        while (true) {
            got = os.waitpid(self.pid, &status, 0);
            if (got < 0 and os.errno() == os.EINTR) continue;
            break;
        }
        if (used != bytes.len or got != self.pid or status != 0) return .{ .spawn_errno = os.EIO };
        return result;
    }

    /// Only after wait has returned; no pending worker may still reference this.
    pub fn deinit(self: *Owner) void {
        self.cancel();
        _ = os.close(self.report);
        self.report = -1;
    }
};

/// All descriptors are borrowed. No allocations or application/runtime callbacks
/// run after fork. The child closes unrelated inherited descriptors before any
/// command exec (also important when other jobs are starting concurrently).
pub fn start(config: Config) error{SystemResources}!Owner {
    var control: [2]c_int = undefined;
    if (os.pipe2(&control, os.CLOEXEC) != 0) return error.SystemResources;
    defer _ = os.close(control[0]);
    errdefer _ = os.close(control[1]);
    var report: [2]c_int = undefined;
    if (os.pipe2(&report, os.CLOEXEC) != 0) return error.SystemResources;
    defer _ = os.close(report[1]);
    errdefer _ = os.close(report[0]);
    // Relocate every source above the destination range before fork, so dup2
    // cannot overwrite another source even if the host had closed fd 0/1/2.
    var sources: [6]c_int = @splat(-1);
    defer for (sources) |fd| {
        if (fd >= 0) _ = os.close(fd);
    };
    for ([_]c_int{ config.stdin, config.stdout, config.stderr, control[0], report[1] }, 0..) |fd, i| {
        sources[i] = os.fcntl(fd, 1030, @as(c_int, 10)); // F_DUPFD_CLOEXEC
        if (sources[i] < 0) return error.SystemResources;
    }
    if (config.executable) |exe| {
        sources[5] = os.fcntl(exe.fd, 1030, @as(c_int, 10));
        if (sources[5] < 0) return error.SystemResources;
    }
    // On Linux sigprocmask changes only this thread. Block delivery across
    // _Fork so an inherited application signal handler cannot run in the
    // child before its dispositions have been reset. Restore the worker mask.
    var blocked: [16]c_ulong = undefined;
    var previous: [16]c_ulong = undefined;
    _ = os.sigfillset(&blocked);
    if (os.sigprocmask(2, &blocked, &previous) < 0) return error.SystemResources;
    defer _ = os.sigprocmask(2, &previous, null);
    const pid = os._Fork();
    if (pid < 0) return error.SystemResources;
    if (pid == 0) supervise(config, sources);
    return .{ .pid = pid, .control = control[1], .report = report[0] };
}

fn sendReport(report: Report) noreturn {
    const bytes = std.mem.asBytes(&report);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = os.write(4, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and os.errno() == os.EINTR) continue;
        if (n <= 0) os._exit(125);
        offset += @intCast(n);
    }
    os._exit(0);
}

fn execFailed(fd: c_int) noreturn {
    execFailure(fd, os.errno());
}

fn execFailure(fd: c_int, failure: c_int) noreturn {
    const bytes = std.mem.asBytes(&failure);
    while (os.write(fd, bytes.ptr, bytes.len) < 0 and os.errno() == os.EINTR) {}
    os._exit(127);
}

fn supervise(config: Config, sources: [6]c_int) noreturn {
    const source_count: usize = if (config.executable != null) 6 else 5;
    for (sources[0..source_count], 0..) |fd, i| {
        if (os.dup2(fd, @intCast(i)) < 0) os._exit(125);
    }
    // Linux close_range and prctl are syscall-only libc wrappers. No locks,
    // allocation, GLib, formatting, or Zig runtime work is allowed here.
    if (os.close_range(@intCast(source_count), std.math.maxInt(c_uint), 0) != 0) sendReport(.{ .spawn_errno = os.errno() });
    var mask: [16]c_ulong = undefined;
    _ = os.sigemptyset(&mask);
    var sig: c_int = 1;
    while (sig < 65) : (sig += 1) _ = os.signal(sig, null); // SIG_DFL (including SIGCHLD)
    _ = os.sigprocmask(2, &mask, null); // SIG_SETMASK, only after resetting handlers
    if (os.setsid() < 0 or os.prctl(36, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) < 0)
        sendReport(.{ .spawn_errno = os.errno() }); // PR_SET_CHILD_SUBREAPER
    var handshake: [2]c_int = undefined;
    if (os.pipe2(&handshake, os.CLOEXEC) < 0) sendReport(.{ .spawn_errno = os.errno() });
    const leader = os._Fork();
    if (leader < 0) sendReport(.{ .spawn_errno = os.errno() });
    if (leader == 0) {
        _ = os.close(handshake[0]);
        _ = os.close(3);
        _ = os.close(4);
        if (os.setsid() < 0) execFailed(handshake[1]);
        if (config.terminal and os.ioctl(0, os.TIOCSCTTY, @as(c_int, 0)) < 0) execFailed(handshake[1]);
        if (os.chdir(config.cwd) < 0) execFailed(handshake[1]);
        if (config.executable) |exe| {
            // dup2 cleared CLOEXEC. Native binaries need no inherited handle;
            // scripts do: the kernel passes /dev/fd/5 to their interpreter.
            if (os.fcntl(5, 2, @as(c_int, 1)) < 0) execFailed(handshake[1]); // F_SETFD, FD_CLOEXEC
            if (!exe.identity.matches(5)) execFailure(handshake[1], os.ESTALE);
            _ = os.execveat(5, "", config.argv, config.environment, 0x1000); // AT_EMPTY_PATH
            if (os.errno() == os.ENOENT) {
                // Linux rejects CLOEXEC script fds with ENOENT. Retry ONLY the
                // same descriptor, retained until the interpreter closes it or
                // exits. Missing interpreters/procfs still fail safely.
                if (os.fcntl(5, 2, @as(c_int, 0)) < 0) execFailed(handshake[1]);
                if (!exe.identity.matches(5)) execFailure(handshake[1], os.ESTALE);
                _ = os.execveat(5, "", config.argv, config.environment, 0x1000);
            }
        } else {
            _ = os.execve(config.argv[0].?, config.argv, config.environment);
        }
        execFailed(handshake[1]);
    }
    if (config.executable != null) _ = os.close(5);
    _ = os.close(handshake[1]);
    for (0..3) |fd| _ = os.close(@intCast(fd));
    var report = Report{};
    var n: isize = 0;
    while (true) {
        n = os.read(handshake[0], std.mem.asBytes(&report.spawn_errno).ptr, @sizeOf(c_int));
        if (n < 0 and os.errno() == os.EINTR) continue;
        break;
    }
    _ = os.close(handshake[0]);
    if (n != 0) {
        if (n != @sizeOf(c_int)) report.spawn_errno = os.EIO;
        while (os.waitpid(leader, null, 0) < 0 and os.errno() == os.EINTR) {}
        // Setup/exec failed: no user code ran and no group signaling is needed.
        sendReport(report);
    }
    // The exec handshake established setsid success. Even a very short-lived
    // command remains waitable: WNOWAIT reserves its ID until cleanup ends.
    while (true) {
        var info: [32]c_int align(8) = @splat(0);
        const rc = os.waitid(1, @intCast(leader), &info, 4 | 1 | 0x1000000); // P_PID, WEXITED|WNOHANG|WNOWAIT
        if (rc == 0 and info[0] != 0) break;
        if (rc < 0 and os.errno() != os.EINTR) os._exit(125); // never signal without ownership
        var pollfd = [_]os.PollFd{.{ .fd = 3, .events = os.POLLIN }};
        if (os.poll(&pollfd, 1, 5) > 0) break; // cancel/shutdown channel EOF
    }
    _ = os.kill(-leader, os.TERM);
    const deadline = os.nowMs() + grace_ms;
    var no_fds: [0]os.PollFd = .{};
    while (os.nowMs() < deadline) _ = os.poll(&no_fds, 0, @intCast(@max(1, deadline - os.nowMs())));
    _ = os.kill(-leader, os.KILL);
    // No signals after this point. Reap the leader, then only the owned group.
    // The subreaper adopts its grandchildren as intermediate parents die.
    while (os.waitpid(leader, &report.status, 0) < 0) {
        if (os.errno() != os.EINTR) os._exit(125);
    }
    report.reaped = 1;
    while (true) {
        if (os.waitpid(-leader, null, 0) >= 0) continue;
        if (os.errno() == os.EINTR) continue;
        if (os.errno() != os.ECHILD) os._exit(125);
        break;
    }
    sendReport(report);
}
