//! Pure Linux/libc execution-boundary regressions; no GTK or timing-based races.
const std = @import("std");
const executable = @import("executable.zig");
const transport = @import("../language/transport.zig");
const os = @import("posix.zig");
const Fixture = @import("../workspace/manifest_test_support.zig").Fixture;
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

fn capture(path: [*:0]const u8) !executable.Verified {
    const fd = std.c.open(path, .{ .PATH = true, .CLOEXEC = true });
    try expect(fd >= 0);
    errdefer _ = std.c.close(fd);
    return .{ .fd = fd, .identity = try executable.Identity.capture(fd) };
}

fn script(f: *Fixture, name: []const u8, contents: []const u8) ![:0]u8 {
    try f.write(name, contents);
    const path = try f.path(name);
    errdefer a.free(path);
    try equal(@as(c_int, 0), std.c.chmod(path, 0o700));
    return path;
}

fn config(exe: executable.Verified, argv: []const []const u8) transport.Config {
    return .{ .authorization = .approved, .executable = exe, .argv = argv, .cwd = "/", .timeout_ms = 3000 };
}

fn wait(t: *transport.Transport, output: []u8) !usize {
    const deadline = os.nowMs() + 6000;
    var used: usize = 0;
    while (true) {
        used += t.read(output[used..]);
        if (t.isComplete()) return used;
        if (used == output.len) return error.TestOutputFull;
        if (os.nowMs() >= deadline) return error.TestTimeout;
        _ = os.poll(&.{}, 0, 1);
    }
}

fn cleanup(t: *transport.Transport) void {
    t.stop();
    var output: [4096]u8 = undefined;
    _ = wait(t, &output) catch @panic("descriptor transport cleanup failed");
    t.destroy();
}

fn descriptorCount() !usize {
    const fd = std.c.open("/proc/self/fd", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    try expect(fd >= 0);
    const dir = std.c.fdopendir(fd) orelse {
        _ = std.c.close(fd);
        return error.ProcUnavailable;
    };
    defer _ = std.c.closedir(dir);
    var count: usize = 0;
    while (std.c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) count += 1;
    }
    return count;
}

test "verified exec ignores a replaced pathname before spawn and supports shebang lifetime" {
    const before = try descriptorCount();
    {
        var f = try Fixture.init();
        defer f.deinit();
        const original = try script(&f, "original", "#!/bin/sh\nread line\n[ -r /dev/fd/5 ] || exit 91\nprintf 'approved:%s:%s' \"$line\" \"$0\"\n");
        defer a.free(original);
        const replacement = try script(&f, "replacement", "#!/bin/sh\nprintf replacement-ran\n");
        defer a.free(replacement);
        try f.symlink(original, "server");
        const path = try f.path("server");
        defer a.free(path);
        const exe = try capture(path);
        var closed = false;
        defer if (!closed) exe.close();
        // No scheduling race: change argv[0]'s target before transport.start.
        // The approved inode stays unchanged, so descriptor execution succeeds.
        try equal(@as(c_int, 0), std.c.unlink(path));
        try equal(@as(c_int, 0), std.c.symlink(replacement, path));
        const t = try transport.start(a, config(exe, &.{path}));
        defer cleanup(t);
        exe.close(); // Emulate Config.deinit immediately after launch returns.
        closed = true;
        try t.send("alive\n");
        t.closeInput();
        var output: [128]u8 = undefined;
        const len = try wait(t, &output);
        // Direct descriptor shebang execution exposes the fd path as $0, not
        // the original script pathname; self-relative scripts need an explicit
        // interpreter argv with the original script path as its argument.
        try std.testing.expectEqualStrings("approved:alive:/dev/fd/5", output[0..len]);
        try equal(transport.Outcome.success, t.result().?.outcome);
        try expect(t.result().?.reaped);
    }
    try equal(before, try descriptorCount());
}

test "verified explicit interpreter preserves script dollar zero for sibling execution" {
    const before = try descriptorCount();
    {
        var f = try Fixture.init();
        defer f.deinit();
        try f.mkdir("server scripts");
        const path = try script(&f, "server scripts/server.sh",
            \\#!/bin/sh
            \\printf '%s\n' "$0"
            \\exec "$(dirname -- "$0")/sibling" "$1"
            \\
        );
        defer a.free(path);
        const sibling = try script(&f, "server scripts/sibling", "#!/bin/sh\nprintf 'sibling:%s' \"$1\"\n");
        defer a.free(sibling);
        // Only /bin/sh is descriptor-bound. The script argument and sibling
        // remain ordinary pathname dependencies, not verified executables.
        const exe = try capture("/bin/sh");
        defer exe.close();
        var cfg = config(exe, &.{ "/bin/sh", path, "literal argument" });
        cfg.environment = &.{.{ .name = "PATH", .value = "/usr/bin:/bin" }};
        const t = try transport.start(a, cfg);
        defer cleanup(t);
        var output: [512]u8 = undefined;
        const len = try wait(t, &output);
        const expected = try std.fmt.allocPrint(a, "{s}\nsibling:literal argument", .{path});
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, output[0..len]);
        try equal(transport.Outcome.success, t.result().?.outcome);
        try expect(t.result().?.reaped);
    }
    try equal(before, try descriptorCount());
}

