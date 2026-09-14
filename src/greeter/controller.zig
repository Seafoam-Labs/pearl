//! Pure authority state machine. No UI, sockets, account lookup or process launch.
const std = @import("std");
const p = @import("protocol.zig");
pub const State = enum { idle, connecting, authenticating, prompt, cancelling, authenticated, starting, handoff, failed, unavailable };
pub const Pending = enum { create, answer, cancel, start };
pub const Controller = struct {
    state: State = .idle,
    pending: ?Pending = null,
    attempt: u64 = 0,
    connection: u64 = 0,
    prompt_generation: u64 = 0,
    exchanges: usize = 0,
    kind: p.Prompt = .info,
    start_submitted: bool = false,
    pub fn begin(self: *Controller) !void {
        if (self.state != .idle) return error.Busy;
        self.attempt +%= 1;
        self.connection +%= 1;
        self.exchanges = 0;
        self.start_submitted = false;
        self.state = .connecting;
    }
    pub fn connected(self: *Controller) !void {
        if (self.state != .connecting) return error.UnexpectedConnection;
        self.state = .authenticating;
        self.pending = .create;
    }
    pub fn answer(self: *Controller, generation: u64, is_null: bool) !void {
        if (self.state != .prompt or generation != self.prompt_generation or self.pending != null) return error.StalePrompt;
        if (is_null != (self.kind == .info or self.kind == .@"error")) return error.InvalidAnswerKind;
        self.state = .authenticating;
        self.pending = .answer;
    }
    pub fn cancel(self: *Controller) !void {
        if (self.start_submitted or self.state == .idle or self.state == .handoff or self.state == .unavailable or self.state == .cancelling) return error.CannotCancel;
        self.attempt +%= 1;
        self.connection +%= 1;
        self.prompt_generation +%= 1;
        self.state = .cancelling;
        self.pending = .cancel;
    }
    pub fn start(self: *Controller) !void {
        if (self.state != .authenticated or self.pending != null or self.start_submitted) return error.UnauthorizedStart;
        self.start_submitted = true;
        self.state = .starting;
        self.pending = .start;
    }
    pub fn receive(self: *Controller, connection: u64, response: p.Response) !void {
        if (connection != self.connection) return error.StaleConnection;
        const pending = self.pending orelse return error.UnsolicitedResponse;
        self.pending = null;
        if (response.kind == .@"error") {
            self.state = if (pending == .cancel or pending == .start) .unavailable else .failed;
            return;
        }
        if (pending == .cancel) {
            if (response.kind != .success) return error.UnexpectedResponse;
            self.state = .idle;
            return;
        }
        if (pending == .start) {
            if (response.kind != .success) return error.UnexpectedResponse;
            self.state = .handoff;
            return;
        }
        if (response.kind == .success) {
            self.state = .authenticated;
            return;
        }
        self.exchanges += 1;
        if (self.exchanges > 128) {
            self.state = .failed;
            return error.ConversationLimit;
        }
        self.prompt_generation +%= 1;
        self.kind = response.prompt;
        self.state = .prompt;
    }
    pub fn lost(self: *Controller) void {
        self.pending = null;
        self.connection +%= 1;
        self.state = if (self.start_submitted) .handoff else .unavailable;
    }
};
test "stale replies cannot authorize changed selection and start never replays" {
    var c: Controller = .{};
    try std.testing.expectError(error.UnauthorizedStart, c.start());
    try c.begin();
    try c.connected();
    const old = c.connection;
    try c.cancel();
    try std.testing.expectError(error.StaleConnection, c.receive(old, .{ .kind = .success }));
    try c.receive(c.connection, .{ .kind = .success });
    try c.begin();
    try c.connected();
    try c.receive(c.connection, .{ .kind = .success });
    try c.start();
    c.lost();
    try std.testing.expectEqual(State.handoff, c.state);
    try std.testing.expectError(error.UnauthorizedStart, c.start());
    try std.testing.expectError(error.Busy, c.begin());
}
test "only one matching response per prompt including null acknowledgements" {
    var c: Controller = .{};
    try c.begin();
    try c.connected();
    try c.receive(c.connection, .{ .kind = .auth_message, .prompt = .secret });
    try std.testing.expectError(error.InvalidAnswerKind, c.answer(c.prompt_generation, true));
    try c.answer(c.prompt_generation, false);
    try std.testing.expectError(error.StalePrompt, c.answer(c.prompt_generation, false));
    try c.receive(c.connection, .{ .kind = .auth_message, .prompt = .info });
    try c.answer(c.prompt_generation, true);
    try c.receive(c.connection, .{ .kind = .@"error", .authentication_error = true });
    try std.testing.expectError(error.Busy, c.begin());
    try c.cancel();
    try c.receive(c.connection, .{ .kind = .success });
    try std.testing.expectEqual(State.idle, c.state);
}
