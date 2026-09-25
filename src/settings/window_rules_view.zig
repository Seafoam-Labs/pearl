//! Ordered window rules; Aqueous owns the schema, draft and apply lifecycle.
const std = @import("std");
const gtk = @import("gtk4");
const object = @import("gobject2");
const glib = @import("glib2");
const m = @import("../config/aqueous_model.zig");
const projection = @import("../config/aqueous_rule_editor.zig");
const mutations = @import("../config/aqueous_collections.zig");
const builder = @import("rule_builder.zig");
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;
pub fn For(comptime Parent: type) type {
    return struct {
        const Self = @This();
        const Action = struct { self: *Self, rule: ?projection.Rule = null, direction: ?i64 = null };
        const Field = struct { self: *Self, spec: m.Value, row: *gtk.Box, input: *gtk.Widget, active: bool, empty: ?*gtk.CheckButton = null };
        parent: *Parent,
        host: ?*gtk.Box = null,
        add: ?*gtk.Button = null,
        arena: std.heap.ArenaAllocator = .init(a),
        shell: ?builder.Shell = null,
        error_label: ?*gtk.Label = null,
        fields: std.ArrayList(*Field) = .empty,
        controls: std.ArrayList(builder.Control) = .empty,
        dialog_controls: std.ArrayList(builder.Control) = .empty,
        choosers: [2]?*gtk.DropDown = .{ null, null },
        add_buttons: [2]?*gtk.Button = .{ null, null },
        original: projection.Rule = .{ .values = .{ .object = .empty } },
        is_new: bool = true,
        version: u64 = 0,
        revision: u64 = 0,
        draft_hash: [64]u8 = undefined,
        visible: bool = true,
        focus_id: ?[]const u8 = null,
        focus_source: c_uint = 0,
        page: usize = 0,
        const page_size = 40;
        pub fn create(parent: *Parent) !*Self {
            const self = try a.create(Self);
            self.* = .{ .parent = parent };
            return self;
        }
        pub fn detach(self: *Self) void {
            self.host = null;
            self.add = null;
            self.controls.clearRetainingCapacity();
        }
        pub fn destroy(self: *Self) void {
            if (self.focus_source != 0) _ = glib.Source.remove(self.focus_source);
            self.close();
            self.arena.deinit();
            self.controls.deinit(a);
            self.dialog_controls.deinit(a);
            if (self.focus_id) |id| a.free(id);
            a.destroy(self);
        }
        fn z(self: *Self, bytes: []const u8) [:0]const u8 {
            return self.arena.allocator().dupeZ(u8, bytes) catch "";
        }
        fn text(host: *gtk.Box, value: [:0]const u8, css: ?[*:0]const u8) void {
            const label = w.label(value, css);
            label.setWrap(1);
            host.append(label.as(gtk.Widget));
        }
        fn editable(self: *Self) bool {
            const c = self.parent.client;
            if (c.job != null or c.conflict() or c.previewPhase() != 0 or c.unresolved) return false;
            if (@hasField(@TypeOf(c.*), "ready")) return c.ready and c.online and !c.locked and !c.suspended and !c.recovery;
            return true;
        }
        fn canPresent(self: *Self) bool {
            const c = self.parent.client;
            if (!self.visible or self.parent.page_index != 4) return false;
            if (@hasField(@TypeOf(c.*), "ready")) return c.online and !c.locked and !c.suspended;
            return self.parent.host.as(gtk.Widget).getMapped() != 0;
        }
        pub fn update(self: *Self) void {
            if (self.host) |host| host.as(gtk.Widget).setSensitive(@intFromBool(self.editable()));
            if (self.shell) |shell| {
                builder.style(shell.dialog, self.parent.window);
                shell.dialog.as(gtk.Widget).setVisible(@intFromBool(self.canPresent()));
                for ([_]c_int{ 1, @intFromEnum(gtk.ResponseType.accept) }) |response| if (shell.dialog.getWidgetForResponse(response)) |response_button| response_button.setSensitive(@intFromBool(self.editable()));
            }
        }
        fn control(self: *Self, id: []const u8, widget: *gtk.Widget, dialog: bool) !void {
            if (dialog) try self.dialog_controls.append(a, .{ .id = id, .widget = widget }) else try self.controls.append(a, .{ .id = id, .widget = widget });
        }
        fn button(self: *Self, host: anytype, label: [:0]const u8, id: []const u8, action: Action) !*gtk.Button {
            const button_ = w.wrappingButton(label);
            if (@TypeOf(host) == *gtk.FlowBox) host.insert(button_.as(gtk.Widget), -1) else host.append(button_.as(gtk.Widget));
            w.name(button_.as(gtk.Widget), label);
            const bound = try self.parent.arena.allocator().create(Action);
            bound.* = action;
            self.parent.form_signals.add(button_.as(object.Object), gtk.Button.signals.clicked.connect(button_, *Action, clicked, bound, .{}));
            try self.control(id, button_.as(gtk.Widget), false);
            return button_;
        }
        fn shortValue(alloc: std.mem.Allocator, value: m.Value) ![]const u8 {
            const bytes = try std.json.Stringify.valueAlloc(alloc, value, .{});
            if (bytes.len <= 160) return bytes;
            var end: usize = 160;
            while (end > 0 and !std.unicode.utf8ValidateSlice(bytes[0..end])) end -= 1;
            return std.fmt.allocPrint(alloc, "{s}…", .{bytes[0..end]});
        }
        fn summary(alloc: std.mem.Allocator, values: m.Value, conditions: bool) ![:0]const u8 {
            var out: std.Io.Writer.Allocating = .init(alloc);
            if (values == .object) {
                var it = values.object.iterator();
                while (it.next()) |e| {
                    if ((projection.matcher(e.key_ptr.*) or std.mem.eql(u8, e.key_ptr.*, "scope")) != conditions) continue;
                    if (out.written().len > 0) try out.writer.writeAll(" · ");
                    const value = try shortValue(alloc, e.value_ptr.*);
                    try out.writer.print("{s}: {s}", .{ labelFor(e.key_ptr.*), value });
                }
            }
            return alloc.dupeZ(u8, if (out.written().len == 0) (if (conditions) "No conditions — this rule does not match windows" else "No explicit effects — later matching rules are still skipped") else out.written());
        }
        pub fn render(self: *Self, host: *gtk.Box, snapshot: m.Value) !void {
            self.host = host;
            const alloc = self.parent.arena.allocator();
            text(host, "Window rules", "pearl-card-title");
            text(host, "Rules run from top to bottom. All conditions must match; the first matching rule applies. Later rules do not supply missing settings.", "pearl-secondary");
            if (!@import("../config/aqueous_contract.zig").Capabilities.read(snapshot).collections) {
                text(host, "Structured rules require a newer Aqueous helper with collection schema, identity and precondition support. Use Advanced to inspect your configuration.", "pearl-secondary");
                return;
            }
            const request = m.parse(alloc, self.parent.client.draft orelse "{}", m.max_request) catch {
                text(host, "Repair the invalid draft in Advanced before editing rules.", "pearl-secondary");
                return;
            };
            const rows = projection.project(alloc, snapshot, request) catch {
                text(host, "The rule draft no longer matches this snapshot. Review Advanced, then rebase or discard the draft.", "pearl-secondary");
                return;
            };
            const blocked = projection.hasMove(request) or m.get(m.get(request, "raw_files"), "rules") != .null;
            self.add = try self.button(host, "Add rule", "rules.add", .{ .self = self });
            self.add.?.as(gtk.Widget).setSensitive(@intFromBool(!blocked));
            if (blocked) text(host, "Apply or discard the pending move or raw rules edit before editing rules.", "pearl-secondary");
            if (rows.len == 0) text(host, "No window rules yet. New windows use normal Aqueous behavior until a rule matches.", "pearl-secondary");
            self.page = @min(self.page, if (rows.len == 0) 0 else (rows.len - 1) / page_size);
            const start = self.page * page_size;
            const end = @min(rows.len, start + page_size);
            text(host, try std.fmt.allocPrintSentinel(alloc, "{d} rules · showing {d}–{d}", .{ rows.len, if (rows.len == 0) 0 else start + 1, end }, 0), "pearl-secondary");
            for (rows[start..end], start..) |rule, i| {
                const card = builder.card();
                host.append(card.as(gtk.Widget));
                text(card, try std.fmt.allocPrintSentinel(alloc, "{d}. {s}{s}", .{ i + 1, try summary(alloc, rule.values, true), if (rule.pending != null) " (unsaved)" else "" }, 0), "settings-row-title");
                text(card, try summary(alloc, rule.values, false), "pearl-secondary");
                const actions = w.flow(3);
                actions.setHomogeneous(0);
                card.append(actions.as(gtk.Widget));
                const id = if (rule.pending) |index| try std.fmt.allocPrint(alloc, "new.{d}", .{index}) else m.str(rule.id);
                const edit = try self.button(actions, "Edit rule", try std.fmt.allocPrint(alloc, "rules.edit.{s}", .{id}), .{ .self = self, .rule = rule });
                w.name(edit.as(gtk.Widget), try std.fmt.allocPrintSentinel(alloc, "Edit rule {d}", .{i + 1}, 0));
                edit.as(gtk.Widget).setSensitive(@intFromBool(!blocked));
                for ([_]i64{ -1, 1 }) |d| {
                    const button_ = try self.button(actions, if (d == -1) "Move earlier" else "Move later", try std.fmt.allocPrint(alloc, "rules.{s}.{s}", .{ if (d == -1) "up" else "down", id }), .{ .self = self, .rule = rule, .direction = d });
                    w.name(button_.as(gtk.Widget), try std.fmt.allocPrintSentinel(alloc, "Move rule {d} {s}", .{ i + 1, if (d == -1) "earlier" else "later" }, 0));
                    button_.as(gtk.Widget).setSensitive(@intFromBool(self.parent.client.draft == null and rule.pending == null and (if (d == -1) i > 0 else i + 1 < rows.len)));
                }
            }
            if (rows.len > page_size) {
                for ([_]bool{ false, true }) |next| {
                    const button_ = w.wrappingButton(if (next) "Next rules" else "Previous rules");
                    host.append(button_.as(gtk.Widget));
                    const action = try alloc.create(Action);
                    action.* = .{ .self = self, .direction = if (next) 1 else -1 };
                    self.parent.form_signals.add(button_.as(object.Object), gtk.Button.signals.clicked.connect(button_, *Action, pageClicked, action, .{}));
                    button_.as(gtk.Widget).setSensitive(@intFromBool(if (next) end < rows.len else start > 0));
                }
            }
            text(host, "Save rule stages an Aqueous draft. Apply & save saves all pending Aqueous changes. Moving a rule is a separate transaction; apply or discard it before making other edits.", "pearl-secondary");
            const tester = gtk.Expander.new("Test window");
            const test_body = w.column(8);
            text(test_body, "Testing requires an Aqueous helper and Pearl backend that expose authoritative window-rule testing. This session does not offer it. Validate checks the draft without creating or moving a window.", "pearl-secondary");
            tester.setChild(test_body.as(gtk.Widget));
            host.append(tester.as(gtk.Widget));
            try self.control("rules.tester", tester.as(gtk.Widget), false);
            self.update();
        }
        fn pageClicked(_: *gtk.Button, action: *Action) callconv(.c) void {
            const self = action.self;
            if (action.direction.? > 0) self.page += 1 else self.page -|= 1;
            self.parent.build() catch |err| self.parent.fail(err);
        }
        fn clicked(_: *gtk.Button, action: *Action) callconv(.c) void {
            const self = action.self;
            if (action.direction) |d| self.move(action.rule.?, d) catch |err| self.parent.fail(err) else self.open(action.rule) catch |err| self.parent.fail(err);
        }
        fn move(self: *Self, rule: projection.Rule, direction: i64) !void {
            if (!self.editable() or self.parent.client.draft != null) return error.SaveRuleMoveFirst;
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const alloc = scratch.allocator();
            const change = try m.parse(alloc, try std.json.Stringify.valueAlloc(alloc, .{ .op = "move", .id = rule.id, .direction = direction }, .{}), 8192);
            try self.parent.client.keepDraft(try mutations.stage(alloc, self.parent.client.baseValue(), try self.parent.client.emptyDraft(alloc), projection.key, change));
            self.parent.syncRequest();
            try self.parent.build();
        }
        fn close(self: *Self) void {
            self.dialog_controls.clearRetainingCapacity();
            if (self.shell) |shell| {
                self.shell = null;
                shell.dialog.as(gtk.Window).destroy();
                shell.dialog.unref();
            }
            self.error_label = null;
            self.fields = .empty;
            self.choosers = .{ null, null };
            self.add_buttons = .{ null, null };
            _ = self.arena.reset(.retain_capacity);
        }
        fn open(self: *Self, rule: ?projection.Rule) !void {
            if (!self.editable() or self.shell != null) return;
            const c = self.parent.client;
            const alloc = self.arena.allocator();
            self.version = c.version;
            self.revision = c.revision;
            self.draft_hash = @import("editor_protocol.zig").digest(c.draft orelse "");
            self.is_new = rule == null;
            self.original = if (rule) |r| .{ .id = try m.parse(alloc, try std.json.Stringify.valueAlloc(alloc, r.id, .{}), m.max_request), .pending = r.pending, .values = try m.parse(alloc, try std.json.Stringify.valueAlloc(alloc, r.values, .{}), m.max_request) } else .{ .values = .{ .object = .empty } };
            if (self.focus_id) |id| a.free(id);
            self.focus_id = null;
            self.focus_id = if (rule) |r| if (r.pending) |index| try std.fmt.allocPrint(a, "rules.edit.new.{d}", .{index}) else try std.fmt.allocPrint(a, "rules.edit.{s}", .{m.str(r.id)}) else try a.dupe(u8, "rules.add");
            const shell = builder.open(self.parent.window, if (rule == null) "Add window rule" else "Edit window rule");
            self.shell = shell;
            errdefer self.close();
            const schema = try m.parse(alloc, try std.json.Stringify.valueAlloc(alloc, m.get(m.get(m.get(c.baseValue(), "collection_schema"), "window_rules"), "fields"), .{}), m.max_response);
            const conditions = w.column(8);
            const effects = w.column(8);
            shell.body.append(conditions.as(gtk.Widget));
            shell.body.append(effects.as(gtk.Widget));
            text(conditions, "When a window matches", "pearl-card-title");
            text(conditions, "All conditions must match. Patterns match the entire value and are case sensitive: * matches any bytes; ? matches one byte. Launch tag alone supports backslash escaping; a missing tag never matches.", "pearl-secondary");
            text(effects, "Apply these settings", "pearl-card-title");
            text(effects, "Remove a setting to inherit normal Aqueous behavior. Off and zero are explicit settings. Content-type rules apply only visual/client-buffer effects; placement is ignored. Unmanaged scope has restricted effects. Validate checks restrictions.", "pearl-secondary");
            for (m.list(schema)) |spec| {
                const k = m.str(m.get(spec, "key"));
                if (!projection.known(k)) continue;
                const value = m.get(self.original.values, k);
                mutations.scalar(spec, value) catch continue; // preserve newer/unknown values verbatim
                if (value == .string and value.string.len > 1024) continue;
                const field = try alloc.create(Field);
                const row = builder.card();
                const is_condition = projection.matcher(k) or std.mem.eql(u8, k, "scope");
                (if (is_condition) conditions else effects).append(row.as(gtk.Widget));
                const typ = m.str(m.get(spec, "type"));
                const options = m.list(m.get(spec, "options"));
                var input: *gtk.Widget = undefined;
                if (std.mem.eql(u8, typ, "boolean")) {
                    const choice = builder.choiceRow(row, self.z(labelFor(k)), &.{ "On", "Off", null });
                    choice.setSelected(if (m.equal(value, .{ .bool = false })) 1 else 0);
                    input = choice.as(gtk.Widget);
                } else if (options.len > 0) {
                    const names = try alloc.allocSentinel(?[*:0]const u8, options.len, null);
                    for (options, 0..) |option, i| names[i] = self.z(m.str(option));
                    const choice = builder.choiceRow(row, self.z(labelFor(k)), names);
                    for (options, 0..) |option, i| if (m.equal(option, value)) {
                        choice.setSelected(@intCast(i));
                        break;
                    };
                    input = choice.as(gtk.Widget);
                } else {
                    const entry = builder.entryRow(row, self.z(labelFor(k)), 1024);
                    if (value != .null) entry.as(gtk.Editable).setText(self.z(if (value == .string) value.string else try std.json.Stringify.valueAlloc(alloc, value, .{})));
                    if (m.get(spec, "range") != .null) text(row, self.z(try std.fmt.allocPrint(alloc, "Allowed range: {s}{s}", .{ try std.json.Stringify.valueAlloc(alloc, m.get(spec, "range"), .{}), if (m.equal(m.get(spec, "exclusive_minimum"), .{ .bool = true })) " (minimum excluded)" else "" })), "pearl-secondary");
                    input = entry.as(gtk.Widget);
                }
                field.* = .{ .self = self, .spec = spec, .row = row, .input = input, .active = value != .null };
                if (projection.matcher(k) and options.len == 0 and std.mem.eql(u8, typ, "string") and (std.mem.eql(u8, k, "tag") or (value == .string and value.string.len == 0))) {
                    const empty = gtk.CheckButton.new();
                    empty.setChild(w.label("Allow an explicit empty pattern (advanced)", null).as(gtk.Widget));
                    empty.setActive(@intFromBool(value == .string and value.string.len == 0));
                    if (object.ext.cast(gtk.Label, empty.getChild().?)) |caption| {
                        caption.setWrap(1);
                        caption.setWrapMode(.word_char);
                    }
                    row.append(empty.as(gtk.Widget));
                    field.empty = empty;
                    try self.control(try std.fmt.allocPrint(alloc, "rules.empty.{s}", .{k}), empty.as(gtk.Widget), true);
                }
                const remove = w.wrappingButton("Remove");
                row.append(remove.as(gtk.Widget));
                w.name(remove.as(gtk.Widget), self.z(try std.fmt.allocPrint(alloc, "Remove {s}", .{labelFor(k)})));
                _ = gtk.Button.signals.clicked.connect(remove, *Field, removeClicked, field, .{});
                row.as(gtk.Widget).setVisible(@intFromBool(field.active));
                try self.fields.append(alloc, field);
                try self.control(try std.fmt.allocPrint(alloc, "rules.value.{s}", .{k}), input, true);
                try self.control(try std.fmt.allocPrint(alloc, "rules.remove.{s}", .{k}), remove.as(gtk.Widget), true);
            }
            for ([_]*gtk.Box{ conditions, effects }, 0..) |group, index| {
                const choice = builder.choiceRow(group, if (index == 0) "Condition or scope" else "Setting", &.{null});
                self.choosers[index] = choice;
                const button_ = w.wrappingButton(if (index == 0) "Add condition" else "Add setting");
                group.append(button_.as(gtk.Widget));
                self.add_buttons[index] = button_;
                _ = gtk.Button.signals.clicked.connect(button_, *Self, addClicked, self, .{});
                try self.control(if (index == 0) "rules.condition" else "rules.setting", choice.as(gtk.Widget), true);
                try self.control(if (index == 0) "rules.add-condition" else "rules.add-setting", button_.as(gtk.Widget), true);
            }
            self.refreshChoices();
            if (self.original.values == .object) {
                var it = self.original.values.object.iterator();
                while (it.next()) |e| {
                    var supported = false;
                    for (self.fields.items) |field| if (std.mem.eql(u8, m.str(m.get(field.spec, "key")), e.key_ptr.*)) {
                        supported = true;
                        break;
                    };
                    if (!supported) text(shell.body, self.z(try std.fmt.allocPrint(alloc, "Preserved in Advanced — {s}: {s}", .{ e.key_ptr.*, try shortValue(alloc, e.value_ptr.*) })), "pearl-secondary");
                }
            }
            text(shell.body, "Save rule stages a draft. Apply & save commits all Aqueous changes. Existing rules with no effects can intentionally prevent later rules from applying.", "pearl-secondary");
            const error_label = w.label("", "pearl-secondary");
            error_label.setWrap(1);
            error_label.as(gtk.Widget).setFocusable(1);
            shell.body.append(error_label.as(gtk.Widget));
            self.error_label = error_label;
            if (!self.is_new) {
                const delete = shell.dialog.addButton("Delete rule", 1);
                try self.control("rules.delete", delete, true);
            }
            const cancel = shell.dialog.addButton("Cancel", @intFromEnum(gtk.ResponseType.cancel));
            try self.control("rules.cancel", cancel, true);
            const save_button = shell.dialog.addButton("Save rule", @intFromEnum(gtk.ResponseType.accept));
            save_button.addCssClass("pearl-primary");
            try self.control("rules.save", save_button, true);
            _ = gtk.Dialog.signals.response.connect(shell.dialog, *Self, responded, self, .{});
            shell.dialog.as(gtk.Window).present();
        }
        fn condition(field: *Field) bool {
            const k = m.str(m.get(field.spec, "key"));
            return projection.matcher(k) or std.mem.eql(u8, k, "scope");
        }
        fn refreshChoices(self: *Self) void {
            for (self.choosers, 0..) |optional, index| if (optional) |choice| {
                const names = gtk.StringList.new(null);
                defer names.unref();
                var count: usize = 0;
                for (self.fields.items) |field| if (!field.active and condition(field) == (index == 0)) {
                    names.append(self.z(labelFor(m.str(m.get(field.spec, "key")))));
                    count += 1;
                };
                choice.setModel(names.as(@import("gio2").ListModel));
                choice.setSelected(0);
                choice.as(gtk.Widget).setSensitive(@intFromBool(count > 0));
                if (self.add_buttons[index]) |button_| button_.as(gtk.Widget).setSensitive(@intFromBool(count > 0));
            };
        }
        fn removeClicked(_: *gtk.Button, field: *Field) callconv(.c) void {
            field.active = false;
            field.row.as(gtk.Widget).setVisible(0);
            field.self.refreshChoices();
        }
        fn addClicked(button_: *gtk.Button, self: *Self) callconv(.c) void {
            const index: usize = if (button_ == self.add_buttons[0]) 0 else 1;
            var selected = self.choosers[index].?.getSelected();
            for (self.fields.items) |field| if (!field.active and condition(field) == (index == 0)) {
                if (selected == 0) {
                    field.active = true;
                    field.row.as(gtk.Widget).setVisible(1);
                    self.refreshChoices();
                    _ = field.input.grabFocus();
                    return;
                }
                selected -= 1;
            };
        }
        fn save(self: *Self, delete: bool) !void {
            const c = self.parent.client;
            if (!self.editable() or c.version != self.version or c.revision != self.revision or !std.mem.eql(u8, &self.draft_hash, &@import("editor_protocol.zig").digest(c.draft orelse ""))) return error.StaleDraft;
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const alloc = scratch.allocator();
            var values = self.original.values;
            values.object = try values.object.clone(alloc);
            var matchers: usize = 0;
            var effects: usize = 0;
            if (!delete) for (self.fields.items) |field| {
                const k = m.str(m.get(field.spec, "key"));
                if (!field.active) {
                    _ = values.object.swapRemove(k);
                    continue;
                }
                var value: m.Value = undefined;
                const typ = m.str(m.get(field.spec, "type"));
                if (object.ext.cast(gtk.DropDown, field.input)) |choice| {
                    if (std.mem.eql(u8, typ, "boolean")) value = .{ .bool = choice.getSelected() == 0 } else {
                        const options = m.list(m.get(field.spec, "options"));
                        if (choice.getSelected() >= options.len) return error.InvalidRuleOption;
                        value = options[choice.getSelected()];
                    }
                } else {
                    const bytes = std.mem.span(object.ext.cast(gtk.Entry, field.input).?.as(gtk.Editable).getText());
                    value = if (std.mem.eql(u8, typ, "integer")) .{ .integer = std.fmt.parseInt(i64, bytes, 10) catch return error.InvalidRuleValue } else if (std.mem.eql(u8, typ, "number")) .{ .float = std.fmt.parseFloat(f64, bytes) catch return error.InvalidRuleValue } else .{ .string = bytes };
                    if (field.empty) |empty| if (bytes.len == 0 and empty.getActive() == 0) return error.EmptyPatternNeedsConfirmation;
                }
                if (value == .string and value.string.len > 1024) {
                    self.error_label.?.setText(self.z(try std.fmt.allocPrint(self.arena.allocator(), "{s}: maximum 1024 UTF-8 bytes", .{labelFor(k)})));
                    return error.FieldValidation;
                }
                mutations.scalar(field.spec, value) catch |err| {
                    self.error_label.?.setText(self.z(try std.fmt.allocPrint(self.arena.allocator(), "{s}: {s}", .{ labelFor(k), @errorName(err) })));
                    return error.FieldValidation;
                };
                try projection.checkEmpty(k, m.get(self.original.values, k), value);
                try values.object.put(alloc, k, value);
                if (projection.matcher(k)) matchers += 1 else if (!std.mem.eql(u8, k, "scope")) effects += 1;
            };
            if (!delete and self.is_new and (matchers == 0 or effects == 0)) return error.MatcherAndSettingRequired;
            var change: m.Value = .{ .object = .empty };
            try change.object.put(alloc, "op", .{ .string = if (delete) "delete" else if (self.is_new or self.original.pending != null) "add" else "update" });
            if (!self.is_new and self.original.pending == null) try change.object.put(alloc, "id", self.original.id);
            if (!delete) try change.object.put(alloc, "values", if (self.is_new or self.original.pending != null) values else try projection.delta(alloc, self.original.values, values));
            const current = c.draft orelse try c.emptyDraft(alloc);
            const draft = if (self.original.pending) |index| try mutations.editPending(alloc, current, projection.key, index, change) else try mutations.stage(alloc, c.baseValue(), current, projection.key, change);
            try c.keepDraft(draft);
            self.parent.syncRequest();
        }
        fn responded(_: *gtk.Dialog, response: c_int, self: *Self) callconv(.c) void {
            if (response == 1 or response == @intFromEnum(gtk.ResponseType.accept)) {
                self.save(response == 1) catch |err| {
                    if (err != error.FieldValidation) self.error_label.?.setText(switch (err) {
                        error.StaleDraft => "The shared draft or snapshot changed. Your input is retained. Cancel and reopen the rule to review the latest version.",
                        error.MatcherAndSettingRequired => "Add at least one condition and one setting for a new rule. Scope alone is not a condition.",
                        error.EmptyValueUnsupported => "This helper treats a new empty value as removal. Enter a value or remove the row. Existing empty values are preserved; Launch tag supports explicit empty patterns.",
                        error.EmptyPatternNeedsConfirmation => "Enter a pattern, or explicitly allow an empty pattern in the advanced option.",
                        else => self.z(@errorName(err)),
                    });
                    _ = self.error_label.?.as(gtk.Widget).grabFocus();
                    return;
                };
                if (response == 1) {
                    if (self.focus_id) |id| a.free(id);
                    self.focus_id = a.dupe(u8, "rules.add") catch null;
                }
            }
            self.close();
            self.parent.build() catch |err| self.parent.fail(err);
            if (self.canPresent()) {
                self.parent.window.present();
                if (self.focus_source == 0) self.focus_source = glib.idleAddFull(glib.PRIORITY_DEFAULT_IDLE, focus, self, null);
            }
        }
        fn focus(data: ?*anyopaque) callconv(.c) c_int {
            const self: *Self = @ptrCast(@alignCast(data.?));
            self.focus_source = 0;
            if (!self.canPresent()) return 0;
            if (self.focus_id) |id| for (self.controls.items) |control_| if (std.mem.eql(u8, id, control_.id)) {
                _ = control_.widget.grabFocus();
                return 0;
            };
            if (self.add) |add| _ = add.as(gtk.Widget).grabFocus();
            return 0;
        }
        const Rect = struct { x: f32, y: f32, width: f32, height: f32 };
        const DiagnosticControl = struct { field: []const u8, bounds: ?Rect, enabled: bool };
        pub const Diagnostic = struct { dialog: bool, error_text: []const u8, controls: []const DiagnosticControl, body: ?Rect };
        fn bounds(widget: *gtk.Widget, parent: *gtk.Widget) ?Rect {
            var rect: @import("graphene1").Rect = undefined;
            if (widget.computeBounds(parent, &rect) == 0) return null;
            return .{ .x = rect.f_origin.f_x, .y = rect.f_origin.f_y, .width = rect.f_size.f_width, .height = rect.f_size.f_height };
        }
        pub fn diagnostic(self: *Self, alloc: std.mem.Allocator) !Diagnostic {
            var controls: std.ArrayList(DiagnosticControl) = .empty;
            if (self.shell) |shell| for (self.dialog_controls.items) |control_| if (control_.widget.getMapped() != 0) {
                try controls.append(alloc, .{ .field = control_.id, .bounds = bounds(control_.widget, shell.dialog.as(gtk.Widget)), .enabled = control_.widget.isSensitive() != 0 });
            };
            return .{ .dialog = self.shell != null, .error_text = if (self.error_label) |label| std.mem.span(label.getText()) else "", .controls = controls.items, .body = if (self.shell) |shell| bounds(shell.scroll.as(gtk.Widget), shell.dialog.as(gtk.Widget)) else null };
        }
    };
}
fn labelFor(key: []const u8) []const u8 {
    const labels = .{ .{ "app_id", "Application ID" }, .{ "class", "X11 class" }, .{ "title", "Title" }, .{ "tag", "Launch tag" }, .{ "content_type", "Content type" }, .{ "window_type", "X11 window type" }, .{ "scope", "Scope" }, .{ "floating", "Floating" }, .{ "fullscreen", "Fullscreen" }, .{ "workspace", "Workspace (1-based)" }, .{ "output", "Output connector" }, .{ "stack_layer", "Stack layer" }, .{ "width", "Width" }, .{ "height", "Height" }, .{ "opacity", "Opacity" }, .{ "blur", "Blur" }, .{ "placement_policy", "Placement" } };
    inline for (labels) |pair| if (std.mem.eql(u8, key, pair[0])) return pair[1];
    return key;
}
