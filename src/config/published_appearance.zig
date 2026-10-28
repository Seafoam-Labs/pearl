//! The shell's resolved palette, published for the lock's first frame.
//!
//! The lock is a separate process and used to re-derive its theme from scratch,
//! which flashed stock colors until its own theme job landed. The shell writes
//! the palette it is actually showing on every successful apply; the lock reads
//! it synchronously at startup so its first painted frame already matches.
const std = @import("std");
const glib = @import("glib2");
const io = @import("io.zig");
const theme = @import("../theme/theme.zig");
const a = std.heap.c_allocator;
const Document = struct { version: u8, palette: theme.Palette };

pub fn path(alloc: std.mem.Allocator) ![:0]u8 {
    return std.fmt.allocPrintSentinel(alloc, "{s}/pearl/appearance.json", .{std.mem.span(glib.getUserRuntimeDir())}, 0);
}

/// Best-effort: a missing or unwritable publication only costs the lock its
/// instant first frame, never the lock itself.
pub fn write(palette: theme.Palette) void {
    const pz = path(a) catch return;
    defer a.free(pz);
    const dir = std.fs.path.dirname(pz) orelse return;
    const dir_z = a.dupeSentinel(u8, dir, 0) catch return;
    defer a.free(dir_z);
    io.mkdir(dir_z) catch return;
    const json = std.json.Stringify.valueAlloc(a, .{ .version = 1, .palette = palette }, .{}) catch return;
    defer a.free(json);
    io.atomic(pz, json, false) catch {};
}

pub fn read(alloc: std.mem.Allocator) !theme.Palette {
    const pz = try path(alloc);
    defer alloc.free(pz);
    const disk = try io.read(alloc, pz, 65536, null);
    // The parsed palette's strings alias this buffer for the life of the
    // process; freeing it here would hand the caller dangling hex values.
    try @import("preferences.zig").boundedJson(disk.bytes, 65536, 4);
    const doc = try std.json.parseFromSliceLeaky(Document, alloc, disk.bytes, .{});
    if (doc.version != 1) return error.InvalidAppearance;
    try theme.validate(doc.palette);
    return doc.palette;
}
