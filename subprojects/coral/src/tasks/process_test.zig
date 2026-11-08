//! Headless tests: no GTK initialization, display server, or application shell.
//! /bin/sh interprets only temporary, fixed test fixture files. Untrusted test
//! values are separate argv elements, never interpolated into fixture source.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const process = @import("process.zig");
const a = std.testing.allocator;

const Harness = struct {
    context: *c.GMainContext,
    directory: [:0]u8,
    script: [:0]u8,

    fn init(source: []const u8) !Harness {
        const dir = c.g_dir_make_tmp("coral-process-XXXXXX", null) orelse return error.TempDirectory;
        defer c.g_free(dir);
        const directory = try a.dupeSentinel(u8, std.mem.span(dir), 0);
        errdefer a.free(directory);
        errdefer _ = c.g_rmdir(directory);
        const script = try std.fmt.allocPrintSentinel(a, "{s}/fixture.sh", .{directory}, 0);
        errdefer a.free(script);
        if (c.g_file_set_contents(script, source.ptr, @intCast(source.len), null) == 0) return error.WriteFixture;
        const context = c.g_main_context_new().?;
        c.g_main_context_push_thread_default(context);
        return .{ .context = context, .directory = directory, .script = script };
    }

    fn deinit(self: Harness) void {
        c.g_main_context_pop_thread_default(self.context);
        c.g_main_context_unref(self.context);
        _ = c.g_unlink(self.script);
        _ = c.g_rmdir(self.directory);
        a.free(self.script);
        a.free(self.directory);
    }

    fn config(self: Harness, argv: []const []const u8) process.Config {
        return .{
            .authorization = .approved,
            .identity = .{ .scope = "workspace-A", .request = 42, .generation = 7 },
            .argv = argv,
            .cwd = self.directory,
            .timeout_ms = 3000,
        };
    }

    fn wait(self: Harness, seen: *Seen) !void {
        const until = c.g_get_monotonic_time() + 5_000_000;
        while (seen.count == 0) {
            _ = c.g_main_context_iteration(self.context, 0);
            if (c.g_get_monotonic_time() > until) @panic("capture completion watchdog expired");
            c.g_usleep(1000);
        }
        // Give stale timeout/task/read callbacks an opportunity to fire.
        for (0..15) |_| {
            _ = c.g_main_context_iteration(self.context, 0);
            c.g_usleep(1000);
        }
        try std.testing.expectEqual(@as(usize, 1), seen.count);
        try std.testing.expect(seen.on_context);
    }
};

const Seen = struct {
    context: *c.GMainContext,
    count: usize = 0,
    on_context: bool = false,
    destroy_in_callback: bool = false,

    fn complete(job: *process.Job, result: process.Result, data: ?*anyopaque) void {
        const self = u.cast(Seen, data.?);
        self.count += 1;
        self.on_context = c.g_main_context_is_owner(self.context) != 0;
        std.debug.assert(job.isComplete());
        std.debug.assert(result.identity.request == 42);
        std.debug.assert(result.identity.generation == 7);
        if (self.destroy_in_callback) job.destroy();
    }
};

