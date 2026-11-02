//! Pure clock identities and preferences; no wall clock, GTK or filesystem access.
const std = @import("std");
pub const max_clocks = 8;
pub const Definition = struct {
    id: []const u8,
    timezone: []const u8 = "local",
    label: []const u8 = "",
    hour_format: enum { @"12h", @"24h" } = .@"24h",
    show_date: bool = false,
    /// GDateTime/strftime pattern; empty follows `hour_format`'s built-in pattern.
    time_format: []const u8 = "",
    /// GDateTime/strftime pattern; empty uses "%a %d %b".
    date_format: []const u8 = "",
    /// Rendered between the date and the time on horizontal bars.
    separator: []const u8 = "·",
};
pub const legacy: Definition = .{ .id = "local", .show_date = true };
const format_specifiers = "aAbBcCdDeFgGhHIjklmMnOpPrRsStTuUVwWxXyYzZ%";
pub fn validFormat(pattern: []const u8) bool {
    if (pattern.len > 64 or !std.unicode.utf8ValidateSlice(pattern)) return false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] < 32 or pattern[i] == 127) return false;
        if (pattern[i] != '%') continue;
        i += 1;
        if (i >= pattern.len) return false;
        switch (pattern[i]) {
            '-', '_', '0', '^', '#' => {
                i += 1;
                if (i >= pattern.len) return false;
            },
            else => {},
        }
        if (pattern[i] == ':') {
            i += 1;
            if (i >= pattern.len or pattern[i] != 'z') return false;
        } else if (std.mem.indexOfScalar(u8, format_specifiers, pattern[i]) == null) return false;
    }
    return true;
}
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 32) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}
pub fn reference(ref: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, ref, "clock")) return "local";
    if (!std.mem.startsWith(u8, ref, "clock:")) return null;
    const id = ref[6..];
    return if (validId(id) and !std.mem.eql(u8, id, "local")) id else null;
}
pub fn token(a: std.mem.Allocator, id: []const u8) ![]const u8 {
    return if (std.mem.eql(u8, id, "local")) "clock" else std.fmt.allocPrint(a, "clock:{s}", .{id});
}
pub fn validZone(zone: []const u8) bool {
    if (zone.len == 0 or zone.len > 128) return false;
    var parts = std.mem.splitScalar(u8, zone, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        for (part) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '+') return false;
    }
    return true;
}
pub fn validateDefinition(d: Definition) !void {
    if (!validId(d.id)) return error.InvalidClockId;
    if (!validZone(d.timezone)) return error.InvalidClockZone;
    if (d.label.len > 64 or !std.unicode.utf8ValidateSlice(d.label)) return error.InvalidClockLabel;
    for (d.label) |c| if (c < 32 or c == 127) return error.InvalidClockLabel;
    if (!validFormat(d.time_format) or !validFormat(d.date_format)) return error.InvalidClockFormat;
    if (d.separator.len > 16 or !std.unicode.utf8ValidateSlice(d.separator)) return error.InvalidClockSeparator;
    for (d.separator) |c| if (c < 32 or c == 127) return error.InvalidClockSeparator;
}
pub fn find(definitions: []const Definition, id: []const u8) ?Definition {
    for (definitions) |d| if (std.mem.eql(u8, d.id, id)) return d;
    return if (std.mem.eql(u8, id, "local")) legacy else null;
}
pub fn validate(definitions: []const Definition, groups: anytype) !void {
    if (definitions.len > max_clocks) return error.TooManyClocks;
    var explicit_local = false;
    for (definitions, 0..) |d, i| {
        try validateDefinition(d);
        explicit_local = explicit_local or std.mem.eql(u8, d.id, "local");
        for (definitions[0..i]) |old| if (std.mem.eql(u8, d.id, old.id)) return error.DuplicateClockId;
    }
    var implicit_local = false;
    for ([_][]const u8{ groups.left, groups.center, groups.right }) |group| {
        var parts = std.mem.splitScalar(u8, group, ',');
        while (parts.next()) |part| if (reference(part)) |id| {
            if (find(definitions, id) == null) return error.UnknownClock;
            if (std.mem.eql(u8, id, "local") and !explicit_local) implicit_local = true;
        };
    }
    if (definitions.len + @intFromBool(implicit_local) > max_clocks) return error.TooManyClocks;
}
pub fn displayName(a: std.mem.Allocator, d: Definition) ![:0]const u8 {
    if (d.label.len > 0) return a.dupeSentinel(u8, d.label, 0);
    const city = if (std.mem.eql(u8, d.timezone, "local")) "System local time" else d.timezone[(if (std.mem.lastIndexOfScalar(u8, d.timezone, '/')) |i| i + 1 else 0)..];
    const name = try a.dupeSentinel(u8, city, 0);
    for (name) |*c| if (c.* == '_') {
        c.* = ' ';
    };
    return name;
}

test "clock references and bounded definitions preserve legacy identity" {
    const t = std.testing;
    try t.expectEqualStrings("local", reference("clock").?);
    try t.expect(reference("clock:local") == null);
    try t.expect(reference("clock:") == null);
    try t.expect(reference("clock:../x") == null);
    try t.expect(!validZone("/etc/localtime"));
    try t.expect(!validZone("America/../UTC"));
    try t.expect(!validZone("EST5EDT,M3.2.0,M11.1.0"));
    try t.expect(validZone("Etc/GMT+5"));
    try t.expectError(error.InvalidClockLabel, validateDefinition(.{ .id = "a", .label = "a\nb" }));
    try t.expect(validFormat("%H:%M"));
    try t.expect(validFormat("%a %-d %b %Y"));
    try t.expect(validFormat("%Y-%m-%dT%H:%M%:z"));
    try t.expect(validFormat("100%%"));
    try t.expect(validFormat(""));
    try t.expect(!validFormat("%"));
    try t.expect(!validFormat("%Q"));
    try t.expect(!validFormat("%:x"));
    try t.expect(!validFormat("%H\n%M"));
    try t.expectError(error.InvalidClockFormat, validateDefinition(.{ .id = "a", .time_format = "%Q" }));
    try t.expectError(error.InvalidClockFormat, validateDefinition(.{ .id = "a", .date_format = "%Y-%m-%d %Y-%m-%d %Y-%m-%d %Y-%m-%d %Y-%m-%d %Y-%m-%d %Y-%m-%d %Y" }));
    try t.expectError(error.InvalidClockSeparator, validateDefinition(.{ .id = "a", .separator = "a\tb" }));
    try t.expectError(error.InvalidClockSeparator, validateDefinition(.{ .id = "a", .separator = "xxxxxxxxxxxxxxxxx" }));
    try validateDefinition(.{ .id = "a", .time_format = "%H:%M", .date_format = "%F", .separator = "•" });
}
