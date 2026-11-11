//! Real subprocess tests, no GTK/display required. Fixtures use /bin/python3,
//! /bin/cat and /bin/sh on the same Linux x86_64/glibc platform as Owner.
//! Run via src/transport_tests.zig, so ../terminal stays inside the module root.
const std = @import("std");
const transport = @import("transport.zig");
const os = @import("../terminal/ownership.zig").os;
const a = std.testing.allocator;

fn config(argv: []const []const u8) transport.Config {
    return .{ .authorization = .approved, .argv = argv, .cwd = "/", .timeout_ms = 3000 };
}

fn python(source: []const u8, cfg: *transport.Config, argv: *[3][]const u8) void {
    argv.* = .{ "/bin/python3", "-c", source };
    cfg.* = config(argv);
}

fn pause(ms: c_int) void {
    var fds: [0]os.PollFd = .{};
    _ = os.poll(&fds, 0, ms);
}

/// Test-only blocking main-context stand-in, with a deadline on every wait.
fn wait(t: *transport.Transport, buffer: []u8) !usize {
    const deadline = os.nowMs() + 6000;
    var used: usize = 0;
    while (true) {
        used += t.read(buffer[used..]);
        if (t.isComplete()) return used;
        if (used == buffer.len) {
            var extra: [1]u8 = undefined;
            if (t.read(&extra) != 0) return error.TestBufferFull;
        }
        if (os.nowMs() >= deadline) return error.TestTimeout;
        pause(1);
    }
}

fn cleanup(t: *transport.Transport) void {
    t.stop();
    var buffer: [4096]u8 = undefined;
    const deadline = os.nowMs() + 6000;
    while (!t.isComplete()) {
        _ = t.read(&buffer);
        if (os.nowMs() >= deadline) @panic("transport did not finish cleanup");
        pause(1);
    }
    t.destroy();
}

fn readyLine(t: *transport.Transport, buffer: []u8) ![]const u8 {
    var used: usize = 0;
    const deadline = os.nowMs() + 3000;
    while (true) {
        used += t.read(buffer[used..]);
        if (std.mem.indexOfScalar(u8, buffer[0..used], '\n')) |end| return buffer[0..end];
        if (t.isComplete() or used == buffer.len or os.nowMs() >= deadline) return error.NotReady;
        pause(1);
    }
}

test "transport fragmented binary duplex, copied sends, stdin EOF, stable completion" {
    var cfg: transport.Config = undefined;
    var argv: [3][]const u8 = undefined;
    python(
        \\import os, time
        \\while True:
        \\    b = os.read(0, 2)
        \\    if not b: break
        \\    for byte in b:
        \\        os.write(1, bytes([byte]))
        \\        time.sleep(0.002)
        \\os.write(1, b'EOF')
    , &cfg, &argv);
    const t = try transport.start(a, cfg);
    defer cleanup(t);
    var first = [_]u8{ 'a', 0, 'b' };
    try t.send(&first);
    @memset(&first, 'x');
    try t.send("\xff\nlast");
    t.closeInput();
    t.closeInput();
    try std.testing.expectError(error.Closed, t.send("late"));
    var output: [64]u8 = undefined;
    const len = try wait(t, &output);
    try std.testing.expectEqualStrings("a\x00b\xff\nlastEOF", output[0..len]);
    const result = t.result().?;
    try std.testing.expectEqual(transport.Outcome.success, result.outcome);
    try std.testing.expect(result.reaped);
    try std.testing.expectEqual(@as(?u8, 0), result.exit_code);
    t.stop();
    t.stop();
    try std.testing.expectEqualDeep(result, t.result().?);
    try std.testing.expectEqual(@as(usize, 0), t.read(&output));
}

