//! Compatibility utilities for the extracted preview service; no application UI.
const std = @import("std");
pub const gio = @import("gio2");
pub const glib = @import("glib2");
pub const object = @import("gobject2");
pub const a = std.heap.c_allocator;
pub fn format(comptime fmt: []const u8, args: anytype) [:0]u8 {
    return std.fmt.allocPrintSentinel(a, fmt, args, 0) catch @panic("Out of memory");
}
pub fn file(info: *gio.FileInfo) *gio.File {
    return @ptrCast(info.getAttributeObject("standard::file").?);
}
