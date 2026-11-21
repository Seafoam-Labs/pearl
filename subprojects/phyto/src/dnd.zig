//! Drag-and-drop wiring. File views drag their selection out as a GdkFileList,
//! which GDK also serializes to text/uri-list for other applications, and accept
//! file drops on folder items, the background, Places rows and tab headers.
//! Transfers reuse the operations engine, so collisions, progress, receipts and
//! undo behave exactly like Paste.
const std = @import("std");
const u = @import("ui.zig");
const gtk = u.gtk;
const gio = u.gio;
const glib = u.glib;
const object = u.object;
const gdk = @import("gdk4");
const gsk = @import("gsk4");
const graphene = @import("graphene1");
const pango = @import("pango1");
const a = u.a;
const Tab = @import("tab.zig").Tab;
const Window = @import("window.zig").Window;
const Context = @import("context.zig").Context;
const engine = @import("operations/engine.zig");
const core = @import("core/dnd.zig");
const preview = @import("preview.zig");

/// The one drag this process is performing; a pointer can only drag once at a
/// time. Drop sites use it to recognize their own drags, and drag-end uses it to
/// tell an external move (trash the originals) from an internal one (the engine
/// already moved them).
var active: ?*Drag = null;

const Drag = struct {
    context: Context,
    source_fs: ?[:0]u8 = null,
    thumb: ?*gdk.Texture = null,
    handled: bool = false,
    fn deinit(self: *Drag) void {
        self.context.deinit();
        if (self.source_fs) |id| a.free(id);
        if (self.thumb) |t| t.unref();
        a.destroy(self);
    }
};

pub fn attachTab(tab: *Tab) void {
    for ([_]*gtk.Widget{ tab.grid.as(gtk.Widget), tab.list.as(gtk.Widget) }) |view| {
        const source = gtk.DragSource.new();
        source.setActions(.{ .copy = true, .move = true, .ask = true });
        // Capture on the view itself, and silence the built-in rubberband while
        // a press sits on an item: GtkListBase's bubble-phase drag gesture claims
        // the sequence on the first motion past the threshold even on items,
        // which would deny this source before prepare ever runs.
        source.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.DragSource.signals.prepare.connect(source, *Tab, dragPrepare, tab, .{});
        _ = gtk.DragSource.signals.drag_begin.connect(source, *Tab, dragBegin, tab, .{});
        _ = gtk.DragSource.signals.drag_end.connect(source, *Tab, dragEnd, tab, .{});
        _ = gtk.DragSource.signals.drag_cancel.connect(source, *Tab, dragCancel, tab, .{});
        // GtkGesture begin/end/cancel are not exposed in the bindings; connect
        // them by id ("pressed" does not exist on DragSource in GTK 4.24).
        _ = object.signalConnectClosureById(
            @ptrCast(@alignCast(source)),
            object.signalLookup("begin", gtk.DragSource.getGObjectType()),
            glib.quarkFromString(null),
            object.CClosure.new(@ptrCast(&dragGestureBegin), tab, null),
            0,
        );
        for ([_][:0]const u8{ "end", "cancel" }) |name| {
            _ = object.signalConnectClosureById(
                @ptrCast(@alignCast(source)),
                object.signalLookup(name, gtk.DragSource.getGObjectType()),
                glib.quarkFromString(null),
                object.CClosure.new(@ptrCast(&dragGestureEnd), tab, null),
                0,
            );
        }
        view.addController(source.as(gtk.EventController));
    }
    const target = gtk.DropTarget.new(gdk.FileList.getGObjectType(), .{ .copy = true, .move = true, .link = true });
    _ = gtk.DropTarget.signals.enter.connect(target, *Tab, viewEnter, tab, .{});
    _ = gtk.DropTarget.signals.motion.connect(target, *Tab, viewMotion, tab, .{});
    _ = gtk.DropTarget.signals.leave.connect(target, *Tab, viewLeave, tab, .{});
    _ = gtk.DropTarget.signals.drop.connect(target, *Tab, viewDropped, tab, .{});
    tab.root.as(gtk.Widget).addController(target.as(gtk.EventController));
}

fn dragGestureBegin(source: *gtk.DragSource, sequence: ?*gdk.EventSequence, tab: *Tab) callconv(.c) void {
    var x: f64 = 0;
    var y: f64 = 0;
    if (source.as(gtk.Gesture).getPoint(sequence, &x, &y) == 0) return;
    const view = source.as(gtk.EventController).getWidget() orelse return;
    const picked = view.pick(x, y, .{}) orelse return;
    if (Tab.itemAt(picked, view) == null) return;
    rubberbandState(tab).set(false);
}

fn dragGestureEnd(_: *gtk.DragSource, _: ?*gdk.EventSequence, tab: *Tab) callconv(.c) void {
    rubberbandState(tab).set(true);
}

