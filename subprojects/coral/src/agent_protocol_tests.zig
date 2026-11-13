//! M7 Zed-agent-parity protocol suite (GTK-free, offline, disposable temp dirs).
//!   zig test -lc src/agent_protocol_tests.zig
//! Requires Linux, python3, /bin/sh. Exercises the ACP v1 echo/edit adapters
//! and the fake MCP server via stdio. No host writes outside temp dirs and no
//! live network.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const engine_mod = @import("agent/engine.zig");
const acp = @import("agent/acp.zig");
const mcp = @import("agent/mcp.zig");
const rpc = @import("agent/rpc.zig");
const provider = @import("agent/provider.zig");
const thread_mod = @import("agent/thread.zig");
const test_host = @import("agent/test_host.zig");

const Engine = engine_mod.Engine;
const FakeHost = test_host.FakeHost;

test {
    _ = @import("agent/rpc.zig");
    _ = @import("agent/acp.zig");
    _ = @import("agent/mcp.zig");
    _ = @import("agent/skills.zig");
    _ = @import("agent/engine.zig");
    _ = @import("agent/test_host.zig");
}

fn sleepMs(io: Io, ms: i64) void {
    Io.sleep(io, Io.Duration.fromMilliseconds(ms), .real) catch {};
}

// ---------------------------------------------------------------------------
// Test ACP host for direct client tests
// ---------------------------------------------------------------------------

const TestAcpHost = struct {
    allocator: Allocator,
    chunk_count: usize = 0,
    last_text: std.ArrayList(u8) = .empty,
    permission_decision: acp.PermissionDecision = .{ .select = "allow" },
    permission_count: usize = 0,
    read_content: []const u8 = "file body",
    write_count: usize = 0,
    last_write_path: std.ArrayList(u8) = .empty,
    last_write_content: std.ArrayList(u8) = .empty,
    terminal_create_count: usize = 0,
    terminal_output_count: usize = 0,

    fn deinit(self: *TestAcpHost) void {
        self.last_text.deinit(self.allocator);
        self.last_write_path.deinit(self.allocator);
        self.last_write_content.deinit(self.allocator);
    }

    fn asHost(self: *TestAcpHost) acp.AcpHost {
        return .{
            .ctx = self,
            .onSessionUpdate = onUpdate,
            .requestPermission = onPermission,
            .readTextFile = onRead,
            .writeTextFile = onWrite,
            .terminalCreate = onTerminalCreate,
            .terminalOutput = onTerminalOutput,
            .terminalWait = onTerminalWait,
            .terminalKill = onTerminalKill,
            .terminalRelease = onTerminalRelease,
        };
    }

    fn onUpdate(ctx: *anyopaque, _: []const u8, update: std.json.Value) void {
        const self: *TestAcpHost = @ptrCast(@alignCast(ctx));
        self.chunk_count += 1;
        if (update == .object) {
            if (update.object.get("content")) |content| {
                if (content == .object) {
                    if (content.object.get("text")) |t| {
                        if (t == .string) {
                            self.last_text.clearRetainingCapacity();
                            self.last_text.appendSlice(self.allocator, t.string) catch {};
                        }
                    }
                }
            }
        }
    }

    fn onPermission(ctx: *anyopaque, _: []const u8, _: std.json.Value) acp.PermissionDecision {
        const self: *TestAcpHost = @ptrCast(@alignCast(ctx));
        self.permission_count += 1;
        return self.permission_decision;
    }

    fn onRead(ctx: *anyopaque, allocator: Allocator, _: []const u8, _: []const u8) anyerror![]u8 {
        const self: *TestAcpHost = @ptrCast(@alignCast(ctx));
        return allocator.dupe(u8, self.read_content);
    }

    fn onWrite(ctx: *anyopaque, _: []const u8, path: []const u8, content: []const u8) anyerror!void {
        const self: *TestAcpHost = @ptrCast(@alignCast(ctx));
        self.write_count += 1;
        self.last_write_path.clearRetainingCapacity();
        try self.last_write_path.appendSlice(self.allocator, path);
        self.last_write_content.clearRetainingCapacity();
        try self.last_write_content.appendSlice(self.allocator, content);
    }

    fn onTerminalCreate(ctx: *anyopaque, _: []const u8, _: []const u8, _: []const []const u8, _: ?[]const u8) anyerror![]u8 {
        const self: *TestAcpHost = @ptrCast(@alignCast(ctx));
        self.terminal_create_count += 1;
        return self.allocator.dupe(u8, "term-1");
    }

    fn onTerminalOutput(ctx: *anyopaque, allocator: Allocator, _: []const u8, _: []const u8) anyerror!acp.TerminalOutput {
        const self: *TestAcpHost = @ptrCast(@alignCast(ctx));
        self.terminal_output_count += 1;
        return .{ .output = try allocator.dupe(u8, "hi\n"), .exit_code = 0 };
    }

    fn onTerminalWait(ctx: *anyopaque, _: []const u8, _: []const u8) anyerror!i32 {
        _ = ctx;
        return 0;
    }

    fn onTerminalKill(_: *anyopaque, _: []const u8, _: []const u8) void {}
    fn onTerminalRelease(_: *anyopaque, _: []const u8, _: []const u8) void {}
};

