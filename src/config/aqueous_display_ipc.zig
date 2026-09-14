//! Worker-owned persistent native IPC connection. Bounded deadlines, no shell bridge.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const m = @import("aqueous_model.zig");
const contract = @import("aqueous_contract.zig");
pub const Client = struct {
    socket: *gio.Socket,
    cancel: *gio.Cancellable,
    session: [32]u8 = undefined,
    serial: u64 = 0,
    detail: [128:0]u8 = @splat(0),
    pub fn open(a: std.mem.Allocator, cancel: *gio.Cancellable) !Client {
        const path = glib.getenv("AQUEOUS_SOCKET") orelse return error.AqueousUnavailable;
        const socket = gio.Socket.new(.unix, .stream, .default, null) orelse return error.AqueousUnavailable;
        errdefer socket.unref();
        socket.setTimeout(3);
        const addr = gio.UnixSocketAddress.new(path);
        defer addr.unref();
        if (socket.connect(addr.as(gio.SocketAddress), cancel, null) == 0) return error.AqueousUnavailable;
        errdefer _ = socket.close(null);
        const creds = socket.getCredentials(null) orelse return error.PeerCredentials;
        defer creds.unref();
        if (creds.getUnixUser(null) != std.os.linux.getuid()) return error.PeerCredentials;
        socket.setBlocking(0);
        var self: Client = .{ .socket = socket, .cancel = cancel };
        const hello = try self.call(a, "hello", struct {}{});
        const caps = m.get(hello, "capabilities");
        for ([_][]const u8{ "display_preview_v1", "display_preview_commit_v1", "display_observation_v1", "commands" }) |cap| if (!try contract.boolean(caps, cap)) return error.DisplayCapabilityUnavailable;
        @memcpy(&self.session, try contract.hex(hello, "session", 32));
        return self;
    }
    pub fn close(self: *Client) void {
        _ = self.socket.close(null);
        self.socket.unref();
    }
    pub fn call(self: *Client, a: std.mem.Allocator, op: []const u8, params: anytype) !m.Value {
        self.serial += 1;
        const id = try std.fmt.allocPrint(a, "{d}", .{self.serial});
        const request = try std.json.Stringify.valueAlloc(a, .{ .ipc = 1, .id = id, .op = op, .params = params, .session = if (self.serial == 1) @as(?[]const u8, null) else &self.session }, .{ .emit_null_optional_fields = false });
        const frame = try std.fmt.allocPrint(a, "{s}\n", .{request});
        const limit = (@import("../aqueous/codec.zig").Limits{}).frame_bytes;
        if (request.len > 65536) return error.RequestTooLarge;
        const deadline = glib.getMonotonicTime() + 3000000;
        var offset: usize = 0;
        while (offset < frame.len) {
            try self.wait(.{ .out = true }, deadline);
            const n = self.socket.send(frame[offset..].ptr, frame.len - offset, self.cancel, null);
            if (n <= 0) return error.NativeWriteFailed;
            offset += @intCast(n);
        }
        var bytes: std.ArrayList(u8) = .empty;
        while (true) {
            try self.wait(.{ .in = true }, deadline);
            var chunk: [8192]u8 = undefined;
            const n = self.socket.receive(&chunk, chunk.len, self.cancel, null);
            if (n <= 0) return error.NativeReadFailed;
            if (bytes.items.len + @as(usize, @intCast(n)) > limit) return error.ResponseTooLarge;
            try bytes.appendSlice(a, chunk[0..@intCast(n)]);
            if (std.mem.indexOfScalar(u8, bytes.items, '\n')) |end| {
                if (end + 1 != bytes.items.len) return error.InvalidNativeReply;
                const reply = try m.parse(a, bytes.items[0..end], limit);
                try contract.version(reply, "ipc", 1);
                if (!std.mem.eql(u8, try contract.text(reply, "id", 64), id)) return error.InvalidNativeReply;
                if (!try contract.boolean(reply, "ok")) {
                    const code = m.str(m.get(m.get(reply, "error"), "code"));
                    self.detail = @splat(0);
                    const size = @min(code.len, self.detail.len);
                    @memcpy(self.detail[0..size], code[0..size]);
                    return error.NativeRejected;
                }
                return m.get(reply, "result");
            }
        }
    }
    fn wait(self: *Client, condition: glib.IOCondition, deadline: i64) !void {
        if (self.cancel.isCancelled() != 0) return error.Cancelled;
        const remaining = deadline - glib.getMonotonicTime();
        if (remaining <= 0 or self.socket.conditionTimedWait(condition, remaining, self.cancel, null) == 0) return error.NativeTimedOut;
    }
};
