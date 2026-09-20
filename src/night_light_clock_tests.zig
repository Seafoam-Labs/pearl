const std = @import("std");
const glib = @import("glib2");
const clock = @import("services/night_light_clock.zig");
const Config = @import("services/night_light_policy.zig").Config;
fn check(zone_name: [:0]const u8, unix: i64, config: Config, expected: i64) !void {
    const zone = glib.TimeZone.newIdentifier(zone_name) orelse return error.ZoneUnavailable;
    defer zone.unref();
    const utc = glib.DateTime.newFromUnixUtc(unix).?;
    defer utc.unref();
    const local = utc.toTimezone(zone).?;
    defer local.unref();
    try std.testing.expectEqual(expected, clock.nextBoundary(config, local).?);
}
test "schedule boundaries use actual instants through DST gaps and folds" {
    // 2026-03-08 01:30 EST; a 02:00 start is crossed at 03:00 EDT.
    try check("America/New_York", 1772951400, .{ .schedule = .custom, .start_minute = 120, .end_minute = 240 }, 1772953200);
    // 2026-11-01 01:45 EDT; at the fold 01:00 EST leaves 01:30–02:00.
    try check("America/New_York", 1793511900, .{ .schedule = .custom, .start_minute = 90, .end_minute = 120 }, 1793512800);
    // Same instant in UTC has a different next local boundary.
    try check("UTC", 1772951400, .{ .schedule = .custom, .start_minute = 120, .end_minute = 240 }, 1773021600);
}