fn startAdapter(a: Allocator, io: Io, fixture: []const u8, mode: []const u8, host: acp.AcpHost) !*acp.AcpClient {
    const path = try test_host.fixturePath(a, io, fixture);
    defer a.free(path);
    return acp.AcpClient.start(a, io, &.{ "python3", path, "--mode", mode }, null, host, .{});
}

fn startMcp(a: Allocator, io: Io, mode: []const u8) !*mcp.McpClient {
    const path = try test_host.fixturePath(a, io, "mcp_server_fake.py");
    defer a.free(path);
    return mcp.McpClient.start(a, io, &.{ "python3", path, "--mode", mode }, .{});
}

// ---------------------------------------------------------------------------
// Direct ACP client tests
// ---------------------------------------------------------------------------

test "ACP echo negotiation and prompt streaming" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var host = TestAcpHost{ .allocator = a };
    defer host.deinit();
    const client = try startAdapter(a, io, "acp_adapter_echo.py", "default", host.asHost());
    defer client.deinit();
    try client.initialize(5000);
    try std.testing.expectEqual(@as(i64, 1), client.negotiated_version);
    try std.testing.expect(client.capabilities.prompt_embedded_context);
    const sid = try client.newSession(a, "/wt", 5000);
    defer a.free(sid);
    var token = provider.Token{};
    const stop = try client.prompt(a, sid, "echo me", &token, 5000);
    defer a.free(stop);
    client.drain(5000);
    try std.testing.expectEqualStrings("end_turn", stop);
    try std.testing.expect(host.chunk_count > 0);
    try std.testing.expectEqualStrings("echo me", host.last_text.items);
}

test "ACP omitted capabilities default to false" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var host = TestAcpHost{ .allocator = a };
    defer host.deinit();
    const client = try startAdapter(a, threaded.io(), "acp_adapter_echo.py", "omit-capabilities", host.asHost());
    defer client.deinit();
    try client.initialize(5000);
    try std.testing.expect(!client.capabilities.load_session);
    try std.testing.expect(!client.capabilities.prompt_embedded_context);
    try std.testing.expect(!client.capabilities.prompt_image);
}

test "ACP permission allow/deny/cancel" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cases = [_]struct { decision: acp.PermissionDecision, expected: []const u8 }{
        .{ .decision = .{ .select = "allow" }, .expected = "end_turn" },
        .{ .decision = .{ .select = "deny" }, .expected = "refusal" },
        .{ .decision = .cancel, .expected = "cancelled" },
    };
    for (cases) |case| {
        var host = TestAcpHost{ .allocator = a, .permission_decision = case.decision };
        defer host.deinit();
        const client = try startAdapter(a, io, "acp_adapter_echo.py", "permission", host.asHost());
        defer client.deinit();
        try client.initialize(5000);
        const sid = try client.newSession(a, "/wt", 5000);
        defer a.free(sid);
        var token = provider.Token{};
        const stop = try client.prompt(a, sid, "run", &token, 5000);
        defer a.free(stop);
        client.drain(5000);
        try std.testing.expectEqualStrings(case.expected, stop);
        try std.testing.expectEqual(@as(usize, 1), host.permission_count);
    }
}

