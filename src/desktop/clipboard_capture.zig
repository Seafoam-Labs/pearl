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
const Clipboard = @import("../services/clipboard.zig").Clipboard;
const Capture = @import("../services/capture.zig").Capture;
const a = std.heap.c_allocator;
const Action = enum { take, region, window, cancel, save, copy, clear, select, delete };
const Button = struct { view: *View, widget: *gtk.Button, signal: c_ulong, action: Action, id: u64 };
pub const View = struct {
    clipboard: *Clipboard,
    capture: *Capture,
    context: *anyopaque,
    take: *const fn (*anyopaque, ?[]const u8) anyerror!void,
    host: *gtk.Box,
    stack: *gtk.Stack,
    list: *gtk.Box,
    info: *gtk.Label,
    clipboard_info: *gtk.Label,
    region: *gtk.Entry,
    window_selector: *gtk.DropDown = undefined,
    window_ids: [256]@import("../services/policy.zig").Text(128) = @splat(.{}),
    window_count: usize = 0,
    window_stamp: u64 = 0,
    picture: *gtk.Picture,
    buttons: std.ArrayList(*Button) = .empty,
    rows: std.ArrayList(*Button) = .empty,
    stamp: u64 = 0,
    image_generation: u64 = 0,
    pub fn create(host: *gtk.Box, clipboard: *Clipboard, capture: *Capture, context: *anyopaque, take: @FieldType(View, "take")) !*View {
        const self = try a.create(View);
        self.* = .{ .clipboard = clipboard, .capture = capture, .context = context, .take = take, .host = host, .stack = gtk.Stack.new(), .list = w.column(8), .info = w.label("", "pearl-secondary"), .clipboard_info = w.label("", "pearl-secondary"), .region = gtk.Entry.new(), .picture = gtk.Picture.new() };
        host.append(w.label(tr("Clipboard & capture", "Zwischenablage & Bildschirmfoto"), "pearl-card-title").as(gtk.Widget));
        const switcher = gtk.StackSwitcher.new();
        switcher.setStack(self.stack);
        host.append(switcher.as(gtk.Widget));
        self.stack.as(gtk.Widget).setVexpand(1);
        self.stack.setVhomogeneous(0);
        host.append(self.stack.as(gtk.Widget));
        const history_content = self.page("clipboard", tr("Clipboard", "Zwischenablage"));
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
        try self.button(first, tr("Capture output", "Ausgabe aufnehmen"), .take, 0, false);
        try self.button(first, tr("Capture region", "Bereich aufnehmen"), .region, 0, false);
        try self.button(first, tr("Cancel", "Abbrechen"), .cancel, 0, false);
        self.window_selector = gtk.DropDown.newFromStrings(@ptrCast(&[_:null]?[*:0]const u8{"No capturable windows"}));
        w.name(self.window_selector.as(gtk.Widget), "Isolated window source");
        capture_card.append(self.window_selector.as(gtk.Widget));
        try self.button(capture_card, "Capture isolated window", .window, 0, false);
        capture_card.append(w.label("Isolated capture excludes overlapping windows. PNG export requires SDR color metadata; unsupported or undescribed sources are reported without exporting.", "pearl-secondary").as(gtk.Widget));
        self.picture.setCanShrink(1);
        self.picture.as(gtk.Widget).setSizeRequest(-1, 150);
        self.picture.setContentFit(.contain);
        self.picture.as(gtk.Widget).setVisible(0);
        capture_card.append(self.picture.as(gtk.Widget));
        const actions = w.row(8);
        capture_card.append(actions.as(gtk.Widget));
        try self.button(actions, tr("Save PNG", "PNG speichern"), .save, 0, false);
        try self.button(actions, tr("Copy image", "Bild kopieren"), .copy, 0, false);
        capture_card.append(self.info.as(gtk.Widget));
        const history = w.card();
        history_content.append(history.as(gtk.Widget));
        history.append(w.label(tr("Clipboard history", "Zwischenablageverlauf"), "pearl-card-title").as(gtk.Widget));
        history.append(self.clipboard_info.as(gtk.Widget));
        try self.button(history, tr("Clear history", "Verlauf löschen"), .clear, 0, false);
        history.append(self.list.as(gtk.Widget));
        self.update();
        return self;
    }
    fn page(self: *View, name: [:0]const u8, title: [:0]const u8) *gtk.Box {
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        const content = w.column(16);
        scroll.setChild(content.as(gtk.Widget));
        _ = self.stack.addTitled(scroll.as(gtk.Widget), name, title);
        return content;
    }
    pub fn showCapture(self: *View) void {
        self.stack.setVisibleChildName("capture");
        _ = self.region.as(gtk.Widget).grabFocus();
    }
    fn thumbnail(parent: *gtk.Box, input: []const u8) void {
        const bytes = glib.Bytes.new(input.ptr, input.len);
        defer bytes.unref();
        const stream = gio.MemoryInputStream.newFromBytes(bytes);
        defer stream.unref();
        const image = pixbuf.Pixbuf.newFromStreamAtScale(stream.as(gio.InputStream), 160, 96, 1, null, null) orelse return;
        defer image.unref();
        const picture = gtk.Picture.newForPixbuf(image);
        picture.setCanShrink(1);
        picture.setContentFit(.contain);
        picture.as(gtk.Widget).setSizeRequest(-1, 96);
        w.name(picture.as(gtk.Widget), tr("Clipboard image preview", "Bildvorschau der Zwischenablage"));
        parent.append(picture.as(gtk.Widget));
    }
    fn button(self: *View, parent: *gtk.Box, label: [:0]const u8, action: Action, id: u64, row: bool) !void {
        const b = try a.create(Button);
        errdefer a.destroy(b);
        const widget = gtk.Button.newWithLabel(label);
        _ = widget.as(object.Object).refSink();
        b.* = .{ .view = self, .widget = widget, .signal = 0, .action = action, .id = id };
        try (if (row) &self.rows else &self.buttons).append(a, b);
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
        clearButtons(&self.rows);
        clearButtons(&self.buttons);
        self.rows.deinit(a);
        self.buttons.deinit(a);
        a.destroy(self);
    }
    fn clicked(_: *gtk.Button, b: *Button) callconv(.c) void {
        const self = b.view;
        self.act(b.action, b.id) catch |err| {
            const feedback = if (b.action == .select or b.action == .delete or b.action == .clear) self.clipboard_info else self.info;
            feedback.setText(switch (err) {
                error.InvalidRegion => tr("Enter a region inside this output: x,y,width,height", "Bereich innerhalb der Ausgabe eingeben: x,y,Breite,Höhe"),
                error.Conflict => tr("File already exists; choose another path using pearlctl", "Datei vorhanden; anderen Pfad mit pearlctl wählen"),
                else => tr("Action unavailable or failed. Try again.", "Aktion nicht verfügbar oder fehlgeschlagen. Erneut versuchen."),
            });
        };
    }
    fn act(self: *View, action: Action, id: u64) !void {
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
            .select => try self.clipboard.select(id),
            .delete => try self.clipboard.delete(id),
        }
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
            else => true,
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
        clearButtons(&self.rows);
        while (self.list.as(gtk.Widget).getFirstChild()) |child| self.list.remove(child);
        if (self.clipboard.locked) return;
        if (self.clipboard.entries.items.len == 0) self.list.append(w.label(tr("Copy text or a PNG image to start. History is cleared when locking.", "Text oder PNG kopieren. Beim Sperren wird der Verlauf gelöscht."), "pearl-secondary").as(gtk.Widget));
        for (self.clipboard.entries.items) |entry| {
            const card = w.column(6);
            self.list.append(card.as(gtk.Widget));
            const preview = @import("../services/clipboard_policy.zig").preview(a, if (entry.kind == .text) entry.bytes else "PNG image") catch continue;
            defer a.free(preview);
            card.append(w.label(preview, "pearl-secondary").as(gtk.Widget));
            if (entry.kind == .png) thumbnail(card, entry.bytes);
            const row = w.row(6);
            card.append(row.as(gtk.Widget));
            self.button(row, tr("Copy", "Kopieren"), .select, entry.id, true) catch {};
            self.button(row, tr("Delete", "Löschen"), .delete, entry.id, true) catch {};
        }
    }
};