/// Toggling enable-rubberband adds/removes a gesture controller, and GTK walks
/// the widget's controller list live during event propagation — removing the
/// rubberband gesture from inside a gesture callback frees the list node the
/// walk visits next (general protection fault in get_propagation_phase). Apply
/// the change from a high-priority idle instead: it runs after propagation
/// finishes but before the next pointer event is dispatched, so the rubberband
/// still cannot claim an item drag.
const Rubberband = struct {
    tab: *Tab,
    enable: bool = true,
    idle: c_uint = 0,
    fn set(self: *Rubberband, enable: bool) void {
        self.enable = enable;
        if (self.idle == 0) self.idle = glib.idleAddFull(-100, apply, self, null);
    }
    fn apply(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Rubberband = @ptrCast(@alignCast(data.?));
        self.idle = 0;
        const on: c_int = @intFromBool(self.enable);
        self.tab.grid.setEnableRubberband(on);
        self.tab.list.setEnableRubberband(on);
        return 0;
    }
    fn free(data: ?*anyopaque) callconv(.c) void {
        const self: *Rubberband = @ptrCast(@alignCast(data.?));
        if (self.idle != 0) _ = glib.Source.remove(self.idle);
        a.destroy(self);
    }
};

fn rubberbandState(tab: *Tab) *Rubberband {
    const root = tab.root.as(object.Object);
    if (root.getData("phyto-rubberband")) |data| return @ptrCast(@alignCast(data));
    const state = a.create(Rubberband) catch unreachable;
    state.* = .{ .tab = tab };
    root.setDataFull("phyto-rubberband", state, Rubberband.free);
    return state;
}

pub fn attachPlace(owner: *Window, button: *gtk.Button) void {
    const target = gtk.DropTarget.new(gdk.FileList.getGObjectType(), .{ .copy = true, .move = true, .link = true });
    _ = gtk.DropTarget.signals.motion.connect(target, *Window, placeMotion, owner, .{});
    _ = gtk.DropTarget.signals.leave.connect(target, *Window, placeLeave, owner, .{});
    _ = gtk.DropTarget.signals.drop.connect(target, *Window, placeDropped, owner, .{});
    button.as(gtk.Widget).addController(target.as(gtk.EventController));
}

pub fn attachTabButton(owner: *Window, button: *gtk.Button, tab: *Tab) void {
    const binding = a.create(TabDrop) catch unreachable;
    binding.* = .{ .owner = owner, .tab_id = tab.id };
    button.as(object.Object).setDataFull("phyto-tab-drop", binding, TabDrop.free);
    const target = gtk.DropTarget.new(gdk.FileList.getGObjectType(), .{ .copy = true, .move = true, .link = true });
    _ = gtk.DropTarget.signals.enter.connect(target, *TabDrop, tabEnter, binding, .{});
    _ = gtk.DropTarget.signals.motion.connect(target, *TabDrop, tabMotion, binding, .{});
    _ = gtk.DropTarget.signals.leave.connect(target, *TabDrop, tabLeave, binding, .{});
    _ = gtk.DropTarget.signals.drop.connect(target, *TabDrop, tabDropped, binding, .{});
    button.as(gtk.Widget).addController(target.as(gtk.EventController));
}

fn dragPrepare(source: *gtk.DragSource, x: f64, y: f64, tab: *Tab) callconv(.c) ?*gdk.ContentProvider {
    if (tab.isNetwork()) return null;
    const view = source.as(gtk.EventController).getWidget() orelse return null;
    const picked = view.pick(x, y, .{}) orelse return null;
    // Returning null on the background leaves rubberband selection in charge;
    // GTK re-emits prepare on later motion, so drags still start from items.
    const item = Tab.itemAt(picked, view) orelse return null;
    const position = item.getPosition();
    if (position == std.math.maxInt(c_uint)) return null;
    // Carry the row's already-decoded thumbnail into the drag image; the
    // scheduler owns the entry, so hold our own reference for the drag.
    var thumb: ?*gdk.Texture = null;
    if (item.getChild()) |row| if (row.getFirstChild()) |visual| {
        if (visual.as(object.Object).getData("phyto-preview") != null) {
            if (preview.Slot.from(visual).entry) |e| {
                if (e.texture) |t| if (t.getWidth() >= 48) {
                    t.ref();
                    thumb = t;
                };
            }
        }
    };
    const selection = tab.selection.as(gtk.SelectionModel);
    if (selection.isSelected(position) == 0) {
        _ = selection.unselectAll();
        _ = selection.selectItem(position, 1);
    }
    var context = Context.capture(tab);
    if (context.items.items.len == 0) {
        context.deinit();
        return null;
    }
    const files = a.alloc(*gio.File, context.items.items.len) catch unreachable;
    defer a.free(files);
    for (context.items.items, 0..) |entry, i| files[i] = entry.file;
    const list = gdk.FileList.newFromArray(files.ptr, files.len);
    var value: object.Value = std.mem.zeroes(object.Value);
    _ = object.Value.init(&value, gdk.FileList.getGObjectType());
    defer value.unset();
    value.setBoxedTakeOwnership(list);
    if (active) |old| old.deinit();
    const drag = a.create(Drag) catch unreachable;
    drag.* = .{ .context = context, .source_fs = filesystemId(files[0]), .thumb = thumb };
    active = drag;
    return gdk.ContentProvider.newForValue(&value);
}

