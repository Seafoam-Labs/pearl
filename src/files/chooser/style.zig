//! Chooser appearance inherits its host and the portal's committed theme.
const u = @import("util.zig");
const gtk = u.gtk;
const object = u.object;
const cast = u.cast;
var native_style = false;
var fallback: ?*gtk.CssProvider = null;
fn parentStyle(parent: *object.Object, _: ?*object.ParamSpec, child: *gtk.Widget) callconv(.c) void {
    for ([_][*:0]const u8{ "pearl-dark", "pearl-gtk", "phyto-root", "dark", "light", "native", "coral" }) |class| {
        if (cast(gtk.Widget, parent).hasCssClass(class) != 0) child.addCssClass(class) else child.removeCssClass(class);
    }
}
fn parentChanged(window: *gtk.Window, _: ?*object.ParamSpec, _: ?*anyopaque) callconv(.c) void {
    if (window.getTransientFor()) |parent| {
        parentStyle(cast(object.Object, parent), null, cast(gtk.Widget, window));
        u.connectObject(parent, "notify::css-classes", &parentStyle, window);
    }
}
pub fn appearance(native: bool) void {
    native_style = native;
    const windows = gtk.Window.getToplevels();
    for (0..windows.getNItems()) |i| {
        const window = u.modelItem(gtk.Widget, windows, @intCast(i)) orelse continue;
        defer u.unref(window);
        if (window.hasCssClass("pearl-root") != 0) {
            if (native) window.removeCssClass("pearl-dark") else window.addCssClass("pearl-dark");
        }
    }
}
pub fn apply(window: *gtk.Window) void {
    if (fallback == null) {
        fallback = gtk.CssProvider.new();
        fallback.?.loadFromString(@embedFile("fallback.css"));
    }
    const widget = cast(gtk.Widget, window);
    const display = widget.getDisplay();
    if (u.data(anyopaque, display, "pearl-file-style") == null) {
        u.setData(display, "pearl-file-style", @ptrFromInt(1));
        gtk.StyleContext.addProviderForDisplay(display, cast(gtk.StyleProvider, fallback.?), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION - 1);
    }
    widget.addCssClass("pearl-root");
    if (!native_style) widget.addCssClass("pearl-dark");
    if (u.data(anyopaque, window, "pearl-file-styled") == null) {
        u.setData(window, "pearl-file-styled", @ptrFromInt(1));
        u.connect(window, "notify::transient-for", &parentChanged, null);
        parentChanged(window, null, null);
    }
}
