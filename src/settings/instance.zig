//! Per-session frontend activation endpoint. No global D-Bus forwarding.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const wire = @import("../aqueous/transport.zig");
const protocol = @import("activation.zig");
const limits: @import("protocol.zig").Limits = .{};
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
    context: *anyopaque,
    handle: *const fn (*anyopaque, protocol.Request, std.mem.Allocator) anyerror![]const u8,
    pub fn init(runtime: []const u8, session: []const u8, display: []const u8, context: *anyopaque, handle: @FieldType(Server, "handle")) !Server {
        const path = try protocol.endpoint(a, runtime, session);
        errdefer a.free(path);
        const name = try @import("../cli/protocol.zig").displayPath(a, runtime, display);
        return .{ .path = path, .display = name, .session = session[0..32].*, .context = context, .handle = handle };
    }
    pub fn start(self: *Server) !void {
        for (&self.slots) |*slot| {
            slot.* = .{ .owner = self, .wire = undefined };
            slot.wire = wire.Transport.init(slot, slotEvent);
            slot.wire.framer.limit = limits.handshake_bytes;
        }
        self.initialized = true;
        const parent = std.fs.path.dirname(self.path).?;
        const base = std.fs.path.dirname(parent).?;
        try @import("../cli/server.zig").privateDirectory(base);
        try @import("../cli/server.zig").privateDirectory(parent);
        const lockpath = try std.fmt.allocPrintSentinel(a, "{s}/settings-app.lock", .{parent}, 0);
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
    pub fn deinit(self: *Server) void {
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
                slot.responding = false;
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
                if (slot.closing) {
                    slot.close();
                } else slot.responding = false;
            },
            .failed => slot.close(),
            .frame => |bytes| {
                if (slot.responding) {
                    slot.close();
                    return;
                }
                slot.responding = true;
                slot.reply(bytes) catch {
                    slot.close();
                };
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
    responding: bool = false,
    deadline: c_uint = 0,
    closing: bool = false,
    fn close(self: *Slot) void {
        self.wire.close();
        self.active = false;
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = 0;
        self.closing = false;
    }
    fn reply(self: *Slot, bytes: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const request = protocol.parse(alloc, bytes, @import("build_options").test_hooks) catch |err| return self.failure(alloc, err);
        if (!std.mem.eql(u8, request.session, &self.owner.session)) return self.failure(alloc, error.StaleSession);
        if (!std.mem.eql(u8, request.display, self.owner.display)) return self.failure(alloc, error.DisplayMismatch);
        const result = self.owner.handle(self.owner.context, request, alloc) catch |err| return self.failure(alloc, err);
        self.closing = true;
        const frame = try std.fmt.allocPrint(alloc, "{{\"settings\":1,\"ok\":true,\"result\":{s}}}\n", .{result});
        if (frame.len > (if (@import("build_options").test_hooks and request.op == .probe) limits.frame_bytes else limits.handshake_bytes)) return error.ResponseTooLarge;
        try self.wire.send(frame);
    }
    fn failure(self: *Slot, alloc: std.mem.Allocator, err: anyerror) !void {
        self.closing = true;
        const payload = try std.json.Stringify.valueAlloc(alloc, .{ .settings = 1, .ok = false, .err = .{ .code = @errorName(err) } }, .{});
        try self.wire.send(try std.fmt.allocPrint(alloc, "{s}\n", .{payload}));
    }
};
