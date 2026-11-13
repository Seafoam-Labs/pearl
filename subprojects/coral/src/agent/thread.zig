//! Thread data model and state machine.
//!
//! A thread is a single agent conversation bound to an optional worktree. The
//! state machine is explicit: only legal transitions are permitted, so the UI
//! and backend agree on lifecycle (idle -> streaming -> awaiting_* -> idle,
//! cancellation, failure, closure).

const std = @import("std");
const Allocator = std.mem.Allocator;
const provider = @import("provider.zig");
const context = @import("context.zig");

pub const State = enum {
    idle,
    streaming,
    awaiting_permission,
    awaiting_review,
    cancelling,
    cancelled,
    failed,
    closed,

    pub fn label(self: State) []const u8 {
        return @tagName(self);
    }
};

/// Legal state transitions. Anything not listed is refused.
pub fn canTransition(from: State, to: State) bool {
    return switch (from) {
        .idle => to == .streaming or to == .closed,
        .streaming => to == .awaiting_permission or to == .awaiting_review or
            to == .idle or to == .cancelling or to == .failed or to == .cancelled,
        .awaiting_permission => to == .streaming or to == .cancelling or
            to == .cancelled or to == .failed,
        .awaiting_review => to == .streaming or to == .idle or
            to == .cancelling or to == .failed,
        .cancelling => to == .cancelled or to == .idle or to == .failed,
        .cancelled => to == .streaming or to == .idle or to == .closed,
        .failed => to == .streaming or to == .idle or to == .closed,
        .closed => false,
    };
}

pub const Worktree = struct {
    root: []u8,
    branch: ?[]u8 = null,
    id: ?[]u8 = null,

    pub fn deinit(self: *Worktree, allocator: Allocator) void {
        allocator.free(self.root);
        if (self.branch) |b| allocator.free(b);
        if (self.id) |i| allocator.free(i);
    }
};

pub const Message = struct {
    role: provider.Role,
    content: []u8,
    tool_call_id: ?[]u8 = null,
    name: ?[]u8 = null,

    pub fn deinit(self: *Message, allocator: Allocator) void {
        allocator.free(self.content);
        if (self.tool_call_id) |t| allocator.free(t);
        if (self.name) |n| allocator.free(n);
    }
};

pub const Thread = struct {
    allocator: Allocator,
    id: []u8,
    title: []u8,
    provider_name: []u8,
    model: []u8,
    worktree: ?Worktree = null,
    state: State = .idle,
    messages: std.ArrayList(Message) = .empty,
    attachments: std.ArrayList(context.Attachment) = .empty,
    created_ms: i64 = 0,
    updated_ms: i64 = 0,

    pub fn deinit(self: *Thread) void {
        const a = self.allocator;
        a.free(self.id);
        a.free(self.title);
        a.free(self.provider_name);
        a.free(self.model);
        if (self.worktree) |*w| w.deinit(a);
        for (self.messages.items) |*m| m.deinit(a);
        self.messages.deinit(a);
        for (self.attachments.items) |*att| att.deinit(a);
        self.attachments.deinit(a);
    }

    pub fn setState(self: *Thread, to: State) !void {
        if (!canTransition(self.state, to)) return error.InvalidTransition;
        self.state = to;
    }

    pub fn appendMessage(self: *Thread, role: provider.Role, content: []const u8) !void {
        const owned = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned);
        try self.messages.append(self.allocator, .{ .role = role, .content = owned });
    }
};

test "state machine legal transitions" {
    try std.testing.expect(canTransition(.idle, .streaming));
    try std.testing.expect(canTransition(.streaming, .awaiting_permission));
    try std.testing.expect(canTransition(.awaiting_permission, .streaming));
    try std.testing.expect(canTransition(.streaming, .cancelling));
    try std.testing.expect(canTransition(.cancelling, .cancelled));
    try std.testing.expect(canTransition(.cancelled, .streaming));
    try std.testing.expect(canTransition(.idle, .closed));
}

test "state machine illegal transitions" {
    try std.testing.expect(!canTransition(.idle, .awaiting_permission));
    try std.testing.expect(!canTransition(.closed, .streaming));
    try std.testing.expect(!canTransition(.idle, .cancelled));
    try std.testing.expect(!canTransition(.awaiting_review, .cancelled));
}

test "Thread setState enforces machine" {
    const a = std.testing.allocator;
    var t: Thread = .{
        .allocator = a,
        .id = try a.dupe(u8, "t1"),
        .title = try a.dupe(u8, "T"),
        .provider_name = try a.dupe(u8, "fake"),
        .model = try a.dupe(u8, ""),
    };
    defer t.deinit();
    try t.setState(.streaming);
    try std.testing.expectEqual(State.streaming, t.state);
    try std.testing.expectError(error.InvalidTransition, t.setState(.closed));
    try t.appendMessage(.user, "hello");
    try std.testing.expectEqual(@as(usize, 1), t.messages.items.len);
}
