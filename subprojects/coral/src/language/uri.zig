//! Local POSIX file URIs, without filesystem lookup or shell interpretation.
//! Paths must be absolute UTF-8 without NUL or backslash. Normalization is purely
//! lexical: collapse repeated '/', remove '.', resolve '..', reject escape above
//! root, and drop trailing '/' except root. This is NOT symlink resolution or a
//! sandbox check; callers must authorize the resulting filesystem operation.
//! Decode accepts file:/path, file:///path, and file://localhost/path (scheme and
//! localhost case-insensitive). Other hosts, query/fragment, raw non-ASCII URI
//! bytes, malformed escapes, and percent-encoded '/' or '\\' are rejected.
//! Encoded dot segments are normalized after decoding. Encoded '?'/'#' are valid
//! filename characters. Encode emits file:/// plus unreserved ASCII and '/' only.
//! Returned slices are owned by the caller with the supplied allocator.
const std = @import("std");
const Allocator = std.mem.Allocator;

fn unreserved(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~';
}

fn pathCharacter(ch: u8) bool {
    return unreserved(ch) or ch == '/' or std.mem.indexOfScalar(u8, "!$&'()*+,;=:@", ch) != null;
}

fn normalize(allocator: Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] != '/') return error.NotAbsolute;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.EmbeddedNul;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidPath;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidUtf8;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.append(allocator, '/');
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (out.items.len == 1) return error.PathEscapesRoot;
            const slash = std.mem.lastIndexOfScalar(u8, out.items, '/').?;
            out.shrinkRetainingCapacity(@max(slash, 1));
        } else {
            if (out.items.len > 1) try out.append(allocator, '/');
            try out.appendSlice(allocator, segment);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn fromPath(allocator: Allocator, absolute: []const u8) ![]u8 {
    const path = try normalize(allocator, absolute);
    defer allocator.free(path);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "file://");
    const hex = "0123456789ABCDEF";
    for (path) |ch| {
        if (unreserved(ch) or ch == '/') {
            try out.append(allocator, ch);
        } else {
            try out.appendSlice(allocator, &.{ '%', hex[ch >> 4], hex[ch & 15] });
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn toPath(allocator: Allocator, uri: []const u8) ![]u8 {
    if (uri.len < 5 or !std.ascii.eqlIgnoreCase(uri[0..5], "file:")) return error.InvalidScheme;
    var path = uri[5..];
    if (std.mem.startsWith(u8, path, "//")) {
        const slash = std.mem.indexOfScalarPos(u8, path, 2, '/') orelse return error.NotAbsolute;
        const host = path[2..slash];
        if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return error.RemoteHost;
        path = path[slash..];
    }
    if (path.len == 0 or path[0] != '/') return error.NotAbsolute;
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(allocator);
    var i: usize = 0;
    while (i < path.len) {
        const ch = path[i];
        if (ch == '%') {
            if (path.len - i < 3) return error.InvalidEscape;
            const hi = std.fmt.charToDigit(path[i + 1], 16) catch return error.InvalidEscape;
            const lo = std.fmt.charToDigit(path[i + 2], 16) catch return error.InvalidEscape;
            const byte = hi * 16 + lo;
            if (byte == '/' or byte == '\\') return error.EncodedSeparator;
            if (byte == 0) return error.EmbeddedNul;
            try decoded.append(allocator, byte);
            i += 3;
        } else {
            if (ch == 0) return error.EmbeddedNul;
            if (!pathCharacter(ch)) return error.InvalidUri;
            try decoded.append(allocator, ch);
            i += 1;
        }
    }
    return normalize(allocator, decoded.items);
}
