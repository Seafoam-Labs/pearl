//! Existing-file boundary for command-line opens (not Save As).
//!
//! This does metadata-only resolution: it never creates a file/directory or
//! opens target contents, including FIFOs. It is not a symlink-security sandbox
//! or a promise that a later async load sees the same inode/type. The loader
//! must acquire a descriptor without blindly blocking on a FIFO (on POSIX,
//! O_NONBLOCK without O_CREAT), fstat that descriptor, and reject non-regular
//! files before reading. A separate path check followed by a blocking open is
//! still racy. Hard links are not deduplicated; symlink/path aliases are.
//!
//! App.openExisting should consume this owned path; new documents and explicit
//! Save As remain the creation workflow. Do not use c.zig's canonicalPath here:
//! its intentional missing-target fallback is appropriate only for Save As.
const std = @import("std");
const c = @import("../c.zig").c;

/// Bounds input/decoded/canonical byte strings, not file contents. The native
/// filesystem can impose a smaller path/component limit (also PathTooLong).
pub const max_target_bytes = 64 * 1024;

/// Closed, path-free categories; no GLib message (which may contain a path)
/// escapes this boundary. PermissionDenied is a metadata/resolution failure;
/// success does not establish that the eventual content read is permitted.
pub const Error = error{
    EmptyTarget,
    EmbeddedNul,
    InvalidUtf8,
    InvalidUri,
    NonLocalUri,
    PathTooLong,
    NotFound,
    NotDirectory,
    IsDirectory,
    NotRegularFile,
    PermissionDenied,
    SymlinkLoop,
    OutOfMemory,
    Io,
};

/// Accept a local filename (relative to cwd) or an absolute file: URI. A URI
/// authority must be empty or localhost; no remote provider/DNS is consulted.
/// Prefix a filename containing a URI-like scheme with ./ to make it literal.
/// Query/fragment syntax is rejected; encode literal ?/# in a file URI.
/// Returns a canonical, absolute, sentinel-terminated path owned by allocator.
/// Missing files, missing parents and dangling symlinks always fail.
pub fn resolveExisting(allocator: std.mem.Allocator, requested: []const u8) Error![:0]u8 {
    try validatePath(requested);
    const input = try allocator.dupeSentinel(u8, requested, 0);
    defer allocator.free(input);

    var decoded: [*c]u8 = null;
    defer c.g_free(decoded);
    var native: [:0]const u8 = input;
    if (c.g_uri_peek_scheme(input)) |scheme| {
        if (!std.ascii.eqlIgnoreCase(std.mem.span(scheme), "file")) return error.NonLocalUri;
        if (std.mem.indexOfAny(u8, requested, "?#") != null) return error.InvalidUri;
        var host: [*c]u8 = null;
        defer c.g_free(host);
        var uri_error: ?*c.GError = null;
        defer if (uri_error) |e| c.g_error_free(e);
        decoded = c.g_filename_from_uri(input, &host, &uri_error);
        if (decoded == null) return error.InvalidUri;
        if (host != null and host[0] != 0 and !std.ascii.eqlIgnoreCase(std.mem.span(host), "localhost")) return error.NonLocalUri;
        native = std.mem.span(decoded);
        try validatePath(native);
    }

    // Resolve BEFORE constructing a GFile: lexical normalization of /link/..
    // could otherwise erase the actual symlink traversal. Unlike canonicalPath,
    // realpath has no fallback that invents an identity for a missing target.
    const real = c.realpath(native.ptr, null);
    if (real == null) return fromErrno(std.c.errno(@as(c_int, -1)));
    defer c.free(real);
    const path = std.mem.span(real);
    try validatePath(path);

    const file = c.g_file_new_for_path(real) orelse return error.OutOfMemory;
    defer c.g_object_unref(file);
    var io_error: ?*c.GError = null;
    defer if (io_error) |e| c.g_error_free(e);
    // No content open. NOFOLLOW also rejects a last-component symlink swapped
    // in after realpath, but cannot protect a later load or ancestor traversal.
    const info = c.g_file_query_info(file, "standard::type", c.G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, null, &io_error) orelse return fromGio(io_error);
    defer c.g_object_unref(info);
    switch (c.g_file_info_get_file_type(info)) {
        c.G_FILE_TYPE_REGULAR => {},
        c.G_FILE_TYPE_DIRECTORY => return error.IsDirectory,
        else => return error.NotRegularFile,
    }
    return allocator.dupeSentinel(u8, path, 0);
}

