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

test "workspace tokens reject real late process callbacks while preserving reaping" {
    const identity = @import("../workspace/identity.zig");
    const Routed = struct {
        seen: Seen,
        scope: *const identity.Scope,
        expected: identity.Token,
        accepted: bool = false,
        reaped: bool = false,
        echoed: bool = false,

        fn complete(job: *process.Job, result: process.Result, data: ?*anyopaque) void {
            const self = u.cast(@This(), data.?);
            defer job.destroy(); // Rejected payloads still release all job storage.
            Seen.complete(job, result, &self.seen);
            self.reaped = result.reaped;
            const token = result.identity.workspace orelse return;
            self.echoed = std.meta.eql(self.expected, token);
            self.accepted = self.scope.accepts(token);
        }
    };
    const h = try Harness.init("printf 'late payload'\n");
    defer h.deinit();
    for (0..4) |scenario| {
        var source = identity.Scope.init();
        var other = identity.Scope.init();
        var supervisor: process.Supervisor = .{};
        const token = source.capture().?;
        var routed = Routed{ .seen = .{ .context = h.context }, .scope = if (scenario == 3) &other else &source, .expected = token };
        var cfg = h.config(&.{ "/bin/sh", h.script });
        cfg.owner = &supervisor;
        cfg.identity.workspace = token;
        _ = try process.start(a, cfg, Routed.complete, &routed);
        // Completion cannot run until we iterate the submitting context. No
        // sleeps or timing assumptions are needed to make the result late.
        switch (scenario) {
            1 => source.invalidate(),
            2 => source.close(),
            else => {},
        }
        cfg.identity.workspace = other.capture(); // The job owns a value copy.
        try h.wait(&routed.seen);
        try std.testing.expect(routed.echoed);
        try std.testing.expect(routed.reaped);
        try std.testing.expect(supervisor.isIdle());
        try std.testing.expectEqual(scenario == 0, routed.accepted);
    }
}

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

test "capture normal leader exit cleans background child without waiting for pipe EOF" {
    const h = try Harness.init("/bin/sleep 0.3 &\nprintf done\nexit 0\n");
    defer h.deinit();

    var seen = Seen{ .context = h.context };
    var cfg = h.config(&.{ "/bin/sh", h.script });
    cfg.timeout_ms = 2000;
    const job = try process.start(a, cfg, Seen.complete, &seen);
    defer job.destroy();
    try h.wait(&seen);
    try std.testing.expectEqual(process.Outcome.success, job.result().outcome);
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

const os = @import("../terminal/ownership.zig").os;

fn waitForReady(h: Harness, job: *process.Job) !void {
    const deadline = c.g_get_monotonic_time() + 2_000_000;
    while (std.mem.indexOf(u8, job.storage[0..job.stdout_len], "READY\n") == null) {
        _ = c.g_main_context_iteration(h.context, 0);
        if (job.isComplete() or c.g_get_monotonic_time() > deadline) return error.FixtureNotReady;
        c.g_usleep(1000);
    }
}

// Each fixture descendant ignores TERM and would write a delayed sentinel if
// direct-child-only cancellation, missed leader exit, or missing KILL regressed.
// The readiness file ensures the descendant installed its traps before the
// leader exits; the output barrier makes cancellation independent of spawn time.
const tree_fixture =
    \\trap '' TERM
    \\( trap '' TERM; printf ready > child-ready; /bin/sleep 0.8; printf survived > sentinel ) &
    \\printf '%s\n' "$!"
    \\while [ ! -f child-ready ]; do /bin/sleep 0.005; done
    \\printf 'READY\n'
    \\case "$1" in
    \\  normal) exit 0 ;;
    \\  flood) while :; do printf 'overflow bytes\n'; done ;;
    \\  *) wait ;;
    \\esac
;

