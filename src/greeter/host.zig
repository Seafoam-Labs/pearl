//! Ordinary Aqueous hosting with an inherited, credential-free init lifecycle pipe.
const std = @import("std");
const glib = @import("glib2");
const unix = @import("glibunix2");
const a = std.heap.c_allocator;
const Host = struct {
    loop: *glib.MainLoop,
    pid: c_int,
    pidfd: c_int,
    stopping: bool = false,
    forced: bool = false,
    ready: bool = false,
    init_fd: c_int = -1,
    init_source: c_uint = 0,
    lifecycle_source: c_uint = 0,
    message: [32]u8 = undefined,
    message_len: usize = 0,
    startup_timer: c_uint = 0,
    stop_timer: c_uint = 0,
    fn stop(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Host = @ptrCast(@alignCast(data.?));
        if (!self.stopping) {
            self.stopping = true;
            _ = std.c.kill(-self.pid, std.c.SIG.TERM);
            self.stop_timer = glib.timeoutAdd(5000, force, self);
        }
        return 1;
    }
    fn force(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Host = @ptrCast(@alignCast(data.?));
        self.stop_timer = 0;
        self.forced = true;
        _ = std.c.kill(-self.pid, std.c.SIG.KILL);
        self.loop.quit();
        return 0;
    }
    fn exited(_: c_int, _: glib.IOCondition, data: ?*anyopaque) callconv(.c) c_int {
        // Keep leader unreaped until its group is terminated, so its PID cannot be reused.
        const self: *Host = @ptrCast(@alignCast(data.?));
        _ = stop(self);
        _ = std.c.kill(-self.pid, std.c.SIG.KILL);
        self.loop.quit();
        return 0;
    }
    fn startupTimeout(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Host = @ptrCast(@alignCast(data.?));
        self.startup_timer = 0;
        std.log.err("Greeter init did not start within 30 seconds", .{});
        _ = stop(self);
        return 0;
    }
    fn initExited(_: c_int, _: glib.IOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Host = @ptrCast(@alignCast(data.?));
        self.init_source = 0;
        _ = stop(self);
        return 0;
    }
    fn lifecycle(fd: c_int, _: glib.IOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Host = @ptrCast(@alignCast(data.?));
        const n = std.c.read(fd, self.message[self.message_len..].ptr, self.message.len - self.message_len);
        if (n > 0) {
            self.message_len += @intCast(n);
            if (std.mem.indexOfScalar(u8, self.message[0..self.message_len], '\n')) |end| {
                const pid = std.fmt.parseInt(c_int, self.message[0..end], 10) catch 0;
                if (pid > 0) {
                    const raw = std.os.linux.pidfd_open(pid, 0);
                    if (std.posix.errno(raw) == .SUCCESS) {
                        self.init_fd = @intCast(raw);
                        self.init_source = unix.fdAdd(self.init_fd, .{ .in = true }, initExited, self);
                        self.ready = true;
                        if (self.startup_timer != 0) {
                            _ = glib.Source.remove(self.startup_timer);
                            self.startup_timer = 0;
                        }
                        self.lifecycle_source = 0;
                        return 0;
                    }
                }
            } else if (self.message_len < self.message.len) return 1;
        }
        self.lifecycle_source = 0;
        _ = stop(self);
        return 0;
    }
};
pub fn run(args: []const []const u8) !void {
    return supervise(args, false);
}
pub fn runManaged(args: []const []const u8) !void {
    return supervise(args, true);
}
fn supervise(args: []const []const u8, managed: bool) !void {
    var argv: [257:null]?[*:0]const u8 = @splat(null);
    if (args.len == 0 or args.len > 256 or args[0].len == 0 or args[0][0] != '/') return error.InvalidCommand;
    for (args, 0..) |arg, i| argv[i] = (try a.dupeZ(u8, arg)).ptr;
    // Become the reaper only for descendants of this supervisor.
    if (std.os.linux.prctl(36, 1, 0, 0, 0) != 0) return error.Subreaper;
    var pipe: [2]c_int = undefined;
    if (std.c.pipe2(&pipe, .{ .CLOEXEC = true }) != 0) return error.Pipe;
    defer _ = std.c.close(pipe[0]);
    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(pipe[1]);
        return error.Fork;
    }
    if (pid == 0) {
        _ = std.c.close(pipe[0]);
        if (managed) {
            if (std.c.dup2(pipe[1], 3) < 0) std.process.exit(127);
            if (std.c.fcntl(3, std.c.F.SETFD, @as(c_int, 0)) < 0) std.process.exit(127);
            if (pipe[1] != 3) _ = std.c.close(pipe[1]);
        }
        if (std.c.setsid() < 0) std.process.exit(127);
        _ = std.os.linux.prctl(1, @intFromEnum(std.c.SIG.KILL), 0, 0, 0);
        _ = std.c.execve(argv[0].?, @ptrCast(&argv), @ptrCast(std.c.environ));
        std.process.exit(127);
    }
    _ = std.c.close(pipe[1]);
    const fd_raw = std.os.linux.pidfd_open(pid, 0);
    if (std.posix.errno(fd_raw) != .SUCCESS) {
        _ = std.c.kill(pid, std.c.SIG.KILL);
        _ = std.c.waitpid(pid, null, 0);
        return error.Pidfd;
    }
    var self: Host = .{ .loop = glib.MainLoop.new(null, 0), .pid = pid, .pidfd = @intCast(fd_raw) };
    defer _ = std.c.close(self.pidfd);
    defer self.loop.unref();
    self.lifecycle_source = if (managed) unix.fdAdd(pipe[0], .{ .in = true, .hup = true }, Host.lifecycle, &self) else 0;
    defer if (self.lifecycle_source != 0) {
        _ = glib.Source.remove(self.lifecycle_source);
    };
    defer if (self.init_source != 0) {
        _ = glib.Source.remove(self.init_source);
    };
    defer if (self.init_fd >= 0) {
        _ = std.c.close(self.init_fd);
    };
    if (managed) self.startup_timer = glib.timeoutAdd(30000, Host.startupTimeout, &self);
    defer if (self.startup_timer != 0) {
        _ = glib.Source.remove(self.startup_timer);
    };
    defer if (self.stop_timer != 0) {
        _ = glib.Source.remove(self.stop_timer);
    };
    const source = unix.fdAdd(self.pidfd, .{ .in = true }, Host.exited, &self);
    const term = unix.signalAdd(@intFromEnum(std.c.SIG.TERM), Host.stop, &self);
    const int = unix.signalAdd(@intFromEnum(std.c.SIG.INT), Host.stop, &self);
    defer _ = glib.Source.remove(term);
    defer _ = glib.Source.remove(int);
    std.log.info("event=greeter-host-started", .{});
    self.loop.run();
    if (self.forced) _ = glib.Source.remove(source);
    _ = std.c.kill(-pid, std.c.SIG.KILL);
    try reapDescendants();
    std.log.info("event=greeter-host-reaped", .{});
    if (managed and !self.ready) return error.GreeterStartupFailed;
}

// Aqueous starts init in a separate session. As subreaper, kill and reap each
// adopted generation too; process-group termination alone leaves these alive.
fn reapDescendants() !void {
    const path = try std.fmt.allocPrintSentinel(a, "/proc/self/task/{d}/children", .{std.os.linux.getpid()}, 0);
    defer a.free(path);
    while (true) {
        var contents: [*]u8 = undefined;
        var len: usize = 0;
        if (glib.fileGetContents(path, &contents, &len, null) == 0) return error.ReadChildren;
        defer glib.free(contents);
        var children = std.mem.tokenizeScalar(u8, contents[0..len], ' ');
        var found = false;
        while (children.next()) |entry| {
            const child = try std.fmt.parseInt(c_int, entry, 10);
            found = true;
            // A direct child cannot have its PID reused before we reap it.
            _ = std.c.kill(child, std.c.SIG.KILL);
            while (std.c.waitpid(child, null, 0) < 0) {
                if (std.posix.errno(-1) != .INTR) break;
            }
        }
        if (!found) break;
    }
}
