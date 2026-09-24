const std = @import("std");
const glib = @import("glib2");
const clock = @import("desktop/clock_time.zig");
fn check(zone_name: []const u8, unix: i64, expected: []const u8, offset: []const u8) !void {
    const zone = clock.resolve(zone_name) orelse return error.ZoneUnavailable;
    defer zone.unref();
    const utc = glib.DateTime.newFromUnixUtc(unix).?;
    defer utc.unref();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try clock.format(arena.allocator(), .{ .id = "test", .timezone = zone_name }, utc, zone, false);
    try std.testing.expectEqualStrings(expected, text.time);
    try std.testing.expect(std.mem.indexOf(u8, text.detail, offset) != null);
}
test "clocks convert a shared instant through DST gaps folds and non-hour offsets" {
    try check("America/New_York", 1772953140, "01:59", "UTC-05:00");
    try check("America/New_York", 1772953200, "03:00", "UTC-04:00");
    try check("America/New_York", 1793512740, "01:59", "UTC-04:00");
    try check("America/New_York", 1793512800, "01:00", "UTC-05:00");
    try check("Asia/Kathmandu", 0, "05:30", "UTC+05:30"); // Historical offset, not today's.
    try check("Asia/Kathmandu", 1772953200, "12:45", "UTC+05:45");
    try check("UTC", 1772953200, "07:00", "UTC+00:00");
}
test "date boundaries and twelve hour midnight and noon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const utc = glib.DateTime.newFromUnixUtc(0).?;
    defer utc.unref();
    const west = clock.resolve("America/Los_Angeles").?;
    defer west.unref();
    const east = clock.resolve("Asia/Tokyo").?;
    defer east.unref();
    const west_text = try clock.format(a, .{ .id = "w" }, utc, west, false);
    const east_text = try clock.format(a, .{ .id = "e" }, utc, east, false);
    try std.testing.expect(std.mem.indexOf(u8, west_text.detail, "1969") != null);
    try std.testing.expect(std.mem.indexOf(u8, east_text.detail, "1970") != null);
    const zone = clock.resolve("UTC").?;
    defer zone.unref();
    const midnight = try clock.format(a, .{ .id = "u", .hour_format = .@"12h" }, utc, zone, false);
    try std.testing.expectEqualStrings("12:00 AM", midnight.time);
    const noon = glib.DateTime.newFromUnixUtc(43200).?;
    defer noon.unref();
    try std.testing.expectEqualStrings("12:00 PM", (try clock.format(a, .{ .id = "u", .hour_format = .@"12h" }, noon, zone, false)).time);
    try std.testing.expectEqualStrings("12\n00\nPM", (try clock.format(a, .{ .id = "u", .hour_format = .@"12h" }, noon, zone, true)).time);
}
test "discovery and resolution reject expressions and paths while retaining aliases" {
    try std.testing.expect(!clock.available("NoSuch/Zone"));
    try std.testing.expect(!clock.available("/etc/localtime"));
    try std.testing.expect(!clock.available("EST5"));
    try std.testing.expect(clock.available("US/Eastern"));
    try std.testing.expect(clock.available("local"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const zones = try clock.catalog(arena.allocator());
    try std.testing.expectEqualStrings("local", zones[0]);
    try std.testing.expectEqualStrings("UTC", zones[1]);
    var found = false;
    for (zones) |zone| if (std.mem.eql(u8, zone, "Europe/London")) {
        found = true;
    };
    try std.testing.expect(found);
    try std.testing.expectEqual(clock.databaseStamp(), clock.databaseStamp());
}

test "local zone is resolved afresh after the process local-zone setting changes" {
    // Mutate only this isolated test process, never the desktop or system zone.
    const saved = if (glib.getenv("TZ")) |value| try std.testing.allocator.dupeZ(u8, std.mem.span(value)) else null;
    defer {
        if (saved) |value| {
            _ = glib.setenv("TZ", value, 1);
            std.testing.allocator.free(value);
        } else glib.unsetenv("TZ");
    }
    _ = glib.setenv("TZ", "UTC", 1);
    try check("local", 1772953200, "07:00", "UTC+00:00");
    _ = glib.setenv("TZ", "Asia/Tokyo", 1);
    try check("local", 1772953200, "16:00", "UTC+09:00");
}