test "verified exec never runs replacement after the approved pathname is unlinked" {
    const before = try descriptorCount();
    {
        var f = try Fixture.init();
        defer f.deinit();
        const path = try script(&f, "server", "#!/bin/sh\nprintf approved\n");
        defer a.free(path);
        const replacement = try script(&f, "replacement", "#!/bin/sh\nprintf replacement-ran\n");
        defer a.free(replacement);
        const exe = try capture(path);
        defer exe.close();
        // Unlink normally changes ctime and fails validation. Even on a
        // filesystem with coarse timestamps, only the held inode may run.
        try equal(@as(c_int, 0), std.c.unlink(path));
        try equal(@as(c_int, 0), std.c.link(replacement, path));
        const t = try transport.start(a, config(exe, &.{path}));
        defer cleanup(t);
        var output: [128]u8 = undefined;
        const len = try wait(t, &output);
        if (t.result().?.outcome == .success) {
            try std.testing.expectEqualStrings("approved", output[0..len]);
        } else {
            try equal(@as(usize, 0), len);
            try equal(transport.Outcome.spawn_failed, t.result().?.outcome);
            try equal(os.ESTALE, t.result().?.spawn_errno);
        }
    }
    try equal(before, try descriptorCount());
}

test "verified exec checks every expected metadata field in the child" {
    const before = try descriptorCount();
    {
        const exe = try capture("/bin/sh");
        defer exe.close();
        inline for (@typeInfo(executable.Identity).@"struct".field_names) |field| {
            var changed = exe;
            @field(changed.identity, field) ^= 1;
            const t = try transport.start(a, config(changed, &.{ "/bin/sh", "-c", "printf must-not-run" }));
            defer cleanup(t);
            var output: [128]u8 = undefined;
            try equal(@as(usize, 0), try wait(t, &output));
            try equal(transport.Outcome.spawn_failed, t.result().?.outcome);
            try equal(os.ESTALE, t.result().?.spawn_errno);
        }
    }
    try equal(before, try descriptorCount());
}

test "verified exec detects in-place size and mode changes before spawn" {
    var f = try Fixture.init();
    defer f.deinit();
    const path = try script(&f, "server", "#!/bin/sh\nprintf approved\n");
    defer a.free(path);
    for (0..2) |change| {
        const exe = try capture(path);
        defer exe.close();
        if (change == 0) {
            const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true });
            try expect(fd >= 0);
            defer _ = std.c.close(fd);
            try equal(@as(isize, 1), std.c.write(fd, "\n", 1));
        } else {
            try equal(@as(c_int, 0), std.c.chmod(path, 0o600));
        }
        const t = try transport.start(a, config(exe, &.{path}));
        defer cleanup(t);
        var output: [128]u8 = undefined;
        try equal(@as(usize, 0), try wait(t, &output));
        try equal(transport.Outcome.spawn_failed, t.result().?.outcome);
        try equal(os.ESTALE, t.result().?.spawn_errno);
    }
}

test "verified native exec succeeds without leaking its descriptor into the binary" {
    const exe = try capture("/bin/sh");
    defer exe.close();
    // argv[0] is deliberately nonexistent: there must be no pathname fallback.
    const t = try transport.start(a, config(exe, &.{ "/not/a/real/executable", "-c", "[ ! -e /proc/self/fd/5 ] || exit 92; printf native-ok" }));
    defer cleanup(t);
    var output: [128]u8 = undefined;
    const len = try wait(t, &output);
    try std.testing.expectEqualStrings("native-ok", output[0..len]);
    try equal(transport.Outcome.success, t.result().?.outcome);
    try expect(t.result().?.reaped);
}

test "verified script with missing interpreter fails safely without pathname fallback" {
    const before = try descriptorCount();
    {
        var f = try Fixture.init();
        defer f.deinit();
        const path = try script(&f, "server", "#!/coral/no-such-interpreter\nprintf must-not-run\n");
        defer a.free(path);
        const exe = try capture(path);
        defer exe.close();
        const t = try transport.start(a, config(exe, &.{ "/bin/sh", "-c", "printf fallback-must-not-run" }));
        defer cleanup(t);
        var output: [128]u8 = undefined;
        try equal(@as(usize, 0), try wait(t, &output));
        try equal(transport.Outcome.spawn_failed, t.result().?.outcome);
        try equal(os.ENOENT, t.result().?.spawn_errno);
    }
    try equal(before, try descriptorCount());
}

fn allocationAttempt(allocator: std.mem.Allocator, exe: executable.Verified) !void {
    const before = try descriptorCount();
    defer equal(before, descriptorCount() catch unreachable) catch @panic("descriptor leaked on allocation failure");
    const t = try transport.start(allocator, config(exe, &.{ "/bin/sh", "-c", "exit 0" }));
    defer cleanup(t);
    var output: [128]u8 = undefined;
    _ = try wait(t, &output);
    try equal(transport.Outcome.success, t.result().?.outcome);
}

test "verified transport preserves borrowed fd and closes owned fds on errors and cancellation" {
    const before = try descriptorCount();
    {
        const exe = try capture("/bin/sh");
        defer exe.close();
        try std.testing.checkAllAllocationFailures(a, allocationAttempt, .{exe});
        var cfg = config(exe, &.{ "/bin/sh", "-c", "read line" });
        cfg.authorization = .denied;
        try std.testing.expectError(error.Unauthorized, transport.start(a, cfg));
        cfg.authorization = .approved;
        for (0..8) |_| {
            const t = try transport.start(a, cfg);
            cleanup(t); // Cancellation on either side of the asynchronous fork.
            try expect(exe.identity.matches(exe.fd));
        }
        cfg.cwd = "/coral/no-such-working-directory";
        const t = try transport.start(a, cfg);
        defer cleanup(t);
        var output: [128]u8 = undefined;
        _ = try wait(t, &output);
        try equal(transport.Outcome.spawn_failed, t.result().?.outcome);
        cfg.executable.?.fd = -1;
        try std.testing.expectError(error.SystemResources, transport.start(a, cfg));
    }
    try equal(before, try descriptorCount());
}
