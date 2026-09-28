//! Redaction for text that reaches a log line from outside the process,
//! applied at the call site rather than trusted to the caller: control bytes
//! cannot split a line or fake an entry, length is bounded, and URL
//! credentials are dropped.
const std = @import("std");

/// Longest payload kept; longer input is cut at a character boundary and
/// marked, so a flood of oversized peer strings cannot fill the journal.
pub const limit = 512;

const truncated_marker = "…[truncated]";
const credential_marker = "[redacted]@";

pub const SafeText = struct {
    text: []const u8,

    pub fn format(self: SafeText, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var storage: [limit]u8 = undefined;
        var buffered = std.Io.Writer.fixed(&storage);
        var cut = false;
        sanitize(&buffered, self.text) catch {
            cut = true;
        };
        const body = if (cut) trimSplitUtf8(buffered.buffered()) else buffered.buffered();
        try writer.writeAll(body);
        if (cut) try writer.writeAll(truncated_marker);
    }
};

pub fn safe(text: []const u8) SafeText {
    return .{ .text = text };
}

pub const Fingerprint = struct {
    value: u64,

    pub fn format(self: Fingerprint, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{x:0>16}", .{self.value});
    }
};

/// Identifier for a secret that must stay correlatable across lines without
/// ever being quotable; the input space is far larger than the digest.
pub fn fingerprint(text: []const u8) Fingerprint {
    return .{ .value = std.hash.Fnv1a_64.hash(text) };
}

/// Userinfo bytes are never written, only replaced, so a cut inside a URL
/// cannot expose part of a password.
fn sanitize(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var pos: usize = 0;
    while (pos < text.len) {
        const found = credentials(text, pos);
        const literal_end = if (found) |span| span.start else text.len;
        try literal(writer, text[pos..literal_end]);
        const span = found orelse return;
        try writer.writeAll(credential_marker);
        pos = span.end;
    }
}

fn literal(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var pos: usize = 0;
    while (pos < text.len) {
        const next = control(text[pos..]) orelse text.len - pos;
        if (next > 0) try writer.writeAll(text[pos .. pos + next]);
        pos += next;
        if (pos == text.len) return;
        try writer.writeAll("?");
        pos += 1;
    }
}

fn control(text: []const u8) ?usize {
    for (text, 0..) |byte, index| if (byte < 0x20 or byte == 0x7f) return index;
    return null;
}

const Span = struct { start: usize, end: usize };

/// Locates the userinfo and its `@` in a `scheme://user:pass@host` URL. The
/// last `@` in the authority ends the userinfo, so a password holding one is
/// still covered; userinfo without a colon is a name, not a credential.
fn credentials(text: []const u8, from: usize) ?Span {
    var pos = from;
    while (std.mem.indexOfPos(u8, text, pos, "://")) |scheme| {
        const start = scheme + 3;
        var end = start;
        while (end < text.len and text[end] != '/' and text[end] != '?' and text[end] != '#') end += 1;
        const authority = text[start..end];
        const at = std.mem.lastIndexOfScalar(u8, authority, '@') orelse {
            pos = start;
            continue;
        };
        if (std.mem.indexOfScalar(u8, authority[0..at], ':') == null) {
            pos = start;
            continue;
        }
        return .{ .start = start, .end = start + at + 1 };
    }
    return null;
}

fn trimSplitUtf8(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and text[end - 1] & 0b1100_0000 == 0b1000_0000) end -= 1;
    if (end == 0) return text[0..0];
    const width = std.unicode.utf8ByteSequenceLength(text[end - 1]) catch return text[0 .. end - 1];
    return if (text.len - (end - 1) < @as(usize, width)) text[0 .. end - 1] else text;
}

fn render(storage: []u8, comptime format: []const u8, args: anytype) []const u8 {
    var writer = std.Io.Writer.fixed(storage);
    writer.print(format, args) catch unreachable;
    return writer.buffered();
}

test "ordinary text passes through unchanged" {
    var storage: [1024]u8 = undefined;
    const text = "no such file /usr/share/pearl/style.css (gtk-css-parser 42)";
    try std.testing.expectEqualStrings(text, render(&storage, "{f}", .{safe(text)}));
    try std.testing.expectEqualStrings("", render(&storage, "{f}", .{safe("")}));
}

