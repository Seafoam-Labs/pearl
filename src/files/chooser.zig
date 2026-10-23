//! Pearl's shared native chooser. GTK objects stay on the main context; async
//! jobs retain the dialog and stop on cancellation or a stale navigation epoch.
pub const harness = @import("chooser/harness.zig");
const std = @import("std");
const u = @import("chooser/util.zig");
const gtk = u.gtk;
const gio = u.gio;
const glib = u.glib;
const object = u.object;
const gdk = @import("gdk4");
const cast = u.cast;
const a = u.a;
const W = u.W;
const style = @import("chooser/style.zig");
const preferences = @import("chooser/state.zig");
const previews = @import("previews").api;
const attributes = "standard::*,time::modified,time::modified-usec,access::can-read,access::can-write,etag::value,id::file";
const accepted_response = @intFromEnum(gtk.ResponseType.accept);
const cancelled_response = @intFromEnum(gtk.ResponseType.cancel);
const Chooser = struct {
    dialog: *gtk.Dialog,
    action: gtk.FileChooserAction,
    directory: *gtk.DirectoryList = undefined,
    filtered: *gtk.FilterListModel = undefined,
    sorted: *gtk.SortListModel = undefined,
    selection: *gtk.MultiSelection = undefined,
    filter: *gtk.CustomFilter = undefined,
    sorter: *gtk.CustomSorter = undefined,
    filters: *gio.ListStore = undefined,
    accepted: ?*gio.ListStore = null,
    location: W = undefined,
    search: W = undefined,
    name: W = undefined,
    status: W = undefined,
    accept_button: W = undefined,
    grid: W = undefined,
    places: W = undefined,
    filter_menu: W = undefined,
    batch_box: W = undefined,
    choices_box: W = undefined,
    caller: W = undefined,
    preview: W = undefined,
    preview_label: W = undefined,
    hidden_toggle: W = undefined,
    sort_toggle: W = undefined,
    list_toggle: W = undefined,
    sort_menu: W = undefined,
    preview_toggle: W = undefined,
    breadcrumbs_box: W = undefined,
    places_scroll: W = undefined,
    places_button: W = undefined,
    places_popup: W = undefined,
    panes: W = undefined,
    preview_box: W = undefined,
    state_key: ?[*:0]u8 = null,
    sort_kind: c_uint = 0,
    show_preview: bool = true,
    batch: std.ArrayList(W) = .empty,
    choices: std.ArrayList(Choice) = .empty,
    history: std.ArrayList(*gio.File) = .empty,
    history_index: usize = 0,
    initial_generation: u64 = 0,
    accept_after_navigation: bool = false,
    list_mode: bool = false,
    navigating_history: bool = false,
    multiple: bool = false,
    hidden: bool = false,
    reverse: bool = false,
    local_only: bool = false,
    busy: bool = false,
    closed: bool = false,
    cancel: *gio.Cancellable,
    pending_selection: ?*gio.File = null,
    mounts: *gio.VolumeMonitor = undefined,
    bookmark_monitor: ?*gio.FileMonitor = null,
    phyto_monitor: ?*gio.FileMonitor = null,
    bookmarks: ?[*:0]u8 = null,
    phyto_bookmarks: ?[*:0]u8 = null,
    preview_watch: ?*previews.Watch = null,
};
const Choice = struct {
    id: [*:0]u8,
    widget: W,
    values: std.ArrayList([*:0]u8) = .empty,
    fn deinit(self: *Choice) void {
        glib.free(self.id);
        for (self.values.items) |v| glib.free(v);
        self.values.deinit(a);
    }
};
const Tile = struct { picture: W, icon: W, info: ?*gio.FileInfo = null, watch: ?*previews.Watch = null };
const Validation = struct { dialog: *gtk.Dialog, files: *gio.ListStore, index: c_uint = 0, existing: ?*gio.FileInfo = null };
const Initial = struct { dialog: *gtk.Dialog, generation: u64, activate: bool = false, folder_only: bool = false };
fn state(d: *gtk.Dialog) *Chooser {
    return u.data(Chooser, d, "pearl-chooser").?;
}
fn message(s: *Chooser, text: [*:0]const u8) void {
    const l = cast(gtk.Label, s.status);
    if (u.eql(l.getText(), text)) return;
    l.setText(text);
    if (s.status.getMapped() != 0) cast(gtk.Accessible, s.status).announce(text, .medium);
}
fn validName(text: [*:0]const u8) bool {
    return text[0] != 0 and !u.eql(text, ".") and !u.eql(text, "..") and std.mem.indexOfScalar(u8, std.mem.span(text), '/') == null;
}
fn entryName(entry: W) [*:0]const u8 {
    const text = cast(gtk.Editable, entry).getText();
    const display: ?[*:0]const u8 = @ptrCast(cast(object.Object, entry).getData("original-display"));
    const bytes: ?[*:0]const u8 = @ptrCast(cast(object.Object, entry).getData("original-bytes"));
    return if (display != null and bytes != null and u.eql(text, display.?)) bytes.? else text;
}
fn entryBytes(entry: W, bytes: [*:0]const u8) void {
    const display = glib.filenameDisplayName(bytes);
    u.ownedData(entry, "original-bytes", glib.strdup(bytes), &u.freeData);
    u.ownedData(entry, "original-display", display, &u.freeData);
    cast(gtk.Editable, entry).setText(display);
}
fn cleanup(data: ?*anyopaque) callconv(.c) void {
    const s = cast(Chooser, data);
    s.cancel.cancel();
    previews.pearl_preview_unwatch(s.preview_watch);
    inline for (.{ "pending_selection", "mounts", "bookmark_monitor", "phyto_monitor", "directory", "filtered", "sorted", "selection", "filter", "sorter", "filters", "accepted", "cancel" }) |field| u.unref(@field(s, field));
    glib.free(s.bookmarks);
    glib.free(s.phyto_bookmarks);
    glib.free(s.state_key);
    s.batch.deinit(a);
    for (s.choices.items) |*c| c.deinit();
    s.choices.deinit(a);
    for (s.history.items) |f| u.unref(f);
    s.history.deinit(a);
    a.destroy(s);
}
fn closed(widget: *gtk.Widget, _: ?*anyopaque) callconv(.c) void {
    const s = state(cast(gtk.Dialog, widget));
    s.closed = true;
    s.cancel.cancel();
    s.directory.setFile(null);
    previews.pearl_preview_unwatch(s.preview_watch);
    s.preview_watch = null;
}
fn match(item: *object.Object, data: ?*anyopaque) callconv(.c) c_int {
    const s = cast(Chooser, data);
    const info = cast(gio.FileInfo, item);
    if (!s.hidden and (info.getIsHidden() != 0 or info.getIsBackup() != 0)) return 0;
    if (s.action == .select_folder and info.getFileType() != .directory) return 0;
    const query = cast(gtk.Editable, s.search).getText();
    if (query[0] != 0) {
        const name = glib.utf8Casefold(info.getDisplayName(), -1);
        defer glib.free(name);
        const needle = glib.utf8Casefold(query, -1);
        defer glib.free(needle);
        if (std.mem.indexOf(u8, std.mem.span(name), std.mem.span(needle)) == null) return 0;
    }
    const filter = getFilter(s.dialog);
    return @intFromBool(info.getFileType() == .directory or filter == null or cast(gtk.Filter, filter).match(cast(object.Object, info)) != 0);
}
fn compare(left: ?*const anyopaque, right: ?*const anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    const s = cast(Chooser, data);
    const x = cast(gio.FileInfo, @constCast(left));
    const y = cast(gio.FileInfo, @constCast(right));
    const xd = x.getFileType() == .directory;
    const yd = y.getFileType() == .directory;
    if (xd != yd) return if (xd) -1 else 1;
    var result: c_int = 0;
    if (s.sort_kind == 1) {
        const xv = x.getAttributeUint64("time::modified");
        const yv = y.getAttributeUint64("time::modified");
        result = if (xv < yv) -1 else if (xv > yv) 1 else 0;
    } else if (s.sort_kind == 2) {
        result = if (x.getSize() < y.getSize()) -1 else if (x.getSize() > y.getSize()) 1 else 0;
    } else if (s.sort_kind == 3) result = glib.strcmp0(x.getContentType(), y.getContentType());
    if (result == 0) result = glib.utf8Collate(x.getDisplayName(), y.getDisplayName());
    result = if (result < 0) -1 else if (result > 0) 1 else 0;
    return if (s.reverse) -result else result;
}
fn tileReady(texture: ?*gdk.Texture, _: ?[*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const t = cast(Tile, data);
    if (texture) |image| {
        cast(gtk.Picture, t.picture).setPaintable(cast(gdk.Paintable, image));
        t.icon.setVisible(0);
    }
}
fn tileUnwatch(t: *Tile) void {
    previews.pearl_preview_unwatch(t.watch);
    t.watch = null;
}
fn tileMap(w: W, t: *Tile) callconv(.c) void {
    if (t.info != null and t.watch == null) t.watch = previews.pearl_preview_watch(t.info.?, @intCast(256 * @min(4, w.getScaleFactor())), &tileReady, t);
}
fn tileUnmap(_: W, t: *Tile) callconv(.c) void {
    tileUnwatch(t);
}
fn tileFree(data: ?*anyopaque) callconv(.c) void {
    const t = cast(Tile, data);
    tileUnwatch(t);
    u.unref(t.info);
    a.destroy(t);
}
fn setup(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, s: *Chooser) callconv(.c) void {
    const t = u.new(Tile, .{ .picture = gtk.Picture.new().as(gtk.Widget), .icon = gtk.Image.new().as(gtk.Widget) });
    const box = gtk.Box.new(if (s.list_mode) .horizontal else .vertical, 6).as(gtk.Widget);
    const overlay = gtk.Overlay.new().as(gtk.Widget);
    cast(gtk.Picture, t.picture).setContentFit(.contain);
    t.picture.setSizeRequest(if (s.list_mode) 48 else 96, if (s.list_mode) 40 else 90);
    cast(gtk.Picture, t.picture).setCanShrink(1);
    cast(gtk.Overlay, overlay).setChild(t.picture);
    cast(gtk.Image, t.icon).setPixelSize(if (s.list_mode) 28 else 42);
    cast(gtk.Overlay, overlay).addOverlay(t.icon);
    u.append(box, overlay);
    const name = gtk.Label.new("").as(gtk.Widget);
    cast(gtk.Label, name).setEllipsize(.end);
    cast(gtk.Label, name).setMaxWidthChars(20);
    u.append(box, name);
    name.setHexpand(@intFromBool(s.list_mode));
    if (s.list_mode) cast(gtk.Label, name).setXalign(0);
    const details = gtk.Label.new("").as(gtk.Widget);
    details.addCssClass("dim-label");
    details.setVisible(@intFromBool(s.list_mode));
    u.append(box, details);
    u.setData(item, "details", details);
    u.setData(item, "name", name);
    u.ownedData(item, "tile", t, &tileFree);
    box.addCssClass("pearl-file-tile");
    item.setChild(box);
    u.connect(box, "map", &tileMap, t);
    u.connect(box, "unmap", &tileUnmap, t);
}
fn bind(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
    const t = u.data(Tile, item, "tile").?;
    tileUnwatch(t);
    u.clear(&t.info);
    t.info = u.ref(cast(gio.FileInfo, item.getItem()));
    const info = t.info.?;
    u.data(gtk.Label, item, "name").?.setText(info.getDisplayName());
    const size = if (info.getFileType() == .directory) glib.strdup("Folder") else glib.formatSize(@intCast(@max(0, info.getSize())));
    defer glib.free(size);
    u.data(gtk.Label, item, "details").?.setText(size);
    cast(gtk.Picture, t.picture).setPaintable(null);
    t.icon.setVisible(1);
    const icon = cast(gtk.Image, t.icon);
    if (info.getFileType() == .directory) icon.setFromIconName("folder-symbolic") else if (info.getIcon()) |gicon| icon.setFromGicon(gicon) else icon.setFromIconName("text-x-generic-symbolic");
    const child = item.getChild().?;
    child.setTooltipText(info.getDisplayName());
    if (child.getMapped() != 0) tileMap(child, t);
}
fn unbind(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
    const t = u.data(Tile, item, "tile").?;
    tileUnwatch(t);
    u.clear(&t.info);
    cast(gtk.Picture, t.picture).setPaintable(null);
}
fn infoFile(info: *gio.FileInfo) ?*gio.File {
    return if (info.getAttributeObject("standard::file")) |file| cast(gio.File, file) else null;
}
fn previewReady(texture: ?*gdk.Texture, caption: ?[*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const s = cast(Chooser, data);
    if (s.closed) return;
    cast(gtk.Picture, s.preview).setPaintable(if (texture) |image| cast(gdk.Paintable, image) else null);
    if (caption) |text| cast(gtk.Label, s.preview_label).setText(text);
}
fn selectionChanged(model: *gtk.SelectionModel, position: c_uint, n: c_uint, s: *Chooser) callconv(.c) void {
    const selected = model.getSelection();
    defer selected.unref();
    if (!s.multiple and selected.getSize() > 1) {
        var chosen = selected.getMinimum();
        var i = position;
        while (i < position + n) : (i += 1) {
            if (selected.contains(i) != 0) {
                chosen = i;
                break;
            }
        }
        _ = model.selectItem(chosen, 1);
        return;
    }
    previews.pearl_preview_unwatch(s.preview_watch);
    s.preview_watch = null;
    cast(gtk.Picture, s.preview).setPaintable(null);
    cast(gtk.Label, s.preview_label).setText("");
    if (selected.getSize() == 1) {
        if (u.modelItem(gio.FileInfo, s.sorted, selected.getMinimum())) |info| {
            defer u.unref(info);
            cast(gtk.Label, s.preview_label).setText(info.getDisplayName());
            if (s.preview_box.getVisible() != 0) s.preview_watch = previews.pearl_preview_watch(info, 512, &previewReady, s);
            if (s.action == .save and info.getFileType() != .directory) entryBytes(s.name, info.getName());
        }
    }
    refresh(s);
}
fn acceptIdle(data: ?*anyopaque) callconv(.c) c_int {
    const d = cast(gtk.Dialog, data);
    defer u.unref(d);
    const s = state(d);
    if (!s.closed and s.accept_after_navigation) {
        s.accept_after_navigation = false;
        accept(null, s);
    }
    return 0;
}
fn refresh(s: *Chooser) void {
    if (s.closed) return;
    const bits = cast(gtk.SelectionModel, s.selection).getSelection();
    const n = bits.getSize();
    bits.unref();
    var valid = (s.action == .select_folder and !s.multiple) or n > 0;
    if (s.action == .save) valid = validName(cast(gtk.Editable, s.name).getText());
    if (s.batch.items.len > 0) {
        valid = true;
        for (s.batch.items, 0..) |entry, i| {
            const name = entryName(entry);
            if (!validName(name)) valid = false;
            for (s.batch.items[0..i]) |prior| {
                if (u.eql(name, entryName(prior))) valid = false;
            }
        }
    }
    const loading = s.directory.isLoading() != 0;
    cast(gtk.Accessible, s.grid).updateState(.busy, @as(c_int, @intFromBool(loading or s.busy)), @as(c_int, -1));
    const err = s.directory.getError();
    const ready = valid and !s.busy and err == null and !loading;
    s.accept_button.setSensitive(@intFromBool(ready));
    if (s.accept_after_navigation and ready) _ = glib.idleAdd(&acceptIdle, u.ref(s.dialog));
    if (err != null) message(s, @import("i18n").dtr("pearl-files", "This location is unavailable. Choose another location or retry.")) else if (loading) message(s, @import("i18n").dtr("pearl-files", "Loading files…")) else if (u.count(s.sorted) == 0) message(s, @import("i18n").dtr("pearl-files", "No matching files in this folder.")) else {
        var count_buffer: [32]u8 = undefined;
        var buffer: [256]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buffer, "{d}", .{n}) catch unreachable;
        // Translators: Number of files selected in the file chooser.
        const text = @import("i18n").dnmessage("pearl-files", &buffer, "{count} file selected", "{count} files selected", n, &.{.{ .name = "count", .value = count }});
        message(s, text);
    }
}
fn changed(_: ?W, s: *Chooser) callconv(.c) void {
    cast(gtk.Filter, s.filter).changed(.different);
    refresh(s);
}
fn filterChanged(_: *object.Object, _: *object.ParamSpec, s: *Chooser) callconv(.c) void {
    changed(null, s);
}
fn directoryChanged(_: *object.Object, _: *object.ParamSpec, s: *Chooser) callconv(.c) void {
    refresh(s);
}
fn itemsChanged(_: *gio.ListModel, _: c_uint, _: c_uint, _: c_uint, s: *Chooser) callconv(.c) void {
    if (s.pending_selection) |pending| {
        for (0..u.count(s.sorted)) |i| {
            const info = u.modelItem(gio.FileInfo, s.sorted, @intCast(i)) orelse continue;
            defer u.unref(info);
            if (infoFile(info)) |file| {
                if (file.equal(pending) != 0) {
                    _ = cast(gtk.SelectionModel, s.selection).selectItem(@intCast(i), 1);
                    u.clear(&s.pending_selection);
                    break;
                }
            }
        }
    }
    refresh(s);
}
fn breadcrumbClicked(b: *gtk.Button, s: *Chooser) callconv(.c) void {
    navigate(s, u.data(gio.File, b, "folder").?);
}
fn breadcrumbs(s: *Chooser, folder: *gio.File) void {
    while (s.breadcrumbs_box.getFirstChild()) |child| cast(gtk.Box, s.breadcrumbs_box).remove(child);
    var parents: std.ArrayList(*gio.File) = .empty;
    defer {
        for (parents.items) |f| u.unref(f);
        parents.deinit(a);
    }
    var current: ?*gio.File = u.ref(folder);
    while (current != null and parents.items.len < 4) {
        parents.append(a, current.?) catch @panic("Out of memory");
        current = current.?.getParent();
    }
    u.unref(current);
    var i = parents.items.len;
    while (i > 0) {
        i -= 1;
        const file = parents.items[i];
        const base = file.getBasename();
        defer glib.free(base);
        const display = glib.filenameDisplayName(base orelse "/");
        defer glib.free(display);
        const b = gtk.Button.newWithLabel(display).as(gtk.Widget);
        b.addCssClass("flat");
        u.ownedData(b, "folder", u.ref(file), &u.unrefData);
        u.connect(b, "clicked", &breadcrumbClicked, s);
        u.append(s.breadcrumbs_box, b);
        if (i != 0) u.append(s.breadcrumbs_box, gtk.Label.new(@import("i18n").dtr("pearl-files", "›")).as(gtk.Widget));
    }
}
fn navigate(s: *Chooser, folder: *gio.File) void {
    s.initial_generation +%= 1;
    s.accept_after_navigation = false;
    u.clear(&s.pending_selection);
    if (s.closed or s.busy) return;
    if (s.local_only and folder.isNative() == 0) {
        message(s, @import("i18n").dtr("pearl-files", "Choose a location stored on this computer."));
        return;
    }
    if (!s.navigating_history) {
        while (s.history.items.len > s.history_index + 1) u.unref(s.history.pop().?);
        if (s.history.items.len == 0 or s.history.items[s.history.items.len - 1].equal(folder) == 0) s.history.append(a, u.ref(folder)) catch @panic("Out of memory");
        if (s.history.items.len > 64) u.unref(s.history.orderedRemove(0));
        s.history_index = s.history.items.len - 1;
    }
    u.clear(&s.accepted);
    _ = cast(gtk.SelectionModel, s.selection).unselectAll();
    s.directory.setFile(folder);
    const path = folder.getParseName();
    defer glib.free(path);
    cast(gtk.Editable, s.location).setText(path);
    breadcrumbs(s, folder);
    refresh(s);
}
fn initial(s: *Chooser, file: *gio.File, activate: bool, folder_only: bool) void {
    s.initial_generation +%= 1;
    const job = u.new(Initial, .{ .dialog = u.ref(s.dialog), .generation = s.initial_generation, .activate = activate, .folder_only = folder_only });
    file.queryInfoAsync("standard::type", .{}, 0, s.cancel, &initialQueried, job);
}
fn enterLocation(entry: *gtk.Entry, s: *Chooser) callconv(.c) void {
    const file = gio.File.parseName(cast(gtk.Editable, entry).getText());
    defer u.unref(file);
    initial(s, file, true, false);
}
fn up(_: ?*gtk.Button, s: *Chooser) callconv(.c) void {
    const folder = s.directory.getFile() orelse return;
    const parent = folder.getParent() orelse return;
    defer u.unref(parent);
    navigate(s, parent);
}
fn back(_: ?*gtk.Button, s: *Chooser) callconv(.c) void {
    if (s.history_index == 0) return;
    s.navigating_history = true;
    defer s.navigating_history = false;
    s.history_index -= 1;
    navigate(s, s.history.items[s.history_index]);
}
fn place(b: *gtk.Button, s: *Chooser) callconv(.c) void {
    navigate(s, u.data(gio.File, b, "file").?);
}
fn addPlace(s: *Chooser, name: [*:0]const u8, file: *gio.File) void {
    var child = s.places.getFirstChild();
    while (child) |w| : (child = w.getNextSibling()) {
        if (u.data(gio.File, w, "file")) |existing| {
            if (existing.equal(file) != 0) return;
        }
    }
    const b = gtk.Button.newWithLabel(name).as(gtk.Widget);
    b.addCssClass("flat");
    u.ownedData(b, "file", u.ref(file), &u.unrefData);
    u.connect(b, "clicked", &place, s);
    u.append(s.places, b);
}
fn placesRefresh(s: *Chooser) void {
    while (s.places.getFirstChild()) |child| cast(gtk.Box, s.places).remove(child);
    const home = gio.File.newForPath(glib.getHomeDir());
    defer u.unref(home);
    addPlace(s, "Home", home);
    for (0..8) |i| {
        if (glib.getUserSpecialDir(@enumFromInt(i))) |path| {
            const f = gio.File.newForPath(path);
            defer u.unref(f);
            const base = f.getBasename();
            defer glib.free(base);
            const display = glib.filenameDisplayName(base orelse path);
            defer glib.free(display);
            addPlace(s, display, f);
        }
    }
    if (s.bookmarks) |text| {
        const lines = glib.strsplit(text, "\n", 129);
        defer glib.strfreev(lines);
        var i: usize = 0;
        while (i < 128 and lines[i] != null) : (i += 1) {
            const line = lines[i].?;
            if (line[0] == 0) continue;
            var caption: ?[*:0]const u8 = null;
            if (std.mem.indexOfScalar(u8, std.mem.span(line), ' ')) |space| {
                line[space] = 0;
                if (line[space + 1] != 0) caption = line + space + 1;
            }
            if (glib.Uri.peekScheme(line) == null) continue;
            const f = gio.File.newForUri(line);
            defer u.unref(f);
            const base = f.getBasename();
            defer glib.free(base);
            const display = if (base) |b| glib.filenameDisplayName(b) else glib.strdup(line);
            defer glib.free(display);
            addPlace(s, caption orelse display, f);
        }
    }
    if (s.phyto_bookmarks) |text| {
        const keys = glib.KeyFile.new();
        defer keys.unref();
        if (keys.loadFromData(text, std.mem.len(text), .{}, null) != 0) {
            var n: usize = 0;
            if (keys.getStringList("Files", "bookmarks", &n, null)) |uris| {
                defer glib.strfreev(uris);
                for (0..@min(n, 128)) |i| {
                    const uri = uris[i].?;
                    if (glib.Uri.peekScheme(uri) == null) continue;
                    const file = gio.File.newForUri(uri);
                    defer u.unref(file);
                    const hash = glib.computeChecksumForString(.sha256, uri, -1).?;
                    defer glib.free(hash);
                    const name = keys.getString("Bookmark names", hash, null);
                    defer glib.free(name);
                    const base = file.getBasename();
                    defer glib.free(base);
                    const display = glib.filenameDisplayName(base orelse uri);
                    defer glib.free(display);
                    addPlace(s, if (name != null and name.?[0] != 0) name.? else display, file);
                }
            }
        }
    }
    // The pinned GIR omits nullability for an empty GList. Correct only that
    // signature; the function and all object types still come from the bindings.
    const get_mounts: *const fn (*gio.VolumeMonitor) callconv(.c) ?*glib.List = @ptrCast(&gio.VolumeMonitor.getMounts);
    const mounts = get_mounts(s.mounts);
    defer if (mounts) |list| list.freeFull(&u.unrefData);
    var iter = mounts;
    while (iter) |node| : (iter = node.f_next) {
        const mount = cast(gio.Mount, node.f_data);
        const name = mount.getName();
        defer glib.free(name);
        const f = mount.getRoot();
        defer u.unref(f);
        addPlace(s, name, f);
    }
}
fn mountsChanged(_: *gio.VolumeMonitor, _: *gio.Mount, dialog: *gtk.Dialog) callconv(.c) void {
    const s = state(dialog);
    if (!s.closed) placesRefresh(s);
}
fn bookmarksRead(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const dialog = cast(gtk.Dialog, data);
    defer u.unref(dialog);
    const s = state(dialog);
    const bytes = cast(gio.InputStream, source).readBytesFinish(result, null) orelse return;
    defer bytes.unref();
    if (s.closed) return;
    var length: usize = 0;
    const raw = bytes.getData(&length);
    const text: [*]const u8 = raw orelse "";
    if (length <= 65536 and (length == 0 or glib.utf8Validate(text, @intCast(length), null) != 0)) {
        const storage = if (u.data(anyopaque, source, "phyto") != null) &s.phyto_bookmarks else &s.bookmarks;
        glib.free(storage.*);
        storage.* = glib.strndup(@ptrCast(text), length);
        placesRefresh(s);
    }
}
fn bookmarksOpened(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const dialog = cast(gtk.Dialog, data);
    defer u.unref(dialog);
    const s = state(dialog);
    const stream = cast(gio.File, source).readFinish(result, null) orelse return;
    defer u.unref(stream);
    if (!s.closed) {
        u.setData(stream, "phyto", u.data(anyopaque, source, "phyto"));
        cast(gio.InputStream, stream).readBytesAsync(65537, 0, s.cancel, &bookmarksRead, u.ref(dialog));
    }
}
fn bookmarksLoad(s: *Chooser) void {
    for ([_][]const u8{ "gtk-3.0/bookmarks", "phyto/preferences.ini" }, 0..) |relative, i| {
        const path = u.fmt("{s}/{s}", .{ glib.getUserConfigDir(), relative });
        defer a.free(path);
        const file = gio.File.newForPath(path);
        defer u.unref(file);
        if (i == 1) u.setData(file, "phyto", @ptrFromInt(1));
        file.readAsync(0, s.cancel, &bookmarksOpened, u.ref(s.dialog));
    }
}
fn bookmarksChanged(_: *gio.FileMonitor, _: *gio.File, _: ?*gio.File, _: gio.FileMonitorEvent, dialog: *gtk.Dialog) callconv(.c) void {
    const s = state(dialog);
    if (!s.closed) bookmarksLoad(s);
}
fn hiddenToggled(b: *gtk.ToggleButton, s: *Chooser) callconv(.c) void {
    s.hidden = b.getActive() != 0;
    changed(null, s);
}
fn sortToggled(b: *gtk.ToggleButton, s: *Chooser) callconv(.c) void {
    s.reverse = b.getActive() != 0;
    cast(gtk.Sorter, s.sorter).changed(.different);
}
fn sortChanged(dropdown: *gtk.DropDown, _: *object.ParamSpec, s: *Chooser) callconv(.c) void {
    s.sort_kind = dropdown.getSelected();
    cast(gtk.Sorter, s.sorter).changed(.different);
}
fn previewToggled(b: *gtk.ToggleButton, s: *Chooser) callconv(.c) void {
    s.show_preview = b.getActive() != 0;
}
fn fileFactory(s: *Chooser) *gtk.ListItemFactory {
    const factory = gtk.SignalListItemFactory.new();
    u.connect(factory, "setup", &setup, s);
    u.connect(factory, "bind", &bind, s);
    u.connect(factory, "unbind", &unbind, s);
    return factory.as(gtk.ListItemFactory);
}
fn listToggled(b: *gtk.ToggleButton, s: *Chooser) callconv(.c) void {
    s.list_mode = b.getActive() != 0;
    const factory = fileFactory(s);
    defer u.unref(factory);
    cast(gtk.GridView, s.grid).setFactory(factory);
    cast(gtk.GridView, s.grid).setMaxColumns(if (s.list_mode) 1 else 12);
}
fn validationFree(v: *Validation) void {
    u.unref(v.existing);
    u.unref(v.files);
    u.unref(v.dialog);
    a.destroy(v);
}
fn validationFail(v: *Validation, text: [*:0]const u8) void {
    const s = state(v.dialog);
    s.busy = false;
    if (!s.closed) {
        refresh(s);
        message(s, text);
    }
    validationFree(v);
}
fn replacementChecked(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const v = cast(Validation, data);
    const s = state(v.dialog);
    const info = cast(gio.File, source).queryInfoFinish(result, null);
    defer u.unref(info);
    if (s.closed) {
        validationFree(v);
        return;
    }
    const before = v.existing.?.getAttributeString("etag::value");
    const after = if (info) |f| f.getAttributeString("etag::value") else null;
    if (info == null or before == null or glib.strcmp0(before, after) != 0) {
        validationFail(v, "The destination changed or cannot be verified. Review it and try again.");
        return;
    }
    u.clear(&v.existing);
    v.index += 1;
    validateNext(v);
}
fn replacementChosen(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const v = cast(Validation, data);
    const s = state(v.dialog);
    const choice = cast(gtk.AlertDialog, source).chooseFinish(result, null);
    if (s.closed) {
        validationFree(v);
        return;
    }
    if (choice != 1) {
        validationFail(v, "Replacement cancelled. Choose another name or destination.");
        return;
    }
    const file = u.modelItem(gio.File, v.files, v.index).?;
    defer u.unref(file);
    file.queryInfoAsync(attributes, .{}, 0, s.cancel, &replacementChecked, v);
}
fn validated(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const v = cast(Validation, data);
    const s = state(v.dialog);
    var err: ?*glib.Error = null;
    defer if (err) |e| e.free();
    const info = cast(gio.File, source).queryInfoFinish(result, &err);
    defer u.unref(info);
    if (s.closed) {
        validationFree(v);
        return;
    }
    const saving = s.action == .save or s.batch.items.len > 0;
    const missing = if (err) |e| e.matches(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.not_found)) != 0 else false;
    if (info == null and !(saving and missing)) {
        validationFail(v, "The selected file is no longer accessible. Refresh the location and try again.");
        return;
    }
    if (info) |f| {
        const folder = f.getFileType() == .directory;
        if ((saving and folder) or (!saving and folder != (s.action == .select_folder))) {
            validationFail(v, "The selection has the wrong file type.");
            return;
        }
        if (!saving and f.hasAttribute("access::can-read") != 0 and f.getAttributeBoolean("access::can-read") == 0) {
            validationFail(v, "The selection is no longer readable.");
            return;
        }
        if (!saving and !folder and match(cast(object.Object, f), s) == 0) {
            validationFail(v, "The selection no longer matches the requested file type.");
            return;
        }
        if (saving) {
            v.existing = u.ref(f);
            const alert = gtk.AlertDialog.new("Replace the existing file?");
            defer u.unref(alert);
            alert.setDetail(f.getDisplayName());
            const buttons = [_:null]?[*:0]const u8{ "Cancel", "Replace" };
            alert.setButtons(@ptrCast(&buttons));
            alert.setCancelButton(0);
            alert.setDefaultButton(0);
            alert.choose(cast(gtk.Window, s.dialog), s.cancel, &replacementChosen, v);
            return;
        }
    }
    v.index += 1;
    validateNext(v);
}
fn validateNext(v: *Validation) void {
    const s = state(v.dialog);
    if (s.closed) {
        validationFree(v);
        return;
    }
    if (v.index == u.count(v.files)) {
        u.clear(&s.accepted);
        s.accepted = u.ref(v.files);
        s.busy = false;
        s.dialog.response(accepted_response);
        validationFree(v);
        return;
    }
    const file = u.modelItem(gio.File, v.files, v.index).?;
    defer u.unref(file);
    if (s.local_only and file.isNative() == 0) {
        validationFail(v, "Choose a file stored on this computer.");
        return;
    }
    file.queryInfoAsync(attributes, .{}, 0, s.cancel, &validated, v);
}
fn destinationChecked(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const v = cast(Validation, data);
    const s = state(v.dialog);
    const info = cast(gio.File, source).queryInfoFinish(result, null);
    defer u.unref(info);
    if (s.closed) {
        validationFree(v);
        return;
    }
    if (info == null or info.?.getFileType() != .directory or (info.?.hasAttribute("access::can-write") != 0 and info.?.getAttributeBoolean("access::can-write") == 0)) {
        validationFail(v, "The destination folder is unavailable or read-only.");
        return;
    }
    validateNext(v);
}
fn accept(_: ?*gtk.Button, s: *Chooser) callconv(.c) void {
    if (s.busy or s.closed or s.accept_button.getSensitive() == 0) return;
    const folder = s.directory.getFile() orelse return;
    const v = u.new(Validation, .{ .dialog = u.ref(s.dialog), .files = gio.ListStore.new(gio.File.getGObjectType()) });
    if (s.batch.items.len > 0 or s.action == .save) {
        const count = @max(s.batch.items.len, 1);
        for (0..count) |i| {
            const name = entryName(if (s.batch.items.len > 0) s.batch.items[i] else s.name);
            if (!validName(name)) {
                validationFail(v, "Enter a filename without directory separators.");
                return;
            }
            const file = folder.getChild(name);
            defer u.unref(file);
            u.listAppend(v.files, file);
        }
    } else {
        const bits = cast(gtk.SelectionModel, s.selection).getSelection();
        defer bits.unref();
        var iter: gtk.BitsetIter = undefined;
        var index: c_uint = 0;
        var ok = iter.initFirst(bits, &index);
        while (ok != 0) : (ok = iter.next(&index)) {
            const info = u.modelItem(gio.FileInfo, s.sorted, index) orelse continue;
            defer u.unref(info);
            if (infoFile(info)) |file| u.listAppend(v.files, file);
        }
        if (s.action == .select_folder and u.count(v.files) == 0) u.listAppend(v.files, folder);
    }
    if (u.count(v.files) == 0) {
        validationFail(v, "Select a file first.");
        return;
    }
    s.busy = true;
    s.accept_button.setSensitive(0);
    if (s.action == .save or s.batch.items.len > 0) folder.queryInfoAsync(attributes, .{}, 0, s.cancel, &destinationChecked, v) else validateNext(v);
}
fn activated(_: *gtk.GridView, pos: c_uint, s: *Chooser) callconv(.c) void {
    const info = u.modelItem(gio.FileInfo, s.sorted, pos) orelse return;
    defer u.unref(info);
    if (info.getFileType() == .directory and infoFile(info) != null) navigate(s, infoFile(info).?) else {
        _ = cast(gtk.SelectionModel, s.selection).selectItem(pos, 1);
        accept(null, s);
    }
}
fn mkdirDone(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const dialog = cast(gtk.Dialog, data);
    defer u.unref(dialog);
    const s = state(dialog);
    const file = cast(gio.File, source);
    const ok = file.makeDirectoryFinish(result, null) != 0;
    if (!s.closed) {
        s.busy = false;
        if (ok) navigate(s, file) else {
            refresh(s);
            message(s, @import("i18n").dtr("pearl-files", "Could not create that folder. Check its name and permissions."));
        }
    }
}
fn newFolderResponse(dialog: *gtk.Dialog, response: c_int, owner: *gtk.Dialog) callconv(.c) void {
    const s = state(owner);
    const entry = u.data(gtk.Editable, dialog, "entry").?;
    const name = entry.getText();
    if (response == accepted_response and !s.closed and validName(name)) {
        if (s.directory.getFile()) |folder| {
            const file = folder.getChild(name);
            defer u.unref(file);
            s.busy = true;
            refresh(s);
            file.makeDirectoryAsync(0, s.cancel, &mkdirDone, u.ref(owner));
        }
    }
    cast(gtk.Window, dialog).destroy();
}
fn newFolder(_: ?*gtk.Button, s: *Chooser) callconv(.c) void {
    if (s.busy) return;
    const d = cast(gtk.Dialog, gtk.Dialog.new());
    const w = cast(gtk.Window, d);
    w.setTitle(@import("i18n").dtr("pearl-files", "New folder"));
    w.setTransientFor(cast(gtk.Window, s.dialog));
    w.setModal(1);
    w.setDestroyWithParent(1);
    _ = d.addButton("Cancel", cancelled_response);
    _ = d.addButton("Create", accepted_response);
    const entry = gtk.Entry.new().as(gtk.Widget);
    cast(gtk.Entry, entry).setPlaceholderText(@import("i18n").dtr("pearl-files", "Folder name"));
    u.append(d.getContentArea(), entry);
    style.apply(w);
    u.setData(d, "entry", entry);
    u.ownedData(d, "owner", u.ref(s.dialog), &u.unrefData);
    u.connect(d, "response", &newFolderResponse, s.dialog);
    w.present();
}
fn cancelClicked(_: ?*gtk.Button, s: *Chooser) callconv(.c) void {
    s.dialog.response(cancelled_response);
}
fn reflow(widget: W, _: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
    const s = cast(Chooser, data);
    const width = widget.getWidth();
    if (width <= 0) return 1;
    const preview_visible = s.show_preview and width >= 1040;
    if ((s.preview_box.getVisible() != 0) != preview_visible) {
        s.preview_box.setVisible(@intFromBool(preview_visible));
        previews.pearl_preview_unwatch(s.preview_watch);
        s.preview_watch = null;
        if (preview_visible) {
            const bits = cast(gtk.SelectionModel, s.selection).getSelection();
            defer bits.unref();
            if (bits.getSize() == 1) {
                if (u.modelItem(gio.FileInfo, s.sorted, bits.getMinimum())) |info| {
                    defer u.unref(info);
                    s.preview_watch = previews.pearl_preview_watch(info, 512, &previewReady, s);
                }
            }
        }
    }
    const narrow = width < 680;
    s.places_button.setVisible(@intFromBool(narrow));
    if (narrow and s.places_scroll.getParent() == s.panes) {
        _ = u.ref(s.places_scroll);
        defer u.unref(s.places_scroll);
        cast(gtk.Box, s.panes).remove(s.places_scroll);
        cast(gtk.Popover, s.places_popup).setChild(s.places_scroll);
    } else if (!narrow and s.places_scroll.getParent() != s.panes) {
        _ = u.ref(s.places_scroll);
        defer u.unref(s.places_scroll);
        cast(gtk.Popover, s.places_popup).setChild(null);
        cast(gtk.Box, s.panes).prepend(s.places_scroll);
    }
    return 1;
}
fn key(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, mods: gdk.ModifierType, s: *Chooser) callconv(.c) c_int {
    if (keyval == gdk.KEY_Escape) {
        if (cast(gtk.Window, s.dialog).getFocus()) |focus| {
            if (focus.getAncestor(gtk.Popover.getGObjectType())) |popup| {
                cast(gtk.Popover, popup).popdown();
                return 1;
            }
        }
        s.dialog.response(cancelled_response);
        return 1;
    }
    if (keyval == gdk.KEY_F5 and !s.busy) {
        if (s.directory.getFile()) |current| {
            _ = u.ref(current);
            defer u.unref(current);
            s.directory.setFile(null);
            navigate(s, current);
        }
        return 1;
    }
    if (mods.control_mask) {
        if (keyval == gdk.KEY_Return) {
            accept(null, s);
            return 1;
        }
        if (keyval == gdk.KEY_l) {
            _ = s.location.grabFocus();
            cast(gtk.Editable, s.location).selectRegion(0, -1);
            return 1;
        }
        if (keyval == gdk.KEY_f) {
            _ = s.search.grabFocus();
            return 1;
        }
        if (keyval == gdk.KEY_h) {
            cast(gtk.ToggleButton, s.hidden_toggle).setActive(@intFromBool(!s.hidden));
            return 1;
        }
    }
    if (mods.alt_mask and keyval == gdk.KEY_Up) {
        up(null, s);
        return 1;
    }
    if (mods.alt_mask and keyval == gdk.KEY_Left) {
        back(null, s);
        return 1;
    }
    return 0;
}
fn button(box: W, text: [*:0]const u8, callback: anytype, s: *Chooser) W {
    const icon: ?[*:0]const u8 = if (u.eql(text, "Back")) "go-previous-symbolic" else if (u.eql(text, "Up")) "go-up-symbolic" else if (u.eql(text, "New folder")) "folder-new-symbolic" else null;
    const w = if (icon) |name| gtk.Button.newFromIconName(name).as(gtk.Widget) else gtk.Button.newWithLabel(text).as(gtk.Widget);
    w.setTooltipText(text);
    u.accessibleLabel(w, text);
    u.append(box, w);
    u.connect(w, "clicked", callback, s);
    return w;
}
var helper_configured = false;
pub fn initPreviews() callconv(.c) void {
    if (helper_configured) return;
    helper_configured = true;
    if (glib.fileReadLink("/proc/self/exe", null)) |executable| {
        defer glib.free(executable);
        const dir = glib.pathGetDirname(executable);
        defer glib.free(dir);
        const path = u.fmt("{s}/pearl-preview-helper", .{dir});
        defer a.free(path);
        if (glib.fileTest(path, .{ .is_executable = true }) != 0) {
            previews.pearl_preview_set_helper(path);
            return;
        }
    }
    previews.pearl_preview_set_helper(@import("chooser_options").helper_path);
}
fn rememberState(dialog: *gtk.Dialog, response: c_int, _: ?*anyopaque) callconv(.c) void {
    const s = state(dialog);
    const state_key = s.state_key orelse return;
    var folder: ?[*:0]u8 = null;
    defer glib.free(folder);
    if (response == accepted_response) {
        if (s.directory.getFile()) |file| folder = file.getUri();
    }
    preferences.save(state_key, .{ .list = s.list_mode, .hidden = s.hidden, .reverse = s.reverse, .preview = s.show_preview, .sort = s.sort_kind, .folder = folder });
}
pub fn create(title: [*:0]const u8, action: gtk.FileChooserAction) callconv(.c) *gtk.Dialog {
    gtk.Widget.setDefaultDirection(if (@import("i18n").rtl()) .rtl else .ltr);
    initPreviews();
    const dialog = cast(gtk.Dialog, gtk.Dialog.new());
    const s = u.new(Chooser, .{ .dialog = dialog, .action = action, .cancel = gio.Cancellable.new() });
    u.ownedData(dialog, "pearl-chooser", s, &cleanup);
    u.connect(dialog, "destroy", &closed, null);
    u.connect(dialog, "unmap", &closed, null);
    u.connect(dialog, "response", &rememberState, null);
    const window = cast(gtk.Window, dialog);
    window.setTitle(title);
    window.setDefaultSize(1040, 680);
    cast(gtk.Widget, dialog).addCssClass("pearl-file-chooser");
    style.apply(window);
    const body = cast(gtk.Widget, dialog.getContentArea());
    cast(gtk.Box, body).setSpacing(10);
    body.setMarginStart(16);
    body.setMarginEnd(16);
    body.setMarginTop(12);
    body.setMarginBottom(12);
    s.caller = u.label("");
    s.caller.addCssClass("dim-label");
    s.caller.setVisible(0);
    u.append(body, s.caller);
    const nav = gtk.Box.new(.horizontal, 6).as(gtk.Widget);
    u.append(body, nav);
    s.places_button = gtk.MenuButton.new().as(gtk.Widget);
    cast(gtk.MenuButton, s.places_button).setIconName("sidebar-show-symbolic");
    s.places_button.setTooltipText(@import("i18n").dtr("pearl-files", "Places"));
    s.places_popup = gtk.Popover.new().as(gtk.Widget);
    cast(gtk.MenuButton, s.places_button).setPopover(cast(gtk.Popover, s.places_popup));
    s.places_button.setVisible(0);
    u.append(nav, s.places_button);
    _ = button(nav, "Back", &back, s);
    _ = button(nav, "Up", &up, s);
    s.location = gtk.Entry.new().as(gtk.Widget);
    cast(gtk.Editable, s.location).setWidthChars(1);
    s.location.setHexpand(1);
    u.append(nav, s.location);
    u.accessibleLabel(s.location, "Location");
    u.connect(s.location, "activate", &enterLocation, s);
    _ = button(nav, "New folder", &newFolder, s);
    s.breadcrumbs_box = gtk.Box.new(.horizontal, 2).as(gtk.Widget);
    const crumb_scroll = gtk.ScrolledWindow.new().as(gtk.Widget);
    cast(gtk.ScrolledWindow, crumb_scroll).setPolicy(.automatic, .never);
    cast(gtk.ScrolledWindow, crumb_scroll).setChild(s.breadcrumbs_box);
    u.append(body, crumb_scroll);
    const toolbar = gtk.Box.new(.horizontal, 6).as(gtk.Widget);
    u.append(body, toolbar);
    s.search = gtk.SearchEntry.new().as(gtk.Widget);
    cast(gtk.Editable, s.search).setWidthChars(1);
    s.search.setHexpand(1);
    u.append(toolbar, s.search);
    const view_menu = gtk.MenuButton.new().as(gtk.Widget);
    cast(gtk.MenuButton, view_menu).setLabel(@import("i18n").dtr("pearl-files", "View"));
    const view_popup = gtk.Popover.new().as(gtk.Widget);
    const view_options = gtk.Box.new(.vertical, 6).as(gtk.Widget);
    cast(gtk.Popover, view_popup).setChild(view_options);
    cast(gtk.MenuButton, view_menu).setPopover(cast(gtk.Popover, view_popup));
    u.append(toolbar, view_menu);
    u.append(view_options, u.label(@import("i18n").dtr("pearl-files", "Sort by")));
    const sort_names = [_:null]?[*:0]const u8{ "Name", "Modified", "Size", "Type" };
    s.sort_menu = gtk.DropDown.newFromStrings(@ptrCast(&sort_names)).as(gtk.Widget);
    s.sort_menu.setTooltipText(@import("i18n").dtr("pearl-files", "Sort by"));
    u.append(view_options, s.sort_menu);
    s.hidden_toggle = gtk.ToggleButton.newWithLabel("Hidden").as(gtk.Widget);
    u.append(view_options, s.hidden_toggle);
    u.connect(s.hidden_toggle, "toggled", &hiddenToggled, s);
    s.sort_toggle = gtk.ToggleButton.newWithLabel("Reverse").as(gtk.Widget);
    u.append(view_options, s.sort_toggle);
    u.connect(s.sort_toggle, "toggled", &sortToggled, s);
    s.list_toggle = gtk.ToggleButton.newWithLabel("List").as(gtk.Widget);
    u.append(toolbar, s.list_toggle);
    u.connect(s.list_toggle, "toggled", &listToggled, s);
    s.preview_toggle = gtk.ToggleButton.newWithLabel("Selection preview").as(gtk.Widget);
    cast(gtk.ToggleButton, s.preview_toggle).setActive(1);
    u.append(view_options, s.preview_toggle);
    u.connect(s.preview_toggle, "toggled", &previewToggled, s);
    s.panes = gtk.Box.new(.horizontal, 12).as(gtk.Widget);
    s.panes.setVexpand(1);
    u.append(body, s.panes);
    s.places = gtk.Box.new(.vertical, 4).as(gtk.Widget);
    s.places_scroll = gtk.ScrolledWindow.new().as(gtk.Widget);
    cast(gtk.ScrolledWindow, s.places_scroll).setChild(s.places);
    s.places_scroll.setSizeRequest(130, -1);
    u.append(s.panes, s.places_scroll);
    const home = gio.File.newForPath(glib.getHomeDir());
    defer u.unref(home);
    s.mounts = gio.VolumeMonitor.get();
    placesRefresh(s);
    for ([_][*:0]const u8{ "mount-added", "mount-removed", "mount-changed" }) |signal| u.connectObject(s.mounts, signal, &mountsChanged, dialog);
    for ([_][]const u8{ "gtk-3.0/bookmarks", "phyto/preferences.ini" }, 0..) |relative, i| {
        const path = u.fmt("{s}/{s}", .{ glib.getUserConfigDir(), relative });
        defer a.free(path);
        const file = gio.File.newForPath(path);
        defer u.unref(file);
        const monitor = file.monitorFile(.{}, s.cancel, null);
        if (i == 0) s.bookmark_monitor = monitor else s.phyto_monitor = monitor;
        if (monitor) |m| u.connectObject(m, "changed", &bookmarksChanged, dialog);
    }
    bookmarksLoad(s);
    s.directory = gtk.DirectoryList.new(attributes, null);
    s.directory.setMonitored(1);
    s.filter = gtk.CustomFilter.new(&match, s, null);
    s.filtered = gtk.FilterListModel.new(cast(gio.ListModel, u.ref(s.directory)), cast(gtk.Filter, u.ref(s.filter)));
    s.sorter = gtk.CustomSorter.new(&compare, s, null);
    s.sorted = gtk.SortListModel.new(cast(gio.ListModel, u.ref(s.filtered)), cast(gtk.Sorter, u.ref(s.sorter)));
    s.selection = gtk.MultiSelection.new(cast(gio.ListModel, u.ref(s.sorted)));
    s.grid = gtk.GridView.new(cast(gtk.SelectionModel, u.ref(s.selection)), fileFactory(s)).as(gtk.Widget);
    cast(gtk.GridView, s.grid).setMinColumns(1);
    cast(gtk.GridView, s.grid).setMaxColumns(12);
    const scroll = gtk.ScrolledWindow.new().as(gtk.Widget);
    cast(gtk.ScrolledWindow, scroll).setChild(s.grid);
    scroll.setHexpand(1);
    scroll.setVexpand(1);
    u.append(s.panes, scroll);
    s.preview_box = gtk.Box.new(.vertical, 8).as(gtk.Widget);
    s.preview = gtk.Picture.new().as(gtk.Widget);
    cast(gtk.Picture, s.preview).setContentFit(.contain);
    cast(gtk.Picture, s.preview).setCanShrink(1);
    s.preview.setSizeRequest(180, 180);
    u.append(s.preview_box, s.preview);
    s.preview_label = u.label("");
    cast(gtk.Label, s.preview_label).setMaxWidthChars(24);
    u.append(s.preview_box, s.preview_label);
    u.append(s.panes, s.preview_box);
    s.name = gtk.Entry.new().as(gtk.Widget);
    cast(gtk.Entry, s.name).setPlaceholderText(@import("i18n").dtr("pearl-files", "Filename"));
    u.accessibleLabel(s.name, "Filename");
    u.append(body, s.name);
    s.name.setVisible(@intFromBool(action == .save));
    s.batch_box = gtk.Box.new(.vertical, 4).as(gtk.Widget);
    u.append(body, s.batch_box);
    s.choices_box = gtk.Box.new(.vertical, 4).as(gtk.Widget);
    u.append(body, s.choices_box);
    s.filters = gio.ListStore.new(gtk.FileFilter.getGObjectType());
    const expression = gtk.PropertyExpression.new(gtk.FileFilter.getGObjectType(), null, "name");
    s.filter_menu = gtk.DropDown.new(cast(gio.ListModel, u.ref(s.filters)), cast(gtk.Expression, expression)).as(gtk.Widget);
    s.filter_menu.setVisible(0);
    u.append(body, s.filter_menu);
    s.status = u.label("");
    s.status.addCssClass("dim-label");
    u.append(body, s.status);
    const footer = gtk.Box.new(.horizontal, 8).as(gtk.Widget);
    footer.setHalign(.end);
    u.append(body, footer);
    _ = button(footer, "Cancel", &cancelClicked, s);
    // Validate asynchronously before emitting a response; this is not a Dialog action.
    s.accept_button = gtk.Button.newWithLabel(if (action == .save) @import("i18n").dtr("pearl-files", "Save") else @import("i18n").dtr("pearl-files", "Select")).as(gtk.Widget);
    s.accept_button.addCssClass("suggested-action");
    u.append(footer, s.accept_button);
    u.connect(s.accept_button, "clicked", &accept, s);
    u.connect(s.search, "search-changed", &changed, s);
    u.connect(s.name, "changed", &changed, s);
    u.connect(s.filter_menu, "notify::selected", &filterChanged, s);
    u.connect(s.directory, "notify::loading", &directoryChanged, s);
    u.connect(s.directory, "notify::error", &directoryChanged, s);
    u.connect(s.sorted, "items-changed", &itemsChanged, s);
    u.connect(s.selection, "selection-changed", &selectionChanged, s);
    u.connect(s.grid, "activate", &activated, s);
    u.connect(s.sort_menu, "notify::selected", &sortChanged, s);
    const keys = gtk.EventControllerKey.new();
    cast(gtk.EventController, keys).setPropagationPhase(.capture);
    u.connect(keys, "key-pressed", &key, s);
    cast(gtk.Widget, dialog).addController(cast(gtk.EventController, keys));
    _ = cast(gtk.Widget, dialog).addTickCallback(&reflow, s, null);
    navigate(s, home);
    return dialog;
}
pub fn setStateKey(dialog: *gtk.Dialog, state_key: [*:0]const u8) callconv(.c) void {
    const s = state(dialog);
    if (state_key[0] == 0 or std.mem.len(state_key) > 512) return;
    glib.free(s.state_key);
    s.state_key = glib.computeChecksumForString(.sha256, state_key, -1);
    const prefs = preferences.load(s.state_key.?);
    defer glib.free(prefs.folder);
    cast(gtk.ToggleButton, s.hidden_toggle).setActive(@intFromBool(prefs.hidden));
    cast(gtk.ToggleButton, s.sort_toggle).setActive(@intFromBool(prefs.reverse));
    cast(gtk.ToggleButton, s.list_toggle).setActive(@intFromBool(prefs.list));
    cast(gtk.ToggleButton, s.preview_toggle).setActive(@intFromBool(prefs.preview));
    cast(gtk.DropDown, s.sort_menu).setSelected(prefs.sort);
    if (prefs.folder) |uri| {
        const folder = gio.File.newForUri(uri);
        defer u.unref(folder);
        initial(s, folder, false, true);
    }
}
pub fn setFolder(dialog: *gtk.Dialog, file: *gio.File) callconv(.c) void {
    navigate(state(dialog), file);
}
fn initialQueried(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job = cast(Initial, data);
    defer {
        u.unref(job.dialog);
        a.destroy(job);
    }
    const s = state(job.dialog);
    const file = cast(gio.File, source);
    const info = file.queryInfoFinish(result, null);
    defer u.unref(info);
    if (!s.closed and job.generation == s.initial_generation and (!job.folder_only or (info != null and info.?.getFileType() == .directory))) {
        if (info != null and info.?.getFileType() == .directory) navigate(s, file) else {
            if (file.getParent()) |parent| {
                defer u.unref(parent);
                navigate(s, parent);
            }
            u.clear(&s.pending_selection);
            s.pending_selection = u.ref(file);
            if (s.action == .save) {
                if (file.getBasename()) |name| {
                    defer glib.free(name);
                    entryBytes(s.name, name);
                }
            }
            s.accept_after_navigation = job.activate;
            itemsChanged(cast(gio.ListModel, s.sorted), 0, 0, 0, s);
        }
    }
}
pub fn setFile(d: *gtk.Dialog, f: *gio.File) callconv(.c) void {
    initial(state(d), f, false, false);
}
pub fn setName(d: *gtk.Dialog, name: [*:0]const u8) callconv(.c) void {
    cast(gtk.Editable, state(d).name).setText(name);
}
pub fn setMultiple(d: *gtk.Dialog, value: c_int) callconv(.c) void {
    state(d).multiple = value != 0;
    refresh(state(d));
}
pub fn setLocalOnly(d: *gtk.Dialog, value: c_int) callconv(.c) void {
    state(d).local_only = value != 0;
}
pub fn setAcceptLabel(d: *gtk.Dialog, text: [*:0]const u8) callconv(.c) void {
    cast(gtk.Button, state(d).accept_button).setLabel(text);
}
pub fn setCaller(d: *gtk.Dialog, name: [*:0]const u8) callconv(.c) void {
    const s = state(d);
    cast(gtk.Label, s.caller).setText(name);
    s.caller.setVisible(@intFromBool(name[0] != 0));
}
pub fn addFilter(d: *gtk.Dialog, filter: *gtk.FileFilter) callconv(.c) void {
    const s = state(d);
    u.listAppend(s.filters, filter);
    s.filter_menu.setVisible(1);
    cast(gtk.Filter, s.filter).changed(.different);
}
pub fn setFilter(d: *gtk.Dialog, filter: *gtk.FileFilter) callconv(.c) void {
    const s = state(d);
    var index: c_uint = 0;
    if (s.filters.find(cast(object.Object, filter), &index) != 0) cast(gtk.DropDown, s.filter_menu).setSelected(index);
}
pub fn getFilter(d: *gtk.Dialog) callconv(.c) ?*gtk.FileFilter {
    return if (cast(gtk.DropDown, state(d).filter_menu).getSelectedItem()) |item| cast(gtk.FileFilter, item) else null;
}
pub fn getFiles(d: *gtk.Dialog) callconv(.c) ?*gio.ListModel {
    return if (state(d).accepted) |files| cast(gio.ListModel, u.ref(files)) else null;
}
pub fn getFile(d: *gtk.Dialog) callconv(.c) ?*gio.File {
    return if (state(d).accepted) |files| u.modelItem(gio.File, files, 0) else null;
}
fn invalid(err: ?*?*glib.Error, text: [*:0]const u8) c_int {
    glib.setErrorLiteral(@ptrCast(err), gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.invalid_argument), text);
    return 0;
}
pub fn setBatch(d: *gtk.Dialog, names: *glib.Variant, err: ?*?*glib.Error) callconv(.c) c_int {
    const s = state(d);
    const ty = glib.VariantType.new("aay");
    defer ty.free();
    if (names.isOfType(ty) == 0 or names.nChildren() == 0 or names.nChildren() > 128) return invalid(err, "Invalid batch filenames");
    for (0..names.nChildren()) |i| {
        const child = names.getChildValue(i);
        defer child.unref();
        var size: usize = 0;
        const bytes: [*]const u8 = @ptrCast(child.getFixedArray(&size, 1));
        if (size == 0 or size > 256 or bytes[size - 1] != 0 or std.mem.indexOfScalar(u8, bytes[0 .. size - 1], 0) != null) return invalid(err, "Invalid batch filenames");
        if (!validName(@ptrCast(bytes))) return invalid(err, "Invalid batch filenames");
    }
    s.name.setVisible(0);
    for (0..names.nChildren()) |i| {
        const child = names.getChildValue(i);
        defer child.unref();
        const entry = gtk.Entry.new().as(gtk.Widget);
        entryBytes(entry, @ptrCast(child.getBytestring()));
        u.append(s.batch_box, entry);
        s.batch.append(a, entry) catch @panic("Out of memory");
        u.connect(entry, "changed", &changed, s);
    }
    refresh(s);
    return 1;
}
pub fn setChoices(d: *gtk.Dialog, choices: *glib.Variant, err: ?*?*glib.Error) callconv(.c) c_int {
    const s = state(d);
    const ty = glib.VariantType.new("a(ssa(ss)s)");
    defer ty.free();
    if (choices.isOfType(ty) == 0 or choices.nChildren() > 32) return invalid(err, "Invalid application choices");
    for (0..choices.nChildren()) |i| {
        const row = choices.getChildValue(i);
        defer row.unref();
        const id_v = row.getChildValue(0);
        defer id_v.unref();
        const title_v = row.getChildValue(1);
        defer title_v.unref();
        const options = row.getChildValue(2);
        defer options.unref();
        const selected_v = row.getChildValue(3);
        defer selected_v.unref();
        const id = id_v.getString(null);
        const title = title_v.getString(null);
        const selected = selected_v.getString(null);
        if (id[0] == 0 or std.mem.len(title) > 512 or options.nChildren() > 128) return invalid(err, "Invalid application choices");
        for (s.choices.items) |prior| {
            if (u.eql(prior.id, id)) return invalid(err, "Invalid application choices");
        }
        var choice = Choice{ .id = glib.strdup(id), .widget = undefined };
        var stored = false;
        defer if (!stored) choice.deinit();
        if (options.nChildren() == 0) {
            if (!u.eql(selected, "true") and !u.eql(selected, "false")) return invalid(err, "Invalid application choices");
            choice.widget = gtk.CheckButton.newWithLabel(title).as(gtk.Widget);
            cast(gtk.CheckButton, choice.widget).setActive(@intFromBool(u.eql(selected, "true")));
        } else {
            const labels = gtk.StringList.new(null);
            var transferred = false;
            defer if (!transferred) u.unref(labels);
            var chosen: ?c_uint = null;
            for (0..options.nChildren()) |j| {
                const option = options.getChildValue(j);
                defer option.unref();
                const value_v = option.getChildValue(0);
                defer value_v.unref();
                const caption_v = option.getChildValue(1);
                defer caption_v.unref();
                const value = value_v.getString(null);
                choice.values.append(a, glib.strdup(value)) catch @panic("Out of memory");
                labels.append(caption_v.getString(null));
                if (u.eql(value, selected)) chosen = @intCast(j);
            }
            if (chosen == null and selected[0] != 0) return invalid(err, "Invalid application choices");
            choice.widget = gtk.DropDown.new(cast(gio.ListModel, labels), null).as(gtk.Widget);
            transferred = true;
            cast(gtk.DropDown, choice.widget).setSelected(chosen orelse 0);
            u.append(s.choices_box, u.label(title));
        }
        u.append(s.choices_box, choice.widget);
        s.choices.append(a, choice) catch @panic("Out of memory");
        stored = true;
    }
    return 1;
}
pub fn getChoices(d: *gtk.Dialog) callconv(.c) *glib.Variant {
    const ty = glib.VariantType.new("a(ss)");
    defer ty.free();
    const builder = glib.VariantBuilder.new(ty);
    defer builder.unref();
    for (state(d).choices.items) |choice| {
        const value: [*:0]const u8 = if (choice.values.items.len > 0) choice.values.items[cast(gtk.DropDown, choice.widget).getSelected()] else if (cast(gtk.CheckButton, choice.widget).getActive() != 0) "true" else "false";
        builder.add("(ss)", choice.id, @as([*:0]const u8, value));
    }
    return builder.end();
}
fn asyncResponse(dialog: *gtk.Dialog, response: c_int, task: *gio.Task) callconv(.c) void {
    if (u.data(anyopaque, dialog, "pearl-async-done") != null) return;
    u.setData(dialog, "pearl-async-done", @ptrFromInt(1));
    if (response == accepted_response) {
        if (getFiles(dialog)) |files| task.returnPointer(files, &u.unrefData) else task.returnNewError(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.failed), "No selection");
    } else task.returnNewError(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.cancelled), "Selection cancelled");
    cast(gtk.Window, dialog).destroy();
    u.unref(task);
}
fn asyncDestroyed(dialog: W, task: *gio.Task) callconv(.c) void {
    if (u.data(anyopaque, dialog, "pearl-async-done") != null) return;
    u.setData(dialog, "pearl-async-done", @ptrFromInt(1));
    task.returnNewError(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.cancelled), "Parent window closed");
    u.unref(task);
}
fn asyncParentDestroyed(_: W, dialog: *gtk.Dialog) callconv(.c) void {
    if (u.data(anyopaque, dialog, "pearl-async-done") == null) dialog.response(cancelled_response);
}
fn asyncOpen(parent: ?*gtk.Window, action: gtk.FileChooserAction, multiple: c_int, name: ?[*:0]const u8, callback: ?gio.AsyncReadyCallback, data: ?*anyopaque) void {
    const d = create(if (action == .save) @import("i18n").dtr("pearl-files", "Save document") else @import("i18n").dtr("pearl-files", "Open files"), action);
    const app = gio.Application.getDefault();
    const id = if (app) |application| application.getApplicationId() else null;
    const state_key = u.fmt("first-party/{s}/{d}", .{ id orelse "Pearl", @intFromEnum(action) });
    defer a.free(state_key);
    setStateKey(d, state_key);
    const w = cast(gtk.Window, d);
    if (parent) |p| w.setDisplay(cast(gtk.Widget, p).getDisplay());
    w.setTransientFor(parent);
    w.setModal(1);
    w.setDestroyWithParent(1);
    setMultiple(d, multiple);
    if (name) |n| setName(d, n);
    const task = gio.Task.new(cast(object.Object, d), null, callback, data);
    if (parent) |p| u.connectObject(p, "destroy", &asyncParentDestroyed, d);
    u.connect(d, "response", &asyncResponse, task);
    u.connect(d, "destroy", &asyncDestroyed, task);
    w.present();
}
pub fn openAsync(parent: ?*gtk.Window, multiple: c_int, cb: ?gio.AsyncReadyCallback, data: ?*anyopaque) callconv(.c) void {
    asyncOpen(parent, .open, multiple, null, cb, data);
}
pub fn saveAsync(parent: ?*gtk.Window, name: [*:0]const u8, cb: ?gio.AsyncReadyCallback, data: ?*anyopaque) callconv(.c) void {
    asyncOpen(parent, .save, 0, name, cb, data);
}
pub fn folderAsync(parent: ?*gtk.Window, cb: ?gio.AsyncReadyCallback, data: ?*anyopaque) callconv(.c) void {
    asyncOpen(parent, .select_folder, 0, null, cb, data);
}
pub fn openFinish(result: *gio.AsyncResult, err: ?*?*glib.Error) callconv(.c) ?*gio.ListModel {
    return if (cast(gio.Task, result).propagatePointer(err)) |files| cast(gio.ListModel, files) else null;
}
pub fn saveFinish(result: *gio.AsyncResult, err: ?*?*glib.Error) callconv(.c) ?*gio.File {
    const files = openFinish(result, err) orelse return null;
    defer u.unref(files);
    return u.modelItem(gio.File, files, 0);
}
pub export fn pearl_file_appearance(native: c_int) void {
    style.appearance(native != 0);
}
pub export fn pearl_file_style(window: *gtk.Window) void {
    style.apply(window);
}