fn validatePath(path: []const u8) Error!void {
    if (path.len == 0) return error.EmptyTarget;
    if (path.len > max_target_bytes) return error.PathTooLong;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.EmbeddedNul;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidUtf8;
}

fn fromErrno(e: std.c.E) Error {
    return switch (e) {
        .NOENT => error.NotFound,
        .NOTDIR => error.NotDirectory,
        .ACCES, .PERM => error.PermissionDenied,
        .LOOP => error.SymlinkLoop,
        .NAMETOOLONG => error.PathTooLong,
        .NOMEM => error.OutOfMemory,
        else => error.Io,
    };
}

fn fromGio(err: ?*c.GError) Error {
    const e = err orelse return error.Io;
    if (e.domain != c.g_io_error_quark()) return error.Io;
    return switch (e.code) {
        c.G_IO_ERROR_NOT_FOUND => error.NotFound,
        c.G_IO_ERROR_NOT_DIRECTORY => error.NotDirectory,
        c.G_IO_ERROR_IS_DIRECTORY => error.IsDirectory,
        c.G_IO_ERROR_PERMISSION_DENIED => error.PermissionDenied,
        c.G_IO_ERROR_TOO_MANY_LINKS => error.SymlinkLoop,
        c.G_IO_ERROR_FILENAME_TOO_LONG => error.PathTooLong,
        c.G_IO_ERROR_INVALID_FILENAME => error.InvalidUri,
        else => error.Io,
    };
}

const a = std.testing.allocator;
const Fixture = struct {
    directory: [*:0]u8,

    fn init() !Fixture {
        return .{ .directory = c.g_dir_make_tmp("coral-open-target-XXXXXX", null) orelse return error.TempDirectory };
    }

    fn deinit(self: Fixture) void {
        std.debug.assert(c.g_rmdir(self.directory) == 0);
        c.g_free(self.directory);
    }

    fn path(self: Fixture, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ std.mem.span(self.directory), name }, 0);
    }
};

fn expectSame(expected: []const u8, requested: []const u8) !void {
    const actual = try resolveExisting(a, requested);
    defer a.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqual(@as(u8, 0), actual[actual.len]);
}

test "existing absolute/relative filenames and escaped local file URIs share identity" {
    const f = try Fixture.init();
    defer f.deinit();
    const path = try f.path("space % # ? café.txt");
    defer a.free(path);
    try std.testing.expect(c.g_file_set_contents(path, "original", 8, null) != 0);
    defer _ = c.g_unlink(path);
    const canonical = c.realpath(path, null).?;
    defer c.free(canonical);
    try expectSame(std.mem.span(canonical), path);

    const cwd = c.g_get_current_dir();
    defer c.g_free(cwd);
    const relative = try std.fs.path.relativeAlloc(a, std.mem.span(cwd), null, std.mem.span(cwd), path);
    defer a.free(relative);
    try expectSame(std.mem.span(canonical), relative);
    const uri = c.g_filename_to_uri(path, null, null).?;
    defer c.g_free(uri);
    try expectSame(std.mem.span(canonical), std.mem.span(uri));
    const localhost = c.g_filename_to_uri(path, "localhost", null).?;
    defer c.g_free(localhost);
    try expectSame(std.mem.span(canonical), std.mem.span(localhost));
    const uppercase_uri = try a.dupe(u8, std.mem.span(localhost));
    defer a.free(uppercase_uri);
    @memcpy(uppercase_uri[0..4], "FILE");
    try expectSame(std.mem.span(canonical), uppercase_uri);

    // Input is borrowed; the returned sentinel buffer has independent ownership.
    const input = try a.dupe(u8, path);
    defer a.free(input);
    const owned = try resolveExisting(a, input);
    defer a.free(owned);
    @memset(input, 'x');
    try std.testing.expectEqualStrings(std.mem.span(canonical), owned);
    var bytes: [*c]u8 = null;
    var len: usize = 0;
    try std.testing.expect(c.g_file_get_contents(path, &bytes, &len, null) != 0);
    defer c.g_free(bytes);
    try std.testing.expectEqualStrings("original", bytes[0..len]);
}

