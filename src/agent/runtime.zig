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
const c = @cImport({
    @cInclude("sys/prctl.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("sys/resource.h");
});
const a = std.heap.c_allocator;
pub const Runtime = struct {
    process: ?*gio.Subprocess = null,
    arena: ?std.heap.ArenaAllocator = null,
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
    group: memory.Group = .{},
    enforced_memory: bool = false,
    lockfd: c_int = -1,
    pid: c_int = 0,
    logfd: c_int = -1,
    logs: std.ArrayList(u8) = .empty,
    deadline: i64 = 0,
    last_memory_check: i64 = 0,
    pub fn stop(self: *Runtime) void {
        if (self.process) |p| {
            if (self.pid > 0) _ = std.c.kill(-self.pid, std.c.SIG.KILL);
            p.forceExit();
            _ = p.wait(null, null);
            p.unref();
        }
        self.group.close();
        if (self.lockfd >= 0) _ = std.c.close(self.lockfd);
        if (self.keyfile) |path| _ = std.c.unlink(path);
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
    pub fn ensure(self: *Runtime, cfg: config.Config, cancel: *gio.Cancellable) !void {
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        const resolved = try probe.resolve(temporary, cfg.runtime);
        const model_path = if (registry.find(cfg.model_id)) |model| try @import("downloads.zig").path(temporary, model) else try temporary.dupeZ(u8, cfg.custom_model);
        const model_identity = probe.fingerprint(temporary, model_path) catch return error.ModelNotInstalled;
        const identity = try std.json.Stringify.valueAlloc(a, .{ cfg.model_id, cfg.custom_model, cfg.cpu_threads, cfg.context_tokens, cfg.runtime, cfg.compute, try probe.fingerprint(temporary, resolved), model_identity }, .{});
        defer a.free(identity);
        if (self.process) |process| if (process.getIdentifier() != null and std.mem.eql(u8, identity, self.identity)) return;
        self.launch(cfg, cancel) catch |err| {
            if (cancel.isCancelled() != 0 or !cfg.compute.fallback() or !recoverable(err)) return err;
            var cpu = cfg;
            cpu.compute.mode = .cpu;
            try self.launch(cpu, cancel);
            self.fallback_reason = @errorName(err);
        };
        self.identity = try self.arena.?.allocator().dupe(u8, identity);
    }
    pub fn retryCpu(self: *Runtime, cfg: config.Config, cancel: *gio.Cancellable) !void {
        const identity = try a.dupe(u8, self.identity);
        defer a.free(identity);
        var cpu = cfg;
        cpu.compute.mode = .cpu;
        try self.launch(cpu, cancel);
        self.identity = try self.arena.?.allocator().dupe(u8, identity);
        self.fallback_reason = "GPU inference failed; continued on CPU";
    }
    fn launch(self: *Runtime, cfg: config.Config, cancel: *gio.Cancellable) !void {
        self.stop();
        self.arena = .init(a);
        errdefer self.stop();
        const alloc = self.arena.?.allocator();
        self.deadline = glib.getMonotonicTime() + 90 * std.time.us_per_s;
        const lockpath = try std.fmt.allocPrintSentinel(alloc, "{s}/pearl-assistant-runtime.lock", .{glib.getUserRuntimeDir()}, 0);
        self.lockfd = std.c.open(lockpath, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c_uint, 0o600));
        if (self.lockfd < 0 or fetch.c.flock(self.lockfd, fetch.c.LOCK_EX | fetch.c.LOCK_NB) != 0) return error.AssistantRuntimeBusy;
        const model = registry.find(cfg.model_id);
        const filename = if (model) |m| try @import("downloads.zig").path(alloc, m) else try alloc.dupeZ(u8, cfg.custom_model);
        _ = try @import("downloads.zig").verify(filename, model, cancel);
        const info = try probe.inspect(alloc, cfg.runtime, cfg.compute.mode != .cpu, cancel);
        self.executable = info.executable;
        self.version = info.version;
        var layers: u16 = 0;
        if (cfg.compute.mode != .cpu) {
            const total = try @import("gguf.zig").layers(filename);
            layers = cfg.compute.offload_layers orelse total;
            if (layers > total) return error.InvalidOffloadLayers;
            // Budget includes conservative cache/working-space allowance.
            const weights = if (model) |m| m.bytes / (1024 * 1024) else 768;
            const required = weights * layers / total + @as(u64, cfg.context_tokens) / 16 + 128;
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
        // GPU-capable runtimes may map driver address space even in CPU mode.
        // Bound resident host memory rather than virtual address reservations.
        self.group = memory.Group.create(alloc);
        self.enforced_memory = self.group.procs >= 0;
        if (self.group.procs >= 0) {
            launcher.takeFd(self.group.procs, 4);
            self.group.procs = -1;
        }
        var setup: Setup = .{ .group = self.enforced_memory, .parent = c.getpid() };
        launcher.setChildSetup(childSetup, &setup, null);
        const port_z = try std.fmt.allocPrintSentinel(alloc, "{d}", .{port}, 0);
        const context = try std.fmt.allocPrintSentinel(alloc, "{d}", .{cfg.context_tokens}, 0);
        const threads = try std.fmt.allocPrintSentinel(alloc, "{d}", .{cfg.cpu_threads}, 0);
        var args: std.ArrayList(?[*:0]const u8) = .empty;
        try args.appendSlice(alloc, &.{ info.executable, "-m", filename, "--alias", "pearl-local", "--host", "127.0.0.1", "--port", port_z, "--api-key-file", temp, "--jinja", "--ctx-size", context, "--parallel", "1", "--threads", threads, "--threads-batch", threads, "--threads-http", "2", "--batch-size", "128", "--ubatch-size", "64", "--gpu-layers", if (self.gpu) try std.fmt.allocPrintSentinel(alloc, "{d}", .{layers}, 0) else "0" });
        for ([_][:0]const u8{ "--no-webui", "--no-agent", "--no-op-offload" }) |flag| if (info.has(flag)) {
            try args.append(alloc, flag);
        };
        if (!info.has("--no-webui") and info.has("--no-ui")) try args.append(alloc, "--no-ui");
        if (info.has("--fit")) try args.appendSlice(alloc, &.{ "--fit", "off" });
        if (info.has("--poll")) try args.appendSlice(alloc, &.{ "--poll", "0" });
        if (info.has("--device")) try args.appendSlice(alloc, &.{ "--device", if (self.device) |d| try alloc.dupeZ(u8, d.name) else "none" });
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
                if (err != error.RequestFailed) return err;
                glib.usleep(200000);
                continue;
            };
            if (ready.status == 200 and std.mem.indexOf(u8, ready.bytes, "pearl-local") != null) {
                const unauth = try fetch.request(alloc, .{ .url = try std.fmt.allocPrint(alloc, "{s}/v1/chat/completions", .{self.base}), .body = "{}", .private_endpoint = true, .timeout_seconds = 2 }, cancel);
                if (unauth.status != 401 and unauth.status != 403) return error.RuntimeAuthenticationMissing;
                _ = try @import("llama.zig").tokenCount(alloc, self, "Pearl local compatibility check", cancel);
                try @import("model_check.zig").check(alloc, self, cancel);
                try self.monitor();
                if (self.gpu and self.offload_layers == 0) return error.GpuOffloadUnverified;
                if (!std.mem.eql(u8, info.fingerprint, try probe.fingerprint(alloc, info.executable))) return error.RuntimeChanged;
                self.deadline = 0;
                return;
            }
            glib.usleep(200000);
        }
        return error.RuntimeStartupFailed;
    }
    pub fn monitor(self: *Runtime) !void {
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
        error.GpuUnavailableOrMemoryInsufficient, error.GpuRuntimeCapabilityMissing, error.GpuOffloadUnverified, error.RuntimeStartupFailed, error.RuntimeLaunchFailed, error.InferenceFailed, error.RequestFailed, error.RuntimeExited, error.RuntimeMemoryBudgetExceeded, error.SystemMemoryPressure => true,
        else => false,
    };
}
const Setup = struct { group: bool, parent: c_int };
fn childSetup(data: ?*anyopaque) callconv(.c) void {
    const setup: *Setup = @ptrCast(@alignCast(data.?));
    _ = c.setpgid(0, 0);
    if (setup.group) {
        if (std.c.write(4, "0", 1) != 1) c._exit(1);
        _ = std.c.close(4);
    }
    const parent = setup.parent;
    _ = c.prctl(c.PR_SET_PDEATHSIG, @as(c_int, c.SIGKILL), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
    if (c.getppid() != parent) c._exit(1);
    _ = c.setpriority(c.PRIO_PROCESS, 0, 10);
    const core: c.rlimit = .{ .rlim_cur = 0, .rlim_max = 0 };
    _ = c.setrlimit(c.RLIMIT_CORE, &core);
}
