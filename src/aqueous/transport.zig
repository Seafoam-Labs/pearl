//! Main-context-only nonblocking Unix stream. No worker, polling or C shim.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const codec = @import("codec.zig");
const a = std.heap.c_allocator;
pub const Event = union(enum) { connected, sent, frame: []const u8, failed: anyerror };
pub const Transport = struct {
    socket: ?*gio.Socket = null,
    source: ?*glib.Source = null,
    framer: codec.Framer,
    output: ?[]u8 = null,
    /// Credential-bearing Settings channels clear owned I/O buffers on release.
    secure: bool = false,
    offset: usize = 0,
    sent: usize = 0,
    connecting: bool = false,
    generation: u64 = 0,
    context: *anyopaque,
    notify: *const fn (*anyopaque, Event) void,
    // Also lets the integration probe force deterministic short writes.
    write_chunk: usize = 64 * 1024,
    pub fn init(context: *anyopaque, notify: *const fn (*anyopaque, Event) void) Transport {
        return .{ .context = context, .notify = notify, .framer = codec.Framer.init(a, (codec.Limits{}).frame_bytes) catch unreachable };
    }
    pub fn deinit(self: *Transport) void {
        self.close();
        self.framer.deinit();
    }
    pub fn close(self: *Transport) void {
        self.generation +%= 1;
        self.disarm();
        if (self.socket) |s| {
            _ = s.close(null);
            s.unref();
        }
        self.socket = null;
        if (self.output) |p| { if (self.secure) std.crypto.secureZero(u8, p); a.free(p); }
        self.output = null;
        self.offset = 0;
        if (self.secure) std.crypto.secureZero(u8, self.framer.buffer.items);
        self.framer.reset();
    }
    pub fn open(self: *Transport, path: [:0]const u8) !void {
        self.close();
        var err: ?*glib.Error = null;
        defer if (err) |v| v.free();
        const s = gio.Socket.new(.unix, .stream, .default, &err) orelse return error.Socket;
        self.socket = s;
        errdefer self.close();
        s.setBlocking(0);
        const addr = gio.UnixSocketAddress.new(path.ptr);
        defer addr.unref();
        self.connecting = true;
        if (s.connect(addr.as(gio.SocketAddress), null, &err) == 0 and !is(err, .pending) and !is(err, .would_block)) return error.Connect;
        try self.arm();
    }
    /// Takes ownership of an accepted socket, including on failure.
    pub fn adopt(self: *Transport, socket: *gio.Socket) !void {
        self.close();
        self.socket = socket;
        self.connecting = false;
        errdefer self.close();
        socket.setBlocking(0);
        var err: ?*glib.Error = null;
        defer if (err) |v| v.free();
        const cred = socket.getCredentials(&err) orelse return error.PeerCredentials;
        defer cred.unref();
        const uid = cred.getUnixUser(&err);
        if (!peerAllowed(err == null, uid, std.os.linux.getuid())) return error.PeerCredentials;
        try self.arm();
    }
    /// Copies one LF-terminated request; ownership stays entirely in this channel.
    pub fn send(self: *Transport, frame: []const u8) !void {
        if (self.socket == null or self.connecting) return error.Disconnected;
        if (self.output != null) return error.Busy;
        self.output = try a.dupe(u8, frame);
        self.offset = 0;
        self.sent = 0;
        try self.arm();
    }
    /// Kernel identity of the connected, same-user server; never supplied by IPC.
    pub fn peerPid(self: *Transport) ?u32 {
        if (self.connecting) return null;
        const socket = self.socket orelse return null;
        var err: ?*glib.Error = null;
        defer if (err) |e| e.free();
        const credentials = socket.getCredentials(&err) orelse return null;
        defer credentials.unref();
        const uid = credentials.getUnixUser(&err);
        if (!peerAllowed(err == null, uid, std.os.linux.getuid())) return null;
        const pid = credentials.getUnixPid(&err);
        return if (err == null and pid > 0) @intCast(pid) else null;
    }
    fn disarm(self: *Transport) void {
        if (self.source) |s| {
            s.destroy();
            s.unref();
        }
        self.source = null;
    }
    const Token = struct { owner: *Transport, generation: u64 };
    fn freeToken(data: ?*anyopaque) callconv(.c) void {
        a.destroy(@as(*Token, @ptrCast(@alignCast(data.?))));
    }
    fn arm(self: *Transport) !void {
        const token = try a.create(Token);
        token.* = .{ .owner = self, .generation = self.generation };
        self.disarm();
        const s = self.socket.?.createSource(.{ .in = true, .out = self.connecting or self.output != null, .hup = true, .err = true }, null);
        self.source = s;
        s.setCallback(@ptrCast(&ready), token, freeToken);
        _ = s.attach(null);
    }
    fn ready(_: *gio.Socket, condition: glib.IOCondition, data: ?*anyopaque) callconv(.c) c_int {
        // Copy before any callback can destroy the source and its token.
        const token = @as(*Token, @ptrCast(@alignCast(data.?))).*;
        const self = token.owner;
        if (self.generation != token.generation) return 0;
        self.pump(condition, token.generation) catch |err| {
            if (self.generation == token.generation) self.notify(self.context, .{ .failed = err });
        };
        return 1;
    }
    fn pump(self: *Transport, condition: glib.IOCondition, generation: u64) !void {
        var err: ?*glib.Error = null;
        defer if (err) |v| v.free();
        const socket = self.socket.?;
        if (self.connecting) {
            if (socket.checkConnectResult(&err) == 0) return error.Connect;
            const cred = socket.getCredentials(&err) orelse return error.PeerCredentials;
            defer cred.unref();
            const uid = cred.getUnixUser(&err);
            if (!peerAllowed(err == null, uid, std.os.linux.getuid())) return error.PeerCredentials;
            self.connecting = false;
            self.notify(self.context, .connected);
            if (self.generation != generation) return;
        }
        if (condition.out) {
            if (self.output) |p| {
                const count = socket.send(p.ptr + self.offset, @min(p.len - self.offset, self.write_chunk), null, &err);
                if (count < 0) {
                    if (!is(err, .would_block)) return error.Write;
                } else {
                    if (count == 0) return error.Write;
                    self.offset += @intCast(count);
                    self.sent += @intCast(count);
                    if (self.offset == p.len) {
                        if (self.secure) std.crypto.secureZero(u8, p);
                        a.free(p);
                        self.output = null;
                        self.notify(self.context, .sent);
                        if (self.generation != generation) return;
                    }
                }
            }
        }
        if (err) |v| {
            v.free();
            err = null;
        }
        if (condition.in or condition.hup) {
            var buffer: [16384]u8 = undefined;
            defer if (self.secure) std.crypto.secureZero(u8, &buffer);
            var budget: usize = 256 * 1024;
            while (budget > 0) {
                const count = socket.receive(&buffer, buffer.len, null, &err);
                if (count < 0) {
                    if (is(err, .would_block)) break;
                    return error.Read;
                }
                if (count == 0) {
                    try self.framer.finish();
                    return error.Eof;
                }
                var input: []const u8 = buffer[0..@intCast(count)];
                budget -= input.len;
                while (input.len > 0) {
                    const read = try self.framer.push(input);
                    input = input[read.consumed..];
                    if (read.frame) |frame| self.notify(self.context, .{ .frame = frame });
                    if (self.generation != generation) return;
                    if (read.frame != null and self.secure) std.crypto.secureZero(u8, self.framer.buffer.items);
                }
            }
        }
        if (condition.err or condition.nval) return error.Socket;
        if (self.generation == generation) try self.arm();
    }
};
fn is(err: ?*glib.Error, code: gio.IOErrorEnum) bool {
    return if (err) |v| v.matches(gio.ioErrorQuark(), @intFromEnum(code)) != 0 else false;
}

fn peerAllowed(queried: bool, peer: u32, own: u32) bool {
    return queried and peer == own;
}
test "peer credential failures reject even when fallback uid matches" {
    try std.testing.expect(peerAllowed(true, 1000, 1000));
    try std.testing.expect(!peerAllowed(true, 1001, 1000));
    try std.testing.expect(!peerAllowed(false, 1000, 1000));
}
