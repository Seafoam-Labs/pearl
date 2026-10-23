//! Regional calendar policy uses the active LC_TIME data, independently of UI packs.
const std = @import("std");
const c = @cImport({
    @cInclude("langinfo.h");
});
/// ISO index: Monday = 0, Sunday = 6. Unknown libc data preserves Monday.
pub fn firstWeekday() u32 {
    if (!@hasDecl(c, "_NL_TIME_FIRST_WEEKDAY") or !@hasDecl(c, "_NL_TIME_WEEK_1STDAY")) return 0;
    const first = c.nl_langinfo(c._NL_TIME_FIRST_WEEKDAY);
    const origin = @intFromPtr(c.nl_langinfo(c._NL_TIME_WEEK_1STDAY));
    if (first == null or first[0] < 1 or first[0] > 7) return 0;
    const base: u32 = switch (origin) {
        19971130 => 6,
        19971201 => 0,
        else => return 0,
    };
    return (base + first[0] - 1) % 7;
}
pub fn leading(iso_first: u32, week_start: u32) u32 {
    return (iso_first - 1 + 7 - week_start) % 7;
}
test "regional calendar offsets" {
    try std.testing.expectEqual(@as(u32, 6), leading(7, 0));
    try std.testing.expectEqual(@as(u32, 0), leading(7, 6));
    try std.testing.expectEqual(@as(u32, 2), leading(2, 6));
}