fn treeCase(mode: []const u8, outcome: process.Outcome) !void {
    const h = try Harness.init(tree_fixture);
    defer h.deinit();
    const sentinel = try std.fmt.allocPrintSentinel(a, "{s}/sentinel", .{h.directory}, 0);
    defer a.free(sentinel);
    defer _ = c.g_unlink(sentinel);
    const ready = try std.fmt.allocPrintSentinel(a, "{s}/child-ready", .{h.directory}, 0);
    defer a.free(ready);
    defer _ = c.g_unlink(ready);
    var seen = Seen{ .context = h.context };
    var owner = process.Supervisor{};
    var cfg = h.config(&.{ "/bin/sh", h.script, mode });
    cfg.owner = &owner;
    if (outcome == .timed_out) cfg.timeout_ms = 250;
    if (outcome == .output_limit) cfg.output_limit = 64;
    const job = try process.start(a, cfg, Seen.complete, &seen);
    defer job.destroy();
    if (outcome == .cancelled) {
        try waitForReady(h, job);
        if (std.mem.eql(u8, mode, "shutdown")) {
            owner.shutdown();
            owner.shutdown();
        } else {
            job.cancel();
            job.cancel();
        }
    }
    try h.wait(&seen);
    try std.testing.expect(owner.isIdle());
    const result = job.result();
    try std.testing.expectEqual(outcome, result.outcome);
    try std.testing.expect(result.reaped);
    try std.testing.expect(job.out.done and job.err.done);
    if (outcome == .cancelled or outcome == .timed_out)
        try std.testing.expectEqual(@as(?c_int, os.KILL), result.term_signal);
    // Reaped descendants are not lingering zombies under the host/init.
    const newline = std.mem.indexOfScalar(u8, result.stdout, '\n') orelse return error.MissingChildPid;
    const descendant = try std.fmt.parseInt(c_int, result.stdout[0..newline], 10);
    try std.testing.expect(os.kill(descendant, 0) < 0);
    try std.testing.expectEqual(@as(c_int, 3), os.errno()); // ESRCH
    c.g_usleep(900000);
    try std.testing.expect(c.g_file_test(sentinel, c.G_FILE_TEST_EXISTS) == 0);
    job.cancel(); // never signal a stale/reused process group after completion
    try std.testing.expectEqual(@as(usize, 1), seen.count);
}

test "capture cancellation kills and reaps actual shell descendants before delayed sentinel" {
    try treeCase("cancel", .cancelled);
}

test "capture shutdown kills and reaps actual shell descendants before delayed sentinel" {
    try treeCase("shutdown", .cancelled);
}

test "capture timeout kills and reaps actual shell descendants before delayed sentinel" {
    try treeCase("timeout", .timed_out);
}

test "capture normal leader exit kills and reaps background descendants before delayed sentinel" {
    try treeCase("normal", .success);
}

test "capture output limit kills and reaps shell descendants before delayed sentinel" {
    try treeCase("flood", .output_limit);
}

test "capture supervisor shutdown cancels owned jobs only, including spawn race" {
    const h = try Harness.init("printf 'READY\\n'; /bin/sleep 0.4; printf alive\n");
    defer h.deinit();
    for ([_]bool{ false, true }) |running| {
        var owner = process.Supervisor{};
        var first_seen = Seen{ .context = h.context };
        var second_seen = Seen{ .context = h.context, .destroy_in_callback = true };
        var unrelated_seen = Seen{ .context = h.context };
        var cfg = h.config(&.{ "/bin/sh", h.script });
        const unrelated = try process.start(a, cfg, Seen.complete, &unrelated_seen);
        defer unrelated.destroy();
        cfg.owner = &owner;
        const first = try process.start(a, cfg, Seen.complete, &first_seen);
        defer first.destroy();
        const second = try process.start(a, cfg, Seen.complete, &second_seen);
        try std.testing.expect(!owner.isIdle());
        if (running) {
            try waitForReady(h, first);
            try waitForReady(h, second);
        }
        owner.shutdown();
        owner.shutdown();
        try std.testing.expectError(error.ShuttingDown, process.start(a, cfg, Seen.complete, &first_seen));
        try h.wait(&first_seen);
        try h.wait(&second_seen);
        try std.testing.expect(owner.isIdle());
        try std.testing.expectEqual(process.Outcome.cancelled, first.result().outcome);
        try h.wait(&unrelated_seen);
        try std.testing.expectEqual(process.Outcome.success, unrelated.result().outcome);
        try std.testing.expectEqualStrings("READY\nalive", unrelated.result().stdout);
    }
}

test "capture TERM grace allows cleanup before bounded KILL escalation" {
    const h = try Harness.init(
        \\trap 'printf graceful > term-marker; exit 0' TERM
        \\printf 'READY\n'
        \\while :; do :; done
    );
    defer h.deinit();
    const marker = try std.fmt.allocPrintSentinel(a, "{s}/term-marker", .{h.directory}, 0);
    defer a.free(marker);
    defer _ = c.g_unlink(marker);
    var seen = Seen{ .context = h.context };
    const job = try process.start(a, h.config(&.{ "/bin/sh", h.script }), Seen.complete, &seen);
    defer job.destroy();
    try waitForReady(h, job);
    const began = c.g_get_monotonic_time();
    job.cancel();
    try h.wait(&seen);
    try std.testing.expect(c.g_get_monotonic_time() - began < 2_000_000);
    try std.testing.expectEqual(process.Outcome.cancelled, job.result().outcome);
    try std.testing.expectEqual(@as(?c_int, 0), job.result().exit_code);
    try std.testing.expect(c.g_file_test(marker, c.G_FILE_TEST_EXISTS) != 0);
}
