//! Calendar date arithmetic, kept free of GTK so the pure test step covers it.
const std = @import("std");

pub const Date = struct { year: i32, month: u32, day: u32 };
pub const Month = struct { year: i32, month: u32 };

pub fn sameDate(left: Date, right: Date) bool {
    return left.year == right.year and left.month == right.month and left.day == right.day;
}
pub fn sameMonth(date: Date, month: Month) bool {
    return date.year == month.year and date.month == month.month;
}
pub fn monthOf(date: Date) Month {
    return .{ .year = date.year, .month = date.month };
}
pub fn stepBack(month: Month) Month {
    return if (month.month == 1) .{ .year = month.year - 1, .month = 12 } else .{ .year = month.year, .month = month.month - 1 };
}
pub fn stepForward(month: Month) Month {
    return if (month.month == 12) .{ .year = month.year + 1, .month = 1 } else .{ .year = month.year, .month = month.month + 1 };
}

/// Moves a day offset across month boundaries; callers stay within one week.
pub fn shift(year: i32, month: u32, day: i32) Date {
    if (day < 1) {
        const previous = stepBack(.{ .year = year, .month = month });
        return .{ .year = previous.year, .month = previous.month, .day = @intCast(@as(i32, @intCast(daysInMonth(previous.year, previous.month))) + day) };
    }
    const count: i32 = @intCast(daysInMonth(year, month));
    if (day > count) {
        const next = stepForward(.{ .year = year, .month = month });
        return .{ .year = next.year, .month = next.month, .day = @intCast(day - count) };
    }
    return .{ .year = year, .month = month, .day = @intCast(day) };
}

pub fn daysInMonth(year: i32, month: u32) u32 {
    const lengths = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2 and @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) return 29;
    return lengths[month - 1];
}

/// Sakamoto's algorithm; returns the ISO weekday of the first day, 1 = Monday.
pub fn firstWeekday(year: i32, month: u32) u32 {
    const offsets = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    const adjusted = if (month < 3) year - 1 else year;
    const sunday_first = @mod(adjusted + @divTrunc(adjusted, 4) - @divTrunc(adjusted, 100) + @divTrunc(adjusted, 400) + offsets[month - 1] + 1, 7);
    return @intCast(if (sunday_first == 0) 7 else sunday_first);
}

/// Monday-first leading blanks plus the month's days must fit the fixed grid.
pub fn visibleSlots(lead: u32, count: u32, columns: usize) usize {
    const week: u32 = @intCast(columns);
    return @intCast((lead + count + week - 1) / week * week);
}

test "firstWeekday agrees with known months" {
    try std.testing.expectEqual(@as(u32, 2), firstWeekday(2026, 9)); // Tuesday
    try std.testing.expectEqual(@as(u32, 7), firstWeekday(2026, 3)); // Sunday
    try std.testing.expectEqual(@as(u32, 4), firstWeekday(2024, 2)); // Thursday, leap year
    try std.testing.expectEqual(@as(u32, 3), firstWeekday(2025, 1)); // Wednesday
    try std.testing.expectEqual(@as(u32, 1), firstWeekday(2024, 7)); // Monday
}

test "daysInMonth handles leap years" {
    try std.testing.expectEqual(@as(u32, 29), daysInMonth(2024, 2));
    try std.testing.expectEqual(@as(u32, 28), daysInMonth(2026, 2));
    try std.testing.expectEqual(@as(u32, 28), daysInMonth(1900, 2));
    try std.testing.expectEqual(@as(u32, 29), daysInMonth(2000, 2));
    try std.testing.expectEqual(@as(u32, 31), daysInMonth(2026, 12));
}

test "shift crosses month and year boundaries" {
    try std.testing.expectEqual(Date{ .year = 2026, .month = 8, .day = 31 }, shift(2026, 9, 0));
    try std.testing.expectEqual(Date{ .year = 2026, .month = 8, .day = 26 }, shift(2026, 9, -5));
    try std.testing.expectEqual(Date{ .year = 2026, .month = 10, .day = 3 }, shift(2026, 9, 33));
    try std.testing.expectEqual(Date{ .year = 2026, .month = 9, .day = 15 }, shift(2026, 9, 15));
    try std.testing.expectEqual(Date{ .year = 2027, .month = 1, .day = 2 }, shift(2026, 12, 33));
    try std.testing.expectEqual(Date{ .year = 2025, .month = 12, .day = 28 }, shift(2026, 1, -3));
}

test "month stepping wraps the year" {
    try std.testing.expectEqual(Month{ .year = 2025, .month = 12 }, stepBack(.{ .year = 2026, .month = 1 }));
    try std.testing.expectEqual(Month{ .year = 2027, .month = 1 }, stepForward(.{ .year = 2026, .month = 12 }));
    try std.testing.expectEqual(Month{ .year = 2026, .month = 8 }, stepBack(.{ .year = 2026, .month = 9 }));
}

test "visibleSlots rounds the grid up to whole weeks" {
    try std.testing.expectEqual(@as(usize, 28), visibleSlots(0, 28, 7)); // February starting Monday
    try std.testing.expectEqual(@as(usize, 42), visibleSlots(5, 31, 7)); // 31 days starting Saturday
    try std.testing.expectEqual(@as(usize, 35), visibleSlots(1, 30, 7)); // 30 days starting Tuesday
    try std.testing.expectEqual(@as(usize, 42), visibleSlots(6, 31, 7)); // worst case
}
