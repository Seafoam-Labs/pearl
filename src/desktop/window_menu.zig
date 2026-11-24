//! Right-click window menu for shell-drawn decorations. A small layer-shell
//! overlay positioned at the pointer; actions route through the validated
//! IPC command queue. The pure toggle policy is unit-testable.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const object = @import("gobject2");
const layer = @import("gtk4layershell1");
const adapter = @import("../aqueous/client.zig");
const commands = @import("../aqueous/commands.zig");
const entities = @import("../aqueous/entities.zig");
const Model = @import("../aqueous/reducer.zig").Model;
const tr = @import("text.zig").tr;
const log = std.log.scoped(.desktop);
const a = std.heap.c_allocator;

pub const Toggles = struct {
    minimize: bool,
    maximize: bool,
    fullscreen: bool,
    can_minimize: bool,
    can_maximize: bool,
};

/// Target values for the stateful menu items, derived from committed state.
pub fn toggles(window: entities.Window) Toggles {
    return .{
        .minimize = !window.minimized,
        .maximize = !window.maximized,
        .fullscreen = !window.fullscreen,
        .can_minimize = window.can_minimize,
        .can_maximize = window.can_maximize,
    };
}

pub const Options = struct {
    app: *gtk.Application,
    client: *adapter.Client,
    monitor: *gdk.Monitor,
    /// Global logical pointer position.
    x: i32,
    y: i32,
    /// Output origin to convert global coordinates into layer-shell margins.
    origin_x: i32,
    origin_y: i32,
    window_id: []const u8,
    dark: bool,
};

