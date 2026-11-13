//! M6 agent core integration suite (GTK-free, offline, disposable temp dirs).
//!   zig test -lc src/agent_core_tests.zig
//! Requires Linux, /bin/sh, /bin/sleep. No host writes outside temp dirs and
//! no live network. The parent may import this root from a libc-linked module.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const engine_mod = @import("agent/engine.zig");
const provider = @import("agent/provider.zig");
const context = @import("agent/context.zig");
const policy_mod = @import("agent/policy.zig");
const review = @import("agent/review.zig");
const thread_mod = @import("agent/thread.zig");
const store_mod = @import("agent/store.zig");
const auth = @import("agent/auth.zig");
const skills_mod = @import("agent/skills.zig");
const tools = @import("agent/tools.zig");
const test_host = @import("agent/test_host.zig");

const Engine = engine_mod.Engine;
const FakeHost = test_host.FakeHost;

test {
    _ = @import("agent/cancel.zig");
    _ = @import("agent/host.zig");
    _ = @import("agent/auth.zig");
    _ = @import("agent/context.zig");
    _ = @import("agent/policy.zig");
    _ = @import("agent/review.zig");
    _ = @import("agent/thread.zig");
    _ = @import("agent/store.zig");
    _ = @import("agent/provider.zig");
    _ = @import("agent/skills.zig");
    _ = @import("agent/tools.zig");
    _ = @import("agent/test_host.zig");
    _ = @import("agent/engine.zig");
}

const Fixture = struct {
    allocator: Allocator,
    tmp: std.testing.TmpDir,
    threaded: Io.Threaded,
    fh: FakeHost,
    engine: *Engine,
    root: [:0]u8,

    fn init(a: Allocator) !*Fixture {
        const self = try a.create(Fixture);
        errdefer a.destroy(self);
        self.allocator = a;
        self.tmp = std.testing.tmpDir(.{});
        self.threaded = Io.Threaded.init(a, .{});
        const io_local = self.threaded.io();
        self.root = try self.tmp.dir.realPathFileAlloc(io_local, ".", a);
        self.fh = FakeHost.init(a, io_local);
        const state_dir = try std.fs.path.join(a, &.{ self.root, "state" });
        defer a.free(state_dir);
        self.engine = try Engine.init(a, self.fh.asHost(), .{ .state_dir = state_dir });
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.engine.deinit();
        self.fh.deinit();
        self.allocator.free(self.root);
        self.tmp.cleanup();
        self.threaded.deinit();
        self.allocator.destroy(self);
    }

    fn io(self: *Fixture) Io {
        return self.threaded.io();
    }

    fn path(self: *Fixture, rel: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.root, rel });
    }

    fn writeFile(self: *Fixture, rel: []const u8, content: []const u8) !void {
        const p = try self.path(rel);
        defer self.allocator.free(p);
        try Io.Dir.cwd().writeFile(self.io(), .{ .sub_path = p, .data = content });
    }
};