test "ACP fs read/write callbacks" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var host = TestAcpHost{ .allocator = a, .read_content = "original" };
    defer host.deinit();
    const client = try startAdapter(a, threaded.io(), "acp_adapter_echo.py", "fs", host.asHost());
    defer client.deinit();
    try client.initialize(5000);
    const sid = try client.newSession(a, "/wt", 5000);
    defer a.free(sid);
    var token = provider.Token{};
    const stop = try client.prompt(a, sid, "edit", &token, 5000);
    defer a.free(stop);
    client.drain(5000);
    try std.testing.expectEqualStrings("end_turn", stop);
    try std.testing.expectEqual(@as(usize, 1), host.write_count);
    try std.testing.expectEqualStrings("file.txt", host.last_write_path.items);
    try std.testing.expectEqualStrings("edited:original", host.last_write_content.items);
}

test "ACP terminal callbacks" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var host = TestAcpHost{ .allocator = a };
    defer host.deinit();
    const client = try startAdapter(a, threaded.io(), "acp_adapter_echo.py", "terminal", host.asHost());
    defer client.deinit();
    try client.initialize(5000);
    const sid = try client.newSession(a, "/wt", 5000);
    defer a.free(sid);
    var token = provider.Token{};
    const stop = try client.prompt(a, sid, "term", &token, 5000);
    defer a.free(stop);
    client.drain(5000);
    try std.testing.expectEqualStrings("end_turn", stop);
    try std.testing.expectEqual(@as(usize, 1), host.terminal_create_count);
    try std.testing.expect(host.terminal_output_count > 0);
}

test "ACP disconnect mid-prompt is safe" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var host = TestAcpHost{ .allocator = a };
    defer host.deinit();
    const client = try startAdapter(a, threaded.io(), "acp_adapter_echo.py", "disconnect", host.asHost());
    defer client.deinit();
    try client.initialize(5000);
    const sid = try client.newSession(a, "/wt", 5000);
    defer a.free(sid);
    var token = provider.Token{};
    try std.testing.expectError(error.Disconnected, client.prompt(a, sid, "go", &token, 5000));
    try std.testing.expect(client.isDisconnected());
}

test "ACP malformed input is bounded and survives" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var host = TestAcpHost{ .allocator = a };
    defer host.deinit();
    const client = try startAdapter(a, threaded.io(), "acp_adapter_echo.py", "malformed", host.asHost());
    defer client.deinit();
    try client.initialize(5000);
    const sid = try client.newSession(a, "/wt", 5000);
    defer a.free(sid);
    var token = provider.Token{};
    const stop = try client.prompt(a, sid, "echo", &token, 5000);
    defer a.free(stop);
    client.drain(5000);
    try std.testing.expectEqualStrings("end_turn", stop);
    try std.testing.expect(client.conn.protocolErrorCount() > 0);
}

test "ACP fragmented input reassembles" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var host = TestAcpHost{ .allocator = a };
    defer host.deinit();
    const client = try startAdapter(a, threaded.io(), "acp_adapter_echo.py", "fragment", host.asHost());
    defer client.deinit();
    try client.initialize(5000);
    const sid = try client.newSession(a, "/wt", 5000);
    defer a.free(sid);
    var token = provider.Token{};
    const stop = try client.prompt(a, sid, "fragmented", &token, 5000);
    defer a.free(stop);
    client.drain(5000);
    try std.testing.expectEqualStrings("end_turn", stop);
    try std.testing.expectEqualStrings("fragmented", host.last_text.items);
}

test "ACP late response after cancel is ignored" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var host = TestAcpHost{ .allocator = a };
    defer host.deinit();
    const client = try startAdapter(a, io, "acp_adapter_echo.py", "late", host.asHost());
    defer client.deinit();
    try client.initialize(5000);
    const sid = try client.newSession(a, "/wt", 5000);
    defer a.free(sid);
    var token = provider.Token{};
    const stop = try client.prompt(a, sid, "echo", &token, 5000);
    defer a.free(stop);
    try std.testing.expectEqualStrings("end_turn", stop);
    client.cancel(sid); // adapter emits a late duplicate response
    sleepMs(io, 50);
    try std.testing.expect(!client.isDisconnected());
}

// ---------------------------------------------------------------------------
// Direct MCP client tests
// ---------------------------------------------------------------------------

