//! Constructors return floating GTK widgets. The receiving parent owns them.
const gtk = @import("gtk4");
const gobject = @import("gobject2");

pub fn label(text: [*:0]const u8, class: ?[*:0]const u8) *gtk.Label {
    const result = gtk.Label.new(text);
    result.setXalign(0);
    result.setWrap(1);
    result.setWrapMode(.word_char);
    result.as(gtk.Widget).setHexpand(1);
    if (class) |css_class| result.as(gtk.Widget).addCssClass(css_class);
    return result;
}
pub fn column(spacing: c_int) *gtk.Box {
    return gtk.Box.new(.vertical, spacing);
}
pub fn row(spacing: c_int) *gtk.Box {
    return gtk.Box.new(.horizontal, spacing);
}
pub fn name(widget: *gtk.Widget, text: [*:0]const u8) void {
    widget.as(gtk.Accessible).updateProperty(.label, text, @as(c_int, -1));
}
pub fn icon(symbol: [*:0]const u8) *gtk.Image {
    const image = gtk.Image.newFromIconName(symbol);
    image.setPixelSize(20);
    return image;
}
pub fn iconButton(symbol: [*:0]const u8, tooltip: [*:0]const u8) *gtk.Button {
    const button = gtk.Button.new();
    button.setChild(icon(symbol).as(gtk.Widget));
    button.as(gtk.Widget).addCssClass("pearl-icon");
    button.as(gtk.Widget).setTooltipText(tooltip);
    name(button.as(gtk.Widget), tooltip);
    return button;
}
pub fn card() *gtk.Box {
    const box = column(16);
    box.as(gtk.Widget).addCssClass("pearl-card");
    box.as(gtk.Widget).setHexpand(1);
    box.as(gtk.Widget).setValign(.start);
    return box;
}
pub fn flow(maximum: c_uint) *gtk.FlowBox {
    const box = gtk.FlowBox.new();
    box.setSelectionMode(.none);
    box.setMinChildrenPerLine(1);
    box.setMaxChildrenPerLine(maximum);
    box.setColumnSpacing(12);
    box.setRowSpacing(12);
    box.setHomogeneous(1);
    return box;
}
pub fn section(title: *gtk.Label, detail: ?*gtk.Label, trailing: *gtk.Widget) *gtk.Box {
    const box = row(16);
    box.as(gtk.Widget).addCssClass("pearl-row");
    const labels = column(4);
    labels.as(gtk.Widget).setHexpand(1);
    labels.append(title.as(gtk.Widget));
    if (detail) |subtitle| labels.append(subtitle.as(gtk.Widget));
    trailing.setValign(.center);
    box.append(labels.as(gtk.Widget));
    box.append(trailing);
    return box;
}
pub const Tile = struct { button: *gtk.ToggleButton, subtitle: *gtk.Label };
pub fn tile(symbol: [*:0]const u8, title: *gtk.Label, subtitle: *gtk.Label, active: bool) Tile {
    const button = gtk.ToggleButton.new();
    const box = row(12);
    const labels = column(3);
    labels.append(title.as(gtk.Widget));
    labels.append(subtitle.as(gtk.Widget));
    box.append(icon(symbol).as(gtk.Widget));
    box.append(labels.as(gtk.Widget));
    button.as(gtk.Button).setChild(box.as(gtk.Widget));
    button.setActive(@intFromBool(active));
    button.as(gtk.Widget).addCssClass("pearl-tile");
    return .{ .button = button, .subtitle = subtitle };
}
pub fn pill(text: [*:0]const u8, active: bool) *gtk.ToggleButton {
    const button = gtk.ToggleButton.newWithLabel(text);
    button.setActive(@intFromBool(active));
    button.as(gtk.Widget).addCssClass("pearl-pill");
    return button;
}
pub fn slider(title: *gtk.Label, symbol: [*:0]const u8, value: f64) struct { box: *gtk.Box, scale: *gtk.Scale } {
    const box = column(4);
    box.append(title.as(gtk.Widget));
    const line = row(12);
    line.append(icon(symbol).as(gtk.Widget));
    const scale = gtk.Scale.newWithRange(.horizontal, 0, 100, 1);
    scale.setDrawValue(0);
    scale.as(gtk.Range).setValue(value);
    scale.as(gtk.Widget).setHexpand(1);
    name(scale.as(gtk.Widget), title.getText());
    line.append(scale.as(gtk.Widget));
    box.append(line.as(gtk.Widget));
    return .{ .box = box, .scale = scale };
}
pub const Status = enum { empty, failure, pending };
pub fn status(kind: Status, title: *gtk.Label, detail: *gtk.Label) *gtk.Box {
    const box = row(12);
    box.as(gtk.Widget).addCssClass("pearl-state");
    if (kind == .failure) box.as(gtk.Widget).addCssClass("pearl-error");
    // Pending is deliberately static: it communicates state without an idle spinner.
    const image = icon(switch (kind) {
        .empty => "pearl-emblem-ok-symbolic",
        .failure => "pearl-dialog-warning-symbolic",
        .pending => "pearl-content-loading-symbolic",
    });
    image.as(gtk.Widget).addCssClass("pearl-state-icon");
    const labels = column(4);
    labels.append(title.as(gtk.Widget));
    labels.append(detail.as(gtk.Widget));
    box.append(image.as(gtk.Widget));
    box.append(labels.as(gtk.Widget));
    return box;
}

pub fn listSetup(_: *gtk.SignalListItemFactory, object: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
    const item = gobject.ext.cast(gtk.ListItem, object).?;
    const box = row(12);
    box.as(gtk.Widget).addCssClass("pearl-list-row");
    box.append(icon("pearl-application-x-executable-symbolic").as(gtk.Widget));
    box.append(label("", null).as(gtk.Widget));
    item.setChild(box.as(gtk.Widget));
}
pub fn listBind(_: *gtk.SignalListItemFactory, object: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
    const item = gobject.ext.cast(gtk.ListItem, object).?;
    const string = gobject.ext.cast(gtk.StringObject, item.getItem().?).?;
    const text = gobject.ext.cast(gtk.Label, item.getChild().?.getLastChild().?).?;
    text.setText(string.getString());
    item.setAccessibleLabel(string.getString());
}
