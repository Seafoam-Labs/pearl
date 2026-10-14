const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const w = @import("../../ui/components/widgets.zig");
const model = @import("model.zig");
const layout = @import("layout.zig");
const directory = @import("directory.zig");
const actions = @import("actions.zig");
const Apps = @import("../apps.zig");
const a = std.heap.c_allocator;
pub const View = struct {
    store: *directory.Store,
    apps: *Apps.Index,
    window: *gtk.Window,
    root: *gtk.Box,
    scroll: *gtk.ScrolledWindow,
    fixed: *gtk.Fixed,
    status: *gtk.Label,
    config: model.Config = .{},
    font: u8 = 14,
    width: i32 = 0,
    height: i32 = 0,
    allowed: bool = true,
    arena: std.heap.ArenaAllocator,
    menu_arena: std.heap.ArenaAllocator,
    indices: []usize = &.{},
    uris: []const []const u8 = &.{},
    slots: []usize = &.{},
    selection: model.Selection = .{ .bits = &.{} },
    grid: layout.Grid = layout.Grid.init(800, 48, 14),
    cells: std.ArrayList(*gtk.Widget) = .empty,
    cell_indices: std.ArrayList(usize) = .empty,
    menu: ?*gtk.Popover = null,
    menu_entry: ?*gtk.Entry = null,
    menu_choice: ?*gtk.DropDown = null,
    app_ids: []const [:0]const u8 = &.{},
    job: ?*actions.Job = null,
    queue: std.ArrayList(actions.Request) = .empty,
    queue_arena: std.heap.ArenaAllocator,
    failures: usize = 0,
    feedback: [256:0]u8 = @splat(0),
    successes: usize = 0,
    adjustment_signal: c_ulong = 0,
    dragging: bool = false,
    drag_index: ?usize = null,
    drag_x: f64 = 0,
    drag_y: f64 = 0,
    band: *gtk.Box,
    context: *anyopaque,
    settings: *const fn (*anyopaque) void,
    crop: *const fn (*anyopaque) void,
    pub fn create(window: *gtk.Window, store: *directory.Store, apps: *Apps.Index, context: *anyopaque, settings: *const fn (*anyopaque) void, crop: *const fn (*anyopaque) void) !*View {
        const self = try a.create(View);
        const root = gtk.Box.new(.vertical, 0);
        _ = root.ref();
        const status = w.label("", "pearl-desktop-status");
        status.setWrap(1);
        root.append(status.as(gtk.Widget));
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        scroll.as(gtk.Widget).setHexpand(1);
        const fixed = gtk.Fixed.new();
        fixed.as(gtk.Widget).setFocusable(1);
        fixed.as(gtk.Widget).addCssClass("pearl-desktop-grid");
        fixed.as(gtk.Widget).setVexpand(1);
        w.name(fixed.as(gtk.Widget), "Desktop files");
        scroll.setChild(fixed.as(gtk.Widget));
        root.append(scroll.as(gtk.Widget));
        const band = gtk.Box.new(.vertical, 0);
        band.as(gtk.Widget).addCssClass("pearl-desktop-band");
        band.as(gtk.Widget).setCanTarget(0);
        fixed.put(band.as(gtk.Widget), 0, 0);
        band.as(gtk.Widget).setVisible(0);
        self.* = .{ .store = store, .apps = apps, .window = window, .root = root, .scroll = scroll, .fixed = fixed, .status = status, .arena = .init(a), .menu_arena = .init(a), .queue_arena = .init(a), .band = band, .context = context, .settings = settings, .crop = crop };
        const click = gtk.GestureClick.new();
        click.as(gtk.GestureSingle).setButton(0);
        click.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.GestureClick.signals.pressed.connect(click, *View, pressed, self, .{});
        fixed.as(gtk.Widget).addController(click.as(gtk.EventController));
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *View, key, self, .{});
        fixed.as(gtk.Widget).addController(keys.as(gtk.EventController));
        const drag = gtk.GestureDrag.new();
        drag.as(gtk.GestureSingle).setButton(1);
        drag.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *View, dragBegin, self, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *View, dragUpdate, self, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *View, dragEnd, self, .{});
        fixed.as(gtk.Widget).addController(drag.as(gtk.EventController));
        click.as(gtk.Gesture).group(drag.as(gtk.Gesture));
        self.adjustment_signal = gtk.Adjustment.signals.value_changed.connect(scroll.getVadjustment(), *View, scrolled, self, .{});
        return self;
    }
    pub fn destroy(self: *View) void {
        self.closeMenu();
        if (self.job) |job| job.detach();
        object.signalHandlerDisconnect(self.scroll.getVadjustment().as(object.Object), self.adjustment_signal);
        self.clearCells();
        self.cells.deinit(a);
        self.cell_indices.deinit(a);
        self.queue.deinit(a);
        self.queue_arena.deinit();
        self.arena.deinit();
        self.menu_arena.deinit();
        self.root.unref();
        a.destroy(self);
    }
    pub fn configure(self: *View, config: model.Config, font: u8, width: i32, height: i32, allowed: bool) void {
        const changed = config.icon_size != self.config.icon_size or config.show_hidden != self.config.show_hidden or config.arrangement != self.config.arrangement or font != self.font or width != self.width or height != self.height;
        self.config = config;
        self.font = font;
        self.width = @max(1, width);
        self.height = @max(1, height);
        if (self.allowed and !allowed) {
            self.closeMenu();
            self.dragging = false;
            self.band.as(gtk.Widget).setVisible(0);
            if (self.job) |job| {
                job.detach();
                self.job = null;
                self.queue.clearRetainingCapacity();
            }
        }
        self.allowed = allowed;
        self.root.as(gtk.Widget).setSensitive(@intFromBool(allowed));
        if (changed) self.update();
    }
    pub fn update(self: *View) void {
        self.closeMenu();
        self.dragging = false;
        self.band.as(gtk.Widget).setVisible(0);
        var selected: std.StringHashMap(void) = .init(a);
        defer selected.deinit();
        for (self.uris, 0..) |uri, i| if (self.selection.bits[i]) tryPut(&selected, uri);
        const old_focus = if (self.selection.focus < self.uris.len) self.uris[self.selection.focus] else "";
        const old_anchor = if (self.selection.anchor < self.uris.len) self.uris[self.selection.anchor] else "";
        const old_arena = self.arena;
        self.arena = .init(a);
        defer {
            var old = old_arena;
            old.deinit();
        }
        self.indices = &.{};
        self.uris = &.{};
        self.slots = &.{};
        self.selection = .{ .bits = &.{} };
        const alloc = self.arena.allocator();
        const snapshot = self.store.snapshot orelse {
            self.message("Loading Desktop…");
            self.clearCells();
            return;
        };
        var indices: std.ArrayList(usize) = .empty;
        for (snapshot.items.items, 0..) |item, i| if (self.config.show_hidden or item.info.getIsHidden() == 0) {
            indices.append(alloc, i) catch {};
        };
        self.indices = indices.items;
        const uris = alloc.alloc([]const u8, indices.items.len) catch return;
        self.uris = uris;
        self.selection.bits = alloc.alloc(bool, uris.len) catch return;
        const preferred = alloc.alloc(?layout.Position, uris.len) catch return;
        for (indices.items, 0..) |index, i| {
            uris[i] = alloc.dupe(u8, snapshot.items.items[index].uri) catch "";
            self.selection.bits[i] = selected.contains(uris[i]);
            if (std.mem.eql(u8, old_focus, uris[i])) self.selection.focus = i;
            if (std.mem.eql(u8, old_anchor, uris[i])) self.selection.anchor = i;
            preferred[i] = if (self.config.arrangement == .manual) self.store.state.position(uris[i]) else null;
        }
        self.grid = layout.Grid.init(self.width, self.config.icon_size, self.font);
        self.grid.min_rows = @intCast(@max(1, @divTrunc(self.height - 36, self.grid.cell_height)));
        self.slots = layout.arrange(alloc, self.grid, preferred) catch return;
        var rows: usize = 1;
        for (self.slots) |slot| rows = @max(rows, slot / self.grid.columns + 1);
        self.fixed.as(gtk.Widget).setSizeRequest(self.width, @max(self.height - 36, @as(i32, @intCast(rows)) * self.grid.cell_height));
        self.message(if (self.feedback[0] != 0) std.mem.span(@as([*:0]const u8, &self.feedback)) else if (self.store.save_error) "Could not save desktop positions. Changes remain in memory; try arranging again." else if (self.store.state.corrupt) "Saved positions could not be read. Automatic positions are shown; the old file will be kept for recovery." else snapshot.message);
        self.render();
    }
    fn tryPut(map: *std.StringHashMap(void), key_: []const u8) void {
        map.put(key_, {}) catch {};
    }
    pub fn report(self: *View, alloc: std.mem.Allocator, output: []const u8, keyboard_mode: []const u8) ![]const u8 {
        const Row = struct { name: []const u8, selected: bool, slot: usize, x: i32, y: i32 };
        var rows: std.ArrayList(Row) = .empty;
        for (self.indices[0..@min(40, self.indices.len)], 0..) |index, i| {
            const pos = self.grid.position(self.slots[i]);
            try rows.append(alloc, .{ .name = self.store.snapshot.?.items.items[index].name, .selected = self.selection.bits[i], .slot = self.slots[i], .x = self.root.as(gtk.Widget).getMarginStart() + @as(i32, @intCast(pos.column)) * self.grid.cell_width + @divTrunc(self.grid.cell_width, 2), .y = self.root.as(gtk.Widget).getMarginTop() + @as(i32, @intCast(pos.row)) * self.grid.cell_height + @divTrunc(self.grid.cell_height, 2) - @as(i32, @intFromFloat(self.scroll.getVadjustment().getValue())) + (if (self.status.as(gtk.Widget).getVisible() != 0) self.status.as(gtk.Widget).getHeight() else @as(i32, 0)) });
        }
        var buttons: std.ArrayList(MenuButton) = .empty;
        if (self.menu) |menu| try self.menuButtons(alloc, menu.as(gtk.Widget), &buttons);
        return std.json.Stringify.valueAlloc(alloc, .{ .enabled = true, .output = output, .allowed = self.allowed, .keyboard_mode = keyboard_mode, .count = self.indices.len, .widgets = self.cells.items.len, .rows = rows.items, .message = std.mem.span(self.status.getText()), .menu = self.menu != null and self.menu.?.as(gtk.Widget).getVisible() != 0, .buttons = buttons.items, .busy = self.job != null, .width = self.width, .height = self.height, .focus = self.window.isActive() != 0 }, .{});
    }
    const MenuButton = struct { name: []const u8, x: f32, y: f32 };
    fn menuButtons(self: *View, alloc: std.mem.Allocator, widget: *gtk.Widget, list: *std.ArrayList(MenuButton)) !void {
        if (object.ext.cast(gtk.Button, widget)) |button| {
            var rect: @import("graphene1").Rect = undefined;
            if (widget.computeBounds(self.window.as(gtk.Widget), &rect) != 0) try list.append(alloc, .{ .name = std.mem.span(button.getLabel() orelse ""), .x = rect.f_origin.f_x + rect.f_size.f_width / 2, .y = rect.f_origin.f_y + rect.f_size.f_height / 2 });
        }
        var child = widget.getFirstChild();
        while (child) |next_child| : (child = next_child.getNextSibling()) try self.menuButtons(alloc, next_child, list);
    }
    fn message(self: *View, text: [:0]const u8) void {
        self.status.setText(text);
        self.status.as(gtk.Widget).setVisible(@intFromBool(text.len != 0));
    }
    fn clearCells(self: *View) void {
        self.fixed.as(gtk.Accessible).resetRelation(.active_descendant);
        for (self.cells.items) |cell| self.fixed.remove(cell);
        self.cells.clearRetainingCapacity();
        self.cell_indices.clearRetainingCapacity();
    }
    fn render(self: *View) void {
        self.clearCells();
        const snapshot = self.store.snapshot orelse return;
        const top = self.scroll.getVadjustment().getValue();
        const bottom = top + @as(f64, @floatFromInt(self.height + self.grid.cell_height));
        for (self.slots, 0..) |slot, i| {
            const pos = self.grid.position(slot);
            const y: i32 = @as(i32, @intCast(pos.row)) * self.grid.cell_height;
            if (@as(f64, @floatFromInt(y + self.grid.cell_height)) < top or @as(f64, @floatFromInt(y)) > bottom) continue;
            const item = snapshot.items.items[self.indices[i]];
            const cell = gtk.Button.new();
            // The grid has one keyboard stop; arrows update active-descendant.
            // Accessible button activation still targets the matching item.
            cell.as(gtk.Widget).setFocusable(0);
            cell.as(gtk.Widget).addCssClass("pearl-desktop-icon");
            if (self.selection.bits[i]) cell.as(gtk.Widget).addCssClass("pearl-desktop-selected");
            cell.as(gtk.Accessible).updateState(.selected, @as(c_int, @intFromBool(self.selection.bits[i])), @as(c_int, -1));
            if (i == self.selection.focus) cell.as(gtk.Widget).addCssClass("pearl-desktop-cursor");
            cell.as(gtk.Widget).setSizeRequest(self.grid.cell_width - 8, self.grid.cell_height - 8);
            w.name(cell.as(gtk.Widget), item.name);
            cell.as(gtk.Widget).setTooltipText(item.name);
            const box = gtk.Box.new(.vertical, 6);
            const icon = if (item.info.getIcon()) |gicon| gtk.Image.newFromGicon(gicon) else gtk.Image.newFromIconName("text-x-generic");
            icon.setPixelSize(self.config.icon_size);
            box.append(icon.as(gtk.Widget));
            const label = gtk.Label.new(item.name);
            label.setWrap(1);
            label.setWrapMode(.word_char);
            label.setLines(2);
            label.setEllipsize(.end);
            label.setMaxWidthChars(12);
            label.setJustify(.center);
            box.append(label.as(gtk.Widget));
            cell.setChild(box.as(gtk.Widget));
            // Assistive activation follows the focused item's normal open path.
            _ = gtk.Button.signals.clicked.connect(cell, *View, accessibleOpen, self, .{});
            self.fixed.put(cell.as(gtk.Widget), @floatFromInt(@as(i32, @intCast(pos.column)) * self.grid.cell_width), @floatFromInt(y));
            if (i == self.selection.focus) self.fixed.as(gtk.Accessible).updateRelation(.active_descendant, cell.as(gtk.Accessible), @as(c_int, -1));
            self.cells.append(a, cell.as(gtk.Widget)) catch {};
            self.cell_indices.append(a, i) catch {};
        }
    }
    fn accessibleOpen(button: *gtk.Button, self: *View) callconv(.c) void {
        for (self.cells.items, 0..) |cell, visible_index| if (cell == button.as(gtk.Widget)) {
            self.selection.select(self.cell_indices.items[visible_index], false, false);
            self.activate();
            break;
        };
    }
    fn scrolled(_: *gtk.Adjustment, self: *View) callconv(.c) void {
        self.render();
    }
    fn hit(self: *View, x: f64, y: f64) ?usize {
        const slot = self.grid.hit(x, y);
        for (self.slots, 0..) |candidate, i| if (candidate == slot) return i;
        return null;
    }
    fn select(self: *View, index: usize, ctrl: bool, shift: bool) void {
        if (!shift) {
            self.selection.select(index, ctrl, false);
            return;
        }
        const first = self.slots[@min(self.selection.anchor, self.slots.len - 1)];
        const last = self.slots[index];
        if (!ctrl) self.selection.clear();
        for (self.slots, 0..) |slot, i| if (slot >= @min(first, last) and slot <= @max(first, last)) {
            self.selection.bits[i] = true;
        };
        self.selection.focus = index;
    }
    fn pressed(click: *gtk.GestureClick, count: c_int, x: f64, y: f64, self: *View) callconv(.c) void {
        if (!self.allowed) return;
        _ = self.fixed.as(gtk.Widget).grabFocus();
        const state = click.as(gtk.EventController).getCurrentEventState();
        const target = self.hit(x, y);
        const button = click.as(gtk.GestureSingle).getCurrentButton();
        if (button == 3) {
            if (target) |i| if (!self.selection.bits[i]) self.selection.select(i, false, false);
            self.render();
            self.showMenu(target, x, y);
            _ = click.as(gtk.Gesture).setState(.claimed);
            return;
        }
        if (button != 1) return;
        self.closeMenu();
        if (target) |i| {
            self.select(i, state.control_mask, state.shift_mask);
            self.render();
            if (count == 2) self.activate();
        } else {
            if (!state.control_mask) self.selection.clear();
            self.render();
            if (count == 2) self.crop(self.context);
        }
        _ = click.as(gtk.Gesture).setState(.claimed);
    }
    fn key(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, modifiers: gdk.ModifierType, self: *View) callconv(.c) c_int {
        if (!self.allowed) return 0;
        if (keyval == gdk.KEY_Escape) {
            self.closeMenu();
            self.dragging = false;
            self.band.as(gtk.Widget).setVisible(0);
            self.selection.clear();
            self.render();
            return 1;
        }
        if (keyval == gdk.KEY_Menu or (keyval == gdk.KEY_F10 and modifiers.shift_mask)) {
            self.showMenu(if (self.indices.len > 0) self.selection.focus else null, 32, 32);
            return 1;
        }
        if (keyval == gdk.KEY_a and modifiers.control_mask) {
            @memset(self.selection.bits, true);
            self.render();
            return 1;
        }
        if (self.indices.len == 0) return 0;
        if (keyval == gdk.KEY_Return) {
            self.activate();
            return 1;
        }
        if (keyval == gdk.KEY_space) {
            self.selection.select(self.selection.focus, true, false);
            self.render();
            return 1;
        }
        if (keyval == gdk.KEY_Delete) {
            self.enqueueSelected(.trash, "");
            return 1;
        }
        if (keyval == gdk.KEY_F2) {
            self.showMenu(self.selection.focus, 32, 32);
            self.form(.rename);
            return 1;
        }
        const delta: isize = switch (keyval) {
            gdk.KEY_Left => -1,
            gdk.KEY_Right => 1,
            gdk.KEY_Up => -@as(isize, @intCast(self.grid.columns)),
            gdk.KEY_Down => @intCast(self.grid.columns),
            else => return 0,
        };
        const current = self.slots[self.selection.focus];
        const target = @as(isize, @intCast(current)) + delta;
        var next_index = self.selection.focus;
        var distance: usize = std.math.maxInt(usize);
        for (self.slots, 0..) |slot, i| {
            if ((delta < 0 and slot >= current) or (delta > 0 and slot <= current)) continue;
            const d = @abs(@as(isize, @intCast(slot)) - target);
            if (d < distance) {
                next_index = i;
                distance = d;
            }
        }
        self.select(next_index, modifiers.control_mask, modifiers.shift_mask);
        const y = @as(f64, @floatFromInt(self.grid.position(self.slots[next_index]).row)) * @as(f64, @floatFromInt(self.grid.cell_height));
        const adj = self.scroll.getVadjustment();
        if (y < adj.getValue() or y + @as(f64, @floatFromInt(self.grid.cell_height)) > adj.getValue() + adj.getPageSize()) adj.setValue(y);
        self.render();
        return 1;
    }
    fn dragBegin(_: *gtk.GestureDrag, x: f64, y: f64, self: *View) callconv(.c) void {
        if (!self.allowed) return;
        self.dragging = true;
        self.drag_index = self.hit(x, y);
        self.drag_x = x;
        self.drag_y = y;
    }
    fn dragUpdate(_: *gtk.GestureDrag, dx: f64, dy: f64, self: *View) callconv(.c) void {
        if (!self.allowed or !self.dragging or self.drag_index != null or @abs(dx) + @abs(dy) < 8) return;
        const left = @min(self.drag_x, self.drag_x + dx);
        const top = @min(self.drag_y, self.drag_y + dy);
        self.fixed.move(self.band.as(gtk.Widget), left, top);
        self.band.as(gtk.Widget).setSizeRequest(@intFromFloat(@abs(dx)), @intFromFloat(@abs(dy)));
        self.band.as(gtk.Widget).setVisible(1);
        for (self.slots, 0..) |slot, i| {
            const pos = self.grid.position(slot);
            const x: f64 = @floatFromInt(@as(i32, @intCast(pos.column)) * self.grid.cell_width);
            const y: f64 = @floatFromInt(@as(i32, @intCast(pos.row)) * self.grid.cell_height);
            self.selection.bits[i] = x < left + @abs(dx) and x + @as(f64, @floatFromInt(self.grid.cell_width)) > left and y < top + @abs(dy) and y + @as(f64, @floatFromInt(self.grid.cell_height)) > top;
        }
        self.render();
    }
    fn dragEnd(_: *gtk.GestureDrag, dx: f64, dy: f64, self: *View) callconv(.c) void {
        defer {
            self.dragging = false;
            self.band.as(gtk.Widget).setVisible(0);
        }
        if (!self.allowed or !self.dragging or self.config.arrangement != .manual or @abs(dx) + @abs(dy) < 8) return;
        const index = self.drag_index orelse return;
        const dest = self.grid.position(self.grid.hit(self.drag_x + dx, self.drag_y + dy));
        for (self.slots, 0..) |slot, other| if (other != index and slot == self.grid.slot(dest)) {
            self.store.state.place(self.uris[other], self.grid.position(self.slots[index])) catch {};
        };
        self.store.state.place(self.uris[index], dest) catch {
            self.message("Could not store position.");
            return;
        };
        self.store.persist();
        self.update();
    }
    pub fn closeMenu(self: *View) void {
        if (self.menu) |menu| {
            menu.popdown();
            menu.as(gtk.Widget).unparent();
            self.menu = null;
        }
        self.menu_entry = null;
        self.menu_choice = null;
        self.menu_arena.deinit();
        self.menu_arena = .init(a);
    }
    const Command = enum { open, folder, rename, trash, mkdir, shortcut, arrange, settings, retry, approve, submit_rename, submit_mkdir, submit_shortcut };
    const Callback = struct { view: *View, command: Command };
    fn add(self: *View, box: *gtk.Box, title: [:0]const u8, command: Command) void {
        const cb = self.menu_arena.allocator().create(Callback) catch return;
        cb.* = .{ .view = self, .command = command };
        const button = gtk.Button.newWithLabel(title);
        button.as(gtk.Widget).setHalign(.fill);
        box.append(button.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(button, *Callback, clicked, cb, .{});
    }
    fn showMenu(self: *View, target: ?usize, x: f64, y: f64) void {
        self.closeMenu();
        if (!self.allowed) return;
        const menu = gtk.Popover.new();
        self.menu = menu;
        menu.as(gtk.Widget).setParent(self.fixed.as(gtk.Widget));
        menu.setAutohide(1);
        menu.setPointingTo(&.{ .f_x = @intFromFloat(x), .f_y = @intFromFloat(y), .f_width = 1, .f_height = 1 });
        const box = w.column(6);
        box.as(gtk.Widget).setSizeRequest(250, -1);
        menu.setChild(box.as(gtk.Widget));
        if (target) |i| {
            self.selection.focus = i;
            self.add(box, "Open", .open);
            self.add(box, "Rename…", .rename);
            self.add(box, "Move to Trash", .trash);
            const item = self.store.snapshot.?.items.items[self.indices[i]];
            if (item.launcher and item.digest != null) self.add(box, "Allow launching…", .approve);
        } else {
            self.add(box, "New folder…", .mkdir);
            self.add(box, "Add application shortcut…", .shortcut);
            self.add(box, "Arrange by name", .arrange);
            if (self.store.snapshot) |s| if (s.missing) self.add(box, "Create Desktop folder", .submit_mkdir);
        }
        self.add(box, "Open Desktop folder", .folder);
        self.add(box, "Retry", .retry);
        self.add(box, "Desktop settings…", .settings);
        menu.popup();
    }
    fn form(self: *View, command: Command) void {
        const menu = self.menu orelse return;
        const box = w.column(8);
        box.as(gtk.Widget).setSizeRequest(300, -1);
        menu.setChild(box.as(gtk.Widget));
        if (command == .approve) {
            const item = self.store.snapshot.?.items.items[self.indices[self.selection.focus]];
            const title = w.label(item.launch_name, null);
            title.setWrap(1);
            box.append(title.as(gtk.Widget));
            const label = w.label(item.command, null);
            label.setWrap(1);
            label.setMaxWidthChars(40);
            box.append(label.as(gtk.Widget));
            box.append(w.label("Allow this exact launcher to start applications?", null).as(gtk.Widget));
            const button = gtk.Button.newWithLabel("Allow launching");
            box.append(button.as(gtk.Widget));
            _ = gtk.Button.signals.clicked.connect(button, *View, approveClicked, self, .{});
            _ = button.as(gtk.Widget).grabFocus();
        } else if (command == .shortcut) {
            const catalog = self.apps.catalog orelse {
                self.message("Applications are still loading. Retry shortly.");
                return;
            };
            const strings = gtk.StringList.new(null);
            // DropDown.new takes ownership of the model reference.
            var ids: std.ArrayList([:0]const u8) = .empty;
            for (catalog.entries.items) |entry| if (entry.action == null) {
                strings.append(entry.name);
                ids.append(self.menu_arena.allocator(), self.menu_arena.allocator().dupeZ(u8, entry.id) catch continue) catch {};
            };
            self.app_ids = ids.items;
            self.menu_choice = gtk.DropDown.new(strings.as(gio.ListModel), null);
            self.menu_choice.?.setEnableSearch(1);
            box.append(self.menu_choice.?.as(gtk.Widget));
            self.add(box, "Add shortcut", .submit_shortcut);
        } else {
            self.menu_entry = gtk.Entry.new();
            self.menu_entry.?.setMaxLength(255);
            w.name(self.menu_entry.?.as(gtk.Widget), "Name");
            if (command == .rename) self.menu_entry.?.as(gtk.Editable).setText(self.store.snapshot.?.items.items[self.indices[self.selection.focus]].info.getName());
            box.append(self.menu_entry.?.as(gtk.Widget));
            self.add(box, if (command == .rename) "Rename" else "Create folder", if (command == .rename) .submit_rename else .submit_mkdir);
            _ = self.menu_entry.?.as(gtk.Widget).grabFocus();
        }
    }
    fn approveClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.enqueueSelected(.approve, "");
        self.closeMenu();
    }
    fn clicked(_: *gtk.Button, cb: *Callback) callconv(.c) void {
        const self = cb.view;
        const command = cb.command;
        if (!self.allowed) return;
        switch (command) {
            .rename, .mkdir, .shortcut, .approve => {
                self.form(command);
                return;
            },
            .open => {
                self.activate();
                return;
            },
            .trash => self.enqueueSelected(.trash, ""),
            .submit_rename => if (self.menu_entry) |entry| self.enqueueSelected(.rename, std.mem.span(entry.as(gtk.Editable).getText())),
            .submit_mkdir, .submit_shortcut, .folder => {
                const path = if (self.store.snapshot) |s| s.path else null;
                if (path) |p| {
                    const name: []const u8 = if (command == .submit_shortcut) blk: {
                        const index = self.menu_choice.?.getSelected();
                        if (index >= self.app_ids.len) return;
                        break :blk self.app_ids[index];
                    } else if (self.menu_entry) |entry| std.mem.span(entry.as(gtk.Editable).getText()) else "";
                    self.enqueue(.{ .kind = if (command == .folder) .open else if (command == .submit_shortcut) .shortcut else .mkdir, .path = p, .name = name });
                    self.next();
                }
            },
            .arrange => {
                for (self.uris, 0..) |uri, i| self.store.state.place(uri, self.grid.position(i)) catch {};
                self.store.persist();
                self.update();
            },
            .settings => self.settings(self.context),
            .retry => {
                self.feedback[0] = 0;
                self.store.refresh();
            },
        }
        self.closeMenu();
    }
    fn activate(self: *View) void {
        if (!self.allowed or self.indices.len == 0) return;
        const item = self.store.snapshot.?.items.items[self.indices[self.selection.focus]];
        if (item.launcher) {
            const digest = item.digest orelse {
                self.closeMenu();
                self.message("This launcher is invalid or a symbolic link. Open Desktop folder to inspect it.");
                return;
            };
            if (!self.store.state.approved(item.uri, digest)) {
                // Keep the existing popup grab when Open becomes approval.
                // Replacing the popup during its clicked signal can dismiss
                // the new popup as the old grab is released.
                if (self.menu == null) self.showMenu(self.selection.focus, 32, 32);
                self.form(.approve);
                return;
            }
        }
        self.closeMenu();
        self.enqueueItem(self.selection.focus, .open, "");
        self.next();
    }
    fn enqueueSelected(self: *View, kind: actions.Kind, name: []const u8) void {
        if (!self.allowed or self.job != null) return;
        for (self.selection.bits, 0..) |selected, i| if (selected) {
            self.enqueueItem(i, kind, name);
            if (kind == .rename or kind == .approve) break;
        };
        self.next();
    }
    fn enqueueItem(self: *View, index: usize, kind: actions.Kind, name: []const u8) void {
        const item = self.store.snapshot.?.items.items[self.indices[index]];
        self.enqueue(.{ .kind = kind, .path = item.path, .name = name, .etag = if (item.info.getEtag()) |v| std.mem.span(v) else null, .digest = item.digest, .launcher = item.launcher and (kind == .open or kind == .approve) });
    }
    fn enqueue(self: *View, request: actions.Request) void {
        const alloc = self.queue_arena.allocator();
        var copy = request;
        copy.path = alloc.dupeZ(u8, request.path) catch return;
        copy.name = alloc.dupeZ(u8, request.name) catch return;
        copy.etag = if (request.etag) |v| alloc.dupeZ(u8, v) catch return else null;
        self.queue.append(a, copy) catch {};
    }
    fn next(self: *View) void {
        if (!self.allowed or self.job != null or self.queue.items.len == 0) return;
        if (self.failures == 0 and self.successes == 0) self.feedback[0] = 0;
        const request = self.queue.orderedRemove(0);
        self.job = actions.Job.start(self.store.app, self.window.as(gtk.Widget).getDisplay(), request, self, finished) catch {
            self.message("Could not start file operation.");
            return;
        };
    }
    fn finished(context: *anyopaque, job: *actions.Job) void {
        const self: *View = @ptrCast(@alignCast(context));
        self.job = null;
        if (job.failure) |err| {
            self.failures += 1;
            self.message(std.fmt.bufPrintZ(&self.feedback, "Desktop action failed: {s}. Retry after checking the file.", .{@errorName(err)}) catch "Desktop action failed.");
        } else {
            self.successes += 1;
            if ((job.request.kind == .approve or job.request.kind == .shortcut) and job.digest != null and job.uri != null) {
                self.store.state.approve(job.uri.?, job.digest.?) catch {};
                self.store.persist();
            }
        }
        if (self.queue.items.len > 0) self.next() else {
            self.queue_arena.deinit();
            self.queue_arena = .init(a);
            if (self.failures > 0 and self.successes > 0) self.message("Some desktop actions succeeded; others failed. Check the Desktop folder before retrying.");
            self.failures = 0;
            self.successes = 0;
            self.store.schedule();
        }
    }
};