test "MCP initialize, list tools, read-only hints" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const client = try startMcp(a, threaded.io(), "default");
    defer client.deinit();
    try client.initialize(5000);
    try std.testing.expectEqualStrings("fake-mcp", client.server_name);
    const tools = try client.listTools(a, 5000);
    defer {
        for (tools) |*t| t.deinit(a);
        a.free(tools);
    }
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    var echo_ro = false;
    var write_rw = false;
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, "echo")) echo_ro = t.read_only;
        if (std.mem.eql(u8, t.name, "write_file")) write_rw = !t.read_only;
    }
    try std.testing.expect(echo_ro);
    try std.testing.expect(write_rw);
}

test "MCP call echo and non-read-only write_file (no side effect)" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const client = try startMcp(a, threaded.io(), "default");
    defer client.deinit();
    try client.initialize(5000);
    var token = provider.Token{};
    var echo = try client.call(a, "echo", "{\"text\":\"hello mcp\"}", &token, 5000);
    defer echo.deinit(a);
    try std.testing.expect(!echo.is_error);
    try std.testing.expect(std.mem.indexOf(u8, echo.content, "hello mcp") != null);

    var write = try client.call(a, "write_file", "{\"path\":\"/tmp/x\"}", &token, 5000);
    defer write.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, write.content, "would write /tmp/x") != null);
}

test "MCP malformed input survives" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const client = try startMcp(a, threaded.io(), "malformed");
    defer client.deinit();
    try client.initialize(5000);
    const tools = try client.listTools(a, 5000);
    defer {
        for (tools) |*t| t.deinit(a);
        a.free(tools);
    }
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    try std.testing.expect(client.conn.protocolErrorCount() > 0);
}

// ---------------------------------------------------------------------------
// Engine integration (ACP threads, review routing, concurrency, host PTY)
// ---------------------------------------------------------------------------

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
};

fn adapterArgv(a: Allocator, io: Io, fixture: []const u8, mode: []const u8) ![]const []const u8 {
    const path = try test_host.fixturePath(a, io, fixture);
    defer a.free(path);
    const argv = try a.alloc([]const u8, 4);
    argv[0] = try a.dupe(u8, "python3");
    argv[1] = try a.dupe(u8, path);
    argv[2] = try a.dupe(u8, "--mode");
    argv[3] = try a.dupe(u8, mode);
    return argv;
}

fn freeArgv(a: Allocator, argv: []const []const u8) void {
    for (argv) |s| a.free(s);
    a.free(argv);
}

fn driveReview(engine: *Engine, io: Io, tid: []const u8, accept: bool) !void {
    var attempts: usize = 0;
    while (attempts < 10000) : (attempts += 1) {
        if (engine.pollEvent()) |e| {
            if (e == .review_proposed) {
                const rid = e.review_proposed.review_id;
                defer engine.freeEvent(e);
                if (accept) try engine.acceptReview(tid, rid) else try engine.rejectReview(tid, rid);
                return;
            }
            engine.freeEvent(e);
        } else sleepMs(io, 1);
    }
    return error.ReviewTimeout;
}

fn drivePermission(engine: *Engine, io: Io, tid: []const u8, decision: engine_mod.PermissionResponse) !void {
    var attempts: usize = 0;
    while (attempts < 10000) : (attempts += 1) {
        if (engine.pollEvent()) |e| {
            if (e == .permission_request) {
                const pr = e.permission_request;
                defer engine.freeEvent(e);
                try engine.respondPermission(tid, pr.request_id, decision);
                return;
            }
            engine.freeEvent(e);
        } else sleepMs(io, 1);
    }
    return error.PermissionTimeout;
}

fn drain(engine: *Engine) void {
    while (engine.pollEvent()) |e| engine.freeEvent(e);
}

test "Engine ACP echo thread completes and records assistant message" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const argv = try adapterArgv(a, f.io(), "acp_adapter_echo.py", "default");
    defer freeArgv(a, argv);
    const tid = try f.engine.newThread(.{ .provider = .{ .acp = .{ .argv = argv } }, .worktree = .{ .root = f.root } });
    defer a.free(tid);
    try f.engine.send(tid, "hello acp", &.{});
    f.engine.waitIdle(tid);
    try std.testing.expectEqual(thread_mod.State.idle, f.engine.threadState(tid).?);
    var saw_delta = false;
    while (f.engine.pollEvent()) |e| {
        if (e == .delta) saw_delta = true;
        f.engine.freeEvent(e);
    }
    try std.testing.expect(saw_delta);
}

