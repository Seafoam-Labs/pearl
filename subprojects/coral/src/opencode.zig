//! OpenCode 2.4 local service. Callbacks borrow the parsed response for one invocation.
const std = @import("std");
const u = @import("c.zig");
const c = u.c;
pub const Value = std.json.Value;
pub const Callback = *const fn (*anyopaque, u64, Value, ?[]const u8) void;

pub fn get(value: Value, key: []const u8) Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
pub fn string(value: Value, key: []const u8) []const u8 {
    const field = get(value, key);
    return if (field == .string) field.string else "";
}
pub fn items(value: Value) []const Value {
    return if (value == .array) value.array.items else &.{};
}
pub fn json(value: anytype) []u8 {
    return std.json.Stringify.valueAlloc(u.a, value, .{}) catch unreachable;
}
pub fn escaped(value: [:0]const u8) [:0]u8 {
    const encoded = c.g_uri_escape_string(value, null, 0);
    defer c.g_free(encoded);
    return u.z(std.mem.span(encoded));
}

const Listener = struct { cancel: *c.GCancellable, context: *anyopaque, notify: Callback };

// All service and GTK callbacks run on the UI main context. Windows own their
// requests independently and share one HTTP connection pool and event stream.
var services: std.ArrayList(*Service) = .empty;
const Service = struct {
    http: *c.SoupSession,
    url: [:0]u8,
    identity: [:0]u8,
    authorization: [:0]u8,
    refs: usize = 1,
    stream_cancel: ?*c.GCancellable = null,
    listeners: std.ArrayList(Listener) = .empty,

    fn acquire(url: []const u8, identity: []const u8, authorization: []const u8) *Service {
        for (services.items) |service| {
            if (std.mem.eql(u8, service.url, url) and std.mem.eql(u8, service.identity, identity) and std.mem.eql(u8, service.authorization, authorization)) {
                service.refs += 1;
                return service;
            }
        }
        const service = u.a.create(Service) catch unreachable;
        const http = c.soup_session_new().?;
        c.soup_session_set_timeout(http, 15);
        service.* = .{ .http = http, .url = u.z(url), .identity = u.z(identity), .authorization = u.z(authorization) };
        services.append(u.a, service) catch unreachable;
        return service;
    }
    fn release(self: *Service) void {
        self.refs -= 1;
        if (self.refs > 0) return;
        for (services.items, 0..) |service, i| if (service == self) {
            _ = services.swapRemove(i);
            break;
        };
        if (services.items.len == 0) {
            services.deinit(u.a);
            services = .empty;
        }
        if (self.stream_cancel) |cancel| {
            c.g_cancellable_cancel(cancel);
            c.g_object_unref(cancel);
        }
        self.listeners.deinit(u.a);
        c.soup_session_abort(self.http);
        c.g_object_unref(self.http);
        u.a.free(self.url);
        u.a.free(self.identity);
        u.a.free(self.authorization);
        u.a.destroy(self);
    }
    fn detach(self: *Service, cancel: *c.GCancellable) void {
        for (self.listeners.items, 0..) |listener, i| if (listener.cancel == cancel) {
            _ = self.listeners.swapRemove(i);
            break;
        };
        self.release();
    }
    fn watch(self: *Service, listener: Listener) void {
        var found = false;
        for (self.listeners.items) |*old| if (old.cancel == listener.cancel) {
            old.* = listener;
            found = true;
            break;
        };
        if (!found) self.listeners.append(u.a, listener) catch unreachable;
        if (self.stream_cancel != null) return;
        const url = u.fmt("{s}/api/event", .{self.url});
        defer u.a.free(url);
        const msg = c.soup_message_new("GET", url) orelse return;
        c.soup_message_add_flags(msg, c.SOUP_MESSAGE_NO_REDIRECT);
        c.soup_message_headers_replace(c.soup_message_get_request_headers(msg), "Authorization", self.authorization);
        c.soup_message_headers_replace(c.soup_message_get_request_headers(msg), "Accept", "text/event-stream");
        const stream = u.a.create(Subscription) catch unreachable;
        const cancel = c.g_cancellable_new().?;
        _ = c.g_object_ref(cancel);
        self.stream_cancel = cancel;
        stream.* = .{ .cancel = cancel, .message = msg, .ctx = self, .done = &broadcast };
        c.soup_session_send_async(self.http, msg, 0, cancel, &streamOpened, stream);
    }
};
fn broadcast(ctx: *anyopaque, epoch: u64, value: Value, err: ?[]const u8) void {
    const service = u.cast(Service, ctx);
    service.refs += 1;
    defer service.release();
    if (err != null) {
        if (service.stream_cancel) |cancel| c.g_object_unref(cancel);
        service.stream_cancel = null;
    }
    if (service.listeners.items.len == 1) {
        const listener = service.listeners.items[0];
        if (c.g_cancellable_is_cancelled(listener.cancel) == 0) listener.notify(listener.context, epoch, value, err);
        return;
    }
    const listeners = u.a.dupe(Listener, service.listeners.items) catch unreachable;
    defer u.a.free(listeners);
    for (listeners) |listener| _ = c.g_object_ref(listener.cancel);
    defer for (listeners) |listener| c.g_object_unref(listener.cancel);
    for (listeners) |listener| {
        if (c.g_cancellable_is_cancelled(listener.cancel) == 0) listener.notify(listener.context, epoch, value, err);
    }
}
pub const Client = struct {
    service: ?*Service = null,
    cancel: *c.GCancellable,
    pub fn init() Client {
        return .{ .cancel = c.g_cancellable_new().? };
    }
    pub fn identity(self: *Client) []const u8 {
        return if (self.service) |service| service.identity else "";
    }
    pub fn discover(self: *Client) !void {
        const path = u.fmt("{s}/opencode/service.json", .{std.mem.span(c.g_get_user_state_dir())});
        defer u.a.free(path);
        var data: [*c]u8 = null;
        var size: usize = 0;
        if (c.g_file_get_contents(path, &data, &size, null) == 0) return error.ServiceOffline;
        defer c.g_free(data);
        const parsed = try std.json.parseFromSlice(Value, u.a, data[0..size], .{});
        defer parsed.deinit();
        const endpoint = string(parsed.value, "url");
        const password = string(parsed.value, "password");
        if (password.len == 0) return error.MissingCredentials;
        const url = u.z(std.mem.trimEnd(u8, endpoint, "/"));
        defer u.a.free(url);
        const uri = c.g_uri_parse(url, c.G_URI_FLAGS_NONE, null) orelse return error.InvalidEndpoint;
        defer c.g_uri_unref(uri);
        const host = c.g_uri_get_host(uri);
        if (host == null or c.g_uri_get_userinfo(uri) != null) return error.InvalidEndpoint;
        const local = std.mem.eql(u8, std.mem.span(host), "localhost") or std.mem.eql(u8, std.mem.span(host), "127.0.0.1") or std.mem.eql(u8, std.mem.span(host), "::1");
        if (!local or !std.mem.eql(u8, std.mem.span(c.g_uri_get_scheme(uri)), "http")) return error.InvalidEndpoint;
        const credentials = u.fmt("opencode:{s}", .{password});
        defer u.a.free(credentials);
        const encoded = c.g_base64_encode(credentials.ptr, credentials.len);
        defer c.g_free(encoded);
        const auth = u.fmt("Basic {s}", .{std.mem.span(encoded)});
        defer u.a.free(auth);
        const id = string(parsed.value, "id");
        const next = Service.acquire(url, if (id.len > 0) id else url, auth);
        if (self.service) |old| {
            if (old == next) {
                next.release();
                return;
            }
            c.g_cancellable_cancel(self.cancel);
            old.detach(self.cancel);
            c.g_object_unref(self.cancel);
            self.cancel = c.g_cancellable_new().?;
        }
        self.service = next;
    }
    pub fn request(self: *Client, path: []const u8, body: ?[]const u8, ctx: *anyopaque, epoch: u64, done: Callback) void {
        self.requestMethod(if (body == null) "GET" else "POST", path, body, ctx, epoch, done);
    }
    pub fn requestMethod(self: *Client, method: [:0]const u8, path: []const u8, body: ?[]const u8, ctx: *anyopaque, epoch: u64, done: Callback) void {
        const service = self.service orelse return done(ctx, epoch, .null, "OpenCode is offline");
        const url = u.fmt("{s}{s}", .{ service.url, path });
        defer u.a.free(url);
        const msg = c.soup_message_new(method, url) orelse return done(ctx, epoch, .null, "Invalid OpenCode URL");
        c.soup_message_add_flags(msg, c.SOUP_MESSAGE_NO_REDIRECT);
        c.soup_message_headers_replace(c.soup_message_get_request_headers(msg), "Authorization", service.authorization);
        if (body) |content| {
            const bytes = c.g_bytes_new(content.ptr, content.len).?;
            c.soup_message_set_request_body_from_bytes(msg, "application/json", bytes);
            c.g_bytes_unref(bytes);
        }
        const op = u.a.create(Request) catch unreachable;
        _ = c.g_object_ref(self.cancel);
        op.* = .{ .cancel = self.cancel, .msg = msg, .ctx = ctx, .epoch = epoch, .done = done };
        c.soup_session_send_and_read_async(service.http, msg, 0, self.cancel, &completed, op);
    }
    pub fn subscribe(self: *Client, ctx: *anyopaque, done: Callback) void {
        if (self.service) |service| service.watch(.{ .cancel = self.cancel, .context = ctx, .notify = done });
    }
    pub fn deinit(self: *Client) void {
        c.g_cancellable_cancel(self.cancel);
        if (self.service) |service| service.detach(self.cancel);
        c.g_object_unref(self.cancel);
    }
};
const Request = struct { cancel: *c.GCancellable, msg: *c.SoupMessage, ctx: *anyopaque, epoch: u64, done: Callback };
fn completed(source: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const op = u.cast(Request, data.?);
    defer u.a.destroy(op);
    defer c.g_object_unref(op.msg);
    defer c.g_object_unref(op.cancel);
    if (c.g_cancellable_is_cancelled(op.cancel) != 0) return;
    var err: ?*c.GError = null;
    const bytes = c.soup_session_send_and_read_finish(u.cast(c.SoupSession, source.?), result, &err);
    if (err) |e| {
        defer c.g_error_free(e);
        if (c.g_error_matches(e, c.g_io_error_quark(), c.G_IO_ERROR_CANCELLED) == 0) op.done(op.ctx, op.epoch, .null, std.mem.span(e.message));
        return;
    }
    const response = bytes orelse return op.done(op.ctx, op.epoch, .null, "Empty service response");
    defer c.g_bytes_unref(response);
    const status = c.soup_message_get_status(op.msg);
    var size: usize = 0;
    const payload = c.g_bytes_get_data(response, &size);
    if (status < 200 or status >= 300) {
        if (size > 0 and size <= 65536) {
            if (std.json.parseFromSlice(Value, u.a, @as([*]const u8, @ptrCast(payload))[0..size], .{})) |parsed| {
                defer parsed.deinit();
                const message = string(parsed.value, "message");
                if (message.len != 0) return op.done(op.ctx, op.epoch, .null, message);
            } else |_| {}
        }
        const reason = u.fmt("OpenCode returned HTTP {d}", .{status});
        defer u.a.free(reason);
        return op.done(op.ctx, op.epoch, .null, reason);
    }
    if (size == 0) return op.done(op.ctx, op.epoch, .null, null);
    const parsed = std.json.parseFromSlice(Value, u.a, @as([*]const u8, @ptrCast(payload))[0..size], .{ .allocate = .alloc_always }) catch return op.done(op.ctx, op.epoch, .null, "Invalid JSON from OpenCode");
    defer parsed.deinit();
    op.done(op.ctx, op.epoch, parsed.value, null);
}

