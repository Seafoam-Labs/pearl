//! Shared presentation for domain-owned rule editors. No matching or storage policy.
const gtk = @import("gtk4");
const w = @import("../ui/components/widgets.zig");
pub const Control = struct { id: []const u8, widget: *gtk.Widget };
pub const Shell = struct { dialog: *gtk.Dialog, scroll: *gtk.ScrolledWindow, body: *gtk.Box };
pub fn style(dialog: *gtk.Dialog, parent: *gtk.Window) void {
    inline for (.{ "pearl-root", "settings-window", "pearl-dark", "pearl-gtk", "pearl-compact", "pearl-reduced-motion" }) |class| {
        if (parent.as(gtk.Widget).hasCssClass(class) != 0) dialog.as(gtk.Widget).addCssClass(class) else dialog.as(gtk.Widget).removeCssClass(class);
    }
}
pub fn open(parent: *gtk.Window, title: [:0]const u8) Shell {
    const dialog = gtk.Dialog.new();
    _ = dialog.ref();
    style(dialog, parent);
    dialog.as(gtk.Window).setTitle(title);
    dialog.as(gtk.Window).setTransientFor(parent);
    dialog.as(gtk.Window).setModal(1);
    dialog.as(gtk.Window).setDefaultSize(@min(600, @max(320, parent.as(gtk.Widget).getWidth() - 32)), @min(740, @max(400, parent.as(gtk.Widget).getHeight() - 40)));
    const scroll = gtk.ScrolledWindow.new();
    scroll.setPolicy(.never, .automatic);
    scroll.as(gtk.Widget).setVexpand(1);
    const body = w.column(8);
    inline for (.{ "setMarginStart", "setMarginEnd", "setMarginTop", "setMarginBottom" }) |method| @field(gtk.Widget, method)(body.as(gtk.Widget), 18);
    scroll.setChild(body.as(gtk.Widget));
    dialog.getContentArea().append(scroll.as(gtk.Widget));
    return .{ .dialog = dialog, .scroll = scroll, .body = body };
}
pub fn card() *gtk.Box {
    const box = w.column(6);
    box.as(gtk.Widget).addCssClass("settings-card");
    return box;
}
pub fn entryRow(host: *gtk.Box, label: [:0]const u8, limit: c_int) *gtk.Entry {
    host.append(w.label(label, "pearl-secondary").as(gtk.Widget));
    const entry = gtk.Entry.new();
    entry.setMaxLength(limit);
    entry.as(gtk.Editable).setWidthChars(12);
    entry.as(gtk.Widget).setHexpand(1);
    w.name(entry.as(gtk.Widget), label);
    host.append(entry.as(gtk.Widget));
    return entry;
}
pub fn choiceRow(host: *gtk.Box, label: [:0]const u8, names: []const ?[*:0]const u8) *gtk.DropDown {
    host.append(w.label(label, "pearl-secondary").as(gtk.Widget));
    const choice = gtk.DropDown.newFromStrings(@ptrCast(names.ptr));
    w.name(choice.as(gtk.Widget), label);
    choice.as(gtk.Widget).setHexpand(1);
    host.append(choice.as(gtk.Widget));
    return choice;
}