test "control bytes cannot split or fake a journal line" {
    var storage: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(
        "a?b?c?d?e?g",
        render(&storage, "{f}", .{safe("a\nb\rc\x1bd\x7fe\tg")}),
    );
    try std.testing.expectEqualStrings(
        "event=css-error message=?error(pearl)? event=ready",
        render(&storage, "{f}", .{safe("event=css-error message=\nerror(pearl)\n event=ready")}),
    );
}

test "oversized text is cut at the limit and marked" {
    var storage: [limit + truncated_marker.len + 16]u8 = undefined;
    const at_limit = render(&storage, "{f}", .{safe("y" ** limit)});
    try std.testing.expectEqual(@as(usize, limit), at_limit.len);
    const over = render(&storage, "{f}", .{safe("x" ** (limit + 100))});
    try std.testing.expectEqual(@as(usize, limit + truncated_marker.len), over.len);
    try std.testing.expect(std.mem.endsWith(u8, over, truncated_marker));
    try std.testing.expect(std.mem.startsWith(u8, over, "xxx"));
}

test "the cut never splits a character" {
    var storage: [limit + truncated_marker.len + 16]u8 = undefined;
    const out = render(&storage, "{f}", .{safe(("a" ** (limit - 1)) ++ "é")});
    try std.testing.expectEqual(@as(usize, limit - 1 + truncated_marker.len), out.len);
    try std.testing.expect(std.mem.endsWith(u8, out, truncated_marker));
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "url credentials are redacted and hosts kept" {
    var storage: [1024]u8 = undefined;
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "get https://user:hunter2@example.com/theme.css failed", .out = "get https://[redacted]@example.com/theme.css failed" },
        .{ .in = "a https://u:1@h b ftp://v:2@i c", .out = "a https://[redacted]@h b ftp://[redacted]@i c" },
        .{ .in = "ssh://git@example.com/repo", .out = "ssh://git@example.com/repo" },
        .{ .in = "https://user:p@ss@example.com", .out = "https://[redacted]@example.com" },
        .{ .in = "proxy http://u:p@127.0.0.1:8080/x", .out = "proxy http://[redacted]@127.0.0.1:8080/x" },
        .{ .in = "git@github.com:seafoam/pearl", .out = "git@github.com:seafoam/pearl" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.out, render(&storage, "{f}", .{safe(case.in)}));
}

test "a cut inside a url exposes no userinfo" {
    var storage: [limit + truncated_marker.len + 16]u8 = undefined;
    const cases = [_][]const u8{
        "a" ** (limit - 4) ++ "https://user:hunter2@example.com",
        "a" ** (limit + 4) ++ "https://user:hunter2@example.com",
        "a" ** (limit - 20) ++ "https://user:hunter2@example.com",
    };
    for (cases) |text| {
        const out = render(&storage, "{f}", .{safe(text)});
        try std.testing.expect(std.mem.indexOf(u8, out, "hunter2") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "user") == null);
        try std.testing.expect(std.mem.endsWith(u8, out, truncated_marker));
    }
}

test "fingerprint renders padded hex and hides the input" {
    var padded: [64]u8 = undefined;
    try std.testing.expectEqualStrings("000000000000001f", render(&padded, "{f}", .{Fingerprint{ .value = 0x1f }}));
    const token = "0123456789abcdef0123456789abcdef";
    var first_storage: [64]u8 = undefined;
    var repeat_storage: [64]u8 = undefined;
    var other_storage: [64]u8 = undefined;
    const first = render(&first_storage, "{f}", .{fingerprint(token)});
    try std.testing.expectEqual(@as(usize, 16), first.len);
    try std.testing.expectEqualStrings(first, render(&repeat_storage, "{f}", .{fingerprint(token)}));
    try std.testing.expect(!std.mem.eql(u8, first, render(&other_storage, "{f}", .{fingerprint(token ++ "0")})));
    try std.testing.expect(std.mem.indexOfNone(u8, first, "0123456789abcdef") == null);
}