fn sleepMs(io: Io, ms: i64) void {
    Io.sleep(io, Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn drivePermission(engine: *Engine, io: Io, tid: []const u8, decision: engine_mod.PermissionResponse) !void {
    var attempts: usize = 0;
    while (attempts < 5000) : (attempts += 1) {
        if (engine.pollEvent()) |e| {
            if (e == .permission_request) {
                const pr = e.permission_request;
                defer engine.freeEvent(e);
                try engine.respondPermission(tid, pr.request_id, decision);
                return;
            }
            engine.freeEvent(e);
        } else {
            sleepMs(io, 1);
        }
    }
    return error.PermissionTimeout;
}

/// Drain events and return the first review_proposed id (caller owns).
fn takeReviewId(engine: *Engine, a: Allocator) ?[]u8 {
    var result: ?[]u8 = null;
    while (engine.pollEvent()) |e| {
        if (e == .review_proposed and result == null) {
            result = a.dupe(u8, e.review_proposed.review_id) catch null;
        }
        engine.freeEvent(e);
    }
    return result;
}

fn drain(engine: *Engine) void {
    while (engine.pollEvent()) |e| engine.freeEvent(e);
}

test "fake provider streams text into assistant message and events" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const steps = [_]provider.Step{ .{ .text = "Hello " }, .{ .text = "world" } };
    const tid = try f.engine.newThread(.{ .provider = .{ .fake = .{ .steps = &steps } } });
    defer a.free(tid);
    try f.engine.send(tid, "hi", &.{});
    f.engine.waitIdle(tid);
    try std.testing.expectEqual(thread_mod.State.idle, f.engine.threadState(tid).?);

    var saw_delta = false;
    var done = false;
    while (f.engine.pollEvent()) |e| {
        if (e == .delta) saw_delta = true;
        if (e == .message_done) done = true;
        f.engine.freeEvent(e);
    }
    try std.testing.expect(saw_delta);
    try std.testing.expect(done);
}

test "read_file tool executes via host callback" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    try f.writeFile("data.txt", "file contents");
    const steps = [_]provider.Step{.{ .tool_call = .{ .id = "c1", .name = "read_file", .arguments_json = "{\"path\":\"data.txt\"}" } }};
    const tid = try f.engine.newThread(.{ .provider = .{ .fake = .{ .steps = &steps } }, .worktree = .{ .root = f.root } });
    defer a.free(tid);
    try f.engine.send(tid, "read it", &.{});
    f.engine.waitIdle(tid);
    try std.testing.expectEqual(@as(usize, 1), f.fh.read_count);
    var found = false;
    while (f.engine.pollEvent()) |e| {
        if (e == .tool_finished) {
            try std.testing.expect(e.tool_finished.ok);
            try std.testing.expectEqualStrings("file contents", e.tool_finished.output);
            found = true;
        }
        f.engine.freeEvent(e);
    }
    try std.testing.expect(found);
}

test "permission allow runs terminal; deny has no side effect" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const steps = [_]provider.Step{.{ .tool_call = .{ .id = "c1", .name = "run_terminal", .arguments_json = "{\"command\":\"echo allowed\"}" } }};
    const tid = try f.engine.newThread(.{ .provider = .{ .fake = .{ .steps = &steps } } });
    defer a.free(tid);
    try f.engine.send(tid, "run", &.{});
    try drivePermission(f.engine, f.io(), tid, .allow);
    f.engine.waitIdle(tid);
    try std.testing.expectEqual(@as(usize, 1), f.fh.spawn_count);
    drain(f.engine);

    // Deny: a fresh thread must not spawn anything.
    const tid2 = try f.engine.newThread(.{ .provider = .{ .fake = .{ .steps = &steps } } });
    defer a.free(tid2);
    const before = f.fh.spawn_count;
    try f.engine.send(tid2, "run", &.{});
    try drivePermission(f.engine, f.io(), tid2, .deny);
    f.engine.waitIdle(tid2);
    try std.testing.expectEqual(before, f.fh.spawn_count);
    var denied = false;
    while (f.engine.pollEvent()) |e| {
        if (e == .tool_finished and std.mem.eql(u8, e.tool_finished.output, "permission denied")) denied = true;
        f.engine.freeEvent(e);
    }
    try std.testing.expect(denied);
}

test "policy deny produces no host side effect" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    try f.engine.policy.set("run_terminal", .deny);
    const steps = [_]provider.Step{.{ .tool_call = .{ .id = "c1", .name = "run_terminal", .arguments_json = "{\"command\":\"echo nope\"}" } }};
    const tid = try f.engine.newThread(.{ .provider = .{ .fake = .{ .steps = &steps } } });
    defer a.free(tid);
    try f.engine.send(tid, "run", &.{});
    f.engine.waitIdle(tid);
    try std.testing.expectEqual(@as(usize, 0), f.fh.spawn_count);
    var denied = false;
    while (f.engine.pollEvent()) |e| {
        if (e == .tool_finished and std.mem.eql(u8, e.tool_finished.output, "denied by policy")) denied = true;
        f.engine.freeEvent(e);
    }
    try std.testing.expect(denied);
}

test "propose_edit review accept writes files and creates checkpoint" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    try f.writeFile("a.txt", "original");
    const steps = [_]provider.Step{.{ .tool_call = .{ .id = "c1", .name = "propose_edit", .arguments_json = "{\"title\":\"Edit\",\"files\":[{\"path\":\"a.txt\",\"content\":\"changed\"}]}" } }};
    const tid = try f.engine.newThread(.{ .provider = .{ .fake = .{ .steps = &steps } }, .worktree = .{ .root = f.root } });
    defer a.free(tid);
    try f.engine.send(tid, "edit", &.{});
    f.engine.waitIdle(tid);
    const rid = takeReviewId(f.engine, a) orelse return error.NoReview;
    defer a.free(rid);
    try std.testing.expectEqual(@as(usize, 0), f.fh.write_count); // proposal does not write
    try f.engine.acceptReview(tid, rid);
    try std.testing.expectEqual(@as(usize, 1), f.fh.write_count);
    const p = try f.path("a.txt");
    defer a.free(p);
    const content = try Io.Dir.cwd().readFileAlloc(f.io(), p, a, .limited(1024));
    defer a.free(content);
    try std.testing.expectEqualStrings("changed", content);
}

