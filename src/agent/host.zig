//! Shell-owned process lifetime and acknowledged launcher handoff.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const wire = @import("../aqueous/transport.zig");
const config = @import("config.zig");
const protocol = @import("protocol.zig");
const c = @import("fetch.zig").c;
const a = std.heap.c_allocator;
pub const Host = struct {
    process: ?*gio.Subprocess = null,
    transport: ?wire.Transport = null,
    sequence: u64 = 0,
    pending: u64 = 0,
    deadline: c_uint = 0,
    locked: bool = true,
    palette: @import("../theme/theme.zig").Palette = @import("../theme/theme.zig").dark,
    context: ?*anyopaque = null,
    acknowledge: ?*const fn (*anyopaque, bool) void = null,
    open_settings: ?*const fn (*anyopaque) void = null,
    queued: ?[]u8 = null,
    compute: protocol.ComputeStatus = .{},
    pub fn stop(self: *Host) void {
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = 0;
        if (self.transport) |*t| t.deinit();
        self.transport = null;
        if (self.process) |p| {
            p.forceExit();
            _ = p.wait(null, null);
            p.unref();
        }
        self.process = null;
        if (self.queued) |q| a.free(q);
        self.queued = null;
        self.pending = 0;
        self.compute = .{};
    }
    pub fn configure(self: *Host, cfg: config.Config) void {
        if (!cfg.enabled) {
            self.stop();
            return;
        }
        if (self.process != null and !self.locked) self.send(.{ .id = self.next(), .op = .configure, .config = cfg, .palette = self.palette }) catch self.stop();
    }
    pub fn setLocked(self: *Host, locked: bool) void {
        if (self.locked == locked) return;
        self.locked = locked;
        if (locked and self.process != null) self.send(.{ .id = self.next(), .op = .@"suspend" }) catch self.stop();
    }
    fn next(self: *Host) u64 {
        self.sequence += 1;
        return self.sequence;
    }
    pub fn clear(self: *Host) !void {
        if (self.locked) return error.AssistantUnavailable;
        if (self.process != null) try self.send(.{ .id = self.next(), .op = .clear });
    }
    pub fn releaseRuntime(self: *Host) !void {
        if (self.locked) return error.AssistantUnavailable;
        if (self.compute.busy or self.pending != 0) return error.AssistantBusy;
        if (self.process != null) try self.send(.{ .id = self.next(), .op = .release_runtime });
    }
    pub fn cancelAnswer(self: *Host) !void {
        if (self.locked) return error.AssistantUnavailable;
        if (self.process != null) try self.send(.{ .id = self.next(), .op = .stop });
    }
    pub fn ask(self: *Host, cfg: config.Config, question: []const u8, activation: []const u8) !void {
        if (!cfg.enabled or self.locked) return error.AssistantUnavailable;
        if (self.pending != 0) return error.AssistantBusy;
        if (self.process == null) try self.start();
        const id = self.next();
        try self.send(.{ .id = id, .op = if (question.len == 0) .@"resume" else .ask, .config = cfg, .question = question, .activation = activation, .palette = self.palette });
        self.pending = id;
        self.deadline = glib.timeoutAdd(5000, expired, self);
    }
    fn start(self: *Host) !void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var buffer: [4096]u8 = undefined;
        const exe = try @import("../settings/distribution.zig").executable(&buffer);
        const helper = if (@import("build_options").test_hooks and glib.getenv("PEARL_TEST_AGENT") != null)
            try alloc.dupeSentinel(u8, std.mem.span(glib.getenv("PEARL_TEST_AGENT").?), 0)
        else
            try std.fmt.allocPrintSentinel(alloc, "{s}/pearl-agent{s}", .{ std.fs.path.dirname(exe).?, if (@import("../settings/distribution.zig").isGit(exe)) "-git" else "" }, 0);
        if (std.c.access(helper, std.c.X_OK) != 0) return error.AssistantNotInstalled;
        var pair: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &pair) != 0) return error.AssistantSocket;
        var parent_owned = true;
        defer {
            if (parent_owned) _ = c.close(pair[0]);
        }
        const launcher = gio.SubprocessLauncher.new(.{ .stdout_silence = true, .stderr_silence = !@import("build_options").test_hooks });
        launcher.setenv("PEARL_SESSION_LANGUAGES", @import("i18n").sessionLanguages(), 1);
        defer launcher.unref();
        launcher.takeFd(pair[1], 3);
        const argv = [_:null]?[*:0]const u8{ helper, "--shell-fd=3" };
        self.process = launcher.spawnv(@ptrCast(&argv), null) orelse return error.AssistantLaunchFailed;
        errdefer self.stop();
        self.transport = wire.Transport.init(self, event);
        self.transport.?.secure = true;
        self.transport.?.framer.limit = 32768;
        const socket = gio.Socket.newFromFd(pair[0], null) orelse return error.AssistantSocket;
        parent_owned = false;
        try self.transport.?.adopt(socket);
    }
    fn send(self: *Host, request: protocol.Request) !void {
        const text = try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false });
        defer a.free(text);
        const frame = try std.fmt.allocPrint(a, "{s}\n", .{text});
        if (self.transport.?.output != null) {
            // Config/lock changes coalesce; asks cannot replace an outstanding handoff.
            if (self.queued) |old| a.free(old);
            self.queued = frame;
        } else {
            defer a.free(frame);
            try self.transport.?.send(frame);
        }
    }
    fn event(context: *anyopaque, value: wire.Event) void {
        const self: *Host = @ptrCast(@alignCast(context));
        switch (value) {
            .connected => {},
            .sent => if (self.queued) |q| {
                self.queued = null;
                defer a.free(q);
                self.transport.?.send(q) catch self.stop();
            },
            .failed => {
                const pending = self.pending != 0;
                self.stop();
                if (pending) if (self.acknowledge) |notify| notify(self.context.?, false);
            },
            .frame => |bytes| {
                const reply = std.json.parseFromSlice(protocol.Reply, a, bytes, .{}) catch {
                    self.stop();
                    return;
                };
                defer reply.deinit();
                if (reply.value.agent != 1) {
                    self.stop();
                    return;
                }
                if (reply.value.settings) if (self.open_settings) |open| open(self.context.?);
                if (reply.value.compute) |compute_status| self.compute = compute_status;
                if (reply.value.id == self.pending) {
                    self.pending = 0;
                    if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
                    self.deadline = 0;
                    if (self.acknowledge) |notify| notify(self.context.?, reply.value.ok);
                }
            },
        }
    }
    fn expired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Host = @ptrCast(@alignCast(data.?));
        self.deadline = 0;
        self.stop();
        if (self.acknowledge) |notify| notify(self.context.?, false);
        return 0;
    }
};
