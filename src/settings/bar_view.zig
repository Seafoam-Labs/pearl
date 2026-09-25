//! Selection-based bar editor. All changes go through the shared Pearl draft.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const object = @import("gobject2");
const glib = @import("glib2");
const prefs = @import("../config/preferences.zig");
const clock_policy = @import("../desktop/clock_policy.zig");
const clock_time = @import("../desktop/clock_time.zig");
const tr = @import("../desktop/text.zig").tr;
const workspace_policy = @import("../desktop/workspace_policy.zig");
const policy = @import("../desktop/policy.zig");
const model = @import("bar_model.zig");
const protocol = @import("editor_protocol.zig");
const Editor = @import("editor.zig").Editor;
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;
const Group = model.Group;
const Icon = @import("../ui/components/launcher_icon.zig");
const Intent = union(enum) { clock_new, clock_open, clock_save, clock_cancel, clock_delete, picker: Group, actions, change: model.Action, workspace_mode: prefs.WorkspaceMode, focus: Group, advanced, plugins, icon_open, icon_theme, icon_file, icon_reset, icon_retry, icon_preset };
const Binding = struct { view: *View, id: []const u8, intent: Intent };
/// G_TYPE_STRING: fundamental type index 16 (2 is G_TYPE_INTERFACE) shifted into GType space.
const g_type_string: usize = 16 << 2;
const DragBinding = struct { view: *View, id: [*:0]const u8, widget: *gtk.Widget };
const RowDrop = struct { view: *View, group: Group, index: usize, widget: *gtk.Widget };
const CardDrop = struct { view: *View, group: Group, widget: *gtk.Widget };
pub const Control = struct { id: []const u8, widget: *gtk.Widget };
const Choice = struct { widget: *gtk.Widget, text: []const u8 };
pub const View = struct {
    icon: Icon.Renderer = .{},
    candidate: Icon.Renderer = .{},
    icon_entry: ?*gtk.Entry = null,
    clock_zone: ?*gtk.Entry = null,
    clock_label: ?*gtk.Entry = null,
    clock_format: ?*gtk.DropDown = null,
    clock_chooser: ?*gtk.DropDown = null,
    clock_date: ?*gtk.CheckButton = null,
    clock_preview: ?*gtk.Label = null,
    clock_zones: []const [:0]const u8 = &.{},
    clock_id: []const u8 = "",
    clock_group: ?Group = null,
    picker: ?*gtk.FileChooserDialog = null,
    picker_hash: [64]u8 = undefined,
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
        self.icon.deinit();
        self.candidate.deinit();
        self.controls.deinit(a);
        self.menu_controls.deinit(a);
        self.choices.deinit(a);
        self.arena.deinit();
        self.menu_arena.deinit();
        if (self.focus_id) |id| a.free(id);
        a.destroy(self);
    }
    fn clear(self: *View) void {
        self.icon.clearTargets();
        self.invalidate(self.context, .bar);
        self.controls.clearRetainingCapacity();
        self.cards = @splat(null);
        self.group_titles = @splat(null);
        while (self.content.as(gtk.Widget).getFirstChild()) |child| self.content.remove(child);
        _ = self.arena.reset(.retain_capacity);
    }
    fn releasePopupFocus(self: *View) void {
        const popup = self.popup orelse return;
        if (popup.as(gtk.Widget).getRoot()) |root| if (object.ext.cast(gtk.Window, root)) |window| {
            if (window.getFocus()) |focus| if (focus.isAncestor(popup.as(gtk.Widget)) != 0) window.setFocus(null);
        };
    }
    fn clearPopup(self: *View) void {
        self.closePicker();
        self.candidate.deinit();
        self.icon_entry = null;
        self.clock_zone = null;
        self.clock_label = null;
        self.clock_format = null;
        self.clock_chooser = null;
        self.clock_date = null;
        self.clock_preview = null;
        self.clock_zones = &.{};
        self.clock_id = "";
        self.clock_group = null;
        if (self.popup) |popup| {
            // Detach before freeing callback storage. closed() only queues work.
            self.releasePopupFocus();
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
        if (self.popup_closed) {
            if (self.picker != null or self.candidate.job != null) return 0;
            self.clearPopup();
        }
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
        if (self.picker != null or self.candidate.job != null) {
            if (!self.editor.editable() or self.editor.target.page != .bar or !std.mem.eql(u8, &self.picker_hash, &protocol.digest(self.editor.text()))) {
                self.closePicker();
                self.candidate.deinit();
                if (self.host.as(gtk.Widget).getRoot()) |root| if (object.ext.cast(gtk.Window, root)) |window| window.present();
                self.rememberFocus("bar.widget.launcher");
                self.queue();
            }
        }
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
            if (!editable) self.releasePopupFocus();
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
    fn name(alloc: std.mem.Allocator, id: []const u8, plugins: model.Catalog, bar: prefs.Bar) ![:0]const u8 {
        if (clock_policy.reference(id)) |clock_id| {
            const definition = clock_policy.find(bar.clocks, clock_id) orelse return alloc.dupeZ(u8, id);
            if (std.mem.eql(u8, id, "clock") and definition.label.len == 0 and std.mem.eql(u8, definition.timezone, "local")) return "Clock";
            return clock_policy.displayName(alloc, definition);
        }
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
        try self.icon.want(document.bar.launcher_icon, false);
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
                const item = if (clock_policy.reference(id) != null) policy.Item.clock else std.meta.stringToEnum(policy.Item, id);
                const glyph = if (item == .launcher) try self.icon.image(14) else w.icon(if (item) |builtin| model.metadata(builtin).icon else "pearl-application-x-executable-symbolic");
                glyph.setPixelSize(14);
                icons.append(glyph.as(gtk.Widget));
            }
            picture.append(icons.as(gtk.Widget));
            b.setChild(picture.as(gtk.Widget));
            b.as(gtk.Widget).setHexpand(1);
            if (document.bar.islands) b.as(gtk.Widget).addCssClass("bar-island");
            b.as(gtk.Widget).setSizeRequest(-1, @intCast(@min(document.bar.size, 80)));
            const descriptions = try alloc.alloc([]const u8, items.len);
            for (items, descriptions) |id, *description| description.* = try name(alloc, id, plugins, document.bar);
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
        const icon_status = self.icon.label();
        preview.append(icon_status.as(gtk.Widget));
        try self.controls.append(a, .{ .id = "bar.icon.status", .widget = icon_status.as(gtk.Widget) });
        self.content.append(w.label("Widgets", "settings-row-title").as(gtk.Widget));
        self.content.append(w.label("Add a widget to a group. Drag rows between groups to move or reorder them, or use the actions menu to configure or remove.", "pearl-secondary").as(gtk.Widget));
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
            const card_drop = try alloc.create(CardDrop);
            card_drop.* = .{ .view = self, .group = group, .widget = card.as(gtk.Widget) };
            const card_target = gtk.DropTarget.new(g_type_string, .{ .move = true });
            _ = gtk.DropTarget.signals.motion.connect(card_target, *CardDrop, cardMotion, card_drop, .{});
            _ = gtk.DropTarget.signals.leave.connect(card_target, *CardDrop, cardLeave, card_drop, .{});
            _ = gtk.DropTarget.signals.drop.connect(card_target, *CardDrop, cardDropped, card_drop, .{});
            card.as(gtk.Widget).addController(card_target.as(gtk.EventController));
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
                const drag_binding = try alloc.create(DragBinding);
                drag_binding.* = .{ .view = self, .id = try alloc.dupeZ(u8, id), .widget = row.as(gtk.Widget) };
                const source = gtk.DragSource.new();
                source.setActions(.{ .move = true });
                _ = gtk.DragSource.signals.prepare.connect(source, *DragBinding, dragPrepare, drag_binding, .{});
                _ = gtk.DragSource.signals.drag_begin.connect(source, *DragBinding, dragBegin, drag_binding, .{});
                _ = gtk.DragSource.signals.drag_end.connect(source, *DragBinding, dragEnd, drag_binding, .{});
                _ = gtk.DragSource.signals.drag_cancel.connect(source, *DragBinding, dragCancel, drag_binding, .{});
                row.as(gtk.Widget).addController(source.as(gtk.EventController));
                const row_drop = try alloc.create(RowDrop);
                row_drop.* = .{ .view = self, .group = group, .index = i, .widget = row.as(gtk.Widget) };
                const row_target = gtk.DropTarget.new(g_type_string, .{ .move = true });
                _ = gtk.DropTarget.signals.motion.connect(row_target, *RowDrop, rowMotion, row_drop, .{});
                _ = gtk.DropTarget.signals.leave.connect(row_target, *RowDrop, rowLeave, row_drop, .{});
                _ = gtk.DropTarget.signals.drop.connect(row_target, *RowDrop, rowDropped, row_drop, .{});
                row.as(gtk.Widget).addController(row_target.as(gtk.EventController));
                const builtin = if (clock_policy.reference(id) != null) policy.Item.clock else std.meta.stringToEnum(policy.Item, id);
                row.append((if (builtin == .launcher) try self.icon.image(20) else w.icon(if (builtin) |item| model.metadata(item).icon else "pearl-application-x-executable-symbolic")).as(gtk.Widget));
                const labels = w.column(2);
                labels.as(gtk.Widget).setHexpand(1);
                const title = try name(alloc, id, plugins, document.bar);
                const title_label = w.label(title, null);
                title_label.setMaxWidthChars(16);
                labels.append(title_label.as(gtk.Widget));
                if (std.mem.eql(u8, id, "launcher")) labels.append(w.label("Required", "pearl-secondary").as(gtk.Widget));
                if (clock_policy.reference(id)) |clock_id| {
                    const definition = clock_policy.find(document.bar.clocks, clock_id).?;
                    const detail = w.label(try alloc.dupeZ(u8, definition.timezone), "pearl-secondary");
                    detail.setMaxWidthChars(18);
                    labels.append(detail.as(gtk.Widget));
                }
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
        for (document.bar.clocks) |definition| {
            if (layout.find(try clock_policy.token(alloc, definition.id)) != null) continue;
            const row = w.row(8);
            self.content.append(row.as(gtk.Widget));
            row.append(w.label(try std.fmt.allocPrintSentinel(alloc, "{s}: {s} · {s}", .{ tr("Saved clock", "Gespeicherte Uhr"), try clock_policy.displayName(alloc, definition), definition.timezone }, 0), "pearl-secondary").as(gtk.Widget));
            _ = try self.button(row, tr("Delete saved clock", "Gespeicherte Uhr löschen"), try std.fmt.allocPrint(alloc, "bar.clock.delete.{s}", .{definition.id}), definition.id, .clock_delete, false);
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
            const another = try self.button(list, tr("Add another clock…", "Weitere Uhr hinzufügen…"), "bar.pick.clock-new", "", .clock_new, true);
            try self.choices.append(a, .{ .widget = another.as(gtk.Widget), .text = "clock time zone timezone uhr zeitzone" });
            var count = document.bar.clocks.len;
            if (layout.find("clock") != null) {
                var explicit_local = false;
                for (document.bar.clocks) |definition| if (std.mem.eql(u8, definition.id, "local")) {
                    explicit_local = true;
                };
                if (!explicit_local) count += 1;
            }
            if (count >= clock_policy.max_clocks) {
                another.as(gtk.Widget).setSensitive(0);
                list.append(w.label(tr("Eight clocks are supported. Delete an unused saved clock to add another.", "Bis zu acht Uhren. Eine unbenutzte gespeicherte Uhr löschen, um eine weitere hinzuzufügen."), "pearl-secondary").as(gtk.Widget));
            }
            for (document.bar.clocks) |definition| {
                const ref = try clock_policy.token(alloc, definition.id);
                if (layout.find(ref) != null or std.mem.eql(u8, ref, "clock")) continue;
                try self.choice(list, ref, try clock_policy.displayName(alloc, definition), try alloc.dupeZ(u8, definition.timezone), model.metadata(.clock).icon, layout, document.bar.edge, true);
            }
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
        } else if (std.mem.startsWith(u8, id, "edit-clock:")) {
            const ref = id[11..];
            const clock_id = clock_policy.reference(ref) orelse return error.InvalidClockId;
            try self.clockControls(box, clock_policy.find(document.bar.clocks, clock_id).?, null);
        } else if (std.mem.startsWith(u8, id, "new-clock:")) {
            const destination = std.meta.stringToEnum(Group, id[10..]) orelse return error.InvalidGroups;
            var n: usize = 1;
            while (clock_policy.find(document.bar.clocks, try std.fmt.allocPrint(alloc, "clock{d}", .{n})) != null) : (n += 1) {}
            try self.clockControls(box, .{ .id = try std.fmt.allocPrint(alloc, "clock{d}", .{n}) }, destination);
        } else if (std.mem.eql(u8, id, "launcher-icon")) {
            box.append(w.label("Launcher icon", "settings-row-title").as(gtk.Widget));
            try self.iconControls(box, document.bar.launcher_icon);
        } else {
            const pos = layout.find(id) orelse return error.WidgetNotFound;
            const title = try name(alloc, id, plugins, document.bar);
            box.append(w.label(title, "settings-row-title").as(gtk.Widget));
            box.append(w.label(try std.fmt.allocPrintSentinel(alloc, "{s} · Position {d} of {d}", .{ model.groupLabel(pos.group, document.bar.edge), pos.index + 1, layout.items[@intFromEnum(pos.group)].items.len }, 0), "pearl-secondary").as(gtk.Widget));
            if (clock_policy.reference(id) != null) _ = try self.button(box, tr("Configure clock…", "Uhr konfigurieren…"), "bar.clock.open", id, .clock_open, true);
            if (std.mem.eql(u8, id, "launcher")) _ = try self.button(box, "Change icon…", "bar.icon.expand", "", .icon_open, true);
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
            const remove = try self.button(box, "Remove from bar", "bar.action.remove", id, .{ .change = .remove }, true);
            remove.as(gtk.Widget).setSensitive(@intFromBool(!std.mem.eql(u8, id, "launcher")));
            if (std.mem.eql(u8, id, "launcher")) box.append(w.label("Launcher is required. It can be moved to any group.", "pearl-secondary").as(gtk.Widget));
        }
        box.append(self.popup_error.?.as(gtk.Widget));
        if (std.mem.eql(u8, id, "launcher-icon")) try self.menu_controls.append(a, .{ .id = "bar.icon.error", .widget = self.popup_error.?.as(gtk.Widget) });
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
            error.TooManyClocks => tr("Eight clocks are supported. Delete an unused saved clock first.", "Bis zu acht Uhren. Zuerst eine unbenutzte gespeicherte Uhr löschen."),
            error.InvalidClockZone, error.ClockUnavailable => tr("Choose an installed time zone, such as Europe/London, UTC or local.", "Eine installierte Zeitzone wählen, z. B. Europe/London, UTC oder local."),
            error.InvalidClockLabel => tr("Use a label up to 64 UTF-8 bytes without control characters.", "Eine Beschriftung mit bis zu 64 UTF-8-Bytes ohne Steuerzeichen verwenden."),
            error.InvalidLauncherIcon => "Enter an icon name using letters, digits, dots, underscores or hyphens (up to 128 characters).",
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
        const title = try name(alloc, id, self.catalog(alloc), document.bar);
        const announcement = if (next_layout.find(id)) |pos| try std.fmt.allocPrintSentinel(alloc, "{s}, {s}, position {d} of {d}. Unsaved changes.", .{ title, model.groupLabel(pos.group, document.bar.edge), pos.index + 1, next_layout.items[@intFromEnum(pos.group)].items.len }, 0) else try std.fmt.allocPrintSentinel(alloc, "{s} removed from bar. Unsaved changes.", .{title}, 0);
        self.editing = true;
        defer self.editing = false;
        try self.editor.edit(next);
        self.host.as(gtk.Accessible).announce(announcement, .medium);
        self.rememberFocus(focus);
        if (self.popup) |popup| popup.popdown();
        self.queue();
    }
    /// Drag and drop reuses the menu mutation path; anchor its stale-bar guard
    /// to the document at drag start instead of an unopened menu.
    fn syncBarHash(self: *View) void {
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const alloc = temp.allocator();
        const document = prefs.parse(alloc, self.editor.text()) catch return;
        self.popup_hash = barHash(alloc, document.bar) catch return;
    }
    fn dragPrepare(_: *gtk.DragSource, _: f64, _: f64, binding: *DragBinding) callconv(.c) ?*gdk.ContentProvider {
        binding.view.syncBarHash();
        // g_value_init requires zero-filled memory; stack garbage faults inside gobject.
        var value: object.Value = std.mem.zeroes(object.Value);
        _ = object.Value.init(&value, g_type_string);
        value.setString(binding.id);
        return gdk.ContentProvider.newForValue(&value);
    }
    fn dragBegin(_: *gtk.DragSource, _: *gdk.Drag, binding: *DragBinding) callconv(.c) void {
        binding.widget.addCssClass("pearl-dragging");
    }
    fn dragEnd(_: *gtk.DragSource, _: *gdk.Drag, _: c_int, binding: *DragBinding) callconv(.c) void {
        binding.widget.removeCssClass("pearl-dragging");
    }
    fn dragCancel(_: *gtk.DragSource, _: *gdk.Drag, _: gdk.DragCancelReason, binding: *DragBinding) callconv(.c) c_int {
        binding.widget.removeCssClass("pearl-dragging");
        return 0;
    }
    fn clearDropClasses(widget: *gtk.Widget) void {
        widget.removeCssClass("pearl-drop-above");
        widget.removeCssClass("pearl-drop-below");
        widget.removeCssClass("pearl-drop-target");
    }
    fn rowMotion(_: *gtk.DropTarget, _: f64, y: f64, binding: *RowDrop) callconv(.c) gdk.DragAction {
        const half = @as(f64, @floatFromInt(binding.widget.getHeight())) / 2;
        if (y < half) {
            binding.widget.addCssClass("pearl-drop-above");
            binding.widget.removeCssClass("pearl-drop-below");
        } else {
            binding.widget.addCssClass("pearl-drop-below");
            binding.widget.removeCssClass("pearl-drop-above");
        }
        return .{ .move = true };
    }
    fn rowLeave(_: *gtk.DropTarget, binding: *RowDrop) callconv(.c) void {
        clearDropClasses(binding.widget);
    }
    fn rowDropped(_: *gtk.DropTarget, value: *object.Value, _: f64, y: f64, binding: *RowDrop) callconv(.c) c_int {
        clearDropClasses(binding.widget);
        const raw = value.getString() orelse return 0;
        const half = @as(f64, @floatFromInt(binding.widget.getHeight())) / 2;
        const index = binding.index + if (y >= half) @as(usize, 1) else 0;
        binding.view.mutate(std.mem.span(raw), .{ .place = .{ .group = binding.group, .index = index } }) catch |err| {
            binding.view.report(err);
            return 0;
        };
        return 1;
    }
    fn cardMotion(_: *gtk.DropTarget, _: f64, _: f64, binding: *CardDrop) callconv(.c) gdk.DragAction {
        binding.widget.addCssClass("pearl-drop-target");
        return .{ .move = true };
    }
    fn cardLeave(_: *gtk.DropTarget, binding: *CardDrop) callconv(.c) void {
        binding.widget.removeCssClass("pearl-drop-target");
    }
    fn cardDropped(_: *gtk.DropTarget, value: *object.Value, _: f64, _: f64, binding: *CardDrop) callconv(.c) c_int {
        binding.widget.removeCssClass("pearl-drop-target");
        const raw = value.getString() orelse return 0;
        binding.view.mutate(std.mem.span(raw), .{ .place = .{ .group = binding.group, .index = std.math.maxInt(usize) } }) catch |err| {
            binding.view.report(err);
            return 0;
        };
        return 1;
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
    fn openClock(self: *View, ref: ?[]const u8) !void {
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const alloc = temp.allocator();
        const document = try prefs.parse(alloc, self.editor.text());
        if (!std.mem.eql(u8, &self.popup_hash, &try barHash(alloc, document.bar))) return error.StaleBar;
        const mode = if (ref) |id| try std.fmt.allocPrint(alloc, "edit-clock:{s}", .{id}) else try std.fmt.allocPrint(alloc, "new-clock:{s}", .{@tagName(@as(Group, @enumFromInt(self.destination.?.getSelected())))});
        const focus = if (ref) |id| try std.fmt.allocPrint(alloc, "bar.widget.{s}", .{id}) else try std.fmt.allocPrint(alloc, "bar.add.{s}", .{@tagName(@as(Group, @enumFromInt(self.destination.?.getSelected())))});
        const anchor = self.popup.?.as(gtk.Widget).getParent().?;
        self.clearPopup();
        self.rememberFocus(focus);
        try self.showMenu(anchor, mode, null);
    }
    fn clockEntry(self: *View, box: *gtk.Box, title: [:0]const u8, id: []const u8, value: []const u8, limit: c_int) !*gtk.Entry {
        const alloc = self.menu_arena.allocator();
        box.append(w.label(title, null).as(gtk.Widget));
        const entry = gtk.Entry.new();
        entry.setMaxLength(limit);
        entry.as(gtk.Editable).setWidthChars(22);
        entry.as(gtk.Editable).setText(try alloc.dupeZ(u8, value));
        w.name(entry.as(gtk.Widget), title);
        box.append(entry.as(gtk.Widget));
        try self.menu_controls.append(a, .{ .id = id, .widget = entry.as(gtk.Widget) });
        _ = gtk.Editable.signals.changed.connect(entry.as(gtk.Editable), *View, clockEdited, self, .{});
        return entry;
    }
    fn clockControls(self: *View, box: *gtk.Box, d: clock_policy.Definition, destination: ?Group) !void {
        const alloc = self.menu_arena.allocator();
        self.clock_id = d.id;
        self.clock_group = destination;
        box.append(w.label(if (destination != null) tr("Add clock", "Uhr hinzufügen") else tr("Configure clock", "Uhr konfigurieren"), "settings-row-title").as(gtk.Widget));
        self.clock_zone = try self.clockEntry(box, tr("Time zone", "Zeitzone"), "bar.clock.zone", d.timezone, 128);
        self.clock_zones = try clock_time.catalog(alloc);
        const names = try alloc.allocSentinel(?[*:0]const u8, self.clock_zones.len + 1, null);
        names[0] = tr("Browse time zones…", "Zeitzonen durchsuchen…");
        for (self.clock_zones, names[1..], 0..) |zone, *name_, i| {
            name_.* = if (i == 0) tr("System local time", "Lokale Systemzeit") else (try std.fmt.allocPrintSentinel(alloc, "{s} · {s}", .{ try clock_policy.displayName(alloc, .{ .id = "preview", .timezone = zone }), zone }, 0)).ptr;
        }
        const chooser = gtk.DropDown.newFromStrings(@ptrCast(names.ptr));
        chooser.setEnableSearch(1);
        self.clock_chooser = chooser;
        chooser.setSelected(0);
        for (self.clock_zones, 0..) |zone, i| if (std.mem.eql(u8, zone, d.timezone)) {
            chooser.setSelected(@intCast(i + 1));
            break;
        };
        w.name(chooser.as(gtk.Widget), tr("Browse time zones", "Zeitzonen durchsuchen"));
        box.append(chooser.as(gtk.Widget));
        try self.menu_controls.append(a, .{ .id = "bar.clock.browse", .widget = chooser.as(gtk.Widget) });
        _ = object.Object.signals.notify.connect(chooser.as(object.Object), *View, clockZoneSelected, self, .{ .detail = "selected" });
        self.clock_label = try self.clockEntry(box, tr("Label (optional)", "Beschriftung (optional)"), "bar.clock.label", d.label, 64);
        const formats = [_:null]?[*:0]const u8{ tr("24-hour time", "24-Stunden-Zeit"), tr("12-hour time", "12-Stunden-Zeit") };
        const format = gtk.DropDown.newFromStrings(@ptrCast(&formats));
        self.clock_format = format;
        format.setSelected(if (d.hour_format == .@"24h") 0 else 1);
        w.name(format.as(gtk.Widget), tr("Time format", "Zeitformat"));
        box.append(format.as(gtk.Widget));
        try self.menu_controls.append(a, .{ .id = "bar.clock.format", .widget = format.as(gtk.Widget) });
        _ = object.Object.signals.notify.connect(format.as(object.Object), *View, clockFormatChanged, self, .{ .detail = "selected" });
        const date = gtk.CheckButton.newWithLabel(tr("Show date", "Datum anzeigen"));
        self.clock_date = date;
        date.setActive(@intFromBool(d.show_date));
        box.append(date.as(gtk.Widget));
        try self.menu_controls.append(a, .{ .id = "bar.clock.date", .widget = date.as(gtk.Widget) });
        _ = gtk.CheckButton.signals.toggled.connect(date, *View, clockDateChanged, self, .{});
        self.clock_preview = w.label("", "pearl-secondary");
        self.clock_preview.?.setMaxWidthChars(30);
        box.append(self.clock_preview.?.as(gtk.Widget));
        try self.menu_controls.append(a, .{ .id = "bar.clock.preview", .widget = self.clock_preview.?.as(gtk.Widget) });
        self.updateClockPreview();
        _ = try self.button(box, tr("Save to draft", "Im Entwurf speichern"), "bar.clock.save", "", .clock_save, true);
        _ = try self.button(box, tr("Cancel", "Abbrechen"), "bar.clock.cancel", "", .clock_cancel, true);
    }
    fn clockDefinition(self: *View) clock_policy.Definition {
        return .{ .id = self.clock_id, .timezone = std.mem.trim(u8, std.mem.span(self.clock_zone.?.as(gtk.Editable).getText()), " "), .label = std.mem.span(self.clock_label.?.as(gtk.Editable).getText()), .hour_format = if (self.clock_format.?.getSelected() == 0) .@"24h" else .@"12h", .show_date = self.clock_date.?.getActive() != 0 };
    }
    fn updateClockPreview(self: *View) void {
        const label = self.clock_preview orelse return;
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const alloc = temp.allocator();
        const d = self.clockDefinition();
        const zone = clock_time.resolve(d.timezone) orelse {
            label.setText(tr("Choose an available time zone.", "Eine verfügbare Zeitzone wählen."));
            return;
        };
        defer zone.unref();
        const utc = glib.DateTime.newNowUtc() orelse return;
        defer utc.unref();
        const text = clock_time.format(alloc, d, utc, zone, false) catch return;
        if (self.popup_error) |message| message.setText("");
        label.setText(std.fmt.allocPrintSentinel(alloc, "{s} · {s}\n{s}{s}{s}", .{ tr("Example", "Beispiel"), clock_policy.displayName(alloc, d) catch return, if (d.show_date) text.date else "", if (d.show_date) " · " else "", text.time }, 0) catch return);
    }
    fn clockEdited(_: *gtk.Editable, self: *View) callconv(.c) void {
        if (self.clock_chooser) |chooser| {
            const zone = std.mem.span(self.clock_zone.?.as(gtk.Editable).getText());
            var selected: c_uint = 0;
            for (self.clock_zones, 0..) |candidate, i| if (std.mem.eql(u8, zone, candidate)) {
                selected = @intCast(i + 1);
                break;
            };
            chooser.setSelected(selected);
        }
        self.updateClockPreview();
    }
    fn clockDateChanged(_: *gtk.CheckButton, self: *View) callconv(.c) void {
        self.updateClockPreview();
    }
    fn clockFormatChanged(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        self.updateClockPreview();
    }
    fn clockZoneSelected(obj: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        const index = object.ext.cast(gtk.DropDown, obj).?.getSelected();
        if (index > 0 and index <= self.clock_zones.len) {
            const entry = self.clock_zone.?.as(gtk.Editable);
            if (!std.mem.eql(u8, std.mem.span(entry.getText()), self.clock_zones[index - 1])) entry.setText(self.clock_zones[index - 1]);
        }
    }
    fn saveClock(self: *View) !void {
        if (!self.editor.editable() or self.editor.target.page != .bar) return error.Unavailable;
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const alloc = temp.allocator();
        const document = try prefs.parse(alloc, self.editor.text());
        if (!std.mem.eql(u8, &self.popup_hash, &try barHash(alloc, document.bar))) return error.StaleBar;
        const d = self.clockDefinition();
        try clock_policy.validateDefinition(d);
        if (!clock_time.available(d.timezone)) return error.ClockUnavailable;
        const next = try model.patchClock(alloc, self.editor.text(), d, self.clock_group);
        self.editing = true;
        defer self.editing = false;
        try self.editor.edit(next);
        self.host.as(gtk.Accessible).announce(tr("Clock saved to draft. Apply & save to update the bar.", "Uhr im Entwurf gespeichert. Anwenden und speichern aktualisiert die Leiste."), .medium);
        self.rememberFocus(try std.fmt.allocPrint(alloc, "bar.widget.{s}", .{try clock_policy.token(alloc, d.id)}));
        self.popup.?.popdown();
        self.queue();
    }
    fn deleteClock(self: *View, id: []const u8) !void {
        if (!self.editor.editable() or self.editor.target.page != .bar) return error.Unavailable;
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const next = try model.deleteClock(temp.allocator(), self.editor.text(), id);
        self.editing = true;
        defer self.editing = false;
        try self.editor.edit(next);
        self.host.as(gtk.Accessible).announce(tr("Saved clock deleted. Unsaved changes.", "Gespeicherte Uhr gelöscht. Ungespeicherte Änderungen."), .medium);
        self.rememberFocus("bar.add.center");
        self.queue();
    }
    fn iconControls(self: *View, box: *gtk.Box, config: Icon.Config) !void {
        const alloc = self.menu_arena.allocator();
        const controls = box;
        const source = w.label(try std.fmt.allocPrintSentinel(alloc, "Selected: {s}", .{if (config.kind == .default) "Default" else config.value}, 0), "pearl-secondary");
        source.setMaxWidthChars(30);
        controls.append(source.as(gtk.Widget));
        const presets = w.row(4);
        controls.append(presets.as(gtk.Widget));
        for ([_][:0]const u8{ "pearl-application-x-executable-symbolic", "pearl-view-grid-symbolic", "pearl-emblem-system-symbolic" }, [_][:0]const u8{ "Applications", "Grid", "System" }, 0..) |symbol, title, i| {
            const b = try self.button(presets, title, try std.fmt.allocPrint(alloc, "bar.icon.preset.{d}", .{i}), symbol, .icon_preset, true);
            b.setChild(w.icon(symbol).as(gtk.Widget));
            w.name(b.as(gtk.Widget), title);
            b.as(gtk.Widget).setTooltipText(title);
        }
        controls.append(w.label("Icon theme name", null).as(gtk.Widget));
        const entry = gtk.Entry.new();
        self.icon_entry = entry;
        entry.setMaxLength(128);
        entry.as(gtk.Editable).setWidthChars(20);
        if (config.kind == .theme) entry.as(gtk.Editable).setText(try alloc.dupeZ(u8, config.value));
        w.name(entry.as(gtk.Widget), "Icon theme name");
        controls.append(entry.as(gtk.Widget));
        try self.menu_controls.append(a, .{ .id = "bar.icon.name", .widget = entry.as(gtk.Widget) });
        _ = try self.button(controls, "Use icon name", "bar.icon.use", "", .icon_theme, true);
        _ = try self.button(controls, "Choose PNG…", "bar.icon.file", "", .icon_file, true);
        const note = w.label("Keep the PNG at its selected location. Display overrides remain in Advanced.", "pearl-secondary");
        note.setMaxWidthChars(30);
        controls.append(note.as(gtk.Widget));
        _ = try self.button(controls, "Retry", "bar.icon.retry", "", .icon_retry, true);
        _ = try self.button(controls, "Reset to default", "bar.icon.reset", "", .icon_reset, true);
    }
    fn mutateIcon(self: *View, config: Icon.Config) !void {
        if (!self.editor.editable() or self.editor.target.page != .bar or self.popup == null) return error.Unavailable;
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const alloc = temp.allocator();
        const document = try prefs.parse(alloc, self.editor.text());
        if (!std.mem.eql(u8, &self.popup_hash, &try barHash(alloc, document.bar))) return error.StaleBar;
        const next = try model.patchLauncherIcon(alloc, self.editor.text(), config);
        self.editing = true;
        defer self.editing = false;
        try self.editor.edit(next);
        self.host.as(gtk.Accessible).announce("Launcher icon changed. Apply & save to update the bar.", .medium);
        self.rememberFocus("bar.widget.launcher");
        self.popup.?.popdown();
        self.queue();
    }
    fn retryIcon(self: *View) !void {
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const doc = try prefs.parse(temp.allocator(), self.editor.text());
        if (!std.mem.eql(u8, &self.popup_hash, &try barHash(temp.allocator(), doc.bar))) return error.StaleBar;
        try self.icon.want(doc.bar.launcher_icon, true);
        if (self.editor.client.capabilities.launcher_icon) {
            const params = try std.json.parseFromSliceLeaky(std.json.Value, temp.allocator(), try std.json.Stringify.valueAlloc(temp.allocator(), .{ .selection = doc.bar.launcher_icon }, .{}), .{});
            try self.editor.liveAction(.@"launcher-icon.retry", params);
        }
        self.popup.?.popdown();
        self.rememberFocus("bar.widget.launcher");
        self.queue();
    }
    fn closePicker(self: *View) void {
        if (self.picker) |picker| {
            self.picker = null;
            picker.as(gtk.Window).destroy();
            picker.unref();
        }
    }
    fn chooseIcon(self: *View) !void {
        if (!self.editor.editable() or self.picker != null) return;
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const doc = try prefs.parse(temp.allocator(), self.editor.text());
        if (!std.mem.eql(u8, &self.popup_hash, &try barHash(temp.allocator(), doc.bar))) return error.StaleBar;
        self.picker_hash = protocol.digest(self.editor.text());
        const picker = object.ext.newInstance(gtk.FileChooserDialog, .{ .title = "Choose launcher PNG", .action = gtk.FileChooserAction.open, .use_header_bar = @as(c_int, 1) });
        self.picker = picker;
        _ = picker.ref();
        const window = picker.as(gtk.Window);
        if (self.host.as(gtk.Widget).getRoot()) |root| window.setTransientFor(object.ext.cast(gtk.Window, root));
        window.setModal(1);
        window.setDefaultSize(680, 520);
        const dialog = picker.as(gtk.Dialog);
        _ = dialog.addButton("_Cancel", @intFromEnum(gtk.ResponseType.cancel));
        _ = dialog.addButton("_Select", @intFromEnum(gtk.ResponseType.accept));
        dialog.setDefaultResponse(@intFromEnum(gtk.ResponseType.accept));
        const filter = gtk.FileFilter.new();
        filter.setName("Static PNG images (up to 2 MiB, 2048 × 2048)");
        filter.addMimeType("image/png");
        picker.as(gtk.FileChooser).addFilter(filter);
        _ = gtk.Dialog.signals.response.connect(dialog, *View, iconChosen, self, .{});
        self.popup.?.popdown();
        window.present();
    }
    fn iconChosen(dialog: *gtk.Dialog, response: c_int, self: *View) callconv(.c) void {
        defer {
            self.closePicker();
            if (self.host.as(gtk.Widget).getRoot()) |root| if (object.ext.cast(gtk.Window, root)) |window| window.present();
            self.rememberFocus("bar.widget.launcher");
            self.queue();
        }
        if (response != @intFromEnum(gtk.ResponseType.accept) or !self.editor.editable()) return;
        if (!std.mem.eql(u8, &self.picker_hash, &protocol.digest(self.editor.text()))) {
            self.report(error.StaleBar);
            return;
        }
        const file = object.ext.cast(gtk.FileChooser, dialog).?.getFile() orelse return;
        defer file.unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        self.candidate.context = self;
        self.candidate.changed = candidateLoaded;
        self.candidate.want(.{ .kind = .file, .value = std.mem.span(path) }, true) catch |err| {
            self.report(err);
            return;
        };
        if (self.popup_error) |label| label.setText("Checking PNG…");
    }
    fn candidateLoaded(context: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, &self.picker_hash, &protocol.digest(self.editor.text()))) {
            self.report(error.StaleBar);
            return;
        }
        if (self.candidate.failed) {
            if (self.focus_id) |id| a.free(id);
            self.focus_id = null;
            self.popup_closed = false;
            if (self.popup) |popup| popup.popup();
            if (self.popup_error) |label| label.setText("Could not load PNG. Choose a regular local static PNG up to 2 MiB and 2048 × 2048 pixels.");
            return;
        }
        self.mutateIcon(self.candidate.selection) catch |err| self.report(err);
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
            .clock_new => self.openClock(null) catch |err| self.report(err),
            .clock_open => self.openClock(binding.id) catch |err| self.report(err),
            .clock_save => self.saveClock() catch |err| self.report(err),
            .clock_cancel => {
                self.popup.?.popdown();
                self.queue();
            },
            .clock_delete => self.deleteClock(binding.id) catch |err| self.report(err),
            .icon_open => {
                const anchor = self.popup.?.as(gtk.Widget).getParent().?;
                self.clearPopup();
                self.showMenu(anchor, "launcher-icon", null) catch |err| self.report(err);
            },
            .icon_reset => self.mutateIcon(.{}) catch |err| self.report(err),
            .icon_preset => self.mutateIcon(.{ .kind = .theme, .value = binding.id }) catch |err| self.report(err),
            .icon_theme => self.mutateIcon(.{ .kind = .theme, .value = std.mem.span(self.icon_entry.?.as(gtk.Editable).getText()) }) catch |err| self.report(err),
            .icon_file => self.chooseIcon() catch |err| self.report(err),
            .icon_retry => self.retryIcon() catch |err| self.report(err),
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
