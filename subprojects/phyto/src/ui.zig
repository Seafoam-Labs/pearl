const std = @import("std");
pub const gtk = @import("gtk4");
pub const gio = @import("gio2");
pub const glib = @import("glib2");
pub const object = @import("gobject2");
pub const a = std.heap.c_allocator;

pub fn box(orientation: gtk.Orientation, spacing: c_int, class: ?[*:0]const u8) *gtk.Box {
    const result = gtk.Box.new(orientation, spacing);
    if (class) |c| result.as(gtk.Widget).addCssClass(c);
    return result;
}
pub fn label(text: [*:0]const u8, class: ?[*:0]const u8) *gtk.Label {
    const result = gtk.Label.new(text);
    result.setXalign(0);
    if (class) |c| result.as(gtk.Widget).addCssClass(c);
    return result;
}
pub fn image(symbol: [*:0]const u8, size: c_int) *gtk.Image {
    const result = gtk.Image.newFromIconName(symbol);
    result.setPixelSize(size);
    return result;
}
pub fn name(widget: *gtk.Widget, text: [*:0]const u8) void {
    widget.as(gtk.Accessible).updateProperty(.label, text, @as(c_int, -1));
}
pub fn iconButton(symbol: [*:0]const u8, tooltip: [*:0]const u8) *gtk.Button {
    const button = gtk.Button.newFromIconName(symbol);
    button.as(gtk.Widget).addCssClass("icon-button");
    button.as(gtk.Widget).setTooltipText(tooltip);
    name(button.as(gtk.Widget), tooltip);
    return button;
}
pub fn clear(container: *gtk.Box) void {
    while (container.as(gtk.Widget).getFirstChild()) |child| container.remove(child);
}
pub fn scroll(child: *gtk.Widget) *gtk.ScrolledWindow {
    const result = gtk.ScrolledWindow.new();
    result.setPolicy(.never, .automatic);
    result.setChild(child);
    result.as(gtk.Widget).setVexpand(1);
    result.as(gtk.Widget).setHexpand(1);
    return result;
}
pub fn format(comptime fmt: []const u8, args: anytype) [:0]u8 {
    return std.fmt.allocPrintSentinel(a, fmt, args, 0) catch @panic("Out of memory");
}
pub fn file(info: *gio.FileInfo) *gio.File {
    return @ptrCast(info.getAttributeObject("standard::file").?);
}
pub fn infoIcon(info: *gio.FileInfo, target: *gtk.Image) void {
    // Symbolic folder artwork follows Pearl; files use their installed MIME icons.
    if (info.getFileType() == .directory) target.setFromIconName("folder-symbolic") else if (info.getSymbolicIcon()) |i| target.setFromGicon(i) else target.setFromIconName("text-x-generic-symbolic");
}
pub fn sizeText(info: *gio.FileInfo) [*:0]u8 {
    return if (info.getFileType() == .directory) glib.strdup("Folder") else glib.formatSize(@intCast(@max(0, info.getSize())));
}
pub fn dateText(info: *gio.FileInfo) [*:0]u8 {
    const date = info.getModificationDateTime() orelse return glib.strdup("—");
    defer date.unref();
    return date.format("%e %b %Y, %H:%M") orelse glib.strdup("—");
}
