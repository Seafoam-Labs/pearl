//! Document text extraction. Plain text is read natively with strict bounds;
//! PDFs go through a sandboxed pdftotext child (Poppler), the same integration
//! boundary the preview helper already uses for pdftoppm. Scanned PDFs without
//! a text layer yield no passages and are counted, never OCR'd.
const std = @import("std");
const sandbox = @import("sandbox.zig");
pub const max_file = 20 * 1024 * 1024;
pub const max_output = 8 * 1024 * 1024;
pub const pdf_timeout_ms = 30_000;
pub const Kind = enum { text, pdf, unsupported };
pub fn kind(path: []const u8) Kind {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return .pdf;
    for ([_][]const u8{ ".txt", ".text", ".md", ".markdown", ".rst" }) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return .text;
    }
    return .unsupported;
}
pub fn title(path: []const u8) []const u8 {
    const stem = std.fs.path.stem(path);
    return if (stem.len > 0) stem else "none";
}
pub fn text(a: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c_uint, 0));
    if (fd < 0) return error.DocumentUnavailable;
    defer _ = std.c.close(fd);
    var st: std.os.linux.Statx = undefined;
    if (std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true }, &st) != 0 or st.mode & std.c.S.IFMT != std.c.S.IFREG) return error.DocumentUnavailable;
    if (st.size > max_file) return error.DocumentTooLarge;
    const buffer = try a.alloc(u8, @intCast(st.size));
    errdefer a.free(buffer);
    var done: usize = 0;
    while (done < buffer.len) {
        const n = std.c.read(fd, buffer[done..].ptr, buffer.len - done);
        if (n < 0) return error.DocumentReadFailed;
        if (n == 0) break;
        done += @intCast(n);
    }
    const bytes = buffer[0..done];
    if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.DocumentNotText;
    return bytes;
}
pub fn pdf(a: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c_uint, 0));
    if (fd < 0) return error.DocumentUnavailable;
    defer _ = std.c.close(fd);
    var st: std.os.linux.Statx = undefined;
    if (std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true }, &st) != 0 or st.mode & std.c.S.IFMT != std.c.S.IFREG) return error.DocumentUnavailable;
    if (st.size > max_file) return error.DocumentTooLarge;
    const result = sandbox.run("/usr/bin/pdftotext", &.{ "-enc", "UTF-8", "-nopgbrk", "/input/source", "-" }, fd, pdf_timeout_ms, max_output);
    defer result.deinit();
    switch (result.status) {
        .ok => {},
        .sandbox => return error.SandboxUnavailable,
        .timeout => return error.ExtractionTimeout,
        .limits => return error.ExtractionTooLarge,
        .failed => return error.ExtractionFailed,
    }
    if (!std.unicode.utf8ValidateSlice(result.bytes) or std.mem.indexOfScalar(u8, result.bytes, 0) != null) return error.DocumentNotText;
    return try a.dupe(u8, result.bytes);
}
pub fn pdfAvailable() bool {
    return std.c.access("/usr/bin/bwrap", std.c.X_OK) == 0 and std.c.access("/usr/bin/pdftotext", std.c.X_OK) == 0;
}
test "document kinds and titles are explicit" {
    try std.testing.expectEqual(Kind.pdf, kind("/docs/lease.PDF"));
    try std.testing.expectEqual(Kind.text, kind("/docs/notes.md"));
    try std.testing.expectEqual(Kind.text, kind("/docs/readme.TXT"));
    try std.testing.expectEqual(Kind.unsupported, kind("/docs/photo.png"));
    try std.testing.expectEqual(Kind.unsupported, kind("/docs/archive.pdf.exe"));
    try std.testing.expectEqualStrings("lease", title("/docs/lease.pdf"));
    try std.testing.expectEqualStrings("none", title("/"));
}
test "text extraction enforces size, UTF-8 and regular-file bounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ok.txt", .data = "A clause about pets." });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "binary.txt", .data = "abc\x00def" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "invalid.txt", .data = "abc\xffdef" });
    var dir_buffer: [512]u8 = undefined;
    const dir = try std.mem.printSentinel(&dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    var path_buffer: [4096]u8 = undefined;
    const ok = try std.mem.printSentinel(&path_buffer, "{s}/ok.txt", .{dir}, 0);
    const bytes = try text(std.testing.allocator, ok);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("A clause about pets.", bytes);
    const binary = try std.mem.printSentinel(&path_buffer, "{s}/binary.txt", .{dir}, 0);
    try std.testing.expectError(error.DocumentNotText, text(std.testing.allocator, binary));
    const invalid = try std.mem.printSentinel(&path_buffer, "{s}/invalid.txt", .{dir}, 0);
    try std.testing.expectError(error.DocumentNotText, text(std.testing.allocator, invalid));
    const missing = try std.mem.printSentinel(&path_buffer, "{s}/missing.txt", .{dir}, 0);
    try std.testing.expectError(error.DocumentUnavailable, text(std.testing.allocator, missing));
}
