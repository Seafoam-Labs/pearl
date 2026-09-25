//! Native notification rule editor. Only shared drafts are mutated here;
//! matching samples are evaluated by the session backend without Notify calls.
const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const object = @import("gobject2");
const f = @import("../services/notification_filter_policy.zig");
const model = @import("../config/preferences.zig");
const p = @import("editor_protocol.zig");
const Editor = @import("editor.zig").Editor;
const Text = @import("../services/policy.zig").Text;
const w = @import("../ui/components/widgets.zig");
const tr = @import("../desktop/text.zig").tr;
const a = std.heap.c_allocator;
const builder = @import("rule_builder.zig");
pub const Control = struct { id: []const u8, widget: *gtk.Widget };
const Binding = struct { view: *View, id: Text(64), toggle: bool = false };
const ConditionWidgets = struct {
    view: *View,
    index: usize,
    host: *gtk.Box,
    field: *gtk.DropDown,
    comparison: *gtk.DropDown,
    value: *gtk.Entry,
    urgency: *gtk.DropDown,
    case_sensitive: *gtk.CheckButton,
};
pub const View = struct {
    editor: *Editor,
    window: *gtk.Window,
    host: *gtk.Box,
    rows: *gtk.Box,
    master: *gtk.Switch,
    add: *gtk.Button,
    notice: *gtk.Label,
    test_button: *gtk.Button,
    test_result: *gtk.Label,
    sample: [4]*gtk.Entry,
    sample_urgency: *gtk.DropDown,
    arena: std.heap.ArenaAllocator = .init(a),
    controls: std.ArrayList(Control) = .empty,
    dialog_controls: std.ArrayList(Control) = .empty,
    fixed_count: usize = 0,
    signature: ?[64]u8 = null,
    filling: bool = false,
    editing: bool = false,
    idle: c_uint = 0,
    context: *anyopaque,
    invalidate: *const fn (*anyopaque, @import("../desktop/settings_navigation.zig").Route) void,
    dialog: ?*gtk.Dialog = null,
    dialog_scroll: ?*gtk.ScrolledWindow = null,
    dialog_hash: [64]u8 = undefined,
    rule_id: Text(64) = .{},
    rule_enabled: bool = true,
    rule_name: ?*gtk.Entry = null,
    rule_action: ?*gtk.DropDown = null,
    rule_match: ?*gtk.DropDown = null,
    rule_error: ?*gtk.Label = null,
    condition_widgets: [f.max_conditions]ConditionWidgets = undefined,
    condition_count: usize = 0,
    add_condition: ?*gtk.Button = null,
    focus_id: Text(96) = .{},
    pub fn create(host: *gtk.Box, window: *gtk.Window, editor: *Editor, context: *anyopaque, invalidate: @FieldType(View, "invalidate")) !*View {
        const self = try a.create(View);
        const heading = w.row(12);
        const title = w.label(tr("Notification filters", "Benachrichtigungsfilter"), "pearl-card-title");
        title.setWrap(1);
        title.as(gtk.Widget).setHexpand(1);
        heading.append(title.as(gtk.Widget));
        const master = gtk.Switch.new();
        master.as(gtk.Widget).setValign(.center);
        w.name(master.as(gtk.Widget), tr("Enable notification filters", "Benachrichtigungsfilter aktivieren"));
        heading.append(master.as(gtk.Widget));
        const add = w.wrappingButton(tr("Add filter", "Filter hinzufügen"));
        heading.append(add.as(gtk.Widget));
        host.append(heading.as(gtk.Widget));
        const notice = w.label("", "pearl-secondary");
        notice.setWrap(1);
        host.append(notice.as(gtk.Widget));
        const rows = w.column(8);
        host.append(rows.as(gtk.Widget));
        const help = w.label(tr("Block hides popups and history. History only hides popups. Block takes priority when several filters match.", "Blockieren blendet Popups und Verlauf aus. Nur Verlauf blendet Popups aus. Bei mehreren Treffern hat Blockieren Vorrang."), "pearl-secondary");
        help.setWrap(1);
        host.append(help.as(gtk.Widget));
        const expander = gtk.Expander.new(tr("Test filters", "Filter testen"));
        const tester = w.column(8);
        expander.setChild(tester.as(gtk.Widget));
        host.append(expander.as(gtk.Widget));
        const test_help = w.label(tr("Try a sample against the draft without sending a notification. DND and lock can also hide popups.", "Beispiel am Entwurf testen, ohne eine Benachrichtigung zu senden. Nicht stören und Sperre können Popups ebenfalls ausblenden."), "pearl-secondary");
        test_help.setWrap(1);
        tester.append(test_help.as(gtk.Widget));
        var sample: [4]*gtk.Entry = undefined;
        for (&sample, [_][:0]const u8{ tr("Application name", "Anwendungsname"), tr("Desktop ID", "Desktop-ID"), tr("Title", "Titel"), tr("Body", "Text") }) |*entry, label| entry.* = entryRow(tester, label, 4096);
        const urgency = choiceRow(tester, tr("Urgency", "Dringlichkeit"), &.{ tr("Low", "Niedrig"), tr("Normal", "Normal"), tr("Critical", "Kritisch"), null });
        urgency.setSelected(1);
        const test_button = w.wrappingButton(tr("Test sample", "Beispiel testen"));
        tester.append(test_button.as(gtk.Widget));
        const result = w.label("", "pearl-secondary");
        result.setWrap(1);
        tester.append(result.as(gtk.Widget));
        self.* = .{ .editor = editor, .window = window, .host = host, .rows = rows, .master = master, .add = add, .notice = notice, .test_button = test_button, .test_result = result, .sample = sample, .sample_urgency = urgency, .context = context, .invalidate = invalidate };
        try self.controls.appendSlice(a, &.{ .{ .id = "filters.enabled", .widget = master.as(gtk.Widget) }, .{ .id = "filters.add", .widget = add.as(gtk.Widget) }, .{ .id = "filters.tester", .widget = expander.as(gtk.Widget) }, .{ .id = "filters.test", .widget = test_button.as(gtk.Widget) }, .{ .id = "filters.sample.urgency", .widget = urgency.as(gtk.Widget) } });
        for (sample, [_][]const u8{ "filters.sample.app_name", "filters.sample.desktop_entry", "filters.sample.summary", "filters.sample.body" }) |entry, id| {
            try self.controls.append(a, .{ .id = id, .widget = entry.as(gtk.Widget) });
            _ = gtk.Editable.signals.changed.connect(entry.as(gtk.Editable), *View, sampleChanged, self, .{});
        }
        self.fixed_count = self.controls.items.len;
        _ = object.Object.signals.notify.connect(master.as(object.Object), *View, masterChanged, self, .{ .detail = "active" });
        _ = gtk.Button.signals.clicked.connect(add, *View, addClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(test_button, *View, testClicked, self, .{});
        _ = object.Object.signals.notify.connect(urgency.as(object.Object), *View, sampleChoiceChanged, self, .{ .detail = "selected" });
        self.update();
        return self;
    }
    const entryRow = builder.entryRow;
    const choiceRow = builder.choiceRow;
    pub fn destroy(self: *View) void {
        if (self.idle != 0) _ = glib.Source.remove(self.idle);
        self.closeDialog();
        self.arena.deinit();
        self.controls.deinit(a);
        self.dialog_controls.deinit(a);
        a.destroy(self);
    }
    const Rect = struct { x: f32, y: f32, width: f32, height: f32 };
    const DiagnosticControl = struct { field: []const u8, bounds: ?Rect, enabled: bool };
    pub const Diagnostic = struct { dialog: bool, error_text: []const u8, test_result: []const u8, controls: []const DiagnosticControl, body: ?Rect };
    fn relative(widget: *gtk.Widget, parent: *gtk.Widget) ?Rect {
        var rect: @import("graphene1").Rect = undefined;
        if (widget.computeBounds(parent, &rect) == 0) return null;
        return .{ .x = rect.f_origin.f_x, .y = rect.f_origin.f_y, .width = rect.f_size.f_width, .height = rect.f_size.f_height };
    }
    pub fn diagnostic(self: *View, alloc: std.mem.Allocator) !Diagnostic {
        var controls: std.ArrayList(DiagnosticControl) = .empty;
        if (self.dialog) |dialog| for (self.dialog_controls.items) |control| if (control.widget.getMapped() != 0) {
            try controls.append(alloc, .{ .field = control.id, .bounds = relative(control.widget, dialog.as(gtk.Widget)), .enabled = control.widget.isSensitive() != 0 });
        };
        return .{ .dialog = self.dialog != null, .controls = controls.items, .body = if (self.dialog_scroll) |scroll| relative(scroll.as(gtk.Widget), self.dialog.?.as(gtk.Widget)) else null, .error_text = if (self.rule_error) |label| std.mem.span(label.getText()) else "", .test_result = std.mem.span(self.test_result.getText()) };
    }
    fn editable(self: *View) bool {
        return self.editor.editable() and !self.editor.state.busy and self.editor.action == .none and self.editor.submitted == .none;
    }
    fn configHash(alloc: std.mem.Allocator, config: f.Config) ![64]u8 {
        return p.digest(try std.json.Stringify.valueAlloc(alloc, config, .{}));
    }
    pub fn update(self: *View) void {
        if (self.editing) return;
        const enabled = self.editable() and self.editor.client.capabilities.notification_filters;
        self.host.as(gtk.Widget).setSensitive(@intFromBool(enabled));
        self.styleDialog();
        if (self.dialog) |dialog| {
            const visible = !self.editor.suspended and !self.editor.state.locked and self.editor.online and self.editor.target.page == .notifications;
            dialog.as(gtk.Widget).setVisible(@intFromBool(visible));
            if (dialog.getWidgetForResponse(@intFromEnum(gtk.ResponseType.accept))) |button| button.setSensitive(@intFromBool(enabled));
            if (dialog.getWidgetForResponse(1)) |button| button.setSensitive(@intFromBool(enabled));
        }
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const alloc = scratch.allocator();
        const prefs = model.parse(alloc, self.editor.text()) catch {
            self.host.as(gtk.Widget).setSensitive(0);
            self.notice.setText(tr("Repair the invalid draft in Advanced before editing filters.", "Den ungültigen Entwurf unter Erweitert korrigieren."));
            return;
        };
        self.filling = true;
        defer self.filling = false;
        self.master.setActive(@intFromBool(prefs.notifications.filters_enabled));
        var active: usize = 0;
        for (prefs.notifications.rules) |r| {
            if (r.enabled) active += 1;
        }
        self.notice.setText(if (!self.editor.client.capabilities.notification_filters) tr("This session does not support notification filters.", "Diese Sitzung unterstützt keine Benachrichtigungsfilter.") else if (!prefs.notifications.filters_enabled) tr("Filters paused. Rules remain saved and editable.", "Filter pausiert. Regeln bleiben gespeichert und bearbeitbar.") else std.fmt.allocPrintSentinel(alloc, "{d} / {d} {s}", .{ active, prefs.notifications.rules.len, tr("filters enabled", "Filter aktiviert") }, 0) catch "");
        self.add.as(gtk.Widget).setSensitive(@intFromBool(prefs.notifications.rules.len < f.max_rules));
        const hash = configHash(alloc, prefs.notifications) catch return;
        if (self.signature == null or !std.mem.eql(u8, &hash, &self.signature.?)) {
            self.render(prefs.notifications) catch return;
            self.signature = hash;
        }
        self.test_result.setText("");
        if (self.editor.notification_test_error.len > 0) self.test_result.setText(tr("The sample could not be tested. Wait for the draft to sync, then try again.", "Beispiel konnte nicht getestet werden. Entwurf synchronisieren lassen und erneut versuchen."));
        if (self.editor.notification_test_result) |bytes| if (self.editor.notification_test_hash) |saved| {
            if (std.mem.eql(u8, &saved, &p.digest(self.editor.text()))) {
                const Response = struct { decision: f.Decision, matches: []const struct { id: []const u8, name: []const u8 }, dirty: bool, filters_enabled: bool, draft_revision: []const u8, revision: []const u8 };
                const result = std.json.parseFromSliceLeaky(Response, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return;
                if ((p.number(result.draft_revision) catch return) != self.editor.state.draft_revision or (p.number(result.revision) catch return) != self.editor.state.revision) return;
                var out: std.Io.Writer.Allocating = .init(alloc);
                out.writer.print("{s}: {s}", .{ if (result.dirty) tr("Draft result", "Entwurfsergebnis") else tr("Saved rules", "Gespeicherte Regeln"), switch (result.decision) {
                    .normal => tr("Delivered normally", "Normal zugestellt"),
                    .block => tr("Blocked — no popup or history", "Blockiert — kein Popup oder Verlauf"),
                    .history_only => tr("History only — no popup", "Nur Verlauf — kein Popup"),
                } }) catch return;
                for (result.matches) |match| out.writer.print("\n• {s}", .{match.name}) catch return;
                if (!result.filters_enabled) out.writer.writeAll(tr("\nFiltering is paused.", "\nFilter sind pausiert.")) catch return;
                self.test_result.setText(alloc.dupeZ(u8, out.written()) catch return);
            }
        };
    }
    fn render(self: *View, config: f.Config) !void {
        self.invalidate(self.context, .notifications);
        while (self.rows.as(gtk.Widget).getFirstChild()) |child| self.rows.remove(child);
        self.controls.shrinkRetainingCapacity(self.fixed_count);
        _ = self.arena.reset(.retain_capacity);
        const alloc = self.arena.allocator();
        if (config.rules.len == 0) self.rows.append(w.label(tr("No filters yet. Add a filter to hide matching notifications.", "Noch keine Filter. Einen Filter hinzufügen, um passende Benachrichtigungen auszublenden."), "pearl-secondary").as(gtk.Widget));
        for (config.rules) |r| {
            const card = builder.card();
            const top = w.row(10);
            const title = w.label(try alloc.dupeZ(u8, r.name), "settings-row-title");
            title.setWrap(1);
            title.as(gtk.Widget).setHexpand(1);
            top.append(title.as(gtk.Widget));
            const toggle = gtk.Switch.new();
            toggle.setActive(@intFromBool(r.enabled));
            toggle.as(gtk.Widget).setValign(.center);
            w.name(toggle.as(gtk.Widget), try std.fmt.allocPrintSentinel(alloc, "{s}: {s}", .{ tr("Enable filter", "Filter aktivieren"), r.name }, 0));
            const binding = try alloc.create(Binding);
            binding.* = .{ .view = self, .id = .{}, .toggle = true };
            binding.id.set(r.id);
            _ = object.Object.signals.notify.connect(toggle.as(object.Object), *Binding, ruleToggled, binding, .{ .detail = "active" });
            top.append(toggle.as(gtk.Widget));
            const edit = w.wrappingButton(tr("Edit", "Bearbeiten"));
            _ = gtk.Button.signals.clicked.connect(edit, *Binding, editClicked, binding, .{});
            top.append(edit.as(gtk.Widget));
            card.append(top.as(gtk.Widget));
            var out: std.Io.Writer.Allocating = .init(alloc);
            try out.writer.print("{s} · {s}", .{ if (r.action == .block) tr("Block", "Blockieren") else tr("History only", "Nur Verlauf"), if (r.match == .all) tr("Match all", "Alle Bedingungen") else tr("Match any", "Eine Bedingung") });
            for (r.conditions) |c| try out.writer.print("\n{s} {s} “{s}”", .{ fieldLabel(c.field), if (c.operator == .equals) tr("is", "ist") else tr("contains", "enthält"), c.value });
            const summary = w.label(try alloc.dupeZ(u8, out.written()), "pearl-secondary");
            summary.setWrap(1);
            card.append(summary.as(gtk.Widget));
            self.rows.append(card.as(gtk.Widget));
            try self.controls.appendSlice(a, &.{ .{ .id = try std.fmt.allocPrint(alloc, "filters.toggle.{s}", .{r.id}), .widget = toggle.as(gtk.Widget) }, .{ .id = try std.fmt.allocPrint(alloc, "filters.edit.{s}", .{r.id}), .widget = edit.as(gtk.Widget) } });
        }
    }
    fn fieldLabel(field: f.Field) [:0]const u8 {
        return switch (field) {
            .app_name => tr("Application name", "Anwendungsname"),
            .desktop_entry => tr("Desktop ID", "Desktop-ID"),
            .summary => tr("Title", "Titel"),
            .body => tr("Body", "Text"),
            .urgency => tr("Urgency", "Dringlichkeit"),
        };
    }
    fn queue(self: *View) void {
        if (self.idle == 0) self.idle = glib.idleAdd(refresh, self);
    }
    fn refresh(data: ?*anyopaque) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(data.?));
        self.idle = 0;
        self.update();
        if (self.focus_id.len > 0) {
            for (self.controls.items) |control| if (std.mem.eql(u8, control.id, self.focus_id.slice())) {
                _ = control.widget.grabFocus();
                break;
            };
            self.focus_id = .{};
        }
        return 0;
    }
    fn saveConfig(self: *View, prefs: model.Preferences) !void {
        if (!self.editable()) return error.Unavailable;
        try prefs.validate();
        self.editing = true;
        defer self.editing = false;
        const bytes = try std.json.Stringify.valueAlloc(a, prefs, .{ .whitespace = .indent_2 });
        defer a.free(bytes);
        try self.editor.edit(bytes);
        self.editor.invalidateNotificationTest();
        self.queue();
    }
    fn masterChanged(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        if (self.filling) return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var prefs = model.parse(arena.allocator(), self.editor.text()) catch return;
        prefs.notifications.filters_enabled = self.master.getActive() != 0;
        self.saveConfig(prefs) catch |err| self.editor.error_code.set(@errorName(err));
    }
    fn ruleToggled(_: *object.Object, _: *object.ParamSpec, binding: *Binding) callconv(.c) void {
        const self = binding.view;
        if (self.filling) return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var prefs = model.parse(arena.allocator(), self.editor.text()) catch return;
        const rules = arena.allocator().dupe(f.Rule, prefs.notifications.rules) catch return;
        for (rules) |*r| if (std.mem.eql(u8, r.id, binding.id.slice())) {
            r.enabled = !r.enabled;
            break;
        };
        prefs.notifications.rules = rules;
        var id: [96]u8 = undefined;
        self.focus_id.set(std.fmt.bufPrint(&id, "filters.toggle.{s}", .{binding.id.slice()}) catch "filters.add");
        self.saveConfig(prefs) catch |err| self.editor.error_code.set(@errorName(err));
    }
    fn addClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.openDialog(null) catch |err| self.editor.error_code.set(@errorName(err));
    }
    fn editClicked(_: *gtk.Button, binding: *Binding) callconv(.c) void {
        binding.view.openDialog(binding.id.slice()) catch |err| binding.view.editor.error_code.set(@errorName(err));
    }
    fn sampleChanged(_: *gtk.Editable, self: *View) callconv(.c) void {
        self.editor.invalidateNotificationTest();
        self.test_result.setText("");
    }
    fn sampleChoiceChanged(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        self.editor.invalidateNotificationTest();
        self.test_result.setText("");
    }
    fn testClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.editor.testNotifications(.{ .app_name = std.mem.span(self.sample[0].as(gtk.Editable).getText()), .desktop_entry = std.mem.span(self.sample[1].as(gtk.Editable).getText()), .summary = std.mem.span(self.sample[2].as(gtk.Editable).getText()), .body = std.mem.span(self.sample[3].as(gtk.Editable).getText()), .urgency = @enumFromInt(@min(2, self.sample_urgency.getSelected())) }) catch |err| self.editor.notification_test_error.set(@errorName(err));
        self.test_result.setText(tr("Testing the synchronized draft…", "Synchronisierten Entwurf testen…"));
    }
    fn styleDialog(self: *View) void {
        const dialog = self.dialog orelse return;
        builder.style(dialog, self.window);
    }
    fn closeDialog(self: *View) void {
        self.dialog_controls.clearRetainingCapacity();
        if (self.dialog) |dialog| {
            self.dialog = null;
            dialog.as(gtk.Window).destroy();
            dialog.unref();
        }
        self.dialog_scroll = null;
        self.rule_name = null;
        self.rule_error = null;
    }
    fn openDialog(self: *View, id: ?[]const u8) !void {
        if (!self.editable() or self.dialog != null) return;
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const alloc = scratch.allocator();
        const prefs = try model.parse(alloc, self.editor.text());
        if (id == null and prefs.notifications.rules.len >= f.max_rules) return error.TooManyNotificationFilters;
        var rule: ?f.Rule = null;
        if (id) |wanted| {
            for (prefs.notifications.rules) |r| if (std.mem.eql(u8, r.id, wanted)) {
                rule = r;
                break;
            };
            if (rule == null) return error.Stale;
        }
        self.dialog_hash = try configHash(alloc, prefs.notifications);
        self.rule_id.set(if (rule) |r| r.id else "");
        self.rule_enabled = if (rule) |r| r.enabled else true;
        self.focus_id.set(if (id) |value| try std.fmt.allocPrint(alloc, "filters.edit.{s}", .{value}) else "filters.add");
        const shell = builder.open(self.window, if (rule != null) tr("Edit notification filter", "Benachrichtigungsfilter bearbeiten") else tr("Add notification filter", "Benachrichtigungsfilter hinzufügen"));
        const dialog = shell.dialog;
        const body = shell.body;
        self.dialog = dialog;
        self.dialog_scroll = shell.scroll;
        errdefer self.closeDialog();
        self.rule_name = entryRow(body, tr("Filter name", "Filtername"), 80);
        self.rule_action = choiceRow(body, tr("When a notification matches", "Bei passender Benachrichtigung"), &.{ tr("Block — hide everywhere", "Blockieren — überall ausblenden"), tr("History only — no popup", "Nur Verlauf — kein Popup"), null });
        self.rule_match = choiceRow(body, tr("Conditions", "Bedingungen"), &.{ tr("Match all conditions", "Alle Bedingungen erfüllen"), tr("Match any condition", "Eine Bedingung erfüllen"), null });
        try self.dialog_controls.appendSlice(a, &.{ .{ .id = "filters.rule.name", .widget = self.rule_name.?.as(gtk.Widget) }, .{ .id = "filters.rule.action", .widget = self.rule_action.?.as(gtk.Widget) }, .{ .id = "filters.rule.match", .widget = self.rule_match.?.as(gtk.Widget) } });
        if (rule) |r| {
            self.rule_name.?.as(gtk.Editable).setText(try alloc.dupeZ(u8, r.name));
            self.rule_action.?.setSelected(@intFromEnum(r.action));
            self.rule_match.?.setSelected(@intFromEnum(r.match));
        }
        self.condition_count = if (rule) |r| r.conditions.len else 1;
        for (&self.condition_widgets, 0..) |*cw, i| {
            const box = w.column(6);
            box.as(gtk.Widget).addCssClass("settings-card");
            const line = w.row(8);
            const label = w.label(try std.fmt.allocPrintSentinel(alloc, "{s} {d}", .{ tr("Condition", "Bedingung"), i + 1 }, 0), "settings-row-title");
            label.as(gtk.Widget).setHexpand(1);
            line.append(label.as(gtk.Widget));
            const remove = w.wrappingButton(tr("Remove", "Entfernen"));
            w.name(remove.as(gtk.Widget), try std.fmt.allocPrintSentinel(alloc, "{s} {d}", .{ tr("Remove condition", "Bedingung entfernen"), i + 1 }, 0));
            line.append(remove.as(gtk.Widget));
            box.append(line.as(gtk.Widget));
            const selectors = w.flow(2);
            selectors.setHomogeneous(1);
            const field_box = w.column(4);
            const comparison_box = w.column(4);
            selectors.insert(field_box.as(gtk.Widget), -1);
            selectors.insert(comparison_box.as(gtk.Widget), -1);
            box.append(selectors.as(gtk.Widget));
            const field = choiceRow(field_box, tr("Field", "Feld"), &.{ fieldLabel(.app_name), fieldLabel(.desktop_entry), fieldLabel(.summary), fieldLabel(.body), fieldLabel(.urgency), null });
            const comparison = choiceRow(comparison_box, tr("Comparison", "Vergleich"), &.{ tr("Is exactly", "Ist genau"), tr("Contains", "Enthält"), null });
            const value = entryRow(box, tr("Value", "Wert"), 256);
            const urgency = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ tr("Low", "Niedrig"), tr("Normal", "Normal"), tr("Critical", "Kritisch"), null }));
            w.name(urgency.as(gtk.Widget), tr("Urgency", "Dringlichkeit"));
            box.append(urgency.as(gtk.Widget));
            const case_sensitive = gtk.CheckButton.newWithLabel(tr("Match case", "Groß-/Kleinschreibung beachten"));
            box.append(case_sensitive.as(gtk.Widget));
            cw.* = .{ .view = self, .index = i, .host = box, .field = field, .comparison = comparison, .value = value, .urgency = urgency, .case_sensitive = case_sensitive };
            _ = object.Object.signals.notify.connect(field.as(object.Object), *ConditionWidgets, fieldChanged, cw, .{ .detail = "selected" });
            _ = gtk.Button.signals.clicked.connect(remove, *ConditionWidgets, removeCondition, cw, .{});
            const c: f.Condition = if (rule != null and i < rule.?.conditions.len) rule.?.conditions[i] else .{ .field = if (i == 0) .app_name else .summary, .value = "" };
            fillCondition(cw, c);
            box.as(gtk.Widget).setVisible(@intFromBool(i < self.condition_count));
            body.append(box.as(gtk.Widget));
            // IDs have static lifetime, independent of rule-list refreshes.
            inline for (.{ "field", "comparison", "value", "urgency", "case_sensitive" }) |name| {
                const ids = comptime blk: {
                    var entries: [f.max_conditions][]const u8 = undefined;
                    for (&entries, 0..) |*v, n| v.* = std.fmt.comptimePrint("filters.condition.{d}.{s}", .{ n, name });
                    break :blk entries;
                };
                try self.dialog_controls.append(a, .{ .id = ids[i], .widget = @field(cw, name).as(gtk.Widget) });
            }
            const remove_ids = comptime blk: {
                var ids: [f.max_conditions][]const u8 = undefined;
                for (&ids, 0..) |*v, n| v.* = std.fmt.comptimePrint("filters.condition.{d}.remove", .{n});
                break :blk ids;
            };
            try self.dialog_controls.append(a, .{ .id = remove_ids[i], .widget = remove.as(gtk.Widget) });
        }
        self.add_condition = w.wrappingButton(tr("Add condition", "Bedingung hinzufügen"));
        self.add_condition.?.as(gtk.Widget).setSensitive(@intFromBool(self.condition_count < f.max_conditions));
        body.append(self.add_condition.?.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(self.add_condition.?, *View, addCondition, self, .{});
        const help = w.label(tr("Application identifiers are supplied by the sender. Matching critical notifications are filtered too. Save rule updates the draft; Apply & save activates it.", "Anwendungskennungen stammen vom Absender. Passende kritische Benachrichtigungen werden ebenfalls gefiltert. Regel speichern ändert den Entwurf; Anwenden aktiviert ihn."), "pearl-secondary");
        help.setWrap(1);
        body.append(help.as(gtk.Widget));
        self.rule_error = w.label("", "pearl-error");
        self.rule_error.?.setWrap(1);
        self.rule_error.?.as(gtk.Widget).setFocusable(1);
        body.append(self.rule_error.?.as(gtk.Widget));
        if (rule != null) {
            const delete = dialog.addButton(tr("Delete filter", "Filter löschen"), 1);
            try self.dialog_controls.append(a, .{ .id = "filters.rule.delete", .widget = delete });
        }
        const cancel = dialog.addButton(tr("Cancel", "Abbrechen"), @intFromEnum(gtk.ResponseType.cancel));
        const save = dialog.addButton(tr("Save rule", "Regel speichern"), @intFromEnum(gtk.ResponseType.accept));
        try self.dialog_controls.appendSlice(a, &.{ .{ .id = "filters.rule.cancel", .widget = cancel }, .{ .id = "filters.rule.save", .widget = save }, .{ .id = "filters.condition.add", .widget = self.add_condition.?.as(gtk.Widget) } });
        _ = gtk.Dialog.signals.response.connect(dialog, *View, response, self, .{});
        dialog.as(gtk.Window).present();
        _ = self.rule_name.?.as(gtk.Widget).grabFocus();
    }
    fn fillCondition(cw: *ConditionWidgets, c: f.Condition) void {
        cw.field.setSelected(@intFromEnum(c.field));
        cw.comparison.setSelected(@intFromEnum(c.operator));
        var buffer: [257]u8 = undefined;
        cw.value.as(gtk.Editable).setText(std.fmt.bufPrintZ(&buffer, "{s}", .{c.value}) catch "");
        cw.case_sensitive.setActive(@intFromBool(c.case_sensitive));
        cw.urgency.setSelected(if (std.mem.eql(u8, c.value, "low")) 0 else if (std.mem.eql(u8, c.value, "critical")) 2 else 1);
        configureCondition(cw);
    }
    fn fieldChanged(_: *object.Object, _: *object.ParamSpec, cw: *ConditionWidgets) callconv(.c) void {
        configureCondition(cw);
    }
    fn configureCondition(cw: *ConditionWidgets) void {
        const field: f.Field = @enumFromInt(@min(4, cw.field.getSelected()));
        const fixed = field == .desktop_entry or field == .urgency;
        cw.comparison.as(gtk.Widget).setSensitive(@intFromBool(!fixed));
        if (fixed) {
            cw.comparison.setSelected(0);
            cw.case_sensitive.setActive(1);
        }
        cw.case_sensitive.as(gtk.Widget).setVisible(@intFromBool(!fixed));
        cw.value.as(gtk.Widget).setVisible(@intFromBool(field != .urgency));
        cw.value.setMaxLength(if (field == .app_name) 160 else 256);
        cw.urgency.as(gtk.Widget).setVisible(@intFromBool(field == .urgency));
    }
    fn readCondition(cw: *ConditionWidgets) f.Condition {
        const field: f.Field = @enumFromInt(@min(4, cw.field.getSelected()));
        return .{ .field = field, .operator = @enumFromInt(@min(1, cw.comparison.getSelected())), .value = if (field == .urgency) switch (cw.urgency.getSelected()) {
            0 => "low",
            2 => "critical",
            else => "normal",
        } else std.mem.span(cw.value.as(gtk.Editable).getText()), .case_sensitive = cw.case_sensitive.getActive() != 0 };
    }
    fn addCondition(_: *gtk.Button, self: *View) callconv(.c) void {
        if (self.condition_count >= f.max_conditions) return;
        const cw = &self.condition_widgets[self.condition_count];
        fillCondition(cw, .{ .field = .summary, .operator = .contains, .value = "" });
        self.condition_count += 1;
        cw.host.as(gtk.Widget).setVisible(1);
        self.add_condition.?.as(gtk.Widget).setSensitive(@intFromBool(self.condition_count < f.max_conditions));
        _ = cw.value.as(gtk.Widget).grabFocus();
    }
    fn removeCondition(_: *gtk.Button, cw: *ConditionWidgets) callconv(.c) void {
        const self = cw.view;
        if (self.condition_count <= 1) {
            self.rule_error.?.setText(tr("Keep at least one condition.", "Mindestens eine Bedingung ist erforderlich."));
            return;
        }
        for (cw.index..self.condition_count - 1) |i| {
            const c = readCondition(&self.condition_widgets[i + 1]);
            fillCondition(&self.condition_widgets[i], c);
        }
        self.condition_count -= 1;
        self.condition_widgets[self.condition_count].host.as(gtk.Widget).setVisible(0);
        self.add_condition.?.as(gtk.Widget).setSensitive(1);
        _ = self.add_condition.?.as(gtk.Widget).grabFocus();
    }
    fn commitRule(self: *View, delete: bool) !void {
        if (!self.editable()) return error.Unavailable;
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const alloc = scratch.allocator();
        var prefs = try model.parse(alloc, self.editor.text());
        if (!std.mem.eql(u8, &self.dialog_hash, &try configHash(alloc, prefs.notifications))) return error.FilterDraftChanged;
        var rules: std.ArrayList(f.Rule) = .empty;
        for (prefs.notifications.rules) |r| if (!std.mem.eql(u8, r.id, self.rule_id.slice())) try rules.append(alloc, r);
        if (!delete) {
            const conditions = try alloc.alloc(f.Condition, self.condition_count);
            for (conditions, self.condition_widgets[0..self.condition_count]) |*c, *cw| {
                c.* = readCondition(cw);
                if (c.field == .desktop_entry) c.value = f.withoutSuffix(c.value);
            }
            var id: [32]u8 = undefined;
            if (self.rule_id.len == 0) {
                var random: [16]u8 = undefined;
                if (std.os.linux.getrandom(&random, random.len, 0) != random.len) return error.RandomUnavailable;
                id = std.fmt.bytesToHex(random, .lower);
            }
            try rules.append(alloc, .{ .id = if (self.rule_id.len > 0) self.rule_id.slice() else &id, .name = std.mem.trim(u8, std.mem.span(self.rule_name.?.as(gtk.Editable).getText()), " \t\r\n"), .enabled = self.rule_enabled, .action = @enumFromInt(@min(1, self.rule_action.?.getSelected())), .match = @enumFromInt(@min(1, self.rule_match.?.getSelected())), .conditions = conditions });
            prefs.notifications.rules = rules.items;
            try self.saveConfig(prefs);
        } else {
            prefs.notifications.rules = rules.items;
            try self.saveConfig(prefs);
            self.focus_id.set("filters.add");
        }
    }
    fn response(_: *gtk.Dialog, code: c_int, self: *View) callconv(.c) void {
        if (code == @intFromEnum(gtk.ResponseType.accept) or code == 1) {
            self.commitRule(code == 1) catch |err| {
                self.rule_error.?.setText(if (err == error.FilterDraftChanged) tr("Filters changed elsewhere. Your input is retained; cancel and reopen to review the current rules.", "Filter wurden anderswo geändert. Eingaben bleiben erhalten; abbrechen und zum Prüfen erneut öffnen.") else tr("Check the name and conditions. Values must be nonempty, within their byte limits, and valid for the selected field.", "Name und Bedingungen prüfen. Werte müssen ausgefüllt, innerhalb ihrer Byte-Grenzen und für das Feld gültig sein."));
                _ = self.rule_error.?.as(gtk.Widget).grabFocus();
                return;
            };
        }
        self.closeDialog();
        if (!self.editor.state.locked and self.editor.online and !self.editor.suspended) self.window.present();
        self.queue();
    }
};
