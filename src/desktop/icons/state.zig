//! Versioned state. Placement and launcher approval use separate files.
const std = @import("std");
const Position = @import("layout.zig").Position;
pub const Placement = struct { uri: []const u8, position: Position };
pub const Approval = struct { uri: []const u8, digest: [64]u8 };
pub const Document = struct { version: u32 = 1, placements: []const Placement = &.{} };
pub const Approvals = struct { version: u32 = 1, approvals: []const Approval = &.{} };
pub const State = struct {
    arena: std.heap.ArenaAllocator,
    placements: std.ArrayList(Placement) = .empty,
    approvals: std.ArrayList(Approval) = .empty,
    corrupt: bool = false,
    approvals_corrupt: bool = false,
    pub fn init(a: std.mem.Allocator) State {
        return .{ .arena = .init(a) };
    }
    pub fn deinit(self: *State) void {
        self.arena.deinit();
    }
    pub fn load(self: *State, bytes: []const u8, approvals: []const u8) void {
        const a = self.arena.allocator();
        if (bytes.len != 0) {
            const doc = std.json.parseFromSliceLeaky(Document, a, bytes, .{ .allocate = .alloc_always }) catch {
                self.corrupt = true;
                return self.loadApprovals(approvals);
            };
            if (doc.version != 1 or doc.placements.len > 100000) {
                self.corrupt = true;
            } else {
                for (doc.placements) |p| {
                    if (p.position.column > 10000 or p.position.row > 10000) {
                        self.corrupt = true;
                        break;
                    }
                    self.placements.append(a, p) catch {};
                }
                if (self.corrupt) self.placements.clearRetainingCapacity();
            }
        }
        self.loadApprovals(approvals);
    }
    fn loadApprovals(self: *State, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const a = self.arena.allocator();
        const doc = std.json.parseFromSliceLeaky(Approvals, a, bytes, .{ .allocate = .alloc_always }) catch {
            self.approvals_corrupt = true;
            return;
        };
        if (doc.version != 1 or doc.approvals.len > 10000) {
            self.approvals_corrupt = true;
            return;
        }
        self.approvals.appendSlice(a, doc.approvals) catch {};
    }
    pub fn position(self: *const State, uri: []const u8) ?Position {
        for (self.placements.items) |p| if (std.mem.eql(u8, uri, p.uri)) return p.position;
        return null;
    }
    pub fn place(self: *State, uri: []const u8, pos: Position) !void {
        for (self.placements.items) |*p| if (std.mem.eql(u8, uri, p.uri)) {
            p.position = pos;
            return;
        };
        if (self.placements.items.len >= 100000) return error.StateLimit;
        const a = self.arena.allocator();
        try self.placements.append(a, .{ .uri = try a.dupe(u8, uri), .position = pos });
    }
    pub fn rename(self: *State, old: []const u8, new: []const u8) void {
        for (self.placements.items) |*p| if (std.mem.eql(u8, old, p.uri)) {
            p.uri = self.arena.allocator().dupe(u8, new) catch return;
            return;
        };
        // Approval deliberately does not migrate across file locations.
    }
    pub fn approved(self: *const State, uri: []const u8, digest: [64]u8) bool {
        for (self.approvals.items) |p| if (std.mem.eql(u8, uri, p.uri)) return std.mem.eql(u8, &digest, &p.digest);
        return false;
    }
    pub fn approve(self: *State, uri: []const u8, digest: [64]u8) !void {
        for (self.approvals.items) |*p| if (std.mem.eql(u8, uri, p.uri)) {
            p.digest = digest;
            return;
        };
        if (self.approvals.items.len >= 10000) return error.StateLimit;
        const a = self.arena.allocator();
        try self.approvals.append(a, .{ .uri = try a.dupe(u8, uri), .digest = digest });
    }
};
test "approval content changes and corrupt layout isolation" {
    var s = State.init(std.testing.allocator);
    defer s.deinit();
    try s.approve("file:///Desktop/App.desktop", @splat('a'));
    try std.testing.expect(s.approved("file:///Desktop/App.desktop", @splat('a')));
    try std.testing.expect(!s.approved("file:///Desktop/App.desktop", @splat('b')));
    try std.testing.expect(!s.approved("file:///Desktop/Other.desktop", @splat('a')));
    const text = try std.json.Stringify.valueAlloc(std.testing.allocator, Approvals{ .approvals = s.approvals.items }, .{});
    defer std.testing.allocator.free(text);
    var recovered = State.init(std.testing.allocator);
    defer recovered.deinit();
    recovered.load("broken", text);
    try std.testing.expect(recovered.corrupt);
    try std.testing.expect(recovered.approved("file:///Desktop/App.desktop", @splat('a')));
}
