//! Schema-driven replacement for the Aqueous settings application.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const glib = @import("glib2");
const object = @import("gobject2");
const Client = @import("../config/aqueous_client.zig").Client;
const m = @import("../config/aqueous_model.zig");
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;
const Signals = struct {
    items: std.ArrayList(struct { instance: *object.Object, id: c_ulong }) = .empty,
    fn add(self: *Signals, instance: *object.Object, id: c_ulong) void {
        _ = instance.ref();
        self.items.append(a, .{ .instance = instance, .id = id }) catch {
            object.signalHandlerDisconnect(instance, id);
            instance.unref();
        };
    }
    fn clear(self: *Signals) void {
        // Disconnect all callbacks before releasing any emitter: disposing one
        // GTK child can emit signals on another child retained by focus state.
        for (self.items.items) |item| object.signalHandlerDisconnect(item.instance, item.id);
        for (self.items.items) |item| item.instance.unref();
        self.items.deinit(a);
        self.items = .empty;
    }
};
const Editor = struct { view: *View, field: m.Value, widget: *gtk.Widget, record: ?*gtk.Button = null };
const Monitor = struct { view: *View, id: []const u8, name: []const u8, x: *gtk.SpinButton, y: *gtk.SpinButton, scale: *gtk.SpinButton, transform: *gtk.DropDown, mode: *gtk.Entry };
pub const View = struct {
    host: *gtk.Box,
    client: *Client,
    arena: std.heap.ArenaAllocator,
    content: *gtk.Box,
    message: *gtk.Label,
    request_buffer: ?*gtk.TextBuffer = null,
    raw_buffer: ?*gtk.TextBuffer = null,
    raw_file: ?*gtk.DropDown = null,
    filling: bool = true,
    version: u64 = 0,
    revision: u64 = 0,
    buttons: [3]*gtk.Button,
    preview_buttons: [2]*gtk.Button,
    window: *gtk.Window,
    editors: std.ArrayList(*Editor) = .empty,
    recording: ?*Editor = null,
    inhibited: ?*gdk.Toplevel = null,
    record_timer: c_uint = 0,
    record_deadline: i64 = 0,
    keys: *gtk.EventControllerKey = undefined,
    notebook: ?*gtk.Notebook = null,
    page_index: c_int = 0,
    reload_button: *gtk.Button,
    root_signals: Signals = .{},
    form_signals: Signals = .{},
    pub fn create(host: *gtk.Box, client: *Client, window: *gtk.Window) !*View {
        const self = try a.create(View);
        host.append(w.label("Aqueous settings", "pearl-title").as(gtk.Widget));
        host.append(w.label("Layouts, windows, input and your desktop appearance", "pearl-secondary").as(gtk.Widget));
        const content = w.column(12);
        content.as(gtk.Widget).setVexpand(1);
        host.append(content.as(gtk.Widget));
        const message = w.label("Loading settings…", "pearl-secondary");
        host.append(message.as(gtk.Widget));
        const actions = w.row(8);
        host.append(actions.as(gtk.Widget));
        const refresh = gtk.Button.newWithLabel("Refresh");
        actions.append(refresh.as(gtk.Widget));
        const discard = gtk.Button.newWithLabel("Discard draft");
        actions.append(discard.as(gtk.Widget));
        const rebase = gtk.Button.newWithLabel("Rebase draft");
        actions.append(rebase.as(gtk.Widget));
        const validate = gtk.Button.newWithLabel("Validate");
        actions.append(validate.as(gtk.Widget));
        const apply = gtk.Button.newWithLabel("Apply & save");
        actions.append(apply.as(gtk.Widget));
        apply.as(gtk.Widget).addCssClass("pearl-primary");
        const preview_actions = w.row(8);
        host.append(preview_actions.as(gtk.Widget));
        const keep = gtk.Button.newWithLabel("Keep displays");
        const revert = gtk.Button.newWithLabel("Revert displays");
        const reload = gtk.Button.newWithLabel("Retry compositor reload");
        preview_actions.append(reload.as(gtk.Widget));
        preview_actions.append(keep.as(gtk.Widget));
        preview_actions.append(revert.as(gtk.Widget));
        self.* = .{ .host = host, .client = client, .arena = .init(a), .content = content, .message = message, .buttons = .{ refresh, validate, apply }, .preview_buttons = .{ keep, revert }, .reload_button = reload, .window = window };
        self.root_signals.add(refresh.as(object.Object), gtk.Button.signals.clicked.connect(refresh, *View, refreshed, self, .{}));
        self.root_signals.add(discard.as(object.Object), gtk.Button.signals.clicked.connect(discard, *View, discarded, self, .{}));
        self.root_signals.add(validate.as(object.Object), gtk.Button.signals.clicked.connect(validate, *View, validated, self, .{}));
        self.root_signals.add(apply.as(object.Object), gtk.Button.signals.clicked.connect(apply, *View, applied, self, .{}));
        self.root_signals.add(rebase.as(object.Object), gtk.Button.signals.clicked.connect(rebase, *View, rebased, self, .{}));
        self.root_signals.add(keep.as(object.Object), gtk.Button.signals.clicked.connect(keep, *View, kept, self, .{}));
        self.root_signals.add(revert.as(object.Object), gtk.Button.signals.clicked.connect(revert, *View, reverted, self, .{}));
        self.root_signals.add(reload.as(object.Object), gtk.Button.signals.clicked.connect(reload, *View, reloaded, self, .{}));
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        self.keys = keys;
        self.root_signals.add(keys.as(object.Object), gtk.EventControllerKey.signals.key_pressed.connect(keys, *View, recorded, self, .{}));
        host.as(gtk.Widget).addController(keys.as(gtk.EventController));
        self.build() catch |err| self.fail(err);
        self.update();
        if (client.job == null) client.begin(.refresh) catch |err| self.fail(err);
        return self;
    }
    pub fn destroy(self: *View) void {
        self.stopRecording();
        self.form_signals.clear();
        self.root_signals.clear();
        self.host.as(gtk.Widget).removeController(self.keys.as(gtk.EventController));
        if (self.client.previewing()) self.client.choose(false) catch {};
        self.filling = true;
        while (self.host.as(gtk.Widget).getFirstChild()) |c| self.host.remove(c);
        self.arena.deinit();
        a.destroy(self);
    }
    fn z(self: *View, text: []const u8) [:0]const u8 {
        return self.arena.allocator().dupeZ(u8, text) catch "";
    }
    fn page(self: *View, notebook: *gtk.Notebook, title: []const u8) *gtk.Box {
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        const box = w.column(16);
        inline for (.{ gtk.Widget.setMarginStart, gtk.Widget.setMarginEnd, gtk.Widget.setMarginTop, gtk.Widget.setMarginBottom }) |set| set(box.as(gtk.Widget), 12);
        scroll.setChild(box.as(gtk.Widget));
        _ = notebook.appendPage(scroll.as(gtk.Widget), gtk.Label.new(self.z(title)).as(gtk.Widget));
        return box;
    }
    fn build(self: *View) !void {
        self.stopRecording();
        self.filling = true;
        defer self.filling = false;
        self.form_signals.clear();
        self.notebook = null;
        while (self.content.as(gtk.Widget).getFirstChild()) |c| self.content.remove(c);
        _ = self.arena.reset(.retain_capacity);
        self.editors = .empty;
        self.request_buffer = null;
        self.raw_buffer = null;
        self.raw_file = null;
        self.version = self.client.version;
        self.revision = self.client.revision;
        if (self.client.live == null) return;
        const alloc = self.arena.allocator();
        // UI metadata must not borrow a snapshot replaced by a background refresh.
        const snapshot = try m.parse(alloc, try std.json.Stringify.valueAlloc(alloc, self.client.baseValue(), .{}), m.max_response);
        const notebook = gtk.Notebook.new();
        self.notebook = notebook;
        notebook.setScrollable(1);
        notebook.as(gtk.Widget).setVexpand(1);
        self.content.append(notebook.as(gtk.Widget));
        self.form_signals.add(notebook.as(object.Object), gtk.Notebook.signals.switch_page.connect(notebook, *View, switched, self, .{}));
        const categories = [_][]const u8{ "appearance", "layouts", "input", "keybinds", "rules", "displays" };
        const titles = [_][]const u8{ "Appearance", "Layouts", "Input", "Keybindings", "Rules", "Displays" };
        const draft = m.parse(alloc, self.client.draft orelse try self.client.emptyDraft(alloc), m.max_request) catch m.Value.null;
        for (categories, titles) |category, title| {
            const box = self.page(notebook, title);
            if (std.mem.eql(u8, category, "appearance")) {
                try self.inventory(box, self.client.value(), "desktop_typography", "Desktop font synchronization");
                try self.inventory(box, self.client.value(), "desktop_cursor", "Desktop cursor synchronization");
            }
            if (std.mem.eql(u8, category, "displays")) {
                box.append(w.label("Apply previews connected displays for 15 seconds. Keep saves; Revert, timeout or closing Pearl restores unchanged preview displays. Mirroring, custom modes and raw display policy changes cannot be previewed.", "pearl-secondary").as(gtk.Widget));
                try self.inventory(box, snapshot, "monitors", "Configured displays (including offline outputs)");
                try self.inventory(box, snapshot, "live_outputs", "Connected displays and modes");
                for (m.list(m.get(snapshot, "monitors"))) |monitor| try self.monitorEditor(box, monitor, false);
                for (m.list(m.get(snapshot, "live_outputs"))) |monitor| {
                    var configured = false;
                    for (m.list(m.get(snapshot, "monitors"))) |existing| if (std.mem.eql(u8, m.str(m.get(existing, "name")), m.str(m.get(monitor, "name")))) {
                        configured = true;
                        break;
                    };
                    if (!configured) try self.monitorEditor(box, monitor, true);
                }
            }
            if (std.mem.eql(u8, category, "keybinds")) {
                box.append(w.label("Enter chords such as Super+Return, separated by commas. Record waits for Aqueous to inhibit shortcuts. Escape cancels. Custom bindings are available in Advanced.", "pearl-secondary").as(gtk.Widget));
                try self.inventory(box, snapshot, "custom_keybinds", "Custom bindings");
            }
            if (std.mem.eql(u8, category, "rules")) try self.inventory(box, snapshot, "window_rules", "Window rules");
            if (std.mem.eql(u8, category, "layouts")) {
                try self.inventory(box, snapshot, "snap_zones", "Snap zones");
                try self.inventory(box, snapshot, "snap_layouts", "Snap layouts");
            }
            for (m.list(m.get(snapshot, "fields"))) |field| {
                if (!std.mem.eql(u8, m.str(m.get(field, "category")), category)) continue;
                var value = m.get(field, "value");
                for (m.list(m.get(draft, "changes"))) |c| if (std.mem.eql(u8, m.str(m.get(c, "id")), m.str(m.get(field, "id")))) {
                    value = m.get(c, "value");
                    break;
                };
                const row = w.column(4);
                box.append(row.as(gtk.Widget));
                const label = w.label(self.z(m.str(m.get(field, "label"))), null);
                row.append(label.as(gtk.Widget));
                row.as(gtk.Widget).setTooltipText(self.z(m.str(m.get(field, "description"))));
                const editor = try alloc.create(Editor);
                editor.* = .{ .view = self, .field = field, .widget = undefined };
                const kind = m.str(m.get(field, "type"));
                if (std.mem.eql(u8, kind, "boolean")) {
                    const input = gtk.CheckButton.new();
                    input.setActive(@intFromBool(value == .bool and value.bool));
                    editor.widget = input.as(gtk.Widget);
                    self.form_signals.add(input.as(object.Object), gtk.CheckButton.signals.toggled.connect(input, *Editor, toggled, editor, .{}));
                } else if (std.mem.eql(u8, kind, "integer") or std.mem.eql(u8, kind, "double")) {
                    const input = gtk.SpinButton.newWithRange(number(m.get(field, "min"), -1000000), number(m.get(field, "max"), 1000000), if (std.mem.eql(u8, kind, "integer")) 1 else 0.01);
                    input.setDigits(if (std.mem.eql(u8, kind, "integer")) 0 else 3);
                    input.setValue(number(value, 0));
                    editor.widget = input.as(gtk.Widget);
                    self.form_signals.add(input.as(object.Object), gtk.SpinButton.signals.value_changed.connect(input, *Editor, spun, editor, .{}));
                } else if (std.mem.eql(u8, kind, "select")) {
                    const opts = m.list(m.get(field, "options"));
                    const strings = try alloc.allocSentinel(?[*:0]const u8, opts.len, null);
                    var selected_index: c_uint = 0;
                    for (opts, 0..) |option, i| {
                        strings[i] = self.z(m.str(option));
                        if (m.equal(option, value)) selected_index = @intCast(i);
                    }
                    const input = gtk.DropDown.newFromStrings(@ptrCast(strings.ptr));
                    input.setSelected(selected_index);
                    editor.widget = input.as(gtk.Widget);
                    self.form_signals.add(input.as(object.Object), object.Object.signals.notify.connect(input.as(object.Object), *Editor, selected, editor, .{ .detail = "selected" }));
                } else {
                    const input = gtk.Entry.new();
                    input.setMaxLength(8192);
                    var text = m.str(value);
                    if (value == .array) {
                        var joined: std.ArrayList(u8) = .empty;
                        for (value.array.items, 0..) |item, i| {
                            if (i != 0) try joined.appendSlice(alloc, ", ");
                            try joined.appendSlice(alloc, m.str(item));
                        }
                        text = joined.items;
                    }
                    input.as(gtk.Editable).setText(self.z(text));
                    editor.widget = input.as(gtk.Widget);
                    self.form_signals.add(input.as(object.Object), gtk.Editable.signals.changed.connect(input.as(gtk.Editable), *Editor, edited, editor, .{}));
                }
                w.name(editor.widget, self.z(m.str(m.get(field, "label"))));
                row.append(editor.widget);
                try self.editors.append(alloc, editor);
                if (std.mem.eql(u8, category, "keybinds") and std.mem.eql(u8, kind, "string_list")) {
                    const record_button = gtk.Button.newWithLabel("Record shortcut");
                    row.append(record_button.as(gtk.Widget));
                    editor.record = record_button;
                    self.form_signals.add(record_button.as(object.Object), gtk.Button.signals.clicked.connect(record_button, *Editor, recordClicked, editor, .{}));
                }
                // Raw edits own the whole file; typed widgets cannot obscure them.
                row.as(gtk.Widget).setSensitive(@intFromBool(draft == .object and m.get(m.get(draft, "raw_files"), m.str(m.get(field, "file"))) == .null));
            }
        }
        const advanced = self.page(notebook, "Advanced");
        advanced.append(w.label("Raw edits are retained as you type, including invalid TOML. A file cannot have both raw and structured edits; resolve overlaps in the request below.", "pearl-secondary").as(gtk.Widget));
        self.raw_file = gtk.DropDown.newFromStrings(@ptrCast(&[_:null]?[*:0]const u8{ "wm", "layout", "input", "outputs", "rules", "appearance" }));
        advanced.append(self.raw_file.?.as(gtk.Widget));
        self.raw_buffer = textArea(advanced, "Raw Aqueous TOML", 220);
        self.loadRaw();
        self.form_signals.add(self.raw_buffer.?.as(object.Object), gtk.TextBuffer.signals.insert_text.connect(self.raw_buffer.?, *View, inserting, self, .{}));
        self.form_signals.add(self.raw_buffer.?.as(object.Object), gtk.TextBuffer.signals.changed.connect(self.raw_buffer.?, *View, rawEdited, self, .{}));
        self.form_signals.add(self.raw_file.?.as(object.Object), object.Object.signals.notify.connect(self.raw_file.?.as(object.Object), *View, rawSelected, self, .{ .detail = "selected" }));
        advanced.append(w.label("Full draft request (JSON). Collection editors: monitor_changes, custom_keybind_changes, window_rule_changes, snap_zone_changes, snap_layouts and default_snap_layout. See docs/AQUEOUS_SETTINGS.md for exact examples. System configuration stays read-only unless create_user_override is explicitly true.", "pearl-secondary").as(gtk.Widget));
        self.request_buffer = textArea(advanced, "Aqueous draft request JSON", 280);
        self.request_buffer.?.setText(self.z(self.client.draft orelse try self.client.emptyDraft(alloc)), -1);
        self.form_signals.add(self.request_buffer.?.as(object.Object), gtk.TextBuffer.signals.insert_text.connect(self.request_buffer.?, *View, inserting, self, .{}));
        self.form_signals.add(self.request_buffer.?.as(object.Object), gtk.TextBuffer.signals.changed.connect(self.request_buffer.?, *View, requestEdited, self, .{}));
        notebook.setCurrentPage(self.page_index);
    }
    fn monitorEditor(self: *View, box: *gtk.Box, original: m.Value, live: bool) !void {
        const alloc = self.arena.allocator();
        const name = m.str(m.get(original, "name"));
        if (name.len == 0) return;
        var value = original;
        const draft = m.parse(alloc, self.client.draft orelse "{}", m.max_request) catch m.Value.null;
        for (m.list(m.get(draft, "monitor_changes"))) |change| {
            if (!std.mem.eql(u8, name, m.str(m.get(change, "name"))) or change != .object) continue;
            var it = change.object.iterator();
            while (it.next()) |e| try value.object.put(alloc, e.key_ptr.*, e.value_ptr.*);
        }
        const card = w.card();
        box.append(card.as(gtk.Widget));
        card.append(w.label(self.z(name), "pearl-title").as(gtk.Widget));
        const editor = try alloc.create(Monitor);
        const position = m.list(m.get(value, "position"));
        const x = gtk.SpinButton.newWithRange(-100000, 100000, 1);
        const y = gtk.SpinButton.newWithRange(-100000, 100000, 1);
        x.setValue(if (position.len == 2) number(position[0], 0) else number(m.get(value, "x"), number(m.get(m.get(value, "position"), "x"), 0)));
        y.setValue(if (position.len == 2) number(position[1], 0) else number(m.get(value, "y"), number(m.get(m.get(value, "position"), "y"), 0)));
        const scale = gtk.SpinButton.newWithRange(0.25, 8, 0.25);
        scale.setDigits(2);
        scale.setValue(number(m.get(value, "scale"), 1));
        const transform = gtk.DropDown.newFromStrings(@ptrCast(&[_:null]?[*:0]const u8{ "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270" }));
        const names = [_][]const u8{ "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270" };
        for (names, 0..) |v, i| if (std.mem.eql(u8, v, m.str(m.get(value, "transform")))) {
            transform.setSelected(@intCast(i));
            break;
        };
        const mode = gtk.Entry.new();
        mode.setMaxLength(64);
        mode.setPlaceholderText("Current mode, or 1920x1080@60");
        mode.as(gtk.Editable).setText(self.z(m.str(m.get(value, "mode"))));
        for ([_]*gtk.Widget{ x.as(gtk.Widget), y.as(gtk.Widget), scale.as(gtk.Widget), transform.as(gtk.Widget), mode.as(gtk.Widget) }, [_][*:0]const u8{ "Horizontal position", "Vertical position", "Scale", "Rotation", "Mode" }) |input, title| {
            card.append(w.label(title, null).as(gtk.Widget));
            card.append(input);
            w.name(input, title);
        }
        editor.* = .{ .view = self, .name = name, .id = if (live) try std.fmt.allocPrint(alloc, "live:{s}", .{name}) else m.str(m.get(value, "id")), .x = x, .y = y, .scale = scale, .transform = transform, .mode = mode };
        for ([_]*gtk.SpinButton{ x, y, scale }) |input| self.form_signals.add(input.as(object.Object), gtk.SpinButton.signals.value_changed.connect(input, *Monitor, monitorSpun, editor, .{}));
        self.form_signals.add(transform.as(object.Object), object.Object.signals.notify.connect(transform.as(object.Object), *Monitor, monitorSelected, editor, .{ .detail = "selected" }));
        self.form_signals.add(mode.as(object.Object), gtk.Editable.signals.changed.connect(mode.as(gtk.Editable), *Monitor, monitorEdited, editor, .{}));
    }
    fn monitorSpun(_: *gtk.SpinButton, editor: *Monitor) callconv(.c) void {
        monitorChanged(editor) catch |err| editor.view.fail(err);
    }
    fn monitorSelected(_: *object.Object, _: *object.ParamSpec, editor: *Monitor) callconv(.c) void {
        monitorChanged(editor) catch |err| editor.view.fail(err);
    }
    fn monitorEdited(_: *gtk.Editable, editor: *Monitor) callconv(.c) void {
        monitorChanged(editor) catch |err| editor.view.fail(err);
    }
    fn monitorChanged(editor: *Monitor) !void {
        const self = editor.view;
        if (self.filling) return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var request = try m.parse(alloc, self.client.draft orelse try self.client.emptyDraft(alloc), m.max_request);
        if (request != .object or m.get(m.get(request, "raw_files"), "outputs") != .null) return error.ConflictingEdits;
        const names = [_][]const u8{ "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270" };
        const mode = std.mem.span(editor.mode.as(gtk.Editable).getText());
        const change = try m.parse(alloc, try std.json.Stringify.valueAlloc(alloc, .{ .id = editor.id, .name = editor.name, .x = editor.x.getValueAsInt(), .y = editor.y.getValueAsInt(), .scale = editor.scale.getValue(), .transform = names[@min(7, editor.transform.getSelected())], .mode = if (mode.len > 0) @as(?[]const u8, mode) else null }, .{ .emit_null_optional_fields = false }), 4096);
        var changes = m.get(request, "monitor_changes");
        if (changes == .null) changes = .{ .array = .init(alloc) };
        if (changes != .array) return error.InvalidRequest;
        var found = false;
        for (changes.array.items) |*c| if (std.mem.eql(u8, m.str(m.get(c.*, "id")), editor.id)) {
            c.* = change;
            found = true;
            break;
        };
        if (!found) try changes.array.append(change);
        try request.object.put(alloc, "monitor_changes", changes);
        try self.client.keepDraft(try std.json.Stringify.valueAlloc(alloc, request, .{ .whitespace = .indent_2 }));
        self.syncRequest();
        self.update();
    }
    fn inventory(self: *View, box: *gtk.Box, value: m.Value, key: []const u8, title: []const u8) !void {
        const expander = gtk.Expander.new(self.z(title));
        const label = w.label(self.z(try std.json.Stringify.valueAlloc(self.arena.allocator(), m.get(value, key), .{ .whitespace = .indent_2 })), "pearl-secondary");
        label.setSelectable(1);
        expander.setChild(label.as(gtk.Widget));
        box.append(expander.as(gtk.Widget));
    }
    fn loadRaw(self: *View) void {
        const filling = self.filling;
        self.filling = true;
        defer self.filling = filling;
        const keys = [_][]const u8{ "wm", "layout", "input", "outputs", "rules", "appearance" };
        const key = keys[@min(5, self.raw_file.?.getSelected())];
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const draft = m.parse(arena.allocator(), self.client.draft orelse "{}", m.max_request) catch m.Value.null;
        const raw = m.get(m.get(draft, "raw_files"), key);
        const text = if (raw == .string) raw.string else m.str(m.get(m.get(self.client.baseValue(), "raw_files"), key));
        const terminated = a.dupeZ(u8, text) catch return;
        defer a.free(terminated);
        self.raw_buffer.?.setText(terminated, -1);
    }
    fn fail(self: *View, err: anyerror) void {
        self.message.setText(self.z(@errorName(err)));
    }
    pub fn update(self: *View) void {
        if (self.revision != self.client.revision or (self.version != self.client.version and (self.client.draft == null or self.request_buffer == null))) self.build() catch |err| self.fail(err);
        const c = self.client;
        self.reload_button.as(gtk.Widget).setVisible(@intFromBool(c.reload_state == .failed or c.reload_state == .unknown or c.reload_state == .unavailable));
        self.reload_button.as(gtk.Widget).setSensitive(@intFromBool(c.job == null and c.reload_ticket == null));
        for (self.preview_buttons) |button| button.as(gtk.Widget).setVisible(@intFromBool(c.previewing()));
        self.preview_buttons[0].as(gtk.Widget).setSensitive(@intFromBool(c.remaining() > 0));
        self.content.as(gtk.Widget).setSensitive(@intFromBool(!c.previewing()));
        for (self.buttons) |b| b.as(gtk.Widget).setSensitive(@intFromBool(c.job == null));
        self.buttons[2].as(gtk.Widget).setSensitive(@intFromBool(c.job == null and c.draft != null and !c.conflict() and !c.unresolved));
        var buffer: [700]u8 = undefined;
        var countdown: [100]u8 = undefined;
        const outcome = if (c.previewing()) std.fmt.bufPrint(&countdown, "Keep these displays? Reverting in {d}s.", .{c.remaining()}) catch "Display preview" else if (c.job != null) "Preparing settings…" else switch (c.outcome) {
            .idle => "Open settings to load the configuration",
            .loaded => "Settings loaded",
            .validated => "Draft is valid",
            .saved => "Settings saved",
            .reverted => "Display preview reverted",
            .invalidated => "Preview ended; competing display changes preserved",
            .failed => "Operation failed",
            .uncertain => "Save uncertain; refresh and review before retrying",
        };
        const text = std.fmt.bufPrintZ(&buffer, "{s} · reload: {s} · toolkit sync: {s}{s}{s}{s}{s}{s}{s}", .{
            outcome,                                  if (c.reload_state == .not_requested) "not requested" else @tagName(c.reload_state), if (c.toolkit == .not_requested) "not requested" else @tagName(c.toolkit),
            if (c.draft != null) " · draft retained" else "",
            if (c.conflict()) " · external change; review before rebasing" else "",
            if (c.err != null) " · " else "",
            if (c.err) |err| @errorName(err) else "",
            if (c.detail[0] != 0) " · " else "",
            std.mem.sliceTo(&c.detail, 0),
        }) catch "Settings status unavailable";
        self.message.setText(text);
    }
    fn save(editor: *Editor, value: m.Value) void {
        const self = editor.view;
        if (self.filling) return;
        self.client.editField(m.str(m.get(editor.field, "id")), value) catch |err| {
            self.fail(err);
            return;
        };
        self.syncRequest();
        self.update();
    }
    fn syncRequest(self: *View) void {
        self.revision = self.client.revision;
        self.filling = true;
        defer self.filling = false;
        const text = a.dupeZ(u8, self.client.draft orelse "{}") catch return;
        defer a.free(text);
        if (self.request_buffer) |b| b.setText(text, -1);
    }
    fn toggled(widget: *gtk.CheckButton, editor: *Editor) callconv(.c) void {
        save(editor, .{ .bool = widget.getActive() != 0 });
    }
    fn spun(widget: *gtk.SpinButton, editor: *Editor) callconv(.c) void {
        save(editor, if (std.mem.eql(u8, m.str(m.get(editor.field, "type")), "integer")) .{ .integer = widget.getValueAsInt() } else .{ .float = widget.getValue() });
    }
    fn selected(widget: *object.Object, _: *object.ParamSpec, editor: *Editor) callconv(.c) void {
        const options = m.list(m.get(editor.field, "options"));
        const index = @as(*gtk.DropDown, @ptrCast(widget)).getSelected();
        if (index < options.len) save(editor, options[index]);
    }
    fn edited(widget: *gtk.Editable, editor: *Editor) callconv(.c) void {
        save(editor, .{ .string = std.mem.span(widget.getText()) });
    }
    fn refreshed(_: *gtk.Button, self: *View) callconv(.c) void {
        self.client.begin(.refresh) catch |err| self.fail(err);
    }
    fn discarded(_: *gtk.Button, self: *View) callconv(.c) void {
        self.client.discard();
        self.build() catch |err| self.fail(err);
        self.update();
    }
    fn validated(_: *gtk.Button, self: *View) callconv(.c) void {
        self.client.begin(.validate) catch |err| self.fail(err);
    }
    fn applied(_: *gtk.Button, self: *View) callconv(.c) void {
        self.client.begin(.apply) catch |err| self.fail(err);
    }
    fn rebased(_: *gtk.Button, self: *View) callconv(.c) void {
        self.client.rebase() catch |err| {
            self.fail(err);
            return;
        };
        self.build() catch |err| self.fail(err);
        self.update();
    }
    fn kept(_: *gtk.Button, self: *View) callconv(.c) void {
        self.client.choose(true) catch |err| self.fail(err);
    }
    fn reverted(_: *gtk.Button, self: *View) callconv(.c) void {
        self.client.choose(false) catch |err| self.fail(err);
    }
    fn reloaded(_: *gtk.Button, self: *View) callconv(.c) void {
        self.client.requestReload() catch |err| self.fail(err);
    }
    fn rawSelected(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        self.loadRaw();
    }
    fn rawEdited(_: *gtk.TextBuffer, self: *View) callconv(.c) void {
        if (!self.filling) self.stageRaw() catch |err| self.fail(err);
    }
    fn stageRaw(self: *View) !void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var request = try m.parse(alloc, self.client.draft orelse try self.client.emptyDraft(alloc), m.max_request);
        if (request != .object) return error.InvalidRequest;
        var raw = m.get(request, "raw_files");
        if (raw != .object) return error.InvalidRequest;
        const keys = [_][]const u8{ "wm", "layout", "input", "outputs", "rules", "appearance" };
        const key = keys[@min(5, self.raw_file.?.getSelected())];
        const text = bufferText(self.raw_buffer.?);
        defer glib.free(text);
        try raw.object.put(alloc, key, .{ .string = std.mem.span(text) });
        try request.object.put(alloc, "raw_files", raw);
        try self.client.keepDraft(try std.json.Stringify.valueAlloc(alloc, request, .{ .whitespace = .indent_2 }));
        self.syncRequest();
        self.update();
    }
    fn requestEdited(buffer: *gtk.TextBuffer, self: *View) callconv(.c) void {
        if (self.filling) return;
        const text = bufferText(buffer);
        defer glib.free(text);
        self.client.keepDraft(std.mem.span(text)) catch |err| {
            self.fail(err);
            return;
        };
        self.revision = self.client.revision;
        self.update();
    }
    fn inserting(buffer: *gtk.TextBuffer, _: *gtk.TextIter, _: [*:0]u8, length: c_int, self: *View) callconv(.c) void {
        if (self.filling or length < 0) return;
        if (@as(usize, @intCast(buffer.getCharCount())) * 4 + @as(usize, @intCast(length)) > m.max_request) object.signalStopEmissionByName(buffer.as(object.Object), "insert-text");
    }
    fn recordClicked(_: *gtk.Button, editor: *Editor) callconv(.c) void {
        editor.view.startRecording(editor) catch |err| editor.view.fail(err);
    }
    pub fn record(self: *View, id: []const u8) !void {
        if (self.notebook) |notebook| notebook.setCurrentPage(3);
        for (self.editors.items) |editor| if (editor.record != null and std.mem.eql(u8, m.str(m.get(editor.field, "id")), id)) return self.startRecording(editor);
        return error.UnknownField;
    }
    pub fn showPage(self: *View, name: []const u8) !void {
        const names = [_][]const u8{ "appearance", "layouts", "input", "keybinds", "rules", "displays", "advanced" };
        for (names, 0..) |v, index| if (std.mem.eql(u8, v, name)) {
            self.page_index = @intCast(index);
            if (self.notebook) |notebook| notebook.setCurrentPage(@intCast(index));
            return;
        };
        return error.UnknownPage;
    }
    fn startRecording(self: *View, editor: *Editor) !void {
        self.stopRecording();
        if (self.client.job != null or !self.client.can_record(self.client.context)) return error.ShortcutInhibitionUnavailable;
        const surface = self.window.as(gtk.Native).getSurface() orelse return error.ShortcutInhibitionUnavailable;
        const toplevel = object.ext.cast(gdk.Toplevel, surface) orelse return error.ShortcutInhibitionUnavailable;
        self.inhibited = toplevel;
        self.recording = editor;
        _ = editor.widget.grabFocus();
        toplevel.inhibitSystemShortcuts(null);
        self.record_deadline = glib.getMonotonicTime() + 30000000;
        self.record_timer = glib.timeoutAdd(50, recordTick, self);
        self.message.setText("Waiting for Aqueous to inhibit shortcuts… Escape cancels.");
    }
    fn stopRecording(self: *View) void {
        if (self.record_timer != 0) _ = glib.Source.remove(self.record_timer);
        self.record_timer = 0;
        if (self.inhibited) |v| v.restoreSystemShortcuts();
        self.inhibited = null;
        self.recording = null;
        self.client.recording = false;
    }
    fn recordTick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(data.?));
        if (glib.getMonotonicTime() >= self.record_deadline or self.host.as(gtk.Widget).getMapped() == 0 or !self.client.can_record(self.client.context)) {
            std.log.info("event=shortcut-record-ended reason=deadline-or-unmapped", .{});
            self.record_timer = 0;
            self.stopRecording();
            self.message.setText("Shortcut recording cancelled.");
            return 0;
        }
        var inhibited: c_int = 0;
        self.inhibited.?.as(object.Object).get("shortcuts-inhibited", &inhibited, @as(?[*:0]const u8, null));
        if (inhibited == 0 and self.client.recording) {
            std.log.info("event=shortcut-record-ended reason=revoked", .{});
            self.record_timer = 0;
            self.stopRecording();
            self.message.setText("Shortcut inhibition was revoked.");
            return 0;
        }
        if (inhibited != 0 and !self.client.recording) {
            self.client.recording = true;
            self.message.setText("Press a shortcut. Escape cancels; recording ends after 30 seconds.");
        }
        return 1;
    }
    fn recorded(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, modifiers: gdk.ModifierType, self: *View) callconv(.c) c_int {
        const editor = self.recording orelse return 0;
        if (key == 0xff1b) {
            self.stopRecording();
            self.message.setText("Shortcut recording cancelled.");
            return 1;
        }
        if (!self.client.recording) return 1;
        if (key >= 0xffe1 and key <= 0xffee) return 1; // modifier-only press
        const name = gdk.keyvalName(key) orelse return 1;
        var buffer: [256]u8 = undefined;
        const chord = std.fmt.bufPrintZ(&buffer, "{s}{s}{s}{s}{s}", .{ if (modifiers.super_mask) "Super+" else "", if (modifiers.control_mask) "Ctrl+" else "", if (modifiers.alt_mask) "Alt+" else "", if (modifiers.shift_mask) "Shift+" else "", std.mem.span(name) }) catch return 1;
        self.stopRecording();
        object.ext.cast(gtk.Editable, editor.widget).?.setText(chord);
        return 1;
    }
    fn switched(_: *gtk.Notebook, _: *gtk.Widget, page_index: c_uint, self: *View) callconv(.c) void {
        if (!self.filling) self.page_index = @intCast(page_index);
        self.stopRecording();
    }
};
fn number(v: m.Value, fallback: f64) f64 {
    return switch (v) {
        .integer => @floatFromInt(v.integer),
        .float => v.float,
        else => fallback,
    };
}
fn textArea(box: *gtk.Box, name: [*:0]const u8, height: c_int) *gtk.TextBuffer {
    const view = gtk.TextView.new();
    view.setMonospace(1);
    view.setWrapMode(.word_char);
    view.as(gtk.Widget).setSizeRequest(-1, height);
    w.name(view.as(gtk.Widget), name);
    box.append(view.as(gtk.Widget));
    return view.getBuffer();
}
fn bufferText(buffer: *gtk.TextBuffer) [*:0]u8 {
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    buffer.getBounds(&start, &end);
    return buffer.getText(&start, &end, 1);
}
