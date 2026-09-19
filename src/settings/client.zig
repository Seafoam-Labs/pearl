//! Async verified frontend connection, bounded editor requests and change events.
const std = @import("std");
const glib = @import("glib2");
const gio = @import("gio2");
const wire = @import("../aqueous/transport.zig");
const codec = @import("../aqueous/codec.zig");
const protocol = @import("protocol.zig");
const e = @import("../aqueous/entities.zig");
const a = std.heap.c_allocator;
pub const Operation = @FieldType(protocol.Request, "op");
pub const Reply = struct { op: Operation, result: std.json.Value, error_code: ?[]const u8 = null };
pub const Event = union(enum) { verified, connected: ?@import("appearance.zig").Snapshot, reply: Reply, changed, locked: bool, failed: anyerror };
pub const Client = struct {
    transport: wire.Transport = undefined,
    context: *anyopaque,
    notify: *const fn (*anyopaque, Event) void,
    runtime: []const u8,
    display: [:0]const u8,
    aqueous_path: [:0]const u8,
    native: ?[32]u8 = null,
    session: ?[32]u8 = null,
    epoch: ?[32]u8 = null,
    phase: enum { idle, aqueous, identity, backend } = .idle,
    sequence: u64 = 0,
    waiting: bool = false,
    operation: Operation = .hello,
    capabilities: protocol.Capabilities = .{},
    refresh_appearance: bool = false,
    deadline: c_uint = 0,
    heartbeat: c_uint = 0,
    appearance_transfer: ?@import("asset_transfer.zig").Transfer = null,
    appearance_json: ?[]u8 = null,
    asset_provider: @import("../theme/assets.zig").Provider = .{},
    asset_revision: ?u64 = null,
    pub fn init(self: *Client) void {
        self.transport = wire.Transport.init(self, event);
        self.transport.secure = true;
    }
    pub fn deinit(self: *Client) void {
        self.stop();
        self.asset_provider.deinit();
        self.transport.deinit();
    }
    pub fn stop(self: *Client) void {
        self.clearAppearanceTransfer();
        self.asset_revision = null;
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        if (self.heartbeat != 0) _ = glib.Source.remove(self.heartbeat);
        self.deadline = 0;
        self.heartbeat = 0;
        self.phase = .idle;
        self.waiting = false;
        self.transport.close();
    }
    pub fn begin(self: *Client) void {
        self.stop();
        self.session = null;
        self.capabilities = .{};
        self.refresh_appearance = false;
        self.epoch = null;
        self.phase = .aqueous;
        self.deadline = glib.timeoutAdd(5000, expired, self);
        self.transport.framer.limit = (codec.Limits{}).frame_bytes;
        self.transport.open(self.aqueous_path) catch |err| self.fail(err);
    }
    pub fn nativeChanged(self: *Client, identity: ?[32]u8) void {
        self.native = identity;
        if (self.session) |session| {
            if (identity == null or !std.mem.eql(u8, &session, &identity.?)) {
                self.fail(error.DisplayMismatch);
                return;
            }
        }
        self.verify() catch |err| self.fail(err);
    }
    fn fail(self: *Client, err: anyerror) void {
        self.stop();
        self.notify(self.context, .{ .failed = err });
    }
    fn event(context: *anyopaque, value: wire.Event) void {
        const self: *Client = @ptrCast(@alignCast(context));
        switch (value) {
            .sent => {},
            .failed => |err| self.fail(err),
            .connected => self.send() catch |err| self.fail(err),
            .frame => |bytes| self.receive(bytes) catch |err| self.fail(err),
        }
    }
    fn send(self: *Client) !void {
        if (self.phase == .aqueous) {
            try self.transport.send("{\"ipc\":1,\"id\":\"1\",\"op\":\"hello\",\"params\":{}}\n");
            return;
        }
        self.operation = if (self.sequence == 0) .hello else .ping;
        self.sequence += 1;
        var id: [20]u8 = undefined;
        const heartbeat_request: protocol.Request = .{ .settings = 1, .id = try std.fmt.bufPrint(&id, "{d}", .{self.sequence}), .session = &self.session.?, .display = self.display, .op = if (self.sequence == 1) .hello else .ping };
        const json = try std.json.Stringify.valueAlloc(a, heartbeat_request, .{ .emit_null_optional_fields = false });
        defer a.free(json);
        const frame = try std.fmt.allocPrint(a, "{s}\n", .{json});
        defer a.free(frame);
        self.waiting = true;
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = glib.timeoutAdd(5000, expired, self);
        try self.transport.send(frame);
    }
    pub fn request(self: *Client, op: Operation, params: anytype) !void {
        if (self.phase != .backend or self.epoch == null) return error.Unavailable;
        if (self.waiting) return error.Busy;
        const json = try std.json.Stringify.valueAlloc(a, .{ .settings = 1, .id = @import("editor_protocol.zig").num(self.sequence + 1), .session = self.session.?[0..], .display = self.display, .epoch = self.epoch.?[0..], .op = op, .params = params }, .{ .emit_null_optional_fields = false });
        defer {
            if (op == .@"prompt.answer") std.crypto.secureZero(u8, json);
            a.free(json);
        }
        const frame = try std.fmt.allocPrint(a, "{s}\n", .{json});
        defer {
            if (op == .@"prompt.answer") std.crypto.secureZero(u8, frame);
            a.free(frame);
        }
        if (frame.len - 1 > (protocol.Limits{}).frame_bytes) return error.ResourceLimit;
        try self.transport.send(frame);
        self.sequence += 1;
        self.operation = op;
        self.waiting = true;
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = glib.timeoutAdd(5000, expired, self);
    }
    fn verify(self: *Client) !void {
        if (self.phase != .identity or self.native == null or self.session == null) return;
        if (!std.mem.eql(u8, &self.native.?, &self.session.?)) return error.DisplayMismatch;
        self.notify(self.context, .verified);
        if (self.phase == .idle) return; // A secondary instance forwards and exits.
        const path = try protocol.endpoint(a, self.runtime, &self.session.?);
        defer a.free(path);
        try ownedEndpoint(path);
        self.phase = .backend;
        self.sequence = 0;
        self.transport.framer.limit = (protocol.Limits{}).frame_bytes;
        try self.transport.open(path);
    }
    fn receive(self: *Client, bytes: []const u8) !void {
        if (self.phase == .aqueous) {
            var decoded = try codec.decode(a, bytes, .{}, .hello);
            defer decoded.deinit();
            if (decoded.message != .response or !std.mem.eql(u8, decoded.message.response.id, "1")) return error.InvalidHello;
            self.session = decoded.message.response.result.hello.session[0..32].*;
            self.phase = .identity;
            self.transport.close();
            try self.verify();
            return;
        }
        if (self.phase != .backend) return error.UnexpectedReply;
        try @import("../config/preferences.zig").boundedJson(bytes, (protocol.Limits{}).frame_bytes, 12);
        const memory = try a.alloc(u8, 8 * 1024 * 1024);
        defer a.free(memory);
        var fixed = std.heap.FixedBufferAllocator.init(memory);
        const alloc = fixed.allocator();
        const v = try std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{});
        if (try e.read(u32, alloc, try e.field(v, "settings")) != 1) return error.Version;
        if (v == .object and v.object.contains("event")) {
            const epoch = try e.read([]const u8, alloc, try e.field(v, "epoch"));
            if (self.epoch == null or !std.mem.eql(u8, epoch, &self.epoch.?)) return error.StaleSession;
            _ = try @import("editor_protocol.zig").number(try e.read([]const u8, alloc, try e.field(v, "revision")));
            const name = try e.read([]const u8, alloc, try e.field(v, "event"));
            if (std.mem.eql(u8, name, "lock.changed")) {
                const data = try e.field(v, "data");
                self.notify(self.context, .{ .locked = try e.read(bool, alloc, try e.field(data, "locked")) });
            } else {
                self.refresh_appearance = true;
                self.notify(self.context, .changed);
            }
            if (!self.waiting and self.refresh_appearance) {
                self.refresh_appearance = false;
                try self.send();
            }
            return;
        }
        if (!self.waiting) return error.UnexpectedReply;
        const id = try e.read([]const u8, alloc, try e.field(v, "id"));
        try e.decimal(id);
        if (try std.fmt.parseInt(u64, id, 10) != self.sequence) {
            std.log.err("event=settings-stale-response expected={d} received={s} operation={s}", .{ self.sequence, id, @tagName(self.operation) });
            return error.StaleResponse;
        }
        const ok = try e.read(bool, alloc, try e.field(v, "ok"));
        if (self.operation != .hello and self.operation != .ping) {
            if (self.operation == .@"theme.asset" and self.appearance_transfer != null) {
                self.waiting = false;
                if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
                self.deadline = 0;
                if (!ok) {
                    self.clearAppearanceTransfer();
                    return error.ThemeAssetTransferFailed;
                }
                if (try self.appearance_transfer.?.accept(try e.field(v, "result"))) {
                    var provider = try @import("../theme/assets.zig").Provider.init(self.appearance_transfer.?.blobs.items);
                    errdefer provider.deinit();
                    const saved = try std.json.parseFromSliceLeaky(std.json.Value, alloc, self.appearance_json.?, .{});
                    const snapshot = try @import("appearance.zig").Snapshot.read(alloc, saved);
                    self.notify(self.context, .{ .connected = snapshot });
                    self.asset_provider.deinit();
                    self.asset_provider = provider;
                    self.asset_revision = snapshot.revision;
                    self.clearAppearanceTransfer();
                    if (self.heartbeat == 0) self.heartbeat = glib.timeoutAdd((protocol.Limits{}).heartbeat_ms, tick, self);
                } else try self.appearance_transfer.?.request(self);
                return;
            }
            const epoch = try e.read([]const u8, alloc, try e.field(v, "epoch"));
            if (!std.mem.eql(u8, epoch, &self.epoch.?)) return error.StaleSession;
            self.waiting = false;
            if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
            self.deadline = 0;
            const reply: Reply = .{ .op = self.operation, .result = if (ok) try e.field(v, "result") else .null, .error_code = if (!ok) try e.read([]const u8, alloc, try e.field(try e.field(v, "err"), "code")) else null };
            self.notify(self.context, .{ .reply = reply });
            if (!self.waiting and self.refresh_appearance) {
                self.refresh_appearance = false;
                try self.send();
            }
            return;
        }
        if (!ok) return error.BackendRejected;
        const result = try e.field(v, "result");
        const session = try e.read([]const u8, alloc, try e.field(result, "session"));
        const display = try e.read([]const u8, alloc, try e.field(result, "display"));
        if (!std.mem.eql(u8, session, &self.session.?) or !std.mem.eql(u8, display, self.display)) return error.DisplayMismatch;
        const epoch = try e.read([]const u8, alloc, try e.field(result, "epoch"));
        try e.sessionToken(epoch);
        if (self.sequence > 1 and !std.mem.eql(u8, epoch, &self.epoch.?)) return error.StaleSession;
        self.epoch = epoch[0..32].*;
        const caps = try e.read(protocol.Capabilities, alloc, try e.field(result, "capabilities"));
        if (!caps.handshake) return error.Version;
        self.capabilities = caps;
        var appearance: ?@import("appearance.zig").Snapshot = null;
        if (caps.committed_appearance) {
            appearance = try @import("appearance.zig").Snapshot.read(alloc, try e.field(result, "appearance"));
            try @import("../theme/theme.zig").validate(appearance.?.palette);
            // Apply the same text and range validation as backend preferences.
            var p: @import("../config/preferences.zig").Preferences = .{};
            p.font = appearance.?.font;
            p.font_size = appearance.?.font_size;
            p.theme.gtk_name = appearance.?.gtk_name;
            try p.validate();
        }
        self.waiting = false;
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = 0;
        if (appearance) |snapshot| if (snapshot.images.len > 0 and self.asset_revision != snapshot.revision) {
            if (!caps.theme_assets) return error.UnsupportedThemeAssets;
            self.clearAppearanceTransfer();
            self.appearance_json = try std.json.Stringify.valueAlloc(a, snapshot, .{});
            self.appearance_transfer = try @import("asset_transfer.zig").Transfer.init(snapshot.images, snapshot.revision, false);
            try self.appearance_transfer.?.request(self);
            return;
        };
        self.notify(self.context, .{ .connected = appearance }); // Borrowed during callback only.
        if (appearance) |snapshot| if (snapshot.images.len == 0) {
            self.asset_provider.deinit();
            self.asset_revision = snapshot.revision;
        };
        if (self.heartbeat == 0) self.heartbeat = glib.timeoutAdd(if (caps.pearl_draft) (protocol.Limits{}).heartbeat_ms else 1000, tick, self);
    }
    fn tick(context: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(context.?));
        if (!self.waiting) self.send() catch |err| {
            self.heartbeat = 0;
            self.fail(err);
            return 0;
        };
        return 1;
    }
    fn clearAppearanceTransfer(self: *Client) void {
        if (self.appearance_transfer) |*transfer| transfer.deinit();
        self.appearance_transfer = null;
        if (self.appearance_json) |json| a.free(json);
        self.appearance_json = null;
    }
    fn expired(context: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(context.?));
        self.deadline = 0;
        self.fail(error.Timeout);
        return 0;
    }
};
/// Read-only validation: never create a backend directory from the frontend.
pub fn ownedEndpoint(path: [:0]const u8) !void {
    var dir = std.fs.path.dirname(path) orelse return error.UnsafeEndpoint;
    for (0..2) |_| {
        const z = try a.dupeZ(u8, dir);
        defer a.free(z);
        const file = gio.File.newForPath(z);
        defer file.unref();
        const info = file.queryInfo("standard::type,unix::uid,unix::mode", .{ .nofollow_symlinks = true }, null, null) orelse return error.Unavailable;
        defer info.unref();
        if (info.getFileType() != .directory or info.getAttributeUint32("unix::uid") != std.os.linux.getuid() or info.getAttributeUint32("unix::mode") & 0o077 != 0) return error.UnsafeEndpoint;
        dir = std.fs.path.dirname(dir) orelse return error.UnsafeEndpoint;
    }
    const file = gio.File.newForPath(path);
    defer file.unref();
    const info = file.queryInfo("unix::uid,unix::mode", .{ .nofollow_symlinks = true }, null, null) orelse return error.Unavailable;
    defer info.unref();
    if (info.getAttributeUint32("unix::uid") != std.os.linux.getuid() or info.getAttributeUint32("unix::mode") & 0o170000 != 0o140000) return error.UnsafeEndpoint;
}
