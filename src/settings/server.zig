//! Persistent Settings handshake endpoint, owned by the verified Pearl session.
//! Connection-owned transfers and a shared Pearl draft authority.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const wire = @import("../aqueous/transport.zig");
const protocol = @import("protocol.zig");
const limits: protocol.Limits = .{};
const a = std.heap.c_allocator;
pub const Server = struct {
    path: [:0]u8,
    display: [:0]u8,
    session: [32]u8,
    socket: ?*gio.Socket = null,
    source: ?*glib.Source = null,
    lock: ?std.os.linux.fd_t = null,
    owns_path: bool = false,
    slots: [limits.connections]Slot = undefined,
    initialized: bool = false,
    epoch: [32]u8,
    backend: ?@import("backend.zig").Backend = null,
    last_locked: bool = false,
    appearance_context: ?*anyopaque = null,
    appearance: ?*const fn (*anyopaque) @import("appearance.zig").Snapshot = null,
    pub fn init(runtime: []const u8, session: []const u8, display: []const u8) !Server {
        const path = try protocol.endpoint(a, runtime, session);
        errdefer a.free(path);
        const name = try @import("../cli/protocol.zig").displayPath(a, runtime, display);
        errdefer a.free(name);
        var random: [16]u8 = undefined;
        if (std.os.linux.getrandom(&random, random.len, 0) != random.len) return error.RandomUnavailable;
        return .{ .path = path, .display = name, .session = session[0..32].*, .epoch = std.fmt.bytesToHex(random, .lower) };
    }
    pub fn start(self: *Server) !void {
        if (self.backend) |*backend| {
            backend.service.observer_context = self;
            backend.service.observer = preferencesChanged;
            self.last_locked = backend.locked();
        }
        for (&self.slots) |*slot| {
            slot.* = .{ .owner = self, .wire = undefined };
            slot.wire = wire.Transport.init(slot, slotEvent);
            slot.wire.secure = true;
            slot.wire.framer.limit = limits.handshake_bytes;
        }
        self.initialized = true;
        const parent = std.fs.path.dirname(self.path).?;
        const base = std.fs.path.dirname(parent).?;
        try @import("../cli/server.zig").privateDirectory(base);
        try @import("../cli/server.zig").privateDirectory(parent);
        const lockpath = try std.fmt.allocPrintSentinel(a, "{s}/settings-backend.lock", .{parent}, 0);
        defer a.free(lockpath);
        const fd = std.os.linux.open(lockpath, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true }, 0o600);
        if (std.os.linux.errno(fd) != .SUCCESS) return error.LockFile;
        self.lock = @intCast(fd);
        if (std.os.linux.errno(std.os.linux.flock(self.lock.?, 2 | 4)) != .SUCCESS) return error.AlreadyRunning;
        // Only the lock owner may remove the previous instance's stale socket.
        const file = gio.File.newForPath(self.path);
        defer file.unref();
        var err: ?*glib.Error = null;
        defer if (err) |v| v.free();
        if (file.queryInfo("standard::type,unix::uid,unix::mode", .{ .nofollow_symlinks = true }, null, &err)) |info| {
            defer info.unref();
            if (info.getAttributeUint32("unix::uid") != std.os.linux.getuid() or info.getAttributeUint32("unix::mode") & 0o170000 != 0o140000) return error.UnsafeEndpoint;
            if (file.delete(null, &err) == 0) return error.UnsafeEndpoint;
        } else if (err.?.matches(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.not_found)) == 0) return error.UnsafeEndpoint;
        if (err) |v| {
            v.free();
            err = null;
        }
        const socket = gio.Socket.new(.unix, .stream, .default, &err) orelse return error.Socket;
        self.socket = socket;
        socket.setBlocking(0);
        const address = gio.UnixSocketAddress.new(self.path);
        defer address.unref();
        if (socket.bind(address.as(gio.SocketAddress), 0, &err) == 0) return error.Bind;
        self.owns_path = true;
        if (socket.listen(&err) == 0) return error.Listen;
        self.source = socket.createSource(.{ .in = true }, null);
        self.source.?.setCallback(@ptrCast(&accept), self, null);
        _ = self.source.?.attach(null);
    }
    pub fn preferencesChanged(context: *anyopaque) void {
        const self: *Server = @ptrCast(@alignCast(context));
        if (self.backend) |*backend| backend.changed();
        for (&self.slots) |*slot| if (slot.active and slot.peer.subscribed) {
            slot.dirty = true;
            slot.flush() catch slot.close();
        };
    }
    pub fn sessionChanged(self: *Server) void {
        const backend = if (self.backend) |*b| b else return;
        const locked = backend.locked();
        if (locked == self.last_locked) return;
        self.last_locked = locked;
        backend.changed();
        for (&self.slots) |*slot| if (slot.active and slot.state.ready) {
            if (locked) {
                slot.peer.clearTransfer();
                backend.release(&slot.peer);
            }
            slot.lock_dirty = true;
            slot.dirty = true;
            slot.flush() catch slot.close();
        };
    }
    pub fn deinit(self: *Server) void {
        if (self.backend) |*backend| {
            backend.service.observer = null;
            backend.service.observer_context = null;
        }
        if (self.source) |s| {
            s.destroy();
            s.unref();
        }
        if (self.initialized) for (&self.slots) |*slot| {
            slot.close();
            slot.wire.deinit();
        };
        if (self.socket) |s| {
            _ = s.close(null);
            s.unref();
        }
        if (self.owns_path) {
            const file = gio.File.newForPath(self.path);
            defer file.unref();
            _ = file.delete(null, null);
        }
        // Keep the lock inode in place so a new process cannot lock a different inode.
        if (self.lock) |fd| _ = std.os.linux.close(fd);
        a.free(self.path);
        a.free(self.display);
    }
    fn accept(socket: *gio.Socket, _: glib.IOCondition, context: ?*anyopaque) callconv(.c) c_int {
        const self: *Server = @ptrCast(@alignCast(context.?));
        for (0..limits.connections) |_| {
            const connection = socket.accept(null, null) orelse break;
            const target: ?*Slot = blk: {
                for (&self.slots) |*slot| if (!slot.active) break :blk slot;
                break :blk null;
            };
            if (target) |slot| {
                slot.wire.adopt(connection) catch continue;
                slot.active = true;
                slot.outgoing = .none;
                slot.state = .{};
                slot.closing = false;
                slot.deadline = glib.timeoutAdd(limits.handshake_ms, expired, slot);
            } else {
                _ = connection.close(null);
                connection.unref();
            }
        }
        return 1;
    }
    fn slotEvent(context: *anyopaque, event: wire.Event) void {
        const slot: *Slot = @ptrCast(@alignCast(context));
        switch (event) {
            .connected => {},
            .sent => {
                slot.outgoing = .none;
                if (slot.closing) slot.close() else if (slot.pending_input) |input| {
                    slot.pending_input = null;
                    defer {
                        std.crypto.secureZero(u8, input);
                        a.free(input);
                    }
                    slot.reply(input) catch slot.close();
                } else slot.flush() catch slot.close();
            },
            .failed => slot.close(),
            .frame => |bytes| {
                if (slot.pending_input != null or slot.outgoing == .reply or slot.processing) {
                    slot.close();
                    return;
                }
                if (slot.outgoing == .event) {
                    // An event may be partly written as the next request arrives.
                    // Retain one bounded input; never overwrite the output frame.
                    slot.pending_input = a.dupe(u8, bytes) catch {
                        slot.close();
                        return;
                    };
                } else slot.reply(bytes) catch slot.close();
            },
        }
    }
    fn expired(context: ?*anyopaque) callconv(.c) c_int {
        const slot: *Slot = @ptrCast(@alignCast(context.?));
        slot.deadline = 0;
        slot.close();
        return 0;
    }
};
const Slot = struct {
    owner: *Server,
    wire: wire.Transport,
    active: bool = false,
    outgoing: enum { none, reply, event } = .none,
    processing: bool = false,
    pending_input: ?[]u8 = null,
    deadline: c_uint = 0,
    transfer_timer: c_uint = 0,
    closing: bool = false,
    dirty: bool = false,
    lock_dirty: bool = false,
    state: protocol.Connection = .{},
    peer: @import("backend.zig").Peer = .{},
    fn close(self: *Slot) void {
        if (self.transfer_timer != 0) _ = glib.Source.remove(self.transfer_timer);
        self.transfer_timer = 0;
        self.wire.close();
        self.active = false;
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = 0;
        self.closing = false;
        self.state = .{};
        if (self.owner.backend) |*backend| backend.release(&self.peer);
        self.peer.deinit();
        self.dirty = false;
        self.lock_dirty = false;
        self.outgoing = .none;
        if (self.pending_input) |input| {
            std.crypto.secureZero(u8, input);
            a.free(input);
        }
        self.pending_input = null;
    }
    fn send(self: *Slot, alloc: std.mem.Allocator, payload: []const u8, kind: @FieldType(Slot, "outgoing")) !void {
        if (payload.len > limits.frame_bytes) return error.ResourceLimit;
        self.outgoing = kind;
        try self.wire.send(try std.fmt.allocPrint(alloc, "{s}\n", .{payload}));
    }
    fn flush(self: *Slot) !void {
        if (!self.active or self.processing or self.outgoing != .none or self.pending_input != null or !self.state.ready) return;
        const backend = if (self.owner.backend) |*b| b else return;
        if (!self.lock_dirty and (!self.dirty or !self.peer.subscribed)) return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const payload = if (self.lock_dirty) try std.json.Stringify.valueAlloc(alloc, .{ .settings = 1, .event = "lock.changed", .epoch = self.owner.epoch[0..], .revision = @import("editor_protocol.zig").num(backend.revision), .data = .{ .locked = self.owner.last_locked } }, .{}) else try std.json.Stringify.valueAlloc(alloc, .{ .settings = 1, .event = "state.changed", .epoch = self.owner.epoch[0..], .revision = @import("editor_protocol.zig").num(backend.revision), .data = .{ .domain = "pearl" } }, .{});
        if (self.lock_dirty) self.lock_dirty = false else self.dirty = false;
        try self.send(alloc, payload, .event);
    }
    fn transferExpired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Slot = @ptrCast(@alignCast(data.?));
        self.transfer_timer = 0;
        self.peer.expire();
        self.scheduleTransfer();
        return 0;
    }
    fn scheduleTransfer(self: *Slot) void {
        if (self.transfer_timer != 0) _ = glib.Source.remove(self.transfer_timer);
        self.transfer_timer = 0;
        if (self.peer.transfer) |transfer| {
            const delay = @max(1, transfer.deadline - @divTrunc(glib.getMonotonicTime(), 1000));
            self.transfer_timer = glib.timeoutAdd(@intCast(delay), transferExpired, self);
        }
    }
    fn reply(self: *Slot, bytes: []const u8) !void {
        self.processing = true;
        defer self.processing = false;
        defer self.scheduleTransfer();
        // A fixed decoder arena prevents nested JSON from amplifying a frame
        // into unbounded heap allocations. Only one callback runs at a time.
        const memory = try a.alloc(u8, 8 * 1024 * 1024);
        defer a.free(memory);
        var fixed = std.heap.FixedBufferAllocator.init(memory);
        const alloc = fixed.allocator();
        const request = protocol.parse(alloc, bytes) catch |err| {
            var error_buf: [1024]u8 = undefined;
            var fallback = std.heap.FixedBufferAllocator.init(&error_buf);
            try self.failure(fallback.allocator(), "0", if (err == error.OutOfMemory) error.ResourceLimit else if (err == error.Version) error.Version else error.InvalidRequest, true);
            return;
        };
        defer if (request.op == .@"prompt.answer") std.crypto.secureZero(u8, memory);
        self.state.accept(request, &self.owner.session, self.owner.display) catch |err| {
            try self.failure(alloc, request.id, err, true);
            return;
        };
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = glib.timeoutAdd(limits.idle_ms, Server.expired, self);
        if (self.owner.backend != null) self.wire.framer.limit = limits.frame_bytes;
        if (request.op != .hello and request.op != .ping) {
            if (!std.mem.eql(u8, request.epoch.?, &self.owner.epoch)) {
                try self.failure(alloc, request.id, error.StaleSession, true);
                return;
            }
            const backend = if (self.owner.backend) |*b| b else {
                try self.failure(alloc, request.id, error.Unsupported, false);
                return;
            };
            const result = backend.handle(&self.peer, request, alloc) catch |err| {
                // Leave room for a bounded error even after decoder exhaustion.
                var error_buf: [1024]u8 = undefined;
                var fallback = std.heap.FixedBufferAllocator.init(&error_buf);
                try self.failure(fallback.allocator(), request.id, if (err == error.OutOfMemory) error.ResourceLimit else err, false);
                return;
            };
            const prefix = try std.json.Stringify.valueAlloc(alloc, .{ .settings = 1, .id = request.id, .ok = true, .epoch = self.owner.epoch[0..] }, .{});
            const payload = try std.fmt.allocPrint(alloc, "{s},\"result\":{s}}}", .{ prefix[0 .. prefix.len - 1], result });
            try self.send(alloc, payload, .reply);
            return;
        }
        self.peer.expire();
        const payload = try std.json.Stringify.valueAlloc(alloc, .{
            .settings = protocol.version,
            .id = request.id,
            .ok = true,
            .result = .{
                .session = self.owner.session[0..],
                .display = self.owner.display,
                .epoch = self.owner.epoch[0..],
                .capabilities = protocol.Capabilities{ .community_themes = self.owner.backend != null, .theme_assets = self.owner.backend != null, .application_profiles = self.owner.backend != null, .committed_appearance = self.owner.appearance != null, .page_snapshots = self.owner.backend != null, .pearl_draft = self.owner.backend != null, .aqueous_draft = if (self.owner.backend) |backend| backend.aqueous != null else false, .display_preview = if (self.owner.backend) |backend| backend.aqueous != null else false, .live_controls = if (self.owner.backend) |backend| backend.live != null else false, .prompts = if (self.owner.backend) |backend| backend.live != null else false },
                .appearance = if (self.owner.appearance) |get| @as(?@import("appearance.zig").Snapshot, get(self.owner.appearance_context.?)) else null,
                .limits = limits,
            },
        }, .{});
        try self.send(alloc, payload, .reply);
    }
    fn failure(self: *Slot, alloc: std.mem.Allocator, id: []const u8, err: anyerror, close_after: bool) !void {
        self.closing = close_after;
        const payload = try std.json.Stringify.valueAlloc(alloc, .{ .settings = protocol.version, .id = id, .ok = false, .epoch = self.owner.epoch[0..], .err = .{ .code = @errorName(err) } }, .{});
        try self.send(alloc, payload, .reply);
    }
};