test "transport pins literal argv cwd and explicit environment before worker spawn" {
    var executable = "/bin/python3".*;
    var cwd = "/tmp".*;
    var name = "CORAL_TEST".*;
    var value = "pinned".*;
    var arg = "$(not a shell) * ~ ;".*;
    var argv = [_][]const u8{
        &executable,
        "-c",
        "import os,sys; os.write(1, (os.getcwd()+'|'+os.environ['CORAL_TEST']+'|'+str('HOME' in os.environ)+'|'+sys.argv[1]).encode())",
        &arg,
    };
    var environment = [_]transport.Environment{.{ .name = &name, .value = &value }};
    var cfg = config(&argv);
    cfg.cwd = &cwd;
    cfg.environment = &environment;
    const t = try transport.start(a, cfg);
    defer cleanup(t);
    @memset(&executable, 'x');
    @memset(&cwd, 'x');
    @memset(&name, 'x');
    @memset(&value, 'x');
    @memset(&arg, 'x');
    @memset(&argv, "changed");
    environment[0] = .{ .name = "changed", .value = "changed" };
    var buffer: [128]u8 = undefined;
    const len = try wait(t, &buffer);
    try std.testing.expectEqualStrings("/tmp|pinned|False|$(not a shell) * ~ ;", buffer[0..len]);
    try std.testing.expectEqual(transport.Outcome.success, t.result().?.outcome);
}

test "transport separately drains stderr beyond pipe capacity without retaining secrets" {
    var cfg: transport.Config = undefined;
    var argv: [3][]const u8 = undefined;
    python(
        \\import os
        \\for i in range(128): os.write(2, b'SECRET!!' * 4096)
        \\os.write(1, b'ready\n')
        \\os.write(1, os.read(0, 5))
    , &cfg, &argv);
    cfg.stderr_limit = 37;
    const t = try transport.start(a, cfg);
    defer cleanup(t);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ready", try readyLine(t, &buffer));
    try t.send("hello");
    const len = try wait(t, &buffer);
    try std.testing.expectEqualStrings("hello", buffer[0..len]);
    try std.testing.expectEqual(transport.Outcome.success, t.result().?.outcome);
    try std.testing.expectEqualDeep(transport.Stderr{ .bytes = 37, .capped = true }, t.result().?.stderr);
}

test "transport stdin backpressure is bounded atomic and cancellable" {
    var cfg = config(&.{ "/bin/sh", "-c", "printf 'ready\n'; exec /bin/sleep 10" });
    cfg.input_limit = 1024;
    const t = try transport.start(a, cfg);
    defer cleanup(t);
    var buffer: [64]u8 = undefined;
    _ = try readyLine(t, &buffer);
    const payload: [1024]u8 = @splat('a');
    var accepted: usize = 0;
    const deadline = os.nowMs() + 1500;
    var last_progress = os.nowMs();
    while (true) {
        if (t.send(&payload)) |_| {
            accepted += payload.len;
            last_progress = os.nowMs();
        } else |err| {
            try std.testing.expectEqual(error.Backpressure, err);
            // Give the worker many poll turns. This must fill the kernel pipe,
            // not merely race the first dequeue from the small input ring.
            if (accepted > payload.len and os.nowMs() - last_progress >= 100) break;
            pause(1);
        }
        if (os.nowMs() >= deadline) return error.MissingBackpressure;
    }
    try std.testing.expect(accepted > cfg.input_limit);
    const oversized: [1025]u8 = @splat('b');
    try std.testing.expectError(error.MessageTooLarge, t.send(&oversized));
    const before = os.nowMs();
    t.stop();
    try std.testing.expect(os.nowMs() - before < 100);
    try std.testing.expectError(error.Closed, t.send("x"));
    _ = try wait(t, &buffer);
    try std.testing.expectEqual(transport.Outcome.cancelled, t.result().?.outcome);
    try std.testing.expect(t.result().?.reaped);
}

test "transport retries backpressure and streams more than either ring capacity" {
    var cfg = config(&.{"/bin/cat"});
    cfg.input_limit = 1024;
    cfg.output_limit = 16384;
    const t = try transport.start(a, cfg);
    defer cleanup(t);
    const payload: [257]u8 = @splat(0xab);
    var buffer: [4096]u8 = undefined;
    var sent: usize = 0;
    var received: usize = 0;
    var closed = false;
    const deadline = os.nowMs() + 4000;
    while (!t.isComplete()) {
        if (sent < 1000) {
            if (t.send(&payload)) |_| {
                sent += 1;
            } else |err| if (err != error.Backpressure) return err;
        } else if (!closed) {
            t.closeInput();
            closed = true;
        }
        const n = t.read(&buffer);
        for (buffer[0..n]) |byte| try std.testing.expectEqual(@as(u8, 0xab), byte);
        received += n;
        if (os.nowMs() >= deadline) return error.TestTimeout;
        pause(1);
    }
    try std.testing.expectEqual(@as(usize, 257000), received);
    try std.testing.expectEqual(transport.Outcome.success, t.result().?.outcome);
}

