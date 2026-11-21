//! One user-selected llama-server, authenticated loopback and bounded lifetime.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const fetch = @import("fetch.zig");
const config = @import("config.zig");
const registry = @import("model_registry.zig");
const probe = @import("runtime_probe.zig");
const compute = @import("compute.zig");
const memory = @import("memory.zig");
const embed = @import("embed.zig");
const c = @import("pearl_libc");
const a = std.heap.c_allocator;
pub const Mode = enum { chat, embedding };
pub const Runtime = struct {
    process: ?*gio.Subprocess = null,
    arena: ?std.heap.ArenaAllocator = null,
    mode: Mode = .chat,
    base: []const u8 = "",
    authorization: []const u8 = "",
    keyfile: ?[:0]const u8 = null,
    identity: []const u8 = "",
    executable: []const u8 = "",
    version: []const u8 = "",
    device: ?compute.Device = null,
    gpu: bool = false,
    offload_layers: u16 = 0,
    fallback_reason: []const u8 = "",
    tools_available: bool = false,
    tools_warning: []const u8 = "",
    inference_seconds: u16 = 60,
    check_tokens: u32 = 256,
    lockfd: c_int = -1,
    pid: c_int = 0,
    logfd: c_int = -1,
    logs: std.ArrayList(u8) = .empty,
    deadline: i64 = 0,
    last_memory_check: i64 = 0,
    telemetry: ?*@import("telemetry.zig").Metrics = null,
    pub fn stop(self: *Runtime) void {
        if (self.process) |p| {
            if (self.pid > 0) _ = std.c.kill(-self.pid, std.c.SIG.KILL);
            p.forceExit();
            _ = p.wait(null, null);
            p.unref();
        }
        if (self.lockfd >= 0) _ = std.c.close(self.lockfd);
        if (self.keyfile) |path| _ = std.c.unlink(path);
        if (self.arena) |*arena| arena.deinit();
        self.* = .{ .telemetry = self.telemetry, .mode = self.mode };
    }
    pub fn ensure(self: *Runtime, cfg: config.Config, cancel: *gio.Cancellable) !void {
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        const resolved = try probe.resolve(temporary, cfg.runtime);
        const model_path = if (registry.find(cfg.model_id)) |model| try @import("downloads.zig").path(temporary, model) else try temporary.dupeSentinel(u8, cfg.custom_model, 0);
        const model_identity = probe.fingerprint(temporary, model_path) catch return error.ModelNotInstalled;
        const identity = try std.json.Stringify.valueAlloc(a, .{ cfg.model_id, cfg.custom_model, cfg.cpu_threads, cfg.contextTokens(), cfg.answerTokens(), cfg.runtime, cfg.compute, try probe.fingerprint(temporary, resolved), model_identity }, .{});
        defer a.free(identity);
        if (self.process) |process| if (process.getIdentifier() != null and std.mem.eql(u8, identity, self.identity)) return;
        self.launch(cfg, .chat, cancel) catch |err| {
            if (cancel.isCancelled() != 0 or !cfg.compute.fallback() or !recoverable(err)) return err;
            var cpu = cfg;
            cpu.compute.mode = .cpu;
            try self.launch(cpu, .chat, cancel);
            self.fallback_reason = @errorName(err);
        };
        self.identity = try self.arena.?.allocator().dupe(u8, identity);
    }
    /// Semantic search owns a second, separately locked server for the pinned
    /// embedding backbone. Chat keeps its own lock; the two may coexist.
    pub fn ensureEmbedding(self: *Runtime, cfg: config.Config, cancel: *gio.Cancellable) !void {
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        const resolved = try probe.resolve(temporary, cfg.runtime);
        const model = registry.findEmbedding(cfg.semantic.model_id) orelse return error.UnknownEmbeddingModel;
        const model_path = try @import("downloads.zig").path(temporary, model);
        const model_identity = probe.fingerprint(temporary, model_path) catch return error.ModelNotInstalled;
        const identity = try std.json.Stringify.valueAlloc(a, .{ "embedding", cfg.semantic.model_id, cfg.cpu_threads, cfg.runtime, cfg.compute, try probe.fingerprint(temporary, resolved), model_identity }, .{});
        defer a.free(identity);
        if (self.process) |process| if (process.getIdentifier() != null and std.mem.eql(u8, identity, self.identity)) return;
        self.launch(cfg, .embedding, cancel) catch |err| {
            if (cancel.isCancelled() != 0 or !cfg.compute.fallback() or !recoverable(err)) return err;
            var cpu = cfg;
            cpu.compute.mode = .cpu;
            try self.launch(cpu, .embedding, cancel);
            self.fallback_reason = @errorName(err);
        };
        self.identity = try self.arena.?.allocator().dupe(u8, identity);
    }
    pub fn retryCpu(self: *Runtime, cfg: config.Config, cancel: *gio.Cancellable) !void {
        const identity = try a.dupe(u8, self.identity);
        defer a.free(identity);
        var cpu = cfg;
        cpu.compute.mode = .cpu;
        try self.launch(cpu, self.mode, cancel);
        self.identity = try self.arena.?.allocator().dupe(u8, identity);
        self.fallback_reason = "GPU inference failed; continued on CPU";
    }
    fn launch(self: *Runtime, cfg: config.Config, mode: Mode, cancel: *gio.Cancellable) !void {
        self.stop();
        self.mode = mode;
        self.arena = .init(a);
        errdefer self.stop();
        const alloc = self.arena.?.allocator();
        const model: ?registry.Model = if (mode == .embedding) registry.findEmbedding(cfg.semantic.model_id) else registry.find(cfg.model_id);
        if (mode == .embedding and model == null) return error.UnknownEmbeddingModel;
        self.inference_seconds = if (mode == .embedding) model.?.inference_seconds else cfg.inferenceSeconds();
        self.deadline = glib.getMonotonicTime() + @as(i64, self.inference_seconds) * 3 * std.time.us_per_s;
        const lockname = if (mode == .embedding) "pearl-embedding-runtime.lock" else "pearl-assistant-runtime.lock";
        const lockpath = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ glib.getUserRuntimeDir(), lockname }, 0);
        self.lockfd = std.c.open(lockpath, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c_uint, 0o600));
        if (self.lockfd < 0 or fetch.c.flock(self.lockfd, fetch.c.LOCK_EX | fetch.c.LOCK_NB) != 0) return error.AssistantRuntimeBusy;
        const reasoning = if (mode == .chat) (if (model) |m| m.reasoning else false) else false;
        self.check_tokens = if (reasoning) cfg.answerTokens() else 256;
        const filename = if (model) |m| try @import("downloads.zig").path(alloc, m) else try alloc.dupeSentinel(u8, cfg.custom_model, 0);
        {
            const verify_start = glib.getMonotonicTime();
            defer if (self.telemetry) |metrics| {
                metrics.verification_us += glib.getMonotonicTime() - verify_start;
            };
            _ = try @import("downloads.zig").verify(filename, model, cancel);
        }
        const load_start = glib.getMonotonicTime();
        defer if (self.telemetry) |metrics| {
            metrics.load_us += glib.getMonotonicTime() - load_start;
        };
        if (mode == .embedding) {
            const architecture = try @import("gguf.zig").architecture(alloc, filename);
            if (!std.mem.eql(u8, architecture, registry.embedding_architecture)) return error.NotAnEmbeddingModel;
            // Conservative resident-memory guard before a second server loads.
            var st: std.os.linux.Statx = undefined;
            if (std.os.linux.statx(std.os.linux.AT.FDCWD, filename, 0, .{ .SIZE = true }, &st) != 0) return error.ModelNotInstalled;
            const weights = std.math.divCeil(u64, st.size, 1024 * 1024) catch return error.InvalidModelFile;
            if ((memory.availableMiB() orelse 0) < weights + 512) return error.SystemMemoryPressure;
        }
        const info = try probe.inspect(alloc, cfg.runtime, cfg.compute.mode != .cpu, cancel);
        if (mode == .embedding) try probe.requiredEmbedding(info.help);
        if (reasoning and !info.has("--reasoning-format")) return error.RuntimeReasoningUnsupported;
        self.executable = info.executable;
        self.version = info.version;
        const context_tokens: u32 = if (mode == .embedding) model.?.context_tokens else cfg.contextTokens();
        var layers: u16 = 0;
        if (cfg.compute.mode != .cpu) {
            const total = try @import("gguf.zig").layers(filename);
            layers = cfg.compute.offload_layers orelse total;
            if (layers > total) return error.InvalidOffloadLayers;
            // Budget includes conservative cache/working-space allowance.
            var st: std.os.linux.Statx = undefined;
            if (std.os.linux.statx(std.os.linux.AT.FDCWD, filename, 0, .{ .SIZE = true }, &st) != 0) return error.ModelNotInstalled;
            const weights = std.math.divCeil(u64, st.size, 1024 * 1024) catch return error.InvalidModelFile;
            const required = weights * layers / total + @as(u64, context_tokens) / 16 + 128;
            self.device = try compute.select(info.devices, cfg.compute, required);
            if (self.device) |device| {
                if (!info.has("--device") or !info.has("--split-mode")) return error.GpuRuntimeCapabilityMissing;
                if (device.shared and (memory.availableMiB() orelse 0) < required + 1024) return error.SystemMemoryPressure;
            } else self.fallback_reason = "No compatible GPU with sufficient available memory";
        }
        self.gpu = self.device != null;
        var random: [32]u8 = undefined;
        if (std.os.linux.getrandom(&random, random.len, 0) != random.len) return error.RandomUnavailable;
        const key = std.fmt.bytesToHex(random, .lower);
        self.authorization = try std.fmt.allocPrint(alloc, "Authorization: Bearer {s}", .{key});
        const temp = try std.fmt.allocPrintSentinel(alloc, "{s}/pearl-agent-key-XXXXXX", .{glib.getUserRuntimeDir()}, 0);
        const keyfd = glib.mkstempFull(temp, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CLOEXEC = true }), 0o600);
        if (keyfd < 0) return error.RuntimeDirectoryUnavailable;
        self.keyfile = temp;
        defer _ = std.c.close(keyfd);
        if (std.c.write(keyfd, &key, key.len) != key.len) return error.RuntimeKeyFailed;
        const reservation = gio.Socket.new(.ipv4, .stream, .tcp, null) orelse return error.RuntimePortUnavailable;
        defer reservation.unref();
        const ip = gio.InetAddress.newFromString("127.0.0.1").?;
        defer ip.unref();
        const address = gio.InetSocketAddress.new(ip, 0);
        defer address.unref();
        if (reservation.bind(address.as(gio.SocketAddress), 0, null) == 0) return error.RuntimePortUnavailable;
        const bound = reservation.getLocalAddress(null) orelse return error.RuntimePortUnavailable;
        defer bound.unref();
        const port = @import("gobject2").ext.cast(gio.InetSocketAddress, bound).?.getPort();
        self.base = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{port});
        _ = reservation.close(null);
        const launcher = gio.SubprocessLauncher.new(.{ .stdout_silence = true, .stderr_pipe = true });
        defer launcher.unref();
        const env = try alloc.allocSentinel(?[*:0]const u8, info.child_environment.len, null);
        for (info.child_environment, 0..) |value, i| env[i] = value.ptr;
        launcher.setEnviron(@ptrCast(env.ptr));
        if (cfg.cpu_threads != 0) launcher.setenv("OMP_NUM_THREADS", try std.fmt.allocPrintSentinel(alloc, "{d}", .{cfg.cpu_threads}, 0), 1);
        var setup: Setup = .{ .parent = c.getpid() };
        launcher.setChildSetup(childSetup, &setup, null);
        const port_z = try std.fmt.allocPrintSentinel(alloc, "{d}", .{port}, 0);
        const context = try std.fmt.allocPrintSentinel(alloc, "{d}", .{context_tokens}, 0);
        const threads = try std.fmt.allocPrintSentinel(alloc, "{d}", .{cfg.threads()}, 0);
        const alias: [:0]const u8 = if (mode == .embedding) embed.alias else "pearl-local";
        var args: std.ArrayList(?[*:0]const u8) = .empty;
        try args.appendSlice(alloc, &.{ info.executable, "-m", filename, "--alias", alias, "--host", "127.0.0.1", "--port", port_z, "--api-key-file", temp });
        if (mode == .chat and info.has("--jinja")) try args.append(alloc, "--jinja");
        try args.appendSlice(alloc, &.{ "--ctx-size", context, "--parallel", "1", "--threads", threads, "--threads-batch", threads, "--threads-http", "2", "--batch-size", if (mode == .embedding) "2048" else "128", "--ubatch-size", if (mode == .embedding) "512" else "64", "--gpu-layers", if (self.gpu) try std.fmt.allocPrintSentinel(alloc, "{d}", .{layers}, 0) else "0" });
        if (mode == .embedding) {
            try args.append(alloc, "--embeddings");
            // The GGUF carries mean pooling; request it explicitly where the
            // runtime exposes the switch so older metadata cannot change it.
            if (info.has("--pooling")) try args.appendSlice(alloc, &.{ "--pooling", "mean" });
        }
        for ([_][:0]const u8{ "--no-webui", "--no-agent", "--no-op-offload" }) |flag| if (info.has(flag)) {
            try args.append(alloc, flag);
        };
        if (!info.has("--no-webui") and info.has("--no-ui")) try args.append(alloc, "--no-ui");
        if (info.has("--fit")) try args.appendSlice(alloc, &.{ "--fit", "off" });
        if (info.has("--poll")) try args.appendSlice(alloc, &.{ "--poll", "0" });
        // Keep internal reasoning out of answer text and citation validation.
        if (mode == .chat and info.has("--reasoning-format")) try args.appendSlice(alloc, &.{ "--reasoning-format", "deepseek" });
        if (info.has("--device")) try args.appendSlice(alloc, &.{ "--device", if (self.device) |d| try alloc.dupeSentinel(u8, d.name, 0) else "none" });
        if (self.gpu) try args.appendSlice(alloc, &.{ "--split-mode", "none" });
        try args.append(alloc, null);
        if (!std.mem.eql(u8, info.fingerprint, try probe.fingerprint(alloc, info.executable))) return error.RuntimeChanged;
        self.process = launcher.spawnv(@ptrCast(args.items.ptr), null) orelse return error.RuntimeLaunchFailed;
        self.pid = try std.fmt.parseInt(c_int, std.mem.span(self.process.?.getIdentifier() orelse return error.RuntimeStartupFailed), 10);
        self.logfd = @as(*@import("giounix2").InputStream, @ptrCast(self.process.?.getStderrPipe().?)).getFd();
        for (0..150) |_| {
            if (cancel.isCancelled() != 0) return error.Cancelled;
            try self.monitor();
            if (self.process.?.getIdentifier() == null) return error.RuntimeStartupFailed;
            const ready = self.get(alloc, "/v1/models", cancel) catch |err| {
                if (err != error.RequestFailed and err != error.RequestTimedOut) return err;
                glib.usleep(200000);
                continue;
            };
            if (ready.status == 200 and std.mem.indexOf(u8, ready.bytes, alias) != null) {
                const unauth_path = if (mode == .embedding) "/v1/embeddings" else "/v1/chat/completions";
                const unauth = try fetch.request(alloc, .{ .url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ self.base, unauth_path }), .body = "{}", .private_endpoint = true, .timeout_seconds = 2 }, cancel);
                if (unauth.status != 401 and unauth.status != 403) return error.RuntimeAuthenticationMissing;
                var tools_warning: []const u8 = "";
                if (mode == .chat) {
                    _ = try @import("llama.zig").tokenCount(alloc, self, "Pearl local compatibility check", cancel);
                    tools_warning = try @import("model_check.zig").qualify(alloc, self, info.has("--jinja"), cancel);
                } else {
                    // Rejects non-finite, zero or wrong-width vectors before any
                    // document is indexed (silent-degradation failure class).
                    _ = try embed.vector(alloc, self, "Pearl local embedding compatibility check", cancel);
                }
                try self.monitor();
                if (self.gpu and self.offload_layers == 0) return error.GpuOffloadUnverified;
                if (!std.mem.eql(u8, info.fingerprint, try probe.fingerprint(alloc, info.executable))) return error.RuntimeChanged;
                if (cancel.isCancelled() != 0) return error.Cancelled;
                self.tools_available = mode == .chat and tools_warning.len == 0;
                self.tools_warning = tools_warning;
                self.deadline = 0;
                return;
            }
            glib.usleep(200000);
        }
        return error.RuntimeStartupFailed;
    }
    pub fn monitor(self: *Runtime) !void {
        if (self.telemetry) |metrics| if (metrics.skip) |skip| if (skip.load(.monotonic)) return error.BenchmarkSkipped;
        if (self.telemetry) |metrics| metrics.sample(self.pid);
        if (self.deadline != 0 and glib.getMonotonicTime() > self.deadline) return error.RuntimeCheckTimedOut;
        if (self.logfd >= 0) {
            var poll = [_]std.c.pollfd{.{ .fd = self.logfd, .events = std.c.POLL.IN, .revents = 0 }};
            for (0..32) |_| {
                if (std.c.poll(&poll, 1, 0) <= 0 or poll[0].revents & std.c.POLL.IN == 0) break;
                var bytes: [4096]u8 = undefined;
                const n = std.c.read(self.logfd, &bytes, bytes.len);
                if (n <= 0) break;
                if (self.logs.items.len + @as(usize, @intCast(n)) > 65536) self.logs.clearRetainingCapacity();
                try self.logs.appendSlice(self.arena.?.allocator(), bytes[0..@intCast(n)]);
                self.offload_layers = @max(self.offload_layers, compute.offloaded(self.logs.items));
            }
        }
        const now = glib.getMonotonicTime();
        if (self.pid > 0 and now - self.last_memory_check > 200000) {
            self.last_memory_check = now;
            memory.check(self.pid) catch |err| return if (err == error.MemoryInformationUnavailable) error.RuntimeExited else err;
        }
    }
    pub fn monitorCallback(context: *anyopaque) anyerror!void {
        try (@as(*Runtime, @ptrCast(@alignCast(context)))).monitor();
    }
    pub fn get(self: *Runtime, alloc: std.mem.Allocator, path: []const u8, cancel: *gio.Cancellable) !fetch.Response {
        return fetch.request(alloc, .{ .url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ self.base, path }), .headers = &.{self.authorization}, .private_endpoint = true, .timeout_seconds = 1, .monitor = .{ .context = self, .check = monitorCallback } }, cancel);
    }
    pub fn post(self: *Runtime, alloc: std.mem.Allocator, path: []const u8, body: []const u8, cancel: *gio.Cancellable) ![]const u8 {
        const response = try fetch.request(alloc, .{ .url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ self.base, path }), .headers = &.{ self.authorization, "Content-Type: application/json" }, .body = body, .private_endpoint = true, .timeout_seconds = 60, .monitor = .{ .context = self, .check = monitorCallback } }, cancel);
        if (response.status != 200) return error.InferenceFailed;
        return response.bytes;
    }
};
pub fn recoverable(err: anyerror) bool {
    return switch (err) {
        error.GpuUnavailableOrMemoryInsufficient, error.GpuRuntimeCapabilityMissing, error.GpuOffloadUnverified, error.RuntimeStartupFailed, error.RuntimeLaunchFailed, error.InferenceFailed, error.RequestFailed, error.RequestTimedOut, error.RuntimeExited, error.SystemMemoryPressure => true,
        else => false,
    };
}
// The Python fixture is copied into private temporary storage and serves only
// deterministic local responses. No model download, GPU or search is involved.
const QualificationFixture = struct {
    directory: [:0]const u8,
    executable: [:0]const u8,
    scenario: [:0]const u8,
    requests: [:0]const u8,
    model: [:0]const u8,
    fn write(path: [:0]const u8, bytes: []const u8) !void {
        const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c_uint, 0o700));
        if (fd < 0) return error.FixtureWriteFailed;
        defer _ = std.c.close(fd);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
            if (n <= 0) return error.FixtureWriteFailed;
            offset += @intCast(n);
        }
    }
    fn init(alloc: std.mem.Allocator) !QualificationFixture {
        var pattern = "/tmp/pearl-runtime-qualification-XXXXXX".*;
        const directory = glib.mkdtemp(&pattern) orelse return error.FixtureDirectoryFailed;
        const self: QualificationFixture = .{
            .directory = try alloc.dupeSentinel(u8, std.mem.span(directory), 0),
            .executable = try std.fmt.allocPrintSentinel(alloc, "{s}/qualification-fixture", .{directory}, 0),
            .scenario = try std.fmt.allocPrintSentinel(alloc, "{s}/qualification-fixture.scenario", .{directory}, 0),
            .requests = try std.fmt.allocPrintSentinel(alloc, "{s}/qualification-fixture.requests.jsonl", .{directory}, 0),
            .model = try std.fmt.allocPrintSentinel(alloc, "{s}/fixture.gguf", .{directory}, 0),
        };
        errdefer self.deinit();
        var buffer: [65536]u8 = undefined;
        try write(self.executable, try memory.read("tests/integration/test_agent_runtime.py", &buffer));
        try write(self.model, "GGUF\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00");
        return self;
    }
    fn deinit(self: QualificationFixture) void {
        for ([_][:0]const u8{ self.executable, self.scenario, self.requests, self.model }) |path| _ = std.c.unlink(path);
        _ = std.c.rmdir(self.directory);
    }
    fn select(self: QualificationFixture, scenario: []const u8) !void {
        try write(self.scenario, scenario);
        _ = std.c.unlink(self.requests);
    }
    fn configuration(self: QualificationFixture) config.Config {
        return .{ .enabled = true, .model_id = "custom", .custom_model = self.model, .runtime = .{ .source = .custom, .executable = self.executable } };
    }
    fn expectRequests(self: QualificationFixture, chat: usize, tools: usize, followup: usize) !void {
        var buffer: [32768]u8 = undefined;
        const bytes = try memory.read(self.requests, &buffer);
        try std.testing.expectEqual(chat, std.mem.count(u8, bytes, "\"kind\": \"chat\""));
        try std.testing.expectEqual(tools, std.mem.count(u8, bytes, "\"kind\": \"tools\""));
        try std.testing.expectEqual(followup, std.mem.count(u8, bytes, "\"kind\": \"followup\""));
    }
};

