//! A draft-only schematic. No service calls or preference writes.
const std = @import("std");
const gtk = @import("gtk4");
const prefs = @import("../config/preferences.zig");
const theme = @import("../theme/theme.zig");
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;

pub const View = struct {
    root: *gtk.Overlay,
    picture: *gtk.Picture,
    bar: *gtk.Box,
    dock: *gtk.Box,
    status: *gtk.Label,
    caption: *gtk.Box,
    provider: *gtk.CssProvider,
    signature: ?[64]u8 = null,

    pub fn create(host: *gtk.Box) !*View {
        const self = try a.create(View);
        const root = gtk.Overlay.new();
        root.as(gtk.Widget).addCssClass("appearance-desktop-preview");
        root.as(gtk.Widget).setSizeRequest(200, 150);
        root.as(gtk.Widget).setOverflow(.hidden);
        const picture = gtk.Picture.new();
        picture.setCanShrink(1);
        picture.setContentFit(.cover);
        picture.as(gtk.Widget).addCssClass("settings-draft-preview");
        root.setChild(picture.as(gtk.Widget));
        const sample = w.column(6);
        sample.as(gtk.Widget).addCssClass("appearance-mini-surface");
        sample.as(gtk.Widget).setHalign(.center);
        sample.as(gtk.Widget).setValign(.center);
        sample.as(gtk.Widget).setSizeRequest(126, 68);
        sample.append(w.label(@import("i18n").dtr("pearl", "Sample window"), "appearance-mini-title").as(gtk.Widget));
        sample.append(w.label(@import("i18n").dtr("pearl", "Aa"), "appearance-mini-selection").as(gtk.Widget));
        root.addOverlay(sample.as(gtk.Widget));
        const bar = w.row(12);
        const dock = w.row(5);
        root.addOverlay(bar.as(gtk.Widget));
        root.addOverlay(dock.as(gtk.Widget));
        const layout = w.flow(2);
        layout.setHomogeneous(1);
        layout.as(gtk.Widget).addCssClass("appearance-preview-layout");
        layout.insert(root.as(gtk.Widget), -1);
        const caption = w.column(8);
        caption.as(gtk.Widget).setValign(.center);
        caption.append(w.label(@import("i18n").dtr("pearl", "Desktop preview"), "pearl-section-title").as(gtk.Widget));
        caption.append(w.label(@import("i18n").dtr("pearl", "Draft · Apply & save to update your desktop."), "pearl-secondary").as(gtk.Widget));
        const status = w.label("", "pearl-secondary");
        caption.append(status.as(gtk.Widget));
        caption.append(w.label(@import("i18n").dtr("pearl", "Illustrative · Default bar and dock."), "pearl-secondary").as(gtk.Widget));
        var child = caption.as(gtk.Widget).getFirstChild();
        while (child) |widget| : (child = widget.getNextSibling()) if (@import("gobject2").ext.cast(gtk.Label, widget)) |label| label.setMaxWidthChars(24);
        layout.insert(caption.as(gtk.Widget), -1);
        host.append(layout.as(gtk.Widget));
        const provider = gtk.CssProvider.new();
        gtk.StyleContext.addProviderForDisplay(root.as(gtk.Widget).getDisplay(), provider.as(gtk.StyleProvider), 603);
        self.* = .{ .root = root, .picture = picture, .bar = bar, .dock = dock, .status = status, .caption = caption, .provider = provider };
        return self;
    }
    pub fn destroy(self: *View) void {
        gtk.StyleContext.removeProviderForDisplay(self.root.as(gtk.Widget).getDisplay(), self.provider.as(gtk.StyleProvider));
        self.provider.unref();
        a.destroy(self);
    }
    pub fn palette(self: *View, colors: ?theme.Palette, native: bool) void {
        if (native) {
            self.provider.loadFromString("");
            self.status.setText(@import("i18n").dtr("pearl", "GTK sample · native theme controls the appearance."));
            return;
        }
        const css = theme.scopedCss(a,
            \\.settings-window .$scope .appearance-mini-surface { background: $container$; color: $text$; }
            \\.settings-window .$scope .appearance-mini-selection { background: $primary$; color: $on_primary$; }
        , "appearance-desktop-preview", colors orelse theme.dark) catch return;
        defer a.free(css);
        self.provider.loadFromString(css);
        self.status.setText(if (colors == null)
            (@import("i18n").dtr("pearl", "Sample colors · generated colors apply on save."))
        else
            (@import("i18n").dtr("pearl", "Draft colors · scoped to this preview.")));
    }
    pub fn update(self: *View, p: prefs.Preferences) void {
        const bytes = std.json.Stringify.valueAlloc(a, .{ p.theme, p.wallpaper, p.bar, p.dock }, .{}) catch return;
        defer a.free(bytes);
        const signature = @import("editor_protocol.zig").digest(bytes);
        if (self.signature) |old| if (std.mem.eql(u8, &old, &signature)) return;
        self.signature = signature;
        // Dynamic and community palettes come from the render pipeline; resetting
        // them here would swap the preview back to defaults on every draft edit.
        if (p.theme.mode == .static) self.palette(if (p.theme.variant == .light) theme.light else theme.dark, false) else if (p.theme.mode == .gtk) self.palette(null, true);
        clear(self.bar);
        clear(self.dock);
        position(self.bar, p.bar.edge);
        position(self.dock, if (p.dock.edge == p.bar.edge) switch (p.bar.edge) {
            .top => .bottom,
            .bottom => .top,
            .left => .right,
            .right => .left,
        } else p.dock.edge);
        if (!p.bar.islands) self.bar.as(gtk.Widget).addCssClass("appearance-mini-surface") else self.bar.as(gtk.Widget).removeCssClass("appearance-mini-surface");
        for ([_][]const u8{ p.bar.groups.left, p.bar.groups.center, p.bar.groups.right }) |group| {
            if (group.len == 0) continue;
            const label = w.label(@import("i18n").dtr("pearl", "• • •"), if (p.bar.islands) "appearance-mini-surface" else null);
            self.bar.append(label.as(gtk.Widget));
        }
        self.dock.as(gtk.Widget).addCssClass("appearance-mini-surface");
        self.dock.as(gtk.Widget).setVisible(@intFromBool(p.dock.enabled));
        for (0..4) |_| self.dock.append(w.label(@import("i18n").dtr("pearl", "▪"), "appearance-mini-selection").as(gtk.Widget));
    }
};
fn clear(box: *gtk.Box) void {
    while (box.as(gtk.Widget).getFirstChild()) |child| box.remove(child);
}
fn position(box: *gtk.Box, edge: prefs.Edge) void {
    const vertical = edge == .left or edge == .right;
    box.as(gtk.Orientable).setOrientation(if (vertical) .vertical else .horizontal);
    const widget = box.as(gtk.Widget);
    widget.setHalign(if (vertical) (if (edge == .left) .start else .end) else .center);
    widget.setValign(if (!vertical) (if (edge == .top) .start else .end) else .center);
    widget.setMarginStart(8);
    widget.setMarginEnd(8);
    widget.setMarginTop(8);
    widget.setMarginBottom(8);
}