fn dragBegin(source: *gtk.DragSource, _: *gdk.Drag, tab: *Tab) callconv(.c) void {
    const drag = active orelse return;
    if (dragCard(drag, tab)) |card| {
        defer card.paintable.unref();
        source.setIcon(card.paintable, card.hot_x, card.hot_y);
        return;
    }
    const icon = gtk.IconPaintable.newForFile(drag.context.items.items[0].file, 64, 1);
    defer icon.unref();
    source.setIcon(icon.as(gdk.Paintable), 32, 32);
}

const DragIcon = struct { paintable: *gdk.Paintable, hot_x: c_int, hot_y: c_int };

/// A card showing what is being held: the file's thumbnail (or MIME icon), its
/// name, and a count badge for multi-selection. Colors come from the view's
/// resolved CSS foreground (the Pearl palette slices may be empty or borrowed
/// from a freed snapshot, so they are not safe to read here); the background is
/// chosen against that foreground's luminance so every theme mode stays legible.
fn dragCard(drag: *Drag, tab: *Tab) ?DragIcon {
    var fg: gdk.RGBA = undefined;
    tab.root.as(gtk.Widget).getColor(&fg);
    const luminance = 0.299 * fg.f_red + 0.587 * fg.f_green + 0.114 * fg.f_blue;
    const light = luminance < 0.5;
    const bg: gdk.RGBA = if (light) .{ .f_red = 0.97, .f_green = 0.97, .f_blue = 0.97, .f_alpha = 1 } else .{ .f_red = 0.13, .f_green = 0.13, .f_blue = 0.13, .f_alpha = 1 };
    const badge_bg = fg;
    const badge_fg = bg;
    const first = drag.context.items.items[0];
    var owned_thumb: ?*gdk.Texture = null;
    const thumb = drag.thumb orelse blk: {
        owned_thumb = cachedThumb(first);
        break :blk owned_thumb;
    };
    defer if (owned_thumb) |t| t.unref();
    const context = tab.root.as(gtk.Widget).createPangoContext();
    defer context.unref();
    const font = pango.FontDescription.new();
    defer font.free();
    font.setAbsoluteSize(13);
    const layout = pango.Layout.new(context);
    defer layout.unref();
    layout.setFontDescription(font);
    layout.setText((first.info orelse return null).getDisplayName(), -1);
    layout.setEllipsize(.end);
    layout.setWidth(160 * pango.SCALE);
    var ink: pango.Rectangle = undefined;
    var logical: pango.Rectangle = undefined;
    layout.getPixelExtents(&ink, &logical);
    const pad: f32 = 10;
    const icon_size: f32 = 64;
    const gap: f32 = 6;
    const text_w: f32 = @floatFromInt(logical.f_width);
    const text_h: f32 = @floatFromInt(logical.f_height);
    const w = @max(icon_size, text_w) + pad * 2;
    const h = pad + icon_size + gap + text_h + pad;
    const snap = gtk.Snapshot.new();
    defer snap.unref();
    var outline: gsk.RoundedRect = undefined;
    outline.f_bounds = .{ .f_origin = .{ .f_x = 0, .f_y = 0 }, .f_size = .{ .f_width = w, .f_height = h } };
    const corner: graphene.Size = .{ .f_width = 12, .f_height = 12 };
    outline.f_corner = .{ corner, corner, corner, corner };
    snap.pushRoundedClip(&outline);
    snap.appendColor(&bg, &outline.f_bounds);
    const ix = (w - icon_size) / 2;
    if (thumb) |texture| {
        const tw: f32 = @floatFromInt(texture.getWidth());
        const th: f32 = @floatFromInt(texture.getHeight());
        const scale = @min(icon_size / tw, icon_size / th);
        const dw = tw * scale;
        const dh = th * scale;
        snap.appendTexture(texture, &.{ .f_origin = .{ .f_x = ix + (icon_size - dw) / 2, .f_y = pad + (icon_size - dh) / 2 }, .f_size = .{ .f_width = dw, .f_height = dh } });
    } else {
        const icon = fileIcon(first.info.?, @intFromFloat(icon_size));
        defer icon.unref();
        snap.save();
        snap.translate(&.{ .f_x = ix, .f_y = pad });
        if (object.ext.cast(gtk.SymbolicPaintable, icon)) |symbolic| {
            // Symbolic paintables snapshot with no color of their own; give
            // them the card foreground or they render invisible.
            const colors = [_]gdk.RGBA{fg};
            symbolic.snapshotSymbolic(snap.as(gdk.Snapshot), icon_size, icon_size, &colors, 1);
        } else {
            icon.as(gdk.Paintable).snapshot(snap.as(gdk.Snapshot), icon_size, icon_size);
        }
        snap.restore();
    }
    snap.save();
    snap.translate(&.{ .f_x = (w - text_w) / 2, .f_y = pad + icon_size + gap });
    snap.appendLayout(layout, &fg);
    snap.restore();
    const count = drag.context.items.items.len;
    if (count > 1) {
        const badge = pango.Layout.new(context);
        defer badge.unref();
        badge.setFontDescription(font);
        const text = u.format("{d}", .{count});
        defer a.free(text);
        badge.setText(text, -1);
        badge.getPixelExtents(&ink, &logical);
        const bw: f32 = @floatFromInt(logical.f_width);
        const bh: f32 = @floatFromInt(logical.f_height);
        var circle: gsk.RoundedRect = undefined;
        circle.f_bounds = .{ .f_origin = .{ .f_x = w - 26, .f_y = 2 }, .f_size = .{ .f_width = 24, .f_height = 24 } };
        circle.f_corner = .{ corner, corner, corner, corner };
        snap.pushRoundedClip(&circle);
        snap.appendColor(&badge_bg, &circle.f_bounds);
        snap.save();
        snap.translate(&.{ .f_x = w - 26 + (24 - bw) / 2, .f_y = 2 + (24 - bh) / 2 });
        snap.appendLayout(badge, &badge_fg);
        snap.restore();
        snap.pop();
    }
    snap.pop();
    const paintable = snap.toPaintable(&.{ .f_width = w, .f_height = h }) orelse return null;
    return .{ .paintable = paintable, .hot_x = @intFromFloat(w / 2), .hot_y = @intFromFloat(pad + icon_size / 2) };
}

