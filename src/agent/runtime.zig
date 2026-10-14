//! One privately packaged llama-server, authenticated loopback, CPU only.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const fetch = @import("fetch.zig");
const config = @import("config.zig");
const registry = @import("model_registry.zig");
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
    pub fn stop(self: *Runtime) void {
        if (self.process) |p| {
            p.forceExit();
            _ = p.wait(null, null);
            p.unref();
        }
        if (self.keyfile) |path| _ = std.c.unlink(path);
        if (self.arena) |*memory| memory.deinit();
        self.* = .{};
    }
    pub fn ensure(self: *Runtime, cfg: config.Config, cancel: *gio.Cancellable) !void {
        const identity = try std.fmt.allocPrint(a, "{s}:{s}:{d}:{d}", .{ cfg.model_id, cfg.custom_model, cfg.cpu_threads, cfg.context_tokens });
        defer a.free(identity);
        if (self.process) |process| if (process.getIdentifier() != null and std.mem.eql(u8, identity, self.identity)) return;
        self.stop();
        self.arena = .init(a);
        errdefer self.stop();
        const alloc = self.arena.?.allocator();
        const model = registry.find(cfg.model_id);
        const filename = if (model) |m| try @import("downloads.zig").path(alloc, m) else try alloc.dupeZ(u8, cfg.custom_model);
        _ = try @import("downloads.zig").verify(filename, model, cancel);
        var exe: [4096]u8 = undefined;
        const own = try @import("../settings/distribution.zig").executable(&exe);
        const executable = try std.fmt.allocPrintSentinel(alloc, "{s}/../libexec/pearl/assistant/llama-server", .{std.fs.path.dirname(own).?}, 0);
        if (std.c.access(executable, std.c.X_OK) != 0) return error.AssistantRuntimeNotInstalled;
        const manifest = try std.fmt.allocPrintSentinel(alloc, "{s}/runtime.json", .{std.fs.path.dirname(executable).?}, 0);
        const fd = std.c.open(manifest, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c_uint, 0));
        if (fd < 0) return error.RuntimeManifestMissing;
        defer _ = std.c.close(fd);
        var manifest_bytes: [1024]u8 = undefined;
        const n = std.c.read(fd, &manifest_bytes, manifest_bytes.len);
        if (n <= 0 or n == manifest_bytes.len) return error.RuntimeManifestInvalid;
        const pin = std.json.parseFromSliceLeaky(struct { version: []const u8, commit: []const u8, source_sha256: []const u8, cpu_only: bool }, alloc, manifest_bytes[0..@intCast(n)], .{}) catch return error.RuntimeManifestInvalid;
        if (!pin.cpu_only or !std.mem.eql(u8, pin.version, "v0.6.0") or !std.mem.eql(u8, pin.commit, "d81235049384534c167caea52b85a694f6103d14") or !std.mem.eql(u8, pin.source_sha256, "6b58785f0a82898f4c3442417ff962e2d4b231b1bee5d033902ad90b27901e14")) return error.RuntimeVersionMismatch;
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
        const launcher = gio.SubprocessLauncher.new(.{ .stdout_silence = true, .stderr_silence = !@import("build_options").test_hooks });
        defer launcher.unref();
        const environment = [_:null]?[*:0]const u8{ "PATH=/usr/bin", "LANG=C.UTF-8", "MALLOC_ARENA_MAX=2", "OMP_NUM_THREADS=2" };
        launcher.setEnviron(@ptrCast(@constCast(&environment)));
        launcher.setChildSetup(childSetup, null, null);
        const port_z = try std.fmt.allocPrintSentinel(alloc, "{d}", .{port}, 0);
        const context = try std.fmt.allocPrintSentinel(alloc, "{d}", .{cfg.context_tokens}, 0);
        const threads = try std.fmt.allocPrintSentinel(alloc, "{d}", .{cfg.cpu_threads}, 0);
        const argv = [_:null]?[*:0]const u8{ executable, "-m", filename, "--alias", "pearl-local", "--host", "127.0.0.1", "--port", port_z, "--api-key-file", temp, "--jinja", "--no-webui", "--no-agent", "--ctx-size", context, "--parallel", "1", "--threads", threads, "--threads-batch", threads, "--threads-http", "2", "--batch-size", "128", "--ubatch-size", "64", "--gpu-layers", "0", "--poll", "0" };
        self.process = launcher.spawnv(@ptrCast(&argv), null) orelse return error.RuntimeLaunchFailed;
        for (0..150) |_| {
            if (cancel.isCancelled() != 0) return error.Cancelled;
            if (self.process.?.getIdentifier() == null) return error.RuntimeStartupFailed;
            const ready = self.get(alloc, "/v1/models", cancel) catch {
                glib.usleep(200000);
                continue;
            };
            if (ready.status == 200 and std.mem.indexOf(u8, ready.bytes, "pearl-local") != null) {
                self.identity = try alloc.dupe(u8, identity);
                if (model == null) try @import("model_check.zig").check(alloc, self, cancel);
                return;
            }
            glib.usleep(200000);
        }
        return error.RuntimeStartupFailed;
    }
    pub fn get(self: *Runtime, alloc: std.mem.Allocator, path: []const u8, cancel: *gio.Cancellable) !fetch.Response {
        return fetch.request(alloc, .{ .url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ self.base, path }), .headers = &.{self.authorization}, .private_endpoint = true, .timeout_seconds = 1 }, cancel);
    }
    pub fn post(self: *Runtime, alloc: std.mem.Allocator, path: []const u8, body: []const u8, cancel: *gio.Cancellable) ![]const u8 {
        const response = try fetch.request(alloc, .{ .url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ self.base, path }), .headers = &.{ self.authorization, "Content-Type: application/json" }, .body = body, .private_endpoint = true, .timeout_seconds = 60 }, cancel);
        if (response.status != 200) return error.InferenceFailed;
        return response.bytes;
    }
};
fn childSetup(_: ?*anyopaque) callconv(.c) void {
    const parent = c.getppid();
    _ = c.prctl(c.PR_SET_PDEATHSIG, @as(c_int, c.SIGKILL), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
    if (c.getppid() != parent) c._exit(1);
    _ = c.setpriority(c.PRIO_PROCESS, 0, 10);
    const core: c.rlimit = .{ .rlim_cur = 0, .rlim_max = 0 };
    _ = c.setrlimit(c.RLIMIT_CORE, &core);
    const memory: c.rlimit = .{ .rlim_cur = 1536 * 1024 * 1024, .rlim_max = 1536 * 1024 * 1024 };
    _ = c.setrlimit(c.RLIMIT_AS, &memory);
}
