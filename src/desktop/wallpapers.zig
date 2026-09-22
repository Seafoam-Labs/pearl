//! Bar wallpaper picker: page through a folder of images and apply one.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const pixbuf = @import("gdkpixbuf2");
const w = @import("../ui/components/widgets.zig");
const tr = @import("text.zig").tr;
const slideshow = @import("../config/slideshow.zig");
const Service = @import("../config/service.zig").Service;
const a = std.heap.c_allocator;

/// One page of thumbnails: three landscape tiles by two rows.
const columns = 3;
const rows = 2;
const slots = columns * rows;
const thumb_width = 192;
const thumb_height = 102;
/// Decoded previews kept between pages and pane reopens.
const cache_limit = 64;
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
    cells: [slots]Cell = undefined,
    arena: std.heap.ArenaAllocator,
    cache: std.StringHashMapUnmanaged(*gdk.Texture) = .{},
    cache_dir_ready: bool = false,
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

    pub fn create(host: *gtk.Box, service: *Service) !*View {
        const self = try a.create(View);
        const header = w.row(8);
        header.append(w.label(tr("Wallpaper", "Hintergrundbild"), "pearl-card-title").as(gtk.Widget));
        const refresh = w.iconButton("pearl-view-refresh-symbolic", tr("Rescan folder", "Ordner neu einlesen"));
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
        const previous = gtk.Button.newWithLabel("‹");
        previous.as(gtk.Widget).addCssClass("pearl-icon");
        w.name(previous.as(gtk.Widget), tr("Previous page", "Vorherige Seite"));
        const page_label = gtk.Label.new("");
        page_label.as(gtk.Widget).addCssClass("pearl-secondary");
        const next = gtk.Button.newWithLabel("›");
        next.as(gtk.Widget).addCssClass("pearl-icon");
        w.name(next.as(gtk.Widget), tr("Next page", "Nächste Seite"));
        footer.append(previous.as(gtk.Widget));
        footer.append(page_label.as(gtk.Widget));
        footer.append(next.as(gtk.Widget));
        host.append(footer.as(gtk.Widget));
        const status = w.label("", "pearl-secondary");
        host.append(status.as(gtk.Widget));
        self.* = .{ .host = host, .service = service, .status = status, .page_label = page_label, .previous = previous, .next = next, .arena = std.heap.ArenaAllocator.init(a) };
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
        self.dropCache();
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
            self.status.setText(tr("Set a wallpaper folder in Settings → Appearance → Slideshow.", "Setze einen Hintergrundbild-Ordner unter Einstellungen → Erscheinungsbild → Diashow."));
        } else if (self.names.len == 0) {
            self.status.as(gtk.Widget).setVisible(1);
            self.status.setText(tr("No PNG or JPEG images in this folder.", "Keine PNG- oder JPEG-Bilder in diesem Ordner."));
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
            const label = alloc.dupeZ(u8, name) catch break;
            w.name(cell.button.as(gtk.Widget), label.ptr);
            if (self.cache.get(path)) |texture| {
                cell.picture.setPaintable(texture.as(gdk.Paintable));
                cell.decoded = true;
            } else if (self.diskThumb(path)) |texture| {
                cell.picture.setPaintable(texture.as(gdk.Paintable));
                self.cachePut(path, texture);
                texture.unref();
                cell.decoded = true;
            }
            cell.button.as(gtk.Widget).setVisible(1);
        }
        var buffer: [32:0]u8 = undefined;
        const total = self.pages();
        self.page_label.setText(std.fmt.bufPrintZ(&buffer, "{d} / {d}", .{ if (total == 0) 0 else self.page + 1, total }) catch "");
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
            self.active += 1;
            thumb.file.readAsync(0, thumb.cancel, Thumb.opened, thumb);
        }
    }
    fn cachePut(self: *View, path: []const u8, texture: *gdk.Texture) void {
        if (self.cache.get(path) != null) return;
        if (self.cache.count() >= cache_limit) self.dropCache();
        const key = a.dupe(u8, path) catch return;
        _ = texture.ref();
        self.cache.put(a, key, texture) catch {
            a.free(key);
            texture.unref();
        };
    }
    fn dropCache(self: *View) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            a.free(@constCast(entry.key_ptr.*));
            entry.value_ptr.*.unref();
        }
        self.cache.clearAndFree(a);
    }
    /// Previews live on disk keyed by path, size and mtime, so a page the user
    /// has seen before paints without touching the source image again.
    fn diskThumb(self: *View, path: []const u8) ?*gdk.Texture {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const target = thumbPath(arena.allocator(), path, self.scale) orelse return null;
        if (glib.fileTest(target.ptr, .{ .is_regular = true }) == 0) return null;
        return gdk.Texture.newFromFilename(target.ptr, null);
    }
    /// Orphans in-flight decodes; they free themselves when their callback lands.
    fn cancelAll(self: *View) void {
        for (&self.cells) |*cell| {
            const thumb = cell.thumb orelse continue;
            cell.thumb = null;
            thumb.owner = null;
            thumb.cancel.cancel();
        }
        self.active = 0;
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
            self.status.setText(tr("That selection is not a usable wallpaper.", "Diese Auswahl ist kein verwendbares Hintergrundbild."));
            return;
        };
        const json = std.json.Stringify.valueAlloc(alloc, prefs, .{}) catch return;
        self.service.apply(json, self.service.revision) catch {
            self.status.as(gtk.Widget).setVisible(1);
            self.status.setText(tr("Could not apply the wallpaper. Try again.", "Hintergrundbild konnte nicht angewendet werden. Bitte erneut versuchen."));
        };
    }
    fn clicked(_: *gtk.Button, cell: *Cell) callconv(.c) void {
        const self = cell.view;
        const path = cell.path orelse return;
        self.commit(path);
        take(&self.selected, path);
        self.markSelected();
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
    current.* = a.dupeZ(u8, value) catch null;
}

