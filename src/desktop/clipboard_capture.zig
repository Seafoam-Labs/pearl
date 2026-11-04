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
const presentation = @import("../services/clipboard/presentation.zig");
const history_limit = presentation.capacity;
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
    records: [history_limit]Record = undefined,
    record_count: usize = 0,
    visible: [history_limit]usize = undefined,
    visible_count: usize = 0,
    query: ?[:0]u8 = null,
    composing: bool = false,
    redacting: bool = false,
    stamp: u64 = 0,
    image_generation: u64 = 0,
    connections: [8]struct { instance: *object.Object, id: c_ulong } = undefined,
    connection_count: usize = 0,
    pub fn create(host: *gtk.Box, clipboard: *Clipboard, capture: *Capture, context: *anyopaque, take: @FieldType(View, "take"), dismiss: @FieldType(View, "dismiss")) !*View {
        const self = try a.create(View);
        const search = gtk.SearchEntry.new();
        search.setSearchDelay(0);
        search.setPlaceholderText(@import("i18n").dtr("pearl", "Filter clipboard history"));
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
        host.append(w.label(@import("i18n").dtr("pearl", "Clipboard & capture"), "pearl-card-title").as(gtk.Widget));
        const switcher = gtk.StackSwitcher.new();
        switcher.setStack(self.stack);
        host.append(switcher.as(gtk.Widget));
        self.stack.as(gtk.Widget).setVexpand(1);
        self.stack.setVhomogeneous(0);
        host.append(self.stack.as(gtk.Widget));

        const clipboard_page = w.column(8);
        clipboard_page.as(gtk.Widget).setVexpand(1);
        _ = self.stack.addTitled(clipboard_page.as(gtk.Widget), "clipboard", @import("i18n").dtr("pearl", "Clipboard"));
        const filter = w.row(8);
        self.search.as(gtk.Widget).setHexpand(1);
        filter.append(self.search.as(gtk.Widget));
        try self.button(filter, @import("i18n").dtr("pearl", "Clear history"), .clear);
        clipboard_page.append(filter.as(gtk.Widget));
        clipboard_page.append(self.hint.as(gtk.Widget));
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        scroll.setChild(self.list.as(gtk.Widget));
        clipboard_page.append(scroll.as(gtk.Widget));
        clipboard_page.append(self.clipboard_info.as(gtk.Widget));

        const capture_content = self.page("capture", @import("i18n").dtr("pearl", "Capture"));
        const capture_card = w.card();
        capture_content.append(capture_card.as(gtk.Widget));
        capture_card.append(w.label(@import("i18n").dtr("pearl", "Screenshot"), "pearl-card-title").as(gtk.Widget));
        capture_card.append(w.label(@import("i18n").dtr("pearl", "Output crop includes visible overlapping windows. Coordinates are local to this output."), "pearl-secondary").as(gtk.Widget));
        self.region.setPlaceholderText(@import("i18n").dtr("pearl", "x,y,width,height"));
        w.name(self.region.as(gtk.Widget), @import("i18n").dtr("pearl", "Output region in logical pixels"));
        capture_card.append(self.region.as(gtk.Widget));
        const first = w.row(8);
        capture_card.append(first.as(gtk.Widget));
        try self.button(first, @import("i18n").dtr("pearl", "Capture output"), .take);
        try self.button(first, @import("i18n").dtr("pearl", "Capture region"), .region);
        try self.button(first, @import("i18n").dtr("pearl", "Cancel"), .cancel);
        self.window_selector = gtk.DropDown.newFromStrings(@ptrCast(&[_:null]?[*:0]const u8{@import("i18n").dtr("pearl", "No capturable windows")}));
        w.name(self.window_selector.as(gtk.Widget), @import("i18n").dtr("pearl", "Isolated window source"));
        capture_card.append(self.window_selector.as(gtk.Widget));
        try self.button(capture_card, @import("i18n").dtr("pearl", "Capture isolated window"), .window);
        capture_card.append(w.label(@import("i18n").dtr("pearl", "Isolated capture excludes overlapping windows. PNG export requires SDR color metadata; unsupported or undescribed sources are reported without exporting."), "pearl-secondary").as(gtk.Widget));
        self.picture.setCanShrink(1);
        self.picture.as(gtk.Widget).setSizeRequest(-1, 150);
        self.picture.setContentFit(.contain);
        self.picture.as(gtk.Widget).setVisible(0);
        capture_card.append(self.picture.as(gtk.Widget));
        const actions = w.row(8);
        capture_card.append(actions.as(gtk.Widget));
        try self.button(actions, @import("i18n").dtr("pearl", "Save PNG"), .save);
        try self.button(actions, @import("i18n").dtr("pearl", "Copy image"), .copy);
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
        clipboard_page.as(gtk.Widget).addController(keys.as(gtk.EventController));
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
        if (self.query) |query| {
            std.crypto.secureZero(u8, query);
            a.free(query);
        }
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
            error.Busy => @import("i18n").dtr("pearl", "Clipboard storage is busy. Try again."),
            error.InvalidRegion => @import("i18n").dtr("pearl", "Enter a region inside this output: x,y,width,height"),
            error.Conflict => @import("i18n").dtr("pearl", "File already exists; choose another path using pearlctl"),
            else => @import("i18n").dtr("pearl", "Action unavailable or failed. Try again."),
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
            .clear => try self.clipboard.clear(),
        }
    }
    fn entryAt(self: *const View, position: c_uint) ?u64 {
        return presentation.entryId(self.records[0..self.record_count], self.visible[0..self.visible_count], position);
    }
    fn recordAt(self: *const View, position: c_uint) ?*const Record {
        if (position >= self.visible_count or self.visible[position] >= self.record_count) return null;
        return &self.records[self.visible[position]];
    }
    fn rowAt(self: *const View, item: *gtk.ListItem) ?*Row {
        for (self.rows.items) |row| if (row.item == item) return row;
        return null;
    }
    fn cursor(self: *View) Cursor {
        const position = self.selection.getSelected();
        return .{ .id = self.entryAt(position) orelse return .{}, .position = position };
    }
    fn changed(_: *gtk.SearchEntry, self: *View) callconv(.c) void {
        if (self.redacting) return;
        if (self.query) |query| {
            std.crypto.secureZero(u8, query);
            a.free(query);
        }
        self.query = apps.fold(a, std.mem.span(self.search.as(gtk.Editable).getText())) catch null;
        _ = self.refreshHistory(.{}, true);
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
                _ = self.refreshHistory(self.cursor(), false);
                const position = presentation.navigate(self.selection.getSelected(), self.visible_count, value == 0xff54) orelse return 1;
                self.selection.setSelected(@intCast(position));
                self.list.scrollTo(@intCast(position), .{}, null);
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
        w.name(image.as(gtk.Widget), @import("i18n").dtr("pearl", "Clipboard image preview"));
        card.append(image.as(gtk.Widget));
        const actions = w.row(6);
        const copy = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "Copy"));
        const remove = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "Delete"));
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
            std.crypto.secureZero(u8, record.label);
            std.crypto.secureZero(u8, record.folded);
            a.free(record.label);
            a.free(record.folded);
            if (record.image) |image| image.unref();
        }
        self.record_count = 0;
    }
    fn rebuild(self: *View, keep: Cursor, entries: []const @import("../services/clipboard/history.zig").Entry) void {
        self.freeRecords();
        for (entries) |entry| {
            if (self.record_count == self.records.len) break;
            const label = history.preview(a, if (entry.kind == .text) entry.bytes else @import("i18n").dtr("pearl", "PNG image")) catch continue;
            const folded = apps.fold(a, label) catch {
                a.free(label);
                continue;
            };
            self.records[self.record_count] = .{ .id = entry.id, .label = label, .folded = folded, .image = if (entry.kind == .png) decode(entry.bytes) else null };
            self.record_count += 1;
        }
        self.publish(keep);
    }
    fn publish(self: *View, keep: Cursor) void {
        if (!self.clipboard.accessible()) {
            self.redact();
            return;
        }
        self.visible_count = presentation.filter(self.records[0..self.record_count], self.query orelse "", &self.visible).len;
        var values: [history_limit + 1:null]?[*:0]const u8 = @splat(null);
        for (self.visible[0..self.visible_count], 0..) |index, position| {
            values[position] = self.records[index].label;
        }
        self.strings.splice(0, self.strings.as(gio.ListModel).getNItems(), @ptrCast(&values));
        const selected = presentation.selection(self.records[0..self.record_count], self.visible[0..self.visible_count], keep.id, keep.position);
        self.selection.setSelected(if (selected) |position| @intCast(position) else std.math.maxInt(c_uint));
        self.hint.setText(if (self.record_count == 0) @import("i18n").dtr("pearl", "Copy text or a PNG image to start. Text can be restored for seven days. Locking hides history; PNG images stay in memory.") else @import("i18n").dtr("pearl", "No matching entries"));
        self.hint.as(gtk.Widget).setVisible(@intFromBool(self.visible_count == 0));
    }
    fn refreshHistory(self: *View, keep: Cursor, filter_changed: bool) usize {
        // One maintenance attempt, shared by normal updates, search and keys.
        // Its notification may synchronously redact this view.
        const entries = self.clipboard.entries();
        const accessible = self.clipboard.accessible();
        self.clipboard_info.setText(self.clipboard.message);
        const stamp = presentation.stamp(entries, accessible);
        if (stamp != self.stamp) {
            if (!accessible) {
                self.redact();
            } else {
                self.stamp = stamp;
                self.rebuild(keep, entries);
            }
        } else if (filter_changed and accessible) self.publish(keep);
        return entries.len;
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
        const entry_count = self.refreshHistory(self.cursor(), false);
        self.updateWindows();
        self.info.setText(if (self.capture.saved.len > 0) self.capture.saved.z() else self.capture.message);
        self.clipboard_info.setText(self.clipboard.message);
        const busy = self.capture.pending();
        for (self.buttons.items) |b| b.widget.as(gtk.Widget).setSensitive(@intFromBool(switch (b.action) {
            .window => !self.capture.locked and !busy and self.capture.native.windowAvailable() and self.window_count > 0,
            .take, .region => !self.capture.locked and !busy and self.capture.manager != null,
            .save, .copy => !self.capture.locked and self.capture.image != null and !busy,
            .cancel => busy,
            .clear => self.clipboard.accessible() and entry_count > 0,
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
    }
    /// Called synchronously when a privacy gate closes, including from a UI
    /// callback. Keep the view alive until normal reconciliation destroys it.
    pub fn redact(self: *View) void {
        self.redacting = true;
        defer self.redacting = false;
        self.composing = false;
        // Transient maintenance failure hides previews, but is not a privacy
        // gate closing. Keep the user's filter for a subsequent retry.
        const keep_query = !self.clipboard.locked and !self.clipboard.stopping and !self.clipboard.ambiguous and self.clipboard.device != null and
            (if (self.clipboard.session) |*session| session.maintenance_busy and session.available() else false);
        if (!keep_query) {
            if (self.query) |query| {
                std.crypto.secureZero(u8, query);
                a.free(query);
                self.query = null;
            }
            self.search.as(gtk.Editable).setText("");
        }
        self.strings.splice(0, self.strings.as(gio.ListModel).getNItems(), null);
        for (self.rows.items) |row| {
            row.label.setText("");
            row.image.setPaintable(null);
        }
        self.freeRecords();
        self.visible_count = 0;
        self.stamp = presentation.stamp(&.{}, false);
        self.clipboard_info.setText("");
        self.hint.setText(@import("i18n").dtr("pearl", "History is hidden while clipboard access is paused"));
        self.hint.as(gtk.Widget).setVisible(1);
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

var panel_test_display: ?bool = null;
const PanelTest = struct {
    fixture: @import("../testing/clipboard.zig").Fixture,
    capture: Capture,
    host: *gtk.Box,
    view: *View,

    fn init(self: *PanelTest) !void {
        // These widget tests never start clipboard capture or touch the desktop
        // selection. Without a display the service regressions still run.
        // Cache failure too: GTK cannot safely be initialized again after a
        // failed initCheck in the same test process.
        if (panel_test_display == null) panel_test_display = gtk.initCheck() != 0 and gdk.Display.getDefault() != null;
        if (!panel_test_display.?) return error.SkipZigTest;
        try self.fixture.init();
        errdefer self.fixture.deinit();
        _ = try self.fixture.copy("old preview", 100);
        _ = try self.fixture.copy("live preview", 200);
        self.fixture.clipboard.test_time = @import("../testing/clipboard.zig").at(100 + 604799);
        self.capture = .{ .app = undefined, .display = undefined, .context = self, .changed = noop };
        self.host = gtk.Box.new(.vertical, 0);
        _ = self.host.as(object.Object).refSink();
        errdefer self.host.unref();
        self.view = try View.create(self.host, &self.fixture.clipboard, &self.capture, self, take, noop);
        self.fixture.context = self.view;
        self.fixture.on_change = changed;
        self.view.search.as(gtk.Editable).setText("preview");
        View.changed(self.view.search, self.view);
    }
    fn deinit(self: *PanelTest) void {
        self.fixture.on_change = null;
        self.view.destroy();
        self.host.unref();
        self.fixture.deinit();
    }
    fn changed(context: *anyopaque) void {
        const view: *View = @ptrCast(@alignCast(context));
        if (!view.clipboard.accessible()) view.redact();
    }
    fn noop(_: *anyopaque) void {}
    fn take(_: *anyopaque, _: ?[]const u8) anyerror!void {
        return error.Unavailable;
    }
};

test "open clipboard panel expires cached rows on filtering and navigation without rebuilding unchanged history" {
    const t = std.testing;
    for ([_]bool{ false, true }) |navigate| {
        var panel: PanelTest = undefined;
        try panel.init();
        defer panel.deinit();
        const view = panel.view;
        try t.expectEqual(@as(usize, 2), view.visible_count);
        const label = view.records[0].label.ptr;
        const revision = panel.fixture.clipboard.session.?.model.generation;
        View.changed(view.search, view);
        try t.expectEqual(label, view.records[0].label.ptr);
        try t.expectEqual(revision, panel.fixture.clipboard.session.?.model.generation);
        _ = View.key(undefined, 0xff54, 0, .{}, view);
        try t.expectEqual(@as(c_uint, 1), view.selection.getSelected());
        try t.expectEqual(label, view.records[0].label.ptr);
        panel.fixture.clipboard.test_time = @import("../testing/clipboard.zig").at(100 + 604800);
        if (navigate) {
            _ = View.key(undefined, 0xff52, 0, .{}, view);
        } else View.changed(view.search, view);
        try t.expectEqual(@as(usize, 1), view.record_count);
        try t.expectEqual(@as(usize, 1), view.visible_count);
        try t.expectEqualStrings("live preview", view.records[0].label);
        try t.expectEqualStrings("preview", std.mem.span(view.search.as(gtk.Editable).getText()));
        try t.expectEqual(@as(c_uint, 0), view.selection.getSelected());
        try t.expectEqual(@as(usize, 1), panel.fixture.notifications);
    }
}

test "open clipboard panel synchronously redacts Busy and allocation failures from reads and selection" {
    const t = std.testing;
    for (0..4) |mode| {
        var panel: PanelTest = undefined;
        try panel.init();
        defer panel.deinit();
        const view = panel.view;
        const id = view.records[1].id;
        var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
        if (mode < 2) {
            try panel.fixture.blockRemoval();
        } else panel.fixture.clipboard.session.?.allocator = failing.allocator();
        defer panel.fixture.clipboard.session.?.allocator = t.allocator;
        panel.fixture.clipboard.test_time = @import("../testing/clipboard.zig").at(100 + 604800);
        if (mode % 2 == 0) {
            _ = panel.fixture.clipboard.entries();
        } else try t.expectError(if (mode < 2) error.Busy else error.OutOfMemory, panel.fixture.clipboard.select(id));
        // No main-loop iteration, worker completion or subsequent update occurs.
        try t.expectEqual(@as(usize, 1), panel.fixture.notifications);
        try t.expectEqual(@as(usize, 0), view.record_count);
        try t.expectEqual(@as(usize, 0), view.visible_count);
        try t.expectEqual(@as(c_uint, 0), view.strings.as(gio.ListModel).getNItems());
        try t.expectEqualStrings("preview", std.mem.span(view.search.as(gtk.Editable).getText()));
        // A real privacy gate still wipes the filter as well as the previews.
        panel.fixture.clipboard.locked = true;
        panel.fixture.clipboard.session.?.setLocked(true);
        view.redact();
        try t.expectEqualStrings("", std.mem.span(view.search.as(gtk.Editable).getText()));
        try t.expect(view.query == null);
    }
}