test "capture owns request, preserves literal argv, cwd and explicit environment" {
    const h = try Harness.init(
        \\printf '%s\n' "$1" "$PWD" "$ALLOWED" "${CORAL_PROCESS_TEST_SECRET-unset}" "${HOME-unset}"
        \\printf 'error bytes' >&2
        \\if read line; then exit 9; fi
    );
    defer h.deinit();
    // Environment mutation is confined to this sequential headless test. The
    // child must not receive even a variable present in the parent at submit.
    const old = c.g_strdup(c.g_getenv("CORAL_PROCESS_TEST_SECRET"));
    defer {
        if (old != null) {
            _ = c.g_setenv("CORAL_PROCESS_TEST_SECRET", old, 1);
            c.g_free(old);
        } else c.g_unsetenv("CORAL_PROCESS_TEST_SECRET");
    }
    try std.testing.expect(c.g_setenv("CORAL_PROCESS_TEST_SECRET", "do-not-inherit", 1) != 0);
    const literal = try a.dupe(u8, "$(touch nope); * ' spaces");
    const scope = try a.dupe(u8, "workspace-A");
    const allowed = try a.dupe(u8, "allowlisted-value");
    var seen = Seen{ .context = h.context };
    var cfg = h.config(&.{ "/bin/sh", h.script, literal });
    cfg.identity.scope = scope;
    cfg.environment = &.{.{ .name = "ALLOWED", .value = allowed }};
    const job = try process.start(a, cfg, Seen.complete, &seen);
    defer job.destroy();
    @memset(literal, '?');
    @memset(scope, '?');
    @memset(allowed, '?');
    a.free(literal);
    a.free(scope);
    a.free(allowed);
    try std.testing.expectEqual(@as(usize, 0), seen.count);
    try h.wait(&seen);
    const result = job.result();
    try std.testing.expectEqual(process.Outcome.success, result.outcome);
    try std.testing.expect(result.reaped);
    try std.testing.expectEqualStrings("workspace-A", result.identity.scope);
    const expected = try std.fmt.allocPrint(a, "$(touch nope); * ' spaces\n{s}\nallowlisted-value\nunset\nunset\n", .{h.directory});
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqualStrings("error bytes", result.stderr);
    const marker = try std.fmt.allocPrintSentinel(a, "{s}/nope", .{h.directory}, 0);
    defer a.free(marker);
    try std.testing.expect(c.g_file_test(marker, c.G_FILE_TEST_EXISTS) == 0);
    job.cancel(); // harmless after completion; result is stable
    try std.testing.expectEqual(process.Outcome.success, job.result().outcome);
}

test "capture drains both pipes beyond pipe capacity and exposes nonzero exit" {
    const h = try Harness.init(
        \\i=0
        \\while [ "$i" -lt 6000 ]; do
        \\  printf '0123456789abcdef'
        \\  printf 'fedcba9876543210' >&2
        \\  i=$((i + 1))
        \\done
        \\exit 23
    );
    defer h.deinit();
    var seen = Seen{ .context = h.context };
    const job = try process.start(a, h.config(&.{ "/bin/sh", h.script }), Seen.complete, &seen);
    defer job.destroy();
    try h.wait(&seen);
    const result = job.result();
    try std.testing.expectEqual(process.Outcome.nonzero, result.outcome);
    try std.testing.expectEqual(@as(?c_int, 23), result.exit_code);
    try std.testing.expect(result.reaped);
    try std.testing.expectEqual(@as(usize, 96000), result.stdout.len);
    try std.testing.expectEqual(@as(usize, 96000), result.stderr.len);
    for (0..6000) |i| {
        try std.testing.expectEqualStrings("0123456789abcdef", result.stdout[i * 16 ..][0..16]);
        try std.testing.expectEqualStrings("fedcba9876543210", result.stderr[i * 16 ..][0..16]);
    }
}

test "capture caps output, kills flood and completes exactly once" {
    const h = try Harness.init(
        \\while :; do
        \\  printf 'stdout flooding\n'
        \\  printf 'stderr flooding\n' >&2
        \\done
    );
    defer h.deinit();
    for ([_]usize{ 0, 1, 32768 }) |limit| {
        var seen = Seen{ .context = h.context };
        var cfg = h.config(&.{ "/bin/sh", h.script });
        cfg.output_limit = limit;
        const job = try process.start(a, cfg, Seen.complete, &seen);
        defer job.destroy();
        try h.wait(&seen);
        const result = job.result();
        try std.testing.expectEqual(process.Outcome.output_limit, result.outcome);
        try std.testing.expectEqual(limit, result.stdout.len + result.stderr.len);
        try std.testing.expect(result.reaped);
    }
}

test "capture exactly full budget is not overflow" {
    const h = try Harness.init("printf '123'; printf 'abc' >&2\n");
    defer h.deinit();
    var seen = Seen{ .context = h.context };
    var cfg = h.config(&.{ "/bin/sh", h.script });
    cfg.output_limit = 6;
    const job = try process.start(a, cfg, Seen.complete, &seen);
    defer job.destroy();
    try h.wait(&seen);
    try std.testing.expectEqual(process.Outcome.success, job.result().outcome);
    try std.testing.expectEqualStrings("123", job.result().stdout);
    try std.testing.expectEqualStrings("abc", job.result().stderr);
}

