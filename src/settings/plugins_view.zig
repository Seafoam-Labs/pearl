//! Plugin management belongs exclusively to the full Settings application.
const std = @import("std");
const gtk = @import("gtk4");
const object = @import("gobject2");
const ui = @import("live_protocol.zig");
const m = @import("../plugins/model.zig");
const prefs = @import("../config/preferences.zig");
const Editor = @import("editor.zig").Editor;
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;
const Action = enum { approve, retry, preview, bar, reset };
const Row = struct {
    view: *View,
    info: ui.PluginInfo,
    status: *gtk.Label,
    enabled: *gtk.Switch,
    activity: *gtk.Switch,
    overlay: *gtk.Switch,
    mode: *gtk.DropDown,
    output: *gtk.Entry,
    x: *gtk.SpinButton,
    y: *gtk.SpinButton,
    width: *gtk.SpinButton,
    height: *gtk.SpinButton,
    interactive: *gtk.Switch,
    locked: *gtk.Switch,
    fullscreen: *gtk.Switch,
    values: []*gtk.Widget,
};
const Button = struct { row: *Row, action: Action };
pub const View = struct {
    context: *anyopaque,
    invalidate: *const fn (*anyopaque, @import("../desktop/settings_navigation.zig").Route) void,
    host: *gtk.Box,
    editor: *Editor,
    summary: *gtk.Label,
    content: *gtk.Box,
    arena: std.heap.ArenaAllocator,
    rows: std.ArrayList(*Row) = .empty,
    signals: std.ArrayList(struct { value: *object.Object, id: c_ulong }) = .empty,
    key: ?[]u8 = null,
    filling: bool = false,
    editing: bool = false,
    next: *gtk.Button,
    previous: *gtk.Button,
    next_signal: c_ulong = 0,
    previous_signal: c_ulong = 0,
    pub fn create(host: *gtk.Box, editor: *Editor, context: *anyopaque, invalidate: @FieldType(View, "invalidate")) !*View {
        const self = try a.create(View);
        const summary = w.label("Discovering plugins…", "pearl-secondary");
        host.append(summary.as(gtk.Widget));
        host.append(w.label("Review and approve a plugin before enabling it. Apply saves changes; Retry and Preview act immediately. Restart Pearl after installing or updating packages.", "pearl-secondary").as(gtk.Widget));
        const content = w.column(12);
        host.append(content.as(gtk.Widget));
        const controls = gtk.Box.new(.horizontal, 8);
        host.append(controls.as(gtk.Widget));
        const previous = gtk.Button.newWithLabel("First page");
        controls.append(previous.as(gtk.Widget));
        const next = gtk.Button.newWithLabel("Next page");
        controls.append(next.as(gtk.Widget));
        self.* = .{ .context = context, .invalidate = invalidate, .host = host, .editor = editor, .summary = summary, .content = content, .arena = std.heap.ArenaAllocator.init(a), .next = next, .previous = previous };
        self.previous_signal = gtk.Button.signals.clicked.connect(previous, *View, first, self, .{});
        self.next_signal = gtk.Button.signals.clicked.connect(next, *View, more, self, .{});
        return self;
    }
    fn first(_: *gtk.Button, self: *View) callconv(.c) void {
        self.editor.livePage(0);
    }
    fn more(_: *gtk.Button, self: *View) callconv(.c) void {
        self.editor.livePage(self.editor.live_offset + 4);
    }
    fn track(self: *View, value: *object.Object, id: c_ulong) void {
        self.signals.append(a, .{ .value = value, .id = id }) catch object.signalHandlerDisconnect(value, id);
    }
    fn clear(self: *View) void {
        for (self.signals.items) |signal| object.signalHandlerDisconnect(signal.value, signal.id);
        self.signals.clearRetainingCapacity();
        self.invalidate(self.context, .plugins);
        while (self.content.as(gtk.Widget).getFirstChild()) |child| self.content.remove(child);
        self.rows.clearRetainingCapacity();
        _ = self.arena.reset(.free_all);
        if (self.key) |key| a.free(key);
        self.key = null;
    }
    pub fn destroy(self: *View) void {
        // Host widgets are destroyed immediately after this view by Window.
        object.signalHandlerDisconnect(self.next.as(object.Object), self.next_signal);
        object.signalHandlerDisconnect(self.previous.as(object.Object), self.previous_signal);
        self.clear();
        self.rows.deinit(a);
        self.signals.deinit(a);
        self.arena.deinit();
        a.destroy(self);
    }
    pub fn update(self: *View) void {
        if (self.editing or self.editor.target.page != .plugins) return;
        self.filling = true;
        defer self.filling = false;
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const alloc = temp.allocator();
        const page = std.json.parseFromSliceLeaky(ui.PluginPage, alloc, self.editor.live orelse "{}", .{ .ignore_unknown_fields = true }) catch return;
        self.summary.setText(alloc.dupeZ(u8, page.summary) catch return);
        self.next.as(gtk.Widget).setSensitive(@intFromBool(page.next_offset != null));
        var identities: std.ArrayList([]const u8) = .empty;
        for (page.plugins) |info| {
            identities.append(alloc, info.id) catch return;
            identities.append(alloc, info.digest) catch return;
        }
        const key = std.json.Stringify.valueAlloc(a, identities.items, .{}) catch return;
        defer a.free(key);
        if (self.key == null or !std.mem.eql(u8, self.key.?, key)) {
            self.clear();
            self.key = a.dupe(u8, key) catch return;
            const owned = std.json.parseFromSliceLeaky(ui.PluginPage, self.arena.allocator(), self.editor.live.?, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return;
            for (owned.plugins) |info| self.add(info) catch return;
        }
        const document = std.json.parseFromSliceLeaky(prefs.Preferences, alloc, self.editor.text(), .{}) catch {
            self.content.as(gtk.Widget).setSensitive(0);
            return;
        };
        self.content.as(gtk.Widget).setSensitive(@intFromBool(self.editor.editable()));
        for (self.rows.items, page.plugins) |row, info| {
            const cfg = document.plugins.find(info.id) orelse m.Config{ .id = info.id };
            row.status.setText(std.fmt.allocPrintSentinel(alloc, "{s} · {s}\n{s}\nApproval: {s}", .{ info.status, info.error_code orelse "No runtime error", info.digest, if (std.mem.eql(u8, cfg.digest, info.digest)) "current package approved" else "review and approve this package" }, 0) catch continue);
            row.enabled.as(gtk.Widget).setSensitive(@intFromBool(info.installed or cfg.enabled));
            row.enabled.setActive(@intFromBool(cfg.enabled));
            row.activity.setActive(@intFromBool(cfg.grants.input_activity));
            row.overlay.setActive(@intFromBool(cfg.grants.overlay));
            row.mode.setSelected(if (cfg.placement.mode == .bar) 0 else 1);
            setEntry(row.output, cfg.placement.output, alloc);
            row.x.setValue(@floatFromInt(cfg.placement.x));
            row.y.setValue(@floatFromInt(cfg.placement.y));
            row.width.setValue(@floatFromInt(cfg.placement.width));
            row.height.setValue(@floatFromInt(cfg.placement.height));
            row.interactive.setActive(@intFromBool(cfg.placement.interactive));
            row.locked.setActive(@intFromBool(cfg.placement.locked));
            row.fullscreen.setActive(@intFromBool(cfg.placement.hide_fullscreen));
            for (info.settings, row.values) |spec, entry| {
                var value = spec.default;
                for (cfg.settings) |setting| if (std.mem.eql(u8, setting.key, spec.key)) {
                    value = setting.value;
                    break;
                };
                switch (spec.kind) {
                    .text => setEntry(object.ext.cast(gtk.Entry, entry).?, value, alloc),
                    .number => object.ext.cast(gtk.SpinButton, entry).?.setValue(std.fmt.parseFloat(f64, value) catch @floatFromInt(spec.min)),
                    .toggle => object.ext.cast(gtk.Switch, entry).?.setActive(@intFromBool(std.mem.eql(u8, value, "true"))),
                }
            }
        }
    }
    fn setEntry(entry: *gtk.Entry, text: []const u8, alloc: std.mem.Allocator) void {
        if (!std.mem.eql(u8, std.mem.span(entry.as(gtk.Editable).getText()), text)) entry.as(gtk.Editable).setText(alloc.dupeZ(u8, text) catch return);
    }
    fn add(self: *View, info: ui.PluginInfo) !void {
        const alloc = self.arena.allocator();
        const card = w.column(8);
        card.as(gtk.Widget).addCssClass("settings-card");
        self.content.append(card.as(gtk.Widget));
        card.append(w.label(try std.fmt.allocPrintSentinel(alloc, "{s} · {s}", .{ info.name, info.version }, 0), "settings-row-title").as(gtk.Widget));
        card.append(w.label(try alloc.dupeZ(u8, info.id), "pearl-secondary").as(gtk.Widget));
        const status = w.label("", "pearl-secondary");
        card.append(status.as(gtk.Widget));
        const config = w.column(6);
        const placement = w.column(6);
        config.append(placement.as(gtk.Widget));
        placement.as(gtk.Widget).setVisible(@intFromBool(info.capabilities.overlay));
        const expander = gtk.Expander.new("Settings and placement");
        expander.setChild(config.as(gtk.Widget));
        config.as(gtk.Widget).setSensitive(@intFromBool(info.installed));
        expander.as(gtk.Widget).setVisible(@intFromBool(info.settings.len > 0 or info.capabilities.overlay or info.capabilities.input_activity));
        const row = try alloc.create(Row);
        row.* = .{ .view = self, .info = info, .status = status, .enabled = toggle(card, "Enabled"), .activity = toggle(config, "Allow aggregate input activity (currently unsupported)"), .overlay = toggle(placement, "Allow desktop overlay"), .mode = gtk.DropDown.newFromStrings(@ptrCast(&[_:null]?[*:0]const u8{ "Bar", "Desktop overlay" })), .output = makeEntry(placement, "Overlay output (empty: first output)"), .x = number(placement, "Horizontal position", 0, 65535), .y = number(placement, "Vertical position", 0, 65535), .width = number(placement, "Width", 16, 512), .height = number(placement, "Height", 16, 512), .interactive = toggle(placement, "Accept clicks (off: click through)"), .locked = toggle(placement, "Lock placement"), .fullscreen = toggle(placement, "Hide over fullscreen windows"), .values = try alloc.alloc(*gtk.Widget, info.settings.len) };
        card.append(expander.as(gtk.Widget));
        field(placement, "Placement", row.mode.as(gtk.Widget));
        row.activity.as(gtk.Widget).setSensitive(@intFromBool(info.capabilities.input_activity));
        row.overlay.as(gtk.Widget).setSensitive(@intFromBool(info.capabilities.overlay));
        inline for (.{ "enabled", "activity", "overlay", "interactive", "locked", "fullscreen" }) |name| self.track(@field(row, name).as(object.Object), object.Object.signals.notify.connect(@field(row, name).as(object.Object), *Row, changed, row, .{ .detail = "active" }));
        self.track(row.mode.as(object.Object), object.Object.signals.notify.connect(row.mode.as(object.Object), *Row, changed, row, .{ .detail = "selected" }));
        inline for (.{ "x", "y", "width", "height" }) |name| self.track(@field(row, name).as(object.Object), gtk.SpinButton.signals.value_changed.connect(@field(row, name), *Row, spun, row, .{}));
        self.track(row.output.as(gtk.Editable).as(object.Object), gtk.Editable.signals.changed.connect(row.output.as(gtk.Editable), *Row, edited, row, .{}));
        for (info.settings, row.values) |spec, *value| {
            const label = try alloc.dupeZ(u8, spec.label);
            value.* = switch (spec.kind) {
                .text => blk: {
                    const widget = makeEntry(config, label);
                    self.track(widget.as(gtk.Editable).as(object.Object), gtk.Editable.signals.changed.connect(widget.as(gtk.Editable), *Row, edited, row, .{}));
                    break :blk widget.as(gtk.Widget);
                },
                .number => blk: {
                    const widget = number(config, label, @floatFromInt(spec.min), @floatFromInt(spec.max));
                    self.track(widget.as(object.Object), gtk.SpinButton.signals.value_changed.connect(widget, *Row, spun, row, .{}));
                    break :blk widget.as(gtk.Widget);
                },
                .toggle => blk: {
                    const widget = toggle(config, label);
                    self.track(widget.as(object.Object), object.Object.signals.notify.connect(widget.as(object.Object), *Row, changed, row, .{ .detail = "active" }));
                    break :blk widget.as(gtk.Widget);
                },
            };
        }
        const buttons = w.flow(3);
        buttons.setHomogeneous(0);
        buttons.as(gtk.Widget).setMarginStart(16);
        buttons.as(gtk.Widget).setMarginEnd(16);
        buttons.as(gtk.Widget).setMarginBottom(12);
        card.append(buttons.as(gtk.Widget));
        inline for (.{ .{ Action.approve, "Approve package" }, .{ Action.bar, "Add to bar" }, .{ Action.retry, "Retry" }, .{ Action.preview, "Preview" }, .{ Action.reset, "Reset settings" } }) |pair| {
            const button = gtk.Button.newWithLabel(pair[1]);
            buttons.insert(button.as(gtk.Widget), -1);
            button.as(gtk.Widget).setSensitive(@intFromBool(info.installed));
            const binding = try alloc.create(Button);
            binding.* = .{ .row = row, .action = pair[0] };
            self.track(button.as(object.Object), gtk.Button.signals.clicked.connect(button, *Button, clicked, binding, .{}));
        }
        try self.rows.append(a, row);
    }
    fn field(card: *gtk.Box, title: [:0]const u8, widget: *gtk.Widget) void {
        const box = w.flow(2);
        box.setHomogeneous(0);
        box.as(gtk.Widget).addCssClass("settings-form-row");
        w.name(widget, title);
        box.insert(w.label(title, "settings-row-title").as(gtk.Widget), -1);
        box.insert(widget, -1);
        card.append(box.as(gtk.Widget));
    }
    fn toggle(card: *gtk.Box, title: [:0]const u8) *gtk.Switch {
        const value = gtk.Switch.new();
        field(card, title, value.as(gtk.Widget));
        return value;
    }
    fn number(card: *gtk.Box, title: [:0]const u8, min: f64, max: f64) *gtk.SpinButton {
        const value = gtk.SpinButton.newWithRange(min, max, 1);
        field(card, title, value.as(gtk.Widget));
        return value;
    }
    fn makeEntry(card: *gtk.Box, title: [:0]const u8) *gtk.Entry {
        const value = gtk.Entry.new();
        value.setMaxLength(256);
        field(card, title, value.as(gtk.Widget));
        return value;
    }
    fn changed(_: *object.Object, _: *object.ParamSpec, row: *Row) callconv(.c) void {
        row.view.save(row, null) catch |err| row.view.report(err);
    }
    fn spun(_: *gtk.SpinButton, row: *Row) callconv(.c) void {
        row.view.save(row, null) catch |err| row.view.report(err);
    }
    fn edited(_: *gtk.Editable, row: *Row) callconv(.c) void {
        row.view.save(row, null) catch |err| row.view.report(err);
    }
    fn clicked(_: *gtk.Button, binding: *Button) callconv(.c) void {
        binding.row.view.save(binding.row, binding.action) catch |err| binding.row.view.report(err);
    }
    fn report(self: *View, err: anyerror) void {
        self.summary.setText(@errorName(err));
    }
    fn save(self: *View, row: *Row, action: ?Action) !void {
        if (self.filling or self.editing or !self.editor.editable()) return;
        self.editing = true;
        defer self.editing = false;
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const alloc = temp.allocator();
        if (action == .retry or action == .preview) {
            const bytes = try std.json.Stringify.valueAlloc(alloc, .{ .id = row.info.id, .action = if (action == .retry) "retry" else "preview" }, .{});
            try self.editor.liveAction(.@"plugin.action", try std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{}));
            return;
        }
        var document = try std.json.parseFromSliceLeaky(prefs.Preferences, alloc, self.editor.text(), .{});
        var cfg = document.plugins.find(row.info.id) orelse m.Config{ .id = row.info.id };
        cfg.enabled = row.enabled.getActive() != 0;
        if (row.info.installed) {
            cfg.grants = .{ .input_activity = row.activity.getActive() != 0, .overlay = row.overlay.getActive() != 0 };
            cfg.placement = .{ .mode = if (row.mode.getSelected() == 0) .bar else .overlay, .output = std.mem.span(row.output.as(gtk.Editable).getText()), .x = @intCast(row.x.getValueAsInt()), .y = @intCast(row.y.getValueAsInt()), .width = @intCast(row.width.getValueAsInt()), .height = @intCast(row.height.getValueAsInt()), .interactive = row.interactive.getActive() != 0, .locked = row.locked.getActive() != 0, .hide_fullscreen = row.fullscreen.getActive() != 0 };
            const values = try alloc.alloc(m.Setting, row.values.len);
            for (row.info.settings, row.values, values) |spec, value, *setting| setting.* = .{ .key = spec.key, .value = if (action == .reset) spec.default else switch (spec.kind) {
                .text => std.mem.span(object.ext.cast(gtk.Entry, value).?.as(gtk.Editable).getText()),
                .number => try std.fmt.allocPrint(alloc, "{d}", .{object.ext.cast(gtk.SpinButton, value).?.getValueAsInt()}),
                .toggle => if (object.ext.cast(gtk.Switch, value).?.getActive() != 0) "true" else "false",
            } };
            cfg.settings = values;
            if (action == .approve) cfg.digest = row.info.digest;
        }
        var entries: std.ArrayList(m.Config) = .empty;
        for (document.plugins.entries) |old| if (!std.mem.eql(u8, old.id, cfg.id)) {
            try entries.append(alloc, old);
        };
        try entries.append(alloc, cfg);
        document.plugins.entries = entries.items;
        if (action == .bar) {
            const ref = try std.fmt.allocPrint(alloc, "plugin:{s}/main", .{cfg.id});
            var present = false;
            for ([_][]const u8{ document.bar.groups.left, document.bar.groups.center, document.bar.groups.right }) |group| {
                var parts = std.mem.splitScalar(u8, group, ',');
                while (parts.next()) |part| if (std.mem.eql(u8, part, ref)) {
                    present = true;
                };
            }
            if (!present) document.bar.groups.right = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ document.bar.groups.right, if (document.bar.groups.right.len > 0) "," else "", ref });
        }
        try self.editor.edit(try std.json.Stringify.valueAlloc(alloc, document, .{ .whitespace = .indent_2 }));
    }
};