test "symlink target and parent aliases deduplicate with physical dot-dot semantics" {
    const f = try Fixture.init();
    defer f.deinit();
    const directory = try f.path("real");
    defer a.free(directory);
    try std.testing.expect(c.g_mkdir(directory, 0o700) == 0);
    defer _ = c.g_rmdir(directory);
    const nested = try f.path("real/nested");
    defer a.free(nested);
    try std.testing.expect(c.g_mkdir(nested, 0o700) == 0);
    defer _ = c.g_rmdir(nested);
    const path = try f.path("real/file");
    defer a.free(path);
    try std.testing.expect(c.g_file_set_contents(path, "", 0, null) != 0);
    defer _ = c.g_unlink(path);
    const alias = try f.path("alias");
    defer a.free(alias);
    try std.testing.expect(c.symlink("real/file", alias) == 0);
    defer _ = c.g_unlink(alias);
    const parent = try f.path("parent");
    defer a.free(parent);
    try std.testing.expect(c.symlink("real", parent) == 0);
    defer _ = c.g_unlink(parent);
    const parent_path = try f.path("parent/./file");
    defer a.free(parent_path);
    const nested_alias = try f.path("nested-alias");
    defer a.free(nested_alias);
    try std.testing.expect(c.symlink("real/nested", nested_alias) == 0);
    defer _ = c.g_unlink(nested_alias);
    const physical = try f.path("nested-alias/../file");
    defer a.free(physical);
    const canonical = c.realpath(path, null).?;
    defer c.free(canonical);
    for ([_][]const u8{ path, alias, parent_path, physical }) |request| try expectSame(std.mem.span(canonical), request);
}

test "missing targets and dangling links never create files or parents" {
    const f = try Fixture.init();
    defer f.deinit();
    const missing = try f.path("absent/nested/file");
    defer a.free(missing);
    const parent = try f.path("absent");
    defer a.free(parent);
    try std.testing.expectError(error.NotFound, resolveExisting(a, missing));
    const uri = c.g_filename_to_uri(missing, null, null).?;
    defer c.g_free(uri);
    try std.testing.expectError(error.NotFound, resolveExisting(a, std.mem.span(uri)));
    try std.testing.expect(c.g_file_test(parent, c.G_FILE_TEST_EXISTS) == 0);
    const leaf = try f.path("missing");
    defer a.free(leaf);
    try std.testing.expectError(error.NotFound, resolveExisting(a, leaf));
    try std.testing.expect(c.g_file_test(leaf, c.G_FILE_TEST_EXISTS) == 0);
    const dangling = try f.path("dangling");
    defer a.free(dangling);
    try std.testing.expect(c.symlink("absent/nested/file", dangling) == 0);
    defer _ = c.g_unlink(dangling);
    try std.testing.expectError(error.NotFound, resolveExisting(a, dangling));
    try std.testing.expect(c.g_file_test(parent, c.G_FILE_TEST_EXISTS) == 0);
    const loop = try f.path("loop");
    defer a.free(loop);
    try std.testing.expect(c.symlink("loop", loop) == 0);
    defer _ = c.g_unlink(loop);
    try std.testing.expectError(error.SymlinkLoop, resolveExisting(a, loop));
}

