//! Locale policy independent of installed libc locale data and GTK.
const std = @import("std");
pub const max_locale = 63;
pub fn valid(s: []const u8) bool {
    if (s.len == 0 or s.len > max_locale or !std.ascii.isAlphabetic(s[0])) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '@') return false;
    if (!std.ascii.isAlphanumeric(s[s.len - 1])) return false;
    for (s[1..], s[0 .. s.len - 1]) |current, previous| if (!std.ascii.isAlphanumeric(current) and !std.ascii.isAlphanumeric(previous)) return false;
    if (std.mem.count(u8, s, "@") > 1) return false;
    return true;
}
pub fn isCanonical(s: []const u8) bool {
    var buffer: [64]u8 = undefined;
    const value = canonical(&buffer, s) orelse return false;
    return valid(s) and std.mem.eql(u8, value, s);
}
pub fn canonical(buffer: *[64]u8, raw: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, raw, "C") or std.mem.eql(u8, raw, "POSIX") or std.mem.startsWith(u8, raw, "C.")) return "en";
    var n: usize = 0;
    var encoding = false;
    for (raw) |c| {
        if (c == '.') {
            encoding = true;
            continue;
        }
        if (c == '@') encoding = false;
        if (encoding) continue;
        if (n == buffer.len - 1) return null;
        buffer[n] = if (c == '-') '_' else c;
        n += 1;
    }
    if (!valid(buffer[0..n])) return null;
    return buffer[0..n];
}
pub const Preferences = struct {
    values: [32][64:0]u8 = @splat(@splat(0)),
    lengths: [32]u8 = @splat(0),
    len: usize = 0,
    pub fn get(self: *const Preferences, i: usize) [:0]const u8 {
        return self.values[i][0..self.lengths[i] :0];
    }
    fn add(self: *Preferences, s: []const u8) void {
        for (0..self.len) |i| if (std.mem.eql(u8, self.get(i), s)) return;
        if (self.len == self.values.len) return;
        @memcpy(self.values[self.len][0..s.len], s);
        self.lengths[self.len] = @intCast(s.len);
        self.len += 1;
    }
    pub fn append(self: *Preferences, raw: []const u8) void {
        var buf: [64]u8 = undefined;
        const s = canonical(&buf, raw) orelse return;
        self.add(s);
        const modifier = std.mem.indexOfScalar(u8, s, '@');
        const territory = std.mem.indexOfScalar(u8, s, '_');
        if (territory) |t| if (modifier) |m| {
            var b: [64]u8 = undefined;
            self.add(std.fmt.bufPrint(&b, "{s}{s}", .{ s[0..t], s[m..] }) catch return);
        };
        if (modifier) |m| self.add(s[0..m]);
        if (territory) |t| self.add(s[0..t]) else if (modifier) |m| self.add(s[0..m]);
    }
    pub fn resolve(override: []const u8, language: []const u8, all: []const u8, messages: []const u8, lang: []const u8) Preferences {
        var result: Preferences = .{};
        if (override.len > 0) {
            result.append(override);
        } else {
            const base = if (all.len > 0) all else if (messages.len > 0) messages else if (lang.len > 0) lang else "C";
            // The C locale disables LANGUAGE. C.UTF-8 permits translated UI.
            if (std.mem.eql(u8, base, "C") or std.mem.eql(u8, base, "POSIX")) {
                result.add("en");
                return result;
            }
            if (language.len > 0) {
                var parts = std.mem.splitScalar(u8, language, ':');
                while (parts.next()) |part| result.append(part);
            } else result.append(base);
        }
        result.add("en");
        return result;
    }
};
test "locale preference ordering and safe regional fallback" {
    const p = Preferences.resolve("", "fr_CA:de_DE.UTF-8", "", "", "C.UTF-8");
    try std.testing.expectEqualStrings("fr_CA", p.get(0));
    try std.testing.expectEqualStrings("fr", p.get(1));
    try std.testing.expectEqualStrings("de_DE", p.get(2));
    try std.testing.expectEqualStrings("de", p.get(3));
    try std.testing.expectEqualStrings("en", Preferences.resolve("", "de", "C", "", "de_DE").get(0));
    try std.testing.expectEqualStrings("ar", Preferences.resolve("ar", "de", "C", "", "").get(0));
    try std.testing.expect(!valid("../../de"));
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("sr_RS@latin", canonical(&b, "sr_RS.UTF-8@latin").?);
}
