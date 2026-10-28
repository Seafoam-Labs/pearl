//! Filter kernel uevents; DRM property/power notifications are not hotplug.
const std = @import("std");
pub const Event = struct { kind: enum { ignore, topology, backlight } = .ignore, name: []const u8 = "" };
pub fn parse(bytes: []const u8) Event {
    var subsystem: []const u8 = "";
    var action: []const u8 = "";
    var path: []const u8 = "";
    var hotplug = false;
    var fields = std.mem.splitScalar(u8, bytes, 0);
    while (fields.next()) |field| {
        if (std.mem.startsWith(u8, field, "SUBSYSTEM=")) subsystem = field[10..];
        if (std.mem.startsWith(u8, field, "ACTION=")) action = field[7..];
        if (std.mem.startsWith(u8, field, "DEVPATH=")) path = field[8..];
        if (std.mem.eql(u8, field, "HOTPLUG=1")) hotplug = true;
    }
    const membership = std.mem.eql(u8, action, "add") or std.mem.eql(u8, action, "remove");
    if (std.mem.eql(u8, subsystem, "drm") and (membership or (hotplug and std.mem.eql(u8, action, "change")))) return .{ .kind = .topology };
    if (std.mem.eql(u8, subsystem, "backlight")) {
        if (membership) return .{ .kind = .topology };
        if (std.mem.eql(u8, action, "change")) {
            const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return .{};
            const name = path[slash + 1 ..];
            if (@import("policy.zig").deviceName(name)) return .{ .kind = .backlight, .name = name };
        }
    }
    return .{};
}
test "only genuine topology and targeted backlight events request work" {
    try std.testing.expectEqual(.topology, parse("change@/devices/drm/card0\x00ACTION=change\x00SUBSYSTEM=drm\x00HOTPLUG=1\x00").kind);
    try std.testing.expectEqual(.ignore, parse("ACTION=change\x00SUBSYSTEM=drm\x00PROPERTY=DPMS\x00").kind);
    try std.testing.expectEqual(.ignore, parse("ACTION=change\x00SUBSYSTEM=other\x00HOTPLUG=1\x00").kind);
    try std.testing.expectEqual(.topology, parse("ACTION=remove\x00SUBSYSTEM=drm\x00").kind);
    const backlight = parse("ACTION=change\x00SUBSYSTEM=backlight\x00DEVPATH=/devices/panel0\x00");
    try std.testing.expectEqual(.backlight, backlight.kind);
    try std.testing.expectEqualStrings("panel0", backlight.name);
    try std.testing.expectEqual(.ignore, parse("ACTION=change\x00SUBSYSTEM=backlight\x00").kind);
}
