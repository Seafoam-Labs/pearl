//! Pearl-owned GTK scene renderer. Guest values never become markup or CSS.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const glib = @import("glib2");
const m = @import("model.zig");
const Manager = @import("manager.zig").Manager;
const Slot = @import("manager.zig").Slot;
const a = std.heap.c_allocator;
const Item = struct { view: *View, node: m.Node, widget: *gtk.Widget, clip: ?m.Clip = null, frame: usize = 0, elapsed: i64 = 0, signal: c_ulong = 0 };
pub const View = struct {
    host: *gtk.Box,
    manager: *Manager,
    id: []u8,
    overlay: bool,
    slot: ?*Slot = null,
    shown: ?[]u8 = null,
    reduced_motion: bool = false,
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(*Item) = .empty,
    tick: c_uint = 0,
    pub fn create(host: *gtk.Box, manager: *Manager, id: []const u8, overlay: bool) !*View {
        const self = try a.create(View);
        self.* = .{ .host = host, .manager = manager, .id = try a.dupe(u8, id), .overlay = overlay, .arena = std.heap.ArenaAllocator.init(a) };
        self.update();
        return self;
    }
    fn clear(self: *View) void {
        if (self.tick != 0) self.host.as(gtk.Widget).removeTickCallback(self.tick);
        self.tick = 0;
        for (self.items.items) |item| if (item.signal != 0) @import("gobject2").signalHandlerDisconnect(item.widget.as(@import("gobject2").Object), item.signal);
        while (self.host.as(gtk.Widget).getFirstChild()) |child| self.host.remove(child);
        for (self.items.items) |item| a.destroy(item);
        self.items.clearRetainingCapacity();
        _ = self.arena.reset(.free_all);
        if (self.shown) |bytes| a.free(bytes);
        self.shown = null;
    }
    pub fn destroy(self: *View) void {
        self.clear();
        self.items.deinit(a);
        self.arena.deinit();
        a.free(self.id);
        a.destroy(self);
    }
    pub fn update(self: *View) void {
        var slot: ?*Slot = null;
        for (self.manager.slots.items) |candidate| if (std.mem.eql(u8, candidate.id(), self.id) and candidate.status == .active and candidate.scene != null) {
            slot = candidate;
            break;
        };
        if (slot) |current| {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const cfg = std.json.parseFromSliceLeaky(m.Config, arena.allocator(), current.config orelse "{}", .{}) catch {
                self.clear();
                return;
            };
            if ((cfg.placement.mode == .overlay) != self.overlay) slot = null;
        }
        self.slot = slot;
        const bytes = if (slot) |current| current.scene.? else "";
        if (self.shown) |old| if (std.mem.eql(u8, old, bytes) and self.reduced_motion == self.manager.reduced_motion) return;
        self.clear();
        self.reduced_motion = self.manager.reduced_motion;
        self.host.as(gtk.Widget).setVisible(@intFromBool(slot != null));
        if (slot == null) return;
        self.shown = a.dupe(u8, bytes) catch return;
        const alloc = self.arena.allocator();
        const scene = std.json.parseFromSliceLeaky(m.Scene, alloc, bytes, .{ .allocate = .alloc_always }) catch return;
        for (scene.nodes) |node| {
            const widget = switch (node.kind) {
                .label => blk: {
                    const label = gtk.Label.new(alloc.dupeZ(u8, node.text) catch continue);
                    label.as(gtk.Widget).addCssClass("pearl-plugin-label");
                    label.setMaxWidthChars(40);
                    label.setEllipsize(.end);
                    break :blk label.as(gtk.Widget);
                },
                .button => blk: {
                    const button = gtk.Button.newWithLabel(alloc.dupeZ(u8, node.text) catch continue);
                    if (button.getChild()) |child| if (@import("gobject2").ext.cast(gtk.Label, child)) |label| {
                        label.setEllipsize(.end);
                        label.setMaxWidthChars(24);
                    };
                    break :blk button.as(gtk.Widget);
                },
                .image => blk: {
                    const picture = gtk.Picture.new();
                    picture.setCanShrink(1);
                    picture.setContentFit(.contain);
                    picture.setAlternativeText(alloc.dupeZ(u8, node.text) catch continue);
                    picture.as(gtk.Widget).setSizeRequest(if (self.overlay) 96 else 32, if (self.overlay) 72 else 32);
                    break :blk picture.as(gtk.Widget);
                },
            };
            const item = a.create(Item) catch continue;
            item.* = .{ .view = self, .node = node, .widget = widget };
            self.items.append(a, item) catch {
                a.destroy(item);
                continue;
            };
            self.host.append(widget);
            if (node.kind == .button) item.signal = gtk.Button.signals.clicked.connect(@import("gobject2").ext.cast(gtk.Button, widget).?, *Item, clicked, item, .{});
            if (node.kind == .image) {
                if (node.clip.len > 0) item.clip = slot.?.entry.package.manifest.findClip(node.clip);
                self.paint(item);
            }
        }
        var animated = false;
        for (self.items.items) |item| if (item.clip) |clip| {
            if (clip.frames.len > 1) animated = true;
        };
        if (animated and !self.manager.reduced_motion) self.tick = self.host.as(gtk.Widget).addTickCallback(frame, self, null);
    }
    fn clicked(_: *gtk.Button, item: *Item) callconv(.c) void {
        if (item.view.slot) |slot| slot.send(.{ .kind = .click, .node = item.node.id, .reduced_motion = item.view.manager.reduced_motion }) catch {};
    }
    fn paint(self: *View, item: *Item) void {
        const slot = self.slot orelse return;
        const asset = if (item.clip) |clip| clip.frames[item.frame].asset else item.node.asset;
        for (slot.entry.package.images, slot.entry.images) |source, decoded| if (std.mem.eql(u8, source.id, asset)) {
            const crop = if (item.clip) |clip| blk: {
                const f = clip.frames[item.frame];
                break :blk decoded.newSubpixbuf(f.x, f.y, f.width, f.height);
            } else decoded.ref();
            defer crop.unref();
            const texture = gdk.Texture.newForPixbuf(crop);
            defer texture.unref();
            @import("gobject2").ext.cast(gtk.Picture, item.widget).?.setPaintable(texture.as(gdk.Paintable));
            return;
        };
    }
    fn frame(_: *gtk.Widget, clock: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(data.?));
        if (self.manager.reduced_motion or self.manager.locked) {
            self.tick = 0;
            return 0;
        }
        const now = clock.getFrameTime();
        var animated = false;
        for (self.items.items) |item| if (item.clip) |clip| {
            if (clip.loop or item.frame + 1 < clip.frames.len) animated = true;
            if (item.elapsed == 0) item.elapsed = now;
            if (now - item.elapsed < @as(i64, clip.frames[item.frame].duration_ms) * 1000) continue;
            if (item.frame + 1 == clip.frames.len and !clip.loop) continue;
            item.frame = (item.frame + 1) % clip.frames.len;
            item.elapsed = now;
            self.paint(item);
        };
        if (!animated) {
            self.tick = 0;
            return 0;
        }
        return 1;
    }
};