test "Engine ACP edit routes fs write through review (accept)" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const file_path = try std.fs.path.join(a, &.{ f.root, "file.txt" });
    defer a.free(file_path);
    try Io.Dir.cwd().writeFile(f.io(), .{ .sub_path = file_path, .data = "original" });
    const argv = try adapterArgv(a, f.io(), "acp_adapter_edit.py", "default");
    defer freeArgv(a, argv);
    const tid = try f.engine.newThread(.{ .provider = .{ .acp = .{ .argv = argv } }, .worktree = .{ .root = f.root } });
    defer a.free(tid);
    try f.engine.send(tid, "file.txt", &.{});
    try driveReview(f.engine, f.io(), tid, true);
    f.engine.waitIdle(tid);
    try std.testing.expectEqual(thread_mod.State.idle, f.engine.threadState(tid).?);
    const content = try Io.Dir.cwd().readFileAlloc(f.io(), file_path, a, .limited(1024));
    defer a.free(content);
    try std.testing.expectEqualStrings("original\n// edited", content);
    drain(f.engine);
}

test "Engine ACP edit review reject leaves file unchanged" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const file_path = try std.fs.path.join(a, &.{ f.root, "file.txt" });
    defer a.free(file_path);
    try Io.Dir.cwd().writeFile(f.io(), .{ .sub_path = file_path, .data = "original" });
    const argv = try adapterArgv(a, f.io(), "acp_adapter_edit.py", "default");
    defer freeArgv(a, argv);
    const tid = try f.engine.newThread(.{ .provider = .{ .acp = .{ .argv = argv } }, .worktree = .{ .root = f.root } });
    defer a.free(tid);
    try f.engine.send(tid, "file.txt", &.{});
    try driveReview(f.engine, f.io(), tid, false);
    f.engine.waitIdle(tid);
    const content = try Io.Dir.cwd().readFileAlloc(f.io(), file_path, a, .limited(1024));
    defer a.free(content);
    try std.testing.expectEqualStrings("original", content);
    try std.testing.expectEqual(@as(usize, 0), f.fh.write_count);
    drain(f.engine);
}

test "Engine concurrent ACP agents bound to distinct worktrees" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const wt_a = try std.fs.path.join(a, &.{ f.root, "wtA" });
    defer a.free(wt_a);
    const wt_b = try std.fs.path.join(a, &.{ f.root, "wtB" });
    defer a.free(wt_b);
    try Io.Dir.cwd().createDirPath(f.io(), wt_a);
    try Io.Dir.cwd().createDirPath(f.io(), wt_b);
    const argv = try adapterArgv(a, f.io(), "acp_adapter_echo.py", "default");
    defer freeArgv(a, argv);
    const ta = try f.engine.newThread(.{ .provider = .{ .acp = .{ .argv = argv } }, .worktree = .{ .root = wt_a } });
    defer a.free(ta);
    const tb = try f.engine.newThread(.{ .provider = .{ .acp = .{ .argv = argv } }, .worktree = .{ .root = wt_b } });
    defer a.free(tb);
    try f.engine.send(ta, "agent A", &.{});
    try f.engine.send(tb, "agent B", &.{});
    f.engine.waitIdle(ta);
    f.engine.waitIdle(tb);
    try std.testing.expectEqual(thread_mod.State.idle, f.engine.threadState(ta).?);
    try std.testing.expectEqual(thread_mod.State.idle, f.engine.threadState(tb).?);
    var saw_a = false;
    var saw_b = false;
    while (f.engine.pollEvent()) |e| {
        if (e == .delta) {
            if (std.mem.eql(u8, e.delta.thread_id, ta)) saw_a = true;
            if (std.mem.eql(u8, e.delta.thread_id, tb)) saw_b = true;
        }
        f.engine.freeEvent(e);
    }
    try std.testing.expect(saw_a);
    try std.testing.expect(saw_b);
}

