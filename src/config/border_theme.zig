//! Theme-owned border colors use the normal Aqueous transaction path.
const std = @import("std");
const m = @import("aqueous_model.zig");
const theme = @import("../theme/theme.zig");

pub const ids = [_][]const u8{ "layout.border_focused", "layout.border_normal", "layout.border_urgent" };
pub const Colors = [3][10]u8;
pub fn colors(palette: theme.Palette) !Colors {
    var result: Colors = undefined;
    for ([_][]const u8{ palette.primary, palette.outline, palette.error_color }, &result) |hex, *argb| {
        if (!@import("preferences.zig").hex(hex)) return error.InvalidPalette;
        @memcpy(argb[0..4], "0xFF");
        for (hex[1..], argb[4..]) |ch, *out| out.* = std.ascii.toUpper(ch);
    }
    return result;
}

/// Build a fresh request containing only changed border colors. Never merge a
/// user draft into an automatic save; callers must wait for it to be resolved.
pub fn request(a: std.mem.Allocator, snapshot: m.Value, desired: Colors) !?[]const u8 {
    var draft: ?[]const u8 = null;
    for (ids, desired) |id, color| {
        const spec = m.field(snapshot, id) orelse return error.UnknownField;
        if (std.ascii.eqlIgnoreCase(m.str(m.get(spec, "value")), &color)) continue;
        draft = try @import("aqueous_draft.zig").field(a, snapshot, draft, id, .{ .string = &color });
    }
    return draft;
}

pub const Target = struct { colors: Colors, session: [32]u8 };
pub const Input = struct {
    allowed: bool,
    busy: bool,
    draft: bool,
    unresolved: bool,
    jobs: u64,
    completed_job: ?u64,
    failed: bool,
};
pub const Action = enum { none, refresh, apply };
pub const Sync = struct {
    target: ?Target = null,
    refresh_job: ?u64 = null,
    pending: bool = false,

    pub fn next(self: *Sync, desired: ?Target, input: Input) Action {
        const target = desired orelse {
            self.* = .{};
            return .none;
        };
        if (!input.allowed or input.busy or input.draft or input.unresolved) return .none;
        if (self.target == null or !std.meta.eql(self.target.?, target)) {
            self.target = target;
            self.refresh_job = null;
            self.pending = true;
        }
        if (!self.pending) return .none;
        if (self.refresh_job == null) {
            self.refresh_job = input.jobs +| 1;
            return .refresh;
        }
        if ((input.completed_job orelse return .none) < self.refresh_job.?) return .none;
        // Failures stay visible in Aqueous settings; never retry uncertain saves.
        self.pending = false;
        return if (input.failed) .none else .apply;
    }
};

test "theme borders convert roles to ARGB and stage only the three colors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const desired = try colors(theme.dark);
    try std.testing.expectEqualStrings("0xFFD0BCFF", &desired[0]);
    try std.testing.expectEqualStrings("0xFF79747E", &desired[1]);
    try std.testing.expectEqualStrings("0xFFFFB4AB", &desired[2]);
    const snapshot = try m.parse(a,
        \\{"generation":"abc","fields":[
        \\{"id":"layout.border_focused","file":"layout","value":"0xffd0bcff"},
        \\{"id":"layout.border_normal","file":"layout","value":"0xFF000000"},
        \\{"id":"layout.border_urgent","file":"layout","value":"0xFF000000"}]}
    , 4096);
    const draft = try m.parse(a, (try request(a, snapshot, desired)).?, m.max_request);
    const changes = m.list(m.get(draft, "changes"));
    try std.testing.expectEqual(@as(usize, 2), changes.len);
    try std.testing.expectEqualStrings(ids[1], m.str(m.get(changes[0], "id")));
    try std.testing.expectEqualStrings(&desired[2], m.str(m.get(changes[1], "value")));
    try std.testing.expectEqualStrings("abc", m.str(m.get(draft, "expected_generation")));
    for (m.list(m.get(snapshot, "fields")), &desired) |spec, *color| {
        spec.object.getPtr("value").?.* = .{ .string = color };
    }
    try std.testing.expect((try request(a, snapshot, desired)) == null);
    var bad = theme.dark;
    bad.primary = "invalid";
    try std.testing.expectError(error.InvalidPalette, colors(bad));
}

test "border synchronization waits for drafts and refreshes once per theme or session" {
    var sync: Sync = .{};
    var input: Input = .{ .allowed = true, .busy = false, .draft = true, .unresolved = false, .jobs = 0, .completed_job = null, .failed = false };
    var target: Target = .{ .colors = try colors(theme.dark), .session = @splat('a') };
    try std.testing.expectEqual(Action.none, sync.next(target, input));
    input.draft = false;
    input.allowed = false;
    try std.testing.expectEqual(Action.none, sync.next(target, input));
    input.allowed = true;
    try std.testing.expectEqual(Action.refresh, sync.next(target, input));
    input.busy = true;
    try std.testing.expectEqual(Action.none, sync.next(target, input));
    input.busy = false;
    input.jobs = 1;
    input.completed_job = 1;
    try std.testing.expectEqual(Action.apply, sync.next(target, input));
    try std.testing.expectEqual(Action.none, sync.next(target, input));
    target.colors = try colors(theme.light);
    input.unresolved = true;
    try std.testing.expectEqual(Action.none, sync.next(target, input));
    input.unresolved = false;
    try std.testing.expectEqual(Action.refresh, sync.next(target, input));
    input.completed_job = 2;
    input.jobs = 2;
    input.failed = true;
    try std.testing.expectEqual(Action.none, sync.next(target, input));
    try std.testing.expectEqual(Action.none, sync.next(target, input));
    try std.testing.expectEqual(Action.none, sync.next(null, input));
    try std.testing.expectEqual(Action.refresh, sync.next(target, input));
    input.jobs = 3;
    input.completed_job = 3;
    input.failed = false;
    try std.testing.expectEqual(Action.apply, sync.next(target, input));
    target.session = @splat('b');
    try std.testing.expectEqual(Action.refresh, sync.next(target, input));
}
