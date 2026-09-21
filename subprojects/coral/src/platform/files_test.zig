const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
test "GIO etag save detects external writes and failed replacement preserves bytes" {
    const name = u.fmt("/tmp/coral-io-test-{d}.txt", .{c.getpid()});
    defer u.a.free(name);
    defer _ = c.g_unlink(name);
    const file = c.g_file_new_for_path(name).?;
    defer c.g_object_unref(file);
    var old: [*c]u8 = null;
    defer c.g_free(old);
    try std.testing.expect(c.g_file_replace_contents(file, "original", 8, null, 0, 0, &old, null, null) != 0);
    c.g_usleep(2000);
    try std.testing.expect(c.g_file_replace_contents(file, "external change", 15, null, 0, 0, null, null, null) != 0);
    var err: ?*c.GError = null;
    try std.testing.expect(c.g_file_replace_contents(file, "lost", 4, old, 0, 0, null, null, &err) == 0);
    try std.testing.expectEqual(@as(c_int, c.G_IO_ERROR_WRONG_ETAG), err.?.code);
    c.g_error_free(err.?);
    var bytes: [*c]u8 = null;
    var len: usize = 0;
    try std.testing.expect(c.g_file_load_contents(file, null, &bytes, &len, null, null) != 0);
    defer c.g_free(bytes);
    try std.testing.expectEqualStrings("external change", bytes[0..len]);
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    c.g_cancellable_cancel(cancel);
    try std.testing.expect(c.g_file_replace_contents(file, "cancel", 6, null, 0, 0, null, cancel, null) == 0);
}

test "Save As identity resolves a symlinked parent before creating a file" {
    const directory = u.fmt("/tmp/coral-path-real-{d}", .{c.getpid()});
    defer u.a.free(directory);
    const alias = u.fmt("/tmp/coral-path-link-{d}", .{c.getpid()});
    defer u.a.free(alias);
    try std.testing.expect(c.g_mkdir_with_parents(directory, 0o700) == 0);
    defer _ = c.g_rmdir(directory);
    try std.testing.expect(c.symlink(directory, alias) == 0);
    defer _ = c.g_unlink(alias);
    const requested = u.fmt("{s}/new.txt", .{alias});
    defer u.a.free(requested);
    const expected = u.fmt("{s}/new.txt", .{directory});
    defer u.a.free(expected);
    const actual = u.canonicalPath(requested);
    defer u.a.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}
