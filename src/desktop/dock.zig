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
const a = std.heap.c_allocator;
const Action = enum { activate, launch, pin, unpin, minimize, maximize, close };
const Callback = struct { dock: *Dock, action: Action, id: [:0]const u8, value: bool = false, desktop_action: ?[:0]const u8 = null };
const Group = struct { key: []const u8, desktop: ?[]const u8, pinned: bool, windows: std.ArrayList(*const e.Window) = .empty };
pub const Dock = struct {
    client: *Client,
    index: *Apps.Index,
    preferences: *Preferences,
    output: []const u8,
    window: *gtk.Window,
    sensor: *gtk.Window,
    panel: *gtk.Box,
    scroll: *gtk.ScrolledWindow,
    effects: native.Surface = undefined,
    arena: std.heap.ArenaAllocator,
    menus: std.ArrayList(*gtk.Popover) = .empty,
    hash: ?u64 = null,
    config: p.Config = .{},
    bounds: placement.Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    rect: placement.Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    reason: p.Reason = .empty,
    count: usize = 0,
    truncated: bool = false,
    hover: bool = false,
    keyboard: bool = false,
    locked: bool = true,
    fullscreen: bool = false,
    obstructed: bool = false,
    timer: c_uint = 0,
    destroying: bool = false,
    appearance: u64 = std.math.maxInt(u64),
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    pub fn create(app: *gtk.Application, monitor: *gdk.Monitor, effects: *native.Effects, client: *Client, index: *Apps.Index, preferences: *Preferences, output: []const u8, context: *anyopaque, changed: *const fn (*anyopaque) void) !*Dock {
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
        window.setChild(scroll.as(gtk.Widget));
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
            win.setTitle(if (i == 0) "Pearl dock" else "Pearl dock reveal");
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
        w.name(panel.as(gtk.Widget), "Applications dock");
        self.* = .{ .client = client, .index = index, .preferences = preferences, .output = output, .window = window, .sensor = sensor, .panel = panel, .scroll = scroll, .arena = .init(a), .context = context, .changed = changed };
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
        self.effects.deinit();
        self.clear();
        self.window.destroy();
        self.window.unref();
        self.sensor.destroy();
        self.sensor.unref();
        self.arena.deinit();
        self.menus.deinit(a);
        a.destroy(self);
    }
    fn clear(self: *Dock) void {
        for (self.menus.items) |menu| menu.popdown();
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
        var result: ?[]const u8 = null;
        if (self.index.catalog) |catalog| for (catalog.entries.items) |entry| {
            if (entry.action != null) continue;
            const desktop = object.ext.cast(unix.DesktopAppInfo, entry.info) orelse continue;
            const wmclass = desktop.getStartupWmClass();
            var matches = false;
            for ([_]?[]const u8{ win.app_id, win.class }) |maybe| if (maybe) |id| {
                if (std.mem.eql(u8, p.stem(entry.id), p.stem(id)) or (wmclass != null and std.mem.eql(u8, id, std.mem.span(wmclass.?)))) matches = true;
            };
            if (matches) {
                if (result != null) return null;
                result = entry.id;
            }
        };
        return result;
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
        digest.update(try std.json.Stringify.valueAlloc(alloc, .{ self.index.generation, next, self.preferences.appearance }, .{}));
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
            if (!menu_open) {
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
        const length = @max(1, (if (vertical) self.bounds.height else self.bounds.width) - 64);
        self.scroll.setPolicy(if (vertical) .never else .automatic, if (vertical) .automatic else .never);
        self.scroll.setMaxContentWidth(if (vertical) -1 else length);
        self.scroll.setMaxContentHeight(if (vertical) length else -1);
        const estimate: i32 = @intCast(@max(1, self.count) * (@as(usize, self.config.icon_size) + 36) + 12);
        const width = if (vertical) @as(i32, self.config.icon_size) + 40 else @min(length, estimate);
        const height = if (vertical) @min(length, estimate) else @as(i32, self.config.icon_size) + 40;
        self.window.setDefaultSize(if (vertical) width else -1, if (vertical) -1 else height);
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
        self.sensor.setDefaultSize(if (vertical) 2 else actual_width, if (vertical) actual_height else 2);
        self.rect = .{ .x = self.bounds.x + @divTrunc(self.bounds.width - actual_width, 2), .y = self.bounds.y + @divTrunc(self.bounds.height - actual_height, 2), .width = actual_width, .height = actual_height };
        switch (self.config.edge) {
            .top => self.rect.y = self.bounds.y + self.config.margin,
            .bottom => self.rect.y = self.bounds.y + self.bounds.height - actual_height - self.config.margin,
            .left => self.rect.x = self.bounds.x + self.config.margin,
            .right => self.rect.x = self.bounds.x + self.bounds.width - actual_width - self.config.margin,
        }
    }
    fn showState(self: *Dock) void {
        var interaction = self.hover;
        for (self.menus.items) |menu| if (menu.as(gtk.Widget).getVisible() != 0) {
            interaction = true;
        };
        self.reason = p.visibility(self.config, self.locked, self.count == 0, interaction, self.keyboard, self.fullscreen, self.obstructed);
        const shown = p.shown(self.reason);
        layer.setLayer(self.window, if (shown and self.fullscreen) .overlay else .top);
        layer.setKeyboardMode(self.window, if (shown and self.keyboard) .exclusive else .none);
        self.window.as(gtk.Widget).setVisible(@intFromBool(shown));
        self.sensor.as(gtk.Widget).setVisible(@intFromBool(self.config.enabled and !self.locked and self.count != 0));
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
        if (!self.destroying and self.timer == 0) self.timer = glib.timeoutAdd(450, hideLater, self);
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
    fn button(self: *Dock, text: [:0]const u8, action: Action, id: []const u8, value: bool, desktop_action: ?[]const u8) !*gtk.Button {
        const alloc = self.arena.allocator();
        const cb = try alloc.create(Callback);
        cb.* = .{ .dock = self, .action = action, .id = try alloc.dupeZ(u8, id), .value = value, .desktop_action = if (desktop_action) |v| try alloc.dupeZ(u8, v) else null };
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
        for (groups) |group| {
            const entry = if (group.desktop) |id| self.installed(id) else null;
            const title = if (entry) |v| v.name else if (group.windows.items.len > 0) group.windows.items[0].app_id orelse group.windows.items[0].class orelse "Application" else group.key;
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
            const primary = try self.button(description, if (target != null) .activate else .launch, if (target) |win| win.id else group.desktop.?, false, null);
            primary.as(gtk.Widget).setTooltipText(description);
            primary.as(gtk.Widget).setSensitive(@intFromBool(if (target) |win| win.can_activate else entry != null));
            if (focused) primary.as(gtk.Widget).addCssClass("focused");
            const content = gtk.Box.new(.vertical, 0);
            const icon = if (entry != null and entry.?.info.getIcon() != null and gtk.IconTheme.getForDisplay(self.window.as(gtk.Widget).getDisplay()).hasGicon(entry.?.info.getIcon().?) != 0) gtk.Image.newFromGicon(entry.?.info.getIcon().?) else gtk.Image.newFromIconName("pearl-application-x-executable-symbolic");
            icon.setPixelSize(self.config.icon_size);
            content.append(icon.as(gtk.Widget));
            const indicator = if (group.windows.items.len > 1) try std.fmt.allocPrintSentinel(alloc, "{s} {d}", .{ if (focused) "●" else "•", group.windows.items.len }, 0) else if (focused) "●" else if (minimized) "◦" else if (group.windows.items.len > 0) "•" else "";
            content.append(gtk.Label.new(indicator).as(gtk.Widget));
            primary.setChild(content.as(gtk.Widget));
            box.append(primary.as(gtk.Widget));
            const menu_button = gtk.MenuButton.new();
            menu_button.setIconName("pan-down-symbolic");
            w.name(menu_button.as(gtk.Widget), try std.fmt.allocPrintSentinel(alloc, "Actions for {s}", .{title}, 0));
            const menu = gtk.Popover.new();
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
            menu_button.setPopover(menu);
            try self.menus.append(a, menu);
            const context_click = gtk.GestureClick.new();
            context_click.as(gtk.GestureSingle).setButton(3);
            _ = gtk.GestureClick.signals.pressed.connect(context_click, *gtk.Popover, contextMenu, menu, .{});
            primary.as(gtk.Widget).addController(context_click.as(gtk.EventController));
            if (group.desktop) |id| {
                if (entry != null) items.append((try self.button("Open new window", .launch, id, false, null)).as(gtk.Widget));
                if (p.desktopId(id)) items.append((try self.button(if (group.pinned) "Unpin" else "Pin to dock", if (group.pinned) .unpin else .pin, id, false, null)).as(gtk.Widget));
                var actions: usize = 0;
                if (self.index.catalog) |catalog| for (catalog.entries.items) |item| {
                    if (item.action != null and std.mem.eql(u8, item.id, id) and actions < 8) {
                        items.append((try self.button(item.name, .launch, id, false, item.action)).as(gtk.Widget));
                        actions += 1;
                    }
                };
            }
            for (group.windows.items) |win| {
                const title_text = win.title orelse "Untitled window";
                const label = try alloc.dupeZ(u8, title_text);
                const activate = try self.button(label, .activate, win.id, false, null);
                activate.as(gtk.Widget).setSensitive(@intFromBool(win.can_activate));
                items.append(activate.as(gtk.Widget));
                if (win.can_minimize) items.append((try self.button(if (win.minimized) "Restore minimized window" else "Minimize", .minimize, win.id, !win.minimized, null)).as(gtk.Widget));
                if (win.can_maximize) items.append((try self.button(if (win.maximized) "Unmaximize" else "Maximize", .maximize, win.id, !win.maximized, null)).as(gtk.Widget));
                items.append((try self.button("Close window", .close, win.id, false, null)).as(gtk.Widget));
            }
            box.append(menu_button.as(gtk.Widget));
            self.panel.append(box.as(gtk.Widget));
        }
    }
    fn contextMenu(gesture: *gtk.GestureClick, _: c_int, _: f64, _: f64, menu: *gtk.Popover) callconv(.c) void {
        _ = gesture.as(gtk.Gesture).setState(.claimed);
        menu.popup();
    }
    fn clicked(_: *gtk.Button, cb: *Callback) callconv(.c) void {
        const self = cb.dock;
        self.act(cb.*) catch |err| {
            std.log.info("event=dock-action error={s}", .{@errorName(err)});
            self.window.as(gtk.Widget).setTooltipText("Action unavailable; the application or window may have changed.");
        };
        self.reveal(false);
    }
    fn act(self: *Dock, cb: Callback) !void {
        if (self.locked or self.client.availability != .ready or self.client.model.get(.session, "session").?.locked) return error.Locked;
        switch (cb.action) {
            .pin, .unpin => try self.pin(cb.id, cb.action == .pin),
            .launch => {
                _ = self.installed(cb.id) orelse return error.StaleApplication;
                const desktop = unix.DesktopAppInfo.new(cb.id) orelse return error.StaleApplication;
                defer desktop.unref();
                if (desktop.as(gio.AppInfo).shouldShow() == 0) return error.StaleApplication;
                const context = self.window.as(gtk.Widget).getDisplay().getAppLaunchContext();
                defer context.unref();
                context.setTimestamp(0);
                if (cb.desktop_action) |action| {
                    var found = false;
                    const actions: [*:null]const ?[*:0]const u8 = @ptrCast(desktop.listActions());
                    var i: usize = 0;
                    while (actions[i]) |v| : (i += 1) {
                        if (std.mem.eql(u8, action, std.mem.span(v))) found = true;
                    }
                    if (!found) return error.StaleAction;
                    desktop.launchAction(action, context.as(gio.AppLaunchContext));
                } else {
                    var err: ?*glib.Error = null;
                    defer if (err) |v| v.free();
                    if (desktop.as(gio.AppInfo).launch(null, context.as(gio.AppLaunchContext), &err) == 0) return error.LaunchFailed;
                }
                self.index.remember(cb.id);
            },
            else => {
                const win = self.client.model.get(.window, cb.id) orelse return error.StaleWindow;
                if (!p.eligible(win.*, self.output)) return error.StaleWindow;
                _ = try self.client.enqueue(switch (cb.action) {
                    .activate => .{ .window_activate = .{ .id = cb.id } },
                    .minimize => .{ .window_minimized = .{ .id = cb.id, .value = cb.value } },
                    .maximize => .{ .window_maximized = .{ .id = cb.id, .value = cb.value } },
                    .close => .{ .window_close = .{ .id = cb.id } },
                    else => unreachable,
                });
            },
        }
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
};
