//! Bounded static LSP file-operation registration matching. No filesystem access.
const std = @import("std");
const f = @import("features.zig");
const Value = std.json.Value;
const max_pattern = 1024;
const Token = union(enum) { literal: u21, any, star, globstar, globdir, class: []const u8 };
const Bits = std.StaticBitSet(max_pattern + 1);

pub fn matches(registration: Value, path: []const u8, directory: bool) !bool {
    const filters = try f.array(try f.required(registration, "filters"), 128);
    var budget: usize = 8 * 1024 * 1024;
    for (filters) |filter| {
        if (f.field(filter, "scheme")) |scheme| if (!std.ascii.eqlIgnoreCase(try f.string(scheme), "file")) continue;
        const pattern = try f.required(filter, "pattern");
        if (f.field(pattern, "matches")) |kind| {
            const name = try f.string(kind);
            if (std.mem.eql(u8, name, "file")) {
                if (directory) continue;
            } else if (std.mem.eql(u8, name, "folder")) {
                if (!directory) continue;
            } else return error.InvalidFileOperationFilter;
        }
        const glob = try f.string(try f.required(pattern, "glob"));
        const insensitive = if (f.field(pattern, "options")) |options| try f.optionalBool(options, "ignoreCase", false) else false;
        if (insensitive) {
            // Do not guess Unicode case folding using ASCII lowercasing.
            for (glob) |ch| if (ch >= 128) return error.UnicodeCaseInsensitiveFileGlobUnsupported;
            for (path) |ch| if (ch >= 128) return error.UnicodeCaseInsensitiveFileGlobUnsupported;
        }
        var alternatives: usize = 64;
        if (try expand(glob, path, insensitive, 0, &alternatives, &budget)) return true;
    }
    return false;
}

fn expand(pattern: []const u8, path: []const u8, insensitive: bool, depth: usize, alternatives: *usize, budget: *usize) anyerror!bool {
    if (pattern.len > max_pattern or path.len > 4095 or depth > 8) return error.FileOperationGlobLimit;
    var open: ?usize = null;
    var nesting: usize = 0;
    var escaped = false;
    var in_class = false;
    for (pattern, 0..) |ch, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\') {
            escaped = true;
            continue;
        }
        if (ch == '[') in_class = true;
        if (ch == ']') in_class = false;
        if (in_class) continue;
        if (ch == '{') {
            if (open == null) open = i;
            nesting += 1;
        } else if (ch == '}') {
            if (nesting == 0) return error.InvalidFileOperationGlob;
            nesting -= 1;
            if (nesting != 0) continue;
            const start = open.?;
            var part = start + 1;
            var inner: usize = 0;
            var slash = false;
            var cls = false;
            for (pattern[part .. i + 1], part..) |item, at| {
                if (slash) {
                    slash = false;
                    continue;
                }
                if (item == '\\') {
                    slash = true;
                    continue;
                }
                if (item == '[') cls = true;
                if (item == ']') cls = false;
                if (cls) continue;
                if (item == '{') inner += 1;
                if (at == i or (item == ',' and inner == 0)) {
                    var buffer: [max_pattern]u8 = undefined;
                    const size = start + at - part + pattern.len - i - 1;
                    if (size > buffer.len) return error.FileOperationGlobLimit;
                    @memcpy(buffer[0..start], pattern[0..start]);
                    @memcpy(buffer[start..][0 .. at - part], pattern[part..at]);
                    @memcpy(buffer[start + at - part .. size], pattern[i + 1 ..]);
                    if (try expand(buffer[0..size], path, insensitive, depth + 1, alternatives, budget)) return true;
                    part = at + 1;
                } else if (item == '}') inner -= 1;
            }
            return false;
        }
    }
    if (open != null) return error.InvalidFileOperationGlob;
    if (alternatives.* == 0) return error.FileOperationGlobLimit;
    alternatives.* -= 1;
    return globMatch(pattern, path, insensitive, budget);
}