test "runtime qualifies chat separately from optional tools and resets capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fixture = try QualificationFixture.init(arena.allocator());
    defer fixture.deinit();
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    var runtime: Runtime = .{};
    defer runtime.stop();
    try std.testing.expect(!runtime.tools_available);
    try std.testing.expectEqualStrings("", runtime.tools_warning);
    for ([_][]const u8{ "good", "no_tools", "malformed_arguments", "unexpected_tool", "bad_followup", "http_tools", "truncated_tools", "no_jinja" }) |scenario| {
        try fixture.select(scenario);
        try runtime.ensure(fixture.configuration(), cancel);
        try std.testing.expect(runtime.process != null);
        const good = std.mem.eql(u8, scenario, "good");
        const no_jinja = std.mem.eql(u8, scenario, "no_jinja");
        try std.testing.expectEqual(good, runtime.tools_available);
        try std.testing.expectEqual(!good, std.mem.startsWith(u8, runtime.tools_warning, "Chat-only:"));
        try fixture.expectRequests(if (good or no_jinja) 1 else 2, if (no_jinja) 0 else 1, if (good or std.mem.eql(u8, scenario, "bad_followup")) 1 else 0);
        const warning = runtime.tools_warning;
        runtime.stop();
        try std.testing.expect(!runtime.tools_available);
        try std.testing.expectEqualStrings("", runtime.tools_warning);
        // Warning storage must not point into a released scratch/runtime arena.
        if (!good) try std.testing.expect(std.mem.startsWith(u8, warning, "Chat-only:"));
    }
}