const Subscription = struct {
    message: *c.SoupMessage,
    cancel: *c.GCancellable,
    input: ?*c.GInputStream = null,
    ctx: *anyopaque,
    done: Callback,
    partial: std.ArrayList(u8) = .empty,
    event: std.ArrayList(u8) = .empty,

    fn close(self: *Subscription) void {
        if (c.g_cancellable_is_cancelled(self.cancel) == 0) self.done(self.ctx, 0, .null, "OpenCode event stream disconnected");
        if (self.input) |input| c.g_object_unref(input);
        c.g_object_unref(self.cancel);
        c.g_object_unref(self.message);
        self.partial.deinit(u.a);
        self.event.deinit(u.a);
        u.a.destroy(self);
    }
    fn next(self: *Subscription) void {
        c.g_input_stream_read_bytes_async(self.input, 16384, 0, self.cancel, &streamRead, self);
    }
    fn consume(self: *Subscription, bytes: []const u8) !void {
        try self.partial.appendSlice(u.a, bytes);
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.partial.items, start, '\n')) |end| {
            const line = std.mem.trimEnd(u8, self.partial.items[start..end], "\r");
            start = end + 1;
            if (std.mem.startsWith(u8, line, "data:")) {
                if (self.event.items.len > 0) try self.event.append(u.a, '\n');
                try self.event.appendSlice(u.a, std.mem.trimStart(u8, line[5..], " "));
                if (self.event.items.len > 1024 * 1024) return error.EventTooLarge;
            } else if (line.len == 0 and self.event.items.len > 0) {
                const parsed = try std.json.parseFromSlice(Value, u.a, self.event.items, .{});
                defer parsed.deinit();
                self.done(self.ctx, 0, parsed.value, null);
                self.event.clearRetainingCapacity();
                if (c.g_cancellable_is_cancelled(self.cancel) != 0) return error.Cancelled;
            }
        }
        const remaining = self.partial.items.len - start;
        std.mem.copyForwards(u8, self.partial.items[0..remaining], self.partial.items[start..]);
        self.partial.shrinkRetainingCapacity(remaining);
        if (remaining > 1024 * 1024) return error.LineTooLarge;
    }
};
fn streamOpened(source: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const stream = u.cast(Subscription, data.?);
    stream.input = c.soup_session_send_finish(u.cast(c.SoupSession, source.?), result, null);
    if (stream.input == null or c.g_cancellable_is_cancelled(stream.cancel) != 0 or c.soup_message_get_status(stream.message) != 200) return stream.close();
    stream.next();
}
fn streamRead(source: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const stream = u.cast(Subscription, data.?);
    const bytes = c.g_input_stream_read_bytes_finish(u.cast(c.GInputStream, source.?), result, null) orelse return stream.close();
    defer c.g_bytes_unref(bytes);
    var size: usize = 0;
    const ptr = c.g_bytes_get_data(bytes, &size);
    if (size == 0 or c.g_cancellable_is_cancelled(stream.cancel) != 0) return stream.close();
    stream.consume(@as([*]const u8, @ptrCast(ptr))[0..size]) catch return stream.close();
    stream.next();
}

test "two windows share a service and closing one leaves the other subscribed" {
    const Count = struct {
        calls: usize = 0,
        fn receive(ctx: *anyopaque, _: u64, _: Value, _: ?[]const u8) void {
            u.cast(@This(), ctx).calls += 1;
        }
    };
    var first = Client.init();
    var second = Client.init();
    defer second.deinit();
    const service = Service.acquire("http://127.0.0.1:1", "fixture", "fixture authorization");
    first.service = service;
    second.service = Service.acquire(service.url, service.identity, service.authorization);
    try std.testing.expectEqual(service, second.service.?);
    var left: Count = .{};
    var right: Count = .{};
    try service.listeners.append(u.a, .{ .cancel = first.cancel, .context = &left, .notify = &Count.receive });
    try service.listeners.append(u.a, .{ .cancel = second.cancel, .context = &right, .notify = &Count.receive });
    broadcast(service, 0, .null, null);
    first.deinit();
    broadcast(service, 0, .null, null);
    try std.testing.expectEqual(@as(usize, 1), left.calls);
    try std.testing.expectEqual(@as(usize, 2), right.calls);
}