/// Resolved icon for the held file: folder glyph for directories, the file's
/// symbolic MIME icon otherwise, and a generic file glyph when the theme has
/// nothing for the type — the card must never show an empty icon box.
fn fileIcon(info: *gio.FileInfo, size: c_int) *gtk.IconPaintable {
    const theme = gtk.IconTheme.getForDisplay(gdk.Display.getDefault().?);
    var owned: ?*gio.Icon = null;
    defer if (owned) |i| i.unref();
    const gicon: *gio.Icon = if (info.getFileType() == .directory) blk: {
        const themed = gio.ThemedIcon.new("folder-symbolic");
        owned = themed.as(gio.Icon);
        break :blk themed.as(gio.Icon);
    } else info.getSymbolicIcon() orelse blk: {
        const themed = gio.ThemedIcon.new("text-x-generic-symbolic");
        owned = themed.as(gio.Icon);
        break :blk themed.as(gio.Icon);
    };
    var paintable = theme.lookupByGicon(gicon, size, 1, .ltr, .{});
    if (paintable.getIconName() == null) {
        paintable.unref();
        paintable = theme.lookupIcon("text-x-generic-symbolic", null, size, 1, .ltr, .{});
    }
    return paintable;
}

/// A freedesktop thumbnail cache hit for the held file, so the drag card shows
/// a real preview even when the row has not decoded one (list view, cold row).
/// Thumbnails are small, so the synchronous decode is cheap. Caller unrefs.
fn cachedThumb(item: @import("context.zig").Item) ?*gdk.Texture {
    const info = item.info orelse return null;
    const mime = info.getContentType() orelse return null;
    if (!std.mem.startsWith(u8, std.mem.span(mime), "image/")) return null;
    const uri = item.file.getUri();
    defer glib.free(uri);
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(std.mem.span(uri), &digest, .{});
    const name = std.fmt.bytesToHex(digest, .lower);
    const cache: [*:0]u8 = @constCast(glib.getUserCacheDir());
    defer glib.free(cache);
    for ([_][]const u8{ "large", "normal" }) |class| {
        const path = u.format("{s}/thumbnails/{s}/{s}.png", .{ std.mem.span(cache), class, name });
        defer a.free(path);
        const f = gio.File.newForPath(path);
        defer f.unref();
        var err: ?*glib.Error = null;
        if (gdk.Texture.newFromFile(f, &err)) |texture| return texture;
        if (err) |e| e.free();
    }
    return null;
}

fn dragEnd(_: *gtk.DragSource, _: *gdk.Drag, delete_data: c_int, tab: *Tab) callconv(.c) void {
    const drag = active orelse return;
    active = null;
    defer drag.deinit();
    if (delete_data == 0 or drag.handled or tab.owner.closed) return;
    // Another application accepted a move and copied the files itself, so the
    // originals are no longer needed. Trash keeps that recoverable.
    const j = engine.Job.create(.trash);
    for (drag.context.items.items) |entry| j.add(entry.file, null);
    tab.owner.operations.start(j);
}

