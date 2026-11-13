//! Shared newline-delimited JSON-RPC 2.0 stdio connection.
//!
//! Used by both the ACP and MCP clients. One child process is spawned with
//! piped stdin/stdout. A reader thread parses bounded lines and correlates
//! responses to pending requests; a dispatcher thread delivers incoming
//! requests/notifications to the handler (which may block, e.g. for permission
//! prompts) without stalling response processing.
//!
//! Safety properties:
//!   * Bounded input: lines longer than the buffer are skipped and counted as
//!     protocol errors; malformed JSON is skipped, never fatal.
//!   * Fragmented input: reassembled by the buffered reader.
//!   * Disconnect: pending requests fail with error.Disconnected; the handler
//!     disconnect callback fires once.
//!   * Late responses: responses for unknown/expired request ids are ignored;
//!     pending slots are heap-owned and guarded so there is no use-after-free.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cancel = @import("cancel.zig");
const Token = cancel.Token;

pub const Message = struct {
    method: []const u8,
    id: ?i64,
    params: std.json.Value,
};

pub const Handler = struct {
    ctx: *anyopaque,
    /// Incoming request (id != null) or notification (id == null). Runs on the
    /// dispatcher thread and may block. Message memory is freed after return;
    /// copy anything you need to retain.
    handle: *const fn (ctx: *anyopaque, conn: *Connection, msg: Message) void,
    disconnect: ?*const fn (ctx: *anyopaque) void = null,
};

pub const Options = struct {
    cwd: ?[]const u8 = null,
    environ_map: ?*const std.process.Environ.Map = null,
    /// Maximum line length; longer lines are skipped as protocol errors.
    line_limit: usize = 1024 * 1024,
    /// Default request timeout (milliseconds).
    request_timeout_ms: u32 = 10000,
};

const Pending = struct {
    done: bool = false,
    disconnected: bool = false,
    result_json: ?[]u8 = null,
    error_code: ?i64 = null,
    error_message: ?[]u8 = null,
};

const Incoming = struct {
    arena: *std.heap.ArenaAllocator,
    method: []const u8,
    id: ?i64,
    params: std.json.Value,
};

const Queued = union(enum) {
    message: Incoming,
    disconnect: void,
};

