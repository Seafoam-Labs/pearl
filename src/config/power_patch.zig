//! Allowlisted immediate edits, isolated from the global preference draft.
const std = @import("std");
const model = @import("preferences.zig");
pub const Source = enum { ac, battery };
pub const Field = enum { screen_off_seconds, suspend_seconds, dim, automatic_saver };
pub fn patch(alloc: std.mem.Allocator, current: model.Preferences, source: Source, field: Field, value: u32) ![]const u8 {
    var next = current;
    const timers = if (source == .ac) &next.idle.ac else &next.idle.battery;
    switch (field) {
        .screen_off_seconds => timers.screen_off_seconds = value,
        .suspend_seconds => timers.suspend_seconds = value,
        .dim => {
            if (value > 1) return error.InvalidRequest;
            timers.dim = value == 1;
        },
        .automatic_saver => {
            if (value > 30) return error.InvalidPowerSaverThreshold;
            next.idle.automatic_saver = @intCast(value);
        },
    }
    try next.idle.validate();
    return std.json.Stringify.valueAlloc(alloc, next, .{});
}
test "scoped power changes preserve unrelated configuration and reject unsafe sleep" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var current: model.Preferences = .{};
    current.font_size = 18;
    const next = try model.parse(a, try patch(a, current, .ac, .screen_off_seconds, 300));
    try std.testing.expectEqual(@as(u8, 18), next.font_size);
    try std.testing.expectEqual(@as(u32, 300), next.idle.ac.screen_off_seconds);
    try std.testing.expectEqual(@as(u32, 0), next.idle.battery.screen_off_seconds);
    try std.testing.expectError(error.LockBeforeSuspendRequired, patch(a, current, .ac, .suspend_seconds, 900));
    const ours = "{\"font_size\":20}";
    const encoded = try patch(a, .{}, .ac, .screen_off_seconds, 300);
    const merged = try model.parse(a, try @import("merge.zig").json(a, "{}", ours, encoded));
    try std.testing.expectEqual(@as(u8, 20), merged.font_size);
    try std.testing.expectError(error.MergeConflict, @import("merge.zig").json(a, "{}", "{\"idle\":{\"ac\":{\"screen_off_seconds\":600}}}", encoded));
}
