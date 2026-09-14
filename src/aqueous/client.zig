//! Aqueous IPC v1 adapter. Own on one GLib main context; keep its address stable.
//! Observer arguments are borrowed for the call. Observers may read state but
//! must not reenter mutating methods; schedule UI actions on a subsequent turn.
const std = @import("std");
const glib = @import("glib2");
const codec = @import("codec.zig");
const commands = @import("commands.zig");
const Transport = @import("transport.zig").Transport;
const icons = @import("icons.zig");
pub const Action = commands.Action;
pub const IconKey = icons.Key;
pub const Model = @import("reducer.zig").Model;
const a = std.heap.c_allocator;
const eql = std.mem.eql;
pub const Availability = enum { stopped, connecting, subscribing, ready, reconnecting };
pub const Completion = struct {
    ticket: u64,
    status: enum { applied, accepted, rejected, dropped, unknown },
    detail: []const u8 = "",
    sequence: []const u8 = "",
};
pub const Event = union(enum) { availability: Availability, state, completion: Completion, icons, fault: []const u8 };
const Pending = struct { op: codec.Operation, id: [20]u8, len: usize, deadline: i64 };
const Channel = struct {
    owner: *Client,
    event: bool,
    wire: Transport,
    pending: ?Pending = null,
    connect_deadline: i64 = 0,
    hello: bool = false,
    session: [32]u8 = undefined,
    limits: codec.Limits = .{},
    caps: codec.Capabilities = undefined,
};
pub const Client = struct {
    model: Model,
    availability: Availability = .stopped,
    capabilities: codec.Capabilities = std.mem.zeroes(codec.Capabilities),
    path: [:0]u8,
    request: Channel = undefined,
    events: Channel = undefined,
    observer: *const fn (*anyopaque, Event) void,
    context: *anyopaque,
    timer: ?*glib.Source = null,
    generation: u64 = 0,
    serial: u64 = 0,
    ticket: u64 = 0,
    retry_at: i64 = 0,
    retries: u8 = 0,
    initial_deadline: i64 = 0,
    subscribed: bool = false,
    delivery: [20]u8 = undefined,
    delivery_len: usize = 0,
    last_delivery: u64 = 0,
    queue: std.ArrayList(commands.Owned) = .empty,
    active: ?commands.Owned = null,
    cache: icons.Cache = .{},
    active_icon: ?icons.Entry = null,
    // Defaults are protocol deadlines. The standalone test probe can shorten them.
    request_ms: u32 = 5000,
    subscription_ms: u32 = 8000,

    pub fn init(path: []const u8, runtime: []const u8, context: *anyopaque, observer: *const fn (*anyopaque, Event) void) !Client {
        try validateEndpoint(path, runtime);
        const owned = try a.dupeZ(u8, path);
        errdefer a.free(owned);
        return .{ .path = owned, .model = try Model.init(a, (codec.Limits{}).state_bytes), .context = context, .observer = observer };
    }
    pub fn start(self: *Client) void {
        std.debug.assert(self.availability == .stopped);
        self.request = .{ .owner = self, .event = false, .wire = undefined };
        self.events = .{ .owner = self, .event = true, .wire = undefined };
        self.request.wire = Transport.init(&self.request, wireEvent);
        self.events.wire = Transport.init(&self.events, wireEvent);
        self.setAvailability(.connecting);
        self.connect();
    }
    pub fn stop(self: *Client) void {
        if (self.availability == .stopped) return;
        self.generation +%= 1;
        self.removeTimer();
        self.disposeWork("Stopped");
        self.request.wire.deinit();
        self.events.wire.deinit();
        self.model.clear();
        self.cache.clear();
        self.capabilities = std.mem.zeroes(codec.Capabilities);
        self.setAvailability(.stopped);
    }
    pub fn deinit(self: *Client) void {
        self.stop();
        self.model.deinit();
        self.queue.deinit(a);
        a.free(self.path);
    }
    /// Terminal action after the shell has relinquished GTK surfaces. Stop the
    /// event stream so its EOF cannot discard the command stream's exit reply.
    /// Callers must stop this client after completion; do not resume desktop work.
    pub fn exitSession(self: *Client) !u64 {
        const ticket = try self.enqueue(.session_exit);
        self.events.wire.close();
        self.events.pending = null;
        self.events.connect_deadline = 0;
        return ticket;
    }
    pub fn enqueue(self: *Client, action: Action) !u64 {
        if (self.availability != .ready) return error.Unavailable;
        try commands.validate(action, &self.model, self.capabilities);
        if (self.queue.items.len >= 32) return error.QueueFull;
        self.ticket = std.math.add(u64, self.ticket, 1) catch return error.IdExhausted;
        var owned = try commands.Owned.init(a, action, self.ticket);
        errdefer owned.deinit();
        try self.queue.append(a, owned);
        // One main-context turn batches actions and lets them outrank icon work.
        self.scheduleDispatch();
        return self.ticket;
    }
    pub fn icon(self: *Client, key: IconKey) !?*@import("gdkpixbuf2").Pixbuf {
        if (self.availability != .ready) return error.Unavailable;
        if (!self.capabilities.icon_metadata or !self.capabilities.icon_fetch) return error.Unsupported;
        if (self.model.get(.session, "session").?.locked) return error.Locked;
        if (!key.valid(&self.model)) return error.StaleIcon;
        const result = try self.cache.request(key);
        self.scheduleDispatch();
        return result;
    }
    fn setAvailability(self: *Client, value: Availability) void {
        self.availability = value;
        self.observer(self.context, .{ .availability = value });
    }
    fn connect(self: *Client) void {
        self.retry_at = 0;
        self.initial_deadline = 0;
        self.subscribed = false;
        self.last_delivery = 0;
        self.delivery_len = 0;
        self.model.clear();
        for ([_]*Channel{ &self.request, &self.events }) |c| {
            c.hello = false;
            c.pending = null;
            c.limits = .{};
            c.wire.framer.limit = c.limits.frame_bytes;
            c.connect_deadline = now() + @as(i64, self.request_ms) * 1000;
            c.wire.open(self.path) catch |err| {
                self.fail(err);
                return;
            };
        }
        self.retime();
    }
    fn disposeWork(self: *Client, reason: []const u8) void {
        if (self.active) |*v| {
            self.observer(self.context, .{ .completion = .{ .ticket = v.ticket, .status = if (self.request.wire.sent > 0) .unknown else .dropped, .detail = reason } });
            v.deinit();
            self.active = null;
        }
        for (self.queue.items) |*v| {
            self.observer(self.context, .{ .completion = .{ .ticket = v.ticket, .status = .dropped, .detail = reason } });
            v.deinit();
        }
        self.queue.clearRetainingCapacity();
        if (self.active_icon) |*v| {
            v.deinit();
            self.active_icon = null;
        }
    }
    fn fail(self: *Client, err: anyerror) void {
        if (self.availability == .stopped or self.retry_at != 0) return;
        self.generation +%= 1;
        self.model.invalidate();
        self.capabilities = std.mem.zeroes(codec.Capabilities);
        self.setAvailability(.reconnecting);
        self.observer(self.context, .{ .fault = @errorName(err) });
        self.disposeWork(@errorName(err));
        for ([_]*Channel{ &self.request, &self.events }) |c| {
            c.wire.close();
            c.pending = null;
            c.connect_deadline = 0;
        }
        self.cache.clear();
        self.initial_deadline = 0;
        const base: u32 = @min(@as(u32, 250) << @intCast(@min(self.retries, 5)), 8000);
        self.retries = @min(self.retries +| 1, 5);
        self.retry_at = now() + (@as(i64, base) + glib.randomIntRange(0, @intCast(base / 4 + 1))) * 1000;
        self.retime();
    }
    fn send(self: *Client, channel: *Channel, op: codec.Operation, params: []const u8) !void {
        if (channel.pending != null) return error.OutstandingRequest;
        self.serial = std.math.add(u64, self.serial, 1) catch return error.IdExhausted;
        var p: Pending = .{ .op = op, .id = undefined, .len = 0, .deadline = now() + @as(i64, self.request_ms) * 1000 };
        const id = try std.fmt.bufPrint(&p.id, "{d}", .{self.serial});
        p.len = id.len;
        const op_name = if (op == .window_icon) "window.icon" else @tagName(op);
        const frame = if (op == .hello)
            try std.fmt.allocPrint(a, "{{\"ipc\":1,\"id\":\"{s}\",\"op\":\"hello\",\"params\":{s}}}\n", .{ id, params })
        else
            try std.fmt.allocPrint(a, "{{\"ipc\":1,\"id\":\"{s}\",\"session\":\"{s}\",\"op\":\"{s}\",\"params\":{s}}}\n", .{ id, channel.session, op_name, params });
        defer a.free(frame);
        if (frame.len - 1 > channel.limits.request_bytes) return error.RequestTooLarge;
        try channel.wire.send(frame);
        channel.pending = p;
        self.retime();
    }
    fn wireEvent(context: *anyopaque, event: @import("transport.zig").Event) void {
        const c: *Channel = @ptrCast(@alignCast(context));
        const self = c.owner;
        switch (event) {
            .sent => {},
            .failed => |err| self.fail(err),
            .connected => {
                c.connect_deadline = 0;
                self.send(c, .hello, "{}") catch |err| self.fail(err);
            },
            .frame => |bytes| self.receive(c, bytes) catch |err| self.fail(err),
        }
    }
    fn receive(self: *Client, c: *Channel, bytes: []const u8) !void {
        var decoded = try codec.decode(a, bytes, c.limits, if (c.pending) |p| p.op else null);
        defer decoded.deinit();
        switch (decoded.message) {
            .event => |event| {
                if (!c.event or !self.subscribed or c.pending != null) return error.UnexpectedEvent;
                if (!eql(u8, event.batch.session, &self.request.session)) return error.SessionChanged;
                if (!self.model.ready and event.batch.type != .snapshot) return error.SnapshotRequired;
                if (self.model.ready and event.batch.type != .delta) return error.UnexpectedSnapshot;
                const delivery = try std.fmt.parseInt(u64, event.delivery, 10);
                if (delivery <= self.last_delivery) return error.InvalidDelivery;
                try self.model.apply(event.batch);
                self.last_delivery = delivery;
                self.delivery_len = event.delivery.len;
                @memcpy(self.delivery[0..self.delivery_len], event.delivery);
                self.cache.prune(&self.model);
                const params = try std.json.Stringify.valueAlloc(a, .{ .delivery = event.delivery }, .{});
                defer a.free(params);
                try self.send(c, .ack, params);
                self.observer(self.context, .state);
            },
            .failure => |failure| {
                const p = c.pending orelse return error.UnexpectedResponse;
                if (!eql(u8, p.id[0..p.len], failure.id) or c.wire.output != null) return error.ResponseId;
                if (p.op != .command and p.op != .window_icon) return error.HandshakeRejected;
                c.pending = null;
                if (p.op == .command) {
                    var active = self.active.?;
                    self.active = null;
                    defer active.deinit();
                    self.observer(self.context, .{ .completion = .{ .ticket = active.ticket, .status = .rejected, .detail = failure.code } });
                } else self.finishIcon(null);
                if (eql(u8, failure.code, "stale_session")) return error.SessionChanged;
                try self.dispatch();
            },
            .response => |response| {
                const p = c.pending orelse return error.UnexpectedResponse;
                if (!eql(u8, p.id[0..p.len], response.id) or c.wire.output != null) return error.ResponseId;
                c.pending = null;
                switch (response.result) {
                    .hello => |hello| {
                        c.hello = true;
                        @memcpy(&c.session, hello.session);
                        c.limits = hello.effectiveLimits();
                        try c.limits.validate();
                        c.wire.framer.limit = c.limits.frame_bytes;
                        c.caps = hello.capabilities;
                        if (self.request.hello and self.events.hello) {
                            if (!eql(u8, &self.request.session, &self.events.session)) return error.SessionChanged;
                            self.capabilities = self.request.caps;
                            inline for (@typeInfo(codec.Capabilities).@"struct".fields) |f| @field(self.capabilities, f.name) = @field(self.capabilities, f.name) and @field(self.events.caps, f.name);
                            if (!self.capabilities.state) return error.Unsupported;
                            self.model.limit = @min(self.request.limits.state_bytes, self.events.limits.state_bytes);
                            self.initial_deadline = now() + @as(i64, self.subscription_ms) * 1000;
                            self.setAvailability(.subscribing);
                            try self.send(&self.events, .subscribe, "{}");
                        }
                    },
                    .subscribe => {
                        if (!c.event) return error.UnexpectedResponse;
                        self.subscribed = true;
                    },
                    .ack => |delivery| {
                        if (!c.event or !eql(u8, delivery, self.delivery[0..self.delivery_len])) return error.InvalidAck;
                        self.initial_deadline = 0;
                        if (self.availability != .ready) {
                            self.retries = 0;
                            self.setAvailability(.ready);
                        }
                        try self.dispatch();
                    },
                    .command => |result| {
                        if (c.event or self.active == null) return error.UnexpectedResponse;
                        if (result.status == .accepted and !self.active.?.action.acceptsDeferred()) return error.InvalidCompletion;
                        var active = self.active.?;
                        self.active = null;
                        defer active.deinit();
                        self.observer(self.context, .{ .completion = .{ .ticket = active.ticket, .status = if (result.status == .accepted) .accepted else .applied, .sequence = result.sequence } });
                        try self.dispatch();
                    },
                    .window_icon => |result| {
                        self.finishIcon(result);
                        try self.dispatch();
                    },
                    .snapshot => return error.UnexpectedResponse,
                }
            },
        }
        self.retime();
    }
    fn finishIcon(self: *Client, result: ?codec.IconResult) void {
        var active = self.active_icon orelse return;
        self.active_icon = null;
        defer active.deinit();
        if (self.cache.find(active.key)) |entry| {
            entry.pending = false;
            if (active.key.valid(&self.model) and !self.model.get(.session, "session").?.locked) {
                if (result) |value| entry.pixels = icons.decode(active.key, value) catch null;
                self.observer(self.context, .icons);
            }
        }
    }
    fn dispatch(self: *Client) !void {
        if (self.availability != .ready or self.request.pending != null) return;
        while (self.queue.items.len > 0) {
            var owned = self.queue.orderedRemove(0);
            commands.validate(owned.action, &self.model, self.capabilities) catch |err| {
                self.observer(self.context, .{ .completion = .{ .ticket = owned.ticket, .status = .rejected, .detail = @errorName(err) } });
                owned.deinit();
                continue;
            };
            self.active = owned;
            self.request.wire.sent = 0;
            const params = try owned.action.params(a);
            defer a.free(params);
            self.send(&self.request, .command, params) catch |err| {
                if (err != error.RequestTooLarge) return err;
                self.active = null;
                self.observer(self.context, .{ .completion = .{ .ticket = owned.ticket, .status = .rejected, .detail = @errorName(err) } });
                owned.deinit();
                continue;
            };
            return;
        }
        if (self.model.get(.session, "session").?.locked) return;
        for (self.cache.entries.items) |*entry| if (entry.pending) {
            if (!entry.key.valid(&self.model)) continue;
            self.active_icon = try icons.Entry.init(entry.key);
            const params = try std.json.Stringify.valueAlloc(a, entry.key, .{});
            defer a.free(params);
            self.send(&self.request, .window_icon, params) catch |err| {
                if (err != error.RequestTooLarge) return err;
                self.finishIcon(null);
                continue;
            };
            return;
        };
    }
    fn scheduleDispatch(self: *Client) void {
        self.retime();
    }
    fn removeTimer(self: *Client) void {
        if (self.timer) |v| {
            v.destroy();
            v.unref();
        }
        self.timer = null;
    }
    fn retime(self: *Client) void {
        self.removeTimer();
        if (self.availability == .stopped) return;
        var due: i64 = std.math.maxInt(i64);
        if (self.retry_at != 0) due = self.retry_at else {
            for ([_]*Channel{ &self.request, &self.events }) |c| {
                if (c.connect_deadline != 0) due = @min(due, c.connect_deadline);
                if (c.pending) |p| due = @min(due, p.deadline);
            }
            if (self.initial_deadline != 0) due = @min(due, self.initial_deadline);
            if (self.availability == .ready and self.request.pending == null) {
                var work = self.queue.items.len > 0;
                if (!self.model.get(.session, "session").?.locked) for (self.cache.entries.items) |v| {
                    if (v.pending) {
                        work = true;
                        break;
                    }
                };
                if (work) due = now();
            }
        }
        if (due == std.math.maxInt(i64)) return;
        const token = a.create(TimerToken) catch @panic("Unable to allocate GLib deadline token");
        token.* = .{ .owner = self, .generation = self.generation };
        const source = glib.timeoutSourceNew(0);
        self.timer = source;
        source.setCallback(timerReady, token, freeTimer);
        source.setReadyTime(due);
        _ = source.attach(null);
    }
    const TimerToken = struct { owner: *Client, generation: u64 };
    fn freeTimer(data: ?*anyopaque) callconv(.c) void {
        a.destroy(@as(*TimerToken, @ptrCast(@alignCast(data.?))));
    }
    fn timerReady(data: ?*anyopaque) callconv(.c) c_int {
        const token = @as(*TimerToken, @ptrCast(@alignCast(data.?))).*;
        const self = token.owner;
        if (self.generation != token.generation) return 0;
        self.removeTimer();
        const time = now();
        if (self.retry_at != 0) {
            if (time >= self.retry_at) self.connect();
            return 0;
        }
        if (self.initial_deadline != 0 and time >= self.initial_deadline) {
            self.fail(error.SubscriptionTimeout);
            return 0;
        }
        for ([_]*Channel{ &self.request, &self.events }) |c| {
            if ((c.connect_deadline != 0 and time >= c.connect_deadline) or (c.pending != null and time >= c.pending.?.deadline)) {
                self.fail(error.RequestTimeout);
                return 0;
            }
        }
        self.dispatch() catch |err| {
            self.fail(err);
            return 0;
        };
        self.retime();
        return 0;
    }
};
fn now() i64 {
    return glib.getMonotonicTime();
}
pub fn validateEndpoint(path: []const u8, runtime: []const u8) !void {
    if (path.len >= 108 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidEndpoint;
    @import("../core/startup.zig").validate(.session, .{ .desktop = "Aqueous", .display = "verified-by-caller", .runtime = runtime, .endpoint = path }) catch return error.InvalidEndpoint;
}

test "adapter endpoint validation rejects traversal, overlap and long Unix paths" {
    const t = std.testing;
    try validateEndpoint("/tmp/runtime/aqueous/instance/ipc.sock", "/tmp/runtime");
    for ([_][]const u8{ "relative", "/tmp/runtime/aqueous/ipc.sock", "/tmp/runtime/aqueous//ipc.sock", "/tmp/runtime/aqueous/../ipc.sock", "/tmp/runtime/aqueous/a/b/ipc.sock", "/tmp/runtime-other/aqueous/a/ipc.sock", "/tmp/runtime/aqueous/a/ipc.sock\x00" }) |path| try t.expectError(error.InvalidEndpoint, validateEndpoint(path, "/tmp/runtime"));
    try t.expectError(error.InvalidEndpoint, validateEndpoint("/tmp//runtime/aqueous/a/ipc.sock", "/tmp//runtime"));
    try t.expectError(error.InvalidEndpoint, validateEndpoint("/tmp/runtime/aqueous/" ++ "a" ** 90 ++ "/ipc.sock", "/tmp/runtime"));
}
