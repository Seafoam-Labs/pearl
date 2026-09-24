//! Global task strip and a separate keyboard-capable chooser surface.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const pixbuf = @import("gdkpixbuf2");
const tasks = @import("task_model.zig");
const Apps = @import("apps.zig");
const Client = @import("../aqueous/client.zig").Client;
const w = @import("../ui/components/widgets.zig");
const tr = @import("text.zig").tr;
const a = std.heap.c_allocator;
fn localized(alloc: std.mem.Allocator, comptime en: [:0]const u8, comptime de: [:0]const u8, args: anytype) ![:0]u8 {
    return if (std.mem.eql(u8, tr(en, de), de)) std.fmt.allocPrintSentinel(alloc, de, args, 0) else std.fmt.allocPrintSentinel(alloc, en, args, 0);
}
fn windowWord(count: usize) [:0]const u8 {
    return if (count == 1) tr("window", "Fenster") else tr("windows", "Fenster");
}
pub const Event = union(enum) { activate: []const u8, group: []const u8, overflow: usize };
pub const Rect = struct { x: f64, y: f64, width: i32, height: i32 };
pub const ProbeRow = struct { id: []const u8, kind: []const u8, rect: Rect, enabled: bool, focused: bool };
fn rect(widget: *gtk.Widget, root: *gtk.Widget) Rect {
    var x: f64 = 0;
    var y: f64 = 0;
    _ = widget.translateCoordinates(root, 0, 0, &x, &y);
    return .{ .x = x, .y = y, .width = widget.getWidth(), .height = widget.getHeight() };
}
pub const Dispatch = *const fn (*anyopaque, Event) void;
fn appIcon(index: *Apps.Index, desktop: ?[]const u8, host: *gtk.Widget) *gtk.Image {
    if (desktop) |id| if (index.catalog) |catalog| for (catalog.entries.items) |entry| {
        if (entry.action == null and std.mem.eql(u8, id, entry.id)) if (entry.info.getIcon()) |icon| {
            if (gtk.IconTheme.getForDisplay(host.getDisplay()).hasGicon(icon) != 0) {
                const image = gtk.Image.newFromGicon(icon);
                image.setPixelSize(20);
                return image;
            }
        };
    };
    const image = w.icon("pearl-application-x-executable-symbolic");
    image.setPixelSize(20);
    return image;
}
const StripButton = struct { owner: *Strip, key: [:0]const u8, window: ?[:0]const u8 = null, activate: bool = false, skip: ?usize = null };
const StripRow = struct { id: []const u8, kind: []const u8 };
pub const Strip = struct {
    host: *gtk.Box,
    snapshot: *const tasks.Snapshot,
    index: *Apps.Index,
    client: *Client,
    context: *anyopaque,
    dispatch: Dispatch,
    arena: std.heap.ArenaAllocator = .init(a),
    revision: u64 = std.math.maxInt(u64),
    slots: usize = 1,
    built_slots: usize = 0,
    digest: ?u64 = null,
    shown: usize = 0,
    rows: []const StripRow = &.{},
    vertical: bool,
    compact: bool = false,
    built_compact: bool = false,
    per_window: bool = false,
    built_per_window: bool = false,
    pub fn create(host: *gtk.Box, snapshot: *const tasks.Snapshot, index: *Apps.Index, client: *Client, vertical: bool, per_window: bool, context: *anyopaque, dispatch: Dispatch) !*Strip {
        const self = try a.create(Strip);
        self.* = .{ .host = host, .snapshot = snapshot, .index = index, .client = client, .vertical = vertical, .per_window = per_window, .context = context, .dispatch = dispatch };
        host.setSpacing(2);
        host.as(gtk.Widget).addCssClass("pearl-running-apps");
        return self;
    }
    pub fn destroy(self: *Strip) void {
        self.clear();
        self.arena.deinit();
        a.destroy(self);
    }
    fn clear(self: *Strip) void {
        while (self.host.as(gtk.Widget).getFirstChild()) |child| self.host.remove(child);
        _ = self.arena.reset(.free_all);
        self.rows = &.{};
    }
    /// Cached window pixels; a null result queues the fetch or falls back to the app icon.
    fn windowPixels(self: *Strip, id: []const u8) ?*pixbuf.Pixbuf {
        const win = self.client.model.get(.window, id) orelse return null;
        const icon = win.icon orelse return null;
        if (!icon.has_pixels) return null;
        return self.client.icon(.{ .id = id, .revision = icon.revision, .size = if (self.compact) 16 else 20, .scale = 1 }) catch null;
    }
    pub fn update(self: *Strip) !void {
        const settled = self.revision == self.snapshot.revision and self.built_slots == self.slots and self.built_compact == self.compact and self.built_per_window == self.per_window;
        // Per-window mode rehashes even when settled: icon pixels arrive without a revision bump.
        if (settled and !self.per_window) return;
        const groups = self.snapshot.groups;
        var hash = std.hash.Wyhash.init(self.index.generation);
        hash.update(std.mem.asBytes(&self.slots));
        hash.update(&.{@intFromBool(self.compact)});
        if (self.per_window) {
            hash.update(&.{1});
            for (groups) |group| {
                hash.update(group.key);
                for (group.windows.items) |win| {
                    hash.update(win.id);
                    hash.update(win.title);
                    hash.update(&.{ @intFromBool(win.focused), @intFromBool(win.minimized), @intFromBool(win.can_activate), @intFromBool(self.windowPixels(win.id) != null) });
                }
            }
        } else {
            for (groups) |group| {
                hash.update(group.key);
                hash.update(group.name);
                hash.update(std.mem.asBytes(&group.windows.items.len));
                hash.update(&.{ @intFromBool(group.focused()), @intFromBool(group.minimized()) });
            }
        }
        const digest = hash.final();
        if (self.digest != null and self.digest.? == digest) {
            self.revision = self.snapshot.revision;
            self.built_slots = self.slots;
            self.built_compact = self.compact;
            self.built_per_window = self.per_window;
            return;
        }
        self.clear();
        const alloc = self.arena.allocator();
        var total: usize = 0;
        if (self.per_window) {
            for (groups) |group| total += group.windows.items.len;
        } else total = groups.len;
        self.shown = tasks.visibleCount(total, self.slots);
        self.host.as(gtk.Widget).setVisible(@intFromBool(total > 0));
        var rows: std.ArrayList(StripRow) = .empty;
        var hidden_group: ?usize = null;
        var placed: usize = 0;
        for (groups, 0..) |group, group_index| {
            if (self.per_window) {
                for (group.windows.items) |win| {
                    if (placed >= self.shown) {
                        if (hidden_group == null) hidden_group = group_index;
                        continue;
                    }
                    placed += 1;
                    try rows.append(alloc, .{ .id = win.id, .kind = "window" });
                    const callback = try alloc.create(StripButton);
                    callback.* = .{ .owner = self, .key = try alloc.dupeZ(u8, group.key), .window = try alloc.dupeZ(u8, win.id), .activate = win.can_activate };
                    const button = gtk.Button.new();
                    button.as(gtk.Widget).addCssClass("pearl-task-button");
                    if (win.focused) button.as(gtk.Widget).addCssClass("suggested-action");
                    const image = if (self.windowPixels(win.id)) |pixels| blk: {
                        const widget = gtk.Image.new();
                        widget.setFromPixbuf(pixels);
                        break :blk widget;
                    } else appIcon(self.index, group.desktop, self.host.as(gtk.Widget));
                    image.setPixelSize(if (self.compact) 16 else 20);
                    const marker = if (win.focused) "●" else if (win.minimized) "◦" else "•";
                    const indicator = gtk.Label.new(marker);
                    indicator.as(gtk.Widget).addCssClass("pearl-task-count");
                    try self.pack(button, image, indicator);
                    const name = try localized(alloc, "{s} — 1 {s}, all workspaces{s}{s}", "{s} — 1 {s}, alle Arbeitsflächen{s}{s}", .{ win.title, windowWord(1), if (win.focused) tr(", focused", ", fokussiert") else "", if (win.minimized) tr(", minimized", ", minimiert") else "" });
                    w.name(button.as(gtk.Widget), name);
                    button.as(gtk.Widget).setTooltipText(name);
                    _ = gtk.Button.signals.clicked.connect(button, *StripButton, clicked, callback, .{});
                    const secondary = gtk.GestureClick.new();
                    secondary.as(gtk.GestureSingle).setButton(3);
                    _ = gtk.GestureClick.signals.pressed.connect(secondary, *StripButton, menu, callback, .{});
                    button.as(gtk.Widget).addController(secondary.as(gtk.EventController));
                    self.host.append(button.as(gtk.Widget));
                }
            } else {
                if (placed >= self.shown) {
                    if (hidden_group == null) hidden_group = group_index;
                    continue;
                }
                placed += 1;
                try rows.append(alloc, .{ .id = group.key, .kind = "group" });
                const callback = try alloc.create(StripButton);
                callback.* = .{ .owner = self, .key = try alloc.dupeZ(u8, group.key) };
                const button = gtk.Button.new();
                button.as(gtk.Widget).addCssClass("pearl-task-button");
                if (group.focused()) button.as(gtk.Widget).addCssClass("suggested-action");
                const image = appIcon(self.index, group.desktop, self.host.as(gtk.Widget));
                if (self.compact) image.setPixelSize(16);
                const marker = if (group.focused()) "●" else if (group.minimized()) "◦" else "•";
                const count = if (group.windows.items.len > 1) try std.fmt.allocPrintSentinel(alloc, "{s} {d}", .{ marker, group.windows.items.len }, 0) else marker;
                const indicator = gtk.Label.new(count);
                indicator.as(gtk.Widget).addCssClass("pearl-task-count");
                try self.pack(button, image, indicator);
                const name = try localized(alloc, "{s} — {d} {s}, all workspaces{s}{s}", "{s} — {d} {s}, alle Arbeitsflächen{s}{s}", .{ group.name, group.windows.items.len, windowWord(group.windows.items.len), if (group.focused()) tr(", focused", ", fokussiert") else "", if (group.minimized()) tr(", minimized", ", minimiert") else "" });
                w.name(button.as(gtk.Widget), name);
                button.as(gtk.Widget).setTooltipText(name);
                _ = gtk.Button.signals.clicked.connect(button, *StripButton, clicked, callback, .{});
                const secondary = gtk.GestureClick.new();
                secondary.as(gtk.GestureSingle).setButton(3);
                _ = gtk.GestureClick.signals.pressed.connect(secondary, *StripButton, menu, callback, .{});
                button.as(gtk.Widget).addController(secondary.as(gtk.EventController));
                self.host.append(button.as(gtk.Widget));
            }
        }
        if (placed < total) {
            const callback = try alloc.create(StripButton);
            callback.* = .{ .owner = self, .key = "", .skip = hidden_group orelse groups.len };
            try rows.append(alloc, .{ .id = "", .kind = "overflow" });
            const hidden = total - placed;
            const label = try std.fmt.allocPrintSentinel(alloc, "+{d}", .{hidden}, 0);
            const button = gtk.Button.newWithLabel(label);
            if (self.compact) button.as(gtk.Widget).addCssClass("pearl-task-compact");
            button.as(gtk.Widget).addCssClass("pearl-task-button");
            const name = if (placed == 0) try localized(alloc, "Running applications ({d})", "Laufende Anwendungen ({d})", .{hidden}) else if (self.per_window) try localized(alloc, "{d} more windows", "{d} weitere Fenster", .{hidden}) else try localized(alloc, "{d} more applications", "{d} weitere Anwendungen", .{hidden});
            w.name(button.as(gtk.Widget), name);
            button.as(gtk.Widget).setTooltipText(name);
            _ = gtk.Button.signals.clicked.connect(button, *StripButton, clicked, callback, .{});
            self.host.append(button.as(gtk.Widget));
        }
        self.rows = try rows.toOwnedSlice(alloc);
        self.revision = self.snapshot.revision;
        self.built_slots = self.slots;
        self.built_compact = self.compact;
        self.built_per_window = self.per_window;
        self.digest = digest;
    }
    fn pack(self: *Strip, button: *gtk.Button, image: *gtk.Image, indicator: *gtk.Label) !void {
        if (self.compact) {
            button.as(gtk.Widget).addCssClass("pearl-task-compact");
            const overlay = gtk.Overlay.new();
            overlay.setChild(image.as(gtk.Widget));
            indicator.as(gtk.Widget).setHalign(.end);
            indicator.as(gtk.Widget).setValign(.end);
            indicator.as(gtk.Widget).addCssClass("pearl-task-badge");
            overlay.addOverlay(indicator.as(gtk.Widget));
            button.setChild(overlay.as(gtk.Widget));
        } else {
            const content = gtk.Box.new(.vertical, 0);
            content.append(image.as(gtk.Widget));
            content.append(indicator.as(gtk.Widget));
            button.setChild(content.as(gtk.Widget));
        }
    }
    pub fn report(self: *Strip, alloc: std.mem.Allocator, root: *gtk.Widget) ![]const ProbeRow {
        var result: std.ArrayList(ProbeRow) = .empty;
        var child = self.host.as(gtk.Widget).getFirstChild();
        var i: usize = 0;
        while (child) |widget| : ({
            child = widget.getNextSibling();
            i += 1;
        }) {
            const row = if (i < self.rows.len) self.rows[i] else StripRow{ .id = "", .kind = "overflow" };
            try result.append(alloc, .{ .id = row.id, .kind = row.kind, .rect = rect(widget, root), .enabled = widget.getSensitive() != 0, .focused = widget.hasFocus() != 0 });
        }
        return result.toOwnedSlice(alloc);
    }
    fn clicked(_: *gtk.Button, cb: *StripButton) callconv(.c) void {
        const self = cb.owner;
        if (cb.skip) |skip| {
            self.dispatch(self.context, .{ .overflow = skip });
            return;
        }
        if (cb.window) |id| {
            if (cb.activate) self.dispatch(self.context, .{ .activate = id }) else self.dispatch(self.context, .{ .group = cb.key });
            return;
        }
        const group = self.snapshot.find(cb.key) orelse return;
        if (group.windows.items.len == 1 and group.windows.items[0].can_activate) self.dispatch(self.context, .{ .activate = group.windows.items[0].id }) else self.dispatch(self.context, .{ .group = group.key });
    }
    fn menu(gesture: *gtk.GestureClick, _: c_int, _: f64, _: f64, cb: *StripButton) callconv(.c) void {
        _ = gesture.as(gtk.Gesture).setState(.claimed);
        cb.owner.dispatch(cb.owner.context, .{ .group = cb.key });
    }
};
const Row = struct { owner: *Chooser, button: *gtk.Button, id: [:0]const u8, kind: enum { window, group, back, more } };
pub const Chooser = struct {
    host: *gtk.Box,
    snapshot: *const tasks.Snapshot,
    index: *Apps.Index,
    context: *anyopaque,
    dispatch: Dispatch,
    title: *gtk.Label,
    subtitle: *gtk.Label,
    list: *gtk.Box,
    scroll: *gtk.ScrolledWindow,
    arena: std.heap.ArenaAllocator = .init(a),
    rows: std.ArrayList(*Row) = .empty,
    group: ?[:0]u8 = null,
    group_anchor: ?[]u8 = null,
    skip: usize = 0,
    limit: usize = 50,
    revision: u64 = std.math.maxInt(u64),
    pub fn create(host: *gtk.Box, snapshot: *const tasks.Snapshot, index: *Apps.Index, context: *anyopaque, dispatch: Dispatch) !*Chooser {
        const self = try a.create(Chooser);
        const title = gtk.Label.new(tr("Running applications", "Laufende Anwendungen"));
        title.setXalign(0);
        title.setEllipsize(.end);
        title.as(gtk.Widget).addCssClass("title-2");
        host.append(title.as(gtk.Widget));
        const subtitle = gtk.Label.new(tr("All workspaces · All displays", "Alle Arbeitsflächen · Alle Bildschirme"));
        subtitle.setXalign(0);
        subtitle.setWrap(1);
        subtitle.as(gtk.Widget).addCssClass("pearl-secondary");
        host.append(subtitle.as(gtk.Widget));
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        scroll.setMinContentHeight(0);
        const list = gtk.Box.new(.vertical, 5);
        scroll.setChild(list.as(gtk.Widget));
        host.append(scroll.as(gtk.Widget));
        self.* = .{ .host = host, .snapshot = snapshot, .index = index, .context = context, .dispatch = dispatch, .title = title, .subtitle = subtitle, .list = list, .scroll = scroll };
        const keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Chooser, key, self, .{});
        host.as(gtk.Widget).addController(keys.as(gtk.EventController));
        errdefer self.destroy();
        try self.update();
        return self;
    }
    pub fn destroy(self: *Chooser) void {
        self.clear();
        self.arena.deinit();
        if (self.group) |v| a.free(v);
        if (self.group_anchor) |v| a.free(v);
        a.destroy(self);
    }
    fn clear(self: *Chooser) void {
        while (self.list.as(gtk.Widget).getFirstChild()) |child| self.list.remove(child);
        _ = self.arena.reset(.free_all);
        self.rows = .empty;
    }
    pub fn select(self: *Chooser, group: ?[]const u8, skip: usize) !void {
        const owned = if (group) |v| try a.dupeZ(u8, v) else null;
        if (self.group) |v| a.free(v);
        self.group = owned;
        if (self.group_anchor) |v| a.free(v);
        self.group_anchor = null;
        self.skip = skip;
        self.limit = 50;
        self.revision = std.math.maxInt(u64);
        try self.update();
        self.focus();
    }
    pub fn focus(self: *Chooser) void {
        for (self.rows.items) |row| if (row.button.as(gtk.Widget).getSensitive() != 0) {
            _ = row.button.as(gtk.Widget).grabFocus();
            break;
        };
    }
    pub fn update(self: *Chooser) !void {
        if (self.revision == self.snapshot.revision) return;
        var focused: ?[]u8 = null;
        var focus_index: ?usize = null;
        for (self.rows.items, 0..) |row, i| if (row.button.as(gtk.Widget).hasFocus() != 0) {
            focused = try a.dupe(u8, row.id);
            focus_index = i;
            break;
        };
        defer if (focused) |id| a.free(id);
        const offset = self.scroll.getVadjustment().getValue();
        // Catalog reclassification follows the selected opaque window, when possible.
        if (self.group != null and self.snapshot.find(self.group.?) == null) outer: for (self.snapshot.groups) |group| {
            for (group.windows.items) |win| if ((focused != null and std.mem.eql(u8, win.id, focused.?)) or (self.group_anchor != null and std.mem.eql(u8, win.id, self.group_anchor.?))) {
                const owned = try a.dupeZ(u8, group.key);
                a.free(self.group.?);
                self.group = owned;
                break :outer;
            };
        };
        self.clear();
        const alloc = self.arena.allocator();
        if (self.group) |id| {
            _ = try self.addRow(.back, "", tr("All applications", "Alle Anwendungen"), tr("Back to the application list", "Zurück zur Anwendungsliste"), null, true);
            if (self.snapshot.find(id)) |group| {
                const anchor = try a.dupe(u8, group.windows.items[0].id);
                if (self.group_anchor) |v| a.free(v);
                self.group_anchor = anchor;
                self.title.setText(group.name);
                self.subtitle.setText(try localized(alloc, "{d} {s} · All workspaces & displays", "{d} {s} · Alle Arbeitsflächen und Bildschirme", .{ group.windows.items.len, windowWord(group.windows.items.len) }));
                for (group.windows.items[0..@min(self.limit, group.windows.items.len)]) |win| {
                    const workspace = if (win.workspace) |name| try localized(alloc, "Workspace {s}", "Arbeitsfläche {s}", .{name}) else tr("Workspace unavailable", "Arbeitsfläche nicht verfügbar");
                    const detail = try std.fmt.allocPrintSentinel(alloc, "{s} · {s}{s}{s}", .{ workspace, win.output orelse tr("Display unavailable", "Bildschirm nicht verfügbar"), if (win.focused) tr(" · Focused", " · Fokussiert") else if (win.minimized) tr(" · Minimized", " · Minimiert") else "", if (!win.can_activate) tr(" · Activation unavailable", " · Aktivierung nicht verfügbar") else "" }, 0);
                    const row = try self.addRow(.window, win.id, win.title, detail, group.desktop, win.can_activate);
                    if (win.focused) row.as(gtk.Widget).addCssClass("suggested-action");
                }
                if (group.windows.items.len > self.limit) try self.more(group.windows.items.len - self.limit);
            } else {
                self.title.setText(tr("Application closed", "Anwendung geschlossen"));
                self.subtitle.setText(tr("No windows remain. Choose another application.", "Keine Fenster mehr geöffnet. Wähle eine andere Anwendung."));
            }
        } else {
            self.title.setText(if (self.skip == 0) tr("Running applications", "Laufende Anwendungen") else tr("More applications", "Weitere Anwendungen"));
            const groups = self.snapshot.groups[@min(self.skip, self.snapshot.groups.len)..];
            self.subtitle.setText(try localized(alloc, "{d} {s} · All workspaces & displays", "{d} {s} · Alle Arbeitsflächen und Bildschirme", .{ groups.len, if (groups.len == 1) tr("application", "Anwendung") else tr("applications", "Anwendungen") }));
            if (self.skip != 0) _ = try self.addRow(.back, "", tr("All applications", "Alle Anwendungen"), tr("Show the complete list", "Vollständige Liste anzeigen"), null, true);
            for (groups[0..@min(self.limit, groups.len)]) |group| {
                const detail = try localized(alloc, "{d} {s}{s}{s}", "{d} {s}{s}{s}", .{ group.windows.items.len, windowWord(group.windows.items.len), if (group.focused()) tr(" · Focused", " · Fokussiert") else "", if (group.minimized()) tr(" · Minimized", " · Minimiert") else "" });
                _ = try self.addRow(.group, group.key, group.name, detail, group.desktop, true);
            }
            if (groups.len > self.limit) try self.more(groups.len - self.limit);
            if (groups.len == 0) self.list.append(w.label(tr("No open applications", "Keine geöffneten Anwendungen"), "pearl-secondary").as(gtk.Widget));
        }
        if (focus_index) |i| {
            var target: ?*Row = null;
            for (self.rows.items) |row| if (std.mem.eql(u8, row.id, focused.?) and row.button.as(gtk.Widget).getSensitive() != 0) {
                target = row;
                break;
            };
            if (target == null and self.rows.items.len > 0) target = self.rows.items[@min(i, self.rows.items.len - 1)];
            if (target) |row| if (row.button.as(gtk.Widget).grabFocus() == 0) self.focus();
        }
        self.scroll.getVadjustment().setValue(offset);
        self.revision = self.snapshot.revision;
    }
    pub fn report(self: *Chooser, alloc: std.mem.Allocator, root: *gtk.Widget) ![]const ProbeRow {
        var result: std.ArrayList(ProbeRow) = .empty;
        for (self.rows.items) |row| try result.append(alloc, .{ .id = row.id, .kind = @tagName(row.kind), .rect = rect(row.button.as(gtk.Widget), root), .enabled = row.button.as(gtk.Widget).getSensitive() != 0, .focused = row.button.as(gtk.Widget).hasFocus() != 0 });
        return result.toOwnedSlice(alloc);
    }
    fn more(self: *Chooser, remaining: usize) !void {
        const text = try localized(self.arena.allocator(), "Show more ({d} remaining)", "Mehr anzeigen ({d} verbleibend)", .{remaining});
        _ = try self.addRow(.more, "more", text, tr("Load the next 50 items", "Nächste 50 Einträge laden"), null, true);
    }
    fn addRow(self: *Chooser, kind: @FieldType(Row, "kind"), id: []const u8, title: [:0]const u8, detail: [:0]const u8, desktop: ?[]const u8, enabled: bool) !*gtk.Button {
        const alloc = self.arena.allocator();
        const cb = try alloc.create(Row);
        const button = gtk.Button.new();
        cb.* = .{ .owner = self, .button = button, .id = try alloc.dupeZ(u8, id), .kind = kind };
        try self.rows.append(alloc, cb);
        const box = gtk.Box.new(.horizontal, 12);
        box.append(appIcon(self.index, desktop, self.host.as(gtk.Widget)).as(gtk.Widget));
        const labels = gtk.Box.new(.vertical, 3);
        labels.as(gtk.Widget).setHexpand(1);
        for ([_][:0]const u8{ title, detail }, 0..) |text, i| {
            const label = gtk.Label.new(text);
            label.setXalign(0);
            label.setEllipsize(.end);
            label.setMaxWidthChars(38);
            if (i == 1) label.as(gtk.Widget).addCssClass("pearl-secondary");
            labels.append(label.as(gtk.Widget));
        }
        box.append(labels.as(gtk.Widget));
        button.setChild(box.as(gtk.Widget));
        const name = try std.fmt.allocPrintSentinel(alloc, "{s} — {s}", .{ title, detail }, 0);
        w.name(button.as(gtk.Widget), name);
        button.as(gtk.Widget).setTooltipText(name);
        button.as(gtk.Widget).setSensitive(@intFromBool(enabled));
        _ = gtk.Button.signals.clicked.connect(button, *Row, clicked, cb, .{});
        self.list.append(button.as(gtk.Widget));
        return button;
    }
    fn clicked(_: *gtk.Button, cb: *Row) callconv(.c) void {
        const self = cb.owner;
        switch (cb.kind) {
            .window => self.dispatch(self.context, .{ .activate = cb.id }),
            .group => self.select(cb.id, self.skip) catch {},
            .back => self.select(null, 0) catch {},
            .more => {
                const previous = self.limit;
                self.limit +|= 50;
                self.revision = std.math.maxInt(u64);
                self.update() catch {};
                if (self.rows.items.len > previous) _ = self.rows.items[@min(previous, self.rows.items.len - 1)].button.as(gtk.Widget).grabFocus();
            },
        }
    }
    fn key(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, self: *Chooser) callconv(.c) c_int {
        if (keyval != gdk.KEY_Down and keyval != gdk.KEY_Up) return 0;
        if (self.rows.items.len == 0) return 0;
        var current: usize = 0;
        for (self.rows.items, 0..) |row, i| if (row.button.as(gtk.Widget).hasFocus() != 0) {
            current = i;
            break;
        };
        for (0..self.rows.items.len) |_| {
            current = if (keyval == gdk.KEY_Down) (current + 1) % self.rows.items.len else (current + self.rows.items.len - 1) % self.rows.items.len;
            if (self.rows.items[current].button.as(gtk.Widget).grabFocus() != 0) return 1;
        }
        return 1;
    }
};
