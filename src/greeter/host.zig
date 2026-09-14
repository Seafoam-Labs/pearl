//! Owned process supervision exercised only with private fixtures until GR01 is certified.
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
    fn stop(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Host = @ptrCast(@alignCast(data.?));
        if (!self.stopping) {
            self.stopping = true;
            _ = std.c.kill(-self.pid, std.c.SIG.TERM);
            _ = glib.timeoutAdd(5000, force, self);
        }
        return 1;
    }
    fn force(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Host = @ptrCast(@alignCast(data.?));
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
};
pub fn run(args: []const []const u8) !void {
    var argv: [257:null]?[*:0]const u8 = @splat(null);
    if (args.len == 0 or args.len > 256 or args[0][0] != '/') return error.InvalidFixture;
    for (args, 0..) |arg, i| argv[i] = (try a.dupeZ(u8, arg)).ptr;
    // Become the reaper only for descendants of this supervisor.
    if (std.os.linux.prctl(36, 1, 0, 0, 0) != 0) return error.Subreaper;
    const pid = std.c.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        if (std.c.setsid() < 0) std.process.exit(127);
        _ = std.os.linux.prctl(1, @intFromEnum(std.c.SIG.KILL), 0, 0, 0);
        _ = std.c.execve(argv[0].?, @ptrCast(&argv), @ptrCast(std.c.environ));
        std.process.exit(127);
    }
    const fd_raw = std.os.linux.pidfd_open(pid, 0);
    if (std.posix.errno(fd_raw) != .SUCCESS) {
        _ = std.c.kill(pid, std.c.SIG.KILL);
        _ = std.c.waitpid(pid, null, 0);
        return error.Pidfd;
    }
    var self: Host = .{ .loop = glib.MainLoop.new(null, 0), .pid = pid, .pidfd = @intCast(fd_raw) };
    defer _ = std.c.close(self.pidfd);
    defer self.loop.unref();
    const source = unix.fdAdd(self.pidfd, .{ .in = true }, Host.exited, &self);
    const term = unix.signalAdd(@intFromEnum(std.c.SIG.TERM), Host.stop, &self);
    const int = unix.signalAdd(@intFromEnum(std.c.SIG.INT), Host.stop, &self);
    defer _ = glib.Source.remove(term);
    defer _ = glib.Source.remove(int);
    std.log.info("event=greeter-host-started", .{});
    self.loop.run();
    if (self.forced) _ = glib.Source.remove(source);
    _ = std.c.kill(-pid, std.c.SIG.KILL);
    while (true) {
        const n = std.c.waitpid(-1, null, 0);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
    }
    std.log.info("event=greeter-host-reaped", .{});
}