test "capture timeout remains active after pipes close and reaps child" {
    const h = try Harness.init(
        \\exec 1>&- 2>&-
        \\while :; do :; done
    );
    defer h.deinit();
    var seen = Seen{ .context = h.context };
    var cfg = h.config(&.{ "/bin/sh", h.script });
    cfg.timeout_ms = 40;
    const job = try process.start(a, cfg, Seen.complete, &seen);
    defer job.destroy();
    try h.wait(&seen);
    try std.testing.expectEqual(process.Outcome.timed_out, job.result().outcome);
    try std.testing.expect(job.result().reaped);
}

test "capture cancels before spawn handoff and while running" {
    const h = try Harness.init("printf ready; while :; do :; done\n");
    defer h.deinit();
    for ([_]bool{ false, true }) |running| {
        var seen = Seen{ .context = h.context };
        var cfg = h.config(&.{ "/bin/sh", h.script });
        if (!running) cfg.timeout_ms = 1;
        const job = try process.start(a, cfg, Seen.complete, &seen);
        defer job.destroy();
        if (running) {
            const until = c.g_get_monotonic_time() + 2_000_000;
            while (job.stdout_len == 0) {
                _ = c.g_main_context_iteration(h.context, 0);
                if (c.g_get_monotonic_time() > until) @panic("fixture did not start");
                c.g_usleep(1000);
            }
        }
        job.cancel();
        job.cancel();
        try h.wait(&seen);
        try std.testing.expectEqual(process.Outcome.cancelled, job.result().outcome);
        if (running or job.process != null) try std.testing.expect(job.result().reaped);
    }
}

test "capture spawn failure is asynchronous and callback can destroy job" {
    const h = try Harness.init("exit 0\n");
    defer h.deinit();
    const missing = try std.fmt.allocPrint(a, "{s}/missing-executable", .{h.directory});
    defer a.free(missing);
    var seen = Seen{ .context = h.context };
    const job = try process.start(a, h.config(&.{missing}), Seen.complete, &seen);
    defer job.destroy();
    try std.testing.expectEqual(@as(usize, 0), seen.count);
    try h.wait(&seen);
    try std.testing.expectEqual(process.Outcome.spawn_failed, job.result().outcome);
    try std.testing.expect(!job.result().reaped);
    try std.testing.expect(job.result().error_message.len > 0);
    var destroys = Seen{ .context = h.context, .destroy_in_callback = true };
    _ = try process.start(a, h.config(&.{ "/bin/sh", h.script }), Seen.complete, &destroys);
    try h.wait(&destroys);
}

test "capture unauthorized and malformed requests never spawn or callback" {
    const h = try Harness.init("printf unauthorized > marker\n");
    defer h.deinit();
    var seen = Seen{ .context = h.context };
    var cfg = h.config(&.{ "/bin/sh", h.script });
    cfg.authorization = .denied;
    try std.testing.expectError(error.Unauthorized, process.start(a, cfg, Seen.complete, &seen));
    cfg.authorization = .approved;
    cfg.cwd = ".";
    try std.testing.expectError(error.InvalidConfig, process.start(a, cfg, Seen.complete, &seen));
    cfg.cwd = h.directory;
    cfg.argv = &.{ "sh", h.script };
    try std.testing.expectError(error.InvalidConfig, process.start(a, cfg, Seen.complete, &seen));
    cfg.argv = &.{ "/bin/sh", h.script, "embedded\x00nul" };
    try std.testing.expectError(error.InvalidConfig, process.start(a, cfg, Seen.complete, &seen));
    cfg.argv = &.{ "/bin/sh", h.script };
    cfg.environment = &.{ .{ .name = "A", .value = "1" }, .{ .name = "A", .value = "2" } };
    try std.testing.expectError(error.InvalidConfig, process.start(a, cfg, Seen.complete, &seen));
    cfg.environment = &.{.{ .name = "A=B", .value = "1" }};
    try std.testing.expectError(error.InvalidConfig, process.start(a, cfg, Seen.complete, &seen));
    cfg.environment = &.{};
    cfg.timeout_ms = 0;
    try std.testing.expectError(error.InvalidConfig, process.start(a, cfg, Seen.complete, &seen));
    for (0..20) |_| _ = c.g_main_context_iteration(h.context, 0);
    try std.testing.expectEqual(@as(usize, 0), seen.count);
    const marker = try std.fmt.allocPrintSentinel(a, "{s}/marker", .{h.directory}, 0);
    defer a.free(marker);
    try std.testing.expect(c.g_file_test(marker, c.G_FILE_TEST_EXISTS) == 0);
}