test "stale revision refuses accept with no writes" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    try f.writeFile("a.txt", "original");
    const steps = [_]provider.Step{.{ .tool_call = .{ .id = "c1", .name = "propose_edit", .arguments_json = "{\"files\":[{\"path\":\"a.txt\",\"content\":\"changed\"}]}" } }};
    const tid = try f.engine.newThread(.{ .provider = .{ .fake = .{ .steps = &steps } }, .worktree = .{ .root = f.root } });
    defer a.free(tid);
    try f.engine.send(tid, "edit", &.{});
    f.engine.waitIdle(tid);
    const rid = takeReviewId(f.engine, a) orelse return error.NoReview;
    defer a.free(rid);
    // External modification makes the base revision stale.
    try f.writeFile("a.txt", "externally modified");
    const before = f.fh.write_count;
    try std.testing.expectError(error.StaleRevision, f.engine.acceptReview(tid, rid));
    try std.testing.expectEqual(before, f.fh.write_count);
}

test "reject review performs no writes" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    try f.writeFile("a.txt", "original");
    const steps = [_]provider.Step{.{ .tool_call = .{ .id = "c1", .name = "propose_edit", .arguments_json = "{\"files\":[{\"path\":\"a.txt\",\"content\":\"changed\"}]}" } }};
    const tid = try f.engine.newThread(.{ .provider = .{ .fake = .{ .steps = &steps } }, .worktree = .{ .root = f.root } });
    defer a.free(tid);
    try f.engine.send(tid, "edit", &.{});
    f.engine.waitIdle(tid);
    const rid = takeReviewId(f.engine, a) orelse return error.NoReview;
    defer a.free(rid);
    try f.engine.rejectReview(tid, rid);
    try std.testing.expectEqual(@as(usize, 0), f.fh.write_count);
}

test "checkpoint revert restores original content" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    try f.writeFile("a.txt", "original");
    const steps = [_]provider.Step{.{ .tool_call = .{ .id = "c1", .name = "propose_edit", .arguments_json = "{\"files\":[{\"path\":\"a.txt\",\"content\":\"changed\"}]}" } }};
    const tid = try f.engine.newThread(.{ .provider = .{ .fake = .{ .steps = &steps } }, .worktree = .{ .root = f.root } });
    defer a.free(tid);
    try f.engine.send(tid, "edit", &.{});
    f.engine.waitIdle(tid);
    const rid = takeReviewId(f.engine, a) orelse return error.NoReview;
    defer a.free(rid);
    try f.engine.acceptReview(tid, rid);
    // Find the checkpoint id from the proposal.
    var cp_id: ?[]u8 = null;
    f.engine.mutex.lockUncancelable(f.engine.io);
    for (f.engine.proposals.items) |p| {
        if (std.mem.eql(u8, p.id, rid)) {
            if (p.checkpoint_id) |c| cp_id = a.dupe(u8, c) catch null;
        }
    }
    f.engine.mutex.unlock(f.engine.io);
    const cid = cp_id orelse return error.NoCheckpoint;
    defer a.free(cid);
    try f.engine.revertCheckpoint(cid);
    const p = try f.path("a.txt");
    defer a.free(p);
    const content = try Io.Dir.cwd().readFileAlloc(f.io(), p, a, .limited(1024));
    defer a.free(content);
    try std.testing.expectEqualStrings("original", content);
}

test "cancel mid-stream yields cancelled state" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const steps = [_]provider.Step{ .{ .text = "partial" }, .wait_cancel };
    const tid = try f.engine.newThread(.{ .provider = .{ .fake = .{ .steps = &steps } } });
    defer a.free(tid);
    try f.engine.send(tid, "go", &.{});
    // Wait until the partial delta arrives, then cancel.
    var attempts: usize = 0;
    var saw_partial = false;
    while (attempts < 5000 and !saw_partial) : (attempts += 1) {
        if (f.engine.pollEvent()) |e| {
            if (e == .delta) saw_partial = true;
            f.engine.freeEvent(e);
        } else sleepMs(f.io(), 1);
    }
    f.engine.cancel(tid);
    f.engine.waitIdle(tid);
    try std.testing.expectEqual(thread_mod.State.cancelled, f.engine.threadState(tid).?);
    drain(f.engine);
}

