const std = @import("std");
const u = @import("ui.zig");
const gtk = u.gtk;
const gio = u.gio;
const glib = u.glib;
const object = u.object;
const gobject = object;
const a = u.a;

const attrs = "standard::*,time::modified,time::modified-usec,access::*,trash::*";

/// A `GListModel` that mirrors a monitored `GtkDirectoryList` but can refresh
/// by diffing a fresh enumeration against the live listing. The directory
/// monitor applies create/delete/move edits incrementally yet ignores pure
/// content writes, so a spawned writer's new file keeps its creation-time
/// size and icon. `refresh` re-enumerates and emits minimal `items-changed`
/// signals for only the new, changed or removed items, so untouched items
/// keep their widgets (no flash) while changed ones re-bind with correct
/// bytes and icons.
pub const Model = extern struct {
    parent_instance: Parent,

    pub const Parent = gobject.Object;
    pub const Implements = [_]type{gio.ListModel};
    const Self = @This();

    const Private = struct {
        source: *gtk.DirectoryList = undefined,
        items: std.ArrayList(*gio.FileInfo) = .empty,
        handler: c_ulong = 0,
        spare: ?*gtk.DirectoryList = null,
        spare_handler: c_ulong = 0,

        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "PhytoDirectoryModel",
        .instanceInit = init,
        .implements = &.{gobject.ext.implement(gio.ListModel, .{ .init = ifaceInit })},
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const Class = extern struct {
        parent_class: Parent.Class,
        pub const Instance = Self;
    };

    pub fn new(source: *gtk.DirectoryList) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const p = self.private();
        p.source = source;
        source.ref();
        p.handler = gio.ListModel.signals.items_changed.connect(source.as(gio.ListModel), *Self, sourceChanged, self, .{});
        const model = source.as(gio.ListModel);
        const n = model.getNItems();
        var i: c_uint = 0;
        while (i < n) : (i += 1) {
            const info: *gio.FileInfo = @ptrCast(model.getItem(i).?);
            p.items.append(a, info) catch unreachable;
        }
        return self;
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }
    pub fn ref(self: *Self) void {
        gobject.Object.ref(self.as(gobject.Object));
    }
    pub fn unref(self: *Self) void {
        gobject.Object.unref(self.as(gobject.Object));
    }

    /// Release the mirror's refs and detach from the source. The owning Tab
    /// calls this before dropping its reference during teardown.
    pub fn destroy(self: *Self) void {
        const p = self.private();
        if (p.handler != 0) {
            object.signalHandlerDisconnect(p.source.as(object.Object), p.handler);
            p.handler = 0;
        }
        if (p.spare) |s| {
            object.signalHandlerDisconnect(s.as(object.Object), p.spare_handler);
            p.spare_handler = 0;
            s.unref();
            p.spare = null;
        }
        for (p.items.items) |info| info.unref();
        p.items.deinit(a);
        p.source.unref();
    }

    fn private(self: *Self) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    fn init(self: *Self, _: *Self.Class) callconv(.c) void {
        self.private().items = .empty;
    }

    fn ifaceInit(iface: *gio.ListModel.Iface) callconv(.c) void {
        iface.f_get_item_type = getItemType;
        iface.f_get_n_items = getNItems;
        iface.f_get_item = getItem;
    }

    fn getItemType(_: *gio.ListModel) callconv(.c) usize {
        return gio.FileInfo.getGObjectType();
    }
    fn getNItems(list: *gio.ListModel) callconv(.c) c_uint {
        const self: *Self = @ptrCast(@alignCast(list));
        return @intCast(self.private().items.items.len);
    }
    fn getItem(list: *gio.ListModel, position: c_uint) callconv(.c) ?*gobject.Object {
        const self: *Self = @ptrCast(@alignCast(list));
        const p = self.private();
        if (position >= p.items.items.len) return null;
        const info = p.items.items[position];
        info.ref();
        return info.as(gobject.Object);
    }

    fn emit(self: *Self, position: c_uint, removed: c_uint, added: c_uint) void {
        gio.ListModel.itemsChanged(self.as(gio.ListModel), position, removed, added);
    }

    /// Mirror the source's incremental edits verbatim, keeping our own refs.
    fn sourceChanged(_: *gio.ListModel, position: c_uint, removed: c_uint, added: c_uint, self: *Self) callconv(.c) void {
        const p = self.private();
        var j: c_uint = 0;
        while (j < removed) : (j += 1) {
            const old = p.items.orderedRemove(position);
            old.unref();
        }
        const model = p.source.as(gio.ListModel);
        var k: c_uint = 0;
        while (k < added) : (k += 1) {
            const info: *gio.FileInfo = @ptrCast(model.getItem(position + k).?);
            p.items.insert(a, position + k, info) catch unreachable;
        }
        self.emit(position, removed, added);
    }

    /// Re-enumerate the current folder into a spare list and diff it against
    /// the live items once loading finishes.
    pub fn refresh(self: *Self) void {
        const p = self.private();
        if (p.spare != null) return;
        // getFile is transfer-none: the source owns the file, so do not unref.
        const file = p.source.getFile() orelse return;
        const spare = gtk.DirectoryList.new(attrs, null);
        spare.setIoPriority(200);
        spare.setMonitored(0);
        p.spare = spare;
        p.spare_handler = object.Object.signals.notify.connect(spare.as(object.Object), *Self, spareNotify, self, .{});
        spare.setFile(file);
        if (spare.isLoading() == 0) self.finishDiff();
    }

    fn spareNotify(_: *object.Object, _: *object.ParamSpec, self: *Self) callconv(.c) void {
        const p = self.private();
        if (p.spare) |s| {
            if (s.isLoading() == 0) self.finishDiff();
        }
    }

    fn finishDiff(self: *Self) void {
        const p = self.private();
        const spare = p.spare orelse return;
        p.spare = null;
        object.signalHandlerDisconnect(spare.as(object.Object), p.spare_handler);
        p.spare_handler = 0;
        defer spare.unref();
        if (spare.getError() != null) return;
        self.applyDiff(spare);
    }

    /// Refresh the attributes of items already in the listing. The directory
    /// monitor owns the item *set* (create/delete/move arrive incrementally
    /// through `sourceChanged`); re-adding or removing here would race the
    /// monitor and duplicate items. Content writes are what the monitor
    /// ignores, so only replace items whose rendered attributes changed —
    /// each replacement re-binds a single row (correct size/icon) without
    /// disturbing the rest of the view.
    fn applyDiff(self: *Self, spare: *gtk.DirectoryList) void {
        const p = self.private();
        var fresh = std.StringHashMap(*gio.FileInfo).init(a);
        defer {
            var it = fresh.valueIterator();
            while (it.next()) |info| info.*.unref();
            fresh.deinit();
        }
        const model = spare.as(gio.ListModel);
        const n = model.getNItems();
        var i: c_uint = 0;
        while (i < n) : (i += 1) {
            const info: *gio.FileInfo = @ptrCast(model.getItem(i).?);
            fresh.put(std.mem.span(info.getName()), info) catch unreachable;
        }
        for (p.items.items, 0..) |old, pos| {
            const replacement = fresh.get(std.mem.span(old.getName())) orelse continue;
            if (!sameInfo(old, replacement)) {
                replacement.ref();
                p.items.items[pos] = replacement;
                old.unref();
                self.emit(@intCast(pos), 1, 1);
            }
        }
    }
};

/// Whether two infos would render identically (name, kind, size, icon and
/// modification time). A difference means the item must re-bind.
fn sameInfo(l: *gio.FileInfo, r: *gio.FileInfo) bool {
    if (l.getFileType() != r.getFileType()) return false;
    if (l.getSize() != r.getSize()) return false;
    if (glib.strcmp0(l.getContentType() orelse "", r.getContentType() orelse "") != 0) return false;
    if (l.getAttributeUint64("time::modified") != r.getAttributeUint64("time::modified")) return false;
    if (l.getAttributeUint32("time::modified-usec") != r.getAttributeUint32("time::modified-usec")) return false;
    return true;
}
