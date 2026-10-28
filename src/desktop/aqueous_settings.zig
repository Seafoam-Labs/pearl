//! Schema-driven replacement for the Aqueous settings application.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const glib = @import("glib2");
const object = @import("gobject2");
const Client = @import("../config/aqueous_client.zig").Client;
const m = @import("../config/aqueous_model.zig");
const w = @import("../ui/components/widgets.zig");
const log = std.log.scoped(.desktop);
const a = std.heap.c_allocator;
const layout = @import("aqueous_layout.zig");
const Signals = struct {
    items: std.ArrayList(struct { instance: *object.Object, id: c_ulong }) = .empty,
    pub fn add(self: *Signals, instance: *object.Object, id: c_ulong) void {
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
pub const View = ViewFor(Client);
pub fn ViewFor(comptime ClientType: type) type {
    return struct {
        const Self = @This();
        const Pages = if (@hasDecl(ClientType, "standalone")) gtk.Stack else gtk.Notebook;
        pub const Editor = struct { view: *Self, field: m.Value, widget: *gtk.Widget, record: ?*gtk.Button = null, row: ?*gtk.Box = null, group: layout.map.Group = .keybinds_extra };
        const Layout = layout.For(Self);
        const Monitor = struct { view: *Self, id: []const u8, name: []const u8, x: *gtk.SpinButton, y: *gtk.SpinButton, scale: *gtk.SpinButton, transform: *gtk.DropDown, mode: *gtk.Entry, mirror: *gtk.Entry };

        layout: layout.State = .{},
        open_appearance: ?struct { context: *anyopaque, notify: *const fn (*anyopaque) void } = null,
        open_section: ?struct { context: *anyopaque, notify: *const fn (*anyopaque, []const u8) void } = null,
        issue_button: *gtk.Button,
        issue_focus: [256:0]u8 = @splat(0),
        announced_status: [1000:0]u8 = @splat(0),
        rules_view: ?*@import("../settings/window_rules_view.zig").For(Self) = null,
        host: *gtk.Box,
        client: *ClientType,
        arena: std.heap.ArenaAllocator,
        content: *gtk.Box,
        message: *gtk.Label,
        request_buffer: ?*gtk.TextBuffer = null,
        raw_buffer: ?*gtk.TextBuffer = null,
        raw_file: ?*gtk.DropDown = null,
        filling: bool = true,
        forms_stale: bool = false,
        rule_move_pending: bool = false,
        version: u64 = 0,
        revision: u64 = 0,
        review_version: u64 = 0,
        buttons: [3]*gtk.Button,
        draft_buttons: [2]*gtk.Button,
        actions: *gtk.FlowBox,
        footer_line: *gtk.Box,
        preview_buttons: [2]*gtk.Button,
        preview_actions: *gtk.FlowBox,
        window: *gtk.Window,
        editors: std.ArrayList(*Editor) = .empty,
        recording: ?*Editor = null,
        inhibited: ?*gdk.Toplevel = null,
        record_timer: c_uint = 0,
        record_deadline: i64 = 0,
        keys: *gtk.EventControllerKey = undefined,
        notebook: ?*Pages = null,
        page_widgets: [7]?*gtk.Widget = @splat(null),
        page_count: usize = 0,
        placement_box: ?*gtk.Box = null,
        display_selected: [128:0]u8 = @splat(0),
        display_more: bool = false,
        display_exact: bool = false,
        display_canvas: ?*gtk.DrawingArea = null,
        display_refresh_source: c_uint = 0,
        display_controls: std.ArrayList(struct { id: []const u8, widget: *gtk.Widget }) = .empty,
        display_changes: usize = 0,
        display_other_changes: usize = 0,
        display_advanced_box: ?*gtk.Box = null,
        display_blocked: bool = false,
        preview_dialog: ?*gtk.Window = null,
        preview_message: ?*gtk.Label = null,
        preview_keep: ?*gtk.Button = null,
        preview_revert: ?*gtk.Button = null,
        preview_visible: bool = false,
        shared_dialog: ?*gtk.Dialog = null,
        shared_discard: bool = false,
        shared_revision: u64 = 0,
        page_index: c_int = 0,
        /// The standalone host invalidates page-local focus before widgets die.
        rebuild_observer: ?struct { context: *anyopaque, notify: *const fn (*anyopaque, bool) void } = null,
        reload_button: *gtk.Button,
        root_signals: Signals = .{},
        form_signals: Signals = .{},
        pub fn create(host: *gtk.Box, client: *ClientType, window: *gtk.Window) !*Self {
            return createIn(host, client, window, host);
        }
        pub fn createIn(host: *gtk.Box, client: *ClientType, window: *gtk.Window, footer: *gtk.Box) !*Self {
            const self = try a.create(Self);
            if (!@hasDecl(ClientType, "standalone")) {
                host.append(w.label(@import("i18n").dtr("pearl", "Aqueous settings"), "pearl-title").as(gtk.Widget));
                host.append(w.label(@import("i18n").dtr("pearl", "Layouts, windows, input and your desktop appearance"), "pearl-secondary").as(gtk.Widget));
            }
            const content = w.column(12);
            content.as(gtk.Widget).setVexpand(1);
            host.append(content.as(gtk.Widget));
            const message = w.label(@import("i18n").dtr("pearl", "Loading settings…"), "pearl-secondary");
            const footer_line = w.column(8);
            footer.append(footer_line.as(gtk.Widget));
            footer_line.append(message.as(gtk.Widget));
            const actions = w.flow(5);
            actions.setHomogeneous(0);
            footer_line.append(actions.as(gtk.Widget));
            const refresh = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "Refresh"));
            actions.insert(refresh.as(gtk.Widget), -1);
            const discard = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "Discard draft"));
            actions.insert(discard.as(gtk.Widget), -1);
            const rebase = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "Rebase draft"));
            actions.insert(rebase.as(gtk.Widget), -1);
            const validate = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "Validate"));
            actions.insert(validate.as(gtk.Widget), -1);
            const apply = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "Apply & save"));
            actions.insert(apply.as(gtk.Widget), -1);
            const issue = w.wrappingButton(@import("i18n").dtr("pearl", "Review issue"));
            actions.insert(issue.as(gtk.Widget), -1);
            apply.as(gtk.Widget).addCssClass("pearl-primary");
            const preview_actions = w.flow(3);
            preview_actions.setHomogeneous(0);
            footer.append(preview_actions.as(gtk.Widget));
            const keep = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "Keep displays"));
            const revert = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "Revert displays"));
            const reload = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "Retry compositor reload"));
            preview_actions.insert(reload.as(gtk.Widget), -1);
            preview_actions.insert(keep.as(gtk.Widget), -1);
            preview_actions.insert(revert.as(gtk.Widget), -1);
            self.* = .{ .issue_button = issue, .host = host, .client = client, .arena = .init(a), .content = content, .message = message, .actions = actions, .footer_line = footer_line, .buttons = .{ refresh, validate, apply }, .draft_buttons = .{ discard, rebase }, .preview_buttons = .{ keep, revert }, .preview_actions = preview_actions, .reload_button = reload, .window = window };
            self.root_signals.add(refresh.as(object.Object), gtk.Button.signals.clicked.connect(refresh, *Self, refreshed, self, .{}));
            self.root_signals.add(issue.as(object.Object), gtk.Button.signals.clicked.connect(issue, *Self, issueClicked, self, .{}));
            self.root_signals.add(discard.as(object.Object), gtk.Button.signals.clicked.connect(discard, *Self, discarded, self, .{}));
            self.root_signals.add(validate.as(object.Object), gtk.Button.signals.clicked.connect(validate, *Self, validated, self, .{}));
            self.root_signals.add(apply.as(object.Object), gtk.Button.signals.clicked.connect(apply, *Self, applied, self, .{}));
            self.root_signals.add(rebase.as(object.Object), gtk.Button.signals.clicked.connect(rebase, *Self, rebased, self, .{}));
            self.root_signals.add(keep.as(object.Object), gtk.Button.signals.clicked.connect(keep, *Self, kept, self, .{}));
            self.root_signals.add(revert.as(object.Object), gtk.Button.signals.clicked.connect(revert, *Self, reverted, self, .{}));
            self.root_signals.add(reload.as(object.Object), gtk.Button.signals.clicked.connect(reload, *Self, reloaded, self, .{}));
            const keys = gtk.EventControllerKey.new();
            keys.as(gtk.EventController).setPropagationPhase(.capture);
            self.keys = keys;
            self.root_signals.add(keys.as(object.Object), gtk.EventControllerKey.signals.key_pressed.connect(keys, *Self, recorded, self, .{}));
            host.as(gtk.Widget).addController(keys.as(gtk.EventController));
            self.build() catch |err| self.fail(err);
            self.update();
            if (client.job == null) client.begin(.refresh) catch |err| self.fail(err);
            return self;
        }
        pub fn destroy(self: *Self) void {
            self.layout.clear();
            if (self.rules_view) |view| view.destroy();
            if (self.shared_dialog) |dialog| dialog.as(gtk.Window).destroy();
            if (self.preview_dialog) |dialog| {
                dialog.destroy();
                self.preview_dialog = null;
            }
            self.stopRecording();
            if (self.display_refresh_source != 0) _ = glib.Source.remove(self.display_refresh_source);
            self.display_refresh_source = 0;
            if (self.display_canvas) |canvas| canvas.setDrawFunc(null, null, null);
            self.display_canvas = null;
            self.form_signals.clear();
            self.root_signals.clear();
            self.host.as(gtk.Widget).removeController(self.keys.as(gtk.EventController));
            if (self.client.previewing()) self.client.choose(false) catch {};
            self.filling = true;
            while (self.host.as(gtk.Widget).getFirstChild()) |c| self.host.remove(c);
            self.arena.deinit();
            a.destroy(self);
        }
        pub fn z(self: *Self, text: []const u8) [:0]const u8 {
            return self.arena.allocator().dupeSentinel(u8, text, 0) catch "";
        }
        fn page(self: *Self, notebook: *Pages, title: []const u8) *gtk.Box {
            const scroll = gtk.ScrolledWindow.new();
            scroll.setPolicy(.never, .automatic);
            scroll.as(gtk.Widget).setVexpand(1);
            const box = w.column(16);
            box.as(gtk.Widget).addCssClass("aqueous-view");
            inline for (.{ gtk.Widget.setMarginStart, gtk.Widget.setMarginEnd, gtk.Widget.setMarginTop, gtk.Widget.setMarginBottom }) |set| set(box.as(gtk.Widget), 12);
            scroll.setChild(box.as(gtk.Widget));
            if (@hasDecl(ClientType, "standalone")) {
                inline for (.{ gtk.Widget.setMarginStart, gtk.Widget.setMarginEnd, gtk.Widget.setMarginTop, gtk.Widget.setMarginBottom }) |set| set(box.as(gtk.Widget), 0);
                // The normal window supplies the single page viewport.
                _ = box.ref();
                scroll.setChild(null);
                _ = notebook.addNamed(box.as(gtk.Widget), self.z(title));
                self.page_widgets[self.page_count] = box.as(gtk.Widget);
                self.page_count += 1;
                box.unref();
                _ = scroll.as(object.Object).refSink();
                scroll.unref();
                return box;
            }
            if (!@hasDecl(ClientType, "standalone")) _ = notebook.appendPage(scroll.as(gtk.Widget), gtk.Label.new(self.z(title)).as(gtk.Widget));
            return box;
        }
        pub fn build(self: *Self) !void {
            if (self.rules_view) |view| view.detach();
            if (self.rebuild_observer) |observer| observer.notify(observer.context, true);
            defer if (self.rebuild_observer) |observer| observer.notify(observer.context, false);
            self.placement_box = null;
            self.display_advanced_box = null;
            self.stopRecording();
            self.filling = true;
            self.forms_stale = false;
            defer self.filling = false;
            if (self.display_refresh_source != 0) _ = glib.Source.remove(self.display_refresh_source);
            self.display_refresh_source = 0;
            if (self.display_canvas) |canvas| canvas.setDrawFunc(null, null, null);
            self.display_canvas = null;
            self.form_signals.clear();
            self.layout.clear();
            self.notebook = null;
            self.page_count = 0;
            self.page_widgets = @splat(null);
            while (self.content.as(gtk.Widget).getFirstChild()) |c| self.content.remove(c);
            _ = self.arena.reset(.retain_capacity);
            self.editors = .empty;
            self.display_controls = .empty;
            self.request_buffer = null;
            self.raw_buffer = null;
            self.raw_file = null;
            self.version = self.client.version;
            self.revision = self.client.revision;
            self.review_version = self.client.review_version;
            if (self.client.live == null) return;
            const alloc = self.arena.allocator();
            // UI metadata must not borrow a snapshot replaced by a background refresh.
            const snapshot = try m.parse(alloc, try std.json.Stringify.valueAlloc(alloc, self.client.baseValue(), .{}), m.max_response);
            const notebook = Pages.new();
            self.notebook = notebook;
            if (@hasDecl(ClientType, "standalone")) {
                // Each section measures its own extent; disclosures must not
                // create blank scroll space on other sections.
                notebook.setHhomogeneous(0);
                notebook.setVhomogeneous(0);
            } else notebook.setScrollable(1);
            notebook.as(gtk.Widget).setVexpand(1);
            self.content.append(notebook.as(gtk.Widget));
            if (!@hasDecl(ClientType, "standalone")) self.form_signals.add(notebook.as(object.Object), gtk.Notebook.signals.switch_page.connect(notebook, *Self, switched, self, .{}));
            const categories = [_][]const u8{ "appearance", "layouts", "input", "keybinds", "rules", "displays" };
            const titles = [_][]const u8{ "Appearance", "Layouts", "Input", "Keybindings", "Rules", "Displays" };
            const draft = m.parse(alloc, self.client.draft orelse try self.client.emptyDraft(alloc), m.max_request) catch m.Value.null;
            self.rule_move_pending = @import("../config/aqueous_rule_editor.zig").hasMove(draft);
            for (categories, titles) |category, title| {
                const box = self.page(notebook, title);
                try Layout.render(self, box, snapshot, draft, category);
            }
            const advanced = self.page(notebook, @import("i18n").dtr("pearl", "Advanced"));
            try Layout.status(self, advanced);
            const receipts = try Layout.group(self, advanced, .receipts);
            if (self.client.preview_report) |report| {
                const wrapper = try std.json.Stringify.valueAlloc(alloc, .{ .preview = try m.parse(alloc, report, m.max_response) }, .{});
                try self.inventory(receipts, try m.parse(alloc, wrapper, m.max_response), "preview", @import("i18n").dtr("pearl", "Latest native preview and rollback status"));
            }
            if (self.client.report) |report| {
                const wrapper = try std.json.Stringify.valueAlloc(alloc, .{ .operation = try m.parse(alloc, report, m.max_response) }, .{});
                try self.inventory(receipts, try m.parse(alloc, wrapper, m.max_response), "operation", @import("i18n").dtr("pearl", "Latest operation receipt and recovery details"));
            }
            if (self.client.review) |review| {
                const wrapper = try std.json.Stringify.valueAlloc(alloc, .{ .review = try m.parse(alloc, review, m.max_response) }, .{});
                try self.inventory(receipts, try m.parse(alloc, wrapper, m.max_response), "review", @import("i18n").dtr("pearl", "Validated candidate effects"));
            }
            const raw_host = try Layout.group(self, advanced, .raw);
            raw_host.append(w.label(@import("i18n").dtr("pearl", "Raw edits are retained as you type, including invalid TOML. A file cannot have both raw and structured edits; resolve overlaps in the request below."), "pearl-secondary").as(gtk.Widget));
            self.raw_file = gtk.DropDown.newFromStrings(@ptrCast(&[_:null]?[*:0]const u8{ @import("i18n").dtr("pearl", "wm"), @import("i18n").dtr("pearl", "layout"), @import("i18n").dtr("pearl", "input"), @import("i18n").dtr("pearl", "outputs"), @import("i18n").dtr("pearl", "rules"), @import("i18n").dtr("pearl", "appearance") }));
            self.raw_file.?.setSelected(self.layout.raw_source);
            raw_host.append(self.raw_file.?.as(gtk.Widget));
            self.raw_buffer = textArea(raw_host, "Raw Aqueous TOML", 220);
            try self.layout.controls.append(alloc, .{ .id = "aqueous.raw-source", .widget = self.raw_file.?.as(gtk.Widget) });
            try self.layout.controls.append(alloc, .{ .id = "aqueous.raw", .widget = raw_host.as(gtk.Widget).getLastChild().? });
            self.loadRaw();
            self.form_signals.add(self.raw_buffer.?.as(object.Object), gtk.TextBuffer.signals.insert_text.connect(self.raw_buffer.?, *Self, inserting, self, .{}));
            self.form_signals.add(self.raw_buffer.?.as(object.Object), gtk.TextBuffer.signals.changed.connect(self.raw_buffer.?, *Self, rawEdited, self, .{}));
            self.form_signals.add(self.raw_file.?.as(object.Object), object.Object.signals.notify.connect(self.raw_file.?.as(object.Object), *Self, rawSelected, self, .{ .detail = "selected" }));
            const request_host = try Layout.group(self, advanced, .request);
            request_host.append(w.label(@import("i18n").dtr("pearl", "Full draft request (JSON). Collection editors: monitor_changes, custom_keybind_changes, window_rule_changes, snap_zone_changes, snap_layouts and default_snap_layout. See docs/AQUEOUS_SETTINGS.md for exact examples. System configuration stays read-only unless create_user_override is explicitly true."), "pearl-secondary").as(gtk.Widget));
            self.request_buffer = textArea(request_host, "Aqueous draft request JSON", 280);
            try self.layout.controls.append(alloc, .{ .id = "aqueous.request", .widget = request_host.as(gtk.Widget).getLastChild().? });
            self.request_buffer.?.setText(self.z(self.client.draft orelse try self.client.emptyDraft(alloc)), -1);
            self.form_signals.add(self.request_buffer.?.as(object.Object), gtk.TextBuffer.signals.insert_text.connect(self.request_buffer.?, *Self, inserting, self, .{}));
            self.form_signals.add(self.request_buffer.?.as(object.Object), gtk.TextBuffer.signals.changed.connect(self.request_buffer.?, *Self, requestEdited, self, .{}));
            // Unknown future categories remain editable in Advanced.
            for (m.list(m.get(snapshot, "fields"))) |field| {
                const category = m.fieldCategory(field);
                var known = false;
                for (categories) |name| if (std.mem.eql(u8, name, category)) {
                    known = true;
                    break;
                };
                if (!known) try self.fieldEditor(request_host, field, draft, .request);
            }
            Layout.filter(self);
            self.selectPage(self.page_index);
        }
        pub fn fieldEditor(self: *Self, box: *gtk.Box, field: m.Value, draft: m.Value, group_id: layout.map.Group) !void {
            const alloc = self.arena.allocator();
            const category = m.fieldCategory(field);
            var value = m.get(field, "value");
            for (m.list(m.get(draft, "changes"))) |c| if (std.mem.eql(u8, m.str(m.get(c, "id")), m.str(m.get(field, "id")))) {
                value = m.get(c, "value");
                break;
            };
            const row = w.column(8);
            row.as(gtk.Widget).addCssClass("aqueous-field");
            box.append(row.as(gtk.Widget));
            const label = w.label(self.z(@import("i18n").aqueousField(m.str(m.get(field, "id")), .label, m.str(m.get(field, "label")))), null);
            label.as(gtk.Widget).addCssClass("settings-row-title");
            row.append(label.as(gtk.Widget));
            row.as(gtk.Widget).setTooltipText(self.z(@import("i18n").aqueousField(m.str(m.get(field, "id")), .description, m.str(m.get(field, "description")))));
            const editor = try alloc.create(Editor);
            editor.* = .{ .view = self, .field = field, .widget = undefined, .row = row, .group = group_id };
            const kind = m.str(m.get(field, "type"));
            if (std.mem.eql(u8, kind, "boolean")) {
                row.as(gtk.Orientable).setOrientation(.horizontal);
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
                var known = false;
                for (opts) |option| if (m.equal(option, value)) {
                    known = true;
                    break;
                };
                const strings = try alloc.allocSentinel(?[*:0]const u8, opts.len + @intFromBool(!known), null);
                var selected_index: c_uint = @intCast(opts.len);
                for (opts, 0..) |option, i| {
                    strings[i] = self.z(@import("i18n").aqueousOption(m.str(m.get(field, "id")), m.str(option)));
                    if (m.equal(option, value)) selected_index = @intCast(i);
                }
                if (!known) strings[opts.len] = self.z(try std.fmt.allocPrint(alloc, "{s}: {s}", .{ @import("i18n").dtr("pearl", "Preserved value"), try std.json.Stringify.valueAlloc(alloc, value, .{}) }));
                const input = gtk.DropDown.newFromStrings(@ptrCast(strings.ptr));
                @import("../settings/assistant_layout.zig").wrapChoice(input);
                input.setSelected(selected_index);
                editor.widget = input.as(gtk.Widget);
                self.form_signals.add(input.as(object.Object), object.Object.signals.notify.connect(input.as(object.Object), *Editor, selected, editor, .{ .detail = "selected" }));
                if (known and opts.len > 0 and opts.len <= 16 and std.mem.eql(u8, m.str(m.get(field, "id")), "layout.default")) editor.widget = try Layout.choices(self, row, input, field);
            } else {
                const input = gtk.Entry.new();
                input.setMaxLength(8192);
                input.as(gtk.Editable).setWidthChars(12);
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
            w.name(editor.widget, self.z(@import("i18n").aqueousField(m.str(m.get(field, "id")), .label, m.str(m.get(field, "label")))));
            try self.editors.append(alloc, editor);
            if (std.mem.eql(u8, category, "keybinds") and std.mem.eql(u8, kind, "string_list")) {
                const inputs = w.row(8);
                editor.widget.setHexpand(1);
                inputs.append(editor.widget);
                const record_button = w.wrappingButton(@import("i18n").dtr("pearl", "Record shortcut"));
                inputs.append(record_button.as(gtk.Widget));
                row.append(inputs.as(gtk.Widget));
                editor.record = record_button;
                self.form_signals.add(record_button.as(object.Object), gtk.Button.signals.clicked.connect(record_button, *Editor, recordClicked, editor, .{}));
            } else row.append(editor.widget);
            // Raw edits own the whole file; typed widgets cannot obscure them.
            row.as(gtk.Widget).setSensitive(@intFromBool(draft == .object and m.get(m.get(draft, "raw_files"), m.str(m.get(field, "file"))) == .null));
        }
        pub fn monitorEditor(self: *Self, box: *gtk.Box, original: m.Value, live: bool) !void {
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
            const scale = gtk.SpinButton.newWithRange(0.5, 3, 1.0 / 120.0);
            scale.setDigits(2);
            scale.setValue(number(m.get(value, "scale"), 1));
            const transform = gtk.DropDown.newFromStrings(@ptrCast(&[_:null]?[*:0]const u8{ @import("i18n").dtr("pearl", "normal"), @import("i18n").dtr("pearl", "90"), @import("i18n").dtr("pearl", "180"), @import("i18n").dtr("pearl", "270"), @import("i18n").dtr("pearl", "flipped"), @import("i18n").dtr("pearl", "flipped-90"), @import("i18n").dtr("pearl", "flipped-180"), @import("i18n").dtr("pearl", "flipped-270") }));
            const names = [_][]const u8{ "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270" };
            for (names, 0..) |v, i| if (std.mem.eql(u8, v, m.str(m.get(value, "transform")))) {
                transform.setSelected(@intCast(i));
                break;
            };
            const mode = gtk.Entry.new();
            mode.setMaxLength(64);
            mode.setPlaceholderText(@import("i18n").dtr("pearl", "Current mode, or 1920x1080@60"));
            mode.as(gtk.Editable).setText(self.z(m.str(m.get(value, "mode"))));
            for ([_]*gtk.Widget{ x.as(gtk.Widget), y.as(gtk.Widget), scale.as(gtk.Widget), transform.as(gtk.Widget), mode.as(gtk.Widget) }, [_][*:0]const u8{ "Horizontal position", "Vertical position", "Scale", "Rotation", "Mode" }) |input, title| {
                card.append(w.label(title, null).as(gtk.Widget));
                card.append(input);
                w.name(input, title);
            }
            const mirror = gtk.Entry.new();
            mirror.setMaxLength(128);
            mirror.as(gtk.Editable).setText(self.z(m.str(m.get(value, "mirror_of"))));
            card.append(w.label(@import("i18n").dtr("pearl", "Mirror of (empty for independent)"), null).as(gtk.Widget));
            card.append(mirror.as(gtk.Widget));
            w.name(mirror.as(gtk.Widget), @import("i18n").dtr("pearl", "Mirror target connector"));
            const displays = @import("aqueous_displays.zig");
            card.as(gtk.Widget).setSensitive(@intFromBool(displays.editable(self.client.baseValue(), name, "placement")));
            mirror.as(gtk.Widget).setSensitive(@intFromBool(displays.editable(self.client.baseValue(), name, "mirroring")));
            editor.* = .{ .view = self, .name = name, .id = if (live) try std.fmt.allocPrint(alloc, "live:{s}", .{name}) else m.str(m.get(value, "id")), .x = x, .y = y, .scale = scale, .transform = transform, .mode = mode, .mirror = mirror };
            for ([_]*gtk.SpinButton{ x, y, scale }) |input| self.form_signals.add(input.as(object.Object), gtk.SpinButton.signals.value_changed.connect(input, *Monitor, monitorSpun, editor, .{}));
            self.form_signals.add(transform.as(object.Object), object.Object.signals.notify.connect(transform.as(object.Object), *Monitor, monitorSelected, editor, .{ .detail = "selected" }));
            self.form_signals.add(mirror.as(object.Object), gtk.Editable.signals.changed.connect(mirror.as(gtk.Editable), *Monitor, monitorEdited, editor, .{}));
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
            const change = try m.parse(alloc, try std.json.Stringify.valueAlloc(alloc, .{ .id = editor.id, .name = editor.name, .x = editor.x.getValueAsInt(), .y = editor.y.getValueAsInt(), .scale = editor.scale.getValue(), .transform = names[@min(7, editor.transform.getSelected())], .mirror_of = std.mem.span(editor.mirror.as(gtk.Editable).getText()), .mode = if (mode.len > 0) @as(?[]const u8, mode) else null }, .{ .emit_null_optional_fields = false }), 4096);
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
            try @import("aqueous_displays.zig").refreshPlacement(self);
            self.update();
        }
        pub fn inventory(self: *Self, box: *gtk.Box, value: m.Value, key: []const u8, title: []const u8) !void {
            const disclosure = w.column(4);
            const button = gtk.ToggleButton.new();
            button.as(gtk.Button).setChild(w.label(self.z(title), null).as(gtk.Widget));
            w.name(button.as(gtk.Widget), self.z(title));
            const label = w.label(self.z(try std.json.Stringify.valueAlloc(self.arena.allocator(), m.get(value, key), .{ .whitespace = .indent_2 })), "pearl-secondary");
            label.setSelectable(1);
            label.as(gtk.Widget).setVisible(0);
            disclosure.append(button.as(gtk.Widget));
            disclosure.append(label.as(gtk.Widget));
            self.form_signals.add(button.as(object.Object), gtk.ToggleButton.signals.toggled.connect(button, *gtk.Widget, inventoryToggled, label.as(gtk.Widget), .{}));
            box.append(disclosure.as(gtk.Widget));
        }
        fn inventoryToggled(button: *gtk.ToggleButton, child: *gtk.Widget) callconv(.c) void {
            child.setVisible(button.getActive());
        }
        fn loadRaw(self: *Self) void {
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
            const terminated = a.dupeSentinel(u8, text, 0) catch return;
            defer a.free(terminated);
            self.raw_buffer.?.setText(terminated, -1);
        }
        pub fn fail(self: *Self, err: anyerror) void {
            self.message.setText(self.z(@errorName(err)));
        }
        pub fn update(self: *Self) void {
            if (self.review_version != self.client.review_version or self.revision != self.client.revision or (self.version != self.client.version and (self.client.draft == null or self.request_buffer == null))) self.build() catch |err| self.fail(err);
            const c = self.client;
            Layout.update(self);
            self.issue_button.as(gtk.Widget).setVisible(@intFromBool(c.err != null));
            self.issue_button.as(gtk.Widget).getParent().?.setVisible(@intFromBool(c.err != null));
            if (self.rules_view) |view| view.update();
            self.updatePreviewDialog();
            self.reload_button.as(gtk.Widget).setVisible(@intFromBool(c.reload_state == .failed or c.reload_state == .unknown or c.reload_state == .unavailable));
            self.reload_button.as(gtk.Widget).setSensitive(@intFromBool(c.job == null and c.reload_ticket == null and !c.unresolved));
            self.preview_buttons[0].as(gtk.Widget).setVisible(@intFromBool(c.previewing()));
            self.preview_buttons[1].as(gtk.Widget).setVisible(@intFromBool(c.previewPhase() != 0 and c.previewPhase() != 2));
            for ([_]*gtk.Button{ self.reload_button, self.preview_buttons[0], self.preview_buttons[1] }) |button| button.as(gtk.Widget).getParent().?.setVisible(button.as(gtk.Widget).getVisible());
            self.preview_buttons[0].as(gtk.Widget).setSensitive(@intFromBool(c.remaining() > 0));
            if (@hasDecl(ClientType, "canChoose")) {
                self.preview_buttons[0].as(gtk.Widget).setSensitive(@intFromBool(c.remaining() > 0 and c.canChoose()));
                self.preview_buttons[1].as(gtk.Widget).setSensitive(@intFromBool(c.canChoose()));
            }
            self.content.as(gtk.Widget).setSensitive(@intFromBool(c.previewPhase() == 0 and !self.rule_move_pending));
            for (self.buttons) |b| b.as(gtk.Widget).setSensitive(@intFromBool(c.job == null));
            self.buttons[2].as(gtk.Widget).setSensitive(@intFromBool(c.job == null and c.draft != null and c.canRevalidate() and !c.unresolved and @import("../config/aqueous_contract.zig").Capabilities.read(c.value()).apply));
            var buffer: [1000]u8 = undefined;
            var countdown: [100]u8 = undefined;
            const outcome = if (c.previewing()) std.fmt.bufPrint(&countdown, "Keep these displays? Reverting in {d}s.", .{c.remaining()}) catch "Display preview" else if (c.job != null) switch (c.previewPhase()) {
                2 => "Saving confirmed display settings…",
                3 => "Waiting for displays to present the preview…",
                4 => "Reverting displays; waiting for completion…",
                5 => "Session inactive; rollback will continue when it resumes…",
                else => "Preparing settings…",
            } else switch (c.outcome) {
                .idle => "Open settings to load the configuration",
                .loaded => "Settings loaded",
                .validated => switch (c.impact_route) {
                    .unknown => "Draft syntax valid; unknown impact blocks save",
                    .display => "Display change: Apply starts a native preview",
                    .runtime => "Runtime change validated",
                    .no_change => "No runtime change; Apply saves file edits",
                },
                .saved => "Settings saved",
                .reverted => "Display preview reverted",
                .invalidated => "Preview ended; competing display changes preserved",
                .failed => "Operation failed",
                .uncertain => "Outcome unresolved; Refresh reconciles the preview and operation receipt. Writes remain blocked.",
            };
            const text = std.mem.printSentinel(&buffer, "{s} · Last result — save: {s} · receipt: {s} · display: {s} · reload: {s} · toolkit sync: {s}{s}{s}{s}{s}{s}{s}", .{
                outcome,                                  if (c.save_state) |state| @tagName(state) else "not requested", if (c.receipt) |state| @tagName(state) else "not requested", @tagName(c.display_state), if (c.reload_state == .not_requested) "not requested" else @tagName(c.reload_state), if (c.toolkit == .not_requested) "not requested" else @tagName(c.toolkit),
                if (c.draft != null) " · draft retained" else "",
                if (c.conflict()) " · external change; review before rebasing" else "",
                if (c.err != null) " · " else "",
                if (c.err) |err| @errorName(err) else "",
                if (c.detail[0] != 0) " · " else "",
                std.mem.sliceTo(&c.detail, 0),
            }, 0) catch "Settings status unavailable";
            if (self.layout.status) |status| status.setText(text);
            self.message.setText(if (self.rule_move_pending) @import("i18n").dtr("pearl", "Rule order changed. Review & apply or Discard before making other Aqueous edits.") else if (c.err != null or c.conflict() or c.unresolved) text else if (c.job != null or c.previewPhase() != 0) self.z(outcome) else if (c.draft != null) @import("i18n").dtr("pearl", "Unsaved Aqueous changes · Review includes every section.") else @import("i18n").dtr("pearl", "All Aqueous settings saved"));
            const simple = self.page_index == 5 and self.display_canvas != null;
            if (!simple and c.draft != null and c.err == null and !c.conflict() and !c.unresolved and c.job == null and !self.rule_move_pending) {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const draft = m.parse(arena.allocator(), c.draft.?, m.max_request) catch .null;
                self.message.setText(layout.map.footer(arena.allocator(), c.baseValue(), draft) catch @import("i18n").dtr("pearl", "Unsaved Aqueous changes"));
            }
            if (simple) self.footer_line.as(gtk.Widget).addCssClass("display-footer") else self.footer_line.as(gtk.Widget).removeCssClass("display-footer");
            self.footer_line.as(gtk.Orientable).setOrientation(if (simple and self.host.as(gtk.Widget).getWidth() >= 620) .horizontal else .vertical);
            self.actions.as(gtk.Widget).setHalign(.fill);
            self.actions.setMinChildrenPerLine(if (simple) 2 else 1);
            self.actions.as(gtk.Widget).setSizeRequest(if (simple) 260 else -1, -1);
            self.message.setMaxWidthChars(if (simple) 42 else -1);
            self.preview_actions.as(gtk.Widget).setVisible(@intFromBool(!self.preview_visible));
            if (simple and c.previewPhase() != 0) self.message.setText(self.z(outcome));
            // Advanced owns routine diagnostics; recovery actions remain available here.
            const recovery_actions = !simple and self.page_index != 6 and (c.err != null or c.conflict() or c.unresolved);
            for ([_]*gtk.Button{ self.buttons[0], self.buttons[1], self.draft_buttons[1] }) |button| {
                button.as(gtk.Widget).setVisible(@intFromBool(recovery_actions));
                button.as(gtk.Widget).getParent().?.setVisible(@intFromBool(recovery_actions));
            }
            self.draft_buttons[0].as(gtk.Widget).setSensitive(@intFromBool(c.job == null and c.draft != null));
            self.draft_buttons[0].setLabel(@import("i18n").dtr("pearl", "Discard"));
            self.buttons[2].setLabel(if (c.job != null) @import("i18n").dtr("pearl", "Checking settings…") else if (simple) @import("i18n").dtr("pearl", "Apply changes") else @import("i18n").dtr("pearl", "Review & apply"));
            self.preview_buttons[0].setLabel(if (simple) @import("i18n").dtr("pearl", "Keep changes") else @import("i18n").dtr("pearl", "Keep displays"));
            self.preview_buttons[1].setLabel(if (simple) @import("i18n").dtr("pearl", "Revert") else @import("i18n").dtr("pearl", "Revert displays"));
            if (simple and (self.display_blocked or self.display_changes + self.display_other_changes == 0)) self.buttons[2].as(gtk.Widget).setSensitive(0);
            if (simple and c.previewPhase() == 0 and c.job == null and c.err == null and !c.conflict() and !c.unresolved) {
                var message: [256]u8 = undefined;
                self.message.setText(if (c.draft != null) (std.mem.printSentinel(&message, "{d} unsaved display changes · {d} other Aqueous changes.\nApply to try this setup. Keep it only if everything looks right.", .{ self.display_changes, self.display_other_changes }, 0) catch "Display settings") else @import("i18n").dtr("pearl", "All display settings saved.\nChanges take effect only when you apply them."));
            }
            if (c.job == null and (c.err != null or c.unresolved or (c.outcome == .saved and c.draft == null))) {
                const status = std.mem.span(self.message.getText());
                if (!std.mem.eql(u8, status, std.mem.sliceTo(&self.announced_status, 0))) {
                    _ = std.mem.printSentinel(&self.announced_status, "{s}", .{status}, 0) catch "";
                    self.message.as(gtk.Accessible).announce(self.message.getText(), .medium);
                }
            }
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
        fn styleDialog(self: *Self, dialog: *gtk.Window) void {
            const classes = self.window.as(gtk.Widget).getCssClasses();
            defer glib.strfreev(@ptrCast(classes));
            dialog.as(gtk.Widget).setCssClasses(@ptrCast(classes));
            dialog.as(gtk.Widget).addCssClass("display-confirmation");
        }
        fn updatePreviewDialog(self: *Self) void {
            const c = self.client;
            if (!@hasDecl(ClientType, "standalone")) return;
            if (!c.previewing() and !self.preview_visible) return;
            if (self.preview_dialog == null) {
                const dialog = gtk.Window.new();
                self.styleDialog(dialog);
                dialog.setTitle(@import("i18n").dtr("pearl", "Keep these display settings?"));
                dialog.setTransientFor(self.window);
                dialog.setModal(1);
                dialog.setDefaultSize(460, -1);
                const content = w.column(18);
                inline for (.{ gtk.Widget.setMarginStart, gtk.Widget.setMarginEnd, gtk.Widget.setMarginTop, gtk.Widget.setMarginBottom }) |set| set(content.as(gtk.Widget), 24);
                content.append(w.label(@import("i18n").dtr("pearl", "Keep these display settings?"), "pearl-title").as(gtk.Widget));
                const message = w.label("", "pearl-secondary");
                message.setMaxWidthChars(48);
                content.append(message.as(gtk.Widget));
                const actions = w.row(12);
                actions.as(gtk.Widget).setHalign(.end);
                const revert = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "Revert"));
                const keep = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "Keep changes"));
                keep.as(gtk.Widget).addCssClass("pearl-primary");
                actions.append(revert.as(gtk.Widget));
                actions.append(keep.as(gtk.Widget));
                content.append(actions.as(gtk.Widget));
                dialog.setChild(content.as(gtk.Widget));
                self.preview_dialog = dialog;
                self.preview_message = message;
                self.preview_keep = keep;
                self.preview_revert = revert;
                self.root_signals.add(dialog.as(object.Object), gtk.Window.signals.close_request.connect(dialog, *Self, previewClosed, self, .{}));
                self.root_signals.add(keep.as(object.Object), gtk.Button.signals.clicked.connect(keep, *Self, kept, self, .{}));
                self.root_signals.add(revert.as(object.Object), gtk.Button.signals.clicked.connect(revert, *Self, reverted, self, .{}));
                const keys = gtk.EventControllerKey.new();
                self.root_signals.add(keys.as(object.Object), gtk.EventControllerKey.signals.key_pressed.connect(keys, *Self, previewKey, self, .{}));
                dialog.as(gtk.Widget).addController(keys.as(gtk.EventController));
            }
            if (c.previewPhase() == 0) {
                self.preview_dialog.?.as(gtk.Widget).setVisible(0);
                self.preview_visible = false;
                return;
            }
            var buffer: [512]u8 = undefined;
            const text = if (c.previewing()) (std.mem.printSentinel(&buffer, "Your displays are using the new settings. Check every screen. Reverting in {d} seconds.\n\nKeep changes saves the complete Aqueous draft. Revert restores your previous displays and retains your edits.", .{c.remaining()}, 0) catch "Check every screen before keeping these settings.") else switch (c.previewPhase()) {
                2 => "Saving confirmed settings…",
                4 => "Reverting displays. Waiting for Aqueous to confirm completion…",
                5 => "Session inactive. Rollback will continue when the session resumes.",
                else => "Waiting for the display operation to complete…",
            };
            self.styleDialog(self.preview_dialog.?);
            self.preview_message.?.setText(text);
            const can_choose = if (@hasDecl(ClientType, "canChoose")) c.canChoose() else true;
            self.preview_keep.?.as(gtk.Widget).setSensitive(@intFromBool(c.previewing() and c.remaining() > 0 and can_choose));
            self.preview_revert.?.as(gtk.Widget).setSensitive(@intFromBool(c.previewing() and can_choose));
            if (!self.preview_visible) {
                self.preview_visible = true;
                self.preview_dialog.?.present();
                _ = self.preview_revert.?.as(gtk.Widget).grabFocus();
            }
        }
        fn previewClosed(_: *gtk.Window, self: *Self) callconv(.c) c_int {
            if (self.client.previewing()) self.client.choose(false) catch |err| self.fail(err);
            return 1;
        }
        fn previewKey(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, _: gdk.ModifierType, self: *Self) callconv(.c) c_int {
            if (key != gdk.KEY_Escape) return 0;
            return previewClosed(self.preview_dialog.?, self);
        }
        pub fn syncRequest(self: *Self) void {
            self.revision = self.client.revision;
            self.filling = true;
            defer self.filling = false;
            const text = a.dupeSentinel(u8, self.client.draft orelse "{}", 0) catch return;
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
        pub fn perform(self: *Self, action: layout.Action) void {
            switch (action) {
                .refresh => refreshed(self.buttons[0], self),
                .validate => validated(self.buttons[1], self),
                .rebase => rebased(self.draft_buttons[1], self),
                .appearance => if (self.open_appearance) |link| link.notify(link.context),
            }
        }
        fn refreshed(_: *gtk.Button, self: *Self) callconv(.c) void {
            self.client.begin(.refresh) catch |err| self.fail(err);
        }
        fn discarded(_: *gtk.Button, self: *Self) callconv(.c) void {
            if (self.confirmShared(true)) return;
            self.client.discard();
            self.build() catch |err| self.fail(err);
            self.update();
        }
        fn validated(_: *gtk.Button, self: *Self) callconv(.c) void {
            self.client.begin(.validate) catch |err| self.fail(err);
        }
        fn applied(_: *gtk.Button, self: *Self) callconv(.c) void {
            if (self.confirmShared(false)) return;
            self.client.begin(.apply) catch |err| self.fail(err);
        }
        fn confirmShared(displays: *Self, discard: bool) bool {
            if (displays.client.draft == null) return false;
            if (displays.page_index == 5 and displays.display_other_changes == 0) return false;
            if (displays.shared_dialog) |dialog| {
                dialog.as(gtk.Window).present();
                return true;
            }
            const self = displays;
            const dialog = gtk.Dialog.new();
            const win = dialog.as(gtk.Window);
            self.styleDialog(win);
            win.setTitle(if (discard) @import("i18n").dtr("pearl", "Discard all Aqueous changes?") else @import("i18n").dtr("pearl", "Review Aqueous changes"));
            win.setTransientFor(self.window);
            win.setModal(1);
            win.setDefaultSize(@min(520, @max(300, self.window.as(gtk.Widget).getWidth() - 40)), 420);
            self.shared_dialog = dialog;
            self.shared_discard = discard;
            self.shared_revision = self.client.revision;
            const scroller = gtk.ScrolledWindow.new();
            scroller.setPolicy(.never, .automatic);
            scroller.as(gtk.Widget).setVexpand(1);
            const content = w.column(12);
            scroller.setChild(content.as(gtk.Widget));
            dialog.getContentArea().append(scroller.as(gtk.Widget));
            inline for (.{ gtk.Widget.setMarginStart, gtk.Widget.setMarginEnd, gtk.Widget.setMarginTop, gtk.Widget.setMarginBottom }) |set| set(content.as(gtk.Widget), 20);
            content.append(w.label(@import("i18n").dtr("pearl", "This action includes the complete Aqueous draft. Pearl preferences are separate."), null).as(gtk.Widget));
            const draft = m.parse(self.arena.allocator(), self.client.draft orelse "{}", m.max_request) catch .null;
            const summary = layout.map.summary(self.arena.allocator(), self.client.baseValue(), draft) catch "Other Aqueous settings";
            content.append(w.label(self.z(summary), "pearl-secondary").as(gtk.Widget));
            content.append(w.label(@import("i18n").dtr("pearl", "Apply validates the candidate. Display effects require a protected preview before saving."), "pearl-secondary").as(gtk.Widget));
            const cancel = dialog.addButton(@import("i18n").dtr("pearl", "Cancel"), 0);
            const accept = dialog.addButton(if (discard) @import("i18n").dtr("pearl", "Discard all Aqueous changes") else @import("i18n").dtr("pearl", "Apply all Aqueous changes"), 1);
            for ([_]*gtk.Widget{ cancel, accept }) |button| if (object.ext.cast(gtk.Button, button)) |b| if (b.getChild()) |child| if (object.ext.cast(gtk.Label, child)) |label| {
                label.setWrap(1);
                label.setWrapMode(.word_char);
            };
            accept.addCssClass("pearl-primary");
            self.root_signals.add(dialog.as(object.Object), gtk.Dialog.signals.response.connect(dialog, *Self, sharedResponse, self, .{}));
            win.present();
            _ = cancel.grabFocus();
            return true;
        }
        fn sharedResponse(dialog: *gtk.Dialog, response: c_int, self: *Self) callconv(.c) void {
            dialog.as(gtk.Window).destroy();
            self.shared_dialog = null;
            _ = (if (self.shared_discard) self.draft_buttons[0] else self.buttons[2]).as(gtk.Widget).grabFocus();
            if (response != 1) return;
            if (self.shared_revision != self.client.revision) {
                self.fail(error.StaleDraft);
                return;
            }
            if (self.shared_discard) {
                self.client.discard();
                self.build() catch |err| self.fail(err);
                self.update();
            } else self.client.begin(.apply) catch |err| self.fail(err);
        }
        pub fn sharedFocus(self: *Self) []const u8 {
            const dialog = self.shared_dialog orelse return "";
            const focus = dialog.as(gtk.Window).getFocus() orelse return "";
            if (dialog.getWidgetForResponse(1)) |accept| if (focus == accept or focus.isAncestor(accept) != 0) return "accept";
            if (dialog.getWidgetForResponse(0)) |cancel| if (focus == cancel or focus.isAncestor(cancel) != 0) return "cancel";
            return "content";
        }
        fn rebased(_: *gtk.Button, self: *Self) callconv(.c) void {
            self.client.rebase() catch |err| {
                self.fail(err);
                return;
            };
            self.build() catch |err| self.fail(err);
            self.update();
        }
        fn kept(_: *gtk.Button, self: *Self) callconv(.c) void {
            self.client.choose(true) catch |err| self.fail(err);
        }
        fn reverted(_: *gtk.Button, self: *Self) callconv(.c) void {
            self.client.choose(false) catch |err| self.fail(err);
        }
        fn reloaded(_: *gtk.Button, self: *Self) callconv(.c) void {
            self.client.requestReload() catch |err| self.fail(err);
        }
        fn rawSelected(_: *object.Object, _: *object.ParamSpec, self: *Self) callconv(.c) void {
            self.layout.raw_source = self.raw_file.?.getSelected();
            self.loadRaw();
        }
        fn rawEdited(_: *gtk.TextBuffer, self: *Self) callconv(.c) void {
            if (!self.filling) self.stageRaw() catch |err| self.fail(err);
        }
        fn stageRaw(self: *Self) !void {
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
            self.forms_stale = true;
            self.update();
        }
        fn requestEdited(buffer: *gtk.TextBuffer, self: *Self) callconv(.c) void {
            if (self.filling) return;
            const text = bufferText(buffer);
            defer glib.free(text);
            self.client.keepDraft(std.mem.span(text)) catch |err| {
                self.fail(err);
                return;
            };
            self.revision = self.client.revision;
            self.forms_stale = true;
            self.update();
        }
        fn inserting(buffer: *gtk.TextBuffer, _: *gtk.TextIter, _: [*:0]u8, length: c_int, self: *Self) callconv(.c) void {
            if (self.filling or length < 0) return;
            if (@as(usize, @intCast(buffer.getCharCount())) * 4 + @as(usize, @intCast(length)) > m.max_request) object.signalStopEmissionByName(buffer.as(object.Object), "insert-text");
        }
        pub fn recordEntry(self: *Self, row: *gtk.Box, input: *gtk.Widget) !void {
            const editor = try self.arena.allocator().create(Editor);
            const button = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "Record custom shortcut"));
            if (@import("build_options").test_hooks) button.as(gtk.Widget).setName("Record custom shortcut");
            row.append(button.as(gtk.Widget));
            editor.* = .{ .view = self, .field = .null, .widget = input, .record = button };
            self.form_signals.add(button.as(object.Object), gtk.Button.signals.clicked.connect(button, *Editor, recordClicked, editor, .{}));
        }
        fn recordClicked(_: *gtk.Button, editor: *Editor) callconv(.c) void {
            editor.view.startRecording(editor) catch |err| editor.view.fail(err);
        }
        pub fn record(self: *Self, id: []const u8) !void {
            self.selectPage(3);
            for (self.editors.items) |editor| if (editor.record != null and std.mem.eql(u8, m.str(m.get(editor.field, "id")), id)) {
                if (self.layout.sections[@backingInt(editor.group)]) |section| section.reveal();
                return self.startRecording(editor);
            };
            return error.UnknownField;
        }
        fn selectPage(self: *Self, index: c_int) void {
            const notebook = self.notebook orelse return;
            if (@hasDecl(ClientType, "standalone")) {
                if (index >= 0 and index < self.page_count) if (self.page_widgets[@intCast(index)]) |child| notebook.setVisibleChild(child);
            } else notebook.setCurrentPage(index);
        }
        pub fn showPage(self: *Self, name: []const u8) !void {
            if (self.forms_stale and !self.filling) try self.build();
            if (self.issue_focus[0] != 0) self.revealIssue();
            const names = @import("settings_navigation.zig").aqueous_sections;
            for (names, 0..) |v, index| if (std.mem.eql(u8, v, name)) {
                self.page_index = @intCast(index);
                if (self.notebook) |notebook| {
                    self.selectPage(@intCast(index));
                    // The standalone window restores its own section focus.
                    if (!@hasDecl(ClientType, "standalone")) {
                        if (notebook.getNthPage(@intCast(index))) |page_widget| _ = page_widget.childFocus(.tab_forward);
                    }
                }
                return;
            };
            return error.UnknownPage;
        }
        fn issueClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
            const detail = std.mem.sliceTo(&self.client.detail, 0);
            var section: []const u8 = "advanced";
            @memset(&self.issue_focus, 0);
            for (self.editors.items) |editor| {
                const id = m.str(m.get(editor.field, "id"));
                if (id.len == 0 or id.len >= self.issue_focus.len or std.mem.indexOf(u8, detail, id) == null) continue;
                @memcpy(self.issue_focus[0..id.len], id);
                section = layout.map.spec(editor.group).page;
                break;
            }
            if (self.issue_focus[0] == 0) @memcpy(self.issue_focus[0..8], "@request");
            self.revealIssue();
            if (self.open_section) |callback| callback.notify(callback.context, section) else self.showPage(section) catch {};
        }
        fn revealIssue(self: *Self) void {
            const id = std.mem.sliceTo(&self.issue_focus, 0);
            if (std.mem.eql(u8, id, "@request")) {
                if (self.layout.sections[@backingInt(layout.map.Group.request)]) |section| section.reveal();
            } else for (self.editors.items) |editor| if (std.mem.eql(u8, id, m.str(m.get(editor.field, "id")))) {
                if (std.mem.eql(u8, m.fieldCategory(editor.field), "keybinds")) {
                    @memset(&self.layout.search, 0);
                    if (self.layout.search_entry) |entry| entry.as(gtk.Editable).setText("");
                    Layout.filter(self);
                }
                if (self.layout.sections[@backingInt(editor.group)]) |section| section.reveal();
                break;
            };
        }
        pub fn focusIssue(self: *Self) bool {
            if (self.issue_focus[0] == 0) return false;
            defer @memset(&self.issue_focus, 0);
            const id = std.mem.sliceTo(&self.issue_focus, 0);
            for (self.editors.items) |editor| if (std.mem.eql(u8, id, m.str(m.get(editor.field, "id")))) return editor.widget.grabFocus() != 0;
            if (self.layout.sections[@backingInt(layout.map.Group.request)]) |section| if (section.button) |button| return button.as(gtk.Widget).grabFocus() != 0;
            return false;
        }
        pub fn focusName(window: *gtk.Window) []const u8 {
            var current = window.getFocus();
            while (current) |widget| : (current = widget.getParent()) {
                const name = std.mem.span(widget.getName());
                if (!std.mem.startsWith(u8, name, "Gtk")) return name;
            }
            return if (window.getFocus()) |focus| std.mem.span(focus.getName()) else "none";
        }
        fn startRecording(self: *Self, editor: *Editor) !void {
            self.stopRecording();
            if (self.client.job != null or !self.client.canRecord()) return error.ShortcutInhibitionUnavailable;
            const surface = self.window.as(gtk.Native).getSurface() orelse return error.ShortcutInhibitionUnavailable;
            const toplevel = object.ext.cast(gdk.Toplevel, surface) orelse return error.ShortcutInhibitionUnavailable;
            self.inhibited = toplevel;
            self.recording = editor;
            _ = editor.widget.grabFocus();
            toplevel.inhibitSystemShortcuts(null);
            self.record_deadline = glib.getMonotonicTime() + 30000000;
            self.record_timer = glib.timeoutAdd(50, recordTick, self);
            self.message.setText(@import("i18n").dtr("pearl", "Waiting for Aqueous to inhibit shortcuts… Escape cancels."));
        }
        pub fn stopRecording(self: *Self) void {
            if (self.record_timer != 0) _ = glib.Source.remove(self.record_timer);
            self.record_timer = 0;
            if (self.inhibited) |v| v.restoreSystemShortcuts();
            self.inhibited = null;
            self.recording = null;
            self.client.recording = false;
        }
        fn recordTick(data: ?*anyopaque) callconv(.c) c_int {
            const self: *Self = @ptrCast(@alignCast(data.?));
            if (glib.getMonotonicTime() >= self.record_deadline or self.host.as(gtk.Widget).getMapped() == 0 or !self.client.canRecord()) {
                log.info("event=shortcut-record-ended reason=deadline-or-unmapped", .{});
                self.record_timer = 0;
                self.stopRecording();
                self.message.setText(@import("i18n").dtr("pearl", "Shortcut recording cancelled."));
                return 0;
            }
            var inhibited: c_int = 0;
            self.inhibited.?.as(object.Object).get("shortcuts-inhibited", &inhibited, @as(?[*:0]const u8, null));
            if (inhibited == 0 and self.client.recording) {
                log.info("event=shortcut-record-ended reason=revoked", .{});
                self.record_timer = 0;
                self.stopRecording();
                self.message.setText(@import("i18n").dtr("pearl", "Shortcut inhibition was revoked."));
                return 0;
            }
            if (inhibited != 0 and !self.client.recording) {
                self.client.recording = true;
                self.message.setText(@import("i18n").dtr("pearl", "Press a shortcut. Escape cancels; recording ends after 30 seconds."));
            }
            return 1;
        }
        fn recorded(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, modifiers: gdk.ModifierType, self: *Self) callconv(.c) c_int {
            const editor = self.recording orelse return 0;
            if (key == 0xff1b) {
                self.stopRecording();
                self.message.setText(@import("i18n").dtr("pearl", "Shortcut recording cancelled."));
                return 1;
            }
            if (!self.client.recording) return 1;
            if (key >= 0xffe1 and key <= 0xffee) return 1; // modifier-only press
            const name = gdk.keyvalName(key) orelse return 1;
            var buffer: [256]u8 = undefined;
            const chord = std.mem.printSentinel(&buffer, "{s}{s}{s}{s}{s}", .{ if (modifiers.super_mask) "Super+" else "", if (modifiers.control_mask) "Ctrl+" else "", if (modifiers.alt_mask) "Alt+" else "", if (modifiers.shift_mask) "Shift+" else "", std.mem.span(name) }, 0) catch return 1;
            self.stopRecording();
            object.ext.cast(gtk.Editable, editor.widget).?.setText(chord);
            return 1;
        }
        fn switched(_: *gtk.Notebook, _: *gtk.Widget, page_index: c_uint, self: *Self) callconv(.c) void {
            if (!self.filling) self.page_index = @intCast(page_index);
            self.stopRecording();
            if (!self.filling and self.forms_stale) self.build() catch |err| self.fail(err);
        }
    };
}

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
