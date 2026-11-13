//! Agent Client Protocol (ACP) v1 JSON-RPC stdio client.
//!
//! Wraps the shared rpc.Connection with ACP semantics: initialize with
//! protocolVersion 1 and capability negotiation (omitted agent capabilities
//! default to false), session/new, session/prompt with streamed session/update
//! notifications, session/cancel, and agent->client requests for permission,
//! filesystem (writes routed through the host's review flow) and terminals.
//!
//! Disconnect and late-response safety are inherited from rpc.Connection.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const rpc = @import("rpc.zig");
const cancel = @import("cancel.zig");
const Token = cancel.Token;

pub const protocol_version: i64 = 1;

pub const PermissionDecision = union(enum) {
    select: []const u8,
    cancel: void,
};

pub const TerminalOutput = struct {
    output: []const u8,
    truncated: bool = false,
    exit_code: ?i32 = null,
};

/// Host callbacks supplied by the engine. Blocking callbacks (permission,
/// writeTextFile) run on the dispatcher thread and may wait for the UI.
pub const AcpHost = struct {
    ctx: *anyopaque,
    onSessionUpdate: *const fn (ctx: *anyopaque, session_id: []const u8, update: std.json.Value) void,
    requestPermission: *const fn (ctx: *anyopaque, session_id: []const u8, params: std.json.Value) PermissionDecision,
    readTextFile: *const fn (ctx: *anyopaque, allocator: Allocator, session_id: []const u8, path: []const u8) anyerror![]u8,
    writeTextFile: *const fn (ctx: *anyopaque, session_id: []const u8, path: []const u8, content: []const u8) anyerror!void,
    terminalCreate: *const fn (ctx: *anyopaque, session_id: []const u8, command: []const u8, args: []const []const u8, cwd: ?[]const u8) anyerror![]u8,
    terminalOutput: *const fn (ctx: *anyopaque, allocator: Allocator, session_id: []const u8, terminal_id: []const u8) anyerror!TerminalOutput,
    terminalWait: *const fn (ctx: *anyopaque, session_id: []const u8, terminal_id: []const u8) anyerror!i32,
    terminalKill: *const fn (ctx: *anyopaque, session_id: []const u8, terminal_id: []const u8) void,
    terminalRelease: *const fn (ctx: *anyopaque, session_id: []const u8, terminal_id: []const u8) void,
    onDisconnect: ?*const fn (ctx: *anyopaque) void = null,
};

pub const Capabilities = struct {
    load_session: bool = false,
    prompt_image: bool = false,
    prompt_audio: bool = false,
    prompt_embedded_context: bool = false,
};

const empty_obj: std.json.Value = .{ .object = .empty };