fn dragCancel(_: *gtk.DragSource, _: *gdk.Drag, _: gdk.DragCancelReason, _: *Tab) callconv(.c) c_int {
    if (active) |drag| {
        active = null;
        drag.deinit();
    }
    return 0;
}

const ViewDrop = struct {
    highlighted: ?*gtk.Widget = null,
    dest_uri: ?[:0]u8 = null,
    dest_fs: ?[:0]u8 = null,
    fn clear(self: *ViewDrop) void {
        if (self.highlighted) |w| w.removeCssClass("drop-target");
        self.highlighted = null;
    }
    fn free(data: ?*anyopaque) callconv(.c) void {
        const self: *ViewDrop = @ptrCast(@alignCast(data.?));
        self.clear();
        if (self.dest_uri) |s| a.free(s);
        if (self.dest_fs) |s| a.free(s);
        a.destroy(self);
    }
};

fn viewState(tab: *Tab) *ViewDrop {
    const root = tab.root.as(object.Object);
    if (root.getData("phyto-drop")) |data| return @ptrCast(@alignCast(data));
    const state = a.create(ViewDrop) catch unreachable;
    state.* = .{};
    root.setDataFull("phyto-drop", state, ViewDrop.free);
    return state;
}

const Destination = struct { file: *gio.File, widget: ?*gtk.Widget };

/// The folder under the pointer, or the tab's own folder on the background.
/// The returned file is referenced for the caller.
fn destinationAt(tab: *Tab, x: f64, y: f64) Destination {
    const root = tab.root.as(gtk.Widget);
    if (root.pick(x, y, .{})) |picked| {
        if (Tab.itemAt(picked, root)) |item| {
            if (item.getItem()) |obj| {
                const info = object.ext.cast(gio.FileInfo, obj).?;
                if (info.getFileType() == .directory) {
                    const f = u.file(info);
                    f.ref();
                    return .{ .file = f, .widget = item.getChild() };
                }
            }
        }
    }
    return .{ .file = gio.File.newForUri(tab.uri), .widget = null };
}

fn viewEnter(target: *gtk.DropTarget, x: f64, y: f64, tab: *Tab) callconv(.c) gdk.DragAction {
    return viewMotion(target, x, y, tab);
}

fn viewMotion(target: *gtk.DropTarget, x: f64, y: f64, tab: *Tab) callconv(.c) gdk.DragAction {
    const state = viewState(tab);
    state.clear();
    if (tab.isNetwork()) return .{};
    const dest = destinationAt(tab, x, y);
    defer dest.file.unref();
    if (dest.widget) |w| {
        w.addCssClass("drop-target");
        state.highlighted = w;
    }
    const drop = target.getCurrentDrop() orelse return .{};
    const uri = dest.file.getUri();
    defer glib.free(uri);
    if (state.dest_uri == null or !std.mem.eql(u8, state.dest_uri.?, std.mem.span(uri))) {
        if (state.dest_uri) |s| a.free(s);
        if (state.dest_fs) |s| a.free(s);
        state.dest_uri = a.dupeSentinel(u8, std.mem.span(uri), 0) catch unreachable;
        state.dest_fs = filesystemId(dest.file);
    }
    const same = if (active) |d| (if (d.source_fs) |src| (if (state.dest_fs) |dst| std.mem.eql(u8, src, dst) else false) else false) else false;
    // Never return ask from motion: GDK excludes it from the drop's reported
    // actions, so the protocol only ever sees a concrete copy/move choice. The
    // drop handler re-reads the modifiers and opens the choice dialog itself.
    var offer = dropOffer(drop);
    offer.ask = false;
    return actionFlag(core.pickAction(offer, dropMods(drop), same));
}

fn viewLeave(target: *gtk.DropTarget, tab: *Tab) callconv(.c) void {
    _ = target;
    viewState(tab).clear();
}

fn viewDropped(target: *gtk.DropTarget, value: *object.Value, x: f64, y: f64, tab: *Tab) callconv(.c) c_int {
    const state = viewState(tab);
    state.clear();
    if (tab.isNetwork()) return 0;
    var files = filesFromValue(value) orelse return 0;
    defer releaseFiles(&files);
    const dest = destinationAt(tab, x, y);
    defer dest.file.unref();
    const drop = target.getCurrentDrop();
    markInternal(drop);
    const action = dropAction(drop, dest.file);
    switch (action) {
        .none => return 0,
        .ask => {
            askAction(tab.owner, tab, files, dest.file);
            files = .empty;
            return 1;
        },
        else => {
            perform(tab.owner, tab, files.items, dest.file, action);
            return 1;
        },
    }
}

