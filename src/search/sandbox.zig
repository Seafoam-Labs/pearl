//! Bounded bubblewrap supervisor for document converters, mirroring the
//! audited preview-helper sandbox (fixed argv, dropped capabilities, read-only
//! source bind, resource limits, pipe caps and child reaping). Converters run
//! in a child of the indexing worker, never in the shell's main thread.
const std = @import("std");
const c = std.c;
const linux = std.os.linux;
const a = std.heap.c_allocator;
pub const Status = enum { ok, failed, sandbox, timeout, limits };
pub const Result = struct {
    bytes: []u8 = &.{},
    allocation: []u8 = &.{},
    status: Status = .ok,
    pub fn deinit(self: Result) void {
        if (self.allocation.len > 0) a.free(self.allocation);
    }
};
const Argv = struct {
    items: [192:null]?[*:0]const u8 = @splat(null),
    len: usize = 0,
    fn append(self: *Argv, values: []const [*:0]const u8) void {
        std.debug.assert(self.len + values.len < self.items.len);
        for (values) |value| {
            self.items[self.len] = value;
            self.len += 1;
        }
    }
};
fn close(fd: *c.fd_t) void {
    if (fd.* >= 0) _ = c.close(fd.*);
    fd.* = -1;
}
fn nowMs() ?i64 {
    var time: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &time) != 0) return null;
    return @as(i64, time.sec) * 1000 + @divTrunc(time.nsec, 1_000_000);
}
// After fork, use only syscall/libc operations safe in a child of a threaded
// process. Build argv and allocate the output buffer before entering this branch.
fn child(argv: *const Argv, pipes: [2][2]c.fd_t, input: c.fd_t, parent: c.pid_t) noreturn {
    if (linux.errno(linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @backingInt(c.SIG.KILL), 0, 0, 0)) != .SUCCESS or c.getppid() != parent) c._exit(125);
    if (c.dup2(pipes[0][1], 1) < 0 or c.dup2(pipes[1][1], 2) < 0 or c.dup2(input, 3) < 0) c._exit(125);
    const null_fd = c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    if (null_fd < 0 or c.dup2(null_fd, 0) < 0) c._exit(125);
    if (linux.errno(linux.close_range(4, std.math.maxInt(c.fd_t), .{ .UNSHARE = false, .CLOEXEC = false })) != .SUCCESS) c._exit(125);
    if (c.setrlimit(.AS, &.{ .cur = 512 * 1024 * 1024, .max = 512 * 1024 * 1024 }) != 0 or
        c.setrlimit(.CORE, &.{ .cur = 0, .max = 0 }) != 0 or
        c.setrlimit(.STACK, &.{ .cur = 8 * 1024 * 1024, .max = 8 * 1024 * 1024 }) != 0 or
        c.setrlimit(.FSIZE, &.{ .cur = 1024 * 1024, .max = 1024 * 1024 }) != 0) c._exit(125);
    _ = c.execve(argv.items[0].?, &argv.items, @ptrCast(c.environ));
    c._exit(125);
}
pub fn run(tool: [:0]const u8, args: []const ?[*:0]const u8, source: c.fd_t, timeout_ms: u32, cap: usize) Result {
    if (c.access("/usr/bin/bwrap", c.X_OK) != 0 or c.access(tool, c.X_OK) != 0) return .{ .status = .sandbox };
    if (args.len >= 96) return .{ .status = .failed };
    var pipes: [2][2]c.fd_t = .{ .{ -1, -1 }, .{ -1, -1 } };
    defer for (&pipes) |*pipe| {
        for (pipe) |*fd| close(fd);
    };
    for (&pipes) |*pipe| if (c.pipe2(pipe, .{ .CLOEXEC = true }) != 0) return .{ .status = .failed };
    var input = c.fcntl(source, c.F.DUPFD_CLOEXEC, @as(c_int, 10));
    if (input < 0) return .{ .status = .failed };
    defer close(&input);
    var argv: Argv = .{};
    argv.append(&.{ "/usr/bin/bwrap", "--unshare-all", "--die-with-parent", "--new-session", "--cap-drop", "ALL", "--ro-bind", "/usr", "/usr" });
    for ([_][:0]const u8{ "/lib", "/lib64", "/etc/ld.so.cache" }) |path| {
        if (c.access(path, c.R_OK) == 0) argv.append(&.{ "--ro-bind", path, path });
    }
    argv.append(&.{
        "--proc",          "/proc",     "--dev",        "/dev",
        "--dir",           "/input",    "--ro-bind-fd", "3",
        "/input/source",   "--ro-bind", tool,           "/tool",
        "--dir",           "/home",     "--dir",        "/home/search",
        "--size",          "1048576",   "--tmpfs",      "/tmp",
        "--remount-ro",    "/",         "--chdir",      "/input",
        "--clearenv",      "--setenv",  "HOME",         "/home/search",
        "--setenv",        "LC_ALL",    "C",            "--setenv",
        "OMP_NUM_THREADS", "2",         "--setenv",     "MALLOC_ARENA_MAX",
        "2",               "--",        "/tool",
    });
    for (args) |arg| argv.append(&.{arg orelse break});
    const buffer = a.alloc(u8, cap) catch return .{ .status = .failed };
    var transfer_buffer = false;
    defer if (!transfer_buffer) a.free(buffer);
    const began = nowMs() orelse return .{ .status = .failed };
    const deadline = began + @max(timeout_ms, 1);
    const parent = c.getpid();
    const pid = c.fork();
    if (pid < 0) return .{ .status = .failed };
    if (pid == 0) child(&argv, pipes, input, parent);
    var exited = false;
    var wait_status: c_int = 0;
    // Every post-fork return reaps the child. Killing bubblewrap tears down its
    // PID namespace, including converter descendants which still hold pipes open.
    defer if (!exited) {
        _ = c.kill(pid, .KILL);
        while (c.waitpid(pid, &wait_status, 0) < 0) {
            if (c.errno(@as(c_int, -1)) != .INTR) break;
        }
    };
    close(&input);
    close(&pipes[0][1]);
    close(&pipes[1][1]);
    var fds = [_]c.pollfd{
        .{ .fd = pipes[0][0], .events = c.POLL.IN, .revents = 0 },
        .{ .fd = pipes[1][0], .events = c.POLL.IN, .revents = 0 },
    };
    pipes[0][0] = -1;
    pipes[1][0] = -1;
    defer for (&fds) |*fd| close(&fd.fd);
    for (fds) |fd| {
        const flags = c.fcntl(fd.fd, c.F.GETFL);
        if (flags < 0 or c.fcntl(fd.fd, c.F.SETFL, flags | @as(c_int, @bitCast(c.O{ .NONBLOCK = true }))) < 0) return .{ .status = .failed };
    }
    var status: Status = .ok;
    var length: usize = 0;
    while (status == .ok and (!exited or fds[0].fd >= 0 or fds[1].fd >= 0)) {
        const now = nowMs() orelse {
            status = .failed;
            break;
        };
        if (now >= deadline) {
            status = .timeout;
            break;
        }
        const polled = c.poll(&fds, fds.len, @intCast(@min(25, deadline - now)));
        if (polled < 0) {
            if (c.errno(polled) == .INTR) continue;
            status = .failed;
            break;
        }
        for (&fds, 0..) |*fd, i| {
            if (fd.fd < 0 or fd.revents == 0) continue;
            var chunk: [16384]u8 = undefined;
            const count = c.read(fd.fd, &chunk, chunk.len);
            if (count == 0) {
                close(&fd.fd);
            } else if (count < 0) {
                const err = c.errno(count);
                if (err != .AGAIN and err != .INTR) {
                    status = .failed;
                    break;
                }
            } else {
                const n: usize = @intCast(count);
                if (i == 0) {
                    if (n > cap - length) {
                        status = .limits;
                        break;
                    }
                    @memcpy(buffer[length..][0..n], chunk[0..n]);
                    length += n;
                }
                // Drain stderr without retaining or displaying it.
            }
        }
        if (!exited) {
            const got = c.waitpid(pid, &wait_status, c.W.NOHANG);
            if (got == pid) {
                exited = true;
            } else if (got < 0 and c.errno(got) != .INTR) {
                if (c.errno(got) == .CHILD) exited = true;
                status = .failed;
            }
        }
    }
    const raw_status: u32 = @bitCast(wait_status);
    if (status == .ok and (!c.W.IFEXITED(raw_status) or c.W.EXITSTATUS(raw_status) != 0)) status = .failed;
    if (status != .ok) return .{ .status = status };
    transfer_buffer = true;
    return .{ .bytes = buffer[0..length], .allocation = buffer };
}
