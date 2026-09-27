//! A local, installable VSIX; no marketplace or editor process is required.
const std = @import("std");
const c = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});
const Output = @import("application_profiles.zig").Output;
pub fn pack(a: std.mem.Allocator, outputs: []const Output) ![]const u8 {
    const archive = c.archive_write_new() orelse return error.ThemeArchive;
    defer _ = c.archive_write_free(archive);
    if (c.archive_write_set_format_zip(archive) != c.ARCHIVE_OK) return error.ThemeArchive;
    const buffer = try a.alloc(u8, 131072);
    var used: usize = 0;
    if (c.archive_write_open_memory(archive, buffer.ptr, buffer.len, &used) != c.ARCHIVE_OK) return error.ThemeArchive;
    try entry(a, archive, "[Content_Types].xml", "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"json\" ContentType=\"application/json\"/><Default Extension=\"vsixmanifest\" ContentType=\"text/xml\"/></Types>");
    try entry(a, archive, "extension.vsixmanifest", "<?xml version=\"1.0\"?><PackageManifest Version=\"2.0.0\" xmlns=\"http://schemas.microsoft.com/developer/vsx-schema/2011\"><Metadata><Identity Language=\"en-US\" Id=\"pearl-material\" Version=\"1.0.0\" Publisher=\"pearl\"/><DisplayName>Pearl Material</DisplayName><Description xml:space=\"preserve\">Material colors from Pearl</Description><Tags>theme</Tags><Categories>Themes</Categories><Properties><Property Id=\"Microsoft.VisualStudio.Code.Engine\" Value=\"^1.60.0\"/></Properties></Metadata><Installation><InstallationTarget Id=\"Microsoft.VisualStudio.Code\"/></Installation><Dependencies/><Assets><Asset Type=\"Microsoft.VisualStudio.Code.Manifest\" Path=\"extension/package.json\" Addressable=\"true\"/></Assets></PackageManifest>");
    for (outputs) |output| try entry(a, archive, try std.fmt.allocPrint(a, "extension/{s}", .{output.name}), output.bytes);
    try entry(a, archive, "extension/LICENSE", @embedFile("material/pearl.material.vscode/LICENSE"));
    if (c.archive_write_close(archive) != c.ARCHIVE_OK) return error.ThemeArchive;
    return buffer[0..used];
}
fn entry(a: std.mem.Allocator, archive: *c.struct_archive, name: []const u8, bytes: []const u8) !void {
    const e = c.archive_entry_new() orelse return error.OutOfMemory;
    defer c.archive_entry_free(e);
    c.archive_entry_set_pathname(e, try a.dupeZ(u8, name));
    c.archive_entry_set_filetype(e, 0o100000);
    c.archive_entry_set_perm(e, 0o644);
    c.archive_entry_set_size(e, @intCast(bytes.len));
    c.archive_entry_set_mtime(e, 0, 0);
    if (c.archive_write_header(archive, e) != c.ARCHIVE_OK) return error.ThemeArchive;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.archive_write_data(archive, bytes[offset..].ptr, bytes.len - offset);
        if (n <= 0) return error.ThemeArchive;
        offset += @intCast(n);
    }
}