test "runtime cannot downgrade failed chat or missing authentication to chat-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fixture = try QualificationFixture.init(arena.allocator());
    defer fixture.deinit();
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    var runtime: Runtime = .{};
    defer runtime.stop();
    for ([_]struct { scenario: []const u8, err: anyerror }{
        .{ .scenario = "empty_chat", .err = error.ModelChatIncompatible },
        .{ .scenario = "tool_in_chat", .err = error.ModelChatIncompatible },
        .{ .scenario = "chat_http", .err = error.InferenceFailed },
        .{ .scenario = "unhealthy_after_tools", .err = error.InferenceFailed },
        .{ .scenario = "no_auth", .err = error.RuntimeAuthenticationMissing },
        .{ .scenario = "missing_auth", .err = error.RuntimeCapabilityMissing },
    }) |case| {
        try fixture.select(case.scenario);
        try std.testing.expectError(case.err, runtime.ensure(fixture.configuration(), cancel));
        try std.testing.expect(runtime.process == null);
        try std.testing.expect(!runtime.tools_available);
        try std.testing.expectEqualStrings("", runtime.tools_warning);
    }
    cancel.cancel();
    try std.testing.expectError(error.Cancelled, runtime.ensure(fixture.configuration(), cancel));
    try std.testing.expect(runtime.process == null);
    try std.testing.expect(!runtime.tools_available);
}

