//! Classifies a GLib file `GError` into a closed, path-free category for the
//! journal. The message is never carried out: GLib file errors routinely embed
//! the filename or a provider string, so only the domain's registered name and
//! the numeric code are safe to log. Pure; the call site owns the log scope and
//! the redaction of the domain name.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;

pub const Category = struct {
    /// The GError domain's registered quark name (a fixed GLib string such as
    /// `g-io-error-quark`), or `"?"` when the quark carries no name.
    domain: []const u8,
    code: c_int,
};

/// `null` means the operation was cancelled, which is how a dismissed file
/// dialog or an aborted transfer arrives (`G_IO_ERROR_CANCELLED`). Cancellation
/// is a user action, not a failure, and must not write an error line.
pub fn classify(err: ?*c.GError) ?Category {
    const e = err orelse return null;
    if (e.domain == c.g_io_error_quark() and e.code == c.G_IO_ERROR_CANCELLED) return null;
    const domain = if (c.g_quark_to_string(e.domain)) |name| std.mem.span(name) else "?";
    return .{ .domain = domain, .code = e.code };
}

test "cancellation is classified away from failure" {
    const e = c.g_error_new_literal(c.g_io_error_quark(), c.G_IO_ERROR_CANCELLED, "Operation was cancelled");
    defer c.g_error_free(e);
    try std.testing.expect(classify(e) == null);
    // A null error is likewise not a failure.
    try std.testing.expect(classify(null) == null);
}

test "a real error yields the domain and code, never the message or a path" {
    const e = c.g_error_new_literal(c.g_io_error_quark(), c.G_IO_ERROR_NOT_FOUND, "No such file /home/user/secret.txt");
    defer c.g_error_free(e);
    const cat = classify(e) orelse return error.ExpectedCategory;
    try std.testing.expectEqual(@as(c_int, c.G_IO_ERROR_NOT_FOUND), cat.code);
    // The quark name is a fixed GLib string; the message and its path are not.
    try std.testing.expect(cat.domain.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, cat.domain, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, cat.domain, "/") == null);
    try std.testing.expect(std.mem.indexOf(u8, cat.domain, "No such file") == null);
}