test "cancel kills a running terminal subprocess" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    try f.engine.policy.set("run_terminal", .allow);
    const steps = [_]provider.Step{.{ .tool_call = .{ .id = "c1", .name = "run_terminal", .arguments_json = "{\"command\":\"sleep 30\"}" } }};
    const tid = try f.engine.newThread(.{ .provider = .{ .fake = .{ .steps = &steps } } });
    defer a.free(tid);
    try f.engine.send(tid, "run", &.{});
    var attempts: usize = 0;
    while (attempts < 5000 and f.fh.spawn_count == 0) : (attempts += 1) sleepMs(f.io(), 1);
    try std.testing.expect(f.fh.spawn_count > 0);
    f.engine.cancel(tid);
    f.engine.waitIdle(tid);
    try std.testing.expect(f.fh.kill_count > 0);
    try std.testing.expectEqual(thread_mod.State.cancelled, f.engine.threadState(tid).?);
    drain(f.engine);
}

test "threads persist and restore across engine restart" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const state_dir = try std.fs.path.join(a, &.{ root, "state" });
    defer a.free(state_dir);

    var tid_copy: ?[]u8 = null;
    defer if (tid_copy) |t| a.free(t);
    {
        var fh = FakeHost.init(a, io);
        defer fh.deinit();
        const engine = try Engine.init(a, fh.asHost(), .{ .state_dir = state_dir });
        defer engine.deinit();
        const steps = [_]provider.Step{.{ .text = "persisted reply" }};
        const tid = try engine.newThread(.{ .title = "Persist", .provider = .{ .fake = .{ .steps = &steps } } });
        defer a.free(tid);
        try engine.send(tid, "hello", &.{});
        engine.waitIdle(tid);
        tid_copy = try a.dupe(u8, tid);
    }
    {
        var fh2 = FakeHost.init(a, io);
        defer fh2.deinit();
        const engine2 = try Engine.init(a, fh2.asHost(), .{ .state_dir = state_dir });
        defer engine2.deinit();
        try std.testing.expectEqual(thread_mod.State.idle, engine2.threadState(tid_copy.?).?);
    }
}

test "concurrent threads bind to distinct worktrees" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const wt_a = try f.path("wtA");
    defer a.free(wt_a);
    const wt_b = try f.path("wtB");
    defer a.free(wt_b);
    try Io.Dir.cwd().createDirPath(f.io(), wt_a);
    try Io.Dir.cwd().createDirPath(f.io(), wt_b);
    const fa = try std.fs.path.join(a, &.{ wt_a, "f.txt" });
    defer a.free(fa);
    const fb = try std.fs.path.join(a, &.{ wt_b, "f.txt" });
    defer a.free(fb);
    try Io.Dir.cwd().writeFile(f.io(), .{ .sub_path = fa, .data = "AAA" });
    try Io.Dir.cwd().writeFile(f.io(), .{ .sub_path = fb, .data = "BBB" });

    const steps = [_]provider.Step{.{ .tool_call = .{ .id = "c1", .name = "read_file", .arguments_json = "{\"path\":\"f.txt\"}" } }};
    const ta = try f.engine.newThread(.{ .provider = .{ .fake = .{ .steps = &steps } }, .worktree = .{ .root = wt_a } });
    defer a.free(ta);
    const tb = try f.engine.newThread(.{ .provider = .{ .fake = .{ .steps = &steps } }, .worktree = .{ .root = wt_b } });
    defer a.free(tb);
    try f.engine.send(ta, "read", &.{});
    try f.engine.send(tb, "read", &.{});
    f.engine.waitIdle(ta);
    f.engine.waitIdle(tb);

    var saw_a = false;
    var saw_b = false;
    while (f.engine.pollEvent()) |e| {
        if (e == .tool_finished) {
            if (std.mem.eql(u8, e.tool_finished.thread_id, ta) and std.mem.eql(u8, e.tool_finished.output, "AAA")) saw_a = true;
            if (std.mem.eql(u8, e.tool_finished.thread_id, tb) and std.mem.eql(u8, e.tool_finished.output, "BBB")) saw_b = true;
        }
        f.engine.freeEvent(e);
    }
    try std.testing.expect(saw_a);
    try std.testing.expect(saw_b);
}

