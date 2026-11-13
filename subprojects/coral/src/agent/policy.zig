//! Per-tool policy: allow / deny / ask.
//!
//! A `deny` decision must produce NO side effect: the engine never invokes a
//! host callback for a denied tool and returns a denial result instead. `ask`
//! defers to an interactive permission request. `allow` executes directly.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Decision = enum { allow, deny, ask };

pub const Policy = struct {
    allocator: Allocator,
    rules: std.StringHashMap(Decision),
    default_decision: Decision = .ask,

    pub fn init(allocator: Allocator) Policy {
        return .{ .allocator = allocator, .rules = std.StringHashMap(Decision).init(allocator) };
    }

    pub fn deinit(self: *Policy) void {
        var it = self.rules.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.rules.deinit();
    }

    pub fn set(self: *Policy, tool: []const u8, decision: Decision) !void {
        const gop = try self.rules.getOrPut(tool);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, tool);
        }
        gop.value_ptr.* = decision;
    }

    pub fn decide(self: *const Policy, tool: []const u8) Decision {
        return self.rules.get(tool) orelse self.default_decision;
    }

    /// The explicit rule for `tool`, or null when only the default applies.
    pub fn rule(self: *const Policy, tool: []const u8) ?Decision {
        return self.rules.get(tool);
    }

    /// Sensible defaults: read-only tools allowed, edits propose review,
    /// terminal commands ask. Unknown tools fall back to `default_decision`.
    pub fn withDefaults(allocator: Allocator) !Policy {
        var p = Policy.init(allocator);
        errdefer p.deinit();
        try p.set("read_file", .allow);
        try p.set("list_dir", .allow);
        try p.set("search", .allow);
        try p.set("propose_edit", .allow);
        try p.set("run_terminal", .ask);
        return p;
    }
};

test "policy decisions and defaults" {
    const a = std.testing.allocator;
    var p = try Policy.withDefaults(a);
    defer p.deinit();
    try std.testing.expectEqual(Decision.allow, p.decide("read_file"));
    try std.testing.expectEqual(Decision.ask, p.decide("run_terminal"));
    try std.testing.expectEqual(Decision.ask, p.decide("unknown_tool"));
    try std.testing.expect(p.rule("read_file") == .allow);
    try std.testing.expect(p.rule("unknown_tool") == null);
    try p.set("run_terminal", .deny);
    try std.testing.expectEqual(Decision.deny, p.decide("run_terminal"));
    try p.set("read_file", .ask);
    try std.testing.expectEqual(Decision.ask, p.decide("read_file"));
}
