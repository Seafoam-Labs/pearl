//! Standalone executable smoke tests: zig test src/terminal/pty.zig -lc
//! No display server, installed widget, package installation, or shell-string
//! interpolation of user values. Fixed fixture source only; values use argv.
const std = @import("std");
const pty = @import("pty.zig");
const os = pty.os;

fn receiveUntil(handle: *pty.Pty, storage: []u8, used: *usize, needle: []const u8) !void {
    const deadline = os.nowMs() + 3000;
    while (std.mem.indexOf(u8, storage[0..used.*], needle) == null) {
        if (used.* == storage.len) return error.OutputLimit;
        if (os.nowMs() > deadline) return error.TestTimeout;
        const n = handle.read(storage[used.*..]) catch |err| switch (err) {
            error.WouldBlock => {
                var fds = [_]os.PollFd{.{ .fd = handle.master, .events = os.POLLIN }};
                _ = os.poll(&fds, 1, 10);
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.UnexpectedEof;
        used.* += n;
    }
}

fn sendAll(handle: *pty.Pty, bytes: []const u8) !void {
    const deadline = os.nowMs() + 3000;
    var used: usize = 0;
    while (used < bytes.len) {
        if (os.nowMs() > deadline) return error.TestTimeout;
        used += handle.write(bytes[used..]) catch |err| switch (err) {
            error.WouldBlock => {
                var fds = [_]os.PollFd{.{ .fd = handle.master, .events = os.POLLOUT }};
                _ = os.poll(&fds, 1, 10);
                continue;
            },
            else => return err,
        };
    }
}

test "PTY native isatty, initial size, resize, argv, UTF8 bidirectional bytes and EOF" {
    const fixture =
        \\test -t 0 && test -t 1 && test -t 2 || exit 31
        \\printf 'TTY:'; /bin/stty size
        \\printf 'ARG:%s\nREADY\n' "$1"
        \\IFS= read -r line || exit 32
        \\printf 'SIZE:'; /bin/stty size
        \\printf 'REPLY:%s\n' "$line"
        \\printf '\033]52;c;not-a-clipboard-operation\007'
        \\printf 'DONE\n'
    ;
    var handle = try pty.start(.{
        .authorization = .approved,
        .argv = &.{ "/bin/sh", "-c", fixture, "pty-fixture", "literal ; $(no-execution) λ" },
        .cwd = "/",
    });
    defer handle.deinit();
    try std.testing.expect(os.isatty(handle.master) == 1);
    var storage: [8192]u8 = undefined;
    var used: usize = 0;
    try receiveUntil(&handle, &storage, &used, "READY\r\n");
    try std.testing.expect(std.mem.indexOf(u8, storage[0..used], "TTY:24 80\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, storage[0..used], "ARG:literal ; $(no-execution) λ\r\n") != null);
    try handle.resize(41, 109);
    // Deliberately split multibyte UTF-8 across writes; no text decoder lives
    // in the transport, nor should one silently replace or drop those bytes.
    const input = "héλ🙂";
    for (input) |byte| try sendAll(&handle, &.{byte});
    try sendAll(&handle, "\n");
    try receiveUntil(&handle, &storage, &used, "DONE\r\n");
    try std.testing.expect(std.mem.indexOf(u8, storage[0..used], "SIZE:41 109\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, storage[0..used], "REPLY:héλ🙂\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, storage[0..used], "\x1b]52;c;not-a-clipboard-operation\x07") != null);
    const report = handle.wait();
    try std.testing.expectEqual(@as(c_int, 0), report.spawn_errno);
    try std.testing.expectEqual(@as(c_int, 0), report.status);
    try std.testing.expectEqual(@as(c_int, 1), report.reaped);
    try std.testing.expectEqual(@as(usize, 0), try handle.read(&storage));
    // A late cancel closes only our channel; it cannot signal a stale PID.
    handle.cancel();
    handle.cancel();
}

extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn unlink([*:0]const u8) c_int;
extern "c" fn rmdir([*:0]const u8) c_int;
extern "c" fn access([*:0]const u8, c_int) c_int;

test "PTY cancel escalates and reaps background descendants before sentinel write" {
    var template = "/tmp/coral-pty-XXXXXX".*;
    const directory = mkdtemp(&template) orelse return error.TempDirectory;
    defer _ = rmdir(directory);
    const sentinel = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/sentinel", .{directory}, 0);
    defer std.testing.allocator.free(sentinel);
    defer _ = unlink(sentinel);
    var handle = try pty.start(.{
        .authorization = .approved,
        .argv = &.{
            "/bin/sh",     "-c",
            \\trap '' TERM HUP
            \\( trap '' TERM HUP; printf 'CHILD-READY\n'; /bin/sleep 0.7; printf escaped > "$1" ) &
            \\wait
            ,
            "pty-fixture", sentinel,
        },
        .cwd = std.mem.span(directory),
    });
    defer handle.deinit();
    var storage: [512]u8 = undefined;
    var used: usize = 0;
    try receiveUntil(&handle, &storage, &used, "CHILD-READY\r\n");
    const started = os.nowMs();
    handle.cancel();
    const report = handle.wait();
    try std.testing.expect(os.nowMs() - started < 2000);
    try std.testing.expectEqual(@as(c_int, 9), report.status & 0x7f);
    try std.testing.expectEqual(@as(c_int, 1), report.reaped);
    var fds: [0]os.PollFd = .{};
    _ = os.poll(&fds, 0, 800);
    try std.testing.expect(access(sentinel, 0) != 0);
}

test "PTY asynchronous exec failure and denied requests" {
    try std.testing.expectError(error.Unauthorized, pty.start(.{ .argv = &.{"/bin/sh"}, .cwd = "/" }));
    try std.testing.expectError(error.InvalidConfig, pty.start(.{ .authorization = .approved, .argv = &.{"sh"}, .cwd = "/" }));
    var handle = try pty.start(.{ .authorization = .approved, .argv = &.{"/definitely-missing-coral-pty-executable"}, .cwd = "/" });
    defer handle.deinit();
    const report = handle.wait();
    try std.testing.expect(report.spawn_errno != 0);
    try std.testing.expectEqual(@as(c_int, 0), report.reaped);
}