pub const Menu = struct {
    window: *gtk.Window,
    client: *adapter.Client,
    window_id: []u8,
    items: std.ArrayList(*Item) = .empty,
    notify_signal: c_ulong = 0,
    was_active: bool = false,
    closed: bool = false,

    pub fn open(opts: Options) !*Menu {
        const model = &opts.client.model;
        const window = (model.get(.window, opts.window_id) orelse return error.NotFound).*;
        const self = try a.create(Menu);
        errdefer a.destroy(self);
        self.* = .{
            .window = undefined,
            .client = opts.client,
            .window_id = try a.dupe(u8, opts.window_id),
        };
        errdefer a.free(self.window_id);
        errdefer {
            for (self.items.items) |item| {
                item.owned.deinit();
                a.destroy(item);
            }
            self.items.deinit(a);
        }
        const win = gtk.ApplicationWindow.new(opts.app).as(gtk.Window);
        _ = win.ref();
        errdefer {
            win.destroy();
            win.unref();
        }
        self.window = win;
        win.setTitle(tr("Window menu"));
        win.as(gtk.Widget).addCssClass("pearl-root");
        win.as(gtk.Widget).addCssClass(if (opts.dark) "pearl-dark" else "pearl-light");
        win.as(gtk.Widget).addCssClass("pearl-shell");
        layer.initForWindow(win);
        layer.setMonitor(win, opts.monitor);
        layer.setNamespace(win, "pearl:window-menu");
        layer.setLayer(win, .overlay);
        layer.setExclusiveZone(win, 0);
        layer.setKeyboardMode(win, .on_demand);
        layer.setAnchor(win, .top, 1);
        layer.setAnchor(win, .left, 1);
        layer.setMargin(win, .left, @max(0, opts.x - opts.origin_x));
        layer.setMargin(win, .top, @max(0, opts.y - opts.origin_y));

        const panel = gtk.Box.new(.vertical, 2);
        panel.as(gtk.Widget).addCssClass("pearl-surface-panel");
        panel.as(gtk.Widget).addCssClass("pearl-menu-panel");
        const t = toggles(window);
        if (t.can_minimize) try self.addItem(panel, if (window.minimized) tr("Restore") else tr("Minimize"), .{ .window_minimized = .{ .id = self.window_id, .value = t.minimize } });
        if (t.can_maximize) try self.addItem(panel, if (window.maximized) tr("Restore") else tr("Maximize"), .{ .window_maximized = .{ .id = self.window_id, .value = t.maximize } });
        try self.addItem(panel, if (window.fullscreen) tr("Exit fullscreen") else tr("Fullscreen"), .{ .window_fullscreen = .{ .id = self.window_id, .value = t.fullscreen } });
        // Flat workspace list for the window's output.
        if (window.output) |output_id| {
            const Ws = struct { number: u32, id: []const u8 };
            var workspaces: std.ArrayList(Ws) = .empty;
            defer workspaces.deinit(a);
            var it = model.entities.valueIterator();
            while (it.next()) |entity| {
                if (entity.* != .workspace) continue;
                const ws = entity.workspace;
                if (!std.mem.eql(u8, ws.output, output_id)) continue;
                if (window.workspace) |current| if (std.mem.eql(u8, current, ws.id)) continue;
                try workspaces.append(a, .{ .number = ws.number, .id = ws.id });
            }
            std.mem.sort(Ws, workspaces.items, {}, struct {
                fn less(_: void, lhs: Ws, rhs: Ws) bool {
                    return lhs.number < rhs.number;
                }
            }.less);
            if (workspaces.items.len > 0) {
                panel.append(gtk.Separator.new(.horizontal).as(gtk.Widget));
                for (workspaces.items) |ws| {
                    var buf: [64]u8 = undefined;
                    const label = std.fmt.bufPrint(&buf, "{s} {d}", .{ tr("Move to workspace"), ws.number }) catch continue;
                    try self.addItem(panel, label, .{ .window_move_workspace = .{ .id = self.window_id, .workspace = ws.id } });
                }
            }
        }
        panel.append(gtk.Separator.new(.horizontal).as(gtk.Widget));
        try self.addItem(panel, tr("Close"), .{ .window_close = .{ .id = self.window_id } });
        win.setChild(panel.as(gtk.Widget));

        const keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Menu, keyPressed, self, .{});
        win.as(gtk.Widget).addController(keys.as(gtk.EventController));
        self.notify_signal = object.Object.signals.notify.connect(win.as(object.Object), *Menu, activeChanged, self, .{ .detail = "is-active" });
        win.present();
        log.info("event=decoration-menu-opened window={s}", .{self.window_id});
        return self;
    }

    fn addItem(self: *Menu, panel: *gtk.Box, label: []const u8, action: commands.Action) !void {
        const label_z = try a.dupeSentinel(u8, label, 0);
        defer a.free(label_z);
        const button = gtk.Button.newWithLabel(label_z);
        button.as(gtk.Widget).addCssClass("pearl-menu-item");
        button.as(gtk.Widget).setHalign(.fill);
        const owned = try a.create(Item);
        errdefer a.destroy(owned);
        // Clone action strings: model-owned IDs may be freed by the next batch.
        owned.* = .{ .menu = self, .owned = try commands.Owned.init(a, action, 0) };
        errdefer owned.owned.deinit();
        try self.items.append(a, owned);
        _ = gtk.Button.signals.clicked.connect(button, *Item, Item.clicked, owned, .{});
        panel.append(button.as(gtk.Widget));
    }

    const Item = struct {
        menu: *Menu,
        owned: commands.Owned,
        fn clicked(_: *gtk.Button, self: *Item) callconv(.c) void {
            const menu = self.menu;
            for (menu.items.items, 0..) |item, i| {
                if (item == self) {
                    _ = menu.items.orderedRemove(i);
                    break;
                }
            }
            const action = self.owned.action;
            self.owned.deinit();
            a.destroy(self);
            if (menu.closed) return;
            _ = menu.client.enqueue(action) catch |err| {
                log.debug("event=decoration-menu-action-failed error={s}", .{@errorName(err)});
            };
            log.info("event=decoration-menu-action window={s}", .{menu.window_id});
            menu.close();
        }
    };

    fn keyPressed(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, _: gdk.ModifierType, self: *Menu) callconv(.c) c_int {
        if (key == 0xff1b) {
            self.close();
            return 1;
        }
        return 0;
    }

    fn activeChanged(_: *object.Object, _: *object.ParamSpec, self: *Menu) callconv(.c) void {
        if (self.closed) return;
        const active = self.window.isActive() != 0;
        if (active) {
            self.was_active = true;
        } else if (self.was_active) {
            self.close();
        }
    }

    pub fn close(self: *Menu) void {
        if (self.closed) return;
        self.closed = true;
        for (self.items.items) |item| {
            item.owned.deinit();
            a.destroy(item);
        }
        self.items.deinit(a);
        if (self.notify_signal != 0 and object.signalHandlerIsConnected(self.window.as(object.Object), self.notify_signal) != 0) {
            object.signalHandlerDisconnect(self.window.as(object.Object), self.notify_signal);
        }
        self.window.destroy();
        self.window.unref();
        a.free(self.window_id);
        a.destroy(self);
    }
};

test "menu toggles invert committed state and respect capabilities" {
    var window: entities.Window = .{
        .id = "1",
        .backend = .xdg,
        .app_id = null,
        .class = null,
        .title = null,
        .workspace = null,
        .output = null,
        .geometry = .{ .x = 0, .y = 0, .width = 100, .height = 100 },
        .outer_geometry = .{ .x = 0, .y = 0, .width = 100, .height = 100 },
        .layout = "tile",
        .focused = true,
        .visible = true,
        .floating = false,
        .minimized = false,
        .maximized = true,
        .fullscreen = false,
        .skip_taskbar = false,
        .skip_switcher = false,
        .always_above = false,
        .always_below = false,
        .snapped = false,
        .fixed_position = false,
        .can_minimize = true,
        .can_maximize = false,
        .can_activate = true,
    };
    const t = toggles(window);
    try std.testing.expect(t.minimize and !t.maximize and t.fullscreen);
    try std.testing.expect(t.can_minimize and !t.can_maximize);
    window.minimized = true;
    window.fullscreen = true;
    const u = toggles(window);
    try std.testing.expect(!u.minimize and !u.fullscreen);
}