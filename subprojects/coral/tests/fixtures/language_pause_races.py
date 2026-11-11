"""Deterministic tests of current production pause/completion and poll-timeout code.

Invoked by language.py's pause-completion-races case. Source regions are extracted
verbatim on every run, never maintained as a second implementation. GTK/I/O owner
methods (including configReady's destructive paused delivery) and the clock are
fakes. The pump's config/timeout prefix and invalidation are also extracted
verbatim; session transport teardown is observed through a fake stopSession.
This covers exact timeout/completion ordering, not native GTK/worker integration;
the companion pause native cases cover real locks, shutdown and durable resume.
Generated source and region hashes are retained with the case evidence.
"""
from pathlib import Path
import argparse
import hashlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
controller = (root / 'src/language/controller.zig').read_text()
automatic = (root / 'src/language/automatic.zig').read_text()

def between(text, start, end):
    assert text.count(start) == text.count(end) == 1, ('production extraction anchors changed', start, end)
    return text[text.index(start):text.index(end, text.index(start))].rstrip()

finish = between(controller, 'fn finishConfigJob(', 'fn executableChanged(')
resume = between(controller, '    fn queuedResume(', '    fn dispatchNextConfig(')
dispatch = between(controller, '    fn dispatchNextConfig(', '    fn pump(')
pump = between(controller, '    fn pump(', '        if (self.resource) |request_resource| if (!request_resource.cancelled and !self.resourceCurrent(request_resource))')
invalidate = between(controller, '    pub fn invalidate(', '    fn stopSession(')
pause_code = between(automatic, 'const Pause = struct', 'const Review = struct')
same = between(automatic, 'pub fn same(', 'pub fn workspaceKey(')
source = '''const std = @import("std");
const automatic = struct {
    pub const Key = [32]u8;
    pub const limit = 128;
''' + same + '\n' + pause_code + '''
    pub fn release(_: *anyopaque, _: bool) void {}
};
var clock: i64 = 0;
const c = struct { fn g_get_monotonic_time() i64 { return clock; } };
var config_worker_busy = false;
var pending_pause_writes: usize = 0;
const ConfigKind = enum { poll, start, grant, launch, approve, pause };
const App = struct {
    closing: bool = false,
    holds: usize = 1,
    releases: usize = 0,
    fn hold(self: *App) void { self.holds += 1; }
    fn release(self: *App) void { self.holds -= 1; self.releases += 1; }
};
const ConfigJob = struct {
    owner: *Controller,
    kind: ConfigKind,
    workspace: automatic.Key = @splat(7),
    pause_revision: u64 = 0,
    pause_retry: automatic.PauseRetry = .{},
    started: bool = true,
    err: ?anyerror = null,
    generation: u64 = 1,
    screen: u64 = 1,
    timed_out: bool = false,
    deadline: i64 = 5_000_000,
    cancelled: std.atomic.Value(bool) = .init(false),
    destroyed: bool = false,
    fn destroy(self: *ConfigJob) void { std.debug.assert(!self.destroyed); self.destroyed = true; }
};
const Session = struct { restart: bool = true, stopped: bool = false };
const Controller = struct {
    app: *App,
    config_monitors_dirty: bool = false,
    sessions: [1]?*Session = @splat(null),
    pending: ?u64 = null,
    stopped_sessions: usize = 0,
    config_job: ?*ConfigJob = null,
    config_queued: ?*ConfigJob = null,
    pause_jobs: std.ArrayList(*ConfigJob) = .empty,
    config_generation: u64 = 1,
    screen_generation: u64 = 2,
    next_config_poll: i64 = 0,
    poll_deliveries: usize = 0,

    failures: usize = 0,
    dispatched: usize = 0,
    fn workspaceKey(_: *Controller) ?automatic.Key { return @splat(7); }
    fn failure(self: *Controller, _: anyerror) void { self.failures += 1; }
    fn clearScreen(self: *Controller) void {
        self.screen_generation += 1;
        if (self.config_queued) |next| next.destroy();
        self.config_queued = null;
    }
    fn clearNavigation(_: *Controller) void {}
    fn rearmConfigMonitors(_: *Controller) void {}
    fn startConfigWorker(_: *Controller, _: *ConfigJob) void {}
    fn stopSession(self: *Controller, session: *Session) void {
        self.stopped_sessions += 1;
        session.stopped = true;
    }
    fn configReady(self: *Controller, job: *ConfigJob) !void {
        if (job.kind == .pause) {
            automatic.pauseWritten(job.workspace, job.pause_revision);
        } else if (job.kind == .poll) {
            // Model the destructive paused-snapshot delivery: queued Start must
            // never reach this method through an older poll completion.
            self.poll_deliveries += 1;
            self.invalidate();
        }
    }
    fn dispatchConfig(self: *Controller, job: *ConfigJob) void {
        self.dispatched += 1;
        self.config_job = job;
        self.app.hold();
    }
''' + resume + '\n' + dispatch + '\n' + invalidate + '\n' + pump + '\n    }\n};\n' + finish + '''
fn reset() void {
    automatic.pause_len = 0;
    automatic.pause_saturated = false;
    config_worker_busy = false;
    pending_pause_writes = 0;
    clock = 0;
}
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

test "Busy retains job, hold, write ordering and bounded backoff until publication" {
    reset();
    var app: App = .{};
    var owner: Controller = .{ .app = &app };
    var stop: ConfigJob = .{ .owner = &owner, .kind = .pause, .pause_revision = try automatic.pause(@splat(7)) };
    var start: ConfigJob = .{ .owner = &owner, .kind = .start, .screen = 2 };
    owner.config_job = &stop;
    owner.config_queued = &start;
    pending_pause_writes = 1;
    for (0..16) |i| {
        config_worker_busy = true;
        stop.started = true;
        stop.err = error.Busy;
        finishConfigJob(&stop);
        try expect(owner.config_job == &stop and owner.config_queued == &start);
        try expect(!config_worker_busy and !stop.started and !stop.destroyed);
        try equal(@as(usize, 1), app.holds);
        try equal(@as(usize, 0), app.releases);
        try equal(@as(usize, 1), pending_pause_writes);
        try equal(i + 1, stop.pause_retry.attempts);
        try expect(stop.pause_retry.due - clock >= 50_000 and stop.pause_retry.due - clock <= 1_000_000);
        if (i >= 5) try equal(@as(i64, 1_000_000), stop.pause_retry.due - clock);
        try expect(!stop.pause_retry.ready(stop.pause_retry.due - 1));
        clock = stop.pause_retry.due;
        try expect(stop.pause_retry.ready(clock));
    }
    stop.started = true;
    stop.err = null;
    finishConfigJob(&stop);
    try expect(stop.destroyed and owner.config_job == &start);
    try equal(@as(usize, 1), owner.dispatched);
    try equal(@as(usize, 1), app.holds);
    try equal(@as(usize, 1), app.releases);
    try equal(@as(usize, 0), pending_pause_writes);
    try expect(automatic.paused(@splat(7)));
    try expect(!automatic.observePause(@splat(7), automatic.epoch(@splat(7)), false).?);
}

test "closing keeps Busy Stop hold but drops queued UI resume after publication" {
    reset();
    var app: App = .{ .closing = true };
    var owner: Controller = .{ .app = &app };
    var stop: ConfigJob = .{ .owner = &owner, .kind = .pause, .err = error.Busy, .pause_revision = try automatic.pause(@splat(7)) };
    var start: ConfigJob = .{ .owner = &owner, .kind = .start, .screen = 2 };
    owner.config_job = &stop;
    owner.config_queued = &start;
    pending_pause_writes = 1;
    finishConfigJob(&stop);
    try equal(@as(usize, 1), app.holds);
    try expect(!stop.destroyed and !start.destroyed);
    stop.err = null;
    finishConfigJob(&stop);
    try expect(stop.destroyed and start.destroyed);
    try equal(@as(usize, 0), app.holds);
    try equal(@as(usize, 0), pending_pause_writes);
    try expect(automatic.paused(@splat(7)));
}

test "nonretryable failure drains once and disk cannot clear unsaved Stop" {
    reset();
    var app: App = .{};
    var owner: Controller = .{ .app = &app };
    var stop: ConfigJob = .{ .owner = &owner, .kind = .pause, .err = error.Io, .pause_revision = try automatic.pause(@splat(7)) };
    owner.config_job = &stop;
    pending_pause_writes = 1;
    finishConfigJob(&stop);
    try equal(@as(usize, 1), owner.failures);
    try equal(@as(usize, 0), pending_pause_writes);
    try equal(@as(usize, 0), stop.pause_retry.attempts);
    try equal(@as(usize, 0), app.holds);
    try expect(stop.destroyed and owner.config_job == null);
    try expect(automatic.observePause(@splat(7), automatic.epoch(@splat(7)), false).?);
    try expect(automatic.unpause(@splat(7), stop.pause_revision));
    try expect(!automatic.paused(@splat(7)));
}

test "external resume clears acknowledged pause but pre-Stop and pre-ack snapshots cannot" {
    reset();
    const key: automatic.Key = @splat(7);
    const before_stop = automatic.epoch(key);
    const rev = try automatic.pause(key);
    const before_ack = automatic.epoch(key);
    try expect(automatic.observePause(key, before_stop, false) == null);
    try expect(automatic.observePause(key, before_ack, false).?);
    automatic.pauseWritten(key, rev);
    try expect(automatic.observePause(key, before_ack, false) == null);
    try expect(automatic.paused(key));
    const fresh = automatic.epoch(key);
    try expect(!automatic.observePause(key, fresh, false).?);
    try expect(!automatic.paused(key));
    try expect(automatic.observePause(key, fresh, true) == null);
    const new_rev = try automatic.pause(key);
    automatic.pauseWritten(key, rev); // older completion must not acknowledge new intent
    try expect(automatic.observePause(key, automatic.epoch(key), false).?);
    automatic.pauseFailed(key, new_rev);
    try expect(automatic.observePause(key, automatic.epoch(key), false).?);
}

test "old paused poll and old Busy poll yield to newer explicit Start" {
    inline for (.{ @as(?anyerror, null), @as(?anyerror, error.Busy) }) |err| {
        reset();
        var app: App = .{};
        var owner: Controller = .{ .app = &app };
        var poll: ConfigJob = .{ .owner = &owner, .kind = .poll, .err = err };
        var start: ConfigJob = .{ .owner = &owner, .kind = .start, .screen = 2 };
        owner.config_job = &poll;
        owner.config_queued = &start;
        finishConfigJob(&poll);
        try expect(poll.destroyed and !start.destroyed and owner.config_job == &start);
        try equal(@as(usize, 0), owner.poll_deliveries);
        try equal(@as(u64, 1), owner.config_generation);
        try equal(@as(usize, 0), owner.failures);
        try equal(@as(usize, 1), app.holds);
    }
}

test "pump timeout stops sessions but keeps newer Start queued until old worker drains" {
    reset();
    var app: App = .{};
    var session: Session = .{};
    var owner: Controller = .{ .app = &app, .sessions = .{&session} };
    var poll: ConfigJob = .{ .owner = &owner, .kind = .poll };
    var start: ConfigJob = .{ .owner = &owner, .kind = .start, .screen = 2, .started = false, .pause_revision = 42 };
    owner.config_job = &poll;
    owner.config_queued = &start;
    config_worker_busy = true;
    clock = poll.deadline - 1;
    owner.pump();
    try expect(!poll.timed_out and !session.stopped);
    try equal(@as(usize, 0), owner.failures);

    clock = poll.deadline;
    owner.pump();
    try expect(poll.timed_out and poll.cancelled.load(.acquire));
    try expect(session.stopped and !session.restart);
    try equal(@as(usize, 1), owner.stopped_sessions);
    try equal(@as(usize, 1), owner.failures);
    try expect(owner.config_job == &poll and owner.config_queued == &start);
    try expect(!start.destroyed and !start.started and !start.cancelled.load(.acquire));
    try equal(@as(u64, 2), owner.config_generation);
    try equal(@as(u64, 3), owner.screen_generation);
    try equal(owner.config_generation, start.generation);
    try equal(owner.screen_generation, start.screen);
    try equal(@as(u64, 42), start.pause_revision);
    try expect(automatic.same(@splat(7), start.workspace));
    try equal(@as(usize, 0), owner.dispatched);
    try equal(@as(usize, 1), app.holds);
    try expect(config_worker_busy);

    clock += 10_000_000;
    owner.pump();
    try equal(@as(usize, 1), owner.failures); // no repeated timeout/rebase
    try equal(@as(usize, 1), owner.stopped_sessions);
    try equal(@as(usize, 0), owner.dispatched);
    finishConfigJob(&poll);
    try expect(poll.destroyed and !start.destroyed and owner.config_job == &start);
    try equal(@as(usize, 1), owner.dispatched);
    try equal(@as(usize, 0), owner.poll_deliveries);
    try equal(@as(usize, 1), app.holds);
    try equal(@as(usize, 1), app.releases);
}

test "later invalidation still cancels Start preserved across poll timeout" {
    reset();
    var app: App = .{};
    var owner: Controller = .{ .app = &app };
    var poll: ConfigJob = .{ .owner = &owner, .kind = .poll };
    var start: ConfigJob = .{ .owner = &owner, .kind = .start, .screen = 2, .started = false };
    owner.config_job = &poll;
    owner.config_queued = &start;
    clock = poll.deadline;
    owner.pump();
    try expect(owner.config_queued == &start and !start.destroyed);
    owner.invalidate(); // e.g. trust revocation or workspace replacement
    try expect(start.destroyed and owner.config_queued == null);
    finishConfigJob(&poll);
    try equal(@as(usize, 0), owner.dispatched);
    try equal(@as(usize, 0), app.holds);
}

test "pump timeout does not preserve unrelated stale non-Start or closing intent" {
    for (0..5) |mismatch| {
        reset();
        var app: App = .{};
        var session: Session = .{};
        var owner: Controller = .{ .app = &app, .sessions = .{&session} };
        var poll: ConfigJob = .{ .owner = &owner, .kind = .poll };
        var start: ConfigJob = .{ .owner = &owner, .kind = .start, .screen = 2 };
        switch (mismatch) {
            0 => start.workspace = @splat(9),
            1 => start.generation = 0,
            2 => start.screen = 1,
            3 => start.kind = .launch,
            4 => app.closing = true,
            else => unreachable,
        }
        owner.config_job = &poll;
        owner.config_queued = &start;
        clock = poll.deadline;
        owner.pump();
        try expect(poll.timed_out and poll.cancelled.load(.acquire));
        try expect(session.stopped and !session.restart);
        try expect(start.destroyed and owner.config_queued == null);
        finishConfigJob(&poll);
        try equal(@as(usize, 0), owner.dispatched);
        try equal(@as(usize, 0), app.holds);
    }
}

test "unrelated or stale queued Start does not supersede current poll" {
    for (0..3) |mismatch| {
        reset();
        var app: App = .{};
        var owner: Controller = .{ .app = &app };
        var poll: ConfigJob = .{ .owner = &owner, .kind = .poll };
        var start: ConfigJob = .{ .owner = &owner, .kind = .start, .screen = 2 };
        switch (mismatch) {
            0 => start.workspace = @splat(9),
            1 => start.generation = 0,
            2 => start.screen = 1,
            else => unreachable,
        }
        owner.config_job = &poll;
        owner.config_queued = &start;
        finishConfigJob(&poll);
        try equal(@as(usize, 1), owner.poll_deliveries);
        try expect(start.destroyed and owner.config_job == null);
        try equal(@as(usize, 0), app.holds);
    }
}
'''
path = out / 'pause_races.zig'
path.write_text(source)
for name, body in [('finishConfigJob', finish), ('queuedResume', resume), ('dispatchNextConfig', dispatch),
                   ('pump-config-timeout-prefix', pump), ('invalidate', invalidate), ('pause-state-and-backoff', pause_code)]:
    print(name, hashlib.sha256(body.encode()).hexdigest(), flush=True)
subprocess.run(['zig', 'test', str(path), '-O', 'safe'], cwd=root, check=True, timeout=60)