test "attachment budgets truncate and disclose" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const steps = [_]provider.Step{.{ .text = "ok" }};
    const tid = try f.engine.newThread(.{ .provider = .{ .fake = .{ .steps = &steps } } });
    defer a.free(tid);
    const big = try a.alloc(u8, 100 * 1024);
    defer a.free(big);
    @memset(big, 'x');
    try f.engine.send(tid, "with context", &.{.{ .kind = .file, .label = "big.bin", .content = big }});
    f.engine.waitIdle(tid);
    var saw_disclosure = false;
    while (f.engine.pollEvent()) |e| {
        if (e == .disclosure) {
            saw_disclosure = true;
            try std.testing.expect(std.mem.indexOf(u8, e.disclosure.text, "truncated") != null);
        }
        f.engine.freeEvent(e);
    }
    try std.testing.expect(saw_disclosure);
}

test "openai provider errors never leak the api key" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const BadTransport = struct {
        fn post(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const provider.Header, _: []const u8, _: provider.LineSink, _: *provider.Token) anyerror!void {
            return error.HttpError;
        }
    };
    const tid = try f.engine.newThread(.{ .provider = .{ .openai = .{
        .base_url = "https://api.example.test/v1",
        .api_key = "sk-super-secret",
        .transport = .{ .ptr = undefined, .post = BadTransport.post },
    } } });
    defer a.free(tid);
    try f.engine.send(tid, "hi", &.{});
    f.engine.waitIdle(tid);
    try std.testing.expectEqual(thread_mod.State.failed, f.engine.threadState(tid).?);
    try std.testing.expect(!f.fh.loggedContains("sk-super-secret"));
    while (f.engine.pollEvent()) |e| {
        if (e == .failed) try std.testing.expect(std.mem.indexOf(u8, e.failed.message, "sk-super-secret") == null);
        f.engine.freeEvent(e);
    }
}

test "skills load, search and inject into prompt" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const skills_dir = try f.path("skills");
    defer a.free(skills_dir);
    try Io.Dir.cwd().createDirPath(f.io(), skills_dir);
    const skill_path = try std.fs.path.join(a, &.{ skills_dir, "zig.md" });
    defer a.free(skill_path);
    try Io.Dir.cwd().writeFile(f.io(), .{ .sub_path = skill_path, .data = "---\nname: zig\ndescription: Zig style\n---\nWrite Zig." });
    const steps = [_]provider.Step{.{ .text = "ok" }};
    const tid = try f.engine.newThread(.{ .provider = .{ .fake = .{ .steps = &steps } }, .skills_dirs = &.{skills_dir} });
    defer a.free(tid);
    const matches = try f.engine.searchSkills(tid, "zig");
    defer a.free(matches);
    try std.testing.expect(matches.len > 0);
    try f.engine.send(tid, "hi", &.{});
    f.engine.waitIdle(tid);
    try std.testing.expectEqual(thread_mod.State.idle, f.engine.threadState(tid).?);
    drain(f.engine);
}

test "openai provider config probe resolves key offline" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var fh = FakeHost.init(a, io);
    defer fh.deinit();
    const auth_path = try std.fs.path.join(a, &.{ root, "auth.json" });
    defer a.free(auth_path);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = auth_path,
        .data = "{\"providers\":{\"openai\":{\"api_key_env\":\"CORAL_TEST_KEY\",\"base_url\":\"https://api.example.test/v1\"}}}",
    });
    const FakeEnv = struct {
        fn get(_: ?*anyopaque, name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "CORAL_TEST_KEY")) return "sk-test-env";
            return null;
        }
    };
    const state_dir = try std.fs.path.join(a, &.{ root, "state" });
    defer a.free(state_dir);
    const engine = try Engine.init(a, fh.asHost(), .{
        .state_dir = state_dir,
        .auth_path = auth_path,
        .env = .{ .get = FakeEnv.get },
    });
    defer engine.deinit();
    const result = try engine.probe("openai");
    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("configured", result.detail);
    try std.testing.expect((try engine.probe("fake")).ok);
    try std.testing.expect(!(try engine.probe("nope")).ok);
}
