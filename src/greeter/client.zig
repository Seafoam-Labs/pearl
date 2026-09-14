//! greetd conversation adapter; owns both cancellation and conversation generations.
const std = @import("std");
const glib = @import("glib2");
const p = @import("protocol.zig");
const wire = @import("ipc.zig");
const Controller = @import("controller.zig").Controller;
const PassiveToken = @import("controller.zig").PassiveToken;
pub const Client = struct {
    transport: wire.Transport = undefined,
    controller: Controller = .{},
    response: p.Response = .{ .kind = .success },
    username: [257:0]u8 = @splat(0),
    path: [:0]const u8,
    deadline: c_uint = 0,
    attempt_deadline: c_uint = 0,
    attempt_ends_us: i64 = 0,
    ack_source: c_uint = 0,
    ack_token: ?PassiveToken = null,
    history: @import("status_history.zig").History = .{},
    timeout_ms: c_uint = 120000,
    accepted: bool = false,
    recover_after_cancel: bool = false,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    pub fn init(self: *Client) void {
        self.transport = wire.Transport.init(self, event);
    }
    pub fn deinit(self: *Client) void {
        self.clearTimer();
        self.clearAttempt();
        self.clearAck();
        self.history.clear();
        self.transport.deinit();
        std.crypto.secureZero(u8, std.mem.asBytes(&self.response));
    }
    fn clearAck(self: *Client) void {
        if (self.ack_source != 0) _ = glib.Source.remove(self.ack_source);
        self.ack_source = 0;
        self.ack_token = null;
    }
    fn clearAttempt(self: *Client) void {
        if (self.attempt_deadline != 0) _ = glib.Source.remove(self.attempt_deadline);
        self.attempt_deadline = 0;
        self.attempt_ends_us = 0;
    }
    fn attemptExpired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(data.?));
        self.attempt_deadline = 0;
        self.cancel() catch self.fail();
        return 0;
    }
    fn expiredAttempt(self: *Client) bool {
        if (self.attempt_ends_us == 0 or glib.getMonotonicTime() < self.attempt_ends_us) return false;
        self.cancel() catch self.fail();
        return true;
    }
    fn acknowledge(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(data.?));
        self.ack_source = 0;
        const token = self.ack_token orelse return 0;
        self.ack_token = null;
        if (self.expiredAttempt()) return 0;
        self.controller.acknowledge(token) catch return 0;
        self.sendAnswer(null) catch self.fail();
        return 0;
    }
    fn clearTimer(self: *Client) void {
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = 0;
    }
    fn timer(self: *Client, ms: c_uint) void {
        self.clearTimer();
        self.deadline = glib.timeoutAdd(ms, expired, self);
    }
    fn expired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(data.?));
        self.deadline = 0;
        if (self.controller.state == .cancelling or self.controller.start_submitted) self.fail() else self.cancel() catch self.fail();
        return 0;
    }
    pub fn begin(self: *Client, username: []const u8) !void {
        if (username.len == 0 or !p.validText(username, 256)) return error.InvalidUsername;
        try self.controller.begin();
        self.clearAck();
        self.clearAttempt();
        self.history.clear();
        self.attempt_ends_us = glib.getMonotonicTime() + @as(i64, self.timeout_ms) * 1000;
        self.attempt_deadline = glib.timeoutAdd(self.timeout_ms, attemptExpired, self);
        self.accepted = false;
        self.recover_after_cancel = false;
        self.username = @splat(0);
        @memcpy(self.username[0..username.len], username);
        self.transport.open(self.path) catch {
            self.fail();
            return error.Connect;
        };
        self.timer(5000);
        self.changed(self.context);
    }
    pub fn cancel(self: *Client) !void {
        // greetd has global conversation state and no request IDs. An old
        // create/answer handler can still finish after a second-socket cancel.
        // Never begin another login in that ambiguous daemon generation.
        const uncertain = self.controller.pending != null or self.controller.state == .connecting;
        try self.controller.cancel();
        self.clearAck();
        self.clearAttempt();
        self.history.clear();
        self.recover_after_cancel = uncertain;
        // Replace the blocked conversation socket. EOF alone is not cancellation.
        self.transport.open(self.path) catch {
            self.fail();
            return error.Connect;
        };
        self.timer(5000);
        self.changed(self.context);
    }
    pub fn activity(self: *Client) void {
        if (self.controller.needsInput() and !self.expiredAttempt()) self.timer(self.timeout_ms);
    }
    pub fn answer(self: *Client, generation: u64, response: ?[]const u8) !void {
        // Only the queued client callback may acknowledge passive messages.
        if (!self.controller.needsInput() or response == null) return error.NoInputQuestion;
        if (self.expiredAttempt()) return error.AttemptExpired;
        if (!p.validText(response.?, 4096)) return error.InvalidResponse;
        try self.controller.answer(generation, false);
        try self.sendAnswer(response);
    }
    fn sendAnswer(self: *Client, response: ?[]const u8) !void {
        var frame: p.Frame = .{};
        defer frame.wipe();
        try frame.answer(response);
        self.transport.send(frame.slice()) catch {
            self.fail();
            return error.Write;
        };
        self.timer(self.timeout_ms);
        self.changed(self.context);
    }
    pub fn start(self: *Client, env: []const []const u8) !void {
        if (self.expiredAttempt()) return error.AttemptExpired;
        var frame: p.Frame = .{};
        defer frame.wipe();
        try frame.start(env);
        try self.controller.start();
        self.clearAttempt();
        self.clearAck();
        self.history.clear();
        self.transport.send(frame.slice()) catch {
            self.fail();
            return error.Write;
        };
        self.timer(30000);
        self.changed(self.context);
    }
    fn fail(self: *Client) void {
        self.clearTimer();
        self.clearAttempt();
        self.clearAck();
        self.history.clear();
        self.controller.lost();
        self.transport.close();
        self.changed(self.context);
    }
    fn event(context: *anyopaque, ev: wire.Event) void {
        const self: *Client = @ptrCast(@alignCast(context));
        switch (ev) {
            .sent => {},
            .failed => self.fail(),
            .connected => self.connected() catch self.fail(),
            .frame => |bytes| self.receive(bytes) catch self.fail(),
        }
    }
    fn connected(self: *Client) !void {
        var frame: p.Frame = .{};
        defer frame.wipe();
        if (self.controller.state == .cancelling) {
            try frame.cancel();
            self.timer(5000);
        } else {
            try self.controller.connected();
            try frame.create(std.mem.sliceTo(&self.username, 0));
            self.timer(self.timeout_ms);
        }
        try self.transport.send(frame.slice());
        self.changed(self.context);
    }
    fn receive(self: *Client, bytes: []const u8) !void {
        if (self.expiredAttempt()) return;
        self.response = try p.decode(bytes);
        try self.controller.receive(self.controller.connection, self.response);
        self.accepted = self.controller.state == .handoff and self.response.kind == .success;
        if (self.controller.state == .idle and self.recover_after_cancel) self.controller.lost();
        self.clearTimer();
        switch (self.controller.state) {
            .prompt, .authenticated, .failed => self.timer(self.timeout_ms),
            .idle, .handoff, .unavailable => {
                self.clearAttempt();
                self.clearAck();
                self.history.clear();
                self.transport.close();
            },
            else => {},
        }
        if (self.controller.passiveToken()) |token| {
            try self.history.append(self.response.text[0..self.response.len]);
            self.ack_token = token;
            self.ack_source = glib.idleAdd(acknowledge, self);
        }
        self.changed(self.context);
    }
};
