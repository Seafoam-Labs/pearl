//! Managed, output-bound layer surfaces. Plugins never own native windows.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const object = @import("gobject2");
const layer = @import("gtk4layershell1");
const native = @import("../platform/wayland/effects.zig");
const m = @import("model.zig");
const View = @import("view.zig").View;
const a = std.heap.c_allocator;
pub const Overlay = struct {
    window: *gtk.Window,
    view: *View,
    effects: native.Surface = undefined,
    preferences: *@import("../config/service.zig").Service,
    config: m.Placement = .{},
    available_width: i32 = 1,
    available_height: i32 = 1,
    x: i32 = 0,
    y: i32 = 0,
    seen: bool = false,
    pub fn create(app: *gtk.Application, monitor: *gdk.Monitor, effects: *native.Effects, manager: *@import("manager.zig").Manager, preferences: *@import("../config/service.zig").Service, id: []const u8) !*Overlay {
        const self = try a.create(Overlay);
        errdefer a.destroy(self);
        const window = gtk.Window.new();
        _ = window.as(object.Object).refSink();
        errdefer {
            window.destroy();
            window.unref();
        }
        window.setApplication(app);
        window.setDecorated(0);
        window.setTitle("Pearl plugin");
        window.as(gtk.Widget).addCssClass("pearl-root");
        window.as(gtk.Widget).addCssClass("pearl-shell");
        layer.initForWindow(window);
        layer.setNamespace(window, "pearl:plugin");
        layer.setMonitor(window, monitor);
        layer.setLayer(window, .top);
        layer.setKeyboardMode(window, .none);
        layer.setExclusiveZone(window, 0);
        layer.setAnchor(window, .left, 1);
        layer.setAnchor(window, .top, 1);
        const panel = gtk.Box.new(.vertical, 4);
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.external, .external);
        scroll.setChild(panel.as(gtk.Widget));
        window.setChild(scroll.as(gtk.Widget));
        self.* = .{ .window = window, .view = try View.create(panel, manager, id, true), .preferences = preferences };
        try self.effects.init(effects, window, scroll.as(gtk.Widget), false, .empty);
        const drag = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *Overlay, dragged, self, .{});
        window.as(gtk.Widget).addController(drag.as(gtk.EventController));
        return self;
    }
    pub fn destroy(self: *Overlay) void {
        self.effects.deinit();
        self.view.destroy();
        self.window.destroy();
        self.window.unref();
        a.destroy(self);
    }
    pub fn update(self: *Overlay, cfg: m.Placement, width: i32, height: i32, hidden: bool) void {
        self.seen = true;
        self.config = cfg;
        self.config.output = "";
        self.available_width = width;
        self.available_height = height;
        self.x = @min(cfg.x, @max(0, width - cfg.width));
        self.y = @min(cfg.y, @max(0, height - cfg.height));
        layer.setMargin(self.window, .left, self.x);
        layer.setMargin(self.window, .top, self.y);
        self.window.setDefaultSize(@min(width, cfg.width), @min(height, cfg.height));
        self.effects.input = if (cfg.interactive or !cfg.locked) .panel else .empty;
        self.effects.last = null;
        self.effects.refresh();
        self.view.update();
        self.preferences.style(self.window.as(gtk.Widget), self.view.host.as(gtk.Widget));
        self.window.as(gtk.Widget).setVisible(@intFromBool(!hidden));
    }
    fn dragged(_: *gtk.GestureDrag, dx: f64, dy: f64, self: *Overlay) callconv(.c) void {
        if (self.config.locked or self.view.manager.locked or !std.math.isFinite(dx) or !std.math.isFinite(dy)) return;
        // A concurrent Settings draft remains authoritative; don't overwrite it.
        if (self.preferences.draft.text != null) return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var prefs = self.preferences.prefs();
        const entries = alloc.dupe(m.Config, prefs.plugins.entries) catch return;
        for (entries) |*entry| if (std.mem.eql(u8, entry.id, self.view.id)) {
            entry.placement.x = @intFromFloat(@min(65535, @max(0, @min(@as(f64, @floatFromInt(self.available_width - self.config.width)), @as(f64, @floatFromInt(self.x)) + dx))));
            entry.placement.y = @intFromFloat(@min(65535, @max(0, @min(@as(f64, @floatFromInt(self.available_height - self.config.height)), @as(f64, @floatFromInt(self.y)) + dy))));
        };
        prefs.plugins.entries = entries;
        const bytes = std.json.Stringify.valueAlloc(alloc, prefs, .{}) catch return;
        self.preferences.apply(bytes, self.preferences.revision) catch {};
    }
};
