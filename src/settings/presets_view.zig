//! Shipped bar and dock layouts. Choosing a preset rewrites only the bar and
//! dock settings it owns in the shared draft; the footer still decides when the
//! desktop changes.
const std = @import("std");
const gtk = @import("gtk4");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const prefs = @import("../config/preferences.zig");
const presets = @import("../config/bar_dock_presets.zig");
const i18n = @import("i18n");
const Editor = @import("editor.zig").Editor;
const a = std.heap.c_allocator;

pub const Control = struct { id: []const u8, widget: *gtk.Widget };
const Binding = struct { view: *View, index: usize };
const Tile = struct { id: []const u8, button: *gtk.CheckButton, signal: c_ulong };

pub const View = struct {
    editor: *Editor,
    root: *gtk.Box,
    status: *gtk.Label,
    tiles: []Tile,
    bindings: []Binding,
    controls: std.ArrayList(Control) = .empty,
    arena: std.heap.ArenaAllocator = .init(a),
    filling: bool = false,
    editing: bool = false,

    pub fn create(host: *gtk.Box, editor: *Editor) !*View {
        const self = try a.create(View);
        errdefer a.destroy(self);
        self.* = .{ .editor = editor, .root = undefined, .status = undefined, .tiles = &.{}, .bindings = &.{} };
        const alloc = self.arena.allocator();
        const root = w.column(10);
        root.as(gtk.Widget).addCssClass("settings-card");
        root.as(gtk.Widget).addCssClass("bar-presets");
        host.append(root.as(gtk.Widget));
        self.root = root;
        root.append(w.label(i18n.dtr("pearl", "Layout presets"), "settings-row-title").as(gtk.Widget));
        const hint = w.label(i18n.dtr("pearl", "Start from a shipped layout. A preset changes bar and dock settings and their widgets only: your other preferences, per-display overrides, pinned applications and widget data such as the weather location stay as they are."), "pearl-secondary");
        hint.setWrap(1);
        hint.as(gtk.Widget).setHexpand(1);
        hint.as(gtk.Widget).setHalign(.fill);
        root.append(hint.as(gtk.Widget));
        const catalog = try presets.catalog(alloc);
        const flow = w.flow(4);
        flow.setHomogeneous(1);
        flow.as(gtk.Widget).addCssClass("appearance-modes");
        root.append(flow.as(gtk.Widget));
        self.tiles = try alloc.alloc(Tile, catalog.len);
        self.bindings = try alloc.alloc(Binding, catalog.len);
        for (catalog, 0..) |preset, i| {
            const button = gtk.CheckButton.new();
            if (i > 0) button.setGroup(self.tiles[0].button);
            button.as(gtk.Widget).addCssClass("appearance-mode");
            const labels = w.column(3);
            labels.as(gtk.Widget).setValign(.center);
            const name = try alloc.dupeSentinel(u8, preset.name, 0);
            labels.append(w.label(i18n.dtr("pearl", name), "settings-row-title").as(gtk.Widget));
            const summary = w.label(try alloc.dupeSentinel(u8, try presets.summary(alloc, preset), 0), "pearl-secondary");
            labels.append(summary.as(gtk.Widget));
            button.setChild(labels.as(gtk.Widget));
            // The longer description lives in the tooltip so the tile stays as
            // compact as the Appearance cards and its content fills it.
            button.as(gtk.Widget).setTooltipText(try alloc.dupeSentinel(u8, preset.description, 0));
            w.name(button.as(gtk.Widget), name);
            flow.insert(button.as(gtk.Widget), -1);
            self.bindings[i] = .{ .view = self, .index = i };
            self.tiles[i] = .{ .id = try alloc.dupe(u8, preset.id), .button = button, .signal = 0 };
            self.tiles[i].signal = gtk.CheckButton.signals.toggled.connect(button, *Binding, chosen, &self.bindings[i], .{});
            try self.controls.append(a, .{ .id = try std.fmt.allocPrint(alloc, "bar.preset.{s}", .{preset.id}), .widget = button.as(gtk.Widget) });
        }
        self.status = w.label("", "pearl-secondary");
        root.append(self.status.as(gtk.Widget));
        try self.controls.append(a, .{ .id = "bar.preset.status", .widget = self.status.as(gtk.Widget) });
        self.update();
        return self;
    }

    pub fn destroy(self: *View) void {
        for (self.tiles) |tile| object.signalHandlerDisconnect(tile.button.as(object.Object), tile.signal);
        self.controls.deinit(a);
        self.arena.deinit();
        a.destroy(self);
    }

    pub fn update(self: *View) void {
        if (self.editing) return;
        self.filling = true;
        defer self.filling = false;
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const alloc = temp.allocator();
        const document = prefs.parse(alloc, self.editor.text()) catch {
            self.root.as(gtk.Widget).setSensitive(0);
            return;
        };
        self.root.as(gtk.Widget).setSensitive(@intFromBool(self.editor.editable()));
        // A recorded id that is no longer shipped reads as a custom layout.
        const preset = if (document.bar_dock_preset.len == 0) null else presets.find(alloc, document.bar_dock_preset) catch null;
        for (self.tiles) |tile| tile.button.setActive(@intFromBool(preset != null and std.mem.eql(u8, tile.id, preset.?.id)));
        self.status.setText(statusText(alloc, preset) catch i18n.dtr("pearl", "Custom layout"));
    }

    fn statusText(alloc: std.mem.Allocator, preset: ?presets.Preset) ![:0]const u8 {
        const found = preset orelse return i18n.dtr("pearl", "Custom layout · choose a preset to start from one");
        return alloc.dupeSentinel(u8, try std.fmt.allocPrint(alloc, "{s} layout · {s}", .{ found.name, try presets.summary(alloc, found) }), 0);
    }

    fn chosen(_: *gtk.CheckButton, binding: *Binding) callconv(.c) void {
        const self = binding.view;
        const tile = &self.tiles[binding.index];
        // A radio group also reports the tile that was left; only the chosen one
        // applies, and a redraw from the draft never re-applies anything.
        if (self.filling or self.editing or !self.editor.editable() or tile.button.getActive() == 0) return;
        self.editing = true;
        defer {
            self.editing = false;
            self.update();
        }
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const text = presets.apply(arena.allocator(), self.editor.text(), tile.id) catch |err| {
            self.editor.error_code.set(@errorName(err));
            return;
        };
        self.editor.edit(text) catch |err| self.editor.error_code.set(@errorName(err));
    }
};
