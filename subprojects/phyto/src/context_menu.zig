//! Native, capability-driven context menus and explicit-target action dispatch.
const std = @import("std");
const u = @import("ui.zig");
const gtk = u.gtk;
const gio = u.gio;
const glib = u.glib;
const object = u.object;
const gdk = @import("gdk4");
const a = u.a;
const Window = @import("window.zig").Window;
const Tab = @import("tab.zig").Tab;
const Context = @import("context.zig").Context;
const rules = @import("core/context.zig");
const Command = @import("actions.zig").Command;
const apps = @import("platform/applications.zig");
const Extra = struct { kind: enum { app, copy, move, template, provider }, file: ?*gio.File = null, app: ?*gio.AppInfo = null, provider: ?*apps.Provider = null };
const Action = struct { menu: *Menu, command: Command };
pub const Menu = struct {
    owner: *Window,
    popover: ?*gtk.PopoverMenu = null,
    group: *gio.SimpleActionGroup,
    actions: [std.enums.values(Command).len]Action = undefined,
    snapshot: ?Context = null,
    extras: std.ArrayList(Extra) = .empty,
    cleanup: c_uint = 0,
    serial: u64 = 0,
    active: bool = false,
    focus_anchor: ?*gtk.Widget = null,
    query_cancel: ?*gio.Cancellable = null,
    providers: apps.Providers = .{},
    pub fn init(owner: *Window) Menu {
        return .{ .owner = owner, .group = gio.SimpleActionGroup.new() };
    }
    pub fn start(self: *Menu) void {
        self.owner.root.as(gtk.Widget).insertActionGroup("ctx", self.group.as(gio.ActionGroup));
        for (std.enums.values(Command)) |cmd| {
            const i = @intFromEnum(cmd);
            self.actions[i] = .{ .menu = self, .command = cmd };
            const action = if (toggle(cmd)) gio.SimpleAction.newStateful(@tagName(cmd), null, glib.Variant.newBoolean(0)) else gio.SimpleAction.new(@tagName(cmd), null);
            _ = gio.SimpleAction.signals.activate.connect(action, *Action, activated, &self.actions[i], .{});
            self.group.as(gio.ActionMap).addAction(action.as(gio.Action));
            action.unref();
        }
        const t = glib.VariantType.new("u");
        defer t.free();
        const action = gio.SimpleAction.new("extra", t);
        _ = gio.SimpleAction.signals.activate.connect(action, *Menu, extraActivated, self, .{});
        self.group.as(gio.ActionMap).addAction(action.as(gio.Action));
        action.unref();
        self.providers.load();
    }
    fn toggle(cmd: Command) bool {
        return switch (cmd) {
            .grid, .list, .sort_name, .sort_size, .sort_type, .sort_modified, .hidden, .reverse, .folders_first, .advanced, .allow_delete, .pin, .favorite => true,
            else => false,
        };
    }
    fn clearExtras(self: *Menu) void {
        for (self.extras.items) |e| {
            if (e.file) |f| f.unref();
            if (e.app) |app| app.unref();
        }
        self.extras.clearRetainingCapacity();
    }
    pub fn close(self: *Menu) void {
        self.active = false;
        self.serial +%= 1;
        if (self.cleanup != 0) {
            _ = glib.Source.remove(self.cleanup);
            self.cleanup = 0;
        }
        if (self.query_cancel) |c| {
            c.cancel();
            c.unref();
            self.query_cancel = null;
        }
        if (self.popover) |p| p.as(gtk.Popover).popdown();
        if (self.snapshot) |*c| c.deinit();
        self.snapshot = null;
        self.clearExtras();
        if (self.focus_anchor) |w| {
            if (w.getRoot() != null) _ = w.grabFocus();
            w.unref();
            self.focus_anchor = null;
        }
    }
    pub fn stop(self: *Menu) void {
        self.close();
        if (self.popover) |p| {
            p.as(gtk.Widget).unparent();
            p.unref();
            self.popover = null;
        }
    }
    pub fn deinit(self: *Menu) void {
        self.stop();
        self.group.unref();
        self.extras.deinit(a);
        self.providers.deinit();
    }
    fn closed(_: *gtk.Popover, self: *Menu) callconv(.c) void {
        if (self.cleanup == 0 and self.active) self.cleanup = glib.idleAdd(cleanupIdle, self);
    }
    fn cleanupIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Menu = @ptrCast(@alignCast(data.?));
        self.cleanup = 0;
        self.close();
        return 0;
    }
    pub fn show(self: *Menu, c: Context, anchor: *gtk.Widget, x: f64, y: f64) void {
        self.close();
        self.snapshot = c;
        self.active = true;
        const tab = self.owner.findTab(c.tab_id).?;
        const focused = self.owner.window.getFocus() orelse (if (tab.list_mode) tab.list.as(gtk.Widget) else tab.grid.as(gtk.Widget));
        focused.ref();
        self.focus_anchor = focused;
        if (self.popover == null) {
            const p = gtk.PopoverMenu.newFromModel(null);
            _ = p.as(object.Object).refSink();
            p.as(gtk.Widget).setParent(self.owner.root.as(gtk.Widget));
            p.as(gtk.Widget).addCssClass("context-menu");
            const keys = gtk.EventControllerKey.new();
            keys.as(gtk.EventController).setPropagationPhase(.capture);
            _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Window, Window.keyPressed, self.owner, .{});
            p.as(gtk.Widget).addController(keys.as(gtk.EventController));
            p.as(gtk.Popover).setHasArrow(0);
            p.as(gtk.Popover).setAutohide(1);
            _ = gtk.Popover.signals.closed.connect(p.as(gtk.Popover), *Menu, closed, self, .{});
            self.popover = p;
        }
        self.build();
        var px: f64 = 0;
        var py: f64 = 0;
        _ = anchor.translateCoordinates(self.owner.root.as(gtk.Widget), x, y, &px, &py);
        const rect: gdk.Rectangle = .{ .f_x = @intFromFloat(px), .f_y = @intFromFloat(py), .f_width = 1, .f_height = 1 };
        self.popover.?.as(gtk.Popover).setPointingTo(&rect);
        self.popover.?.as(gtk.Popover).popup();
        self.query();
    }
    pub fn keyboard(self: *Menu, tab: *Tab) void {
        const focus = self.owner.window.getFocus();
        if (focus) |f| if (Tab.itemAt(f, tab.root.as(gtk.Widget)) orelse (if (f != tab.grid.as(gtk.Widget) and f != tab.list.as(gtk.Widget)) Tab.itemWithin(f) else null)) |item| {
            const pos = item.getPosition();
            if (pos != std.math.maxInt(c_uint) and tab.selection.as(gtk.SelectionModel).isSelected(pos) == 0) _ = tab.selection.as(gtk.SelectionModel).selectItem(pos, 1);
        };
        const anchor = focus orelse tab.root.as(gtk.Widget);
        self.show(Context.capture(tab), anchor, 8, @floatFromInt(@min(anchor.getHeight(), 32)));
    }
    pub fn fresh(self: *Menu, cmd: Command) void {
        var c = if (self.snapshot) |*snapshot| snapshot.clone() else Context.capture(self.owner.current());
        defer c.deinit();
        const enabled = self.valid(&c) and self.allowed(&c, cmd);
        self.close();
        if (enabled) self.execute(&c, cmd);
    }
    fn activated(_: *gio.SimpleAction, _: ?*glib.Variant, data: *Action) callconv(.c) void {
        const self = data.menu;
        if (self.snapshot == null) return;
        var c = self.snapshot.?.clone();
        defer c.deinit();
        if (!self.valid(&c) or !self.allowed(&c, data.command)) {
            self.close();
            return;
        }
        self.close();
        self.execute(&c, data.command);
    }
    fn valid(self: *Menu, c: *const Context) bool {
        const tab = self.owner.findTab(c.tab_id) orelse return false;
        return tab.generation == c.generation and !self.owner.closed;
    }
    fn countUnknown(c: *const Context) bool {
        for (c.items.items) |item| if (item.info != null) return false;
        return true;
    }
    fn add(_: *Menu, model: *gio.Menu, label: [*:0]const u8, cmd: Command) void {
        const name = u.format("ctx.{s}", .{@tagName(cmd)});
        defer a.free(name);
        const item = gio.MenuItem.new(label, name);
        defer item.unref();
        const shortcut: ?[*:0]const u8 = switch (cmd) {
            .cut => "<Control>x",
            .copy => "<Control>c",
            .paste => "<Control>v",
            .undo => "<Control>z",
            .redo => "<Control><Shift>z",
            .rename => "F2",
            .properties => "<Alt>Return",
            .new_folder => "<Control><Shift>n",
            .trash => "Delete",
            .delete => "<Shift>Delete",
            .new_tab => "<Control>t",
            .close_tab => "<Control>w",
            .hidden => "<Control>h",
            .grid => "<Control>1",
            .list => "<Control>2",
            else => null,
        };
        if (shortcut) |value| item.setAttributeValue("accel", glib.Variant.newString(value));
        model.appendItem(item);
    }
    fn section(_: *Menu, model: *gio.Menu, part: *gio.Menu) void {
        if (part.as(gio.MenuModel).getNItems() > 0) model.appendSection(null, part.as(gio.MenuModel));
        part.unref();
    }
    fn submenu(_: *Menu, model: *gio.Menu, label: [*:0]const u8, part: *gio.Menu) void {
        if (part.as(gio.MenuModel).getNItems() > 0) model.appendSubmenu(label, part.as(gio.MenuModel));
        part.unref();
    }
    pub fn extra(self: *Menu, model: *gio.Menu, label: [*:0]const u8, value: Extra) void {
        if (value.file) |f| f.ref();
        if (value.app) |app| app.ref();
        const idx = self.extras.items.len;
        self.extras.append(a, value) catch unreachable;
        const item = gio.MenuItem.new(label, null);
        defer item.unref();
        item.setActionAndTargetValue("ctx.extra", glib.Variant.newUint32(@intCast(idx)));
        model.appendItem(item);
    }
    fn extraActivated(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Menu) callconv(.c) void {
        const idx = (param orelse return).getUint32();
        if (idx >= self.extras.items.len or self.snapshot == null) return;
        const e = self.extras.items[idx];
        if (e.file) |f| f.ref();
        defer if (e.file) |f| f.unref();
        if (e.app) |app| app.ref();
        defer if (e.app) |app| app.unref();
        var c = self.snapshot.?.clone();
        defer c.deinit();
        if (!self.valid(&c)) {
            self.close();
            return;
        }
        const cmd: Command = switch (e.kind) {
            .template => .new_document,
            .copy => .copy_to,
            .move => .move_to,
            else => .properties,
        };
        if (!self.allowed(&c, cmd)) {
            self.close();
            return;
        }
        self.close();
        switch (e.kind) {
            .app => apps.launch(self.owner, &c, e.app.?),
            .copy, .move => self.owner.operations.transfer(&c, e.file, if (e.kind == .copy) .copy else .move),
            .template => {
                var source = Context.init(self.owner.current(), .selection);
                defer source.deinit();
                source.add(e.file.?, null);
                self.owner.operations.transfer(&source, c.directory, .copy);
            },
            .provider => apps.runProvider(self.owner, &c, e.provider.?),
        }
    }
    pub fn allowed(self: *Menu, c: *const Context, cmd: Command) bool {
        var f = c.facts(self.owner.clipboard.available(), self.owner.operations.busy);
        const place = c.kind == .place or c.kind == .bookmark or c.kind == .location or c.kind == .device or c.kind == .tab;
        if (place and countUnknown(c)) f.all_directories = true;
        const accessible = c.volume == null or c.mount != null;
        const count = c.items.items.len;
        if (cmd == .paste or cmd == .new_folder or cmd == .new_document) f.can_write = if (c.directory_info) |i| i.getAttributeBoolean("access::can-write") != 0 else false;
        return switch (cmd) {
            .open => accessible and count > 0 and (place or !f.trash),
            .copy => rules.enabled(f, .copy),
            .cut => rules.enabled(f, .cut),
            .rename => rules.enabled(f, .rename),
            .trash => rules.enabled(f, .trash),
            .delete => rules.enabled(f, .delete) and (self.owner.preferences.allow_delete or f.trash),
            .paste, .paste_into => rules.enabled(f, .paste) and (cmd != .paste_into or (count == 1 and f.all_directories)),
            .new_folder, .new_document => rules.enabled(f, .create),
            .open_tab, .open_window => accessible and f.all_directories and (!f.trash or place),
            .terminal => rules.enabled(f, .terminal) and apps.terminalProgram() != null,
            .copy_to, .duplicate => rules.enabled(f, .copy) and !f.busy,
            .move_to => rules.enabled(f, .cut) and !f.busy,
            .copy_other, .move_other => self.owner.split and !f.busy and count > 0 and !f.trash,
            .link => f.local and count > 0 and !f.trash and !f.busy,
            .restore, .restore_to => rules.enabled(f, .restore),
            .empty_trash => f.trash and !f.busy and (self.owner.findTab(c.tab_id).?.selection.as(gio.ListModel).getNItems() > 0),
            .undo => !f.busy and self.owner.operations.undo_stack.items.len > 0,
            .redo => !f.busy and self.owner.operations.redo_stack.items.len > 0,
            .open_with => count > 0 and !f.all_directories and !f.trash,
            .follow_link => count == 1 and (if (c.items.items[0].info) |i| i.getIsSymlink() != 0 else false),
            .containing => count == 1,
            .pin, .favorite => count > 0 and !f.trash,
            .bookmark_add => (count == 0 or (count == 1 and f.all_directories)) and !f.trash,
            .mount => if (c.volume) |v| v.canMount() != 0 else false,
            .unmount => if (c.mount) |m| m.canUnmount() != 0 else false,
            .eject => if (c.mount) |m| m.canEject() != 0 else if (c.volume) |v| v.canEject() != 0 else false,
            .tab_other => self.owner.split,
            .tab_left, .tab_right => blk: {
                const t = self.owner.findTab(c.tab_id) orelse break :blk false;
                const p = &self.owner.panes[t.pane];
                for (p.tabs.items, 0..) |tab, i| if (tab == t) break :blk if (cmd == .tab_left) i > 0 else i + 1 < p.tabs.items.len;
                break :blk false;
            },
            .tab_close_others => self.owner.panes[c.pane].tabs.items.len > 1,
            .archive, .extract => f.local and count > 0 and apps.available("file-roller"),
            .bulk_rename => count > 1 and apps.available("bulky") and f.local,
            .admin => f.local and f.all_directories and apps.adminAvailable(),
            else => true,
        };
    }
    pub fn update(self: *Menu) void {
        if (!self.active or self.snapshot == null) return;
        const c = &self.snapshot.?;
        if (!self.valid(c)) {
            self.close();
            return;
        }
        for (std.enums.values(Command)) |cmd| {
            const action: *gio.SimpleAction = @ptrCast(self.group.as(gio.ActionMap).lookupAction(@tagName(cmd)).?);
            action.setEnabled(@intFromBool(self.allowed(c, cmd)));
            if (toggle(cmd)) {
                const state = switch (cmd) {
                    .grid => !self.owner.findTab(c.tab_id).?.list_mode,
                    .list => self.owner.findTab(c.tab_id).?.list_mode,
                    .sort_name => self.owner.preferences.sort == .name,
                    .sort_size => self.owner.preferences.sort == .size,
                    .sort_type => self.owner.preferences.sort == .type,
                    .sort_modified => self.owner.preferences.sort == .modified,
                    .hidden => self.owner.findTab(c.tab_id).?.hidden,
                    .reverse => self.owner.preferences.reverse,
                    .folders_first => self.owner.preferences.folders_first,
                    .advanced => self.owner.preferences.advanced,
                    .allow_delete => self.owner.preferences.allow_delete,
                    .pin => self.owner.preferences.contains("pinned", c.target()),
                    .favorite => self.owner.preferences.contains("favorites", c.target()),
                    else => false,
                };
                action.setState(glib.Variant.newBoolean(@intFromBool(state)));
            }
        }
    }
    fn build(self: *Menu) void {
        const c = &self.snapshot.?;
        const f = c.facts(self.owner.clipboard.available(), self.owner.operations.busy);
        const menu = gio.Menu.new();
        defer menu.unref();
        if (c.kind == .tab) {
            const first = gio.Menu.new();
            self.add(first, "New tab", .new_tab);
            self.add(first, "Duplicate tab", .tab_duplicate);
            self.section(menu, first);
            const second = gio.Menu.new();
            self.add(second, "Move tab left", .tab_left);
            self.add(second, "Move tab right", .tab_right);
            if (self.owner.split) self.add(second, "Move to other pane", .tab_other);
            self.section(menu, second);
            const end = gio.Menu.new();
            self.add(end, "Close tab", .close_tab);
            self.add(end, "Close other tabs", .tab_close_others);
            self.section(menu, end);
        } else if (c.kind == .bookmark or c.kind == .place or c.kind == .location or c.kind == .device) {
            const open = gio.Menu.new();
            self.add(open, "Open", .open);
            self.add(open, "Open in new tab", .open_tab);
            self.add(open, "Open in new window", .open_window);
            if (apps.terminalProgram() != null) self.add(open, "Open in terminal", .terminal);
            self.section(menu, open);
            const edit = gio.Menu.new();
            self.add(edit, "Copy location", .copy_location);
            if (c.kind == .bookmark) {
                self.add(edit, "Rename bookmark…", .bookmark_rename);
                self.add(edit, "Remove bookmark", .bookmark_remove);
            }
            if (c.kind == .device) {
                if (self.allowed(c, .mount)) self.add(edit, "Mount", .mount);
                if (self.allowed(c, .eject)) self.add(edit, "Eject", .eject) else if (self.allowed(c, .unmount)) self.add(edit, "Unmount", .unmount);
            }
            self.section(menu, edit);
            self.add(menu, "Properties", .properties);
        } else if (f.trash) {
            const restore = gio.Menu.new();
            if (c.items.items.len > 0) {
                self.add(restore, "Restore", .restore);
                self.add(restore, "Restore to…", .restore_to);
                self.add(restore, "Delete permanently…", .delete);
            } else self.add(restore, "Empty Trash…", .empty_trash);
            self.section(menu, restore);
            if (c.items.items.len == 0) self.viewMenu(menu);
            self.add(menu, "Properties", .properties);
        } else if (c.items.items.len == 0) {
            const create = gio.Menu.new();
            self.add(create, "New folder…", .new_folder);
            const documents = gio.Menu.new();
            self.add(documents, "Empty document…", .new_document);
            self.templates(documents);
            self.submenu(create, "New document", documents);
            self.section(menu, create);
            const edit = gio.Menu.new();
            self.add(edit, "Paste", .paste);
            self.add(edit, "Undo", .undo);
            self.add(edit, "Redo", .redo);
            self.section(menu, edit);
            if (apps.terminalProgram() != null) self.add(menu, "Open in terminal", .terminal);
            self.viewMenu(menu);
            const extensions = gio.Menu.new();
            for (self.providers.items.items) |p| if (p.matches(c)) self.extra(extensions, p.name, .{ .kind = .provider, .provider = p });
            self.section(menu, extensions);
            self.add(menu, "Properties", .properties);
        } else {
            const open = gio.Menu.new();
            const label = if (c.items.items.len > 1) u.format("Open {d} items", .{c.items.items.len}) else a.dupeZ(u8, "Open") catch unreachable;
            defer a.free(label);
            self.add(open, label, .open);
            if (f.all_directories) {
                self.add(open, "Open in new tab", .open_tab);
                self.add(open, "Open in new window", .open_window);
                if (apps.terminalProgram() != null and c.items.items.len == 1) self.add(open, "Open in terminal", .terminal);
            } else {
                const with = gio.Menu.new();
                const candidates = apps.common(c);
                defer {
                    for (candidates.items) |app| app.unref();
                    var list_ = candidates;
                    list_.deinit(a);
                }
                for (candidates.items) |app| self.extra(with, app.getDisplayName(), .{ .kind = .app, .app = app });
                self.add(with, "Other application…", .open_with);
                self.submenu(open, "Open with", with);
            }
            if (self.allowed(c, .follow_link)) self.add(open, "Follow link to original", .follow_link);
            if (self.owner.findTab(c.tab_id).?.query.len != 0) self.add(open, "Open containing folder", .containing);
            self.section(menu, open);
            const edit = gio.Menu.new();
            self.add(edit, "Cut", .cut);
            self.add(edit, "Copy", .copy);
            if (f.all_directories and c.items.items.len == 1) self.add(edit, "Paste into folder", .paste_into);
            if (self.owner.preferences.advanced) {
                self.destinations(edit, false);
                self.destinations(edit, true);
            }
            self.section(menu, edit);
            const change = gio.Menu.new();
            if (c.items.items.len == 1) self.add(change, "Rename…", .rename) else if (apps.available("bulky")) self.add(change, "Rename items…", .bulk_rename);
            if (self.owner.preferences.advanced) {
                self.add(change, "Duplicate", .duplicate);
                self.add(change, "Make link", .link);
                self.add(change, "Pinned", .pin);
                self.add(change, "Favorite", .favorite);
            }
            if (f.all_directories and c.items.items.len == 1) self.add(change, "Add bookmark", .bookmark_add);
            self.section(menu, change);
            const extensions = gio.Menu.new();
            if (apps.available("file-roller") and f.local) {
                self.add(extensions, "Compress…", .archive);
                if (apps.archive(c)) self.add(extensions, "Extract…", .extract);
            }
            if (f.all_directories and f.local and apps.adminAvailable()) self.add(extensions, "Open as administrator", .admin);
            for (self.providers.items.items) |p| if (p.matches(c)) self.extra(extensions, p.name, .{ .kind = .provider, .provider = p });
            self.section(menu, extensions);
            const remove = gio.Menu.new();
            self.add(remove, "Move to Trash…", .trash);
            if (self.owner.preferences.allow_delete) self.add(remove, "Delete permanently…", .delete);
            self.section(menu, remove);
            self.add(menu, "Properties", .properties);
        }
        self.popover.?.setMenuModel(menu.as(gio.MenuModel));
        self.update();
    }
    fn viewMenu(self: *Menu, menu: *gio.Menu) void {
        const section_ = gio.Menu.new();
        const view = gio.Menu.new();
        self.add(view, "Icon view", .grid);
        self.add(view, "Detailed list", .list);
        self.submenu(section_, "View", view);
        const sort = gio.Menu.new();
        self.add(sort, "Name", .sort_name);
        self.add(sort, "Size", .sort_size);
        self.add(sort, "Type", .sort_type);
        self.add(sort, "Modified", .sort_modified);
        self.add(sort, "Descending", .reverse);
        self.add(sort, "Folders first", .folders_first);
        self.submenu(section_, "Sort by", sort);
        self.add(section_, "Show hidden files", .hidden);
        self.section(menu, section_);
    }
    fn destinations(self: *Menu, menu: *gio.Menu, move: bool) void {
        const part = gio.Menu.new();
        if (self.owner.split) self.add(part, "Other pane", if (move) .move_other else .copy_other);
        const bookmarks = self.owner.preferences.strings("bookmarks");
        defer if (bookmarks) |v| glib.strfreev(v);
        if (bookmarks) |v| for (std.mem.span(v)) |uri| {
            const f = gio.File.newForUri(uri.?);
            defer f.unref();
            const label = self.owner.preferences.bookmarkName(f);
            defer glib.free(label);
            self.extra(part, label, .{ .kind = if (move) .move else .copy, .file = f });
        };
        self.add(part, "Choose folder…", if (move) .move_to else .copy_to);
        self.submenu(menu, if (move) "Move to" else "Copy to", part);
    }
    fn templates(self: *Menu, menu: *gio.Menu) void {
        if (self.allowed(&self.snapshot.?, .new_document)) apps.templates(self, menu);
    }
    fn query(self: *Menu) void {
        self.query_cancel = gio.Cancellable.new();
        const c = &self.snapshot.?;
        if (c.directory_info == null) self.queryOne(c.directory, null);
        for (c.items.items, 0..) |item, i| if (item.info == null) self.queryOne(item.file, i);
    }
    const Query = struct { owner: *Menu, serial: u64, index: ?usize };
    fn queryOne(self: *Menu, file: *gio.File, index: ?usize) void {
        const request = a.create(Query) catch unreachable;
        request.* = .{ .owner = self, .serial = self.serial, .index = index };
        self.owner.app.as(gio.Application).hold();
        file.queryInfoAsync("standard::*,access::*,trash::*", .{ .nofollow_symlinks = true }, 0, self.query_cancel, queried, request);
    }
    fn queried(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const r: *Query = @ptrCast(@alignCast(data.?));
        const self = r.owner;
        defer {
            self.owner.app.as(gio.Application).release();
            a.destroy(r);
        }
        var err: ?*glib.Error = null;
        const file: *gio.File = @ptrCast(source.?);
        const info = file.queryInfoFinish(result, &err);
        if (err) |e| e.free();
        if (!self.active or self.serial != r.serial or self.snapshot == null) {
            if (info) |i| i.unref();
            return;
        }
        if (r.index) |idx| self.snapshot.?.items.items[idx].info = info else self.snapshot.?.directory_info = info;
        self.update();
    }
    pub fn execute(self: *Menu, c: *const Context, cmd: Command) void {
        const owner = self.owner;
        const tab = owner.findTab(c.tab_id) orelse return;
        switch (cmd) {
            .open, .open_tab, .open_window => {
                if (c.items.items.len > 5) self.confirmOpen(c, cmd) else self.openTargets(c, cmd);
            },
            .new_folder => owner.operations.name(c, .folder),
            .new_document => owner.operations.name(c, .document),
            .rename => owner.operations.name(c, .rename),
            .trash => owner.operations.confirm(c, .trash),
            .delete => owner.operations.confirm(c, .delete),
            .empty_trash => owner.operations.confirm(c, .empty_trash),
            .copy, .cut => owner.operations.copy(c, cmd == .cut),
            .paste => owner.operations.pasteInto(c.directory),
            .paste_into => owner.operations.pasteInto(c.target()),
            .copy_to, .move_to, .restore_to => self.choose(c, cmd),
            .copy_other, .move_other => {
                const p = &owner.panes[1 - c.pane];
                const dir = gio.File.newForUri(p.tabs.items[p.selected].uri);
                defer dir.unref();
                owner.operations.transfer(c, dir, if (cmd == .copy_other) .copy else .move);
            },
            .duplicate, .link => owner.operations.duplicate(c, cmd == .link),
            .restore => owner.operations.transfer(c, null, .restore),
            .undo, .redo => owner.operations.undo(cmd == .redo),
            .properties => apps.properties(owner, c),
            .open_with => apps.choose(owner, c),
            .terminal => apps.terminal(owner, c.target()),
            .copy_location => {
                const path = c.target().getParseName();
                defer glib.free(path);
                gdk.Display.getDefault().?.getClipboard().setText(path);
            },
            .containing => {
                const parent = c.target().getParent() orelse return;
                defer parent.unref();
                tab.navigate(parent, true);
            },
            .follow_link => apps.follow(owner, c),
            .bookmark_add => {
                owner.preferences.addBookmark(c.target());
                owner.refreshPlaces();
            },
            .bookmark_remove => {
                owner.preferences.removeBookmark(c.target());
                owner.refreshPlaces();
            },
            .bookmark_rename => owner.operations.name(c, .bookmark),
            .pin, .favorite => {
                const key: [:0]const u8 = if (cmd == .pin) "pinned" else "favorites";
                const remove = owner.preferences.contains(key, c.target());
                for (c.items.items) |item| if (owner.preferences.contains(key, item.file) == remove) owner.preferences.toggle(key, item.file);
                owner.refreshPlaces();
                owner.resort();
            },
            .menu_settings => self.settings(),
            .mount, .unmount, .eject => apps.volume(owner, c, cmd),
            .tab_duplicate, .tab_left, .tab_right, .tab_other, .tab_close_others, .close_tab => owner.tabCommand(tab, cmd),
            .archive, .extract, .bulk_rename, .admin => apps.integration(owner, c, cmd),
            else => {
                owner.activatePane(c.pane);
                owner.dispatch(cmd);
            },
        }
    }
    fn openTargets(self: *Menu, c: *const Context, cmd: Command) void {
        const owner = self.owner;
        const tab = owner.findTab(c.tab_id) orelse return;
        for (c.items.items, 0..) |item, i| {
            const folder = if (item.info) |info| info.getFileType() == .directory else c.kind != .selection;
            if (cmd == .open_tab or (cmd == .open and folder and i > 0)) owner.addTab(c.pane, item.file) else if (cmd == .open_window) @import("main.zig").newWindow(owner.app, item.file, owner.options) else if (folder) tab.navigate(item.file, true) else if (item.info) |info| owner.openFile(item.file, info);
        }
        owner.sync();
    }
    const OpenRequest = struct { menu: *Menu, context: Context, command: Command };
    fn confirmOpen(self: *Menu, c: *const Context, cmd: Command) void {
        const r = a.create(OpenRequest) catch unreachable;
        r.* = .{ .menu = self, .context = c.clone(), .command = cmd };
        const d = gtk.Dialog.new();
        d.as(gtk.Window).setTitle("Open selected items?");
        d.as(gtk.Window).setTransientFor(self.owner.window);
        d.as(gtk.Window).setModal(1);
        d.as(gtk.Window).setDestroyWithParent(1);
        const title = u.format("Open all {d} selected items?", .{c.items.items.len});
        defer a.free(title);
        d.getContentArea().append(u.label(title, null).as(gtk.Widget));
        _ = d.addButton("Cancel", 0);
        _ = d.addButton("Open items", 1);
        d.setDefaultResponse(0);
        self.owner.app.as(gio.Application).hold();
        d.as(object.Object).setDataFull("phyto-open", r, openFreed);
        _ = gtk.Dialog.signals.response.connect(d, *OpenRequest, openResponse, r, .{});
        d.as(gtk.Window).present();
    }
    fn openFreed(data: ?*anyopaque) callconv(.c) void {
        const r: *OpenRequest = @ptrCast(@alignCast(data.?));
        r.context.deinit();
        r.menu.owner.app.as(gio.Application).release();
        a.destroy(r);
    }
    fn openResponse(d: *gtk.Dialog, response: c_int, r: *OpenRequest) callconv(.c) void {
        if (response == 1 and !r.menu.owner.closed) r.menu.openTargets(&r.context, r.command);
        d.as(gtk.Window).destroy();
    }
    const Choose = struct { owner: *Window, context: Context, command: Command, dialog: *gtk.FileDialog };
    fn choose(self: *Menu, c: *const Context, cmd: Command) void {
        const r = a.create(Choose) catch unreachable;
        r.* = .{ .owner = self.owner, .context = c.clone(), .command = cmd, .dialog = gtk.FileDialog.new() };
        r.dialog.setTitle("Choose destination folder");
        self.owner.app.as(gio.Application).hold();
        r.dialog.selectFolder(self.owner.window, self.owner.background_cancel, chosen, r);
    }
    fn chosen(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const r: *Choose = @ptrCast(@alignCast(data.?));
        defer {
            r.context.deinit();
            r.dialog.unref();
            r.owner.app.as(gio.Application).release();
            a.destroy(r);
        }
        var err: ?*glib.Error = null;
        const folder = r.dialog.selectFolderFinish(result, &err);
        if (err) |e| e.free();
        if (folder) |dir| {
            defer dir.unref();
            if (!r.owner.closed) r.owner.operations.transfer(&r.context, dir, if (r.command == .copy_to) .copy else if (r.command == .restore_to) .restore else .move);
        }
    }
    fn settings(self: *Menu) void {
        const d = gtk.Dialog.new();
        d.as(gtk.Window).setTitle("Context menu options");
        d.as(gtk.Window).setDestroyWithParent(1);
        d.as(gtk.Window).setTransientFor(self.owner.window);
        d.as(gtk.Window).setModal(1);
        d.as(gtk.Widget).addCssClass("phyto-root");
        d.as(gtk.Widget).addCssClass(if (self.owner.options.native) "native" else if (self.owner.options.light) "light" else "dark");
        d.as(gtk.Widget).insertActionGroup("win", object.ext.cast(gtk.ApplicationWindow, self.owner.window).?.as(gio.ActionGroup));
        const body = d.getContentArea();
        body.as(gtk.Widget).addCssClass("dialog-body");
        inline for (.{ .{ "Show advanced file actions", "advanced" }, .{ "Show permanent deletion", "allow_delete" } }) |pair| {
            const b = gtk.CheckButton.newWithLabel(pair[0]);
            b.setActive(@intFromBool(@field(self.owner.preferences, pair[1])));
            b.as(gtk.Actionable).setActionName("win." ++ pair[1]);
            body.append(b.as(gtk.Widget));
        }
        _ = d.addButton("Close", 0);
        _ = gtk.Dialog.signals.response.connect(d, ?*anyopaque, struct {
            fn close(dialog: *gtk.Dialog, _: c_int, _: ?*anyopaque) callconv(.c) void {
                dialog.as(gtk.Window).destroy();
            }
        }.close, null, .{});
        d.as(gtk.Window).present();
    }
};