pub const Connection = struct {
    allocator: Allocator,
    io: Io,
    child: std.process.Child,
    stdin: Io.File,
    stdout: Io.File,
    handler: Handler,
    line_limit: usize,
    default_timeout_ms: u32,

    write_mutex: Io.Mutex = .init,
    state_mutex: Io.Mutex = .init,
    queue_mutex: Io.Mutex = .init,
    pending_cond: Io.Condition = .init,
    queue_cond: Io.Condition = .init,

    pending: std.AutoHashMap(i64, *Pending),
    next_id: std.atomic.Value(i64) = std.atomic.Value(i64).init(1),
    queue: std.ArrayList(Queued) = .empty,
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    disconnect_queued: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    protocol_errors: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    threads_joined: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    dispatch_busy: bool = false,
    drain_cond: Io.Condition = .init,

    reader_thread: ?std.Thread = null,
    dispatcher_thread: ?std.Thread = null,

    pub fn start(allocator: Allocator, io: Io, argv: []const []const u8, handler: Handler, opts: Options) !*Connection {
        const self = try allocator.create(Connection);
        errdefer allocator.destroy(self);

        var cwd: std.process.Child.Cwd = .inherit;
        if (opts.cwd) |p| cwd = .{ .path = p };
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = cwd,
            .environ_map = opts.environ_map,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer child.kill(io);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .child = child,
            .stdin = child.stdin.?,
            .stdout = child.stdout.?,
            .handler = handler,
            .line_limit = opts.line_limit,
            .default_timeout_ms = opts.request_timeout_ms,
            .pending = std.AutoHashMap(i64, *Pending).init(allocator),
        };

        self.reader_thread = try std.Thread.spawn(.{ .allocator = allocator }, readerMain, .{self});
        errdefer if (self.reader_thread) |t| t.join();
        self.dispatcher_thread = try std.Thread.spawn(.{ .allocator = allocator }, dispatcherMain, .{self});
        return self;
    }

    pub fn isDisconnected(self: *const Connection) bool {
        return self.closed.load(.acquire);
    }

    pub fn protocolErrorCount(self: *const Connection) usize {
        return self.protocol_errors.load(.monotonic);
    }

    /// Send a request and wait for its result. The returned Value is allocated
    /// in `allocator` (pass an arena for convenient cleanup).
    pub fn request(self: *Connection, allocator: Allocator, method: []const u8, params: ?std.json.Value, timeout_ms: u32) !std.json.Value {
        return self.requestInner(allocator, method, params, timeout_ms, null);
    }

    pub fn requestCancel(self: *Connection, allocator: Allocator, method: []const u8, params: ?std.json.Value, timeout_ms: u32, token: *Token) !std.json.Value {
        return self.requestInner(allocator, method, params, timeout_ms, token);
    }

    fn requestInner(self: *Connection, allocator: Allocator, method: []const u8, params: ?std.json.Value, timeout_ms: u32, token: ?*Token) !std.json.Value {
        if (self.isDisconnected()) return error.Disconnected;
        const id = self.next_id.fetchAdd(1, .monotonic);

        const pending = try self.allocator.create(Pending);
        pending.* = .{};
        {
            self.state_mutex.lockUncancelable(self.io);
            defer self.state_mutex.unlock(self.io);
            try self.pending.put(id, pending);
        }

        self.send(.{ .id = id, .method = method, .params = params }) catch |err| {
            self.state_mutex.lockUncancelable(self.io);
            _ = self.pending.remove(id);
            self.state_mutex.unlock(self.io);
            self.allocator.destroy(pending);
            return err;
        };

        const effective_timeout = if (timeout_ms == 0) self.default_timeout_ms else timeout_ms;
        const deadline = Io.Clock.real.now(self.io).nanoseconds +
            @as(i96, effective_timeout) * std.time.ns_per_ms;

        var timed_out = false;
        var cancelled = false;
        {
            self.state_mutex.lockUncancelable(self.io);
            defer self.state_mutex.unlock(self.io);
            while (!pending.done) {
                if (self.isDisconnected()) {
                    pending.disconnected = true;
                    break;
                }
                if (token) |t| {
                    if (t.isCancelled()) {
                        cancelled = true;
                        break;
                    }
                }
                if (Io.Clock.real.now(self.io).nanoseconds >= deadline) {
                    timed_out = true;
                    break;
                }
                self.pending_cond.waitTimeout(self.io, &self.state_mutex, .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(20), .clock = .real } }) catch {};
            }
        }

        // Extract results and detach the slot under the lock, then free it.
        self.state_mutex.lockUncancelable(self.io);
        const result_json = pending.result_json;
        pending.result_json = null;
        const error_code = pending.error_code;
        const error_message = pending.error_message;
        pending.error_message = null;
        const was_done = pending.done;
        const was_disc = pending.disconnected;
        _ = self.pending.remove(id);
        self.state_mutex.unlock(self.io);
        self.allocator.destroy(pending);

        if (cancelled) {
            if (result_json) |r| self.allocator.free(r);
            if (error_message) |m| self.allocator.free(m);
            return error.Cancelled;
        }
        if (timed_out) {
            if (result_json) |r| self.allocator.free(r);
            if (error_message) |m| self.allocator.free(m);
            return error.Timeout;
        }
        if (was_disc or !was_done) {
            if (result_json) |r| self.allocator.free(r);
            if (error_message) |m| self.allocator.free(m);
            return error.Disconnected;
        }
        if (error_code != null) {
            if (result_json) |r| self.allocator.free(r);
            if (error_message) |m| self.allocator.free(m);
            return error.RemoteError;
        }
        if (result_json) |r| {
            defer self.allocator.free(r);
            return std.json.parseFromSliceLeaky(std.json.Value, allocator, r, .{});
        }
        return .null;
    }

    pub fn notify(self: *Connection, method: []const u8, params: ?std.json.Value) !void {
        try self.send(.{ .method = method, .params = params });
    }

    pub fn respond(self: *Connection, id: i64, result: std.json.Value) !void {
        try self.send(.{ .id = id, .result = result });
    }

    pub fn respondError(self: *Connection, id: i64, code: i64, message: []const u8) !void {
        try self.send(.{ .id = id, .err = .{ .code = code, .message = message } });
    }

    const Outgoing = struct {
        id: ?i64 = null,
        method: ?[]const u8 = null,
        params: ?std.json.Value = null,
        result: ?std.json.Value = null,
        err: ?struct { code: i64, message: []const u8 } = null,
    };

    fn send(self: *Connection, out: Outgoing) !void {
        if (self.isDisconnected()) return error.Disconnected;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var obj: std.json.ObjectMap = .empty;
        try obj.put(a, "jsonrpc", .{ .string = "2.0" });
        if (out.id) |i| try obj.put(a, "id", .{ .integer = i });
        if (out.method) |m| try obj.put(a, "method", .{ .string = m });
        if (out.params) |p| try obj.put(a, "params", p);
        if (out.result) |r| try obj.put(a, "result", r);
        if (out.err) |e| {
            var eo: std.json.ObjectMap = .empty;
            try eo.put(a, "code", .{ .integer = e.code });
            try eo.put(a, "message", .{ .string = e.message });
            try obj.put(a, "error", .{ .object = eo });
        }
        const value: std.json.Value = .{ .object = obj };
        const line = try std.json.Stringify.valueAlloc(a, value, .{});
        try self.sendRaw(line);
    }

    fn sendRaw(self: *Connection, line: []const u8) !void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.isDisconnected()) return error.Disconnected;
        var buf: [4096]u8 = undefined;
        var writer = self.stdin.writer(self.io, &buf);
        try writer.interface.writeAll(line);
        try writer.interface.writeAll("\n");
        try writer.interface.flush();
    }

    fn queueDisconnect(self: *Connection) void {
        if (self.disconnect_queued.swap(true, .acq_rel)) return;
        self.queue_mutex.lockUncancelable(self.io);
        self.queue.append(self.allocator, .disconnect) catch {};
        self.queue_mutex.unlock(self.io);
        self.queue_cond.broadcast(self.io);
    }

    fn failAllPending(self: *Connection) void {
        self.state_mutex.lockUncancelable(self.io);
        var it = self.pending.valueIterator();
        while (it.next()) |pending| {
            pending.*.disconnected = true;
            pending.*.done = true;
        }
        self.state_mutex.unlock(self.io);
        self.pending_cond.broadcast(self.io);
    }

    /// Idempotent: terminate the child, wake waiters, join threads.
    pub fn close(self: *Connection) void {
        // The reader may already have set `closed` after EOF; shutdown must
        // still kill the child and join both threads exactly once, otherwise
        // deinit would free the connection while they are still running.
        self.closed.store(true, .release);
        self.child.kill(self.io);
        self.failAllPending();
        self.queueDisconnect();
        self.queue_cond.broadcast(self.io);
        if (!self.threads_joined.swap(true, .acq_rel)) {
            if (self.reader_thread) |t| t.join();
            if (self.dispatcher_thread) |t| t.join();
        }
        // child.kill already closed and nulled the pipe handles; do not
        // close self.stdin/self.stdout again (double-close is a BADF panic).
    }

    /// Wait until the dispatcher has applied all queued incoming messages
    /// (including the one currently being handled). Bounded by timeout_ms.
    pub fn drain(self: *Connection, timeout_ms: u32) void {
        const deadline = Io.Clock.real.now(self.io).nanoseconds +
            @as(i96, timeout_ms) * std.time.ns_per_ms;
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        while ((self.queue.items.len > 0 or self.dispatch_busy) and !self.isDisconnected()) {
            if (Io.Clock.real.now(self.io).nanoseconds >= deadline) break;
            self.drain_cond.waitTimeout(self.io, &self.queue_mutex, .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(5), .clock = .real } }) catch {};
        }
    }

    pub fn deinit(self: *Connection) void {
        self.close();
        var it = self.pending.valueIterator();
        while (it.next()) |pending| {
            if (pending.*.result_json) |r| self.allocator.free(r);
            if (pending.*.error_message) |m| self.allocator.free(m);
            self.allocator.destroy(pending.*);
        }
        self.pending.deinit();
        for (self.queue.items) |item| {
            switch (item) {
                .message => |m| {
                    m.arena.deinit();
                    self.allocator.destroy(m.arena);
                },
                .disconnect => {},
            }
        }
        self.queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn readerMain(self: *Connection) void {
        const buffer = self.allocator.alloc(u8, self.line_limit) catch {
            self.closed.store(true, .release);
            self.failAllPending();
            self.queueDisconnect();
            return;
        };
        defer self.allocator.free(buffer);
        var file_reader = self.stdout.reader(self.io, buffer);
        const reader = &file_reader.interface;

        while (!self.isDisconnected()) {
            const line = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    _ = self.protocol_errors.fetchAdd(1, .monotonic);
                    _ = reader.discardDelimiterLimit('\n', .limited(16 * 1024 * 1024)) catch break;
                    continue;
                },
                error.ReadFailed => break,
            } orelse break;
            if (line.len == 0) continue;
            self.handleLine(line);
        }

        self.closed.store(true, .release);
        self.failAllPending();
        self.queueDisconnect();
    }

    fn handleLine(self: *Connection, line: []const u8) void {
        const arena = self.allocator.create(std.heap.ArenaAllocator) catch return;
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        const a = arena.allocator();
        var parsed = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch {
            _ = self.protocol_errors.fetchAdd(1, .monotonic);
            arena.deinit();
            self.allocator.destroy(arena);
            return;
        };
        // parsed uses arena `a`; keep arena alive for queued messages.
        if (parsed.value != .object) {
            _ = self.protocol_errors.fetchAdd(1, .monotonic);
            parsed.deinit();
            arena.deinit();
            self.allocator.destroy(arena);
            return;
        }
        const obj = parsed.value.object;
        if (obj.get("method")) |method_val| {
            if (method_val != .string) {
                parsed.deinit();
                arena.deinit();
                self.allocator.destroy(arena);
                return;
            }
            var id: ?i64 = null;
            if (obj.get("id")) |id_val| {
                if (id_val == .integer) id = id_val.integer;
            }
            const params = obj.get("params") orelse std.json.Value.null;
            const incoming: Incoming = .{
                .arena = arena,
                .method = method_val.string,
                .id = id,
                .params = params,
            };
            self.queue_mutex.lockUncancelable(self.io);
            self.queue.append(self.allocator, .{ .message = incoming }) catch {
                self.queue_mutex.unlock(self.io);
                parsed.deinit();
                arena.deinit();
                self.allocator.destroy(arena);
                return;
            };
            self.queue_mutex.unlock(self.io);
            self.queue_cond.signal(self.io);
            return;
        }
        if (obj.get("id")) |id_val| {
            if (id_val == .integer) {
                self.deliverResponse(id_val.integer, obj);
            }
        }
        parsed.deinit();
        arena.deinit();
        self.allocator.destroy(arena);
    }

    fn deliverResponse(self: *Connection, id: i64, obj: std.json.ObjectMap) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const pending = self.pending.get(id) orelse return; // late/unknown response ignored
        if (obj.get("error")) |err_val| {
            if (err_val == .object) {
                if (err_val.object.get("code")) |c| {
                    if (c == .integer) pending.error_code = c.integer;
                }
                if (err_val.object.get("message")) |m| {
                    if (m == .string) pending.error_message = self.allocator.dupe(u8, m.string) catch null;
                }
            }
            if (pending.error_code == null) pending.error_code = -1;
        } else if (obj.get("result")) |result_val| {
            pending.result_json = std.json.Stringify.valueAlloc(self.allocator, result_val, .{}) catch null;
        } else {
            pending.result_json = self.allocator.dupe(u8, "null") catch null;
        }
        pending.done = true;
        self.pending_cond.broadcast(self.io);
    }

    fn dispatcherMain(self: *Connection) void {
        while (true) {
            self.queue_mutex.lockUncancelable(self.io);
            while (self.queue.items.len == 0 and !self.isDisconnected()) {
                self.queue_cond.waitUncancelable(self.io, &self.queue_mutex);
            }
            if (self.queue.items.len == 0) {
                self.queue_mutex.unlock(self.io);
                break;
            }
            const item = self.queue.orderedRemove(0);
            self.dispatch_busy = true;
            self.queue_mutex.unlock(self.io);

            var disconnect = false;
            switch (item) {
                .message => |m| {
                    self.handler.handle(self.handler.ctx, self, .{ .method = m.method, .id = m.id, .params = m.params });
                    m.arena.deinit();
                    self.allocator.destroy(m.arena);
                },
                .disconnect => {
                    if (self.handler.disconnect) |d| d(self.handler.ctx);
                    disconnect = true;
                },
            }
            self.queue_mutex.lockUncancelable(self.io);
            self.dispatch_busy = false;
            self.drain_cond.broadcast(self.io);
            self.queue_mutex.unlock(self.io);
            if (disconnect) break;
        }
    }
};

test "spawn and close a trivial peer without leaks" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const H = struct {
        fn handle(_: *anyopaque, _: *Connection, _: Message) void {}
    };
    const conn = try Connection.start(a, io, &.{"/bin/cat"}, .{ .ctx = undefined, .handle = H.handle }, .{});
    conn.close();
    try std.testing.expect(conn.isDisconnected());
    conn.deinit();
}
