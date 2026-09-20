const std = @import("std");
const u = @import("../ui/widgets.zig");
const c = u.c;
const m = @import("../core/model.zig");
pub const Service = struct { name: m.Text(256) = .{}, description: m.Text(256) = .{}, state: m.Name = .{}, substate: m.Name = .{}, load: m.Name = .{}, path: m.Path = .{} };
pub const Controller = struct {
    connection: ?*c.GDBusConnection = null,
    cancel: ?*c.GCancellable = null,
    items: std.ArrayList(Service) = .empty,
    context: ?*anyopaque = null,
    changed: *const fn (?*anyopaque) void,
    system: bool = false,
    generation: u64 = 0,
    pending: usize = 0,
    loading: bool = false,
    available: bool = false,
    closed: bool = false,
    signal_id: c_uint = 0,
    owner_id: c_uint = 0,
    message: m.Text(512) = .{},
    last_refresh: i64 = 0,
    dirty: bool = true,
    requested: m.Text(256) = .{},
    expected: m.Name = .{},
    request_time: i64 = 0,
    job: m.Path = .{},
    completed_job: m.Path = .{},
    job_result: m.Name = .{},
    failure: m.Text(512) = .{},
    failure_until: i64 = 0,
    fn failAction(self: *Controller, text: []const u8) void {
        self.failure.set(text);
        self.failure_until = c.g_get_monotonic_time() + 8000000;
        self.message = self.failure;
        self.requested = .{};
    }
    fn jobComplete(self: *Controller) bool {
        return self.job.len > 0 and std.mem.eql(u8, self.job.slice(), self.completed_job.slice());
    }

    const Request = struct { owner: *Controller, generation: u64, action: bool = false };
    fn request(self: *Controller, is_action: bool) *Request {
        const r = u.a.create(Request) catch unreachable;
        r.* = .{ .owner = self, .generation = self.generation, .action = is_action };
        self.pending += 1;
        return r;
    }
    fn finish(r: *Request) void {
        r.owner.pending -= 1;
        u.a.destroy(r);
    }
    pub fn init(self: *Controller) void {
        self.cancel = c.g_cancellable_new().?;
        self.open(false);
    }
    pub fn open(self: *Controller, system: bool) void {
        self.generation += 1;
        self.system = system;
        self.available = false;
        self.items.clearRetainingCapacity();
        self.requested = .{};
        self.expected = .{};
        self.job = .{};
        self.completed_job = .{};
        self.failure_until = 0;
        self.detach();
        self.loading = true;
        self.message.set("Connecting to the service manager…");
        c.g_bus_get(if (system) c.G_BUS_TYPE_SYSTEM else c.G_BUS_TYPE_SESSION, self.cancel, connected, self.request(false));
    }
    fn detach(self: *Controller) void {
        if (self.connection) |connection| {
            if (self.signal_id != 0) c.g_dbus_connection_signal_unsubscribe(connection, self.signal_id);
            if (self.owner_id != 0) c.g_dbus_connection_signal_unsubscribe(connection, self.owner_id);
            c.g_object_unref(connection);
        }
        self.connection = null;
        self.signal_id = 0;
        self.owner_id = 0;
    }
    pub fn deinit(self: *Controller) void {
        self.closed = true;
        c.g_cancellable_cancel(self.cancel);
        self.detach();
        while (self.pending > 0) {
            _ = c.g_main_context_iteration(null, 1);
        }
        c.g_object_unref(self.cancel);
        self.items.deinit(u.a);
    }
    fn connected(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const r = u.cast(Request, data);
        defer finish(r);
        const self = r.owner;
        var err: ?*c.GError = null;
        const connection = c.g_bus_get_finish(result, &err);
        defer if (err) |e| c.g_error_free(e);
        if (self.closed or r.generation != self.generation) {
            if (connection) |v| c.g_object_unref(v);
            return;
        }
        self.loading = false;
        if (connection == null) {
            self.message.set(if (err) |e| std.mem.span(e.message) else "Service manager unavailable");
            self.changed(self.context);
            return;
        }
        self.connection = connection;
        self.signal_id = c.g_dbus_connection_signal_subscribe(connection, "org.freedesktop.systemd1", null, null, null, null, 0, signal, self, null);
        self.owner_id = c.g_dbus_connection_signal_subscribe(connection, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", "org.freedesktop.systemd1", 0, signal, self, null);
        self.subscribe();
        self.refresh();
    }
    fn subscribe(self: *Controller) void {
        const connection = self.connection orelse return;
        c.g_dbus_connection_call(connection, "org.freedesktop.systemd1", "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager", "Subscribe", null, null, c.G_DBUS_CALL_FLAGS_NO_AUTO_START, 2000, self.cancel, subscribed, self.request(false));
    }
    fn subscribed(source: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const r = u.cast(Request, data);
        defer finish(r);
        var err: ?*c.GError = null;
        const reply = c.g_dbus_connection_call_finish(u.cast(c.GDBusConnection, source), result, &err);
        if (reply) |v| c.g_variant_unref(v);
        if (err) |e| c.g_error_free(e);
        // Polling remains available when a manager cannot subscribe.
    }
    fn signal(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, name: [*c]const u8, parameters: ?*c.GVariant, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data);
        if (self.closed) return;
        if (std.mem.eql(u8, std.mem.span(name), "NameOwnerChanged")) {
            self.generation += 1;
            self.loading = false;
            self.available = false;
            self.requested = .{};
            self.items.clearRetainingCapacity();
            self.subscribe();
            self.changed(self.context);
        }
        if (std.mem.eql(u8, std.mem.span(name), "JobRemoved") and parameters != null and self.requested.len > 0 and c.g_variant_is_of_type(parameters, @ptrCast("(uoss)")) != 0) {
            const params = parameters.?;
            const unit = childText(params, 2);
            const job = childText(params, 1);
            if (std.mem.eql(u8, unit, self.requested.slice()) and (self.job.len == 0 or std.mem.eql(u8, job, self.job.slice()))) {
                self.completed_job.set(job);
                self.job_result.set(childText(params, 3));
            }
        }
        self.dirty = true;
    }
    pub fn tick(self: *Controller) void {
        if (self.closed or self.loading or self.connection == null) return;
        const now = c.g_get_monotonic_time();
        if ((self.dirty and now - self.last_refresh > 250000) or now - self.last_refresh > 5000000) self.refresh();
    }
    pub fn refresh(self: *Controller) void {
        const connection = self.connection orelse return;
        if (self.loading or self.closed) return;
        self.loading = true;
        self.dirty = false;
        self.last_refresh = c.g_get_monotonic_time();
        c.g_dbus_connection_call(connection, "org.freedesktop.systemd1", "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager", "ListUnits", null, null, c.G_DBUS_CALL_FLAGS_NO_AUTO_START, 2000, self.cancel, listed, self.request(false));
    }
    fn childText(tuple: *c.GVariant, index: usize) []const u8 {
        const v = c.g_variant_get_child_value(tuple, index).?;
        defer c.g_variant_unref(v);
        return std.mem.span(c.g_variant_get_string(v, null));
    }
    fn listed(source: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const r = u.cast(Request, data);
        defer finish(r);
        const self = r.owner;
        var err: ?*c.GError = null;
        const reply = c.g_dbus_connection_call_finish(u.cast(c.GDBusConnection, source), result, &err);
        defer if (err) |e| c.g_error_free(e);
        defer if (reply) |v| c.g_variant_unref(v);
        if (self.closed or r.generation != self.generation) return;
        self.loading = false;
        self.items.clearRetainingCapacity();
        if (reply == null) {
            self.available = false;
            self.message.set("Service manager unavailable. Performance and process monitoring remain active.");
            self.changed(self.context);
            return;
        }
        if (c.g_variant_is_of_type(reply, @ptrCast("(a(ssssssouso))")) == 0) {
            self.message.set("Unexpected service-manager response");
            self.changed(self.context);
            return;
        }
        const array = c.g_variant_get_child_value(reply, 0).?;
        defer c.g_variant_unref(array);
        self.available = true;
        const n = @min(c.g_variant_n_children(array), 16384);
        for (0..n) |i| {
            const tuple = c.g_variant_get_child_value(array, i).?;
            defer c.g_variant_unref(tuple);
            const name = childText(tuple, 0);
            if (!std.mem.endsWith(u8, name, ".service")) continue;
            const item: Service = .{ .name = m.Text(256).init(name), .description = m.Text(256).init(childText(tuple, 1)), .load = m.Name.init(childText(tuple, 2)), .state = m.Name.init(childText(tuple, 3)), .substate = m.Name.init(childText(tuple, 4)), .path = m.Path.init(childText(tuple, 6)) };
            self.items.append(u.a, item) catch unreachable;
        }
        self.message.set(if (self.system) "System services · Actions may require authentication" else "Current user session services");
        if (self.requested.len > 0) {
            var satisfied = false;
            for (self.items.items) |item| {
                if (std.mem.eql(u8, item.name.slice(), self.requested.slice()) and std.mem.eql(u8, item.state.slice(), self.expected.slice())) {
                    satisfied = true;
                    break;
                }
            }
            if (self.jobComplete() and !std.mem.eql(u8, self.job_result.slice(), "done")) {
                const description = @import("io.zig").path("Service job did not complete successfully: {s}", .{self.job_result.slice()});
                self.failAction(description.slice());
            } else if (satisfied and self.jobComplete()) {
                self.message.set("Service reached the requested state");
                self.requested = .{};
            } else if (c.g_get_monotonic_time() - self.request_time > 15000000) {
                self.message.set("Service has not reached the requested state; inspect its status");
                self.requested = .{};
            } else self.message.set("Request accepted; waiting for the service state to update");
        }
        if (self.failure_until > c.g_get_monotonic_time()) self.message = self.failure;
        self.changed(self.context);
    }
    pub fn action(self: *Controller, name: [*:0]const u8, method: [*:0]const u8) void {
        const connection = self.connection orelse return;
        if (self.requested.len > 0) return;
        self.job = .{};
        self.completed_job = .{};
        self.job_result = .{};
        self.failure_until = 0;
        self.requested.set(std.mem.span(name));
        self.expected.set(if (std.mem.eql(u8, std.mem.span(method), "StopUnit")) "inactive" else "active");
        self.request_time = c.g_get_monotonic_time();
        self.message.set("Service request in progress…");
        self.changed(self.context);
        c.g_dbus_connection_call(connection, "org.freedesktop.systemd1", "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager", method, c.g_variant_new("(ss)", name, @as([*:0]const u8, "replace")), null, c.G_DBUS_CALL_FLAGS_ALLOW_INTERACTIVE_AUTHORIZATION, 30000, self.cancel, acted, self.request(true));
    }
    fn acted(source: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const r = u.cast(Request, data);
        defer finish(r);
        const self = r.owner;
        var err: ?*c.GError = null;
        const reply = c.g_dbus_connection_call_finish(u.cast(c.GDBusConnection, source), result, &err);
        defer if (err) |e| c.g_error_free(e);
        defer if (reply) |v| c.g_variant_unref(v);
        if (self.closed or r.generation != self.generation) return;
        self.message.set(if (reply == null) (if (err) |e| std.mem.span(e.message) else "Service action failed") else "Request accepted; waiting for the service state to update");
        if (reply == null) {
            self.failAction(self.message.slice());
        } else if (c.g_variant_is_of_type(reply, @ptrCast("(o)")) != 0) {
            self.job.set(childText(reply.?, 0));
        } else self.failAction("Unexpected service job response");
        self.dirty = true;
        self.changed(self.context);
    }
};
