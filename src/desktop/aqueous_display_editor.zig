//! Typed declaration operations with explicit keep/set/inherit intent.
const std = @import("std");
const gtk = @import("gtk4");
const object = @import("gobject2");
const m = @import("../config/aqueous_model.zig");
const mutations = @import("../config/aqueous_display_mutations.zig");
const w = @import("../ui/components/widgets.zig");
pub fn For(comptime View: type) type {
    return struct {
        const Field = struct { key: []const u8, spec: m.Value, action: *gtk.DropDown, input: *gtk.Widget, y: ?*gtk.SpinButton = null };
        const Form = struct {
            view: *View,
            snapshot: m.Value,
            selector: *gtk.DropDown,
            source: *gtk.DropDown,
            parent: *gtk.DropDown,
            before: *gtk.DropDown,
            members: *gtk.DropDown,
            targets: []const m.Value,
            parent_targets: []const m.Value,
            fields_box: *gtk.Box,
            fields: std.ArrayList(Field) = .empty,
            fn selected(self: *Form) m.Value {
                const i = self.selector.getSelected();
                return if (i >= 3 and i - 3 < self.targets.len) self.targets[i - 3] else .null;
            }
            fn kind(self: *Form) []const u8 {
                const existing = self.selected();
                return if (existing != .null) m.str(m.get(existing, "kind")) else switch (self.selector.getSelected()) {
                    1 => "profile",
                    2 => "policy",
                    else => "output",
                };
            }
            fn target(self: *Form, selector: *gtk.DropDown) m.Value {
                const index = selector.getSelected();
                const values = if (selector == self.parent) self.parent_targets else self.targets;
                return if (index > 0 and index <= values.len) m.get(values[index - 1], "id") else .null;
            }
            fn load(self: *Form) !void {
                const view = self.view;
                const a = view.arena.allocator();
                while (self.fields_box.as(gtk.Widget).getFirstChild()) |child| self.fields_box.remove(child);
                self.fields = .empty;
                const existing = self.selected();
                const kind_ = self.kind();
                if (existing != .null) self.source.setSelected(if (std.mem.eql(u8, m.str(m.get(existing, "source")), "wm")) 0 else 1);
                self.source.as(gtk.Widget).setSensitive(@intFromBool(existing == .null));
                self.parent.setSelected(0);
                self.before.setSelected(0);
                for (self.parent_targets, 0..) |d, i| if (m.equal(m.get(existing, "parent_id"), m.get(d, "id"))) {
                    self.parent.setSelected(@intCast(i + 1));
                };
                self.parent.as(gtk.Widget).setSensitive(@intFromBool(!std.mem.eql(u8, kind_, "policy")));
                self.before.as(gtk.Widget).setSensitive(@intFromBool(!std.mem.eql(u8, kind_, "policy")));
                self.members.as(gtk.Widget).setSensitive(@intFromBool(std.mem.eql(u8, kind_, "profile")));
                const specs = try mutations.fields(a);
                var it = specs.object.iterator();
                const draft = try m.parse(a, view.client.draft orelse "{}", m.max_request);
                for (m.list(m.get(m.get(draft, "display_declaration_changes"), "operations"))) |op| {
                    if (m.equal(m.get(op, "id"), m.get(existing, "id")) and existing != .null) {
                        try view.inventory(self.fields_box, op, "set", "Staged explicit values");
                        try view.inventory(self.fields_box, op, "unset", "Staged inherited values");
                    }
                }
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const spec = entry.value_ptr.*;
                    if (!mutations.fieldAllowed(kind_, key)) continue;
                    const row = w.column(4);
                    self.fields_box.append(row.as(gtk.Widget));
                    row.append(w.label(view.z(key), null).as(gtk.Widget));
                    for (m.list(m.get(existing, "entries"))) |local| if (std.mem.eql(u8, m.str(m.get(local, "key")), key)) {
                        row.append(w.label(view.z(try std.fmt.allocPrint(a, "Current local assignment: {s}", .{m.str(m.get(local, "raw"))})), "pearl-secondary").as(gtk.Widget));
                    };
                    const action = gtk.DropDown.newFromStrings(@ptrCast(&[_:null]?[*:0]const u8{ "Keep current / omitted", "Set explicit value", "Use inherited value" }));
                    named(action.as(gtk.Widget), view.z(try std.fmt.allocPrint(a, "{s} edit action", .{key})));
                    row.append(action.as(gtk.Widget));
                    var f: Field = .{ .key = key, .spec = spec, .action = action, .input = undefined };
                    const typ = m.str(m.get(spec, "type"));
                    const options = m.list(m.get(spec, "enum"));
                    if (std.mem.eql(u8, typ, "boolean")) f.input = gtk.CheckButton.newWithLabel("Enabled").as(gtk.Widget) else if (options.len > 0) {
                        const names = try a.allocSentinel(?[*:0]const u8, options.len, null);
                        for (options, 0..) |option, i| names[i] = view.z(m.str(option));
                        f.input = gtk.DropDown.newFromStrings(@ptrCast(names.ptr)).as(gtk.Widget);
                    } else if (std.mem.eql(u8, key, "position")) {
                        f.input = gtk.SpinButton.newWithRange(-2147483648, 2147483647, 1).as(gtk.Widget);
                        f.y = gtk.SpinButton.newWithRange(-2147483648, 2147483647, 1);
                    } else if (std.mem.eql(u8, typ, "integer") or std.mem.eql(u8, typ, "number")) {
                        const input = gtk.SpinButton.newWithRange(number(m.get(spec, "minimum"), 0), number(m.get(spec, "maximum"), 65535), if (std.mem.eql(u8, typ, "integer")) 1 else 0.01);
                        input.setDigits(if (std.mem.eql(u8, typ, "integer")) 0 else 3);
                        f.input = input.as(gtk.Widget);
                    } else {
                        const input = gtk.Entry.new();
                        input.setMaxLength(256);
                        f.input = input.as(gtk.Widget);
                    }
                    named(f.input, view.z(key));
                    row.append(f.input);
                    if (f.y) |y| {
                        named(y.as(gtk.Widget), "position y");
                        row.append(y.as(gtk.Widget));
                    }
                    try self.fields.append(a, f);
                }
            }
            fn stage(self: *Form, operation: []const u8) !void {
                const view = self.view;
                if (view.client.job != null or view.client.conflict()) return error.StaleDraft;
                var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const existing = self.selected();
                const kind_ = self.kind();
                const save = std.mem.eql(u8, operation, "save");
                if (!save and existing == .null) return error.SelectExistingItem;
                var op: m.Value = .{ .object = .empty };
                try op.object.put(a, "op", .{ .string = if (save) (if (existing == .null) "add" else "update") else operation });
                try op.object.put(a, "source", .{ .string = if (self.source.getSelected() == 0) "wm" else "outputs" });
                if (existing != .null) try op.object.put(a, "id", m.get(existing, "id"));
                if (save) {
                    var set: m.Value = .{ .object = .empty };
                    var unset: m.Value = .{ .array = .init(a) };
                    // Retain previously staged fields when editing the same node again.
                    const draft = try m.parse(a, view.client.draft orelse "{}", m.max_request);
                    for (m.list(m.get(m.get(draft, "display_declaration_changes"), "operations"))) |old| {
                        if (existing != .null and m.equal(m.get(old, "id"), m.get(existing, "id"))) {
                            if (m.get(old, "set") == .object) set = m.get(old, "set");
                            if (m.get(old, "unset") == .array) unset = m.get(old, "unset");
                        }
                    }
                    for (self.fields.items) |f| {
                        const intent = f.action.getSelected();
                        if (intent == 0) continue;
                        _ = set.object.swapRemove(f.key);
                        var i: usize = unset.array.items.len;
                        while (i > 0) {
                            i -= 1;
                            if (std.mem.eql(u8, m.str(unset.array.items[i]), f.key)) _ = unset.array.orderedRemove(i);
                        }
                        if (intent == 2) {
                            if (existing != .null) try unset.array.append(.{ .string = f.key });
                            continue;
                        }
                        var value: m.Value = .null;
                        if (object.ext.cast(gtk.SpinButton, f.input)) |input| {
                            if (f.y) |y| {
                                value = .{ .array = .init(a) };
                                try value.array.append(.{ .integer = @intFromFloat(input.getValue()) });
                                try value.array.append(.{ .integer = @intFromFloat(y.getValue()) });
                            } else value = if (std.mem.eql(u8, m.str(m.get(f.spec, "type")), "integer")) .{ .integer = @intFromFloat(input.getValue()) } else .{ .float = input.getValue() };
                        } else if (object.ext.cast(gtk.CheckButton, f.input)) |input| value = .{ .bool = input.getActive() != 0 } else if (object.ext.cast(gtk.DropDown, f.input)) |input| value = m.list(m.get(f.spec, "enum"))[input.getSelected()] else if (object.ext.cast(gtk.Entry, f.input)) |input| value = .{ .string = std.mem.span(input.as(gtk.Editable).getText()) };
                        try set.object.put(a, f.key, value);
                    }
                    if (set.object.count() > 0 or existing == .null) try op.object.put(a, "set", set);
                    if (unset.array.items.len > 0) try op.object.put(a, "unset", unset);
                    if (existing == .null) {
                        try op.object.put(a, "kind", .{ .string = kind_ });
                        const count = m.list(m.get(m.get(draft, "display_declaration_changes"), "operations")).len;
                        try op.object.put(a, "ref", .{ .string = try std.fmt.allocPrint(a, "draft{d}", .{count}) });
                    }
                }
                if ((existing == .null and std.mem.eql(u8, kind_, "output")) or (std.mem.eql(u8, operation, "move") and !std.mem.eql(u8, kind_, "profile"))) try op.object.put(a, "parent", self.target(self.parent));
                if ((existing == .null or std.mem.eql(u8, operation, "move")) and self.target(self.before) != .null) try op.object.put(a, "before", self.target(self.before));
                if (std.mem.eql(u8, operation, "delete") and std.mem.eql(u8, kind_, "profile")) {
                    try op.object.put(a, "members", .{ .string = if (self.members.getSelected() == 0) "delete" else "move" });
                    if (self.members.getSelected() != 0) try op.object.put(a, "parent", self.target(self.parent));
                }
                const bytes = try mutations.stage(a, view.client.baseValue(), view.client.draft orelse try view.client.emptyDraft(a), op);
                try view.client.keepDraft(bytes);
                view.syncRequest();
                try view.build();
            }
        };
        pub fn render(view: *View, box: *gtk.Box, snapshot: m.Value) !void {
            if (!@import("../config/aqueous_contract.zig").Capabilities.read(snapshot).display_mutations) {
                box.append(w.label("Structured display editing requires aqueous-config with display_declaration_mutations_v1. Refresh after upgrading the helper.", "pearl-secondary").as(gtk.Widget));
                return;
            }
            const a = view.arena.allocator();
            const card = w.card();
            box.append(card.as(gtk.Widget));
            card.append(w.label("Display declarations and profiles", "pearl-title").as(gtk.Widget));
            card.append(w.label("Stage explicit values or remove local overrides. Keep current leaves a field untouched. Aqueous validates the complete candidate; live apply depends on each output's preview support. Policy identify_by and rollback_seconds are compatibility settings; rollback_seconds does not change the confirmation timer.", "pearl-secondary").as(gtk.Widget));
            var targets: std.ArrayList(m.Value) = .empty;
            for (m.list(m.get(snapshot, "display_declarations"))) |d| try targets.append(a, d);
            const draft = try m.parse(a, view.client.draft orelse "{}", m.max_request);
            for (m.list(m.get(m.get(draft, "display_declaration_changes"), "operations"))) |op| {
                if (!std.mem.eql(u8, m.str(m.get(op, "op")), "add")) continue;
                var d: m.Value = .{ .object = .empty };
                try d.object.put(a, "id", .{ .string = try std.fmt.allocPrint(a, "new:{s}", .{m.str(m.get(op, "ref"))}) });
                for ([_][]const u8{ "source", "kind" }) |key| try d.object.put(a, key, m.get(op, key));
                try d.object.put(a, "parent_id", m.get(op, "parent"));
                try targets.append(a, d);
            }
            var remaining: usize = targets.items.len;
            while (remaining > 0) {
                remaining -= 1;
                for (m.list(m.get(m.get(draft, "display_declaration_changes"), "operations"))) |op| {
                    if (std.mem.eql(u8, m.str(m.get(op, "op")), "delete") and m.equal(m.get(op, "id"), m.get(targets.items[remaining], "id"))) {
                        _ = targets.orderedRemove(remaining);
                        break;
                    }
                }
            }
            const items = try targets.toOwnedSlice(a);
            var parents: std.ArrayList(m.Value) = .empty;
            for (items) |d| if (std.mem.eql(u8, m.str(m.get(d, "kind")), "profile")) try parents.append(a, d);
            const parent_items = try parents.toOwnedSlice(a);
            const parent_names = try a.allocSentinel(?[*:0]const u8, parent_items.len + 1, null);
            parent_names[0] = "Top level";
            for (parent_items, 0..) |d, n| parent_names[n + 1] = try declarationLabel(view, d, n);
            const names = try a.allocSentinel(?[*:0]const u8, items.len + 3, null);
            names[0] = "New output";
            names[1] = "New profile";
            names[2] = "New policy";
            const refs = try a.allocSentinel(?[*:0]const u8, items.len + 1, null);
            refs[0] = "Top level / append";
            for (items, 0..) |d, i| {
                names[i + 3] = try declarationLabel(view, d, i);
                refs[i + 1] = names[i + 3];
            }
            const form = try a.create(Form);
            form.* = .{ .view = view, .snapshot = snapshot, .targets = items, .parent_targets = parent_items, .selector = gtk.DropDown.newFromStrings(@ptrCast(names.ptr)), .source = gtk.DropDown.newFromStrings(@ptrCast(&[_:null]?[*:0]const u8{ "wm", "outputs" })), .parent = gtk.DropDown.newFromStrings(@ptrCast(parent_names.ptr)), .before = gtk.DropDown.newFromStrings(@ptrCast(refs.ptr)), .members = gtk.DropDown.newFromStrings(@ptrCast(&[_:null]?[*:0]const u8{ "Delete profile members", "Move members to selected parent" })), .fields_box = w.column(8) };
            form.source.setSelected(1);
            for ([_]*gtk.DropDown{ form.selector, form.source, form.parent, form.before, form.members }, [_][*:0]const u8{ "Display declaration", "Declaration source", "Destination parent profile", "Insert before declaration", "Profile deletion members" }) |input, label| {
                card.append(w.label(label, null).as(gtk.Widget));
                named(input.as(gtk.Widget), label);
                card.append(input.as(gtk.Widget));
            }
            card.append(form.fields_box.as(gtk.Widget));
            const actions = w.flow(3);
            actions.setHomogeneous(0);
            card.append(actions.as(gtk.Widget));
            for ([_][2][]const u8{ .{ "Stage declaration", "save" }, .{ "Move declaration", "move" }, .{ "Delete declaration", "delete" } }) |pair| {
                const button = gtk.Button.newWithLabel(view.z(pair[0]));
                named(button.as(gtk.Widget), view.z(pair[0]));
                actions.insert(button.as(gtk.Widget), -1);
                const action = try a.create(Action);
                action.* = .{ .form = form, .operation = pair[1] };
                view.form_signals.add(button.as(object.Object), gtk.Button.signals.clicked.connect(button, *Action, clicked, action, .{}));
            }
            try view.inventory(card, draft, "display_declaration_changes", "Staged display operations");
            view.form_signals.add(form.selector.as(object.Object), object.Object.signals.notify.connect(form.selector.as(object.Object), *Form, selected, form, .{ .detail = "selected" }));
            try form.load();
        }
        fn declarationLabel(view: *View, declaration: m.Value, ordinal: usize) ![:0]const u8 {
            var name: []const u8 = "";
            for (m.list(m.get(declaration, "entries"))) |entry| if (std.mem.eql(u8, m.str(m.get(entry, "key")), "name") or std.mem.eql(u8, m.str(m.get(entry, "key")), "edid")) {
                name = m.str(m.get(entry, "raw"));
                break;
            };
            return view.z(try std.fmt.allocPrint(view.arena.allocator(), "{s} · {s} · {d} {s}", .{ m.str(m.get(declaration, "source")), m.str(m.get(declaration, "kind")), ordinal + 1, name }));
        }
        const Action = struct { form: *Form, operation: []const u8 };
        fn clicked(_: *gtk.Button, action: *Action) callconv(.c) void {
            const view = action.form.view;
            action.form.stage(action.operation) catch |err| view.fail(err);
        }
        fn selected(_: *object.Object, _: *object.ParamSpec, form: *Form) callconv(.c) void {
            form.load() catch |err| form.view.fail(err);
        }
        fn named(widget: *gtk.Widget, name: [*:0]const u8) void {
            w.name(widget, name);
            if (@import("build_options").test_hooks) widget.setName(name);
        }
        fn number(v: m.Value, fallback: f64) f64 {
            return switch (v) {
                .integer => @floatFromInt(v.integer),
                .float => v.float,
                else => fallback,
            };
        }
    };
}