pub const AcpClient = struct {
    allocator: Allocator,
    io: Io,
    conn: *rpc.Connection,
    host: AcpHost,
    capabilities: Capabilities = .{},
    negotiated_version: i64 = 0,

    pub fn start(allocator: Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8, host: AcpHost, opts: rpc.Options) !*AcpClient {
        const self = try allocator.create(AcpClient);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .conn = undefined,
            .host = host,
        };
        self.conn = try rpc.Connection.start(allocator, io, argv, .{
            .ctx = self,
            .handle = handle,
            .disconnect = handleDisconnect,
        }, blk: {
            var options = opts;
            if (cwd) |p| options.cwd = p;
            break :blk options;
        });
        return self;
    }

    pub fn initialize(self: *AcpClient, timeout_ms: u32) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var fs: std.json.ObjectMap = .empty;
        try fs.put(a, "readTextFile", .{ .bool = true });
        try fs.put(a, "writeTextFile", .{ .bool = true });
        var caps: std.json.ObjectMap = .empty;
        try caps.put(a, "fs", .{ .object = fs });
        try caps.put(a, "terminal", .{ .bool = true });
        var params: std.json.ObjectMap = .empty;
        try params.put(a, "protocolVersion", .{ .integer = protocol_version });
        try params.put(a, "clientCapabilities", .{ .object = caps });

        const result = try self.conn.request(a, "initialize", .{ .object = params }, timeout_ms);
        if (result != .object) return error.InvalidResponse;
        const version = result.object.get("protocolVersion") orelse return error.InvalidResponse;
        if (version != .integer or version.integer != protocol_version) return error.UnsupportedProtocol;
        self.negotiated_version = version.integer;

        if (result.object.get("agentCapabilities")) |ac| {
            if (ac == .object) {
                if (ac.object.get("loadSession")) |v| {
                    if (v == .bool) self.capabilities.load_session = v.bool;
                }
                if (ac.object.get("promptCapabilities")) |pc| {
                    if (pc == .object) {
                        if (pc.object.get("image")) |v| {
                            if (v == .bool) self.capabilities.prompt_image = v.bool;
                        }
                        if (pc.object.get("audio")) |v| {
                            if (v == .bool) self.capabilities.prompt_audio = v.bool;
                        }
                        if (pc.object.get("embeddedContext")) |v| {
                            if (v == .bool) self.capabilities.prompt_embedded_context = v.bool;
                        }
                    }
                }
            }
        }
    }

    /// Create a session bound to `cwd` (the worktree root). Returns owned id.
    pub fn newSession(self: *AcpClient, allocator: Allocator, cwd: []const u8, timeout_ms: u32) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var params: std.json.ObjectMap = .empty;
        try params.put(a, "cwd", .{ .string = cwd });
        try params.put(a, "mcpServers", .{ .array = std.json.Array.init(a) });
        const result = try self.conn.request(a, "session/new", .{ .object = params }, timeout_ms);
        if (result != .object) return error.InvalidResponse;
        const sid = result.object.get("sessionId") orelse return error.InvalidResponse;
        if (sid != .string) return error.InvalidResponse;
        return allocator.dupe(u8, sid.string);
    }

    /// Send a prompt; session/update notifications stream via the host while
    /// this blocks. Returns the owned stopReason. Cancellation sends
    /// session/cancel and returns error.Cancelled.
    pub fn prompt(self: *AcpClient, allocator: Allocator, session_id: []const u8, text: []const u8, token: *Token, timeout_ms: u32) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var block: std.json.ObjectMap = .empty;
        try block.put(a, "type", .{ .string = "text" });
        try block.put(a, "text", .{ .string = text });
        var prompt_arr = std.json.Array.init(a);
        try prompt_arr.append(.{ .object = block });
        var params: std.json.ObjectMap = .empty;
        try params.put(a, "sessionId", .{ .string = session_id });
        try params.put(a, "prompt", .{ .array = prompt_arr });

        const result = self.conn.requestCancel(a, "session/prompt", .{ .object = params }, timeout_ms, token) catch |err| {
            if (err == error.Cancelled) self.cancel(session_id);
            return err;
        };
        var stop_reason: []const u8 = "end_turn";
        if (result == .object) {
            if (result.object.get("stopReason")) |sr| {
                if (sr == .string) stop_reason = sr.string;
            }
        }
        return allocator.dupe(u8, stop_reason);
    }

    pub fn cancel(self: *AcpClient, session_id: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var params: std.json.ObjectMap = .empty;
        params.put(a, "sessionId", .{ .string = session_id }) catch return;
        self.conn.notify("session/cancel", .{ .object = params }) catch {};
    }

    pub fn isDisconnected(self: *const AcpClient) bool {
        return self.conn.isDisconnected();
    }

    /// Wait for queued session updates to be applied by the dispatcher.
    pub fn drain(self: *AcpClient, timeout_ms: u32) void {
        self.conn.drain(timeout_ms);
    }

    pub fn close(self: *AcpClient) void {
        self.conn.close();
    }

    pub fn deinit(self: *AcpClient) void {
        self.conn.deinit();
        self.allocator.destroy(self);
    }

    fn handleDisconnect(ctx: *anyopaque) void {
        const self: *AcpClient = @ptrCast(@alignCast(ctx));
        if (self.host.onDisconnect) |d| d(self.host.ctx);
    }

    fn handle(ctx: *anyopaque, conn: *rpc.Connection, msg: rpc.Message) void {
        const self: *AcpClient = @ptrCast(@alignCast(ctx));
        const host = self.host;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const params = if (msg.params == .object) msg.params.object else null;
        const session_id = blk: {
            if (params) |p| {
                if (p.get("sessionId")) |s| {
                    if (s == .string) break :blk s.string;
                }
            }
            break :blk "";
        };

        if (std.mem.eql(u8, msg.method, "session/update")) {
            const update = if (params) |p| (p.get("update") orelse empty_obj) else empty_obj;
            host.onSessionUpdate(host.ctx, session_id, update);
            return;
        }

        const id = msg.id orelse return; // remaining methods are requests

        if (std.mem.eql(u8, msg.method, "session/request_permission")) {
            const decision = host.requestPermission(host.ctx, session_id, msg.params);
            var outcome: std.json.ObjectMap = .empty;
            switch (decision) {
                .select => |option_id| {
                    outcome.put(a, "outcome", .{ .string = "selected" }) catch return;
                    outcome.put(a, "optionId", .{ .string = option_id }) catch return;
                },
                .cancel => outcome.put(a, "outcome", .{ .string = "cancelled" }) catch return,
            }
            var result: std.json.ObjectMap = .empty;
            result.put(a, "outcome", .{ .object = outcome }) catch return;
            conn.respond(id, .{ .object = result }) catch {};
            return;
        }

        if (std.mem.eql(u8, msg.method, "fs/read_text_file")) {
            const path = getString(params, "path") orelse {
                conn.respondError(id, -32602, "missing path") catch {};
                return;
            };
            const content = host.readTextFile(host.ctx, a, session_id, path) catch |err| {
                conn.respondError(id, -32000, @errorName(err)) catch {};
                return;
            };
            var result: std.json.ObjectMap = .empty;
            result.put(a, "content", .{ .string = content }) catch return;
            conn.respond(id, .{ .object = result }) catch {};
            return;
        }

        if (std.mem.eql(u8, msg.method, "fs/write_text_file")) {
            const path = getString(params, "path") orelse {
                conn.respondError(id, -32602, "missing path") catch {};
                return;
            };
            const content = getString(params, "content") orelse "";
            host.writeTextFile(host.ctx, session_id, path, content) catch |err| {
                conn.respondError(id, -32000, @errorName(err)) catch {};
                return;
            };
            conn.respond(id, empty_obj) catch {};
            return;
        }

        if (std.mem.eql(u8, msg.method, "terminal/create")) {
            const command = getString(params, "command") orelse {
                conn.respondError(id, -32602, "missing command") catch {};
                return;
            };
            var args: std.ArrayList([]const u8) = .empty;
            if (params) |p| {
                if (p.get("args")) |av| {
                    if (av == .array) {
                        for (av.array.items) |item| {
                            if (item == .string) args.append(a, item.string) catch {};
                        }
                    }
                }
            }
            const cwd = getString(params, "cwd");
            const terminal_id = host.terminalCreate(host.ctx, session_id, command, args.items, cwd) catch |err| {
                conn.respondError(id, -32000, @errorName(err)) catch {};
                return;
            };
            defer self.allocator.free(terminal_id);
            var result: std.json.ObjectMap = .empty;
            result.put(a, "terminalId", .{ .string = terminal_id }) catch return;
            conn.respond(id, .{ .object = result }) catch {};
            return;
        }

        if (std.mem.eql(u8, msg.method, "terminal/output")) {
            const tid = getString(params, "terminalId") orelse {
                conn.respondError(id, -32602, "missing terminalId") catch {};
                return;
            };
            const out = host.terminalOutput(host.ctx, a, session_id, tid) catch |err| {
                conn.respondError(id, -32000, @errorName(err)) catch {};
                return;
            };
            var result: std.json.ObjectMap = .empty;
            result.put(a, "output", .{ .string = out.output }) catch return;
            result.put(a, "truncated", .{ .bool = out.truncated }) catch return;
            if (out.exit_code) |code| {
                var es: std.json.ObjectMap = .empty;
                es.put(a, "exitCode", .{ .integer = code }) catch return;
                result.put(a, "exitStatus", .{ .object = es }) catch return;
            }
            conn.respond(id, .{ .object = result }) catch {};
            return;
        }

        if (std.mem.eql(u8, msg.method, "terminal/wait_for_exit")) {
            const tid = getString(params, "terminalId") orelse {
                conn.respondError(id, -32602, "missing terminalId") catch {};
                return;
            };
            const code = host.terminalWait(host.ctx, session_id, tid) catch |err| {
                conn.respondError(id, -32000, @errorName(err)) catch {};
                return;
            };
            var result: std.json.ObjectMap = .empty;
            result.put(a, "exitCode", .{ .integer = code }) catch return;
            conn.respond(id, .{ .object = result }) catch {};
            return;
        }

        if (std.mem.eql(u8, msg.method, "terminal/kill")) {
            const tid = getString(params, "terminalId") orelse {
                conn.respondError(id, -32602, "missing terminalId") catch {};
                return;
            };
            host.terminalKill(host.ctx, session_id, tid);
            conn.respond(id, empty_obj) catch {};
            return;
        }

        if (std.mem.eql(u8, msg.method, "terminal/release")) {
            const tid = getString(params, "terminalId") orelse {
                conn.respondError(id, -32602, "missing terminalId") catch {};
                return;
            };
            host.terminalRelease(host.ctx, session_id, tid);
            conn.respond(id, empty_obj) catch {};
            return;
        }

        conn.respondError(id, -32601, "method not found") catch {};
    }

    fn getString(params: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const p = params orelse return null;
        const v = p.get(key) orelse return null;
        if (v != .string) return null;
        return v.string;
    }
};

test "Capabilities default to false" {
    const caps: Capabilities = .{};
    try std.testing.expect(!caps.load_session);
    try std.testing.expect(!caps.prompt_image);
    try std.testing.expect(!caps.prompt_embedded_context);
}
