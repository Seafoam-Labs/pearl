//! No inference or I/O while typing. Exact matches and calculations win.
const std = @import("std");
pub const max_query = 2048;
pub fn question(raw: []const u8) []const u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    return if (std.mem.startsWith(u8, value, "?")) std.mem.trimStart(u8, value[1..], " \t") else value;
}
pub fn score(raw: []const u8, enabled: bool, calculation: bool, exact: bool) ?i32 {
    if (!enabled or raw.len > max_query or question(raw).len == 0 or !std.unicode.utf8ValidateSlice(raw)) return null;
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
