//! Named placeholders with bounded output and no translated format-string execution.
const std = @import("std");
pub const Arg = struct { name: []const u8, value: []const u8 };
pub fn render(buffer: []u8, template: []const u8, args: []const Arg) ![:0]const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    var pos: usize = 0;
    while (pos < template.len) {
        const c = template[pos];
        pos += 1;
        if ((c == '{' or c == '}') and pos < template.len and template[pos] == c) {
            try out.writeByte(c);
            pos += 1;
            continue;
        }
        if (c == '}') return error.InvalidPlaceholder;
        if (c != '{') {
            try out.writeByte(c);
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, template, pos, '}') orelse return error.InvalidPlaceholder;
        const name = template[pos..end];
        if (name.len == 0) return error.InvalidPlaceholder;
        for (args) |arg| {
            if (std.mem.eql(u8, name, arg.name)) {
                try out.writeAll(arg.value);
                break;
            }
        } else return error.UnknownPlaceholder;
        pos = end + 1;
    }
    const len = out.end;
    try out.writeByte(0);
    return buffer[0..len :0];
}
pub fn compatible(source: []const u8, translated: []const u8) bool {
    // Check both directions, so dropped arguments are rejected as well as new ones.
    return subset(source, translated) and subset(translated, source);
}
fn subset(source: []const u8, other: []const u8) bool {
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        i += 1;
        if ((c == '{' or c == '}') and i < source.len and source[i] == c) {
            i += 1;
            continue;
        }
        if (c == '}') return false;
        if (c != '{') continue;
        const end = std.mem.indexOfScalarPos(u8, source, i, '}') orelse return false;
        if (end == i) return false;
        if (!has(other, source[i..end])) return false;
        i = end + 1;
    }
    return true;
}
fn has(text: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        i += 1;
        if ((c == '{' or c == '}') and i < text.len and text[i] == c) {
            i += 1;
            continue;
        }
        if (c != '{') continue;
        const end = std.mem.indexOfScalarPos(u8, text, i, '}') orelse return false;
        if (std.mem.eql(u8, text[i..end], name)) return true;
        i = end + 1;
    }
    return false;
}
test "reordered placeholders escaped braces and bounded output" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Ziel: /tmp, 2 Dateien {ok}", try render(&buffer, "Ziel: {destination}, {count} Dateien {{ok}}", &.{ .{ .name = "count", .value = "2" }, .{ .name = "destination", .value = "/tmp" } }));
    try std.testing.expect(compatible("{a} {b}", "{b}: {a}"));
    try std.testing.expect(!compatible("{a} {b}", "{a}"));
    try std.testing.expectError(error.UnknownPlaceholder, render(&buffer, "{missing}", &.{}));
    try std.testing.expectError(error.WriteFailed, render(buffer[0..2], "long", &.{}));
}

/// Convert developer-owned Zig format placeholders into numbered catalog arguments.
/// Only source formats are ever interpreted by std.fmt; catalogs see {0}, {1}, ...
pub fn sourceTemplate(comptime source: []const u8) [:0]const u8 {
    const result = comptime blk: {
        @setEvalBranchQuota(100000);
        var bytes: [source.len * 4 + 32:0]u8 = @splat(0);
        var out: usize = 0;
        var pos: usize = 0;
        var index: usize = 0;
        while (pos < source.len) {
            if (source[pos] == '{' and pos + 1 < source.len and source[pos + 1] != '{') {
                const end = std.mem.indexOfScalarPos(u8, source, pos, '}') orelse @compileError("Invalid source format");
                const key = std.fmt.comptimePrint("{{{d}}}", .{index});
                @memcpy(bytes[out..][0..key.len], key);
                out += key.len;
                index += 1;
                pos = end + 1;
            } else {
                bytes[out] = source[pos];
                out += 1;
                if ((source[pos] == '{' or source[pos] == '}') and pos + 1 < source.len and source[pos + 1] == source[pos]) {
                    pos += 1;
                    bytes[out] = source[pos];
                    out += 1;
                }
                pos += 1;
            }
        }
        break :blk .{ .bytes = bytes, .len = out };
    };
    return std.fmt.comptimePrint("{s}", .{result.bytes[0..result.len]});
}
pub fn spec(comptime source: []const u8, comptime index: usize) []const u8 {
    const result = comptime blk: {
        var pos: usize = 0;
        var n: usize = 0;
        while (pos < source.len) : (pos += 1) {
            if (source[pos] != '{') continue;
            if (pos + 1 < source.len and source[pos + 1] == '{') {
                pos += 1;
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, source, pos, '}') orelse @compileError("Invalid source format");
            if (n == index) break :blk source[pos + 1 .. end];
            n += 1;
            pos = end;
        }
        @compileError("Missing source argument");
    };
    return result;
}
test "source format conversion preserves escapes and types" {
    try std.testing.expectEqualStrings("{0} files at {1} {{ok}}", sourceTemplate("{d} files at {s} {{ok}}"));
    try std.testing.expectEqualStrings("d:.1", spec("{d:.1}", 0));
}