test "transport stdout overflow fails closed retains bounded prefix and reaps" {
    var cfg: transport.Config = undefined;
    var argv: [3][]const u8 = undefined;
    python("import os; os.write(1, b'x' * 65536)", &cfg, &argv);
    cfg.output_limit = 16;
    const t = try transport.start(a, cfg);
    defer cleanup(t);
    // Deliberately do not consume. Wait for the worker, not public completion:
    // queued stdout must precede the caller's closed notification.
    const deadline = os.nowMs() + 3000;
    while (!t.done.load(.acquire)) {
        if (os.nowMs() >= deadline) return error.TestTimeout;
        pause(1);
    }
    try std.testing.expect(!t.isComplete());
    try std.testing.expect(t.result() == null);
    var buffer: [32]u8 = undefined;
    const n = try wait(t, &buffer);
    try std.testing.expectEqualStrings("xxxxxxxxxxxxxxxx", buffer[0..n]);
    try std.testing.expectEqual(transport.Outcome.output_limit, t.result().?.outcome);
    try std.testing.expect(t.result().?.stdout_discarded);
    try std.testing.expect(t.result().?.reaped);
}

test "transport exact stdout capacity and capped stderr boundary are not overflow" {
    for ([_]usize{ 0, 16 }) |limit| {
        var cfg = config(&.{ "/bin/sh", "-c", "printf 1234567890abcdef; printf 1234567890abcdef >&2" });
        cfg.output_limit = 16;
        cfg.stderr_limit = limit;
        const t = try transport.start(a, cfg);
        defer cleanup(t);
        var buffer: [32]u8 = undefined;
        const n = try wait(t, &buffer);
        try std.testing.expectEqualStrings("1234567890abcdef", buffer[0..n]);
        try std.testing.expectEqual(transport.Outcome.success, t.result().?.outcome);
        try std.testing.expectEqualDeep(transport.Stderr{ .bytes = limit, .capped = limit == 0 }, t.result().?.stderr);
    }
}

test "transport stdout EOF waits for queued bytes but not process exit" {
    var cfg: transport.Config = undefined;
    var argv: [3][]const u8 = undefined;
    python(
        \\import os, time
        \\os.write(1, (str(os.getpid()) + '\ntrailing bytes').encode())
        \\os.close(1)
        \\time.sleep(30)
    , &cfg, &argv);
    cfg.timeout_ms = 0; // Long-lived language servers have no lifetime timeout.
    const t = try transport.start(a, cfg);
    defer cleanup(t);
    // Synchronize with actual worker EOF publication without consuming output,
    // so the drained-EOF guard is tested deterministically rather than by sleep.
    const deadline = os.nowMs() + 3000;
    while (!t.output_eof.load(.acquire)) {
        if (t.isComplete() or os.nowMs() >= deadline) return error.MissingOutputEof;
        pause(1);
    }
    try std.testing.expect(!t.isOutputClosed());
    try std.testing.expect(!t.isComplete());
    try std.testing.expect(t.result() == null);
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), t.read(buffer[0..1]));
    try std.testing.expect(!t.isOutputClosed());
    var used: usize = 1;
    while (!t.isOutputClosed()) {
        if (used == buffer.len or os.nowMs() >= deadline) return error.OutputNotDrained;
        used += t.read(buffer[used..]);
    }
    const newline = std.mem.indexOfScalar(u8, buffer[0..used], '\n') orelse return error.MissingPid;
    const pid = try std.fmt.parseInt(c_int, buffer[0..newline], 10);
    try std.testing.expectEqualStrings("trailing bytes", buffer[newline + 1 .. used]);
    try std.testing.expectEqual(@as(usize, 0), t.read(&buffer));
    try std.testing.expectEqual(@as(c_int, 0), os.kill(pid, 0));
    try std.testing.expect(!t.isComplete());
    try std.testing.expect(t.result() == null);
    t.stop();
    _ = try wait(t, &buffer);
    try std.testing.expect(t.isOutputClosed());
    try std.testing.expectEqual(transport.Outcome.cancelled, t.result().?.outcome);
    try std.testing.expect(t.result().?.reaped);
    try std.testing.expect(os.kill(pid, 0) < 0);
    try std.testing.expectEqual(@as(c_int, 3), os.errno()); // ESRCH, not a zombie
}

