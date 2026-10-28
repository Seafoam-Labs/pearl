//! Bar wallpaper picker: page through a folder of images and apply one.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const tr = @import("text.zig").tr;
const slideshow = @import("../config/slideshow.zig");
const crop_window = @import("wallpaper_crop.zig");
const Service = @import("../config/service.zig").Service;
const a = std.heap.c_allocator;

/// One page of thumbnails: three landscape tiles by two rows.
const columns = 3;
const rows = 2;
const slots = columns * rows;
const thumb_width = 192;
const thumb_height = 102;
const selected_class = "pearl-wallpaper-selected";

const Cell = struct {
    view: *View,
    button: *gtk.Button,
    picture: *gtk.Picture,
    path: ?[:0]const u8 = null,
    thumb: ?*Thumb = null,
    decoded: bool = false,
};

pub const View = struct {
    host: *gtk.Box,
    service: *Service,
    status: *gtk.Label,
    page_label: *gtk.Label,
    previous: *gtk.Button,
    next: *gtk.Button,
    /// Double-clicking a thumbnail asks this to open the crop editor for it.
    request: crop_window.Request,
    cells: [slots]Cell = undefined,
    arena: std.heap.ArenaAllocator,
    /// Display scale the current page was decoded for; previews are sharp at it.
    scale: c_int = 1,
    mapped: bool = false,
    dirty: bool = false,
    /// Sorted eligible basenames for the current folder.
    names: [][]const u8 = &.{},
    folder: ?[:0]u8 = null,
    selected: ?[:0]u8 = null,
    page: usize = 0,
    /// Bumped on every repopulate so a late decode cannot write into stale cells.
    generation: u64 = 0,
    active: usize = 0,

    pub fn create(host: *gtk.Box, service: *Service, request: crop_window.Request) !*View {
        @import("file_chooser").initPreviews();
        const self = try a.create(View);
        const header = w.row(8);
        header.append(w.label(@import("i18n").dtr("pearl", "Wallpaper"), "pearl-card-title").as(gtk.Widget));
        const refresh = w.iconButton("pearl-view-refresh-symbolic", @import("i18n").dtr("pearl", "Rescan folder"));
        header.append(refresh.as(gtk.Widget));
        host.append(header.as(gtk.Widget));
        const scroll = gtk.ScrolledWindow.new();
        // A classic scrollbar reserves its own lane instead of floating over the
        // thumbnails, and the grid never scrolls sideways.
        scroll.setOverlayScrolling(0);
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        scroll.as(gtk.Widget).setHexpand(1);
        const flow = gtk.FlowBox.new();
        flow.setSelectionMode(.none);
        flow.setHomogeneous(1);
        flow.setMinChildrenPerLine(columns);
        flow.setMaxChildrenPerLine(columns);
        flow.setColumnSpacing(10);
        flow.setRowSpacing(10);
        flow.as(gtk.Widget).setHalign(.fill);
        scroll.setChild(flow.as(gtk.Widget));
        host.append(scroll.as(gtk.Widget));
        const footer = w.row(12);
        footer.as(gtk.Widget).setHalign(.center);
        const previous = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "‹"));
        previous.as(gtk.Widget).addCssClass("pearl-icon");
        w.name(previous.as(gtk.Widget), @import("i18n").dtr("pearl", "Previous page"));
        const page_label = gtk.Label.new("");
        page_label.as(gtk.Widget).addCssClass("pearl-secondary");
        const next = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "›"));
        next.as(gtk.Widget).addCssClass("pearl-icon");
        w.name(next.as(gtk.Widget), @import("i18n").dtr("pearl", "Next page"));
        footer.append(previous.as(gtk.Widget));
        footer.append(page_label.as(gtk.Widget));
        footer.append(next.as(gtk.Widget));
        host.append(footer.as(gtk.Widget));
        const status = w.label("", "pearl-secondary");
        host.append(status.as(gtk.Widget));
        self.* = .{ .host = host, .service = service, .status = status, .page_label = page_label, .previous = previous, .next = next, .request = request, .arena = std.heap.ArenaAllocator.init(a) };
        for (&self.cells) |*cell| {
            const button = gtk.Button.new();
            button.as(gtk.Widget).addCssClass("pearl-wallpaper-thumb");
            const picture = gtk.Picture.new();
            picture.setCanShrink(1);
            picture.setContentFit(.cover);
            // A picture's natural height is its texture's, which would stretch
            // every FlowBox row. This clip reports no natural size of its own,
            // so the row height comes from the size request alone.
            const clip = gtk.ScrolledWindow.new();
            clip.setPolicy(.never, .never);
            clip.setOverlayScrolling(0);
            clip.setPropagateNaturalWidth(0);
            clip.setPropagateNaturalHeight(0);
            clip.as(gtk.Widget).setSizeRequest(-1, thumb_height);
            clip.setChild(picture.as(gtk.Widget));
            button.setChild(clip.as(gtk.Widget));
            button.as(gtk.Widget).setVisible(0);
            cell.* = .{ .view = self, .button = button, .picture = picture };
            _ = gtk.Button.signals.clicked.connect(button, *Cell, clicked, cell, .{});
            const double = gtk.GestureClick.new();
            double.as(gtk.GestureSingle).setButton(1);
            // Capturing runs this ahead of the button's own activation gesture,
            // so a second press is seen without a single click losing its apply.
            double.as(gtk.EventController).setPropagationPhase(.capture);
            _ = gtk.GestureClick.signals.pressed.connect(double, *Cell, doubleClicked, cell, .{});
            button.as(gtk.Widget).addController(double.as(gtk.EventController));
            flow.insert(button.as(gtk.Widget), -1);
        }
        _ = gtk.Button.signals.clicked.connect(refresh, *View, refreshed, self, .{});
        _ = gtk.Button.signals.clicked.connect(previous, *View, previousPage, self, .{});
        _ = gtk.Button.signals.clicked.connect(next, *View, nextPage, self, .{});
        // The scale factor is only real once the window is realized, so the first
        // populate waits for map instead of caching previews at the wrong scale.
        _ = gtk.Widget.signals.map.connect(host.as(gtk.Widget), *View, onMap, self, .{});
        self.update();
        return self;
    }
    pub fn destroy(self: *View) void {
        self.generation += 1;
        self.cancelAll();
        self.arena.deinit();
        if (self.folder) |folder| a.free(folder);
        if (self.selected) |selected| a.free(selected);
        a.destroy(self);
    }

    /// Refreshes from committed preferences; re-lists only when the folder moved.
    pub fn update(self: *View) void {
        const prefs = self.service.prefs();
        const folder = prefs.wallpaper.slideshow.folder;
        const same_folder = self.folder != null and std.mem.eql(u8, self.folder.?, folder);
        const same_selected = self.selected != null and std.mem.eql(u8, self.selected.?, prefs.wallpaper.path);
        if (same_folder and same_selected) return;
        if (same_folder) {
            take(&self.selected, prefs.wallpaper.path);
            self.markSelected();
            return;
        }
        take(&self.folder, folder);
        take(&self.selected, prefs.wallpaper.path);
        self.page = 0;
        if (self.mapped) self.rebuild() else self.dirty = true;
    }
    fn onMap(_: *gtk.Widget, self: *View) callconv(.c) void {
        const scale = @max(1, self.host.as(gtk.Widget).getScaleFactor());
        const stale = scale != self.scale or self.dirty;
        self.scale = scale;
        self.mapped = true;
        self.dirty = false;
        if (stale) self.rebuild();
    }

    fn rebuild(self: *View) void {
        self.generation += 1;
        self.cancelAll();
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(a);
        const alloc = self.arena.allocator();
        const folder = self.folder orelse "";
        self.names = if (folder.len == 0) &.{} else slideshow.listImages(alloc, folder) catch &.{};
        if (folder.len == 0) {
            self.status.as(gtk.Widget).setVisible(1);
            self.status.setText(@import("i18n").dtr("pearl", "Set a wallpaper folder in Settings → Appearance → Slideshow."));
        } else if (self.names.len == 0) {
            self.status.as(gtk.Widget).setVisible(1);
            self.status.setText(@import("i18n").dtr("pearl", "No PNG or JPEG images in this folder."));
        } else self.status.as(gtk.Widget).setVisible(0);
        const total = self.pages();
        if (self.page >= total) self.page = if (total == 0) 0 else total - 1;
        self.populate();
    }
    fn pages(self: *const View) usize {
        return (self.names.len + slots - 1) / slots;
    }
    fn populate(self: *View) void {
        self.generation += 1;
        self.cancelAll();
        for (&self.cells) |*cell| {
            cell.path = null;
            cell.decoded = false;
            cell.picture.setPaintable(null);
            cell.button.as(gtk.Widget).setVisible(0);
            cell.button.as(gtk.Widget).removeCssClass(selected_class);
        }
        const start = self.page * slots;
        const end = @min(self.names.len, start + slots);
        const alloc = self.arena.allocator();
        const folder = self.folder orelse "";
        for (self.names[start..end], 0..) |name, i| {
            const cell = &self.cells[i];
            const path = std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ folder, name }, 0) catch break;
            cell.path = path;
            const label = alloc.dupeSentinel(u8, name, 0) catch break;
            w.name(cell.button.as(gtk.Widget), label.ptr);
            cell.button.as(gtk.Widget).setVisible(1);
        }
        var buffer: [32:0]u8 = undefined;
        const total = self.pages();
        self.page_label.setText(std.mem.printSentinel(&buffer, "{d} / {d}", .{ if (total == 0) 0 else self.page + 1, total }, 0) catch "");
        self.previous.as(gtk.Widget).setSensitive(@intFromBool(self.page > 0));
        self.next.as(gtk.Widget).setSensitive(@intFromBool(self.page + 1 < total));
        self.markSelected();
        self.pump();
    }
    fn markSelected(self: *View) void {
        const selected = self.selected orelse "";
        for (&self.cells) |*cell| {
            const on = selected.len != 0 and cell.path != null and std.mem.eql(u8, cell.path.?, selected);
            const widget = cell.button.as(gtk.Widget);
            if (widget.hasCssClass(selected_class) != 0) {
                if (!on) widget.removeCssClass(selected_class);
            } else if (on) widget.addCssClass(selected_class);
        }
    }
    /// Cached pages paint instantly; the rest decode concurrently.
    fn pump(self: *View) void {
        for (&self.cells) |*cell| {
            if (cell.path == null or cell.decoded or cell.thumb != null) continue;
            const thumb = a.create(Thumb) catch return;
            thumb.* = .{ .owner = self, .generation = self.generation, .cell = cell, .file = gio.File.newForPath(cell.path.?.ptr), .cancel = gio.Cancellable.new() };
            cell.thumb = thumb;
            thumb.file.queryInfoAsync("standard::*,access::can-read,time::modified,time::modified-usec", .{ .nofollow_symlinks = true }, 0, thumb.cancel, Thumb.queried, thumb);
        }
    }
    /// Orphans in-flight decodes; they free themselves when their callback lands.
    fn cancelAll(self: *View) void {
        for (&self.cells) |*cell| {
            const thumb = cell.thumb orelse continue;
            cell.thumb = null;
            thumb.owner = null;
            thumb.cancel.cancel();
            if (!thumb.query_pending) thumb.destroy();
        }
    }

    /// Committing through the preferences service keeps the wallpaper watch,
    /// dynamic colors and every output surface consistent with a manual change.
    fn commit(self: *View, path: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var prefs = self.service.prefs();
        prefs.wallpaper.path = path;
        if (prefs.wallpaper.mode != .cover and prefs.wallpaper.mode != .contain) prefs.wallpaper.mode = .cover;
        prefs.validate() catch {
            self.status.as(gtk.Widget).setVisible(1);
            self.status.setText(@import("i18n").dtr("pearl", "That selection is not a usable wallpaper."));
            return;
        };
        const json = std.json.Stringify.valueAlloc(alloc, prefs, .{}) catch return;
        self.service.apply(json, self.service.revision) catch {
            self.status.as(gtk.Widget).setVisible(1);
            self.status.setText(@import("i18n").dtr("pearl", "Could not apply the wallpaper. Try again."));
        };
    }
    fn clicked(_: *gtk.Button, cell: *Cell) callconv(.c) void {
        const self = cell.view;
        const path = cell.path orelse return;
        self.commit(path);
        take(&self.selected, path);
        self.markSelected();
    }
    /// A single click applies; the second press of a double click opens the crop
    /// editor for the image that click just made current.
    fn doubleClicked(_: *gtk.GestureClick, presses: c_int, _: f64, _: f64, cell: *Cell) callconv(.c) void {
        if (presses != 2) return;
        const path = cell.path orelse return;
        const request = cell.view.request;
        request.open(request.context, path);
    }
    fn refreshed(_: *gtk.Button, self: *View) callconv(.c) void {
        self.rebuild();
    }
    fn previousPage(_: *gtk.Button, self: *View) callconv(.c) void {
        if (self.page == 0) return;
        self.page -= 1;
        self.populate();
    }
    fn nextPage(_: *gtk.Button, self: *View) callconv(.c) void {
        if (self.page + 1 >= self.pages()) return;
        self.page += 1;
        self.populate();
    }
};