const TabDrop = struct {
    owner: *Window,
    tab_id: u64,
    fn free(data: ?*anyopaque) callconv(.c) void {
        const self: *TabDrop = @ptrCast(@alignCast(data.?));
        a.destroy(self);
    }
};

/// Hovering a tab reveals its folder after a moment, so files can be carried
/// into another folder without letting go. The destroy notify cancels the
/// timer if the button is rebuilt or the drag moves on first.
const Spring = struct {
    owner: *Window,
    tab_id: u64,
    source_id: c_uint = 0,
    fn free(data: ?*anyopaque) callconv(.c) void {
        const self: *Spring = @ptrCast(@alignCast(data.?));
        if (self.source_id != 0) _ = glib.Source.remove(self.source_id);
        a.destroy(self);
    }
};

fn springOpen(data: ?*anyopaque) callconv(.c) c_int {
    const spring: *Spring = @ptrCast(@alignCast(data.?));
    spring.source_id = 0;
    const owner = spring.owner;
    if (owner.closed) return 0;
    const tab = owner.findTab(spring.tab_id) orelse return 0;
    revealTab(owner, tab);
    return 0;
}

fn revealTab(owner: *Window, tab: *Tab) void {
    const p = &owner.panes[tab.pane];
    if (owner.active == tab.pane and p.tabs.items[p.selected] == tab) return;
    for (p.tabs.items, 0..) |t, i| if (t == tab) {
        p.selected = i;
        break;
    };
    p.stack.setVisibleChild(tab.root.as(gtk.Widget));
    owner.active = tab.pane;
    owner.rebuildTabs(tab.pane);
    owner.sync();
}

fn tabEnter(target: *gtk.DropTarget, x: f64, y: f64, binding: *TabDrop) callconv(.c) gdk.DragAction {
    const widget = target.as(gtk.EventController).getWidget().?;
    widget.addCssClass("drop-target");
    const spring = a.create(Spring) catch unreachable;
    spring.* = .{ .owner = binding.owner, .tab_id = binding.tab_id };
    spring.source_id = glib.timeoutAdd(600, springOpen, spring);
    widget.as(object.Object).setDataFull("phyto-spring", spring, Spring.free);
    return tabMotion(target, x, y, binding);
}

fn tabMotion(target: *gtk.DropTarget, _: f64, _: f64, binding: *TabDrop) callconv(.c) gdk.DragAction {
    const tab = binding.owner.findTab(binding.tab_id) orelse return .{};
    if (tab.isNetwork()) return .{};
    const drop = target.getCurrentDrop() orelse return .{};
    const dest = gio.File.newForUri(tab.uri);
    defer dest.unref();
    var offer = dropOffer(drop);
    offer.ask = false;
    const same = if (active) |d| sameFilesystem(d.source_fs, dest) else false;
    return actionFlag(core.pickAction(offer, dropMods(drop), same));
}

fn tabLeave(target: *gtk.DropTarget, _: *TabDrop) callconv(.c) void {
    const widget = target.as(gtk.EventController).getWidget().?;
    widget.removeCssClass("drop-target");
    widget.as(object.Object).setDataFull("phyto-spring", null, null);
}

fn tabDropped(target: *gtk.DropTarget, value: *object.Value, _: f64, _: f64, binding: *TabDrop) callconv(.c) c_int {
    const widget = target.as(gtk.EventController).getWidget().?;
    widget.removeCssClass("drop-target");
    widget.as(object.Object).setDataFull("phyto-spring", null, null);
    const owner = binding.owner;
    const tab = owner.findTab(binding.tab_id) orelse return 0;
    if (tab.isNetwork()) return 0;
    var files = filesFromValue(value) orelse return 0;
    defer releaseFiles(&files);
    const dest = gio.File.newForUri(tab.uri);
    defer dest.unref();
    const drop = target.getCurrentDrop();
    markInternal(drop);
    const action = dropAction(drop, dest);
    if (action == .none) return 0;
    revealTab(owner, tab);
    if (action == .ask) {
        askAction(owner, tab, files, dest);
        files = .empty;
        return 1;
    }
    perform(owner, tab, files.items, dest, action);
    return 1;
}

fn placeMotion(target: *gtk.DropTarget, _: f64, _: f64, owner: *Window) callconv(.c) gdk.DragAction {
    _ = owner;
    const widget = target.as(gtk.EventController).getWidget().?;
    // An unmounted volume is not a folder yet; mounting stays a deliberate click.
    if (widget.as(object.Object).getData("phyto-volume") != null) return .{};
    const dest: *gio.File = @ptrCast(@alignCast(widget.as(object.Object).getData("phyto-file") orelse return .{}));
    widget.addCssClass("drop-target");
    const drop = target.getCurrentDrop() orelse return .{};
    var offer = dropOffer(drop);
    offer.ask = false;
    const same = if (active) |d| sameFilesystem(d.source_fs, dest) else false;
    return actionFlag(core.pickAction(offer, dropMods(drop), same));
}

