//! Image/text surfaces with subscriptions tied to widget lifetime and visibility.
const std = @import("std");
const u = @import("ui.zig");
const gtk = u.gtk;
const gio = u.gio;
const glib = u.glib;
const gdk = @import("gdk4");
const a = u.a;
const service = @import("platform/thumbnails.zig");
const policy = @import("core/preview.zig");
const Preferences = @import("platform/preferences.zig").Preferences;
const Window = @import("window.zig").Window;
pub const Mode = enum { grid, list, details, quick };
var slots: std.ArrayList(*Slot) = .empty;
var update_id: c_uint = 0;
pub fn schedule() void {
    if (update_id == 0) update_id = glib.timeoutAdd(35, update, null);
}
fn update(_: ?*anyopaque) callconv(.c) c_int {
    update_id = 0;
    for (slots.items) |s| s.refresh();
    return 0;
}
pub fn scrolled(_: *gtk.Adjustment, _: ?*anyopaque) callconv(.c) void {
    schedule();
}
pub fn shutdown() void {
    if (update_id != 0) {
        _ = glib.Source.remove(update_id);
        update_id = 0;
    }
    std.debug.assert(slots.items.len == 0);
    slots.deinit(a);
    slots = .empty;
}
pub fn readyCount() usize {
    var n: usize = 0;
    for (slots.items) |s| if (s.entry) |e| {
        if (e.texture != null) n += 1;
    };
    return n;
}
pub const Slot = struct {
    root: *gtk.Stack,
    picture: *gtk.Picture,
    icon: *gtk.Image,
    text: ?*gtk.TextView,
    info: ?*gio.FileInfo = null,
    entry: ?*service.Entry = null,
    listener: service.Listener = undefined,
    preferences: *Preferences,
    mode: Mode,
    edge: u32 = 0,
    limit: usize = 0,
    pub fn create(mode: Mode) *Slot {
        const s = a.create(Slot) catch unreachable;
        const root = gtk.Stack.new();
        root.setHhomogeneous(0);
        root.setVhomogeneous(0);
        root.as(gtk.Widget).addCssClass("preview-slot");
        const icon = u.image("text-x-generic-symbolic", if (mode == .list) 20 else 48);
        _ = root.addNamed(icon.as(gtk.Widget), "icon");
        const picture = gtk.Picture.new();
        picture.setContentFit(.contain);
        picture.setCanShrink(1);
        const image_frame = gtk.Overlay.new();
        const sizing = u.box(.vertical, 0, null);
        sizing.as(gtk.Widget).setSizeRequest(if (mode == .grid) 80 else if (mode == .list) 24 else 160, if (mode == .grid) 64 else if (mode == .list) 24 else 160);
        image_frame.setChild(sizing.as(gtk.Widget));
        image_frame.addOverlay(picture.as(gtk.Widget));
        picture.as(gtk.Widget).setHalign(.fill);
        picture.as(gtk.Widget).setValign(.fill);
        _ = root.addNamed(image_frame.as(gtk.Widget), "image");
        var text: ?*gtk.TextView = null;
        if (mode == .quick or mode == .details) {
            const t = gtk.TextView.new();
            t.setEditable(0);
            t.setCursorVisible(0);
            t.setMonospace(1);
            t.setWrapMode(.word_char);
            u.name(t.as(gtk.Widget), "File preview text");
            _ = root.addNamed(u.scroll(t.as(gtk.Widget)).as(gtk.Widget), "text");
            text = t;
        }
        root.setVisibleChildName("icon");
        root.as(gtk.Widget).setSizeRequest(if (mode == .grid) 80 else if (mode == .list) 24 else 160, if (mode == .grid) 64 else if (mode == .list) 24 else 160);
        if (mode == .quick) root.as(gtk.Widget).setVexpand(1);
        s.* = .{ .root = root, .picture = picture, .icon = icon, .text = text, .mode = mode, .preferences = Preferences.acquire() };
        s.listener = .{ .data = s, .ready = completed };
        root.as(u.object.Object).setDataFull("phyto-preview", s, disposed);
        _ = gtk.Widget.signals.map.connect(root.as(gtk.Widget), *Slot, mapped, s, .{});
        _ = gtk.Widget.signals.unmap.connect(root.as(gtk.Widget), *Slot, unmapped, s, .{});
        _ = u.object.Object.signals.notify.connect(root.as(u.object.Object), *Slot, scaleChanged, s, .{ .detail = "scale-factor" });
        slots.append(a, s) catch unreachable;
        return s;
    }
    pub fn from(widget: *gtk.Widget) *Slot {
        return @ptrCast(@alignCast(widget.as(u.object.Object).getData("phyto-preview").?));
    }
    pub fn set(self: *Slot, info: ?*gio.FileInfo) void {
        self.clear();
        if (self.info) |i| i.unref();
        self.info = info;
        if (info) |i| {
            i.ref();
            u.infoIcon(i, self.icon);
            self.picture.setAlternativeText(i.getDisplayName());
        }
        schedule();
    }
    pub fn clear(self: *Slot) void {
        self.picture.setPaintable(null);
        if (self.text) |t| t.getBuffer().setText("", 0);
        self.root.setVisibleChildName("icon");
        if (self.entry) |e| {
            self.entry = null;
            service.detach(e, &self.listener);
        }
    }
    fn visible(self: *Slot) bool {
        const widget = self.root.as(gtk.Widget);
        if (widget.getMapped() == 0) return false;
        var ancestor = widget.getParent();
        while (ancestor) |parent| : (ancestor = parent.getParent()) {
            if (u.object.ext.cast(gtk.ScrolledWindow, parent) != null) {
                var x: f64 = 0;
                var y: f64 = 0;
                if (widget.translateCoordinates(parent, 0, 0, &x, &y) == 0) return false;
                if (x + @as(f64, @floatFromInt(widget.getWidth())) <= 0 or y + @as(f64, @floatFromInt(widget.getHeight())) <= 0 or x >= @as(f64, @floatFromInt(parent.getWidth())) or y >= @as(f64, @floatFromInt(parent.getHeight()))) return false;
            }
        }
        return true;
    }
    fn refresh(self: *Slot) void {
        const automatic = self.mode != .quick;
        const allowed = if (self.mode == .details) self.preferences.preview_details else if (automatic) self.preferences.thumbnails else true;
        if (!allowed or !self.visible()) {
            self.clear();
            return;
        }
        const info = self.info orelse return;
        const text = self.mode == .details or self.mode == .quick;
        const logical: u32 = switch (self.mode) {
            .grid => 80,
            .list => 24,
            .details => 224,
            .quick => 2048,
        };
        const edge = policy.bucket(logical, @intCast(@max(1, self.root.as(gtk.Widget).getScaleFactor())));
        const limit = self.preferences.thumbnail_limit;
        if (self.edge != edge or self.limit != limit) self.clear();
        self.edge = edge;
        self.limit = limit;
        if (self.entry == null) {
            self.entry = service.request(info, edge, limit, text, if (self.mode == .quick) 0 else if (self.mode == .details) 1 else 2, &self.listener);
            if (self.entry) |e| {
                if (e.state == .ready) self.apply(e);
            } else if (text and !service.eligible(info, true)) {
                self.text.?.getBuffer().setText("No preview is available for this file type.", -1);
                self.root.setVisibleChildName("text");
            }
        }
    }
    fn apply(self: *Slot, e: *service.Entry) void {
        if (e.texture) |texture| {
            self.picture.setPaintable(texture.as(gdk.Paintable));
            self.root.setVisibleChildName("image");
        } else if (self.text) |t| {
            t.getBuffer().setText(e.caption orelse "Preview unavailable.", -1);
            self.root.setVisibleChildName("text");
        }
    }
    fn completed(data: *anyopaque, e: *service.Entry) void {
        const self: *Slot = @ptrCast(@alignCast(data));
        if (self.entry == e) self.apply(e);
    }
    fn mapped(_: *gtk.Widget, _: *Slot) callconv(.c) void {
        schedule();
    }
    fn unmapped(_: *gtk.Widget, self: *Slot) callconv(.c) void {
        self.clear();
    }
    fn scaleChanged(_: *u.object.Object, _: *u.object.ParamSpec, _: *Slot) callconv(.c) void {
        schedule();
    }
    fn disposed(data: ?*anyopaque) callconv(.c) void {
        const self: *Slot = @ptrCast(@alignCast(data.?));
        // Child widgets may already be disposed. Only release the subscription.
        if (self.entry) |e| service.detach(e, &self.listener);
        if (self.info) |i| i.unref();
        self.preferences.release();
        for (slots.items, 0..) |s, i| if (s == self) {
            _ = slots.swapRemove(i);
            break;
        };
        a.destroy(self);
    }
};

