//! No inference or I/O while typing. Exact matches and calculations win.
const std = @import("std");
pub const max_query = 32768;
pub fn validateQuestion(value: []const u8) !void {
    if (value.len > max_query) return error.QuestionTooLong;
    if (std.mem.trim(u8, value, " \t\r\n").len == 0 or std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidQuestion;
}
pub fn question(raw: []const u8) []const u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    return if (std.mem.startsWith(u8, value, "?")) std.mem.trimStart(u8, value[1..], " \t") else value;
}
pub fn score(raw: []const u8, enabled: bool, calculation: bool, exact: bool) ?i32 {
    if (!enabled or question(raw).len == 0) return null;
    validateQuestion(raw) catch return null;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value[0] == '?') return std.math.maxInt(i32) - 1;
    if (value[0] == '=' or calculation or exact) return -1000;
    if (value[value.len - 1] == '?') return 1000000;
    var words = std.mem.tokenizeAny(u8, value, " \t\r\n");
    const first = words.next() orelse return -1000;
    for ([_][]const u8{ "how", "why", "what", "when", "where", "who", "which", "can", "is", "are", "does", "do", "explain", "summarize", "wie", "warum", "was", "wann", "wo", "wer", "kann", "ist", "sind" }) |word|
        if (std.ascii.eqlIgnoreCase(first, word) and words.next() != null) return 1000000;
    return -1000;
}
test "question intent preserves calculator and exact application precedence" {
    const t = std.testing;
    try t.expect(score("why is the sky blue", true, false, false).? > 0);
    try t.expect(score("Was ist RAM", true, false, false).? > 0);
    try t.expect(score("What", true, false, true).? < 0);
    try t.expect(score("2 + 2", true, true, false).? < 0);
    try t.expect(score("? search RAM", true, false, true).? > 0);
    try t.expect(score("question?", false, false, false) == null);
    try t.expect(score("? ", true, false, false) == null);
    try t.expectEqualStrings("RAM", question(" ? RAM "));
}

test "paragraphs remain askable without outranking exact matches or calculations" {
    const paragraph = "I am planning a trip next month.\nHelp me compare the options and make a packing list.";
    try std.testing.expect(score(paragraph, true, false, false) != null);
    try std.testing.expect(score(paragraph, true, false, true).? < 0);
    try std.testing.expect(score(paragraph, true, true, false).? < 0);
    try std.testing.expectEqualStrings(paragraph, question(paragraph));
    try std.testing.expect(score("firefox", true, false, false).? < 0);
}

test "questions accept more than 2048 bytes but retain a shared finite byte limit" {
    const value: [max_query + 1]u8 = @splat('x');
    try validateQuestion(value[0..2049]);
    try validateQuestion(value[0..max_query]);
    try std.testing.expect(score(value[0..max_query], true, false, false) != null);
    try std.testing.expectError(error.QuestionTooLong, validateQuestion(&value));
    try std.testing.expect(score(&value, true, false, false) == null);
    try std.testing.expectError(error.InvalidQuestion, validateQuestion("\x00"));
    try std.testing.expectError(error.InvalidQuestion, validateQuestion("\xff"));
    try std.testing.expectError(error.InvalidQuestion, validateQuestion(" \n\t"));
}
