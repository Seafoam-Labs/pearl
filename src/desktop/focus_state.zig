//! Stable, non-secret widget identities for reconstructed compact pages.
const std = @import("std");
const gtk = @import("gtk4");
pub const prefix = "settings-focus:";
pub fn tag(widget: *gtk.Widget, comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    widget.setName(std.fmt.bufPrintZ(&buffer, prefix ++ format, args) catch @panic("Focus identity too long"));
}
pub fn find(widget: *gtk.Widget, name: []const u8) ?*gtk.Widget {
    if (widget.getMapped() == 0 or widget.getSensitive() == 0) return null;
    if (std.mem.eql(u8, std.mem.span(widget.getName()), name)) return widget;
    var child = widget.getFirstChild();
    while (child) |item| : (child = item.getNextSibling()) if (find(item, name)) |found| return found;
    return null;
}