fn take(current: *?[:0]u8, value: []const u8) void {
    if (current.*) |old| a.free(old);
    current.* = a.dupeSentinel(u8, value, 0) catch null;
}

const Thumb = struct {
    owner: ?*View,
    generation: u64,
    cell: *Cell,
    file: *gio.File,
    cancel: *gio.Cancellable,
    query_pending: bool = true,
    watch: ?*anyopaque = null,
    fn destroy(self: *Thumb) void {
        pearl_preview_unwatch(self.watch);
        self.file.unref();
        self.cancel.unref();
        a.destroy(self);
    }
    fn ready(texture: ?*gdk.Texture, _: ?[*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Thumb = @ptrCast(@alignCast(data.?));
        const owner = self.owner orelse return;
        if (owner.generation != self.generation) return;
        self.cell.decoded = true;
        if (texture) |image| self.cell.picture.setPaintable(image.as(gdk.Paintable));
    }
    fn queried(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Thumb = @ptrCast(@alignCast(data.?));
        self.query_pending = false;
        const info = self.file.queryInfoFinish(result, null);
        defer if (info) |value| value.unref();
        const owner = self.owner orelse {
            self.destroy();
            return;
        };
        if (info) |value| {
            value.setAttributeObject("standard::file", self.file.as(object.Object));
            self.watch = pearl_preview_watch(value, @intCast(thumb_width * owner.scale), ready, self);
        }
        if (self.watch == null) self.cell.decoded = true;
    }
};
extern fn pearl_preview_watch(*gio.FileInfo, c_uint, *const fn (?*gdk.Texture, ?[*:0]const u8, ?*anyopaque) callconv(.c) void, ?*anyopaque) ?*anyopaque;
extern fn pearl_preview_unwatch(?*anyopaque) void;
