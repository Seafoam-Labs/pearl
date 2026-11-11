//! Strict LSP positions in UTF-8 documents. Lines end at LF, CRLF, or bare CR.
//! End-of-line positions point before the terminator; CRLF has no interior
//! position. Columns count encoding units, not graphemes (combining marks count).
//! Out-of-range columns are rejected, never clamped. All text must be valid UTF-8.
const std = @import("std");

pub const Encoding = enum { utf8, utf16, utf32 };
pub const Position = struct { line: u32, character: u32 };
pub const Range = struct { start: Position, end: Position };
pub const ByteRange = struct { start: usize, end: usize };
pub const Error = error{ InvalidUtf8, InvalidBoundary, OutOfRange, ReversedRange };

fn validate(text: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
}

fn newlineLength(text: []const u8, byte: usize) usize {
    return switch (text[byte]) {
        '\r' => if (byte + 1 < text.len and text[byte + 1] == '\n') 2 else 1,
        '\n' => 1,
        else => 0,
    };
}

fn units(width: usize, encoding: Encoding) usize {
    return switch (encoding) {
        .utf8 => width,
        .utf16 => if (width == 4) 2 else 1,
        .utf32 => 1,
    };
}

pub fn byteOffset(text: []const u8, position: Position, encoding: Encoding) Error!usize {
    try validate(text);
    return offsetValidated(text, position, encoding);
}

fn offsetValidated(text: []const u8, position: Position, encoding: Encoding) Error!usize {
    var byte: usize = 0;
    var line: u32 = 0;
    while (line < position.line) {
        if (byte == text.len) return error.OutOfRange;
        const nl = newlineLength(text, byte);
        if (nl != 0) {
            byte += nl;
            line += 1;
        } else byte += std.unicode.utf8ByteSequenceLength(text[byte]) catch unreachable;
    }
    var column: usize = 0;
    while (column < position.character) {
        if (byte == text.len or newlineLength(text, byte) != 0) return error.OutOfRange;
        const width = std.unicode.utf8ByteSequenceLength(text[byte]) catch unreachable;
        const count = units(width, encoding);
        if (count > position.character - column) return error.InvalidBoundary;
        column += count;
        byte += width;
    }
    return byte;
}

pub fn positionAt(text: []const u8, byte: usize, encoding: Encoding) Error!Position {
    try validate(text);
    if (byte > text.len) return error.OutOfRange;
    var cursor: usize = 0;
    var position: Position = .{ .line = 0, .character = 0 };
    while (cursor < byte) {
        const nl = newlineLength(text, cursor);
        if (nl != 0) {
            if (nl > byte - cursor) return error.InvalidBoundary;
            position.line = std.math.add(u32, position.line, 1) catch return error.OutOfRange;
            position.character = 0;
            cursor += nl;
        } else {
            const width = std.unicode.utf8ByteSequenceLength(text[cursor]) catch unreachable;
            if (width > byte - cursor) return error.InvalidBoundary;
            position.character = std.math.add(u32, position.character, @intCast(units(width, encoding))) catch return error.OutOfRange;
            cursor += width;
        }
    }
    return position;
}

/// Converts and validates both ends; reversed ranges are never silently reordered.
pub fn byteRange(text: []const u8, range: Range, encoding: Encoding) Error!ByteRange {
    try validate(text);
    const start = try offsetValidated(text, range.start, encoding);
    const end = try offsetValidated(text, range.end, encoding);
    if (start > end) return error.ReversedRange;
    return .{ .start = start, .end = end };
}
