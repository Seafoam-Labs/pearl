//! Clipboard history and output capture controls share the shell's themed card components.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const glib = @import("glib2");
const gio = @import("gio2");
const pixbuf = @import("gdkpixbuf2");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const tr = @import("text.zig").tr;
const apps = @import("apps.zig");
const Clipboard = @import("../services/clipboard.zig").Clipboard;
const Capture = @import("../services/capture.zig").Capture;
const history = @import("../services/clipboard_policy.zig");
const test_hooks = @import("build_options").test_hooks;
const a = std.heap.c_allocator;
const Action = enum { take, region, window, cancel, save, copy, clear };
const Button = struct { view: *View, widget: *gtk.Button, signal: c_ulong, action: Action };
/// One retained clipboard entry, decoded once per model change.
const Record = struct { id: u64, label: [:0]u8, folded: [:0]u8, image: ?*pixbuf.Pixbuf };
/// Widgets of one recycled list row, owned by the GtkListItem that holds them.
const Row = struct {
    view: *View,
    item: *gtk.ListItem,
    label: *gtk.Label,
    image: *gtk.Picture,
    copy: *gtk.Button,
    remove: *gtk.Button,
    copy_signal: c_ulong,
    remove_signal: c_ulong,
    fn release(self: *Row) void {
        if (object.signalHandlerIsConnected(self.copy.as(object.Object), self.copy_signal) != 0) object.signalHandlerDisconnect(self.copy.as(object.Object), self.copy_signal);
        if (object.signalHandlerIsConnected(self.remove.as(object.Object), self.remove_signal) != 0) object.signalHandlerDisconnect(self.remove.as(object.Object), self.remove_signal);
    }
};
const Cursor = struct { id: ?u64 = null, position: c_uint = 0 };
const Rect = struct { x: i32, y: i32, width: i32, height: i32 };
fn bounds(widget: *gtk.Widget, root: *gtk.Widget) ?Rect {
    const width = widget.getWidth();
    const height = widget.getHeight();
    if (width <= 0 or height <= 0) return null;
    var x: f64 = 0;
    var y: f64 = 0;
    _ = widget.translateCoordinates(root, 0, 0, &x, &y);
    return .{ .x = @intFromFloat(x), .y = @intFromFloat(y), .width = width, .height = height };
}
pub const View = struct {
    clipboard: *Clipboard,
    capture: *Capture,
    context: *anyopaque,
    take: *const fn (*anyopaque, ?[]const u8) anyerror!void,
    dismiss: *const fn (*anyopaque) void,
    stack: *gtk.Stack,
    search: *gtk.SearchEntry,
    strings: *gtk.StringList,
    selection: *gtk.SingleSelection,
    list: *gtk.ListView,
    hint: *gtk.Label,
    info: *gtk.Label,
    clipboard_info: *gtk.Label,
    region: *gtk.Entry,
    window_selector: *gtk.DropDown = undefined,
    window_ids: [256]@import("../services/policy.zig").Text(128) = @splat(.{}),
    window_count: usize = 0,
    window_stamp: u64 = 0,
    picture: *gtk.Picture,
    buttons: std.ArrayList(*Button) = .empty,
    rows: std.ArrayList(*Row) = .empty,
    records: [history.entries_limit]Record = undefined,
    record_count: usize = 0,
    visible: [history.entries_limit]usize = undefined,
    visible_count: usize = 0,
    query: ?[:0]u8 = null,
    composing: bool = false,
    stamp: u64 = 0,
    image_generation: u64 = 0,
    connections: [8]struct { instance: *object.Object, id: c_ulong } = undefined,
    connection_count: usize = 0,
    pub fn create(host: *gtk.Box, clipboard: *Clipboard, capture: *Capture, context: *anyopaque, take: @FieldType(View, "take"), dismiss: @FieldType(View, "dismiss")) !*View {
        const self = try a.create(View);
        const search = gtk.SearchEntry.new();
        search.setSearchDelay(0);
        search.setPlaceholderText(tr("Filter clipboard history", "Zwischenablageverlauf filtern"));
        search.as(gtk.Widget).setName("clipboard-search");
        const strings = gtk.StringList.new(null);
        _ = strings.ref();
        const selection = gtk.SingleSelection.new(strings.as(gio.ListModel));
        _ = selection.ref();
        const factory = gtk.SignalListItemFactory.new();
        const list = gtk.ListView.new(selection.as(gtk.SelectionModel), factory.as(gtk.ListItemFactory));
        list.setSingleClickActivate(1);
        list.setTabBehavior(.item);
        self.* = .{
            .clipboard = clipboard,
            .capture = capture,
            .context = context,
            .take = take,
            .dismiss = dismiss,
            .stack = gtk.Stack.new(),
            .search = search,
            .strings = strings,
            .selection = selection,
            .list = list,
            .hint = w.label("", "pearl-secondary"),
            .info = w.label("", "pearl-secondary"),
            .clipboard_info = w.label("", "pearl-secondary"),
            .region = gtk.Entry.new(),
            .picture = gtk.Picture.new(),
        };
        host.append(w.label(tr("Clipboard & capture", "Zwischenablage & Bildschirmfoto"), "pearl-card-title").as(gtk.Widget));
        const switcher = gtk.StackSwitcher.new();
        switcher.setStack(self.stack);
        host.append(switcher.as(gtk.Widget));
        self.stack.as(gtk.Widget).setVexpand(1);
        self.stack.setVhomogeneous(0);
        host.append(self.stack.as(gtk.Widget));

        const clipboard_page = w.column(8);
        clipboard_page.as(gtk.Widget).setVexpand(1);
        _ = self.stack.addTitled(clipboard_page.as(gtk.Widget), "clipboard", tr("Clipboard", "Zwischenablage"));
        const filter = w.row(8);
        self.search.as(gtk.Widget).setHexpand(1);
        filter.append(self.search.as(gtk.Widget));
        try self.button(filter, tr("Clear history", "Verlauf löschen"), .clear);
        clipboard_page.append(filter.as(gtk.Widget));
        clipboard_page.append(self.hint.as(gtk.Widget));
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        scroll.setChild(self.list.as(gtk.Widget));
        clipboard_page.append(scroll.as(gtk.Widget));
        clipboard_page.append(self.clipboard_info.as(gtk.Widget));

        const capture_content = self.page("capture", tr("Capture", "Bildschirmfoto"));
        const capture_card = w.card();
        capture_content.append(capture_card.as(gtk.Widget));
        capture_card.append(w.label(tr("Screenshot", "Bildschirmfoto"), "pearl-card-title").as(gtk.Widget));
        capture_card.append(w.label(tr("Output crop includes visible overlapping windows. Coordinates are local to this output.", "Ausgabebereich enthält überlappende Fenster. Koordinaten gelten für diese Ausgabe."), "pearl-secondary").as(gtk.Widget));
        self.region.setPlaceholderText("x,y,width,height");
        w.name(self.region.as(gtk.Widget), tr("Output region in logical pixels", "Ausgabebereich in logischen Pixeln"));
        capture_card.append(self.region.as(gtk.Widget));
        const first = w.row(8);
        capture_card.append(first.as(gtk.Widget));
        try self.button(first, tr("Capture output", "Ausgabe aufnehmen"), .take);
        try self.button(first, tr("Capture region", "Bereich aufnehmen"), .region);
        try self.button(first, tr("Cancel", "Abbrechen"), .cancel);
        self.window_selector = gtk.DropDown.newFromStrings(@ptrCast(&[_:null]?[*:0]const u8{"No capturable windows"}));
        w.name(self.window_selector.as(gtk.Widget), "Isolated window source");
        capture_card.append(self.window_selector.as(gtk.Widget));
        try self.button(capture_card, "Capture isolated window", .window);
        capture_card.append(w.label("Isolated capture excludes overlapping windows. PNG export requires SDR color metadata; unsupported or undescribed sources are reported without exporting.", "pearl-secondary").as(gtk.Widget));
        self.picture.setCanShrink(1);
        self.picture.as(gtk.Widget).setSizeRequest(-1, 150);
        self.picture.setContentFit(.contain);
        self.picture.as(gtk.Widget).setVisible(0);
        capture_card.append(self.picture.as(gtk.Widget));
        const actions = w.row(8);
        capture_card.append(actions.as(gtk.Widget));
        try self.button(actions, tr("Save PNG", "PNG speichern"), .save);
        try self.button(actions, tr("Copy image", "Bild kopieren"), .copy);
        capture_card.append(self.info.as(gtk.Widget));

        self.connect(factory.as(object.Object), gtk.SignalListItemFactory.signals.setup.connect(factory, *View, setup, self, .{}));
        self.connect(factory.as(object.Object), gtk.SignalListItemFactory.signals.bind.connect(factory, *View, bind, self, .{}));
        self.connect(factory.as(object.Object), gtk.SignalListItemFactory.signals.teardown.connect(factory, *View, teardown, self, .{}));
        self.connect(search.as(object.Object), gtk.SearchEntry.signals.search_changed.connect(search, *View, changed, self, .{}));
        self.connect(search.as(object.Object), gtk.SearchEntry.signals.activate.connect(search, *View, entered, self, .{}));
        self.connect(list.as(object.Object), gtk.ListView.signals.activate.connect(list, *View, activated, self, .{}));
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        self.connect(keys.as(object.Object), gtk.EventControllerKey.signals.key_pressed.connect(keys, *View, key, self, .{}));
        search.as(gtk.Widget).addController(keys.as(gtk.EventController));
        if (search.as(gtk.Editable).getDelegate()) |delegate| if (object.ext.cast(gtk.Text, delegate)) |text| {
            self.connect(text.as(object.Object), gtk.Text.signals.preedit_changed.connect(text, *View, preeditChanged, self, .{}));
        };
        self.update();
        return self;
    }
    fn connect(self: *View, instance: *object.Object, id: c_ulong) void {
        self.connections[self.connection_count] = .{ .instance = instance, .id = id };
        self.connection_count += 1;
    }
    fn page(self: *View, name: [:0]const u8, title: [:0]const u8) *gtk.Box {
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        const content = w.column(16);
        scroll.setChild(content.as(gtk.Widget));
        _ = self.stack.addTitled(scroll.as(gtk.Widget), name, title);
        return content;
    }
    /// The clipboard page owns keyboard focus; `capture show` moves it afterwards.
    pub fn focus(self: *View) void {
        self.stack.setVisibleChildName("clipboard");
        _ = self.search.as(gtk.Widget).grabFocus();
    }
    pub fn showCapture(self: *View) void {
        self.stack.setVisibleChildName("capture");
        _ = self.region.as(gtk.Widget).grabFocus();
    }
    fn button(self: *View, parent: *gtk.Box, label: [:0]const u8, action: Action) !void {
        const b = try a.create(Button);
        errdefer a.destroy(b);
        const widget = gtk.Button.newWithLabel(label);
        _ = widget.as(object.Object).refSink();
        b.* = .{ .view = self, .widget = widget, .signal = 0, .action = action };
        try self.buttons.append(a, b);
        b.signal = gtk.Button.signals.clicked.connect(widget, *Button, clicked, b, .{});
        parent.append(widget.as(gtk.Widget));
    }
    fn clearButtons(buttons: *std.ArrayList(*Button)) void {
        for (buttons.items) |b| {
            object.signalHandlerDisconnect(b.widget.as(object.Object), b.signal);
            b.widget.unref();
            a.destroy(b);
        }
        buttons.clearRetainingCapacity();
    }
    pub fn destroy(self: *View) void {
        // Disconnect the factory first: teardown would otherwise reach freed rows.
        for (self.connections[0..self.connection_count]) |connection| {
            if (object.signalHandlerIsConnected(connection.instance, connection.id) != 0) object.signalHandlerDisconnect(connection.instance, connection.id);
        }
        self.connection_count = 0;
        for (self.rows.items) |row| {
            row.release();
            a.destroy(row);
        }
        self.rows.deinit(a);
        clearButtons(&self.buttons);
        self.buttons.deinit(a);
        self.freeRecords();
        if (self.query) |query| a.free(query);
        self.selection.unref();
        self.strings.unref();
        a.destroy(self);
    }
    fn clicked(_: *gtk.Button, b: *Button) callconv(.c) void {
        b.view.act(b.action) catch |err| report(if (b.action == .clear) b.view.clipboard_info else b.view.info, err);
    }
    fn copyClicked(_: *gtk.Button, row: *Row) callconv(.c) void {
        const self = row.view;
        const id = self.entryAt(row.item.getPosition()) orelse return;
        self.clipboard.select(id) catch |err| {
            report(self.clipboard_info, err);
            return;
        };
        self.dismiss(self.context);
    }
    fn removeClicked(_: *gtk.Button, row: *Row) callconv(.c) void {
        const self = row.view;
        const id = self.entryAt(row.item.getPosition()) orelse return;
        self.clipboard.delete(id) catch |err| report(self.clipboard_info, err);
    }
    fn report(label: *gtk.Label, err: anyerror) void {
        label.setText(switch (err) {
            error.InvalidRegion => tr("Enter a region inside this output: x,y,width,height", "Bereich innerhalb der Ausgabe eingeben: x,y,Breite,Höhe"),
            error.Conflict => tr("File already exists; choose another path using pearlctl", "Datei vorhanden; anderen Pfad mit pearlctl wählen"),
            else => tr("Action unavailable or failed. Try again.", "Aktion nicht verfügbar oder fehlgeschlagen. Erneut versuchen."),
        });
    }
    fn act(self: *View, action: Action) !void {
        switch (action) {
            .take => try self.take(self.context, null),
            .region => try self.take(self.context, std.mem.span(self.region.as(gtk.Editable).getText())),
            .window => {
                const index = self.window_selector.getSelected();
                if (index >= self.window_count) return error.WindowUnavailable;
                try self.capture.native.takeWindow(self.window_ids[index].slice());
            },
            .cancel => self.capture.cancel(),
            .save => try self.capture.save(self.capture.generation, null),
            .copy => try self.capture.copy(self.clipboard, self.capture.generation),
            .clear => self.clipboard.clear(),
        }
    }
    fn entryAt(self: *const View, position: c_uint) ?u64 {
        if (position >= self.visible_count) return null;
        return self.records[self.visible[position]].id;
    }
    fn recordAt(self: *const View, position: c_uint) ?*const Record {
        if (position >= self.visible_count) return null;
        return &self.records[self.visible[position]];
    }
    fn rowAt(self: *const View, item: *gtk.ListItem) ?*Row {
        for (self.rows.items) |row| if (row.item == item) return row;
        return null;
    }
    fn cursor(self: *View) Cursor {
        const position = self.selection.getSelected();
        if (position >= self.visible_count) return .{};
        return .{ .id = self.records[self.visible[position]].id, .position = position };
    }
    fn changed(_: *gtk.SearchEntry, self: *View) callconv(.c) void {
        if (self.query) |query| a.free(query);
        self.query = apps.fold(a, std.mem.span(self.search.as(gtk.Editable).getText())) catch null;
        self.publish(.{});
    }
    fn preeditChanged(_: *gtk.Text, preedit: [*:0]u8, self: *View) callconv(.c) void {
        self.composing = preedit[0] != 0;
    }
    fn entered(_: *gtk.SearchEntry, self: *View) callconv(.c) void {
        self.activate(self.selection.getSelected());
    }
    fn activated(_: *gtk.ListView, position: c_uint, self: *View) callconv(.c) void {
        self.activate(position);
    }
    /// Escape stays with the surface-level controller that dismisses the popup.
    fn key(_: *gtk.EventControllerKey, value: c_uint, _: c_uint, _: gdk.ModifierType, self: *View) callconv(.c) c_int {
        switch (value) {
            0xff52, 0xff54 => {
                if (self.visible_count == 0) return 1;
                const last: c_uint = @intCast(self.visible_count - 1);
                const old = @min(self.selection.getSelected(), last);
                const position = if (value == 0xff54) @min(old + 1, last) else old -| 1;
                self.selection.setSelected(position);
                self.list.scrollTo(position, .{}, null);
                return 1;
            },
            // Delete removes the entry instead of deleting a character of the filter.
            0xffff => {
                if (self.entryAt(self.selection.getSelected())) |id| self.clipboard.delete(id) catch |err| report(self.clipboard_info, err);
                return 1;
            },
            else => return 0,
        }
    }
    fn activate(self: *View, position: c_uint) void {
        if (self.composing) return;
        const id = self.entryAt(position) orelse return;
        self.clipboard.select(id) catch |err| {
            report(self.clipboard_info, err);
            return;
        };
        self.dismiss(self.context);
    }
    fn setup(_: *gtk.SignalListItemFactory, obj: *object.Object, self: *View) callconv(.c) void {
        const item = object.ext.cast(gtk.ListItem, obj).?;
        const row = a.create(Row) catch return;
        const card = w.column(6);
        card.as(gtk.Widget).addCssClass("pearl-list-row");
        const label = w.label("", "pearl-secondary");
        card.append(label.as(gtk.Widget));
        const image = gtk.Picture.new();
        image.setCanShrink(1);
        image.setContentFit(.contain);
        image.as(gtk.Widget).setSizeRequest(-1, 96);
        image.as(gtk.Widget).setVisible(0);
        w.name(image.as(gtk.Widget), tr("Clipboard image preview", "Bildvorschau der Zwischenablage"));
        card.append(image.as(gtk.Widget));
        const actions = w.row(6);
        const copy = gtk.Button.newWithLabel(tr("Copy", "Kopieren"));
        const remove = gtk.Button.newWithLabel(tr("Delete", "Löschen"));
        actions.append(copy.as(gtk.Widget));
        actions.append(remove.as(gtk.Widget));
        card.append(actions.as(gtk.Widget));
        item.setChild(card.as(gtk.Widget));
        row.* = .{ .view = self, .item = item, .label = label, .image = image, .copy = copy, .remove = remove, .copy_signal = 0, .remove_signal = 0 };
        row.copy_signal = gtk.Button.signals.clicked.connect(copy, *Row, copyClicked, row, .{});
        row.remove_signal = gtk.Button.signals.clicked.connect(remove, *Row, removeClicked, row, .{});
        self.rows.append(a, row) catch {
            row.release();
            a.destroy(row);
        };
    }
    fn bind(_: *gtk.SignalListItemFactory, obj: *object.Object, self: *View) callconv(.c) void {
        const item = object.ext.cast(gtk.ListItem, obj).?;
        const row = self.rowAt(item) orelse return;
        const record = self.recordAt(item.getPosition()) orelse return;
        row.label.setText(record.label);
        row.image.setPixbuf(record.image);
        row.image.as(gtk.Widget).setVisible(@intFromBool(record.image != null));
        item.setAccessibleLabel(record.label);
    }
    fn teardown(_: *gtk.SignalListItemFactory, obj: *object.Object, self: *View) callconv(.c) void {
        const item = object.ext.cast(gtk.ListItem, obj).?;
        const row = self.rowAt(item) orelse return;
        for (self.rows.items, 0..) |candidate, index| if (candidate == row) {
            _ = self.rows.orderedRemove(index);
            break;
        };
        // The row's widgets are already disposed here, and GObject dropped their
        // handlers with them; only the bookkeeping record is left to free.
        a.destroy(row);
    }
    fn decode(bytes: []const u8) ?*pixbuf.Pixbuf {
        const data = glib.Bytes.new(bytes.ptr, bytes.len);
        defer data.unref();
        const stream = gio.MemoryInputStream.newFromBytes(data);
        defer stream.unref();
        return pixbuf.Pixbuf.newFromStreamAtScale(stream.as(gio.InputStream), 160, 96, 1, null, null);
    }
    fn freeRecords(self: *View) void {
        for (self.records[0..self.record_count]) |*record| {
            a.free(record.label);
            a.free(record.folded);
            if (record.image) |image| image.unref();
        }
        self.record_count = 0;
    }
    fn rebuild(self: *View, keep: Cursor) void {
        self.freeRecords();
        if (!self.clipboard.locked) for (self.clipboard.entries.items) |entry| {
            if (self.record_count == self.records.len) break;
            const label = history.preview(a, if (entry.kind == .text) entry.bytes else tr("PNG image", "PNG-Bild")) catch continue;
            const folded = apps.fold(a, label) catch {
                a.free(label);
                continue;
            };
            self.records[self.record_count] = .{ .id = entry.id, .label = label, .folded = folded, .image = if (entry.kind == .png) decode(entry.bytes) else null };
            self.record_count += 1;
        };
        self.publish(keep);
    }
    fn publish(self: *View, keep: Cursor) void {
        self.visible_count = 0;
        for (self.records[0..self.record_count], 0..) |*record, index| {
            if (self.query) |query| if (query.len > 0 and std.mem.indexOf(u8, record.folded, query) == null) continue;
            self.visible[self.visible_count] = index;
            self.visible_count += 1;
        }
        var values: [history.entries_limit + 1:null]?[*:0]const u8 = @splat(null);
        var selected: ?c_uint = null;
        for (self.visible[0..self.visible_count], 0..) |index, position| {
            values[position] = self.records[index].label;
            if (keep.id) |id| {
                if (self.records[index].id == id) selected = @intCast(position);
            }
        }
        self.strings.splice(0, self.strings.as(gio.ListModel).getNItems(), @ptrCast(&values));
        const last: c_uint = if (self.visible_count == 0) 0 else @intCast(self.visible_count - 1);
        self.selection.setSelected(selected orelse @min(keep.position, last));
        self.hint.setText(if (self.record_count == 0) tr("Copy text or a PNG image to start. History is cleared when locking.", "Text oder PNG kopieren. Beim Sperren wird der Verlauf gelöscht.") else tr("No matching entries", "Keine passenden Einträge"));
        self.hint.as(gtk.Widget).setVisible(@intFromBool(self.visible_count == 0));
    }
    fn updateWindows(self: *View) void {
        var hash = std.hash.Wyhash.init(@intFromBool(self.capture.locked));
        for (self.capture.native.windows.items) |window| {
            hash.update(window.id.slice());
            hash.update(window.title.slice());
        }
        const stamp = hash.final();
        if (stamp == self.window_stamp) return;
        self.window_stamp = stamp;
        const old = if (self.window_selector.getSelected() < self.window_count) self.window_ids[self.window_selector.getSelected()] else @import("../services/policy.zig").Text(128){};
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const strings = gtk.StringList.new(null);
        defer strings.unref();
        self.window_count = 0;
        var selected: c_uint = 0;
        if (!self.capture.locked) for (self.capture.native.windows.items) |window| {
            if (!window.done or window.id.len == 0 or self.window_count == self.window_ids.len) continue;
            self.window_ids[self.window_count] = window.id;
            if (std.mem.eql(u8, old.slice(), window.id.slice())) selected = @intCast(self.window_count);
            const label = std.fmt.allocPrintSentinel(alloc, "{s} · {s}", .{ window.title.slice(), window.app_id.slice() }, 0) catch continue;
            strings.append(label);
            self.window_count += 1;
        };
        if (self.window_count == 0) strings.append("No capturable windows");
        self.window_selector.setModel(strings.as(gio.ListModel));
        self.window_selector.setSelected(selected);
    }
    pub fn update(self: *View) void {
        self.updateWindows();
        self.info.setText(if (self.capture.saved.len > 0) self.capture.saved.z() else self.capture.message);
        self.clipboard_info.setText(self.clipboard.message);
        const busy = self.capture.pending();
        for (self.buttons.items) |b| b.widget.as(gtk.Widget).setSensitive(@intFromBool(switch (b.action) {
            .window => !self.capture.locked and !busy and self.capture.native.windowAvailable() and self.window_count > 0,
            .take, .region => !self.capture.locked and !busy and self.capture.manager != null,
            .save, .copy => !self.capture.locked and self.capture.image != null and !busy,
            .cancel => busy,
            .clear => !self.clipboard.locked and self.clipboard.entries.items.len > 0,
        }));
        if (self.capture.image == null) {
            self.picture.setPaintable(null);
            self.picture.as(gtk.Widget).setVisible(0);
            self.image_generation = 0;
        } else if (self.image_generation != self.capture.generation) {
            const bytes = glib.Bytes.new(self.capture.image.?.ptr, self.capture.image.?.len);
            defer bytes.unref();
            if (gdk.Texture.newFromBytes(bytes, null)) |texture| {
                defer texture.unref();
                self.picture.setPaintable(texture.as(gdk.Paintable));
                self.picture.as(gtk.Widget).setVisible(1);
            }
            self.image_generation = self.capture.generation;
        }
        var hash = std.hash.Wyhash.init(@intFromBool(self.clipboard.locked));
        for (self.clipboard.entries.items) |entry| hash.update(std.mem.asBytes(&entry.id));
        const stamp = hash.final();
        if (stamp == self.stamp) return;
        self.stamp = stamp;
        self.rebuild(self.cursor());
    }
    /// Compiled only when called by the private integration control hook.
    pub fn testReport(self: *View, alloc: std.mem.Allocator, root: *gtk.Widget) ![]const u8 {
        if (!test_hooks) unreachable;
        const Probe = struct { id: u64, label: []const u8, selected: bool, row: ?Rect, copy: ?Rect, remove: ?Rect };
        var probes: std.ArrayList(Probe) = .empty;
        for (self.visible[0..self.visible_count], 0..) |index, position| {
            var probe: Probe = .{ .id = self.records[index].id, .label = self.records[index].label, .selected = self.selection.getSelected() == position, .row = null, .copy = null, .remove = null };
            for (self.rows.items) |candidate| if (candidate.item.getPosition() == position) {
                if (candidate.item.getChild()) |card| probe.row = bounds(card, root);
                probe.copy = bounds(candidate.copy.as(gtk.Widget), root);
                probe.remove = bounds(candidate.remove.as(gtk.Widget), root);
                break;
            };
            try probes.append(alloc, probe);
        }
        return std.json.Stringify.valueAlloc(alloc, .{
            .query = std.mem.span(self.search.as(gtk.Editable).getText()),
            .message = std.mem.span(self.clipboard_info.getText()),
            .hint = std.mem.span(self.hint.getText()),
            .hint_visible = self.hint.as(gtk.Widget).getVisible() != 0,
            .selected = self.selection.getSelected(),
            .rows = probes.items,
        }, .{});
    }
};