fn placeLeave(target: *gtk.DropTarget, _: *Window) callconv(.c) void {
    const widget = target.as(gtk.EventController).getWidget().?;
    widget.removeCssClass("drop-target");
}

fn placeDropped(target: *gtk.DropTarget, value: *object.Value, _: f64, _: f64, owner: *Window) callconv(.c) c_int {
    const widget = target.as(gtk.EventController).getWidget().?;
    widget.removeCssClass("drop-target");
    if (widget.as(object.Object).getData("phyto-volume") != null) return 0;
    const dest: *gio.File = @ptrCast(@alignCast(widget.as(object.Object).getData("phyto-file") orelse return 0));
    if (!isDirectory(dest)) {
        owner.setStatus("Files can only be dropped onto folders.");
        return 0;
    }
    var files = filesFromValue(value) orelse return 0;
    defer releaseFiles(&files);
    const drop = target.getCurrentDrop();
    markInternal(drop);
    const action = dropAction(drop, dest);
    if (action == .none) return 0;
    if (action == .ask) {
        askAction(owner, owner.current(), files, dest);
        files = .empty;
        return 1;
    }
    perform(owner, owner.current(), files.items, dest, action);
    return 1;
}

/// A local drag whose drop we handle ourselves: the engine performs any move,
/// so drag-end must not delete the originals a second time.
fn markInternal(drop: ?*gdk.Drop) void {
    const d = drop orelse return;
    if (d.getDrag() == null) return;
    if (active) |drag| drag.handled = true;
}

fn dropAction(drop: ?*gdk.Drop, dest: *gio.File) core.Action {
    const d = drop orelse return .copy;
    const same = if (active) |drag| sameFilesystem(drag.source_fs, dest) else false;
    return core.pickAction(dropOffer(d), dropMods(d), same);
}

fn dropOffer(drop: *gdk.Drop) core.Offer {
    const available = drop.getActions();
    return .{
        .copy = available.copy,
        .move = available.move,
        .link = available.link,
        // GDK never reports ASK for a drop; only our own source offers it.
        .ask = drop.getDrag() != null,
    };
}

fn dropMods(drop: *gdk.Drop) core.Mods {
    const mods = drop.getDevice().getModifierState();
    return .{ .control = mods.control_mask, .shift = mods.shift_mask };
}

fn actionFlag(action: core.Action) gdk.DragAction {
    return switch (action) {
        .copy => .{ .copy = true },
        .move => .{ .move = true },
        .link => .{ .link = true },
        .ask => .{ .ask = true },
        .none => .{},
    };
}

/// Dropped GFiles, each referenced for the caller. GDK deserializes
/// text/uri-list into GdkFileList, so drops from other applications arrive here
/// in the same shape as our own drags.
fn filesFromValue(value: *object.Value) ?std.ArrayList(*gio.File) {
    const raw = value.getBoxed() orelse return null;
    const list: *gdk.FileList = @ptrCast(@alignCast(raw));
    var files: std.ArrayList(*gio.File) = .empty;
    var node: ?*glib.SList = list.getFiles();
    while (node) |n| : (node = n.f_next) {
        const f: *gio.File = @ptrCast(@alignCast(n.f_data.?));
        f.ref();
        files.append(a, f) catch unreachable;
    }
    if (files.items.len == 0) {
        files.deinit(a);
        return null;
    }
    return files;
}

fn releaseFiles(files: *std.ArrayList(*gio.File)) void {
    for (files.items) |f| f.unref();
    files.deinit(a);
}

/// id::filesystem of a local file, or null for remote URIs whose query could
/// block the main thread. Callers own the returned string.
fn filesystemId(file: *gio.File) ?[:0]u8 {
    const path = file.getPath() orelse return null;
    glib.free(path);
    var err: ?*glib.Error = null;
    const info = file.queryInfo("id::filesystem", .{}, null, &err) orelse {
        if (err) |e| e.free();
        return null;
    };
    defer info.unref();
    const id = info.getAttributeString("id::filesystem") orelse return null;
    return a.dupeSentinel(u8, std.mem.span(id), 0) catch unreachable;
}

fn sameFilesystem(source_fs: ?[]const u8, dest: *gio.File) bool {
    const src = source_fs orelse return false;
    const dst = filesystemId(dest) orelse return false;
    defer a.free(dst);
    return std.mem.eql(u8, src, dst);
}

fn isDirectory(file: *gio.File) bool {
    // Remote Places rows are folders by construction; let the engine report
    // the real error if one is not.
    const path = file.getPath() orelse return true;
    glib.free(path);
    var err: ?*glib.Error = null;
    const info = file.queryInfo("standard::type", .{}, null, &err) orelse {
        if (err) |e| e.free();
        return true;
    };
    defer info.unref();
    return info.getFileType() == .directory;
}

