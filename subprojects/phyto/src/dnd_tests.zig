//! Drag-and-drop interoperability checks. These pin the GDK content-format
//! unions that let Phyto exchange files with other applications: the Wayland
//! drag source offers the serializable mime types of its provider, and incoming
//! drops gain the GTypes registered deserializers can produce.
const std = @import("std");
const u = @import("ui.zig");
const gdk = @import("gdk4");

/// GDK registers its built-in content serializers during GTK initialization,
/// so the format checks need a display connection; headless runs skip them.
fn initGtk() bool {
    return u.gtk.initCheck() != 0;
}

test "file drag content serializes to text/uri-list for other applications" {
    if (!initGtk()) return error.SkipZigTest;
    const file = u.gio.File.newForPath("/tmp");
    defer file.unref();
    var files = [_]*u.gio.File{file};
    const list = gdk.FileList.newFromArray(&files, 1);
    var value: u.object.Value = std.mem.zeroes(u.object.Value);
    _ = u.object.Value.init(&value, gdk.FileList.getGObjectType());
    defer value.unset();
    value.setBoxedTakeOwnership(list);
    const provider = gdk.ContentProvider.newForValue(&value);
    defer provider.unref();
    // gdk_wayland_drag_create_data_source offers exactly this union. The union
    // consumes its input (transfer full), so only the result is unref'd.
    const offered = provider.refFormats().unionSerializeMimeTypes();
    defer offered.unref();
    try std.testing.expect(offered.containMimeType("text/uri-list") != 0);
}

test "file drop target accepts text/uri-list from other applications" {
    if (!initGtk()) return error.SkipZigTest;
    const target = u.gtk.DropTarget.new(gdk.FileList.getGObjectType(), .{ .copy = true, .move = true });
    defer target.unref();
    // getFormats is transfer-none; the target owns the formats.
    const target_formats = target.getFormats() orelse return error.NoFormats;
    // gdk_drop_add_formats expands an incoming offer with this union before
    // GtkDropTarget matches it against the target's GTypes. This union also
    // consumes its input.
    var mimes = [_][*:0]const u8{"text/uri-list"};
    const mime_slice: [][*:0]const u8 = &mimes;
    const expanded = gdk.ContentFormats.new(mime_slice.ptr, 1).unionDeserializeGtypes();
    defer expanded.unref();
    try std.testing.expect(expanded.containGtype(gdk.FileList.getGObjectType()) != 0);
    try std.testing.expect(target_formats.containGtype(gdk.FileList.getGObjectType()) != 0);
}
