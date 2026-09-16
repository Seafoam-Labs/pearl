//! No shell. Anonymous stdin avoids pipe deadlocks; both output pipes are drained
//! under byte/deadline limits. Cancellation kills and reaps the helper group.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
extern fn memfd_create([*:0]const u8, c_uint) c_int;
extern fn waitid(c_int, c_uint, *std.c.siginfo_t, c_int) c_int;
extern fn setpgid(c_int, c_int) c_int;
fn streamFd(stream: *gio.InputStream) c_int {
    return @as(*@import("giounix2").InputStream, @ptrCast(stream)).getFd();
}
pub const Result = struct { stdout: []const u8, stderr: []const u8, success: bool };
fn child(_: ?*anyopaque) callconv(.c) void {
    _ = setpgid(0, 0);
}
pub const Choice = std.atomic.Value(u8); // 0 pending, 1 Keep, 2 Revert
pub fn run(a: std.mem.Allocator, argv: []const [:0]const u8, input: ?[]const u8, cancel: *gio.Cancellable, timeout_ms: i64) !Result {
    return runIn(a, argv, input, cancel, timeout_ms, null);
}
pub fn runIn(a: std.mem.Allocator, argv: []const [:0]const u8, input: ?[]const u8, cancel: *gio.Cancellable, timeout_ms: i64, instance: ?@import("aqueous_instance.zig").Context) !Result {
    const launcher = gio.SubprocessLauncher.new(.{ .stdout_pipe = true, .stderr_pipe = true });
    defer launcher.unref();
    if (instance) |ctx| ctx.configure(launcher);
    launcher.setChildSetup(child, null, null);
    if (input) |bytes| {
        if (bytes.len > @import("aqueous_model.zig").max_request) return error.RequestTooLarge;
        const fd = memfd_create("pearl-aqueous-request", 1);
        if (fd < 0) return error.StdinUnavailable;
        launcher.takeStdinFd(fd);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
            if (n <= 0) return error.StdinWriteFailed;
            offset += @intCast(n);
        }
        if (std.c.lseek(fd, 0, std.c.SEEK.SET) < 0) return error.StdinWriteFailed;
    }
    const args = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| args[i] = arg.ptr;
    const process = launcher.spawnv(@ptrCast(args.ptr), null) orelse return error.HelperUnavailable;
    defer process.unref();
    const pid = std.fmt.parseInt(c_int, std.mem.span(process.getIdentifier() orelse return error.HelperUnavailable), 10) catch return error.HelperUnavailable;
    defer {
        _ = std.c.kill(-pid, std.c.SIG.KILL);
        process.forceExit();
        _ = process.wait(null, null);
    }
    var fds = [_]std.c.pollfd{
        .{ .fd = streamFd(process.getStdoutPipe().?), .events = std.c.POLL.IN, .revents = 0 },
        .{ .fd = streamFd(process.getStderrPipe().?), .events = std.c.POLL.IN, .revents = 0 },
    };
    var buffers: [2]std.ArrayList(u8) = .{ .empty, .empty };
    const limits = [_]usize{ @import("aqueous_model.zig").max_response, 65536 };
    const deadline = glib.getMonotonicTime() + timeout_ms * 1000;
    while (fds[0].fd >= 0 or fds[1].fd >= 0) {
        if (cancel.isCancelled() != 0) return error.Cancelled;
        if (glib.getMonotonicTime() >= deadline) return error.HelperTimedOut;
        const ready = std.c.poll(&fds, fds.len, 50);
        if (ready < 0) {
            if (std.posix.errno(ready) == .INTR) continue;
            return error.HelperReadFailed;
        }
        for (&fds, 0..) |*fd, i| {
            if (fd.fd < 0 or fd.revents == 0) continue;
            var chunk: [8192]u8 = undefined;
            const n = std.c.read(fd.fd, &chunk, chunk.len);
            if (n < 0) return error.HelperReadFailed;
            if (n == 0) {
                fd.fd = -1;
                continue;
            }
            if (buffers[i].items.len + @as(usize, @intCast(n)) > limits[i]) return error.HelperOutputTooLarge;
            try buffers[i].appendSlice(a, chunk[0..@intCast(n)]);
        }
    }
    // A helper may close its pipes before exiting; never wait without a deadline.
    while (true) {
        var info: std.c.siginfo_t = undefined;
        const rc = waitid(1, @intCast(pid), &info, std.c.W.EXITED | std.c.W.NOHANG | std.c.W.NOWAIT);
        if (rc == 0 and info.fields.common.first.piduid.pid != 0) break;
        // GSubprocess may have reaped it through GLib's child watcher already.
        if (rc < 0 and std.posix.errno(rc) == .CHILD) break;
        if (cancel.isCancelled() != 0) return error.Cancelled;
        if (glib.getMonotonicTime() >= deadline) return error.HelperTimedOut;
        _ = std.c.poll(&fds, 0, 20);
    }
    if (process.wait(null, null) == 0) return error.HelperFailed;
    return .{ .stdout = buffers[0].items, .stderr = buffers[1].items, .success = process.getSuccessful() != 0 };
}
test "helper process drains both pipes, preserves stdin and caps stderr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    const input = try alloc.alloc(u8, 200000);
    @memset(input, 'x');
    const result = try run(alloc, &.{ "/usr/bin/python3", "-c", "import sys; sys.stderr.write('diagnostic'); sys.stdout.write(str(len(sys.stdin.buffer.read())))" }, input, cancel, 3000);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("200000", result.stdout);
    try std.testing.expectEqualStrings("diagnostic", result.stderr);
    try std.testing.expectError(error.HelperOutputTooLarge, run(alloc, &.{ "/usr/bin/python3", "-c", "import sys; sys.stderr.write('x'*70000)" }, null, cancel, 3000));
}
test "helper deadline covers closed pipes, inherited pipes and cancellation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    try std.testing.expectError(error.HelperTimedOut, run(alloc, &.{ "/usr/bin/python3", "-c", "import os,time; os.close(1); os.close(2); time.sleep(10)" }, null, cancel, 100));
    try std.testing.expectError(error.HelperTimedOut, run(alloc, &.{ "/usr/bin/python3", "-c", "import os,time; p=os.fork(); time.sleep(10) if p==0 else None" }, null, cancel, 100));
    cancel.cancel();
    try std.testing.expectError(error.Cancelled, run(alloc, &.{ "/usr/bin/python3", "-c", "import time; time.sleep(10)" }, null, cancel, 1000));
}