test "Engine ACP terminal thread drives host PTY subprocess" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const argv = try adapterArgv(a, f.io(), "acp_adapter_echo.py", "terminal");
    defer freeArgv(a, argv);
    const tid = try f.engine.newThread(.{ .provider = .{ .acp = .{ .argv = argv } }, .worktree = .{ .root = f.root } });
    defer a.free(tid);
    try f.engine.send(tid, "term", &.{});
    f.engine.waitIdle(tid);
    try std.testing.expectEqual(thread_mod.State.idle, f.engine.threadState(tid).?);
    try std.testing.expect(f.fh.spawn_count > 0);
    drain(f.engine);
}

test "Engine ACP permission allow via respondPermission" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const argv = try adapterArgv(a, f.io(), "acp_adapter_echo.py", "permission");
    defer freeArgv(a, argv);
    const tid = try f.engine.newThread(.{ .provider = .{ .acp = .{ .argv = argv } }, .worktree = .{ .root = f.root } });
    defer a.free(tid);
    try f.engine.send(tid, "run", &.{});
    try drivePermission(f.engine, f.io(), tid, .allow);
    f.engine.waitIdle(tid);
    try std.testing.expectEqual(thread_mod.State.idle, f.engine.threadState(tid).?);
    drain(f.engine);
}

test "Engine MCP tools exposed and read-only call executes" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const mcp_path = try test_host.fixturePath(a, f.io(), "mcp_server_fake.py");
    defer a.free(mcp_path);
    const steps = [_]provider.Step{.{ .tool_call = .{ .id = "c1", .name = "mcp:fake-mcp:echo", .arguments_json = "{\"text\":\"via engine\"}" } }};
    const tid = try f.engine.newThread(.{
        .provider = .{ .fake = .{ .steps = &steps } },
        .mcp_servers = &.{.{ .name = "fake", .argv = &.{ "python3", mcp_path, "--mode", "default" } }},
    });
    defer a.free(tid);
    try f.engine.send(tid, "call mcp", &.{});
    f.engine.waitIdle(tid);
    var found = false;
    while (f.engine.pollEvent()) |e| {
        if (e == .tool_finished and std.mem.indexOf(u8, e.tool_finished.output, "via engine") != null) found = true;
        f.engine.freeEvent(e);
    }
    try std.testing.expect(found);
}

test "Engine MCP non-read-only tool runs after approval" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const mcp_path = try test_host.fixturePath(a, f.io(), "mcp_server_fake.py");
    defer a.free(mcp_path);
    const steps = [_]provider.Step{.{ .tool_call = .{ .id = "c1", .name = "mcp:fake-mcp:write_file", .arguments_json = "{\"path\":\"target.txt\"}" } }};
    const tid = try f.engine.newThread(.{
        .provider = .{ .fake = .{ .steps = &steps } },
        .mcp_servers = &.{.{ .name = "fake", .argv = &.{ "python3", mcp_path, "--mode", "default" } }},
    });
    defer a.free(tid);
    try f.engine.send(tid, "call mcp write", &.{});
    try drivePermission(f.engine, f.io(), tid, .allow);
    f.engine.waitIdle(tid);
    try std.testing.expectEqual(thread_mod.State.idle, f.engine.threadState(tid).?);
    var found = false;
    while (f.engine.pollEvent()) |e| {
        if (e == .tool_finished and e.tool_finished.ok and std.mem.indexOf(u8, e.tool_finished.output, "would write target.txt") != null) found = true;
        f.engine.freeEvent(e);
    }
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 0), f.fh.write_count);
}

test "Engine MCP approval deny has no side effect" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const mcp_path = try test_host.fixturePath(a, f.io(), "mcp_server_fake.py");
    defer a.free(mcp_path);
    const steps = [_]provider.Step{.{ .tool_call = .{ .id = "c1", .name = "mcp:fake-mcp:write_file", .arguments_json = "{\"path\":\"target.txt\"}" } }};
    const tid = try f.engine.newThread(.{
        .provider = .{ .fake = .{ .steps = &steps } },
        .mcp_servers = &.{.{ .name = "fake", .argv = &.{ "python3", mcp_path, "--mode", "default" } }},
    });
    defer a.free(tid);
    try f.engine.send(tid, "call mcp write", &.{});
    try drivePermission(f.engine, f.io(), tid, .deny);
    f.engine.waitIdle(tid);
    var denied = false;
    while (f.engine.pollEvent()) |e| {
        if (e == .tool_finished) {
            try std.testing.expect(!e.tool_finished.ok);
            try std.testing.expect(std.mem.indexOf(u8, e.tool_finished.output, "permission denied") != null);
            denied = true;
        }
        f.engine.freeEvent(e);
    }
    try std.testing.expect(denied);
    try std.testing.expectEqual(@as(usize, 0), f.fh.write_count);
}