test "transport empty stdout queue and stderr EOF are not stdout EOF" {
    var cfg: transport.Config = undefined;
    var argv: [3][]const u8 = undefined;
    python(
        \\import os, time
        \\os.close(2)
        \\os.write(1, b'ready\n')
        \\os.read(0, 1)
        \\os.close(1)
        \\time.sleep(30)
    , &cfg, &argv);
    cfg.timeout_ms = 0;
    const t = try transport.start(a, cfg);
    defer cleanup(t);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ready", try readyLine(t, &buffer));
    try std.testing.expectEqual(@as(usize, 0), t.read(&buffer));
    try std.testing.expect(!t.isOutputClosed());
    try t.send("x");
    const deadline = os.nowMs() + 3000;
    while (!t.isOutputClosed()) {
        if (t.isComplete() or os.nowMs() >= deadline) return error.MissingOutputEof;
        pause(1);
    }
    try std.testing.expect(!t.isComplete());
    try std.testing.expect(t.result() == null);
    t.stop();
    _ = try wait(t, &buffer);
    try std.testing.expectEqual(transport.Outcome.cancelled, t.result().?.outcome);
    try std.testing.expect(t.result().?.reaped);
    try std.testing.expect(t.isOutputClosed());
}

test "transport timeout survives stdout stderr EOF and needs no main ticks" {
    var cfg = config(&.{ "/bin/sh", "-c", "exec 1>&- 2>&-; exec /bin/sleep 10" });
    cfg.timeout_ms = 80;
    const t = try transport.start(a, cfg);
    defer cleanup(t);
    pause(400);
    var buffer: [1]u8 = undefined;
    _ = try wait(t, &buffer);
    try std.testing.expectEqual(transport.Outcome.timed_out, t.result().?.outcome);
    try std.testing.expect(t.result().?.reaped);
}

test "transport cancellation across spawn handoff never loses the Owner" {
    for (0..32) |i| {
        const t = try transport.start(a, config(&.{ "/bin/sleep", "10" }));
        defer cleanup(t);
        if (i % 2 != 0) pause(1);
        t.stop();
        t.stop();
        var buffer: [1]u8 = undefined;
        _ = try wait(t, &buffer);
        try std.testing.expectEqual(transport.Outcome.cancelled, t.result().?.outcome);
        // No process was execed if cancellation won before worker entry.
        try std.testing.expect(t.result().?.spawn_errno == 0);
    }
}

test "transport nonzero signal exec and cwd failures are asynchronous terminal results" {
    const Case = struct { argv: []const []const u8, cwd: []const u8 = "/", outcome: transport.Outcome, code: ?u8 = null, signal: ?u8 = null };
    for ([_]Case{
        .{ .argv = &.{ "/bin/sh", "-c", "exit 23" }, .outcome = .nonzero, .code = 23 },
        .{ .argv = &.{ "/bin/sh", "-c", "kill -KILL $$" }, .outcome = .signaled, .signal = 9 },
        .{ .argv = &.{"/coral-transport-nonexistent-executable"}, .outcome = .spawn_failed },
        .{ .argv = &.{"/bin/cat"}, .cwd = "/coral-transport-nonexistent-cwd", .outcome = .spawn_failed },
    }) |case| {
        var cfg = config(case.argv);
        cfg.cwd = case.cwd;
        const t = try transport.start(a, cfg);
        defer cleanup(t);
        var buffer: [32]u8 = undefined;
        _ = try wait(t, &buffer);
        const result = t.result().?;
        try std.testing.expectEqual(case.outcome, result.outcome);
        try std.testing.expectEqual(case.code, result.exit_code);
        try std.testing.expectEqual(case.signal, result.term_signal);
        try std.testing.expectEqual(case.outcome != .spawn_failed, result.reaped);
        try std.testing.expectEqual(case.outcome == .spawn_failed, result.spawn_errno != 0);
    }
}

