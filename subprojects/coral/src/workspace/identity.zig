//! Process-local routing identity, never a path, display name, or persisted ID.
//! Scope is owned by the application/main-context thread; tokens are copyable
//! values, not lifetime holds. Callers must still finish/reap rejected results.
const std = @import("std");

pub const WorkspaceId = enum(u64) { _ };
pub const Token = struct {
    workspace: WorkspaceId,
    generation: u64,
};

// Shared across App instances, including instances created after another closes.
// Saturate rather than wrap: an old token must never name a new workspace.
var last_id = std.atomic.Value(u64).init(0);
fn allocateId() WorkspaceId {
    var previous = last_id.load(.monotonic);
    while (true) {
        const next = std.math.add(u64, previous, 1) catch @panic("Workspace IDs exhausted");
        previous = last_id.cmpxchgWeak(previous, next, .monotonic, .monotonic) orelse return @fromBackingInt(@intCast(next));
    }
}

/// One owner per scope: do not copy a live Scope or mutate its fields directly.
/// Allocate a new scope for a different workspace; invalidate retains identity
/// but retires all earlier requests. Closing is terminal and idempotent.
pub const Scope = struct {
    id: WorkspaceId,
    generation: u64 = 1,
    closed: bool = false,

    pub fn init() Scope {
        return .{ .id = allocateId() };
    }

    pub fn capture(self: *const Scope) ?Token {
        if (self.closed) return null;
        return .{ .workspace = self.id, .generation = self.generation };
    }

    pub fn accepts(self: *const Scope, token: Token) bool {
        return !self.closed and self.id == token.workspace and self.generation == token.generation;
    }

    pub fn invalidate(self: *Scope) void {
        if (self.closed) return;
        self.generation = std.math.add(u64, self.generation, 1) catch @panic("Workspace generation exhausted");
    }

    pub fn close(self: *Scope) void {
        self.closed = true;
    }
};

test "workspace tokens isolate synthetic late results without skipping reaping" {
    const Completion = struct {
        applied: usize = 0,
        reaped: usize = 0,

        fn deliver(self: *@This(), scope: *const Scope, token: Token) void {
            defer self.reaped += 1;
            if (!scope.accepts(token)) return;
            self.applied += 1;
        }
    };
    var first = Scope.init();
    var second = Scope.init();
    const original = first.capture().?;
    var completion: Completion = .{};
    completion.deliver(&first, original);
    completion.deliver(&second, original);
    first.invalidate();
    completion.deliver(&first, original);
    const current = first.capture().?;
    try std.testing.expectEqual(original.workspace, current.workspace);
    try std.testing.expect(current.generation > original.generation);
    completion.deliver(&first, current);
    first.close();
    first.close();
    first.invalidate(); // Must not reopen the scope.
    completion.deliver(&first, current);
    try std.testing.expect(first.capture() == null);
    try std.testing.expectEqual(@as(usize, 2), completion.applied);
    try std.testing.expectEqual(@as(usize, 5), completion.reaped);
    try std.testing.expect(second.accepts(second.capture().?));
}

test "workspace IDs are nonrecycled across closed scopes and independent of generation" {
    var first = Scope.init();
    const token = first.capture().?;
    first.close();
    for (0..128) |_| {
        var next = Scope.init();
        try std.testing.expect(@backingInt(next.id) > @backingInt(token.workspace));
        try std.testing.expectEqual(token.generation, next.capture().?.generation);
        try std.testing.expect(!next.accepts(token));
        next.close();
    }
}