fn perform(owner: *Window, tab: *Tab, files: []const *gio.File, dest: *gio.File, action: core.Action) void {
    const uri = dest.getUri();
    defer glib.free(uri);
    var c = Context.init(tab, .selection);
    defer c.deinit();
    if (std.mem.startsWith(u8, std.mem.span(uri), "trash:")) {
        for (files) |f| c.add(f, null);
        owner.operations.transfer(&c, null, .trash);
        return;
    }
    var rejected = false;
    for (files) |f| {
        // A folder can never be transferred into itself or its own subtree.
        if (dest.hasPrefix(f) != 0 or dest.equal(f) != 0) {
            rejected = true;
            continue;
        }
        // Moving an item onto its own folder is a no-op, not a numbered copy.
        if (action == .move) {
            if (f.getParent()) |parent| {
                defer parent.unref();
                if (parent.equal(dest) != 0) continue;
            }
        }
        c.add(f, null);
    }
    if (c.items.items.len == 0) {
        owner.setStatus(if (rejected) "A folder cannot be moved into itself." else "The files are already in this folder.");
        return;
    }
    if (action == .link) {
        const j = engine.Job.create(.link);
        j.self_duplicate = true;
        for (c.items.items) |item| {
            const base = item.file.getBasename() orelse continue;
            defer glib.free(base);
            const name_ = u.format("Link to {s}", .{std.mem.span(base)});
            defer a.free(name_);
            const target = dest.getChild(name_);
            defer target.unref();
            j.add(item.file, target);
        }
        owner.operations.start(j);
        return;
    }
    owner.operations.transfer(&c, dest, if (action == .move) .move else .copy);
}

const Ask = struct {
    owner: *Window,
    tab_id: u64,
    files: std.ArrayList(*gio.File),
    dest: *gio.File,
    fn free(data: ?*anyopaque) callconv(.c) void {
        const self: *Ask = @ptrCast(@alignCast(data.?));
        releaseFiles(&self.files);
        self.dest.unref();
        a.destroy(self);
    }
};

/// Ctrl+Shift drop: let the user choose instead of guessing. Ownership of
/// `files` moves into the dialog and is released when it closes.
fn askAction(owner: *Window, tab: *Tab, files: std.ArrayList(*gio.File), dest: *gio.File) void {
    const ask = a.create(Ask) catch unreachable;
    dest.ref();
    ask.* = .{ .owner = owner, .tab_id = tab.id, .files = files, .dest = dest };
    const d = gtk.Dialog.new();
    d.as(gtk.Widget).addCssClass("phyto-root");
    d.as(gtk.Widget).addCssClass(@import("appearance.zig").themeClass());
    d.as(gtk.Window).setTitle(@import("i18n").dtr("phyto", "Drop files"));
    d.as(gtk.Window).setTransientFor(owner.window);
    d.as(gtk.Window).setDestroyWithParent(1);
    d.as(gtk.Window).setModal(1);
    d.as(gtk.Window).setDefaultSize(420, -1);
    const body = d.getContentArea();
    body.as(gtk.Widget).addCssClass("dialog-body");
    const caption = u.format("Choose what to do with the {d} dropped items.", .{files.items.len});
    defer a.free(caption);
    const label = u.label(caption, null);
    label.setWrap(1);
    label.setMaxWidthChars(50);
    body.append(label.as(gtk.Widget));
    _ = d.addButton(@import("i18n").dtr("phyto", "Cancel"), 0);
    _ = d.addButton(@import("i18n").dtr("phyto", "Copy here"), 1);
    _ = d.addButton(@import("i18n").dtr("phyto", "Move here"), 2);
    var all_local = true;
    for (files.items) |f| {
        if (f.getPath()) |path| glib.free(path) else all_local = false;
    }
    if (all_local) _ = d.addButton(@import("i18n").dtr("phyto", "Link here"), 3);
    d.setDefaultResponse(2);
    d.as(object.Object).setDataFull("phyto-drop-ask", ask, Ask.free);
    _ = gtk.Dialog.signals.response.connect(d, *Ask, askResponse, ask, .{});
    d.as(gtk.Window).present();
}

fn askResponse(d: *gtk.Dialog, response: c_int, ask: *Ask) callconv(.c) void {
    defer d.as(gtk.Window).destroy();
    if (response == 0 or ask.owner.closed) return;
    const tab = ask.owner.findTab(ask.tab_id) orelse return;
    const action: core.Action = switch (response) {
        1 => .copy,
        2 => .move,
        3 => .link,
        else => return,
    };
    perform(ask.owner, tab, ask.files.items, ask.dest, action);
}
