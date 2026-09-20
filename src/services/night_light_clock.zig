const glib = @import("glib2");
const Config = @import("night_light_policy.zig").Config;
fn minute(now: *glib.DateTime) u16 {
    return @intCast(now.getHour() * 60 + now.getMinute());
}
/// Search real instants in the supplied zone, so skipped and repeated local
/// hours both work. Bounded to 50 hours, including a possible dateline jump.
pub fn nextBoundary(config: Config, now: *glib.DateTime) ?i64 {
    if (config.schedule != .custom) return null;
    const current = config.scheduled(minute(now));
    const start = @divFloor(now.toUnix(), 60) * 60;
    for (1..3001) |offset| {
        const unix = start + @as(i64, @intCast(offset)) * 60;
        const utc = glib.DateTime.newFromUnixUtc(unix) orelse return null;
        defer utc.unref();
        const local = utc.toTimezone(now.getTimezone()) orelse return null;
        defer local.unref();
        if (config.scheduled(minute(local)) != current) return unix;
    }
    return null;
}
