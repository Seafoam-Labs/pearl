//! Selection-based bar editor. All changes go through the shared Pearl draft.
const std = @import("std");
const gtk = @import("gtk4");
const object = @import("gobject2");
const glib = @import("glib2");
const prefs = @import("../config/preferences.zig");
const workspace_policy = @import("../desktop/workspace_policy.zig");
const policy = @import("../desktop/policy.zig");
const model = @import("bar_model.zig");
const protocol = @import("editor_protocol.zig");
const Editor = @import("editor.zig").Editor;
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;
const Group = model.Group;
const Intent = union(enum) { picker: Group, actions, change: model.Action, workspace_mode: prefs.WorkspaceMode, focus: Group, advanced, plugins };
const Binding = struct { view: *View, id: []const u8, intent: Intent };
pub const Control = struct { id: []const u8, widget: *gtk.Widget };
const Choice = struct { widget: *gtk.Widget, text: []const u8 };
pub const View = struct {
    editor: *Editor,
    host: *gtk.Box,
    content: *gtk.Box,
    notice: *gtk.Label,
    repair: *gtk.Button,
    context: *anyopaque,
    invalidate: *const fn (*anyopaque, @import("../desktop/settings_navigation.zig").Route) void,
    arena: std.heap.ArenaAllocator,
    menu_arena: std.heap.ArenaAllocator,
    controls: std.ArrayList(Control) = .empty,
    menu_controls: std.ArrayList(Control) = .empty,
    choices: std.ArrayList(Choice) = .empty,
    cards: [3]?*gtk.Widget = @splat(null),
    group_titles: [3]?*gtk.Label = @splat(null),
    popup: ?*gtk.Popover = null,
    popup_closed: bool = false,
    popup_hash: [64]u8 = undefined,
    popup_error: ?*gtk.Label = null,
    popup_workspace_mode: prefs.WorkspaceMode = .large,
    destination: ?*gtk.DropDown = null,
    search: ?*gtk.Entry = null,
    signature: ?[64]u8 = null,
    idle: c_uint = 0,
    editing: bool = false,
    focus_id: ?[]u8 = null,

    pub fn create(host: *gtk.Box, editor: *Editor, context: *anyopaque, invalidate: @FieldType(View, "invalidate")) !*View {
        const self = try a.create(View);
        const notice = w.label("", "pearl-secondary");
        host.append(notice.as(gtk.Widget));
        const repair = gtk.Button.newWithLabel("Repair draft in Advanced");
        host.append(repair.as(gtk.Widget));
        repair.as(gtk.Widget).setVisible(0);
        _ = gtk.Button.signals.clicked.connect(repair, *View, repairDraft, self, .{});
        const content = w.column(14);
        host.append(content.as(gtk.Widget));
        self.* = .{ .host = host, .editor = editor, .notice = notice, .repair = repair, .content = content, .context = context, .invalidate = invalidate, .arena = .init(a), .menu_arena = .init(a) };
        self.update();
        return self;
    }
    fn repairDraft(_: *gtk.Button, self: *View) callconv(.c) void {
        self.editor.navigate(.{ .page = .advanced }, false);
    }
    pub fn destroy(self: *View) void {
        if (self.idle != 0) _ = glib.Source.remove(self.idle);
        self.clearPopup();
        self.clear();
        self.controls.deinit(a);
        self.menu_controls.deinit(a);
        self.choices.deinit(a);
        self.arena.deinit();
        self.menu_arena.deinit();
        if (self.focus_id) |id| a.free(id);
        a.destroy(self);
    }
    fn clear(self: *View) void {
        self.invalidate(self.context, .bar);
        self.controls.clearRetainingCapacity();
        self.cards = @splat(null);
        self.group_titles = @splat(null);
        while (self.content.as(gtk.Widget).getFirstChild()) |child| self.content.remove(child);
        _ = self.arena.reset(.retain_capacity);
    }
    fn clearPopup(self: *View) void {
        if (self.popup) |popup| {
            // Detach before freeing callback storage. closed() only queues work.
            self.popup = null;
            popup.as(gtk.Widget).unparent();
        }
        self.popup_error = null;
        self.destination = null;
        self.search = null;
        self.popup_closed = false;
        self.menu_controls.clearRetainingCapacity();
        self.choices.clearRetainingCapacity();
        _ = self.menu_arena.reset(.retain_capacity);
    }
    fn queue(self: *View) void {
        if (self.idle == 0) self.idle = glib.idleAdd(refresh, self);
    }
    fn refresh(data: ?*anyopaque) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(data.?));
        self.idle = 0;
        if (self.popup_closed) self.clearPopup();
        self.update();
        if (self.focus_id) |id| {
            for (self.controls.items) |control| if (std.mem.eql(u8, control.id, id)) {
                _ = control.widget.grabFocus();
                break;
            };
            a.free(id);
            self.focus_id = null;
        }
        return 0;
    }
    fn rememberFocus(self: *View, id: []const u8) void {
        if (self.focus_id) |old| a.free(old);
        self.focus_id = a.dupe(u8, id) catch null;
    }
    fn catalog(self: *View, alloc: std.mem.Allocator) model.Catalog {
        if (self.editor.target.page != .bar or !self.editor.client.capabilities.bar_widgets) return .{};
        return std.json.parseFromSliceLeaky(model.Catalog, alloc, self.editor.live orelse "{}", .{ .ignore_unknown_fields = true }) catch .{};
    }
    fn barHash(alloc: std.mem.Allocator, bar: prefs.Bar) ![64]u8 {
        return protocol.digest(try std.json.Stringify.valueAlloc(alloc, bar, .{}));
    }
    pub fn update(self: *View) void {
        if (self.editing) return;
        if (self.editor.target.page != .bar and self.signature != null) {
            if (self.popup) |popup| popup.popdown();
            return;
        }
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const alloc = temp.allocator();
        const document = prefs.parse(alloc, self.editor.text()) catch {
            self.repair.as(gtk.Widget).setVisible(1);
            self.notice.setText("The preference draft needs repair. Open Advanced to fix it; your text is retained.");
            self.content.as(gtk.Widget).setSensitive(0);
            if (self.popup) |popup| popup.popdown();
            return;
        };
        const editable = self.editor.editable();
        self.repair.as(gtk.Widget).setVisible(0);
        self.notice.setText("Default bar layout. Display overrides take priority and remain in Advanced.");
        if (self.popup) |popup| {
            if (!self.editor.online or self.editor.state.locked or self.editor.suspended or self.editor.recovery or self.editor.target.page != .bar) popup.popdown();
            if (popup.getChild()) |child| child.setSensitive(@intFromBool(editable));
            // Keep picker focus through acknowledgments. Activation checks the
            // latest document and catalog, and rejects a changed bar revision.
            return;
        }
        self.content.as(gtk.Widget).setSensitive(@intFromBool(editable));
        const plugins = self.catalog(alloc);
        const signature = protocol.digest(std.json.Stringify.valueAlloc(alloc, .{ .bar = document.bar, .plugins = document.plugins, .catalog = plugins }, .{}) catch return);
        if (self.signature) |old| if (std.mem.eql(u8, &old, &signature)) return;
        // Only invalidate widget pointers when the displayed layout changes.
        if (self.focus_id == null) for (self.controls.items) |control| if (control.widget.hasFocus() != 0) {
            self.rememberFocus(control.id);
            self.queue();
            break;
        };
        self.clear();
        self.signature = null;
        self.render(document, plugins) catch |err| {
            self.report(err);
            return;
        };
        self.signature = signature;
    }
    fn button(self: *View, parent: *gtk.Box, label: [:0]const u8, control_id: []const u8, id: []const u8, intent: Intent, menu: bool) !*gtk.Button {
        const alloc = if (menu) self.menu_arena.allocator() else self.arena.allocator();
        const binding = try alloc.create(Binding);
        binding.* = .{ .view = self, .id = try alloc.dupe(u8, id), .intent = intent };
        const result = if (intent == .actions) gtk.Button.newWithLabel(label) else w.wrappingButton(label);
        parent.append(result.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(result, *Binding, clicked, binding, .{});
        const controls = if (menu) &self.menu_controls else &self.controls;
        try controls.append(a, .{ .id = try alloc.dupe(u8, control_id), .widget = result.as(gtk.Widget) });
        return result;
    }
    fn name(alloc: std.mem.Allocator, id: []const u8, plugins: model.Catalog) ![:0]const u8 {
        if (std.meta.stringToEnum(policy.Item, id)) |item| return model.metadata(item).name;
        if (plugins.bar_widgets) |items| for (items) |plugin| {
            const ref = try std.fmt.allocPrint(alloc, "plugin:{s}/main", .{plugin.id});
            if (std.mem.eql(u8, ref, id)) return alloc.dupeZ(u8, plugin.name);
        };
        return alloc.dupeZ(u8, id);
    }
    fn pluginDetail(alloc: std.mem.Allocator, document: prefs.Preferences, id: []const u8, plugins: model.Catalog) ![:0]const u8 {
        if (plugins.bar_widgets) |items| for (items) |plugin| {
            const ref = try std.fmt.allocPrint(alloc, "plugin:{s}/main", .{plugin.id});
            if (!std.mem.eql(u8, ref, id)) continue;
            const config = document.plugins.find(plugin.id) orelse return "Plugin is not enabled · Placement retained";
            if (!plugin.available) return "Plugin unavailable · Placement retained";
            if (!std.mem.eql(u8, config.digest, plugin.digest)) return "Approval needed in Plugins · Placement retained";
            if (!config.enabled) return "Plugin disabled · Placement retained";
            if (config.placement.mode != .bar) return "Desktop overlay · Bar placement retained";
            return std.fmt.allocPrintSentinel(alloc, "Plugin · {s}", .{plugin.status}, 0);
        };
        return "Plugin metadata unavailable · Placement retained";
    }
    fn render(self: *View, document: prefs.Preferences, plugins: model.Catalog) !void {
        const alloc = self.arena.allocator();
        const layout = try model.Layout.parse(alloc, document.bar.groups);
        self.notice.setText("Default bar layout. Display overrides take priority and remain in Advanced.");
        const preview = w.column(8);
        preview.as(gtk.Widget).addCssClass("settings-card");
        preview.as(gtk.Widget).addCssClass("bar-preview");
        self.content.append(preview.as(gtk.Widget));
        preview.append(w.label(try std.fmt.allocPrintSentinel(alloc, "Draft preview · {s} edge · {d} px · {s}", .{ @tagName(document.bar.edge), document.bar.size, if (document.bar.islands) "Separate islands" else "Continuous bar" }, 0), "pearl-secondary").as(gtk.Widget));
        const vertical = document.bar.edge == .left or document.bar.edge == .right;
        const preview_groups = w.flow(if (vertical) 1 else 3);
        preview_groups.setColumnSpacing(if (document.bar.islands) 12 else 0);
        preview.append(preview_groups.as(gtk.Widget));
        for (model.groups) |group| {
            const items = layout.items[@intFromEnum(group)].items;
            const text = try std.fmt.allocPrintSentinel(alloc, "{s} · {d}", .{ model.groupLabel(group, document.bar.edge), items.len }, 0);
            const slot = w.column(0);
            preview_groups.insert(slot.as(gtk.Widget), -1);
            const b = try self.button(slot, text, try std.fmt.allocPrint(alloc, "bar.preview.{s}", .{@tagName(group)}), "", .{ .focus = group }, false);
            const picture = w.column(4);
            picture.append(w.label(text, "pearl-secondary").as(gtk.Widget));
            const icons = w.row(3);
            for (items) |id| {
                const item = std.meta.stringToEnum(policy.Item, id);
                const glyph = w.icon(if (item) |builtin| model.metadata(builtin).icon else "pearl-application-x-executable-symbolic");
                glyph.setPixelSize(14);
                icons.append(glyph.as(gtk.Widget));
            }
            picture.append(icons.as(gtk.Widget));
            b.setChild(picture.as(gtk.Widget));
            b.as(gtk.Widget).setHexpand(1);
            if (document.bar.islands) b.as(gtk.Widget).addCssClass("bar-island");
            b.as(gtk.Widget).setSizeRequest(-1, @intCast(@min(document.bar.size, 80)));
            const descriptions = try alloc.alloc([]const u8, items.len);
            for (items, descriptions) |id, *description| description.* = try name(alloc, id, plugins);
            b.as(gtk.Widget).setTooltipText(try alloc.dupeZ(u8, try std.mem.join(alloc, " → ", descriptions)));
            w.name(b.as(gtk.Widget), try std.fmt.allocPrintSentinel(alloc, "Edit {s} widgets", .{model.groupLabel(group, document.bar.edge)}, 0));
        }
        if (layout.find("workspaces") != null) {
            const mode = document.bar.workspace_mode;
            const range = workspace_policy.visibleRange(9, 4, mode);
            var numbers: [9][]const u8 = undefined;
            for (range.start..range.end, 0..) |index, i| numbers[i] = try std.fmt.allocPrint(alloc, "{s}{d}{s}", .{ if (index == 4) "[" else "", index + 1, if (index == 4) "]" else "" });
            const example = try std.mem.join(alloc, "  ", numbers[0 .. range.end - range.start]);
            const label = w.label(try std.fmt.allocPrintSentinel(alloc, "Workspace example · {s} · 5 active\n{s}", .{ mode.label(), example }, 0), "pearl-secondary");
            preview.append(label.as(gtk.Widget));
            try self.controls.append(a, .{ .id = "bar.workspace.preview", .widget = label.as(gtk.Widget) });
        }
        self.content.append(w.label("Widgets", "settings-row-title").as(gtk.Widget));
        self.content.append(w.label("Add a widget to a group. Use its actions menu to configure, move, reorder or remove it.", "pearl-secondary").as(gtk.Widget));
        const flow = w.flow(3);
        self.content.append(flow.as(gtk.Widget));
        for (model.groups) |group| {
            const g = @intFromEnum(group);
            const card = w.column(6);
            card.as(gtk.Widget).addCssClass("settings-card");
            card.as(gtk.Widget).addCssClass("bar-group");
            card.as(gtk.Widget).setSizeRequest(195, -1);
            card.as(gtk.Widget).setValign(.start);
            card.as(gtk.Widget).setFocusable(1);
            self.cards[g] = card.as(gtk.Widget);
            flow.insert(card.as(gtk.Widget), -1);
            const group_title = w.label(try std.fmt.allocPrintSentinel(alloc, "{s} · {d} widgets", .{ model.groupLabel(group, document.bar.edge), layout.items[g].items.len }, 0), "settings-row-title");
            self.group_titles[g] = group_title;
            card.append(group_title.as(gtk.Widget));
            const add = try self.button(card, "+ Add widget", try std.fmt.allocPrint(alloc, "bar.add.{s}", .{@tagName(group)}), "", .{ .picker = group }, false);
            w.name(add.as(gtk.Widget), try std.fmt.allocPrintSentinel(alloc, "Add widget to {s}", .{model.groupLabel(group, document.bar.edge)}, 0));
            if (layout.items[g].items.len == 0) card.append(w.label("No widgets here yet", "pearl-secondary").as(gtk.Widget));
            for (layout.items[g].items, 0..) |id, i| {
                const row = w.row(8);
                row.as(gtk.Widget).addCssClass("bar-widget-row");
                card.append(row.as(gtk.Widget));
                const builtin = std.meta.stringToEnum(policy.Item, id);
                row.append(w.icon(if (builtin) |item| model.metadata(item).icon else "pearl-application-x-executable-symbolic").as(gtk.Widget));
                const labels = w.column(2);
                labels.as(gtk.Widget).setHexpand(1);
                const title = try name(alloc, id, plugins);
                const title_label = w.label(title, null);
                title_label.setMaxWidthChars(16);
                labels.append(title_label.as(gtk.Widget));
                if (std.mem.eql(u8, id, "launcher")) labels.append(w.label("Required", "pearl-secondary").as(gtk.Widget));
                if (builtin == .workspaces) labels.append(w.label(document.bar.workspace_mode.label(), "pearl-secondary").as(gtk.Widget));
                if (builtin == null) {
                    const detail = w.label(try pluginDetail(alloc, document, id, plugins), "pearl-secondary");
                    detail.setMaxWidthChars(18);
                    labels.append(detail.as(gtk.Widget));
                }
                row.append(labels.as(gtk.Widget));
                const b = try self.button(row, "⋯", try std.fmt.allocPrint(alloc, "bar.widget.{s}", .{id}), id, .actions, false);
                w.name(b.as(gtk.Widget), try std.fmt.allocPrintSentinel(alloc, "Actions for {s}, {s}, position {d} of {d}", .{ title, model.groupLabel(group, document.bar.edge), i + 1, layout.items[g].items.len }, 0));
                b.as(gtk.Widget).setTooltipText(try std.fmt.allocPrintSentinel(alloc, "Actions for {s}", .{title}, 0));
            }
        }
        const links = w.row(8);
        self.content.append(links.as(gtk.Widget));
        _ = try self.button(links, "Open Advanced", "bar.advanced", "", .advanced, false);
        _ = try self.button(links, "Manage plugins", "bar.plugins", "", .plugins, false);
    }
    fn showMenu(self: *View, anchor: *gtk.Widget, id: []const u8, group: ?Group) !void {
        if (self.popup != null or !self.editor.editable()) return;
        const alloc = self.menu_arena.allocator();
        const document = try prefs.parse(alloc, self.editor.text());
        const layout = try model.Layout.parse(alloc, document.bar.groups);
        const plugins = self.catalog(alloc);
        self.popup_hash = try barHash(alloc, document.bar);
        const popup = gtk.Popover.new();
        self.popup = popup;
        errdefer self.clearPopup();
        popup.setAutohide(1);
        popup.as(gtk.Widget).setParent(anchor);
        const box = w.column(8);
        box.as(gtk.Widget).addCssClass("bar-menu");
        popup.setChild(box.as(gtk.Widget));
        _ = gtk.Popover.signals.closed.connect(popup, *View, closed, self, .{});
        self.popup_error = w.label("", "pearl-secondary");
        if (group) |destination| {
            box.append(w.label("Add widget", "settings-row-title").as(gtk.Widget));
            const names = [_:null]?[*:0]const u8{ model.groupLabel(.left, document.bar.edge), model.groupLabel(.center, document.bar.edge), model.groupLabel(.right, document.bar.edge) };
            self.destination = gtk.DropDown.newFromStrings(@ptrCast(&names));
            self.destination.?.setSelected(@intFromEnum(destination));
            w.name(self.destination.?.as(gtk.Widget), "Add widget to group");
            box.append(self.destination.?.as(gtk.Widget));
            try self.menu_controls.append(a, .{ .id = "bar.picker.destination", .widget = self.destination.?.as(gtk.Widget) });
            const search = gtk.Entry.new();
            self.search = search;
            search.setPlaceholderText("Search widgets…");
            search.as(gtk.Editable).setWidthChars(12);
            w.name(search.as(gtk.Widget), "Search widgets");
            box.append(search.as(gtk.Widget));
            try self.menu_controls.append(a, .{ .id = "bar.picker.search", .widget = search.as(gtk.Widget) });
            _ = gtk.Editable.signals.changed.connect(search.as(gtk.Editable), *View, searched, self, .{});
            const scroll = gtk.ScrolledWindow.new();
            scroll.setPolicy(.never, .automatic);
            scroll.setMaxContentHeight(300);
            scroll.setPropagateNaturalHeight(1);
            const list = w.column(6);
            scroll.setChild(list.as(gtk.Widget));
            box.append(scroll.as(gtk.Widget));
            for (std.enums.values(policy.Item)) |item| {
                const meta = model.metadata(item);
                try self.choice(list, @tagName(item), meta.name, meta.description, meta.icon, layout, document.bar.edge, true);
            }
            if (plugins.bar_widgets) |items| {
                for (items) |plugin| {
                    const ref = try std.fmt.allocPrint(alloc, "plugin:{s}/main", .{plugin.id});
                    try self.choice(list, ref, try alloc.dupeZ(u8, plugin.name), if (model.eligible(document, plugin)) "Plugin widget" else "Enable and approve in Plugins", "pearl-application-x-executable-symbolic", layout, document.bar.edge, model.eligible(document, plugin));
                }
            } else list.append(w.label("Plugin discovery unavailable. Existing placements are retained.", "pearl-secondary").as(gtk.Widget));
            box.append(w.label("Enable additional widgets in Plugins.", "pearl-secondary").as(gtk.Widget));
        } else {
            const pos = layout.find(id) orelse return error.WidgetNotFound;
            const title = try name(alloc, id, plugins);
            box.append(w.label(title, "settings-row-title").as(gtk.Widget));
            box.append(w.label(try std.fmt.allocPrintSentinel(alloc, "{s} · Position {d} of {d}", .{ model.groupLabel(pos.group, document.bar.edge), pos.index + 1, layout.items[@intFromEnum(pos.group)].items.len }, 0), "pearl-secondary").as(gtk.Widget));
            if (std.mem.eql(u8, id, "workspaces")) {
                box.append(w.label("Display mode", "settings-row-title").as(gtk.Widget));
                self.popup_workspace_mode = document.bar.workspace_mode;
                var first: ?*gtk.CheckButton = null;
                for (std.enums.values(prefs.WorkspaceMode)) |mode| {
                    const choice_ = gtk.CheckButton.new();
                    const label = w.label(try std.fmt.allocPrintSentinel(alloc, "{s} · {s}", .{ mode.label(), mode.description() }, 0), null);
                    label.setMaxWidthChars(28);
                    label.as(gtk.Widget).setCanTarget(0);
                    choice_.as(gtk.Widget).setSizeRequest(-1, 32);
                    choice_.setChild(label.as(gtk.Widget));
                    if (first) |leader| choice_.setGroup(leader) else first = choice_;
                    choice_.setActive(@intFromBool(mode == document.bar.workspace_mode));
                    box.append(choice_.as(gtk.Widget));
                    w.name(choice_.as(gtk.Widget), try std.fmt.allocPrintSentinel(alloc, "{s}: {s}", .{ mode.label(), mode.description() }, 0));
                    const binding = try alloc.create(Binding);
                    binding.* = .{ .view = self, .id = "workspaces", .intent = .{ .workspace_mode = mode } };
                    _ = gtk.CheckButton.signals.toggled.connect(choice_, *Binding, modeToggled, binding, .{});
                    try self.menu_controls.append(a, .{ .id = try std.fmt.allocPrint(alloc, "bar.workspace.mode.{s}", .{@tagName(mode)}), .widget = choice_.as(gtk.Widget) });
                }
            }
            const earlier = try self.button(box, "Move earlier", "bar.action.earlier", id, .{ .change = .earlier }, true);
            earlier.as(gtk.Widget).setSensitive(@intFromBool(pos.index != 0));
            const later = try self.button(box, "Move later", "bar.action.later", id, .{ .change = .later }, true);
            later.as(gtk.Widget).setSensitive(@intFromBool(pos.index + 1 < layout.items[@intFromEnum(pos.group)].items.len));
            for (model.groups) |to| if (to != pos.group) {
                _ = try self.button(box, try std.fmt.allocPrintSentinel(alloc, "Move to {s}", .{model.groupLabel(to, document.bar.edge)}, 0), try std.fmt.allocPrint(alloc, "bar.action.move.{s}", .{@tagName(to)}), id, .{ .change = .{ .move = to } }, true);
            };
            const remove = try self.button(box, "Remove from bar", "bar.action.remove", id, .{ .change = .remove }, true);
            remove.as(gtk.Widget).setSensitive(@intFromBool(!std.mem.eql(u8, id, "launcher")));
            if (std.mem.eql(u8, id, "launcher")) box.append(w.label("Launcher is required. It can be moved to any group.", "pearl-secondary").as(gtk.Widget));
        }
        box.append(self.popup_error.?.as(gtk.Widget));
        popup.popup();
        if (self.search) |search| _ = search.as(gtk.Widget).grabFocus();
    }
    fn choice(self: *View, list: *gtk.Box, id: []const u8, title: [:0]const u8, description: [:0]const u8, icon: [:0]const u8, layout: model.Layout, edge: prefs.Edge, eligible: bool) !void {
        const alloc = self.menu_arena.allocator();
        const placed = layout.find(id);
        const label = try std.fmt.allocPrintSentinel(alloc, "{s}\n{s}", .{ title, if (placed) |pos| try std.fmt.allocPrint(alloc, "Already in {s}", .{model.groupLabel(pos.group, edge)}) else description }, 0);
        const b = try self.button(list, label, try std.fmt.allocPrint(alloc, "bar.pick.{s}", .{id}), id, .{ .change = .{ .add = .left } }, true);
        const row = w.row(8);
        row.append(w.icon(icon).as(gtk.Widget));
        row.append(w.label(label, null).as(gtk.Widget));
        b.setChild(row.as(gtk.Widget));
        b.as(gtk.Widget).setSensitive(@intFromBool(eligible and placed == null));
        w.name(b.as(gtk.Widget), try std.fmt.allocPrintSentinel(alloc, "Add {s}{s}", .{ title, if (placed != null) " (already placed)" else "" }, 0));
        try self.choices.append(a, .{ .widget = b.as(gtk.Widget), .text = try std.ascii.allocLowerString(alloc, try std.fmt.allocPrint(alloc, "{s} {s}", .{ title, description })) });
    }
    fn searched(_: *gtk.Editable, self: *View) callconv(.c) void {
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const query = std.ascii.allocLowerString(temp.allocator(), std.mem.span(self.search.?.as(gtk.Editable).getText())) catch return;
        var count: usize = 0;
        for (self.choices.items) |choice_| {
            const visible = std.mem.indexOf(u8, choice_.text, query) != null;
            choice_.widget.setVisible(@intFromBool(visible));
            count += @intFromBool(visible);
        }
        if (self.popup_error) |label| label.setText(if (count == 0) "No widgets match your search." else "");
    }
    fn closed(_: *gtk.Popover, self: *View) callconv(.c) void {
        if (self.popup == null) return;
        self.popup_closed = true;
        self.queue();
    }
    fn report(self: *View, err: anyerror) void {
        const message: [:0]const u8 = switch (err) {
            error.StaleBar => "The bar changed while this menu was open. Close it and try again.",
            error.PluginUnavailable => "This plugin is no longer available for the bar. Review Plugins.",
            error.InvalidGroups => "This group is full or the widget limit was reached. Remove or move a widget first.",
            error.LauncherRequired => "Launcher is required and cannot be removed.",
            error.AlreadyPlaced => "This widget is already on the bar.",
            error.Unavailable => "Editing is unavailable. Your draft is retained.",
            else => "The change could not be completed. Your draft is retained; review Advanced.",
        };
        if (self.popup_error) |label| label.setText(message) else self.notice.setText(message);
    }
    fn mutate(self: *View, id: []const u8, action_: model.Action) !void {
        if (!self.editor.editable() or self.editor.target.page != .bar) return error.Unavailable;
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const alloc = temp.allocator();
        const document = try prefs.parse(alloc, self.editor.text());
        if (!std.mem.eql(u8, &self.popup_hash, &try barHash(alloc, document.bar))) return error.StaleBar;
        var action = action_;
        if (action == .add) {
            action = .{ .add = @enumFromInt(self.destination.?.getSelected()) };
            if (std.mem.startsWith(u8, id, "plugin:")) {
                const plugins = self.catalog(alloc);
                var allowed = false;
                if (plugins.bar_widgets) |items| for (items) |plugin| {
                    if (std.mem.eql(u8, id, try std.fmt.allocPrint(alloc, "plugin:{s}/main", .{plugin.id})) and model.eligible(document, plugin)) allowed = true;
                };
                if (!allowed) return error.PluginUnavailable;
            }
        }
        const next = try model.patch(alloc, self.editor.text(), id, action);
        const focus = if (action == .remove) try std.fmt.allocPrint(alloc, "bar.add.{s}", .{@tagName((try model.Layout.parse(alloc, document.bar.groups)).find(id).?.group)}) else try std.fmt.allocPrint(alloc, "bar.widget.{s}", .{id});
        const next_layout = try model.Layout.parse(alloc, (try prefs.parse(alloc, next)).bar.groups);
        const title = try name(alloc, id, self.catalog(alloc));
        const announcement = if (next_layout.find(id)) |pos| try std.fmt.allocPrintSentinel(alloc, "{s}, {s}, position {d} of {d}. Unsaved changes.", .{ title, model.groupLabel(pos.group, document.bar.edge), pos.index + 1, next_layout.items[@intFromEnum(pos.group)].items.len }, 0) else try std.fmt.allocPrintSentinel(alloc, "{s} removed from bar. Unsaved changes.", .{title}, 0);
        self.editing = true;
        defer self.editing = false;
        try self.editor.edit(next);
        self.host.as(gtk.Accessible).announce(announcement, .medium);
        self.rememberFocus(focus);
        self.popup.?.popdown();
        self.queue();
    }
    fn mutateWorkspaceMode(self: *View, mode: prefs.WorkspaceMode) !void {
        if (!self.editor.editable() or self.editor.target.page != .bar) return error.Unavailable;
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const alloc = temp.allocator();
        const document = try prefs.parse(alloc, self.editor.text());
        if (!std.mem.eql(u8, &self.popup_hash, &try barHash(alloc, document.bar))) return error.StaleBar;
        const next = try model.patchWorkspaceMode(alloc, self.editor.text(), mode);
        self.editing = true;
        defer self.editing = false;
        try self.editor.edit(next);
        self.host.as(gtk.Accessible).announce(try std.fmt.allocPrintSentinel(alloc, "Workspaces: {s}. Unsaved changes.", .{mode.label()}, 0), .medium);
        self.rememberFocus("bar.widget.workspaces");
        self.popup.?.popdown();
        self.queue();
    }
    fn modeToggled(choice_: *gtk.CheckButton, binding: *Binding) callconv(.c) void {
        const self = binding.view;
        if (choice_.getActive() == 0 or self.editing) return;
        self.mutateWorkspaceMode(binding.intent.workspace_mode) catch |err| {
            self.report(err);
            // A rejected draft edit must not leave a falsely selected mode.
            self.editing = true;
            defer self.editing = false;
            for (self.menu_controls.items) |control| if (std.mem.endsWith(u8, control.id, @tagName(self.popup_workspace_mode))) {
                if (object.ext.cast(gtk.CheckButton, control.widget)) |previous| previous.setActive(1);
            };
        };
    }
    fn clicked(button_: *gtk.Button, binding: *Binding) callconv(.c) void {
        const self = binding.view;
        switch (binding.intent) {
            .picker => |group| self.showMenu(button_.as(gtk.Widget), "", group) catch |err| self.report(err),
            .actions => self.showMenu(button_.as(gtk.Widget), binding.id, null) catch |err| self.report(err),
            .change => |action| self.mutate(binding.id, action) catch |err| self.report(err),
            .workspace_mode => |mode| self.mutateWorkspaceMode(mode) catch |err| self.report(err),
            .focus => |group| if (self.cards[@intFromEnum(group)]) |card| {
                _ = card.grabFocus();
            },
            .advanced, .plugins => self.editor.navigate(.{ .page = if (binding.intent == .advanced) .advanced else .plugins }, false),
        }
    }
};
