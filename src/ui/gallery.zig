const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const w = @import("components/widgets.zig");
const i18n = @import("i18n.zig");
const codec = @import("../aqueous/codec.zig");
const Model = @import("../aqueous/reducer.zig").Model;
const options = @import("build_options");
const Key = std.meta.FieldEnum(@TypeOf(i18n.en));
const log = std.log.scoped(.gallery);
const a = std.heap.page_allocator;

pub const Gallery = struct {
    window: *gtk.Window,
    builder: *gtk.Builder,
    language: i18n.Language,
    bindings: [96]Binding = undefined,
    binding_count: usize = 0,
    connections: [64]Connection = undefined,
    connection_count: usize = 0,
    light: *gtk.ToggleButton = undefined,
    compact: *gtk.ToggleButton = undefined,
    large: *gtk.ToggleButton = undefined,
    motion: *gtk.ToggleButton = undefined,
    language_button: *gtk.Button = undefined,
    search: *gtk.SearchEntry = undefined,
    strings: *gtk.StringList = undefined, // borrowed through the ListView's model chain
    filter: *gtk.StringFilter = undefined,
    filtered: *gtk.FilterListModel = undefined,
    selection: *gtk.SingleSelection = undefined,
    list: *gtk.ListView = undefined,
    factory: *gtk.SignalListItemFactory = undefined,
    result_label: *gtk.Label = undefined,
    empty: *gtk.Box = undefined,
    tiles: [3]w.Tile = undefined,
    calendar: ?*@import("../desktop/calendar.zig").View = null,
    volume: *gtk.Scale = undefined,
    brightness: *gtk.Scale = undefined,
    quiet: *gtk.Switch = undefined,
    original_animations: c_int = 1,
    preview_state: enum { pending, ready, failure } = .pending,
    test_sources: [2]c_uint = .{ 0, 0 },
    idle_frame: i64 = 0,
    const Binding = struct { widget: *gtk.Widget, key: Key, kind: enum { label, button, tooltip, name } };
    const Connection = struct { object: *gobject.Object, id: c_ulong };

    pub fn widget(self: *Gallery, comptime T: type, name: [*:0]const u8) *T {
        return gobject.ext.cast(T, self.builder.getObject(name).?).?;
    }
    fn tr(self: *Gallery, key: Key) [:0]const u8 {
        return switch (key) {
            inline else => |k| i18n.text(self.language, @tagName(k)),
        };
    }
    fn bindText(self: *Gallery, widget_: *gtk.Widget, key: Key, kind: @FieldType(Binding, "kind")) void {
        self.bindings[self.binding_count] = .{ .widget = widget_, .key = key, .kind = kind };
        self.binding_count += 1;
    }
    fn label(self: *Gallery, key: Key, class: ?[*:0]const u8) *gtk.Label {
        const result = w.label(self.tr(key), class);
        self.bindText(result.as(gtk.Widget), key, .label);
        return result;
    }
    fn remember(self: *Gallery, object: *gobject.Object, id: c_ulong) void {
        _ = object.ref(); // safe even after the window has been destroyed
        self.connections[self.connection_count] = .{ .object = object, .id = id };
        self.connection_count += 1;
    }
    fn toggle(self: *Gallery, key: Key) *gtk.ToggleButton {
        const result = gtk.ToggleButton.newWithLabel(self.tr(key));
        self.bindText(result.as(gtk.Widget), key, .button);
        self.remember(result.as(gobject.Object), gtk.ToggleButton.signals.toggled.connect(result, *Gallery, appearanceChanged, self, .{}));
        return result;
    }
    /// Must be called on a stable address; signal callbacks borrow this struct.
    pub fn init(self: *Gallery, window: *gtk.Window, builder: *gtk.Builder) !void {
        self.* = .{ .window = window, .builder = builder, .language = initialLanguage() };
        errdefer self.deinit();
        window.as(gtk.Widget).getSettings().as(gobject.Object).get("gtk-enable-animations", &self.original_animations, @as(?[*:0]const u8, null));
        const host = self.widget(gtk.Box, "gallery_host");
        const toolbar = w.flow(5);
        toolbar.setHomogeneous(0);
        self.light = self.toggle(.light);
        self.compact = self.toggle(.compact);
        self.large = self.toggle(.large);
        self.motion = self.toggle(.motion);
        self.language_button = gtk.Button.newWithLabel(self.tr(.language));
        self.light.as(gtk.Widget).setName("theme-light");
        self.compact.as(gtk.Widget).setName("density-compact");
        self.large.as(gtk.Widget).setName("text-large");
        self.motion.as(gtk.Widget).setName("motion-reduced");
        self.language_button.as(gtk.Widget).setName("language");
        self.light.as(gtk.Widget).setTooltipText("Ctrl+L");
        self.compact.as(gtk.Widget).setTooltipText("Ctrl+D");
        self.large.as(gtk.Widget).setTooltipText("Ctrl+E");
        self.motion.as(gtk.Widget).setTooltipText("Ctrl+R");
        self.language_button.as(gtk.Widget).setTooltipText("Ctrl+G");
        self.bindText(self.language_button.as(gtk.Widget), .language, .button);
        for ([_]*gtk.Widget{ self.light.as(gtk.Widget), self.compact.as(gtk.Widget), self.large.as(gtk.Widget), self.motion.as(gtk.Widget), self.language_button.as(gtk.Widget) }) |control| toolbar.insert(control, -1);
        self.remember(self.language_button.as(gobject.Object), gtk.Button.signals.clicked.connect(self.language_button, *Gallery, languageChanged, self, .{}));
        host.append(toolbar.as(gtk.Widget));

        const panels = w.flow(2);
        panels.setColumnSpacing(20);
        panels.setRowSpacing(20);
        host.append(panels.as(gtk.Widget));
        const controls = w.card();
        controls.as(gtk.Widget).setSizeRequest(390, -1);
        controls.append(self.label(.controls, "pearl-card-title").as(gtk.Widget));
        const profile = w.row(12);
        profile.as(gtk.Widget).addCssClass("pearl-profile");
        const avatar = w.icon("pearl-avatar-default-symbolic");
        avatar.as(gtk.Widget).addCssClass("pearl-avatar");
        profile.append(avatar.as(gtk.Widget));
        const greeting = w.column(4);
        greeting.as(gtk.Widget).setHexpand(1);
        greeting.append(self.label(.profile, "pearl-card-title").as(gtk.Widget));
        greeting.append(self.label(.sample, "pearl-secondary").as(gtk.Widget));
        profile.append(greeting.as(gtk.Widget));
        const settings = w.iconButton("pearl-emblem-system-symbolic", self.tr(.settings));
        self.bindText(settings.as(gtk.Widget), .settings, .tooltip);
        self.remember(settings.as(gobject.Object), gtk.Button.signals.clicked.connect(settings, *Gallery, settingsClicked, self, .{}));
        profile.append(settings.as(gtk.Widget));
        controls.append(profile.as(gtk.Widget));
        const tiles = w.flow(2);
        self.tiles = .{
            w.tile("pearl-network-wireless-symbolic", self.label(.wifi, null), w.label("", "pearl-secondary"), true),
            w.tile("pearl-bluetooth-active-symbolic", self.label(.bluetooth, null), w.label("", "pearl-secondary"), false),
            w.tile("pearl-weather-clear-night-symbolic", self.label(.night, null), w.label("", "pearl-secondary"), false),
        };
        for (&self.tiles, [_]Key{ .wifi, .bluetooth, .night }) |*tile, key| {
            tiles.insert(tile.button.as(gtk.Widget), -1);
            self.bindText(tile.button.as(gtk.Widget), key, .name);
            self.remember(tile.button.as(gobject.Object), gtk.ToggleButton.signals.toggled.connect(tile.button, *Gallery, tileChanged, self, .{}));
        }
        const disabled = gtk.Button.newWithLabel(self.tr(.disabled));
        disabled.as(gtk.Widget).setSensitive(0);
        disabled.as(gtk.Widget).setTooltipText(self.tr(.disabled_detail));
        self.bindText(disabled.as(gtk.Widget), .disabled, .button);
        self.bindText(disabled.as(gtk.Widget), .disabled_detail, .tooltip);
        tiles.insert(disabled.as(gtk.Widget), -1);
        controls.append(tiles.as(gtk.Widget));
        const volume = w.slider(self.label(.volume, "pearl-secondary"), "pearl-audio-volume-high-symbolic", 65);
        const brightness = w.slider(self.label(.brightness, "pearl-secondary"), "pearl-display-brightness-symbolic", 80);
        self.volume = volume.scale;
        self.brightness = brightness.scale;
        self.volume.as(gtk.Widget).setName("volume");
        self.brightness.as(gtk.Widget).setName("brightness");
        self.bindText(self.volume.as(gtk.Widget), .volume, .name);
        self.bindText(self.brightness.as(gtk.Widget), .brightness, .name);
        controls.append(volume.box.as(gtk.Widget));
        controls.append(brightness.box.as(gtk.Widget));
        self.quiet = gtk.Switch.new();
        self.quiet.as(gtk.Widget).setName("quiet");
        self.bindText(self.quiet.as(gtk.Widget), .quiet, .name);
        controls.append(w.section(self.label(.quiet, null), self.label(.quiet_detail, "pearl-secondary"), self.quiet.as(gtk.Widget)).as(gtk.Widget));
        controls.append(self.label(.workspaces, "pearl-secondary").as(gtk.Widget));
        try self.addWorkspacePills(controls);
        panels.insert(controls.as(gtk.Widget), -1);

        const launcher = w.card();
        launcher.as(gtk.Widget).setSizeRequest(390, -1);
        launcher.append(self.label(.launcher, "pearl-card-title").as(gtk.Widget));
        self.search = gtk.SearchEntry.new();
        self.search.as(gtk.Widget).setName("search");
        self.search.setSearchDelay(0);
        self.search.as(gtk.Widget).setTooltipText("Ctrl+F");
        launcher.append(self.search.as(gtk.Widget));
        self.strings = gtk.StringList.new(null);
        const expression = gtk.PropertyExpression.new(gtk.StringObject.getGObjectType(), null, "string");
        self.filter = gtk.StringFilter.new(expression.as(gtk.Expression));
        self.filter.setIgnoreCase(1);
        self.filter.setMatchMode(.substring);
        self.filtered = gtk.FilterListModel.new(self.strings.as(gio.ListModel), self.filter.as(gtk.Filter));
        self.selection = gtk.SingleSelection.new(self.filtered.as(gio.ListModel));
        self.selection.setAutoselect(1);
        self.factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(self.factory, ?*anyopaque, w.listSetup, null, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(self.factory, ?*anyopaque, w.listBind, null, .{});
        self.list = gtk.ListView.new(self.selection.as(gtk.SelectionModel), self.factory.as(gtk.ListItemFactory));
        self.list.setSingleClickActivate(1);
        self.list.setTabBehavior(.item);
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.setMinContentHeight(250);
        scroll.setMaxContentHeight(250);
        scroll.setPropagateNaturalHeight(1);
        scroll.setChild(self.list.as(gtk.Widget));
        launcher.append(scroll.as(gtk.Widget));
        self.result_label = w.label("", "pearl-secondary");
        launcher.append(self.result_label.as(gtk.Widget));
        self.empty = w.status(.empty, self.label(.nothing, null), self.label(.nothing_detail, "pearl-secondary"));
        self.empty.as(gtk.Widget).setVisible(0);
        launcher.append(self.empty.as(gtk.Widget));
        launcher.append(w.status(.empty, self.label(.empty, null), self.label(.empty_detail, "pearl-secondary")).as(gtk.Widget));
        panels.insert(launcher.as(gtk.Widget), -1);
        const calendar_host = w.column(0);
        calendar_host.as(gtk.Widget).setSizeRequest(400, 480);
        panels.insert(calendar_host.as(gtk.Widget), -1);
        self.calendar = try @import("../desktop/calendar.zig").View.create(calendar_host);
        self.remember(self.search.as(gobject.Object), gtk.SearchEntry.signals.search_changed.connect(self.search, *Gallery, searchChanged, self, .{}));
        self.remember(self.search.as(gobject.Object), gtk.SearchEntry.signals.activate.connect(self.search, *Gallery, searchActivated, self, .{}));
        self.remember(self.list.as(gobject.Object), gtk.ListView.signals.activate.connect(self.list, *Gallery, listActivated, self, .{}));
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        self.remember(keys.as(gobject.Object), gtk.EventControllerKey.signals.key_pressed.connect(keys, *Gallery, keyPressed, self, .{}));
        window.as(gtk.Widget).addController(keys.as(gtk.EventController));
        const states = w.flow(2);
        states.insert(w.status(.failure, self.label(.error_title, null), self.label(.error_detail, "pearl-secondary")).as(gtk.Widget), -1);
        states.insert(w.status(.pending, self.label(.pending, null), self.label(.pending_detail, "pearl-secondary")).as(gtk.Widget), -1);
        host.append(states.as(gtk.Widget));
        self.bindText(self.widget(gtk.Widget, "badge"), .demo, .label);
        self.bindText(self.widget(gtk.Widget, "heading"), .title, .label);
        self.bindText(self.widget(gtk.Widget, "subtitle"), .subtitle, .label);
        self.bindText(self.widget(gtk.Widget, "card_title"), .preview, .label);
        self.bindText(self.widget(gtk.Widget, "reload"), .reload, .button);
        self.bindText(self.widget(gtk.Widget, "close"), .close, .button);
        self.translate();
        self.applyAppearance();
        _ = self.search.as(gtk.Widget).grabFocus();
    }

    fn fixtureModel() !Model {
        var err: ?*glib.Error = null;
        const bytes = gio.resourcesLookupData("/org/aqueous/Pearl/aqueous-desktop.json", .{}, &err) orelse {
            if (err) |owned| owned.free();
            return error.MissingFixture;
        };
        defer bytes.unref();
        var size: usize = 0;
        const ptr: [*]const u8 = @ptrCast(bytes.getData(&size).?);
        var decoded = try codec.decode(a, std.mem.trimEnd(u8, ptr[0..size], "\n"), .{}, null);
        defer decoded.deinit();
        var model = try Model.init(a, (codec.Limits{}).state_bytes);
        errdefer model.deinit();
        try model.apply(decoded.message.event.batch);
        return model;
    }
    fn addWorkspacePills(self: *Gallery, controls: *gtk.Box) !void {
        var model = try fixtureModel();
        defer model.deinit();
        const workspaces = try model.workspaces(a, "1");
        defer a.free(workspaces);
        const pills = w.flow(9);
        pills.setColumnSpacing(4);
        var first: ?*gtk.ToggleButton = null;
        for (workspaces) |workspace| {
            var buffer: [24]u8 = undefined;
            const title = try std.fmt.bufPrintZ(&buffer, "{d}", .{workspace.number});
            const pill = w.pill(title, false);
            if (first) |group| pill.setGroup(group) else first = pill;
            pill.setActive(@intFromBool(workspace.active));
            self.remember(pill.as(gobject.Object), gtk.ToggleButton.signals.toggled.connect(pill, *Gallery, workspaceChanged, self, .{}));
            pills.insert(pill.as(gtk.Widget), -1);
        }
        controls.append(pills.as(gtk.Widget));
    }
    fn fillList(self: *Gallery) void {
        self.strings.splice(0, self.strings.as(gio.ListModel).getNItems(), null);
        // Fixtures are local content, not translated application identities.
        for ([_][*:0]const u8{ "Files", "Terminal", "Settings", "Draft 🐟", "Café notes", "Musik" }) |item| self.strings.append(item);
        var buffer: [128]u8 = undefined;
        for (0..512) |i| {
            const title = std.fmt.bufPrintZ(&buffer, "{s} {d:0>4}", .{ self.tr(.sample_window), i + 1 }) catch unreachable;
            self.strings.append(title);
        }
    }
    fn translate(self: *Gallery) void {
        self.window.setTitle(self.tr(.window_title));
        for (self.bindings[0..self.binding_count]) |binding| {
            const text = self.tr(binding.key);
            switch (binding.kind) {
                .label => gobject.ext.cast(gtk.Label, binding.widget).?.setText(text),
                .button => gobject.ext.cast(gtk.Button, binding.widget).?.setLabel(text),
                .tooltip => {
                    binding.widget.setTooltipText(text);
                    w.name(binding.widget, text);
                },
                .name => w.name(binding.widget, text),
            }
        }
        self.search.setPlaceholderText(self.tr(.search));
        w.name(self.search.as(gtk.Widget), self.tr(.search));
        w.name(self.list.as(gtk.Widget), self.tr(.results));
        self.fillList();
        self.updateTiles();
        self.updateResults();
        self.drawPreview();
    }
    pub fn previewComplete(self: *Gallery, success: bool) void {
        self.preview_state = if (success) .ready else .failure;
        self.drawPreview();
    }
    fn drawPreview(self: *Gallery) void {
        var buffer: [1024]u8 = undefined;
        const text = switch (self.preview_state) {
            .ready => std.fmt.bufPrintZ(&buffer, "{s}\n{s}", .{ self.tr(.calendar), self.tr(.calendar_detail) }) catch unreachable,
            .pending => self.tr(.loading),
            .failure => self.tr(.load_error),
        };
        self.widget(gtk.Label, "preview").setText(text);
    }
    pub fn previewLoading(self: *Gallery) void {
        self.preview_state = .pending;
        self.drawPreview();
    }
    fn setClass(self: *Gallery, class: [*:0]const u8, enabled: bool) void {
        if (enabled) self.window.as(gtk.Widget).addCssClass(class) else self.window.as(gtk.Widget).removeCssClass(class);
    }
    fn applyAppearance(self: *Gallery) void {
        const light = self.light.getActive() != 0;
        const reduced = self.motion.getActive() != 0 or self.original_animations == 0;
        self.setClass("pearl-light", light);
        self.setClass("pearl-dark", !light);
        self.setClass("pearl-compact", self.compact.getActive() != 0);
        self.setClass("pearl-large", self.large.getActive() != 0);
        self.setClass("pearl-reduced", reduced);
        self.window.as(gtk.Widget).getSettings().as(gobject.Object).set("gtk-enable-animations", @as(c_int, @intFromBool(!reduced)), @as(?[*:0]const u8, null));
        log.info("event=appearance light={} compact={} large={} reduced={}", .{ light, self.compact.getActive() != 0, self.large.getActive() != 0, reduced });
    }
    fn updateTiles(self: *Gallery) void {
        for (&self.tiles, 0..) |*tile, i| tile.subtitle.setText(self.tr(if (tile.button.getActive() == 0) .off else if (i == 0) .connected else .on));
    }
    fn updateResults(self: *Gallery) void {
        const count = self.filtered.as(gio.ListModel).getNItems();
        var buffer: [128]u8 = undefined;
        self.result_label.setText(std.fmt.bufPrintZ(&buffer, "{s} · {d}", .{ self.tr(.results), count }) catch unreachable);
        self.empty.as(gtk.Widget).setVisible(@intFromBool(count == 0));
        log.info("event=search results={d}", .{count});
    }
    fn activateSelected(self: *Gallery) void {
        const item = self.selection.getSelectedItem() orelse return;
        const value = gobject.ext.cast(gtk.StringObject, item).?.getString();
        var buffer: [256]u8 = undefined;
        self.result_label.setText(std.fmt.bufPrintZ(&buffer, "{s} · {s}", .{ self.tr(.selected), value }) catch unreachable);
        log.info("event=sample-activated title={s}", .{value});
    }
    pub fn deinit(self: *Gallery) void {
        for (&self.test_sources) |*source| if (source.* != 0) {
            _ = glib.Source.remove(source.*);
            source.* = 0;
        };
        for (self.connections[0..self.connection_count]) |connection| {
            gobject.signalHandlerDisconnect(connection.object, connection.id);
            connection.object.unref();
        }
        self.connection_count = 0;
        self.window.as(gtk.Widget).getSettings().as(gobject.Object).set("gtk-enable-animations", self.original_animations, @as(?[*:0]const u8, null));
    }

    fn report(self: *Gallery) void {
        var rows: usize = 0;
        var clipped: usize = 0;
        inspect(self.window.as(gtk.Widget), &rows, &clipped);
        var focus = self.window.getFocus();
        var focus_name: [*:0]const u8 = "none";
        while (focus) |widget_| : (focus = widget_.getParent()) {
            focus_name = widget_.getName();
            if (!std.mem.startsWith(u8, std.mem.span(focus_name), "Gtk")) break;
        }
        const counter = self.window.as(gtk.Widget).getFrameClock().?.getFrameCounter();
        log.info("event=gallery-probe rows={d} total={d} clipped={d} width={d} height={d} frame={d} focus={s} volume={d} quiet={} selected={d}", .{
            rows,                                  self.filtered.as(gio.ListModel).getNItems(), clipped,
            self.window.as(gtk.Widget).getWidth(), self.window.as(gtk.Widget).getHeight(),      counter,
            focus_name,                            self.volume.as(gtk.Range).getValue(),        self.quiet.getActive() != 0,
            self.selection.getSelected(),
        });
    }
};

fn inspect(widget: *gtk.Widget, rows: *usize, clipped: *usize) void {
    if (widget.hasCssClass("pearl-list-row") != 0) rows.* += 1;
    if (widget.getMapped() != 0 and widget.getWidth() > 0) {
        if (gobject.ext.cast(gtk.Label, widget)) |label_| {
            var width: c_int = 0;
            label_.getLayout().getPixelSize(&width, null);
            if (width > widget.getWidth() + 2) clipped.* += 1;
        }
    }
    var child = widget.getFirstChild();
    while (child) |value| : (child = value.getNextSibling()) inspect(value, rows, clipped);
}

fn appearanceChanged(_: *gtk.ToggleButton, self: *Gallery) callconv(.c) void {
    self.applyAppearance();
}
fn languageChanged(_: *gtk.Button, self: *Gallery) callconv(.c) void {
    self.language = if (self.language == .en) .de else .en;
    self.translate();
    log.info("event=language value={s}", .{@tagName(self.language)});
}
fn tileChanged(_: *gtk.ToggleButton, self: *Gallery) callconv(.c) void {
    self.updateTiles();
    log.info("event=tile-changed", .{});
}
fn workspaceChanged(button: *gtk.ToggleButton, _: *Gallery) callconv(.c) void {
    if (button.getActive() != 0) log.info("event=sample-workspace number={s}", .{button.as(gtk.Button).getLabel().?});
}
fn settingsClicked(_: *gtk.Button, self: *Gallery) callconv(.c) void {
    _ = self.light.as(gtk.Widget).grabFocus();
}
fn searchChanged(_: *gtk.SearchEntry, self: *Gallery) callconv(.c) void {
    self.filter.setSearch(self.search.as(gtk.Editable).getText());
    self.updateResults();
}
fn searchActivated(_: *gtk.SearchEntry, self: *Gallery) callconv(.c) void {
    self.activateSelected();
}
fn listActivated(_: *gtk.ListView, _: c_uint, self: *Gallery) callconv(.c) void {
    self.activateSelected();
}
fn keyPressed(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, modifiers: gdk.ModifierType, self: *Gallery) callconv(.c) c_int {
    if (options.test_hooks and key == 0xffc7) { // F10: two one-shot measurements, no input during the interval.
        for (&self.test_sources) |*source| if (source.* != 0) {
            _ = glib.Source.remove(source.*);
            source.* = 0;
        };
        self.test_sources[0] = glib.timeoutAdd(1000, idleStart, self);
        return 1;
    }
    if (options.test_hooks and key == 0xffc9) { // F12: read-only instrumentation in test binaries only.
        self.report();
        return 1;
    }
    if (modifiers.control_mask) {
        switch (key) {
            'f', 'F' => {
                _ = self.search.as(gtk.Widget).grabFocus();
            },
            'l', 'L' => self.light.setActive(@intFromBool(self.light.getActive() == 0)),
            'd', 'D' => self.compact.setActive(@intFromBool(self.compact.getActive() == 0)),
            'e', 'E' => self.large.setActive(@intFromBool(self.large.getActive() == 0)),
            'r', 'R' => self.motion.setActive(@intFromBool(self.motion.getActive() == 0)),
            'g', 'G' => languageChanged(self.language_button, self),
            0xff50 => {
                _ = self.light.as(gtk.Widget).grabFocus();
            }, // Ctrl+Home
            0xff57 => {
                _ = self.widget(gtk.Button, "close").as(gtk.Widget).grabFocus();
            }, // Ctrl+End
            else => return 0,
        }
        return 1;
    }
    if (key == 0xff1b) { // Escape clears search without dismissing the gallery.
        self.search.as(gtk.Editable).setText("");
        searchChanged(self.search, self);
        _ = self.search.as(gtk.Widget).grabFocus();
        return 1;
    }
    if (key == 0xff54 and self.window.getFocus() != null and self.window.getFocus().?.isAncestor(self.search.as(gtk.Widget)) != 0) {
        _ = self.list.as(gtk.Widget).grabFocus();
        self.list.scrollTo(self.selection.getSelected(), .{ .focus = true }, null);
        return 1;
    }
    return 0;
}

fn idleStart(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Gallery = @ptrCast(@alignCast(data.?));
    self.test_sources[0] = 0;
    self.idle_frame = self.window.as(gtk.Widget).getFrameClock().?.getFrameCounter();
    self.test_sources[1] = glib.timeoutAdd(3000, idleEnd, self);
    return 0;
}
fn idleEnd(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Gallery = @ptrCast(@alignCast(data.?));
    self.test_sources[1] = 0;
    const end = self.window.as(gtk.Widget).getFrameClock().?.getFrameCounter();
    log.info("event=idle-audit frames={d}", .{end - self.idle_frame});
    return 0;
}

fn initialLanguage() i18n.Language {
    for ([_][*:0]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" }) |key| {
        if (glib.getenv(key)) |value| if (value[0] != 0) return i18n.fromLocale(std.mem.span(value));
    }
    return .en;
}
