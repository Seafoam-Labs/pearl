//! Shipped bar and dock layouts. Choosing a preset rewrites only the bar and
//! dock settings it owns in the shared draft; the footer still decides when the
//! desktop changes.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const pixbuf = @import("gdkpixbuf2");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const prefs = @import("../config/preferences.zig");
const presets = @import("../config/bar_dock_presets.zig");
const i18n = @import("i18n");
const Editor = @import("editor.zig").Editor;
const a = std.heap.c_allocator;

pub const Control = struct { id: []const u8, widget: *gtk.Widget };
const Binding = struct { view: *View, index: usize };
const Tile = struct { id: []const u8, button: *gtk.CheckButton, signal: c_ulong };
const Zoom = struct { view: *View, preview: []const u8, name: []const u8 };

pub const View = struct {
    editor: *Editor,
    root: *gtk.Box,
    status: *gtk.Label,
    tiles: []Tile,
    bindings: []Binding,
    controls: std.ArrayList(Control) = .empty,
    arena: std.heap.ArenaAllocator = .init(a),
    zoom: ?*gtk.Window = null,
    filling: bool = false,
    editing: bool = false,

    pub fn create(host: *gtk.Box, editor: *Editor) !*View {
        const self = try a.create(View);
        errdefer a.destroy(self);
        self.* = .{ .editor = editor, .root = undefined, .status = undefined, .tiles = &.{}, .bindings = &.{} };
        const alloc = self.arena.allocator();
        // A collapsed section like Bar displays: no dead space until opened.
        const expander = gtk.Expander.new(null);
        expander.as(gtk.Widget).addCssClass("settings-card");
        expander.as(gtk.Widget).addCssClass("settings-section");
        w.tagExpanderArrow(expander, "settings-section-arrow");
        const heading = w.column(5);
        heading.as(gtk.Widget).addCssClass("settings-section-heading");
        heading.append(w.label(i18n.dtr("pearl", "Layout presets"), "pearl-section-title").as(gtk.Widget));
        expander.setLabelWidget(heading.as(gtk.Widget));
        w.name(expander.as(gtk.Widget), i18n.dtr("pearl", "Layout presets"));
        try self.controls.append(a, .{ .id = "bar.presets.expand", .widget = heading.as(gtk.Widget) });
        const root = w.column(8);
        root.as(gtk.Widget).addCssClass("settings-card");
        expander.setChild(root.as(gtk.Widget));
        host.append(expander.as(gtk.Widget));
        self.root = root;
        const hint = w.label(i18n.dtr("pearl", "Start from a shipped layout. A preset changes bar and dock settings and their widgets only: your other preferences, per-display overrides, pinned applications and widget data such as the weather location stay as they are."), "pearl-secondary");
        hint.setWrap(1);
        hint.as(gtk.Widget).setHexpand(1);
        hint.as(gtk.Widget).setHalign(.fill);
        root.append(hint.as(gtk.Widget));
        const catalog = try presets.catalog(alloc);
        // A plain row keeps the cards together: flowbox cells spread across
        // the whole body width, pushing the tiles to opposite ends.
        const row = w.row(12);
        row.as(gtk.Widget).setHalign(.start);
        row.as(gtk.Widget).addCssClass("appearance-modes");
        root.append(row.as(gtk.Widget));
        self.tiles = try alloc.alloc(Tile, catalog.len);
        self.bindings = try alloc.alloc(Binding, catalog.len);
        for (catalog, 0..) |preset, i| {
            const button = gtk.CheckButton.new();
            if (i > 0) button.setGroup(self.tiles[0].button);
            button.as(gtk.Widget).addCssClass("appearance-mode");
            const labels = w.column(3);
            labels.as(gtk.Widget).setValign(.center);
            if (preset.preview.len > 0) {
                const picture = gtk.Picture.new();
                picture.setCanShrink(1);
                picture.setContentFit(.cover);
                picture.as(gtk.Widget).setSizeRequest(320, 180);
                picture.as(gtk.Widget).setTooltipText(i18n.dtr("pearl", "Click to enlarge"));
                if (previewTexture(alloc, preset.preview, 480, 270)) |texture| {
                    defer texture.unref();
                    picture.setPaintable(texture.as(gdk.Paintable));
                }
                // The frame holds the 16:9 aspect even when the row shrinks on
                // narrow windows, so cover never crops the capture.
                const frame = gtk.AspectFrame.new(0.5, 0.5, 16.0 / 9.0, 0);
                frame.setChild(picture.as(gtk.Widget));
                // The picture opens the large view; the rest of the tile still
                // selects the preset.
                const zoom = try alloc.create(Zoom);
                zoom.* = .{ .view = self, .preview = try alloc.dupe(u8, preset.preview), .name = try alloc.dupe(u8, preset.name) };
                const click = gtk.GestureClick.new();
                picture.as(gtk.Widget).addController(click.as(gtk.EventController));
                _ = gtk.GestureClick.signals.released.connect(click, *Zoom, zoomClicked, zoom, .{});
                labels.append(frame.as(gtk.Widget));
            }
            const name = try alloc.dupeSentinel(u8, preset.name, 0);
            labels.append(w.label(i18n.dtr("pearl", name), "settings-row-title").as(gtk.Widget));
            const summary = w.label(try alloc.dupeSentinel(u8, try presets.summary(alloc, preset), 0), "pearl-secondary");
            labels.append(summary.as(gtk.Widget));
            button.setChild(labels.as(gtk.Widget));
            // The longer description lives in the tooltip so the tile stays as
            // compact as the Appearance cards and its content fills it.
            button.as(gtk.Widget).setTooltipText(try alloc.dupeSentinel(u8, preset.description, 0));
            w.name(button.as(gtk.Widget), name);
            row.append(button.as(gtk.Widget));
            self.bindings[i] = .{ .view = self, .index = i };
            self.tiles[i] = .{ .id = try alloc.dupe(u8, preset.id), .button = button, .signal = 0 };
            self.tiles[i].signal = gtk.CheckButton.signals.toggled.connect(button, *Binding, chosen, &self.bindings[i], .{});
            try self.controls.append(a, .{ .id = try std.fmt.allocPrint(alloc, "bar.preset.{s}", .{preset.id}), .widget = button.as(gtk.Widget) });
        }
        self.status = w.label("", "pearl-secondary");
        root.append(self.status.as(gtk.Widget));
        try self.controls.append(a, .{ .id = "bar.preset.status", .widget = self.status.as(gtk.Widget) });
        self.update();
        return self;
    }

    pub fn destroy(self: *View) void {
        if (self.zoom) |window| {
            self.zoom = null;
            window.destroy();
            window.unref();
        }
        for (self.tiles) |tile| object.signalHandlerDisconnect(tile.button.as(object.Object), tile.signal);
        self.controls.deinit(a);
        self.arena.deinit();
        a.destroy(self);
    }

    pub fn update(self: *View) void {
        if (self.editing) return;
        self.filling = true;
        defer self.filling = false;
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const alloc = temp.allocator();
        const document = prefs.parse(alloc, self.editor.text()) catch {
            self.root.as(gtk.Widget).setSensitive(0);
            return;
        };
        self.root.as(gtk.Widget).setSensitive(@intFromBool(self.editor.editable()));
        // A recorded id that is no longer shipped reads as a custom layout.
        const preset = if (document.bar_dock_preset.len == 0) null else presets.find(alloc, document.bar_dock_preset) catch null;
        for (self.tiles) |tile| tile.button.setActive(@intFromBool(preset != null and std.mem.eql(u8, tile.id, preset.?.id)));
        self.status.setText(statusText(alloc, preset) catch i18n.dtr("pearl", "Custom layout"));
    }

    fn zoomClicked(_: *gtk.GestureClick, _: c_int, _: f64, _: f64, zoom: *Zoom) callconv(.c) void {
        zoom.view.openZoom(zoom.preview, zoom.name);
    }

    /// The tile shows a small preview; clicking it brings the image up large
    /// in a modal window, scaled to fit without cropping.
    fn openZoom(self: *View, preview: []const u8, name: []const u8) void {
        if (self.zoom != null) return;
        const alloc = self.arena.allocator();
        const title = alloc.dupeSentinel(u8, name, 0) catch return;
        const texture = previewTexture(alloc, preview, 0, 0) orelse return;
        defer texture.unref();
        const window = gtk.Window.new();
        self.zoom = window;
        _ = window.ref();
        window.setTitle(title);
        if (self.root.as(gtk.Widget).getRoot()) |root| window.setTransientFor(object.ext.cast(gtk.Window, root));
        window.setModal(1);
        window.setDefaultSize(1280, 720);
        const picture = gtk.Picture.new();
        picture.setCanShrink(1);
        picture.setContentFit(.contain);
        picture.as(gtk.Widget).setHexpand(1);
        picture.as(gtk.Widget).setVexpand(1);
        picture.setPaintable(texture.as(gdk.Paintable));
        window.setChild(picture.as(gtk.Widget));
        _ = gtk.Window.signals.close_request.connect(window, *View, zoomClosed, self, .{});
        window.present();
    }

    fn zoomClosed(window: *gtk.Window, self: *View) callconv(.c) c_int {
        self.zoom = null;
        window.destroy();
        window.unref();
        return 1;
    }

    /// Decodes through gdk-pixbuf, so any installed loader works: the shipped
    /// captures can be replaced by AVIF/WebP screenshots via the JSON.
    /// A missing or undecodable asset leaves the tile without a picture.
    /// `width`/`height` bound the decode (0 keeps full resolution): a Picture's
    /// natural size is its paintable's intrinsic size, so the tile must load a
    /// bounded texture or the flowbox gives every tile the whole row width.
    fn previewTexture(alloc: std.mem.Allocator, path: []const u8, width: c_int, height: c_int) ?*gdk.Texture {
        const sentinel = alloc.dupeSentinel(u8, path, 0) catch return null;
        defer alloc.free(sentinel);
        const stream = gio.resourcesOpenStream(sentinel, .{}, null) orelse return null;
        defer stream.unref();
        const image = (if (width > 0) pixbuf.Pixbuf.newFromStreamAtScale(stream.as(gio.InputStream), width, height, 1, null, null) else pixbuf.Pixbuf.newFromStream(stream.as(gio.InputStream), null, null)) orelse return null;
        defer image.unref();
        return gdk.Texture.newForPixbuf(image);
    }

    fn statusText(alloc: std.mem.Allocator, preset: ?presets.Preset) ![:0]const u8 {
        const found = preset orelse return i18n.dtr("pearl", "Custom layout · choose a preset to start from one");
        return alloc.dupeSentinel(u8, try std.fmt.allocPrint(alloc, "{s} layout · {s}", .{ found.name, try presets.summary(alloc, found) }), 0);
    }

    fn chosen(_: *gtk.CheckButton, binding: *Binding) callconv(.c) void {
        const self = binding.view;
        const tile = &self.tiles[binding.index];
        // A radio group also reports the tile that was left; only the chosen one
        // applies, and a redraw from the draft never re-applies anything.
        if (self.filling or self.editing or !self.editor.editable() or tile.button.getActive() == 0) return;
        self.editing = true;
        defer {
            self.editing = false;
            self.update();
        }
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const text = presets.apply(arena.allocator(), self.editor.text(), tile.id) catch |err| {
            self.editor.error_code.set(@errorName(err));
            return;
        };
        self.editor.edit(text) catch |err| self.editor.error_code.set(@errorName(err));
    }
};
