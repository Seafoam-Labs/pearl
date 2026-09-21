const std = @import("std");
pub const Newline = enum { lf, crlf, mixed };
pub const Decoded = struct { text: []u8, bom: bool, newline: Newline };
pub fn decode(a: std.mem.Allocator, input: []const u8) !Decoded {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    const bom = std.mem.startsWith(u8, input, "\xef\xbb\xbf");
    const src = if (bom) input[3..] else input;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var lf: usize = 0;
    var crlf: usize = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const b = src[i];
        if (b == 0 or (b < 32 and b != '\n' and b != '\r' and b != '\t' and b != 12)) return error.BinaryInput;
        if (b == '\r') {
            if (i + 1 >= src.len or src[i + 1] != '\n') return error.UnsupportedLineEnding;
            crlf += 1;
            i += 1;
            try out.append(a, '\n');
        } else {
            if (b == '\n') lf += 1;
            try out.append(a, b);
        }
    }
    return .{ .text = try out.toOwnedSlice(a), .bom = bom, .newline = if (lf > 0 and crlf > 0) .mixed else if (crlf > 0) .crlf else .lf };
}
pub fn encode(a: std.mem.Allocator, text: []const u8, bom: bool, newline: Newline) ![]u8 {
    if (newline == .mixed) return error.NeedsNormalization;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    if (bom) try out.appendSlice(a, "\xef\xbb\xbf");
    for (text) |b| {
        if (b == '\n' and newline == .crlf) try out.append(a, '\r');
        try out.append(a, b);
    }
    return out.toOwnedSlice(a);
}
pub fn saveKeepsDirty(captured: u64, current: u64) bool {
    return captured != current;
}
test "UTF-8 BOM CRLF and final-newline round trips" {
    for ([_][]const u8{ "plain", "a\nb\n", "\xef\xbb\xbfcafé 🌱\r\nlast", "" }) |src| {
        const d = try decode(std.testing.allocator, src);
        defer std.testing.allocator.free(d.text);
        const out = try encode(std.testing.allocator, d.text, d.bom, d.newline);
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(src, out);
    }
}
test "reject unsafe inputs and require mixed-line consent" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidUtf8, decode(a, "\xff"));
    try std.testing.expectError(error.BinaryInput, decode(a, "a\x00b"));
    try std.testing.expectError(error.UnsupportedLineEnding, decode(a, "a\rb"));
    const d = try decode(a, "a\r\nb\n");
    defer a.free(d.text);
    try std.testing.expectEqual(Newline.mixed, d.newline);
    try std.testing.expectError(error.NeedsNormalization, encode(a, d.text, false, d.newline));
    try std.testing.expect(saveKeepsDirty(2, 3));
    try std.testing.expect(!saveKeepsDirty(2, 2));
}