pub const Quick = struct {
    owner: *Window,
    window: *gtk.Window,
    slot: *Slot,
    file: *gio.File,
    tab_id: u64,
    monitor: ?*gio.FileMonitor = null,
    cancel: *gio.Cancellable,
    closed: bool = false,
    references: usize = 1,
    revision: u64 = 0,
    pub fn show(owner: *Window, file: *gio.File, tab_id: u64) void {
        if (owner.quick_preview) |old| old.window.close();
        const self = a.create(Quick) catch unreachable;
        const window = gtk.Window.new();
        window.setTransientFor(owner.window);
        window.setDestroyWithParent(1);
        window.setDefaultSize(760, 560);
        window.as(gtk.Widget).addCssClass("phyto-root");
        window.as(gtk.Widget).addCssClass(if (owner.options.native) "native" else if (owner.options.light) "light" else "dark");
        const body = u.box(.vertical, 12, "preview-body");
        window.setChild(body.as(gtk.Widget));
        const name = file.getBasename() orelse glib.strdup("File preview");
        defer glib.free(name);
        window.setTitle(name);
        const title = u.label(name, "file-title");
        title.setEllipsize(.middle);
        body.append(title.as(gtk.Widget));
        const slot = Slot.create(.quick);
        body.append(slot.root.as(gtk.Widget));
        const open = gtk.Button.newWithLabel("Open");
        open.as(gtk.Widget).setHalign(.end);
        body.append(open.as(gtk.Widget));
        file.ref();
        self.* = .{ .owner = owner, .window = window, .slot = slot, .file = file, .tab_id = tab_id, .cancel = gio.Cancellable.new() };
        owner.quick_preview = self;
        _ = gtk.Window.signals.close_request.connect(window, *Quick, close, self, .{});
        _ = gtk.Button.signals.clicked.connect(open, *Quick, opened, self, .{});
        const keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Quick, key, self, .{});
        window.as(gtk.Widget).addController(keys.as(gtk.EventController));
        self.monitor = file.monitorFile(.{}, self.cancel, null);
        if (self.monitor) |m| _ = gio.FileMonitor.signals.changed.connect(m, *Quick, fileChanged, self, .{});
        self.query();
        window.present();
    }
    fn query(self: *Quick) void {
        self.slot.set(null);
        self.revision += 1;
        const r = a.create(Query) catch unreachable;
        r.* = .{ .self = self, .revision = self.revision };
        self.references += 1;
        self.owner.app.as(gio.Application).hold();
        self.file.queryInfoAsync("standard::*,time::modified,time::modified-usec,access::*", .{ .nofollow_symlinks = true }, 0, self.cancel, queried, r);
    }
    const Query = struct { self: *Quick, revision: u64 };
    fn queried(source: ?*u.object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const r: *Query = @ptrCast(@alignCast(data.?));
        const self = r.self;
        defer {
            self.owner.app.as(gio.Application).release();
            self.release();
            a.destroy(r);
        }
        const f: *gio.File = @ptrCast(source.?);
        const info = f.queryInfoFinish(result, null);
        defer if (info) |i| i.unref();
        if (self.closed or r.revision != self.revision) return;
        if (info) |i| {
            i.setAttributeObject("standard::file", f.as(u.object.Object));
            self.slot.set(i);
        } else {
            self.slot.text.?.getBuffer().setText("File is unreadable or has been removed.", -1);
            self.slot.root.setVisibleChildName("text");
        }
    }
    fn fileChanged(_: *gio.FileMonitor, _: *gio.File, _: ?*gio.File, _: gio.FileMonitorEvent, self: *Quick) callconv(.c) void {
        if (!self.closed) self.query();
    }
    fn opened(_: *gtk.Button, self: *Quick) callconv(.c) void {
        if (self.slot.info) |info| self.owner.openFile(self.file, info);
    }
    fn key(_: *gtk.EventControllerKey, symbol: c_uint, _: c_uint, _: gdk.ModifierType, self: *Quick) callconv(.c) c_int {
        if (@import("build_options").test_hooks and symbol == gdk.KEY_F12) {
            self.owner.probe();
            return 1;
        }
        if (symbol != gdk.KEY_Escape) return 0;
        self.window.close();
        return 1;
    }
    fn close(_: *gtk.Window, self: *Quick) callconv(.c) c_int {
        self.closed = true;
        self.cancel.cancel();
        if (self.monitor) |m| {
            _ = m.cancel();
            m.unref();
            self.monitor = null;
        }
        self.slot.set(null);
        self.owner.quick_preview = null;
        if (!self.owner.closed) if (self.owner.findTab(self.tab_id)) |tab| {
            _ = (if (tab.list_mode) tab.list.as(gtk.Widget) else tab.grid.as(gtk.Widget)).grabFocus();
        };
        self.release();
        return 0;
    }
    fn release(self: *Quick) void {
        self.references -= 1;
        if (self.references != 0) return;
        self.cancel.unref();
        self.file.unref();
        a.destroy(self);
    }
};