const Thumb = struct {
    owner: ?*View,
    generation: u64,
    cell: *Cell,
    file: *gio.File,
    cancel: *gio.Cancellable,
    stream: ?*gio.InputStream = null,
    fn destroy(self: *Thumb) void {
        if (self.stream) |stream| {
            _ = stream.close(null, null);
            stream.unref();
        }
        self.file.unref();
        self.cancel.unref();
        a.destroy(self);
    }
    /// Hands the texture to the cell only if the grid still shows this page.
    fn settle(self: *Thumb, texture: ?*gdk.Texture) void {
        const owner = self.owner orelse {
            if (texture) |image| image.unref();
            self.destroy();
            return;
        };
        self.owner = null;
        owner.active -= 1;
        if (owner.generation == self.generation) {
            self.cell.thumb = null;
            self.cell.decoded = true;
            if (texture) |image| {
                self.cell.picture.setPaintable(image.as(gdk.Paintable));
                owner.cachePut(self.cell.path.?, image);
            }
        }
        if (texture) |image| image.unref();
        owner.pump();
        self.destroy();
    }
    fn storeThumb(self: *Thumb, image: *pixbuf.Pixbuf) void {
        const owner = self.owner orelse return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const target = thumbPath(alloc, self.cell.path.?, owner.scale) orelse return;
        if (!owner.cache_dir_ready) {
            owner.cache_dir_ready = true;
            if (std.fs.path.dirname(target)) |dir| {
                const dir_z = alloc.dupeZ(u8, dir) catch return;
                _ = glib.mkdirWithParents(dir_z, 0o755);
            }
        }
        _ = image.savev(target.ptr, "png", null, null, null);
    }
    fn opened(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Thumb = @ptrCast(@alignCast(data.?));
        const stream = self.file.readFinish(result, null) orelse {
            self.settle(null);
            return;
        };
        self.stream = stream.as(gio.InputStream);
        if (self.owner == null) {
            self.settle(null);
            return;
        }
        // The loader fits inside the box, so a square box still covers the tile
        // for square and portrait sources instead of decoding them too small.
        const side = thumb_width * self.owner.?.scale;
        pixbuf.Pixbuf.newFromStreamAtScaleAsync(self.stream.?, side, side, 1, self.cancel, Thumb.decoded, self);
    }
    fn decoded(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Thumb = @ptrCast(@alignCast(data.?));
        const image = pixbuf.Pixbuf.newFromStreamFinish(result, null) orelse {
            self.settle(null);
            return;
        };
        defer image.unref();
        self.storeThumb(image);
        self.settle(gdk.Texture.newForPixbuf(image));
    }
};

fn thumbPath(alloc: std.mem.Allocator, path: []const u8, scale: c_int) ?[:0]u8 {
    const z = alloc.dupeZ(u8, path) catch return null;
    const file = gio.File.newForPath(z);
    defer file.unref();
    const info = file.queryInfo("standard::size,time::modified", .{ .nofollow_symlinks = true }, null, null) orelse return null;
    defer info.unref();
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(path);
    var meta: [48]u8 = undefined;
    const stamp = std.fmt.bufPrint(&meta, ":{d}:{d}:{d}", .{ info.getSize(), info.getAttributeUint64("time::modified"), scale }) catch return null;
    hasher.update(stamp);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const root = std.mem.span(glib.getUserCacheDir());
    return std.fmt.allocPrintSentinel(alloc, "{s}/pearl/wallpaper-thumbs/{s}.png", .{ root, std.fmt.bytesToHex(digest, .lower) }, 0) catch null;
}