test "transport broken stdin does not deliver SIGPIPE to host" {
    const t = try transport.start(a, config(&.{ "/bin/sh", "-c", "exec 0<&-; printf 'ready\n'; exec /bin/sleep 10" }));
    defer cleanup(t);
    var buffer: [64]u8 = undefined;
    _ = try readyLine(t, &buffer);
    try t.send("write into closed pipe");
    _ = try wait(t, &buffer);
    try std.testing.expectEqual(transport.Outcome.io_failed, t.result().?.outcome);
    try std.testing.expect(t.result().?.reaped);
}

const tree_fixture =
    \\import os, signal, time, sys
    \\r,w = os.pipe()
    \\child = os.fork()
    \\if child == 0:
    \\    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    \\    os.close(r)
    \\    os.write(w, b'R')
    \\    time.sleep(10)
    \\    os._exit(99)
    \\os.close(w)
    \\os.read(r, 1)
    \\signal.signal(signal.SIGTERM, signal.SIG_IGN)
    \\os.write(1, (str(os.getpid())+' '+str(child)+'\n').encode())
    \\if sys.argv[1] == 'normal': os._exit(0)
    \\time.sleep(10)
;

test "transport reaps TERM ignoring leader and descendants, isolating unrelated job" {
    const unrelated = try transport.start(a, config(&.{"/bin/cat"}));
    defer cleanup(unrelated);
    for ([_][]const u8{ "cancel", "normal", "timeout" }) |mode| {
        var cfg = config(&.{ "/bin/python3", "-c", tree_fixture, mode });
        if (std.mem.eql(u8, mode, "timeout")) cfg.timeout_ms = 200;
        const t = try transport.start(a, cfg);
        defer cleanup(t);
        var buffer: [128]u8 = undefined;
        const line = try readyLine(t, &buffer);
        var parts = std.mem.splitScalar(u8, line, ' ');
        const leader = try std.fmt.parseInt(c_int, parts.next().?, 10);
        const child = try std.fmt.parseInt(c_int, parts.next().?, 10);
        if (std.mem.eql(u8, mode, "cancel")) t.stop();
        _ = try wait(t, &buffer);
        const expected: transport.Outcome = if (std.mem.eql(u8, mode, "normal")) .success else if (std.mem.eql(u8, mode, "cancel")) .cancelled else .timed_out;
        try std.testing.expectEqual(expected, t.result().?.outcome);
        try std.testing.expect(t.result().?.reaped);
        for ([_]c_int{ leader, child }) |pid| {
            try std.testing.expect(os.kill(pid, 0) < 0);
            try std.testing.expectEqual(@as(c_int, 3), os.errno()); // ESRCH, not a zombie
        }
        try std.testing.expect(!unrelated.isComplete());
    }
    try unrelated.send("unrelated survived");
    unrelated.closeInput();
    var buffer: [64]u8 = undefined;
    const n = try wait(unrelated, &buffer);
    try std.testing.expectEqualStrings("unrelated survived", buffer[0..n]);
    try std.testing.expectEqual(transport.Outcome.success, unrelated.result().?.outcome);
}

test "transport denies unauthorized malformed or unbounded requests synchronously" {
    var cfg = config(&.{"/bin/cat"});
    cfg.authorization = .denied;
    try std.testing.expectError(error.Unauthorized, transport.start(a, cfg));
    cfg.authorization = .approved;
    cfg.argv = &.{};
    try std.testing.expectError(error.InvalidConfig, transport.start(a, cfg));
    cfg.argv = &.{"cat"};
    try std.testing.expectError(error.InvalidConfig, transport.start(a, cfg));
    cfg.argv = &.{ "/bin/cat", "nul\x00byte" };
    try std.testing.expectError(error.InvalidConfig, transport.start(a, cfg));
    cfg.argv = &.{"/bin/cat"};
    cfg.cwd = "relative";
    try std.testing.expectError(error.InvalidConfig, transport.start(a, cfg));
    cfg.cwd = "/";
    for ([_]usize{ 0, 3, 32 * 1024 * 1024 }) |limit| {
        cfg.input_limit = limit;
        try std.testing.expectError(error.InvalidConfig, transport.start(a, cfg));
    }
    cfg.input_limit = 1024;
    cfg.environment = &.{.{ .name = "A=B", .value = "c" }};
    try std.testing.expectError(error.InvalidConfig, transport.start(a, cfg));
    cfg.environment = &.{ .{ .name = "A", .value = "b" }, .{ .name = "A", .value = "c" } };
    try std.testing.expectError(error.InvalidConfig, transport.start(a, cfg));
    cfg.environment = &.{.{ .name = "", .value = "b" }};
    try std.testing.expectError(error.InvalidConfig, transport.start(a, cfg));
    cfg.environment = &.{.{ .name = "A", .value = "b\x00c" }};
    try std.testing.expectError(error.InvalidConfig, transport.start(a, cfg));
}

fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var cfg = config(&.{ "/bin/cat", "-" });
    cfg.environment = &.{.{ .name = "CORAL_TEST", .value = "pinned" }};
    const t = try transport.start(allocator, cfg);
    defer cleanup(t);
    t.closeInput();
    var buffer: [16]u8 = undefined;
    _ = try wait(t, &buffer);
    try std.testing.expect(t.result().?.reaped);
}

test "transport releases every partially pinned request on allocation failure" {
    try std.testing.checkAllAllocationFailures(a, allocationAttempt, .{});
}

test "transport retains final burst across reap until main drains it" {
    var cfg: transport.Config = undefined;
    var argv: [3][]const u8 = undefined;
    python("import os; os.write(1, bytes(range(256)) * 256)", &cfg, &argv);
    cfg.output_limit = 65536;
    const t = try transport.start(a, cfg);
    defer cleanup(t);
    const deadline = os.nowMs() + 3000;
    while (!t.done.load(.acquire)) {
        if (os.nowMs() >= deadline) return error.TestTimeout;
        pause(1);
    }
    try std.testing.expect(!t.isComplete());
    var output: [65536]u8 = undefined;
    const count = try wait(t, &output);
    try std.testing.expectEqual(output.len, count);
    for (output, 0..) |byte, i| try std.testing.expectEqual(@as(u8, @truncate(i)), byte);
    try std.testing.expectEqual(transport.Outcome.success, t.result().?.outcome);
    try std.testing.expect(!t.result().?.stdout_discarded);
    try std.testing.expect(t.result().?.reaped);
}

test "transport stderr flood cannot starve timeout or exhaust metadata budget" {
    var cfg: transport.Config = undefined;
    var argv: [3][]const u8 = undefined;
    python("import os\nwhile True: os.write(2, b'private data' * 4096)", &cfg, &argv);
    cfg.timeout_ms = 150;
    cfg.stderr_limit = 17;
    const t = try transport.start(a, cfg);
    defer cleanup(t);
    var buffer: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try wait(t, &buffer));
    try std.testing.expectEqual(transport.Outcome.timed_out, t.result().?.outcome);
    try std.testing.expectEqualDeep(transport.Stderr{ .bytes = 17, .capped = true }, t.result().?.stderr);
    try std.testing.expect(t.result().?.reaped);
}

test "transport validates both queue limits request budgets and argv count" {
    var cfg = config(&.{"/bin/cat"});
    for ([_]usize{ 0, 3, 32 * 1024 * 1024 }) |limit| {
        cfg.output_limit = limit;
        try std.testing.expectError(error.InvalidConfig, transport.start(a, cfg));
    }
    cfg.output_limit = 1024;
    cfg.stderr_limit = 32 * 1024 * 1024;
    try std.testing.expectError(error.InvalidConfig, transport.start(a, cfg));
    cfg.stderr_limit = 1024;
    const large = try a.alloc(u8, 1024 * 1024);
    defer a.free(large);
    @memset(large, 'x');
    cfg.argv = &.{ "/bin/cat", large };
    try std.testing.expectError(error.InvalidConfig, transport.start(a, cfg));
    const many: [4097][]const u8 = @splat("/bin/cat");
    cfg.argv = &many;
    try std.testing.expectError(error.InvalidConfig, transport.start(a, cfg));
}