fn allocationAttempt(allocator: std.mem.Allocator, h: Harness) !void {
    var seen = Seen{ .context = h.context };
    var cfg = h.config(&.{ "/bin/sh", h.script });
    cfg.environment = &.{.{ .name = "SAFE", .value = "value" }};
    const job = try process.start(allocator, cfg, Seen.complete, &seen);
    defer job.destroy();
    try h.wait(&seen);
    try std.testing.expectEqual(process.Outcome.success, job.result().outcome);
}

test "capture cleans up every synchronous allocation failure" {
    const h = try Harness.init("exit 0\n");
    defer h.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationAttempt, .{h});
}

test "capture preserves binary bytes and reports signal termination" {
    const h = try Harness.init("printf 'a\\000b'; printf 'c\\000d' >&2; kill -TERM $$\n");
    defer h.deinit();
    var seen = Seen{ .context = h.context };
    const job = try process.start(a, h.config(&.{ "/bin/sh", h.script }), Seen.complete, &seen);
    defer job.destroy();
    try h.wait(&seen);
    try std.testing.expectEqual(process.Outcome.signaled, job.result().outcome);
    try std.testing.expectEqual(@as(?c_int, 15), job.result().term_signal);
    try std.testing.expect(job.result().reaped);
    try std.testing.expectEqualStrings("a\x00b", job.result().stdout);
    try std.testing.expectEqualStrings("c\x00d", job.result().stderr);
}

test "capture timeout closes pipes retained by a finite descendant" {
    const h = try Harness.init("/bin/sleep 0.3 &\nprintf done\nexit 0\n");
    defer h.deinit();
    // This intentionally is not process-tree supervision. Let the finite
    // fixture helper exit before the test ends, even if an assertion fails.
    defer c.g_usleep(350000);
    var seen = Seen{ .context = h.context };
    var cfg = h.config(&.{ "/bin/sh", h.script });
    cfg.timeout_ms = 60;
    const job = try process.start(a, cfg, Seen.complete, &seen);
    defer job.destroy();
    try h.wait(&seen);
    try std.testing.expectEqual(process.Outcome.timed_out, job.result().outcome);
    try std.testing.expectEqual(@as(?c_int, 0), job.result().exit_code);
    try std.testing.expectEqualStrings("done", job.result().stdout);
    try std.testing.expect(job.result().reaped);
}

test "capture concurrent jobs retain their submitting context" {
    const h = try Harness.init("printf '%s' \"$1\"\n");
    defer h.deinit();
    var first_seen = Seen{ .context = h.context };
    var second_seen = Seen{ .context = h.context };
    const first = try process.start(a, h.config(&.{ "/bin/sh", h.script, "first" }), Seen.complete, &first_seen);
    defer first.destroy();
    const second = try process.start(a, h.config(&.{ "/bin/sh", h.script, "second" }), Seen.complete, &second_seen);
    defer second.destroy();
    // The context dispatched below is deliberately NOT the thread default
    // anymore. Follow-up reads/waits must still target the captured context.
    const other = c.g_main_context_new().?;
    defer c.g_main_context_unref(other);
    c.g_main_context_push_thread_default(other);
    defer c.g_main_context_pop_thread_default(other);
    try h.wait(&first_seen);
    try h.wait(&second_seen);
    try std.testing.expectEqualStrings("first", first.result().stdout);
    try std.testing.expectEqualStrings("second", second.result().stdout);
}