test "directories, non-directory parents and FIFOs are rejected without opening contents" {
    const f = try Fixture.init();
    defer f.deinit();
    try std.testing.expectError(error.IsDirectory, resolveExisting(a, std.mem.span(f.directory)));
    const directory_alias = try f.path("directory-alias");
    defer a.free(directory_alias);
    try std.testing.expect(c.symlink(".", directory_alias) == 0);
    defer _ = c.g_unlink(directory_alias);
    try std.testing.expectError(error.IsDirectory, resolveExisting(a, directory_alias));
    const path = try f.path("file");
    defer a.free(path);
    try std.testing.expect(c.g_file_set_contents(path, "", 0, null) != 0);
    defer _ = c.g_unlink(path);
    const child = try f.path("file/child");
    defer a.free(child);
    try std.testing.expectError(error.NotDirectory, resolveExisting(a, child));
    const fifo = try f.path("fifo");
    defer a.free(fifo);
    try std.testing.expect(c.mkfifo(fifo, 0o600) == 0);
    defer _ = c.g_unlink(fifo);
    // No writer exists: a blind blocking content open would hang this test.
    try std.testing.expectError(error.NotRegularFile, resolveExisting(a, fifo));
    const alias = try f.path("fifo-alias");
    defer a.free(alias);
    try std.testing.expect(c.symlink("fifo", alias) == 0);
    defer _ = c.g_unlink(alias);
    try std.testing.expectError(error.NotRegularFile, resolveExisting(a, alias));
}

test "invalid input, remote URIs and unreasonable lengths fail closed" {
    try std.testing.expectError(error.EmptyTarget, resolveExisting(a, ""));
    try std.testing.expectError(error.EmbeddedNul, resolveExisting(a, "file\x00ignored"));
    try std.testing.expectError(error.InvalidUtf8, resolveExisting(a, "\xff"));
    try std.testing.expectError(error.InvalidUtf8, resolveExisting(a, "file:///tmp/%FF"));
    for ([_][]const u8{ "https://example.invalid/file", "sftp://localhost/file", "resource:///file", "file://example.invalid/tmp/file" }) |uri| {
        try std.testing.expectError(error.NonLocalUri, resolveExisting(a, uri));
    }
    for ([_][]const u8{ "file:relative", "file:///tmp/%00ignored", "file:///tmp/%GG", "file:///tmp/%", "file:///tmp/file?query", "file:///tmp/file#fragment" }) |uri| {
        try std.testing.expectError(error.InvalidUri, resolveExisting(a, uri));
    }
    const oversized = try a.alloc(u8, max_target_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.PathTooLong, resolveExisting(a, oversized));
}

test "valid UTF-8 symlink name cannot return an invalid UTF-8 canonical identity" {
    const f = try Fixture.init();
    defer f.deinit();
    const path = try f.path("\xff");
    defer a.free(path);
    try std.testing.expect(c.g_file_set_contents(path, "", 0, null) != 0);
    defer _ = c.g_unlink(path);
    const alias = try f.path("valid-alias");
    defer a.free(alias);
    try std.testing.expect(c.symlink("\xff", alias) == 0);
    defer _ = c.g_unlink(alias);
    try std.testing.expectError(error.InvalidUtf8, resolveExisting(a, alias));
}

fn resolveForAllocationTest(allocator: std.mem.Allocator, requested: []const u8) !void {
    const path = try resolveExisting(allocator, requested);
    defer allocator.free(path);
}

test "caller allocation failures propagate and release temporary resources" {
    const f = try Fixture.init();
    defer f.deinit();
    const path = try f.path("file");
    defer a.free(path);
    try std.testing.expect(c.g_file_set_contents(path, "", 0, null) != 0);
    defer _ = c.g_unlink(path);
    try std.testing.checkAllAllocationFailures(a, resolveForAllocationTest, .{path});
    const uri = c.g_filename_to_uri(path, null, null).?;
    defer c.g_free(uri);
    try std.testing.checkAllAllocationFailures(a, resolveForAllocationTest, .{std.mem.span(uri)});
}

test "resolution error mapping stays closed and preserves useful categories" {
    try std.testing.expectEqual(error.PermissionDenied, fromErrno(.ACCES));
    try std.testing.expectEqual(error.PermissionDenied, fromErrno(.PERM));
    try std.testing.expectEqual(error.OutOfMemory, fromErrno(.NOMEM));
    try std.testing.expectEqual(error.PathTooLong, fromErrno(.NAMETOOLONG));
    try std.testing.expectEqual(error.Io, fromErrno(.IO));
    try std.testing.expectEqual(error.Io, fromGio(null));
    const err = c.g_error_new_literal(c.g_io_error_quark(), c.G_IO_ERROR_PERMISSION_DENIED, "private path");
    defer c.g_error_free(err);
    try std.testing.expectEqual(error.PermissionDenied, fromGio(err));
}
