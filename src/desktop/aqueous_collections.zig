//! GTK collection forms: schema fields, explicit inheritance, one shared draft.
const std = @import("std");
const gtk = @import("gtk4");
const object = @import("gobject2");
const m = @import("../config/aqueous_model.zig");
const model = @import("../config/aqueous_collections.zig");
const w = @import("../ui/components/widgets.zig");
pub fn For(comptime View: type) type {
    return struct {
        const Kind = enum { rules, bindings, zones };
        const Field = struct { spec: m.Value, input: *gtk.Widget, inherit: ?*gtk.CheckButton = null };
        const Form = struct {
            view: *View,
            kind: Kind,
            snapshot: m.Value,
            selector: *gtk.DropDown,
            projected: []const m.Value = &.{},
            fields: std.ArrayList(Field) = .empty,
            preview: *gtk.Label,
            fn key(self: *Form) []const u8 {
                return switch (self.kind) {
                    .rules => "window_rule_changes",
                    .bindings => "custom_keybind_changes",
                    .zones => "snap_zone_changes",
                };
            }
            fn items(self: *Form) []const m.Value {
                return self.projected;
            }
            fn selected(self: *Form) m.Value {
                const index = self.selector.getSelected();
                return if (index > 0 and index <= self.items().len) self.items()[index - 1] else .null;
            }
            fn load(self: *Form) !void {
                const a = self.view.arena.allocator();
                const original = self.selected();
                var value = if (self.kind == .rules) m.get(original, "values") else original;
                if (value == .null) value = .{ .object = .empty };
                if (value != .object) return error.InvalidCollection;
                value.object = try value.object.clone(a);
                const draft = try m.parse(a, self.view.client.draft orelse "{}", m.max_request);
                for (m.list(m.get(draft, self.key()))) |patch| {
                    if (original == .null or !m.equal(m.get(patch, "id"), m.get(original, "id"))) continue;
                    const values = if (self.kind == .rules) m.get(patch, "values") else patch;
                    if (values == .object) {
                        var it = values.object.iterator();
                        while (it.next()) |e| try value.object.put(a, e.key_ptr.*, e.value_ptr.*);
                    }
                }
                for (self.fields.items) |field| {
                    const k = m.str(m.get(field.spec, "key"));
                    const v = m.get(value, k);
                    if (field.inherit) |inherit| inherit.setActive(@intFromBool(v == .null));
                    if (object.ext.cast(gtk.SpinButton, field.input)) |input| {
                        input.setValue(number(v, if (std.mem.eql(u8, k, "width") or std.mem.eql(u8, k, "height")) 1 else 0));
                    } else if (object.ext.cast(gtk.CheckButton, field.input)) |input| input.setActive(@intFromBool(m.equal(v, .{ .bool = true }))) else if (object.ext.cast(gtk.DropDown, field.input)) |input| {
                        input.setSelected(0);
                        for (m.list(m.get(field.spec, "options")), 0..) |option, i| if (m.equal(option, v)) {
                            input.setSelected(@intCast(i));
                            break;
                        };
                    } else if (object.ext.cast(gtk.Entry, field.input)) |input| input.as(gtk.Editable).setText(self.view.z(m.str(v)));
                }
            }
            fn stage(self: *Form, op: []const u8, direction: ?i64) !void {
                const view = self.view;
                if (view.client.job != null or view.client.conflict()) return error.StaleDraft;
                var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const existing = self.selected();
                const pending = m.get(existing, "_pending_index");
                if (!std.mem.eql(u8, op, "save") and existing == .null) return error.SelectExistingItem;
                if (self.kind == .zones and existing == .null) return error.SelectExistingItem;
                var change: m.Value = .{ .object = .empty };
                const operation = if (std.mem.eql(u8, op, "save")) (if (existing == .null or pending != .null) "add" else "update") else op;
                try change.object.put(a, "op", .{ .string = operation });
                if (existing != .null and pending == .null) try change.object.put(a, "id", m.get(existing, "id"));
                if (direction) |d| try change.object.put(a, "direction", .{ .integer = d });
                if (std.mem.eql(u8, op, "save")) {
                    var values: m.Value = .{ .object = .empty };
                    for (self.fields.items) |field| {
                        var value: m.Value = .null;
                        if (field.inherit == null or field.inherit.?.getActive() == 0) {
                            if (object.ext.cast(gtk.SpinButton, field.input)) |input| value = if (std.mem.eql(u8, m.str(m.get(field.spec, "type")), "integer")) .{ .integer = @intFromFloat(input.getValue()) } else .{ .float = input.getValue() } else if (object.ext.cast(gtk.CheckButton, field.input)) |input| value = .{ .bool = input.getActive() != 0 } else if (object.ext.cast(gtk.DropDown, field.input)) |input| {
                                const options = m.list(m.get(field.spec, "options"));
                                if (input.getSelected() >= options.len) return error.InvalidRuleOption;
                                value = options[input.getSelected()];
                            } else if (object.ext.cast(gtk.Entry, field.input)) |input| value = .{ .string = std.mem.span(input.as(gtk.Editable).getText()) };
                        }
                        try model.scalar(field.spec, value);
                        try values.object.put(a, m.str(m.get(field.spec, "key")), value);
                    }
                    if (self.kind == .zones) try model.geometry(number(m.get(values, "x"), 0), number(m.get(values, "y"), 0), number(m.get(values, "width"), 0), number(m.get(values, "height"), 0));
                    if (self.kind == .rules) try change.object.put(a, "values", values) else {
                        var it = values.object.iterator();
                        while (it.next()) |e| try change.object.put(a, e.key_ptr.*, e.value_ptr.*);
                    }
                }
                const current = view.client.draft orelse try view.client.emptyDraft(a);
                const draft = if (pending == .integer) try model.editPending(a, current, self.key(), @intCast(pending.integer), change) else try model.stage(a, view.client.baseValue(), current, self.key(), change);
                try view.client.keepDraft(draft);
                view.syncRequest();
                // Rebuild selectors from the shared draft, including unsaved additions.
                try view.build();
            }
        };
        fn number(v: m.Value, fallback: f64) f64 {
            return switch (v) {
                .integer => @floatFromInt(v.integer),
                .float => v.float,
                else => fallback,
            };
        }
        pub fn render(view: *View, box: *gtk.Box, snapshot: m.Value, category: []const u8) !void {
            if (!@import("../config/aqueous_contract.zig").Capabilities.read(snapshot).collections) {
                box.append(w.label("Structured collections require an Aqueous helper with collection_schema_v1 and collection_preconditions_v1.", "pearl-secondary").as(gtk.Widget));
                return;
            }
            const a = view.arena.allocator();
            const kind: Kind = if (std.mem.eql(u8, category, "rules")) .rules else if (std.mem.eql(u8, category, "keybinds")) .bindings else .zones;
            const card = w.card();
            box.append(card.as(gtk.Widget));
            card.append(w.label(switch (kind) {
                .rules => "Window rule editor",
                .bindings => "Custom shortcut editor",
                .zones => "Legacy snap zones",
            }, "pearl-title").as(gtk.Widget));
            card.append(w.label(switch (kind) {
                .rules => "All matchers must match; first matching rule wins. Globs are anchored and case sensitive. Inherit removes a field; false and zero remain explicit. Save a move before other rule operations.",
                .bindings => "Commands keep Aqueous syntax: spawn:, launch:, set_layout: or builtin:. Editing does not execute a command. Validate checks chord collisions.",
                .zones => "Geometry is a fraction of the work area. Width and height must be positive and the zone must fit inside 0–1.",
            }, "pearl-secondary").as(gtk.Widget));
            const form = try a.create(Form);
            form.* = .{ .view = view, .kind = kind, .snapshot = snapshot, .selector = undefined, .preview = w.label("Stage changes to review the canonical request here. Validate checks the complete draft.", "pearl-secondary") };
            const request = try m.parse(a, view.client.draft orelse "{}", m.max_request);
            var items: std.ArrayList(m.Value) = .empty;
            const base_key = switch (kind) {
                .rules => "window_rules",
                .bindings => "custom_keybinds",
                .zones => "snap_zones",
            };
            for (m.list(m.get(snapshot, base_key))) |item| {
                var deleted = false;
                for (m.list(m.get(request, form.key()))) |patch| {
                    if (m.equal(m.get(patch, "id"), m.get(item, "id")) and std.mem.eql(u8, m.str(m.get(patch, "op")), "delete")) deleted = true;
                }
                if (!deleted) try items.append(a, item);
            }
            for (m.list(m.get(request, form.key())), 0..) |patch, index| {
                if (!std.mem.eql(u8, m.str(m.get(patch, "op")), "add")) continue;
                var item = patch;
                item.object = try patch.object.clone(a);
                try item.object.put(a, "_pending_index", .{ .integer = @intCast(index) });
                try item.object.put(a, "id", .{ .string = try std.fmt.allocPrint(a, "Unsaved {d}", .{index + 1}) });
                try items.append(a, item);
            }
            form.projected = try items.toOwnedSlice(a);
            const names = try a.allocSentinel(?[*:0]const u8, form.items().len + 1, null);
            names[0] = "New item";
            for (form.items(), 0..) |item, i| names[i + 1] = view.z(try std.fmt.allocPrint(a, "{s} · {s}", .{ m.str(m.get(item, "id")), if (kind == .bindings) m.str(m.get(item, "chord")) else if (kind == .rules) m.str(m.get(m.get(item, "values"), "app_id")) else "" }));
            form.selector = gtk.DropDown.newFromStrings(@ptrCast(names.ptr));
            named(form.selector.as(gtk.Widget), "Collection item");
            card.append(form.selector.as(gtk.Widget));
            const specs = if (kind == .rules) m.get(m.get(m.get(snapshot, "collection_schema"), "window_rules"), "fields") else try m.parse(a, if (kind == .bindings) "[{\"key\":\"chord\",\"type\":\"string\"},{\"key\":\"command\",\"type\":\"string\"}]" else "[{\"key\":\"x\",\"type\":\"number\",\"range\":[0,1]},{\"key\":\"y\",\"type\":\"number\",\"range\":[0,1]},{\"key\":\"width\",\"type\":\"number\",\"range\":[0,1],\"exclusive_minimum\":true},{\"key\":\"height\",\"type\":\"number\",\"range\":[0,1],\"exclusive_minimum\":true}]", 4096);
            for (m.list(specs)) |spec| {
                const key = m.str(m.get(spec, "key"));
                const typ = m.str(m.get(spec, "type"));
                const options = m.list(m.get(spec, "options"));
                const row = w.column(4);
                card.append(row.as(gtk.Widget));
                row.append(w.label(view.z(key), null).as(gtk.Widget));
                var field: Field = .{ .spec = spec, .input = undefined };
                if (kind == .rules) {
                    field.inherit = gtk.CheckButton.newWithLabel("Inherit");
                    row.append(field.inherit.?.as(gtk.Widget));
                    named(field.inherit.?.as(gtk.Widget), view.z(try std.fmt.allocPrint(a, "Inherit {s}", .{key})));
                }
                if (std.mem.eql(u8, typ, "boolean")) field.input = gtk.CheckButton.new().as(gtk.Widget) else if (options.len > 0) {
                    const strings = try a.allocSentinel(?[*:0]const u8, options.len, null);
                    for (options, 0..) |option, i| strings[i] = view.z(m.str(option));
                    field.input = gtk.DropDown.newFromStrings(@ptrCast(strings.ptr)).as(gtk.Widget);
                } else if (std.mem.eql(u8, typ, "integer") or std.mem.eql(u8, typ, "number")) {
                    const range = m.list(m.get(spec, "range"));
                    const input = gtk.SpinButton.newWithRange(if (range.len == 2) number(range[0], 0) else -100000, if (range.len == 2) number(range[1], 1) else 100000, if (std.mem.eql(u8, typ, "integer")) 1 else 0.01);
                    input.setDigits(if (std.mem.eql(u8, typ, "integer")) 0 else 3);
                    field.input = input.as(gtk.Widget);
                } else {
                    const input = gtk.Entry.new();
                    input.setMaxLength(if (kind == .bindings) (if (std.mem.eql(u8, key, "chord")) 128 else 1024) else 8192);
                    field.input = input.as(gtk.Widget);
                }
                named(field.input, view.z(key));
                row.append(field.input);
                if (kind == .bindings and std.mem.eql(u8, key, "chord")) try view.recordEntry(row, field.input);
                try form.fields.append(a, field);
            }
            const actions = w.row(8);
            card.append(actions.as(gtk.Widget));
            for ([_][]const u8{ "Stage item", "Delete item", "Move up", "Move down" }, 0..) |label, i| {
                if (i >= 2 and kind != .rules) continue;
                const button = gtk.Button.newWithLabel(view.z(label));
                named(button.as(gtk.Widget), view.z(label));
                actions.append(button.as(gtk.Widget));
                const action = try a.create(Action);
                action.* = .{ .form = form, .index = i };
                view.form_signals.add(button.as(object.Object), gtk.Button.signals.clicked.connect(button, *Action, clicked, action, .{}));
            }
            form.preview.setSelectable(1);
            if (m.get(request, form.key()) != .null) form.preview.setText(view.z(try std.json.Stringify.valueAlloc(a, m.get(request, form.key()), .{ .whitespace = .indent_2 })));
            card.append(form.preview.as(gtk.Widget));
            view.form_signals.add(form.selector.as(object.Object), object.Object.signals.notify.connect(form.selector.as(object.Object), *Form, selected, form, .{ .detail = "selected" }));
            try form.load();
        }
        const Action = struct { form: *Form, index: usize };
        fn clicked(_: *gtk.Button, action: *Action) callconv(.c) void {
            const view = action.form.view;
            action.form.stage(switch (action.index) {
                0 => "save",
                1 => "delete",
                else => "move",
            }, if (action.index >= 2) @as(i64, if (action.index == 2) -1 else 1) else null) catch |err| view.fail(err);
        }
        fn selected(_: *object.Object, _: *object.ParamSpec, form: *Form) callconv(.c) void {
            form.load() catch |err| form.view.fail(err);
        }

        fn named(widget: *gtk.Widget, name: [*:0]const u8) void {
            w.name(widget, name);
            if (@import("build_options").test_hooks) widget.setName(name);
        }
    };
}