test "runtime CPU retries requalify tools in both directions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fixture = try QualificationFixture.init(arena.allocator());
    defer fixture.deinit();
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    var runtime: Runtime = .{};
    defer runtime.stop();
    try fixture.select("good");
    const cfg = fixture.configuration();
    try runtime.ensure(cfg, cancel);
    try std.testing.expect(runtime.tools_available);
    try fixture.select("no_tools");
    try runtime.retryCpu(cfg, cancel);
    try std.testing.expect(!runtime.tools_available);
    try std.testing.expect(std.mem.startsWith(u8, runtime.tools_warning, "Chat-only:"));
    try fixture.expectRequests(2, 1, 0);
    // A live, unchanged runtime reuses qualification until explicitly retried.
    try runtime.ensure(cfg, cancel);
    try fixture.expectRequests(2, 1, 0);
    try fixture.select("good");
    try runtime.retryCpu(cfg, cancel);
    try std.testing.expect(runtime.tools_available);
    try std.testing.expectEqualStrings("", runtime.tools_warning);
    try fixture.expectRequests(1, 1, 1);
}

const Setup = struct { parent: c_int };
fn childSetup(data: ?*anyopaque) callconv(.c) void {
    const setup: *Setup = @ptrCast(@alignCast(data.?));
    _ = c.setpgid(0, 0);
    const parent = setup.parent;
    _ = c.prctl(c.PR_SET_PDEATHSIG, @as(c_int, c.SIGKILL), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
    if (c.getppid() != parent) c._exit(1);
    _ = c.setpriority(c.PRIO_PROCESS, 0, 10);
    const core: c.rlimit = .{ .rlim_cur = 0, .rlim_max = 0 };
    _ = c.setrlimit(c.RLIMIT_CORE, &core);
}
