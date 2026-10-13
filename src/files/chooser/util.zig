const std = @import("std");
pub const gtk = @import("gtk4");
pub const gio = @import("gio2");
pub const glib = @import("glib2");
pub const object = @import("gobject2");
pub const a = std.heap.c_allocator;
pub const W = *gtk.Widget;
pub fn cast(comptime T: type, value: anytype) *T {
    const p = if (@typeInfo(@TypeOf(value)) == .optional) value.? else value;
    return @ptrCast(@alignCast(p));
}
pub fn ref(value: anytype) @TypeOf(value) {
    _ = cast(object.Object, value).ref();
    return value;
}
pub fn unref(value: anytype) void {
    if (@typeInfo(@TypeOf(value)) == .optional) {
        if (value) |p| cast(object.Object, p).unref();
    } else cast(object.Object, value).unref();
}
pub fn clear(value: anytype) void {
    unref(value.*);
    value.* = null;
}
pub fn connect(instance: anytype, signal: [*:0]const u8, callback: anytype, context: ?*anyopaque) void {
    _ = object.signalConnectData(cast(object.Object, instance), signal, @ptrCast(callback), context, null, .{});
}
pub fn connectObject(instance: anytype, signal: [*:0]const u8, callback: anytype, owner: anytype) void {
    _ = object.signalConnectObject(cast(object.TypeInstance, instance), signal, @ptrCast(callback), cast(object.Object, owner), .{});
}
pub fn data(comptime T: type, instance: anytype, name: [*:0]const u8) ?*T {
    return if (cast(object.Object, instance).getData(name)) |p| cast(T, p) else null;
}
pub fn setData(instance: anytype, name: [*:0]const u8, value: ?*anyopaque) void {
    cast(object.Object, instance).setData(name, value);
}
pub fn ownedData(instance: anytype, name: [*:0]const u8, value: ?*anyopaque, destroy: ?glib.DestroyNotify) void {
    cast(object.Object, instance).setDataFull(name, value, destroy);
}
pub fn unrefData(p: ?*anyopaque) callconv(.c) void {
    if (p) |v| unref(v);
}
pub fn freeData(p: ?*anyopaque) callconv(.c) void {
    glib.free(p);
}
pub fn eql(left: [*:0]const u8, right: [*:0]const u8) bool {
    return std.mem.eql(u8, std.mem.span(left), std.mem.span(right));
}
pub fn fmt(comptime pattern: []const u8, args: anytype) [:0]u8 {
    return std.fmt.allocPrintSentinel(a, pattern, args, 0) catch @panic("Out of memory");
}
pub fn new(comptime T: type, value: T) *T {
    const p = a.create(T) catch @panic("Out of memory");
    p.* = value;
    return p;
}
pub fn append(box: anytype, child: anytype) void {
    cast(gtk.Box, box).append(cast(gtk.Widget, child));
}
pub fn label(text: [*:0]const u8) W {
    const w = gtk.Label.new(text).as(gtk.Widget);
    cast(gtk.Label, w).setXalign(0);
    cast(gtk.Label, w).setWrap(1);
    return w;
}
pub fn modelItem(comptime T: type, model: anytype, index: c_uint) ?*T {
    return if (cast(gio.ListModel, model).getItem(index)) |p| cast(T, p) else null;
}
pub fn count(model: anytype) c_uint {
    return cast(gio.ListModel, model).getNItems();
}
pub fn listAppend(store: *gio.ListStore, item: anytype) void {
    store.append(cast(object.Object, item));
}
pub fn accessibleLabel(widget: anytype, text: [*:0]const u8) void {
    cast(gtk.Accessible, widget).updateProperty(.label, text, @as(c_int, -1));
}