fn scalar(text: []const u8, index: *usize) !u21 {
    const width = try std.unicode.utf8ByteSequenceLength(text[index.*]);
    if (width > text.len - index.*) return error.InvalidUtf8;
    const value = try std.unicode.utf8Decode(text[index.*..][0..width]);
    index.* += width;
    return value;
}
fn fold(ch: u21, insensitive: bool) u21 {
    return if (insensitive and ch <= 127) std.ascii.toLower(@intCast(ch)) else ch;
}
fn classMatch(pattern: []const u8, value: u21, insensitive: bool) !bool {
    var i: usize = 0;
    const negate = pattern.len != 0 and (pattern[0] == '!' or pattern[0] == '^');
    if (negate) i += 1;
    var found = false;
    while (i < pattern.len) {
        const lo = fold(try scalar(pattern, &i), insensitive);
        var hi = lo;
        if (i + 1 < pattern.len and pattern[i] == '-') {
            i += 1;
            hi = fold(try scalar(pattern, &i), insensitive);
        }
        if (lo > hi) return error.InvalidFileOperationGlob;
        if (value >= lo and value <= hi) found = true;
    }
    return found != negate;
}
fn globMatch(pattern: []const u8, path: []const u8, insensitive: bool, budget: *usize) !bool {
    var tokens: [max_pattern]Token = undefined;
    var count: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) {
        const start = i;
        const ch = try scalar(pattern, &i);
        tokens[count] = switch (ch) {
            '*' => blk: {
                while (i < pattern.len and pattern[i] == '*') i += 1;
                if (i - start >= 2) {
                    if (i < pattern.len and pattern[i] == '/') {
                        i += 1;
                        break :blk .globdir;
                    }
                    break :blk .globstar;
                }
                break :blk .star;
            },
            '?' => .any,
            '[' => blk: {
                const end = std.mem.indexOfScalarPos(u8, pattern, i, ']') orelse return error.InvalidFileOperationGlob;
                if (end == i) return error.InvalidFileOperationGlob;
                const item = pattern[i..end];
                i = end + 1;
                break :blk .{ .class = item };
            },
            '\\' => if (i < pattern.len) .{ .literal = fold(try scalar(pattern, &i), insensitive) } else return error.InvalidFileOperationGlob,
            else => .{ .literal = fold(ch, insensitive) },
        };
        count += 1;
    }
    var current = Bits.empty;
    var middle = Bits.empty;
    current.set(0);
    var offset: usize = 0;
    while (true) {
        if (count > budget.*) return error.FileOperationGlobLimit;
        budget.* -= count;
        const eof = offset == path.len;
        const ch = if (eof) 0 else fold(try scalar(path, &offset), insensitive);
        var next = Bits.empty;
        var next_middle = Bits.empty;
        for (tokens[0..count], 0..) |token, at| {
            const active = current.isSet(at);
            switch (token) {
                .star, .globstar => {
                    if (active) current.set(at + 1);
                    if (active and !eof and (token == .globstar or ch != '/')) next.set(at);
                },
                .globdir => {
                    if (active) current.set(at + 1);
                    if (!eof and (active or middle.isSet(at))) {
                        next_middle.set(at);
                        if (ch == '/') next.set(at + 1);
                    }
                },
                .any => if (active and !eof and ch != '/') {
                    next.set(at + 1);
                },
                .literal => |literal| if (active and !eof and literal == ch) {
                    next.set(at + 1);
                },
                .class => |cls| if (active and !eof and ch != '/' and try classMatch(cls, ch, insensitive)) {
                    next.set(at + 1);
                },
            }
        }
        if (eof) return current.isSet(count);
        current = next;
        middle = next_middle;
    }
}

test "static file operation registrations honor scheme kind and ignoreCase" {
    var parsed = try @import("protocol.zig").parseMessage(std.testing.allocator,
        \\{"filters":[{"scheme":"file","pattern":{"glob":"**/*.ZIG","matches":"file","options":{"ignoreCase":true}}}]}
    );
    defer parsed.deinit();
    try std.testing.expect(try matches(parsed.value, "/root/main.zig", false));
    try std.testing.expect(!try matches(parsed.value, "/root/main.zig", true));
    try std.testing.expect(!try matches(parsed.value, "/root/main.txt", false));
    try std.testing.expectError(error.UnicodeCaseInsensitiveFileGlobUnsupported, matches(parsed.value, "/root/é.zig", false));
    var other = try @import("protocol.zig").parseMessage(std.testing.allocator,
        \\{"filters":[{"scheme":"https","pattern":{"glob":"**"}}]}
    );
    defer other.deinit();
    try std.testing.expect(!try matches(other.value, "/root/main.zig", false));
}

test "file operation glob expansion and matching fail within fixed budgets" {
    var budget: usize = 0;
    var alternatives: usize = 64;
    try std.testing.expectError(error.FileOperationGlobLimit, expand("**/*.zig", "/root/main.zig", false, 0, &alternatives, &budget));
    budget = 100_000;
    alternatives = 1;
    try std.testing.expectError(error.FileOperationGlobLimit, expand("{a,b,c}", "z", false, 0, &alternatives, &budget));
    alternatives = 64;
    try std.testing.expectError(error.InvalidFileOperationGlob, expand("{unclosed", "x", false, 0, &alternatives, &budget));
}

test "file operation filters include globstar braces classes and Unicode positions" {
    const cases = .{
        .{ "**/*.{zig,zon}", "/work/a.zig", true },
        .{ "**/*.{zig,zon}", "/work/a.txt", false },
        .{ "**/a?.zig", "/work/aé.zig", true },
        .{ "**/a[!0-9].zig", "/work/ab.zig", true },
        .{ "**/a[!0-9].zig", "/work/a4.zig", false },
        .{ "**/a.zig", "a.zig", true },
        .{ "/work/*", "/work/deep/a", false },
        .{ "/work/**", "/work/deep/a", true },
        .{ "**/{a,{b,c}}.zig", "/work/c.zig", true },
    };
    inline for (cases) |case| {
        var budget: usize = 100_000;
        var alternatives: usize = 64;
        try std.testing.expectEqual(case[2], try expand(case[0], case[1], false, 0, &alternatives, &budget));
    }
}
