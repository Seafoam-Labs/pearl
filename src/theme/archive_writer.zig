//! Native author tooling: reproducible metadata, ordinary files only, exclusive output.
const std = @import("std");
const pkg = @import("package.zig");
const model = @import("package_model.zig");
const c = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});
pub fn pack(a: std.mem.Allocator, package: pkg.Package) ![]const u8 {
    const archive = c.archive_write_new() orelse return error.ThemeArchive;
    defer _ = c.archive_write_free(archive);
    if (c.archive_write_set_format_pax_restricted(archive) != c.ARCHIVE_OK or c.archive_write_add_filter_gzip(archive) != c.ARCHIVE_OK) return error.ThemeArchive;
    if (c.archive_write_set_filter_option(archive, "gzip", "timestamp", null) != c.ARCHIVE_OK) return error.ThemeArchive;
    const output = try a.alloc(u8, model.max_bytes);
    var used: usize = 0;
    if (c.archive_write_open_memory(archive, output.ptr, output.len, &used) != c.ARCHIVE_OK) return error.ThemeArchive;
    for (package.files) |file| {
        const entry = c.archive_entry_new() orelse return error.OutOfMemory;
        defer c.archive_entry_free(entry);
        c.archive_entry_set_pathname(entry, try a.dupeZ(u8, file.path));
        c.archive_entry_set_filetype(entry, 0o100000);
        c.archive_entry_set_perm(entry, 0o644);
        c.archive_entry_set_size(entry, @intCast(file.bytes.len));
        c.archive_entry_set_mtime(entry, 0, 0);
        c.archive_entry_set_uid(entry, 0);
        c.archive_entry_set_gid(entry, 0);
        if (c.archive_write_header(archive, entry) != c.ARCHIVE_OK) return error.ThemeArchive;
        var pos: usize = 0;
        while (pos < file.bytes.len) {
            const written = c.archive_write_data(archive, file.bytes[pos..].ptr, file.bytes.len - pos);
            if (written <= 0) return error.ThemeArchive;
            pos += @intCast(written);
        }
    }
    if (c.archive_write_close(archive) != c.ARCHIVE_OK) return error.ThemeArchiveLimit;
    return output[0..used];
}