test "Engine ACP cancel mid-prompt yields cancelled state" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const argv = try adapterArgv(a, f.io(), "acp_adapter_echo.py", "slow");
    defer freeArgv(a, argv);
    const tid = try f.engine.newThread(.{ .provider = .{ .acp = .{ .argv = argv } }, .worktree = .{ .root = f.root } });
    defer a.free(tid);
    try f.engine.send(tid, "slow", &.{});
    var attempts: usize = 0;
    while (attempts < 5000) : (attempts += 1) {
        if (f.engine.threadState(tid) == .streaming) break;
        sleepMs(f.io(), 1);
    }
    // Let the prompt reach the adapter before cancelling.
    sleepMs(f.io(), 500);
    f.engine.cancel(tid);
    f.engine.waitIdle(tid);
    try std.testing.expectEqual(thread_mod.State.cancelled, f.engine.threadState(tid).?);
    var saw_cancelled = false;
    while (f.engine.pollEvent()) |e| {
        if (e == .cancelled) saw_cancelled = true;
        f.engine.freeEvent(e);
    }
    try std.testing.expect(saw_cancelled);
}

test "Engine ACP disconnect mid-prompt fails safely" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const argv = try adapterArgv(a, f.io(), "acp_adapter_echo.py", "disconnect");
    defer freeArgv(a, argv);
    const tid = try f.engine.newThread(.{ .provider = .{ .acp = .{ .argv = argv } }, .worktree = .{ .root = f.root } });
    defer a.free(tid);
    try f.engine.send(tid, "go", &.{});
    f.engine.waitIdle(tid);
    try std.testing.expectEqual(thread_mod.State.failed, f.engine.threadState(tid).?);
    var saw_failed = false;
    while (f.engine.pollEvent()) |e| {
        if (e == .failed) saw_failed = true;
        f.engine.freeEvent(e);
    }
    try std.testing.expect(saw_failed);
}

test "Engine ACP edit stale base refuses accept with no write" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const file_path = try std.fs.path.join(a, &.{ f.root, "file.txt" });
    defer a.free(file_path);
    try Io.Dir.cwd().writeFile(f.io(), .{ .sub_path = file_path, .data = "original" });
    const argv = try adapterArgv(a, f.io(), "acp_adapter_edit.py", "default");
    defer freeArgv(a, argv);
    const tid = try f.engine.newThread(.{ .provider = .{ .acp = .{ .argv = argv } }, .worktree = .{ .root = f.root } });
    defer a.free(tid);
    try f.engine.send(tid, "file.txt", &.{});
    var rid: ?[]u8 = null;
    var attempts: usize = 0;
    while (attempts < 10000) : (attempts += 1) {
        if (f.engine.pollEvent()) |e| {
            if (e == .review_proposed) {
                rid = try a.dupe(u8, e.review_proposed.review_id);
                f.engine.freeEvent(e);
                break;
            }
            f.engine.freeEvent(e);
        } else sleepMs(f.io(), 1);
    }
    const review_id = rid orelse return error.ReviewTimeout;
    defer a.free(review_id);
    // Change the file behind the review's back: accept must refuse (stale).
    try Io.Dir.cwd().writeFile(f.io(), .{ .sub_path = file_path, .data = "changed by someone else" });
    try std.testing.expectError(error.StaleRevision, f.engine.acceptReview(tid, review_id));
    f.engine.waitIdle(tid);
    const content = try Io.Dir.cwd().readFileAlloc(f.io(), file_path, a, .limited(1024));
    defer a.free(content);
    try std.testing.expectEqualStrings("changed by someone else", content);
    try std.testing.expectEqual(@as(usize, 0), f.fh.write_count);
    drain(f.engine);
}
