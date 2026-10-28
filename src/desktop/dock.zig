//! Per-output taskbar. GTK owns surfaces; only authoritative Aqueous IDs cross callbacks.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const unix = @import("giounix2");
const glib = @import("glib2");
const object = @import("gobject2");
const layer = @import("gtk4layershell1");
const native = @import("../platform/wayland/effects.zig");
const Apps = @import("apps.zig");
const e = @import("../aqueous/entities.zig");
const Client = @import("../aqueous/client.zig").Client;
const Preferences = @import("../config/service.zig").Service;
const p = @import("dock_policy.zig");
const placement = @import("../ui/surfaces/policy.zig");
const w = @import("../ui/components/widgets.zig");
const log = std.log.scoped(.desktop);
const a = std.heap.c_allocator;
const fade_ms: f64 = 180;
const fade_step_ms: c_uint = 16;
const identity = @import("app_identity.zig");
const TaskApps = @import("task_apps.zig");
const Picker = @import("launcher_picker.zig");
const Action = enum { activate, launch, pin, unpin, minimize, maximize, close, choose_launcher };
const Callback = struct { dock: *Dock, action: Action, id: [:0]const u8, value: bool = false, desktop_action: ?[:0]const u8 = null, resolution_hash: u64 = 0, window_id: ?[:0]const u8 = null, desktop_id: ?[:0]const u8 = null, picker: ?Picker.Request = null };
const Group = struct { key: []const u8, desktop: ?[]const u8, pinned: bool, windows: std.ArrayList(*const e.Window) = .empty };
/// In-process drag state. Reordering never leaves GTK: a Wayland data-source
/// drag that ends outside a drop target crashes Aqueous (wlroots XWM
/// use-after-free in xwm_set_drag_focus), so the dock tracks the pointer
/// itself with a gesture and hit-tests the panel. Slots slide live: the
/// grabbed slot is translated to the hovered position and the slots in
/// between shift one step, Windows-taskbar style.
const DragBinding = struct {
    dock: *Dock,
    key: [*:0]const u8,
    widget: *gtk.Widget,
    box: *gtk.Widget,
    icon: *gtk.Image,
    pins: usize,
    start_x: f64 = 0,
    start_y: f64 = 0,
    origin_x: f64 = 0,
    origin_y: f64 = 0,
    /// Panel-to-window offset; the ghost layer lives in window coordinates.
    win_x: f64 = 0,
    win_y: f64 = 0,
    src_index: usize = 0,
    step: f64 = 0,
    target: usize = 0,
    hover_after: bool = false,
    /// Pointer visited a real slot at least once; distinguishes a sweep from
    /// a click that never moved off the source icon.
    dragged: bool = false,
};
pub const Dock = struct {
    client: *Client,
    index: *Apps.Index,
    tasks: *TaskApps.Store,
    preferences: *Preferences,
    output: []const u8,
    window: *gtk.Window,
    sensor: *gtk.Window,
    panel: *gtk.Box,
    scroll: *gtk.ScrolledWindow,
    /// Hosts the drag ghost above the scroll content; never targets input.
    fixed: *gtk.Fixed,
    ghost: *gtk.Image,
    effects: native.Surface = undefined,
    arena: std.heap.ArenaAllocator,
    menus: std.ArrayList(*gtk.Popover) = .empty,
    hash: ?u64 = null,
    config: p.Config = .{},
    background_css: ?*gtk.CssProvider = null,
    drag_css: ?*gtk.CssProvider = null,
    /// Id whose reorder just landed; the next build plays the settle animation on its slot.
    landed: ?[:0]u8 = null,
    background_opacity: @import("bar_opacity.zig").Config = .{},
    background_color: ?gdk.RGBA = null,
    bounds: placement.Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    rect: placement.Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    reason: p.Reason = .empty,
    count: usize = 0,
    truncated: bool = false,
    /// Edge-direction thickness including margin, reserved as exclusive zone in `always` mode.
    thickness: i32 = 0,
    hover: bool = false,
    dragging: bool = false,
    keyboard: bool = false,
    locked: bool = true,
    fullscreen: bool = false,
    obstructed: bool = false,
    timer: c_uint = 0,
    fade: c_uint = 0,
    fade_start: i64 = 0,
    fade_from: f64 = 1,
    fade_to: f64 = 1,
    shown: bool = false,
    destroying: bool = false,
    appearance: u64 = std.math.maxInt(u64),
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    choose_launcher: ?*const fn (*anyopaque, []const u8, Picker.Request) anyerror!void = null,
    pub fn create(app: *gtk.Application, monitor: *gdk.Monitor, effects: *native.Effects, client: *Client, index: *Apps.Index, tasks: *TaskApps.Store, preferences: *Preferences, output: []const u8, context: *anyopaque, changed: *const fn (*anyopaque) void) !*Dock {
        const self = try a.create(Dock);
        errdefer a.destroy(self);
        const window = gtk.Window.new();
        _ = window.as(object.Object).refSink();
        errdefer {
            window.destroy();
            window.unref();
        }
        const sensor = gtk.Window.new();
        _ = sensor.as(object.Object).refSink();
        errdefer {
            sensor.destroy();
            sensor.unref();
        }
        const panel = gtk.Box.new(.horizontal, 4);
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPropagateNaturalWidth(1);
        scroll.setPropagateNaturalHeight(1);
        scroll.setChild(panel.as(gtk.Widget));
        // The drag ghost floats above the scroll content; pass-through and
        // can-target keep it from stealing events from the dock buttons.
        const overlay = gtk.Overlay.new();
        overlay.setChild(scroll.as(gtk.Widget));
        const fixed = gtk.Fixed.new();
        fixed.as(gtk.Widget).setCanTarget(0);
        const ghost = gtk.Image.new();
        ghost.as(gtk.Widget).addCssClass("pearl-dock-ghost");
        ghost.as(gtk.Widget).setVisible(0);
        fixed.put(ghost.as(gtk.Widget), 0, 0);
        overlay.addOverlay(fixed.as(gtk.Widget));
        overlay.setClipOverlay(fixed.as(gtk.Widget), 1);
        window.setChild(overlay.as(gtk.Widget));
        // A transparent render node maps the reveal strip even without visible pixels.
        const pixels = glib.Bytes.newStatic(&[_]u8{ 0, 0, 0, 0 }, 4);
        defer pixels.unref();
        const texture = gdk.MemoryTexture.new(1, 1, .r8g8b8a8_premultiplied, pixels, 4);
        defer texture.unref();
        const picture = gtk.Picture.newForPaintable(texture.as(gdk.Paintable));
        picture.setContentFit(.fill);
        sensor.setChild(picture.as(gtk.Widget));
        for ([_]*gtk.Window{ window, sensor }, 0..) |win, i| {
            win.setApplication(app);
            win.setDecorated(0);
            win.setTitle(if (i == 0) @import("i18n").dtr("pearl", "Pearl dock") else @import("i18n").dtr("pearl", "Pearl dock reveal"));
            win.as(gtk.Widget).addCssClass("pearl-root");
            win.as(gtk.Widget).addCssClass("pearl-shell");
            layer.initForWindow(win);
            layer.setMonitor(win, monitor);
            layer.setNamespace(win, if (i == 0) "pearl:dock" else "pearl:dock-reveal");
            layer.setLayer(win, if (i == 0) .top else .overlay);
            layer.setExclusiveZone(win, -1);
            layer.setKeyboardMode(win, .none);
        }
        scroll.as(gtk.Widget).addCssClass("pearl-surface-panel");
        panel.as(gtk.Widget).addCssClass("pearl-dock");
        w.name(panel.as(gtk.Widget), @import("i18n").dtr("pearl", "Applications dock"));
        self.* = .{ .client = client, .index = index, .tasks = tasks, .preferences = preferences, .output = output, .window = window, .sensor = sensor, .panel = panel, .scroll = scroll, .fixed = fixed, .ghost = ghost, .arena = .init(a), .context = context, .changed = changed };
        try self.effects.init(effects, window, scroll.as(gtk.Widget), true, .panel);
        self.effects.geometry_context = self;
        self.effects.geometry_changed = measured;
        for ([_]*gtk.Window{ window, sensor }) |win| {
            const motion = gtk.EventControllerMotion.new();
            _ = gtk.EventControllerMotion.signals.enter.connect(motion, *Dock, entered, self, .{});
            _ = gtk.EventControllerMotion.signals.leave.connect(motion, *Dock, left, self, .{});
            win.as(gtk.Widget).addController(motion.as(gtk.EventController));
        }
        const keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Dock, key, self, .{});
        window.as(gtk.Widget).addController(keys.as(gtk.EventController));
        return self;
    }
    pub fn destroy(self: *Dock) void {
        self.destroying = true;
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.stopFade();
        self.effects.deinit();
        self.clear();
        if (self.background_css) |provider| {
            self.scroll.as(gtk.Widget).getStyleContext().removeProvider(provider.as(gtk.StyleProvider));
            provider.unref();
        }
        if (self.drag_css) |provider| {
            self.panel.as(gtk.Widget).getStyleContext().removeProvider(provider.as(gtk.StyleProvider));
            provider.unref();
        }
        if (self.landed) |id| a.free(id);
        self.window.destroy();
        self.window.unref();
        self.sensor.destroy();
        self.sensor.unref();
        self.arena.deinit();
        self.menus.deinit(a);
        a.destroy(self);
    }
    fn clear(self: *Dock) void {
        for (self.menus.items) |menu| {
            menu.popdown();
            menu.as(gtk.Widget).unparent();
        }
        self.menus.clearRetainingCapacity();
        while (self.panel.as(gtk.Widget).getFirstChild()) |child| self.panel.remove(child);
        _ = self.arena.reset(.free_all);
    }
    fn installed(self: *Dock, id: []const u8) ?Apps.Entry {
        if (self.index.catalog) |catalog| for (catalog.entries.items) |entry| {
            if (entry.action == null and std.mem.eql(u8, id, entry.id)) return entry;
        };
        return null;
    }
    fn match(self: *Dock, win: *const e.Window) ?[]const u8 {
        return self.tasks.match(win.*, self.preferences.prefs().application_launchers, self.preferences.prefs().pinned_apps);
    }
    pub fn setBackgroundOpacity(self: *Dock, config: @import("bar_opacity.zig").Config, color: gdk.RGBA) !void {
        const alpha = config.alpha();
        var resolved = color;
        resolved.f_alpha = alpha orelse 1;
        if (std.meta.eql(self.background_opacity, config) and (alpha == null or (self.background_color != null and std.meta.eql(self.background_color.?, resolved)))) return;
        if (alpha != null) {
            const css = try std.fmt.allocPrintSentinel(a, ".pearl-surface-panel {{ background: rgba({d}, {d}, {d}, {d:.2}); }}", .{ @as(u8, @intFromFloat(@round(resolved.f_red * 255))), @as(u8, @intFromFloat(@round(resolved.f_green * 255))), @as(u8, @intFromFloat(@round(resolved.f_blue * 255))), resolved.f_alpha }, 0);
            defer a.free(css);
            if (self.background_css == null) {
                self.background_css = gtk.CssProvider.new();
                self.scroll.as(gtk.Widget).getStyleContext().addProvider(self.background_css.?.as(gtk.StyleProvider), 602);
            }
            self.background_css.?.loadFromString(css);
        } else if (self.background_css) |provider| provider.loadFromString("");
        self.background_color = if (alpha != null) resolved else null;
        self.background_opacity = config;
    }
    pub fn update(self: *Dock, config: p.Config, bar_edge: placement.Edge, bounds: placement.Rect, locked: bool) !void {
        var next = config;
        next.edge = p.edge(config.edge, bar_edge);
        self.config = next;
        self.bounds = bounds;
        self.locked = locked;
        if (locked) {
            self.keyboard = false;
            self.hover = false;
            for (self.menus.items) |menu| menu.popdown();
        }
        if (self.appearance != self.preferences.appearance) {
            self.appearance = self.preferences.appearance;
            self.preferences.style(self.window.as(gtk.Widget), self.scroll.as(gtk.Widget));
            self.preferences.style(self.sensor.as(gtk.Widget), self.sensor.getChild().?);
            self.sensor.getChild().?.removeCssClass("background");
        }
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const alloc = temp.allocator();
        const windows = try self.client.model.windows(alloc, .{ .output = self.output });
        var groups: std.ArrayList(Group) = .empty;
        for (self.preferences.prefs().pinned_apps) |id| try groups.append(alloc, .{ .key = id, .desktop = id, .pinned = true });
        self.truncated = false;
        for (windows) |win| {
            if (!p.eligible(win.*, self.output)) continue;
            const desktop = self.match(win);
            const id = desktop orelse try std.fmt.allocPrint(alloc, "window-app:{s}", .{win.app_id orelse win.class orelse win.id});
            var found: ?usize = null;
            for (groups.items, 0..) |group, i| if (std.mem.eql(u8, group.key, id)) {
                found = i;
                break;
            };
            if (found == null) {
                if (groups.items.len == 32) {
                    self.truncated = true;
                    continue;
                }
                found = groups.items.len;
                try groups.append(alloc, .{ .key = id, .desktop = desktop, .pinned = false });
            }
            const group = &groups.items[found.?];
            if (group.windows.items.len < 64) try group.windows.append(alloc, win) else self.truncated = true;
        }
        self.count = groups.items.len;
        var digest = std.hash.Wyhash.init(0);
        digest.update(try std.json.Stringify.valueAlloc(alloc, .{ self.index.generation, next, self.preferences.appearance, @import("app_identity.zig").digest(self.preferences.prefs().application_launchers) }, .{}));
        for (groups.items) |group| {
            digest.update(try std.json.Stringify.valueAlloc(alloc, .{ group.key, group.desktop, group.pinned }, .{}));
            for (group.windows.items) |win| digest.update(try std.json.Stringify.valueAlloc(alloc, .{ win.id, win.title, win.focused, win.minimized, win.maximized, win.visible, win.can_activate, win.can_minimize, win.can_maximize }, .{}));
        }
        const hash = digest.final();
        // Keep menu callback storage alive until GTK closes it; reconcile next event/timer.
        if (self.hash == null or self.hash.? != hash) {
            var menu_open = false;
            for (self.menus.items) |menu| if (menu.as(gtk.Widget).getVisible() != 0) {
                menu_open = true;
            };
            // A rebuild frees the arena-backed drag bindings; defer it until the
            // gesture ends, which re-syncs via `changed`.
            if (!menu_open and !self.dragging) {
                try self.build(groups.items);
                self.hash = hash;
            }
        }
        self.position();
        self.visibility();
    }
    fn visibility(self: *Dock) void {
        self.fullscreen = false;
        self.obstructed = false;
        var it = self.client.model.entities.valueIterator();
        while (it.next()) |entity| if (entity.* == .window) {
            const win = entity.window;
            if (win.output == null or !std.mem.eql(u8, win.output.?, self.output)) continue;
            if (win.visible and !win.minimized and win.fullscreen) self.fullscreen = true;
            if (p.overlaps(win, self.output, self.rect)) self.obstructed = true;
        };
        self.showState();
    }
    fn measured(context: *anyopaque) void {
        const self: *Dock = @ptrCast(@alignCast(context));
        if (self.destroying) return;
        self.position();
        self.visibility();
    }
    fn menuClosed(_: *gtk.Popover, self: *Dock) callconv(.c) void {
        if (!self.destroying) self.changed(self.context);
    }
    fn position(self: *Dock) void {
        const vertical = self.config.edge == .left or self.config.edge == .right;
        self.panel.as(gtk.Orientable).setOrientation(if (vertical) .vertical else .horizontal);
        // Drives the insertion-indicator CSS, which flips with the dock edge.
        if (vertical) self.panel.as(gtk.Widget).addCssClass("pearl-dock-vertical") else self.panel.as(gtk.Widget).removeCssClass("pearl-dock-vertical");
        const length = @max(1, (if (vertical) self.bounds.height else self.bounds.width) - 64);
        self.scroll.setPolicy(if (vertical) .never else .automatic, if (vertical) .automatic else .never);
        self.scroll.setMaxContentWidth(if (vertical) -1 else length);
        self.scroll.setMaxContentHeight(if (vertical) length else -1);
        const estimate: i32 = @intCast(@max(1, self.count) * (@as(usize, self.config.icon_size) + 36) + 12);
        const width = if (vertical) @as(i32, self.config.icon_size) + 40 else @min(length, estimate);
        const height = if (vertical) @min(length, estimate) else @as(i32, self.config.icon_size) + 40;
        // Horizontal docks hug their content height; the forced estimate left
        // dead space below the icons once the indicator got tighter.
        self.window.setDefaultSize(if (vertical) width else -1, -1);
        for ([_]*gtk.Window{ self.window, self.sensor }) |win| {
            inline for (std.meta.tags(placement.Edge)) |edge| {
                const native_edge: layer.Edge = switch (edge) {
                    .top => .top,
                    .right => .right,
                    .bottom => .bottom,
                    .left => .left,
                };
                layer.setAnchor(win, native_edge, @intFromBool(edge == self.config.edge));
                layer.setMargin(win, native_edge, if (win == self.window and edge == self.config.edge) self.config.margin else 0);
            }
        }
        const actual_width = if (self.window.as(gtk.Widget).getWidth() > 0) self.window.as(gtk.Widget).getWidth() else width;
        const actual_height = if (self.window.as(gtk.Widget).getHeight() > 0) self.window.as(gtk.Widget).getHeight() else height;
        self.thickness = (if (vertical) actual_width else actual_height) + @as(i32, self.config.margin);
        // Fill the margin gap between the screen edge and the dock so the
        // pointer never crosses dead space where both surfaces lose hover.
        const strip = @max(2, @as(i32, self.config.margin));
        self.sensor.setDefaultSize(if (vertical) strip else actual_width, if (vertical) actual_height else strip);
        self.rect = .{ .x = self.bounds.x + @divTrunc(self.bounds.width - actual_width, 2), .y = self.bounds.y + @divTrunc(self.bounds.height - actual_height, 2), .width = actual_width, .height = actual_height };
        switch (self.config.edge) {
            .top => self.rect.y = self.bounds.y + self.config.margin,
            .bottom => self.rect.y = self.bounds.y + self.bounds.height - actual_height - self.config.margin,
            .left => self.rect.x = self.bounds.x + self.config.margin,
            .right => self.rect.x = self.bounds.x + self.bounds.width - actual_width - self.config.margin,
        }
    }
    fn showState(self: *Dock) void {
        var interaction = self.hover or self.dragging;
        for (self.menus.items) |menu| if (menu.as(gtk.Widget).getVisible() != 0) {
            interaction = true;
        };
        self.reason = p.visibility(self.config, self.locked, self.count == 0, interaction, self.keyboard, self.fullscreen, self.obstructed);
        const shown = p.shown(self.reason);
        layer.setLayer(self.window, if (shown and self.fullscreen) .overlay else .top);
        layer.setKeyboardMode(self.window, if (shown and self.keyboard) .exclusive else .none);
        // Mirror the bar: `always` reserves space so applications avoid the dock;
        // other modes float above them.
        layer.setExclusiveZone(self.window, if (shown and self.config.mode == .always and !self.fullscreen) self.thickness else -1);
        if (self.shown != shown) {
            self.shown = shown;
            self.animate(shown);
        }
        self.sensor.as(gtk.Widget).setVisible(@intFromBool(self.config.enabled and !self.locked and self.count != 0));
    }
    /// Fades the dock instead of popping it; autohide and intelligent animate,
    /// and reduced motion keeps the instant switch.
    fn animate(self: *Dock, show: bool) void {
        const widget = self.window.as(gtk.Widget);
        if (self.config.mode == .always or widget.hasCssClass("pearl-reduced-motion") != 0) {
            self.stopFade();
            widget.setOpacity(1);
            widget.setVisible(@intFromBool(show));
            return;
        }
        const was_visible = widget.getVisible() != 0;
        self.fade_from = if (was_visible) widget.getOpacity() else 0;
        self.fade_to = if (show) 1 else 0;
        self.fade_start = @divTrunc(glib.getMonotonicTime(), 1000);
        if (show) {
            if (!was_visible) widget.setOpacity(0);
            widget.setVisible(1);
        }
        if (self.fade == 0) self.fade = glib.timeoutAdd(fade_step_ms, fadeStep, self);
    }
    fn stopFade(self: *Dock) void {
        if (self.fade != 0) _ = glib.Source.remove(self.fade);
        self.fade = 0;
    }
    fn fadeStep(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Dock = @ptrCast(@alignCast(data.?));
        self.fade = 0;
        if (self.destroying) return 0;
        const widget = self.window.as(gtk.Widget);
        const elapsed = @divTrunc(glib.getMonotonicTime(), 1000) - self.fade_start;
        const t = @min(1.0, @max(0.0, @as(f64, @floatFromInt(elapsed)) / fade_ms));
        const eased = 1 - std.math.pow(f64, 1 - t, 3);
        widget.setOpacity(self.fade_from + (self.fade_to - self.fade_from) * eased);
        if (t >= 1.0) {
            if (self.fade_to == 0) widget.setVisible(0);
            return 0;
        }
        self.fade = glib.timeoutAdd(fade_step_ms, fadeStep, self);
        return 0;
    }
    pub fn reveal(self: *Dock, value: bool) void {
        self.keyboard = value;
        self.hover = false;
        if (!value) for (self.menus.items) |menu| {
            menu.popdown();
        };
        self.showState();
        if (value) if (self.panel.as(gtk.Widget).getFirstChild()) |group| if (group.getFirstChild()) |button_| {
            _ = button_.grabFocus();
        };
    }
    fn entered(_: *gtk.EventControllerMotion, _: f64, _: f64, self: *Dock) callconv(.c) void {
        if (self.destroying) return;
        if (self.timer != 0) {
            _ = glib.Source.remove(self.timer);
            self.timer = 0;
        }
        self.hover = true;
        self.showState();
    }
    fn left(_: *gtk.EventControllerMotion, self: *Dock) callconv(.c) void {
        if (!self.destroying and !self.dragging and self.timer == 0) self.timer = glib.timeoutAdd(450, hideLater, self);
    }
    fn hideLater(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Dock = @ptrCast(@alignCast(data.?));
        self.timer = 0;
        self.hover = false;
        self.showState();
        return 0;
    }
    fn key(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, self: *Dock) callconv(.c) c_int {
        if (keyval == 0xff1b) {
            self.reveal(false);
            return 1;
        }
        const direction: gtk.DirectionType = switch (keyval) {
            0xff51, 0xff52 => .tab_backward,
            0xff53, 0xff54 => .tab_forward,
            else => return 0,
        };
        for (self.menus.items) |menu| if (menu.as(gtk.Widget).getVisible() != 0) {
            _ = menu.as(gtk.Widget).childFocus(direction);
            return 1;
        };
        _ = self.panel.as(gtk.Widget).childFocus(direction);
        return 1;
    }
    fn resolutionHash(self: *const Dock) u64 {
        const prefs = self.preferences.prefs();
        const values = [_]u64{ identity.digest(prefs.application_launchers), identity.pinDigest(prefs.pinned_apps), self.index.generation };
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&values));
    }
    fn button(self: *Dock, text: [:0]const u8, action: Action, id: []const u8, value: bool, desktop_action: ?[]const u8, window_id: ?[]const u8, desktop_id: ?[]const u8) !*gtk.Button {
        const alloc = self.arena.allocator();
        const cb = try alloc.create(Callback);
        cb.* = .{ .dock = self, .resolution_hash = self.resolutionHash(), .window_id = if (window_id) |v| try alloc.dupeSentinel(u8, v, 0) else null, .action = action, .id = try alloc.dupeSentinel(u8, id, 0), .value = value, .desktop_action = if (desktop_action) |v| try alloc.dupeSentinel(u8, v, 0) else null, .desktop_id = if (desktop_id) |v| try alloc.dupeSentinel(u8, v, 0) else null };
        const button_ = gtk.Button.newWithLabel(text);
        w.name(button_.as(gtk.Widget), text);
        if (button_.getChild()) |child| if (object.ext.cast(gtk.Label, child)) |label| {
            label.setEllipsize(.end);
            label.setMaxWidthChars(36);
        };
        _ = gtk.Button.signals.clicked.connect(button_, *Callback, clicked, cb, .{});
        return button_;
    }
    fn build(self: *Dock, groups: []Group) !void {
        self.clear();
        const alloc = self.arena.allocator();
        // Pinned groups are built first, so they occupy the leading positions.
        var pins: usize = 0;
        for (groups) |group| {
            if (group.pinned) pins += 1;
        }
        // Slide transitions for the live drag; transform values are reloaded
        // per hover change in `loadDragCss`.
        if (self.drag_css == null) {
            self.drag_css = gtk.CssProvider.new();
            self.panel.as(gtk.Widget).getStyleContext().addProvider(self.drag_css.?.as(gtk.StyleProvider), 601);
        }
        self.loadDragCss(false, 0, 0);
        for (groups) |group| {
            const entry = if (group.desktop) |id| self.installed(id) else null;
            const title = if (entry) |v| v.name else if (group.desktop) |id| try std.fmt.allocPrintSentinel(alloc, "{s} — launcher unavailable", .{id}, 0) else if (group.windows.items.len > 0) group.windows.items[0].app_id orelse group.windows.items[0].class orelse "Application" else group.key;
            var focused = false;
            var minimized = false;
            var hidden = false;
            var target: ?*const e.Window = null;
            for (group.windows.items, 0..) |win, i| {
                if (target == null) target = win;
                if (win.focused) {
                    focused = true;
                    target = group.windows.items[(i + 1) % group.windows.items.len];
                }
                minimized = minimized or win.minimized;
                hidden = hidden or (!win.visible and !win.minimized);
            }
            const description = try std.fmt.allocPrintSentinel(alloc, "{s} — {d} running{s}{s}{s}{s}", .{ title, group.windows.items.len, if (focused) ", focused" else "", if (minimized) ", minimized windows" else "", if (hidden) ", hidden windows" else "", if (group.pinned) ", pinned" else "" }, 0);
            const box = gtk.Box.new(.horizontal, 0);
            // One-shot settle animation on the slot the last reorder landed in.
            if (self.landed) |id| if (group.desktop != null and std.mem.eql(u8, id, group.desktop.?)) {
                box.as(gtk.Widget).addCssClass("pearl-drop-landed");
                a.free(id);
                self.landed = null;
            };
            const primary = try self.button(description, if (target != null) .activate else .launch, if (target) |win| win.id else group.desktop.?, false, null, null, if (target != null) group.desktop else null);
            primary.as(gtk.Widget).setTooltipText(description);
            if (target == null and entry == null) primary.as(gtk.Widget).setSensitive(1); // Keep context menu and Unpin reachable.
            // Keep the icon reachable so unavailable pins can still be unpinned.
            if (focused) primary.as(gtk.Widget).addCssClass("focused");
            const content = gtk.Box.new(.vertical, 0);
            const icon = if (entry != null and entry.?.info.getIcon() != null and gtk.IconTheme.getForDisplay(self.window.as(gtk.Widget).getDisplay()).hasGicon(entry.?.info.getIcon().?) != 0) gtk.Image.newFromGicon(entry.?.info.getIcon().?) else gtk.Image.newFromIconName("pearl-application-x-executable-symbolic");
            icon.setPixelSize(self.config.icon_size);
            content.append(icon.as(gtk.Widget));
            const indicator = if (group.windows.items.len > 1) try std.fmt.allocPrintSentinel(alloc, "{s} {d}", .{ if (focused) "●" else "•", group.windows.items.len }, 0) else if (focused) "●" else if (minimized) "◦" else if (group.windows.items.len > 0) "•" else "";
            const indicator_label = gtk.Label.new(indicator);
            indicator_label.as(gtk.Widget).addCssClass("pearl-dock-indicator");
            content.append(indicator_label.as(gtk.Widget));
            primary.setChild(content.as(gtk.Widget));
            box.append(primary.as(gtk.Widget));
            if (group.pinned) if (group.desktop) |id| {
                const drag = try alloc.create(DragBinding);
                drag.* = .{ .dock = self, .key = try alloc.dupeSentinel(u8, id, 0), .widget = primary.as(gtk.Widget), .box = box.as(gtk.Widget), .icon = icon, .pins = pins };
                const gesture = gtk.GestureDrag.new();
                _ = gtk.GestureDrag.signals.drag_begin.connect(gesture, *DragBinding, dragBegan, drag, .{});
                _ = gtk.GestureDrag.signals.drag_update.connect(gesture, *DragBinding, dragMoved, drag, .{});
                _ = gtk.GestureDrag.signals.drag_end.connect(gesture, *DragBinding, dragDone, drag, .{});
                primary.as(gtk.Widget).addController(gesture.as(gtk.EventController));
            };
            const menu = gtk.Popover.new();
            w.name(menu.as(gtk.Widget), try std.fmt.allocPrintSentinel(alloc, "Actions for {s}", .{title}, 0));
            _ = gtk.Popover.signals.closed.connect(menu, *Dock, menuClosed, self, .{});
            const items = gtk.Box.new(.vertical, 4);
            const scroller = gtk.ScrolledWindow.new();
            scroller.setPolicy(.never, .automatic);
            scroller.setPropagateNaturalHeight(1);
            scroller.setMaxContentHeight(@max(100, self.bounds.height - 100));
            scroller.setMaxContentWidth(@min(360, self.bounds.width - 32));
            scroller.setPropagateNaturalWidth(1);
            scroller.setChild(items.as(gtk.Widget));
            menu.setChild(scroller.as(gtk.Widget));
            try self.menus.append(a, menu);
            menu.as(gtk.Widget).setParent(primary.as(gtk.Widget));
            menu.setPosition(switch (self.config.edge) {
                .top => .bottom,
                .bottom => .top,
                .left => .right,
                .right => .left,
            });
            const context_click = gtk.GestureClick.new();
            context_click.as(gtk.GestureSingle).setButton(3);
            _ = gtk.GestureClick.signals.pressed.connect(context_click, *gtk.Popover, contextMenu, menu, .{});
            primary.as(gtk.Widget).addController(context_click.as(gtk.EventController));
            const context_keys = gtk.EventControllerKey.new();
            context_keys.as(gtk.EventController).setPropagationPhase(.capture);
            _ = gtk.EventControllerKey.signals.key_pressed.connect(context_keys, *gtk.Popover, contextKey, menu, .{});
            primary.as(gtk.Widget).addController(context_keys.as(gtk.EventController));
            const resolution_window = if (group.windows.items.len > 0) group.windows.items[0].id else null;
            if (group.desktop) |id| {
                if (entry != null) items.append((try self.button("Open new window", .launch, id, false, null, resolution_window, null)).as(gtk.Widget));
                if (p.desktopId(id)) items.append((try self.button(if (group.pinned) "Unpin from dock" else "Pin to dock", if (group.pinned) .unpin else .pin, id, false, null, resolution_window, null)).as(gtk.Widget));
                var actions: usize = 0;
                if (self.index.catalog) |catalog| for (catalog.entries.items) |item| {
                    if (item.action != null and std.mem.eql(u8, item.id, id) and actions < 8) {
                        items.append((try self.button(item.name, .launch, id, false, item.action, resolution_window, null)).as(gtk.Widget));
                        actions += 1;
                    }
                };
            }
            var request: ?Picker.Request = null;
            if (group.windows.items.len > 0) {
                const win = group.windows.items[0];
                if (identity.key(win.*)) |key_| request = .{ .key = key_, .window_id = win.id, .current_desktop = group.desktop, .source_pin = if (group.pinned) group.desktop else null };
            } else if (group.desktop) |id| {
                for (self.preferences.prefs().application_launchers) |choice| if (std.mem.eql(u8, choice.desktop_id, id)) {
                    if (request != null) {
                        request = null;
                        break;
                    }
                    request = .{ .key = choice.key(), .current_desktop = id, .source_pin = if (group.pinned) id else null };
                };
            }
            const choose = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "Use launcher…"));
            w.name(choose.as(gtk.Widget), @import("i18n").dtr("pearl", "Use launcher…"));
            items.append(choose.as(gtk.Widget));
            if (request) |r| {
                const cb = try alloc.create(Callback);
                cb.* = .{ .dock = self, .action = .choose_launcher, .id = "", .resolution_hash = self.resolutionHash(), .window_id = if (r.window_id) |v| try alloc.dupeSentinel(u8, v, 0) else null, .picker = .{
                    .key = .{ .backend = r.key.backend, .identity = try alloc.dupe(u8, r.key.identity) },
                    .window_id = if (r.window_id) |id| try alloc.dupe(u8, id) else null,
                    .source_pin = if (r.source_pin) |id| try alloc.dupe(u8, id) else null,
                    .current_desktop = if (r.current_desktop) |id| try alloc.dupe(u8, id) else null,
                } };
                _ = gtk.Button.signals.clicked.connect(choose, *Callback, clicked, cb, .{});
            } else {
                choose.as(gtk.Widget).setSensitive(0);
                choose.as(gtk.Widget).setTooltipText(@import("i18n").dtr("pearl", "A unique application identity is needed. Existing choices can be removed in Settings."));
            }
            // Split the persistent application actions from the per-window controls.
            if (group.windows.items.len > 0) items.append(gtk.Separator.new(.horizontal).as(gtk.Widget));
            for (group.windows.items) |win| {
                const title_text = win.title orelse "Untitled window";
                const label = try alloc.dupeSentinel(u8, title_text, 0);
                const activate = try self.button(label, .activate, win.id, false, null, null, null);
                activate.as(gtk.Widget).setSensitive(@intFromBool(win.can_activate));
                items.append(activate.as(gtk.Widget));
                if (win.can_minimize) items.append((try self.button(if (win.minimized) "Restore minimized window" else "Minimize", .minimize, win.id, !win.minimized, null, null, null)).as(gtk.Widget));
                if (win.can_maximize) items.append((try self.button(if (win.maximized) "Unmaximize" else "Maximize", .maximize, win.id, !win.maximized, null, null, null)).as(gtk.Widget));
                items.append((try self.button("Close window", .close, win.id, false, null, null, null)).as(gtk.Widget));
            }
            self.panel.append(box.as(gtk.Widget));
        }
        // No slot matched (e.g. the pin vanished mid-drag); drop the stale id.
        if (self.landed) |id| {
            a.free(id);
            self.landed = null;
        }
    }
    /// Regenerates the drag slide rules: the grabbed slot translates to the
    /// hovered position while the slots in between shift one step aside.
    fn loadDragCss(self: *Dock, vertical: bool, src_delta: f64, shift: f64) void {
        const provider = self.drag_css orelse return;
        const sx: f64 = if (vertical) 0 else src_delta;
        const sy: f64 = if (vertical) src_delta else 0;
        const fx: f64 = if (vertical) 0 else shift;
        const fy: f64 = if (vertical) shift else 0;
        const css = std.fmt.allocPrintSentinel(a, ".pearl-dock > box {{ transition: transform 160ms ease; }} .pearl-dock > box.pearl-drag-src {{ transform: translate({d:.1}px, {d:.1}px); }} .pearl-dock > box.pearl-drag-fwd {{ transform: translate({d:.1}px, {d:.1}px); }} .pearl-dock > box.pearl-drag-back {{ transform: translate({d:.1}px, {d:.1}px); }}", .{ sx, sy, fx, fy, -fx, -fy }, 0) catch return;
        defer a.free(css);
        provider.loadFromString(css);
    }
    /// Per-slot advance measured from live allocations; falls back to icon + spacing.
    fn slotStep(self: *Dock, vertical: bool) f64 {
        var prev: f64 = 0;
        var have_prev = false;
        var child = self.panel.as(gtk.Widget).getFirstChild();
        while (child) |slot| : (child = slot.getNextSibling()) {
            var rect: gtk.Allocation = undefined;
            slot.getAllocation(&rect);
            const at: f64 = @floatFromInt(if (vertical) rect.f_y else rect.f_x);
            if (have_prev and at != prev) return @abs(at - prev);
            prev = at;
            have_prev = true;
        }
        return @floatFromInt(self.config.icon_size + 10);
    }
    fn clearShiftClasses(widget: *gtk.Widget) void {
        widget.removeCssClass("pearl-drag-fwd");
        widget.removeCssClass("pearl-drag-back");
    }
    fn clearDragClasses(self: *Dock) void {
        var child = self.panel.as(gtk.Widget).getFirstChild();
        while (child) |slot| : (child = slot.getNextSibling()) {
            clearShiftClasses(slot);
            slot.removeCssClass("pearl-drag-src");
        }
    }
    /// Keeps autohide/intelligent docks revealed while an icon is being moved;
    /// the pointer leaves the surface during the drag and would hide it.
    fn dragBegan(_: *gtk.GestureDrag, x: f64, y: f64, binding: *DragBinding) callconv(.c) void {
        const self = binding.dock;
        if (self.locked or self.destroying or self.dragging) return;
        var box_rect: gtk.Allocation = undefined;
        var button_rect: gtk.Allocation = undefined;
        binding.box.getAllocation(&box_rect);
        binding.widget.getAllocation(&button_rect);
        binding.origin_x = @floatFromInt(box_rect.f_x + button_rect.f_x);
        binding.origin_y = @floatFromInt(box_rect.f_y + button_rect.f_y);
        binding.start_x = x;
        binding.start_y = y;
        binding.hover_after = false;
        binding.dragged = false;
        const vertical = self.config.edge == .left or self.config.edge == .right;
        binding.step = self.slotStep(vertical);
        binding.src_index = 0;
        var index: usize = 0;
        var child = self.panel.as(gtk.Widget).getFirstChild();
        while (child) |slot| : (child = slot.getNextSibling()) {
            if (slot == binding.box) {
                binding.src_index = index;
                break;
            }
            index += 1;
        }
        binding.target = binding.src_index;
        // The ghost layer lives in window coordinates: sum panel offsets up
        // to the window (allocations already reflect any scroll).
        binding.win_x = 0;
        binding.win_y = 0;
        {
            var node: ?*gtk.Widget = self.panel.as(gtk.Widget);
            while (node) |n| {
                if (n == self.window.as(gtk.Widget)) break;
                var r: gtk.Allocation = undefined;
                n.getAllocation(&r);
                binding.win_x += @floatFromInt(r.f_x);
                binding.win_y += @floatFromInt(r.f_y);
                node = n.getParent();
            }
        }
        // The ghost mirrors the grabbed icon and follows the pointer while the
        // source slot hides, leaving the landing gap empty.
        if (binding.icon.getGicon()) |gicon| self.ghost.setFromGicon(gicon) else self.ghost.setFromIconName("pearl-application-x-executable-symbolic");
        self.ghost.setPixelSize(self.config.icon_size);
        const half = @as(f64, @floatFromInt(self.config.icon_size)) / 2;
        self.fixed.move(self.ghost.as(gtk.Widget), binding.win_x + binding.origin_x + x - half, binding.win_y + binding.origin_y + y - half);
        self.ghost.as(gtk.Widget).setVisible(1);
        binding.widget.addCssClass("pearl-dragging");
        binding.box.addCssClass("pearl-drag-src");
        self.loadDragCss(vertical, 0, 0);
        self.dragging = true;
        if (self.timer != 0) {
            _ = glib.Source.remove(self.timer);
            self.timer = 0;
        }
        self.showState();
    }
    /// Translates the gesture offset into panel coordinates, finds the hovered
    /// slot and slides the row live so the gap travels with the pointer.
    fn dragMoved(_: *gtk.GestureDrag, off_x: f64, off_y: f64, binding: *DragBinding) callconv(.c) void {
        const self = binding.dock;
        if (!self.dragging or self.destroying) return;
        const px = binding.origin_x + binding.start_x + off_x;
        const py = binding.origin_y + binding.start_y + off_y;
        const half = @as(f64, @floatFromInt(self.config.icon_size)) / 2;
        self.fixed.move(self.ghost.as(gtk.Widget), binding.win_x + px - half, binding.win_y + py - half);
        const vertical = self.config.edge == .left or self.config.edge == .right;
        // Hit-test in visual space: slots displaced by the live slide keep
        // their allocations, and testing those made the target overshoot and
        // the indicator jump. The dragged slot itself covers the gap; landing
        // there means "hold position", which keeps the sweep stable.
        var found: ?*gtk.Widget = null;
        var found_index: usize = 0;
        var after = false;
        var slots: usize = 0;
        var over_panel = false;
        {
            var panel_rect: gtk.Allocation = undefined;
            self.panel.as(gtk.Widget).getAllocation(&panel_rect);
            const x0: f64 = @floatFromInt(panel_rect.f_x);
            const y0: f64 = @floatFromInt(panel_rect.f_y);
            over_panel = px >= x0 and px < x0 + @as(f64, @floatFromInt(panel_rect.f_width)) and py >= y0 and py < y0 + @as(f64, @floatFromInt(panel_rect.f_height));
        }
        // Visual gap position of the current state: when moving right the
        // reorder index counts the dragged slot itself, so the gap sits one
        // position left of it.
        const cur_gap = if (binding.target > binding.src_index) binding.target - 1 else binding.target;
        const src_delta: f64 = @as(f64, @floatFromInt(cur_gap)) - @as(f64, @floatFromInt(binding.src_index));
        var index: usize = 0;
        var child = self.panel.as(gtk.Widget).getFirstChild();
        while (child) |slot| : (child = slot.getNextSibling()) {
            slots += 1;
            var rect: gtk.Allocation = undefined;
            slot.getAllocation(&rect);
            var shift: f64 = 0;
            if (index == binding.src_index) shift = src_delta * binding.step;
            if (cur_gap > binding.src_index and index > binding.src_index and index <= cur_gap) shift = -binding.step;
            if (cur_gap < binding.src_index and index >= cur_gap and index < binding.src_index) shift = binding.step;
            const x0: f64 = @as(f64, @floatFromInt(rect.f_x)) + (if (vertical) @as(f64, 0) else shift);
            const y0: f64 = @as(f64, @floatFromInt(rect.f_y)) + (if (vertical) shift else @as(f64, 0));
            const x1 = x0 + @as(f64, @floatFromInt(rect.f_width));
            const y1 = y0 + @as(f64, @floatFromInt(rect.f_height));
            if (found == null and px >= x0 and px < x1 and py >= y0 and py < y1) {
                found = slot;
                found_index = index;
                after = if (vertical) py >= y0 + (y1 - y0) / 2 else px >= x0 + (x1 - x0) / 2;
            }
            index += 1;
        }
        const over_src = found != null and found_index == binding.src_index;
        // Gap-space target: the pointer half picks which side of the hovered
        // slot the gap snaps to. Slots right of home read one lower because
        // the dragged slot no longer occupies visual space. Resting the row
        // over the gap itself would oscillate, so the gap holds position.
        const gap: usize = if (over_src or (over_panel and found == null)) cur_gap else if (!over_panel or slots == 0) binding.src_index else if (found_index > binding.src_index) found_index - 1 + @intFromBool(after) else found_index + @intFromBool(after);
        const target = @min(gap + @intFromBool(gap >= binding.src_index), slots - 1);
        // Remember the pointer side so a release over the gap keeps its intent.
        binding.hover_after = after;
        if (found != null and !over_src) binding.dragged = true;
        if (target == binding.target) return;
        binding.target = target;
        var i: usize = 0;
        child = self.panel.as(gtk.Widget).getFirstChild();
        while (child) |slot| : (child = slot.getNextSibling()) {
            clearShiftClasses(slot);
            if (target > binding.src_index) {
                if (i > binding.src_index and i < target) slot.addCssClass("pearl-drag-back");
            } else if (target < binding.src_index) {
                if (i >= target and i < binding.src_index) slot.addCssClass("pearl-drag-fwd");
            }
            i += 1;
        }
        const new_gap = if (target > binding.src_index) target - 1 else target;
        const delta = @as(f64, @floatFromInt(new_gap)) - @as(f64, @floatFromInt(binding.src_index));
        self.loadDragCss(vertical, delta * binding.step, binding.step);
    }
    fn dragDone(_: *gtk.GestureDrag, _: f64, _: f64, binding: *DragBinding) callconv(.c) void {
        const self = binding.dock;
        if (!self.dragging) return;
        self.dragging = false;
        binding.widget.removeCssClass("pearl-dragging");
        self.ghost.as(gtk.Widget).setVisible(0);
        self.clearDragClasses();
        self.loadDragCss(false, 0, 0);
        const target = binding.target;
        const after = binding.hover_after;
        const dragged = binding.dragged;
        binding.dragged = false;
        if (self.destroying) return;
        self.showState();
        // The visual target is the landing row position; a release over the
        // gap keeps the pointer side, and drops past the pinned run append.
        if (dragged) {
            const pos = if (target < binding.pins) target + @intFromBool(target == binding.src_index and after) else binding.pins;
            if (self.reorder(std.mem.span(binding.key), pos)) |moved| {
                if (moved) {
                    if (self.landed) |old| a.free(old);
                    self.landed = a.dupeSentinel(u8, std.mem.span(binding.key), 0) catch null;
                }
            } else |err| {
                log.err("event=dock-reorder error={s}", .{@errorName(err)});
                self.window.as(gtk.Widget).setTooltipText(@import("i18n").dtr("pearl", "Action unavailable; the application or window may have changed."));
            }
        }
        // Rebuilds are deferred while dragging; reconcile any model change now.
        self.changed(self.context);
    }
    fn contextMenu(gesture: *gtk.GestureClick, _: c_int, _: f64, _: f64, menu: *gtk.Popover) callconv(.c) void {
        _ = gesture.as(gtk.Gesture).setState(.claimed);
        menu.popup();
    }
    fn contextKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, modifiers: gdk.ModifierType, menu: *gtk.Popover) callconv(.c) c_int {
        if (keyval == 0xff67 or (keyval == 0xffc7 and modifiers.shift_mask)) { // Menu or Shift+F10
            menu.popup();
            return 1;
        }
        return 0;
    }
    fn clicked(_: *gtk.Button, cb: *Callback) callconv(.c) void {
        const self = cb.dock;
        self.act(cb.*) catch |err| {
            log.err("event=dock-action error={s}", .{@errorName(err)});
            self.window.as(gtk.Widget).setTooltipText(@import("i18n").dtr("pearl", "Action unavailable; the application or window may have changed."));
        };
        self.reveal(false);
    }
    fn act(self: *Dock, cb: Callback) !void {
        if (self.locked or self.client.availability != .ready or self.client.model.get(.session, "session").?.locked) return error.Locked;
        if (cb.action == .choose_launcher or ((cb.action == .launch or cb.action == .pin) and cb.window_id != null)) {
            if (cb.resolution_hash != self.resolutionHash()) return error.StaleApplication;
            if (cb.window_id) |id| {
                const win = self.client.model.get(.window, id) orelse return error.StaleWindow;
                if (!p.eligible(win.*, self.output)) return error.StaleWindow;
                const current = self.match(win);
                const expected = if (cb.action == .choose_launcher) cb.picker.?.current_desktop else cb.id;
                if ((current == null) != (expected == null)) return error.StaleApplication;
                if (current) |desktop| if (!std.mem.eql(u8, desktop, expected.?)) return error.StaleApplication;
            }
        }
        switch (cb.action) {
            .choose_launcher => try (self.choose_launcher orelse return error.Unavailable)(self.context, self.output, cb.picker.?),
            .pin, .unpin => try self.pin(cb.id, cb.action == .pin),
            .launch => try self.launchDesktop(cb.id, cb.desktop_action),
            .activate => {
                const win = if (self.client.model.get(.window, cb.id)) |found| (if (p.eligible(found.*, self.output)) found else null) else null;
                if (win == null) {
                    // The icon can outlive the window it was built for; launch instead of swallowing the click.
                    const desktop = cb.desktop_id orelse return error.StaleWindow;
                    log.info("event=dock-activate-fallback reason=stale-window id={s} desktop={s}", .{ cb.id, desktop });
                    try self.launchDesktop(desktop, null);
                    return;
                }
                _ = self.client.enqueue(.{ .window_activate = .{ .id = cb.id } }) catch |err| {
                    const desktop = cb.desktop_id orelse return err;
                    log.info("event=dock-activate-fallback reason={s} id={s} desktop={s}", .{ @errorName(err), cb.id, desktop });
                    try self.launchDesktop(desktop, null);
                };
            },
            else => {
                const win = self.client.model.get(.window, cb.id) orelse return error.StaleWindow;
                if (!p.eligible(win.*, self.output)) return error.StaleWindow;
                _ = try self.client.enqueue(switch (cb.action) {
                    .minimize => .{ .window_minimized = .{ .id = cb.id, .value = cb.value } },
                    .maximize => .{ .window_maximized = .{ .id = cb.id, .value = cb.value } },
                    .close => .{ .window_close = .{ .id = cb.id } },
                    else => unreachable,
                });
            },
        }
    }
    fn launchDesktop(self: *Dock, id: [:0]const u8, action: ?[:0]const u8) !void {
        _ = self.installed(id) orelse return error.StaleApplication;
        const desktop = unix.DesktopAppInfo.new(id) orelse return error.StaleApplication;
        defer desktop.unref();
        if (desktop.as(gio.AppInfo).shouldShow() == 0) return error.StaleApplication;
        const context = self.window.as(gtk.Widget).getDisplay().getAppLaunchContext();
        defer context.unref();
        context.setTimestamp(0);
        if (action) |name| {
            var found = false;
            const actions: [*:null]const ?[*:0]const u8 = @ptrCast(desktop.listActions());
            var i: usize = 0;
            while (actions[i]) |v| : (i += 1) {
                if (std.mem.eql(u8, name, std.mem.span(v))) found = true;
            }
            if (!found) return error.StaleAction;
            desktop.launchAction(name, context.as(gio.AppLaunchContext));
        } else {
            var err: ?*glib.Error = null;
            defer if (err) |v| v.free();
            if (desktop.as(gio.AppInfo).launch(null, context.as(gio.AppLaunchContext), &err) == 0) return error.LaunchFailed;
        }
        self.index.remember(id);
    }
    pub fn pin(self: *Dock, id: []const u8, value: bool) !void {
        if (!p.desktopId(id)) return error.InvalidDesktopId;
        if (value and self.installed(id) == null) return error.StaleApplication;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var prefs = self.preferences.prefs();
        var pins: std.ArrayList([]const u8) = .empty;
        for (prefs.pinned_apps) |existing| if (!std.mem.eql(u8, id, existing)) {
            try pins.append(alloc, existing);
        };
        if (value) try pins.append(alloc, id);
        prefs.pinned_apps = pins.items;
        try prefs.validate();
        const json = try std.json.Stringify.valueAlloc(alloc, prefs, .{});
        try self.preferences.apply(json, self.preferences.revision);
    }
    /// Moves `id` to position `pos` in the pinned list; dragging an unpinned
    /// desktop item pins it at that spot. `pos` counts the pre-removal list.
    /// Returns false when the order is unchanged (no write, no animation).
    pub fn reorder(self: *Dock, id: []const u8, pos: usize) !bool {
        if (!p.desktopId(id)) return error.InvalidDesktopId;
        if (self.locked or self.client.availability != .ready or self.client.model.get(.session, "session").?.locked) return error.Locked;
        if (self.installed(id) == null) return error.StaleApplication;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var prefs = self.preferences.prefs();
        var pins: std.ArrayList([]const u8) = .empty;
        var insertion = pos;
        for (prefs.pinned_apps, 0..) |existing, i| {
            if (std.mem.eql(u8, id, existing)) {
                if (i < insertion) insertion -= 1;
                continue;
            }
            try pins.append(alloc, existing);
        }
        try pins.insert(alloc, @min(insertion, pins.items.len), id);
        if (pins.items.len == prefs.pinned_apps.len) {
            var same = true;
            for (pins.items, prefs.pinned_apps) |x, y| if (!std.mem.eql(u8, x, y)) {
                same = false;
                break;
            };
            if (same) return false;
        }
        prefs.pinned_apps = pins.items;
        try prefs.validate();
        const json = try std.json.Stringify.valueAlloc(alloc, prefs, .{});
        try self.preferences.apply(json, self.preferences.revision);
        return true;
    }
};
