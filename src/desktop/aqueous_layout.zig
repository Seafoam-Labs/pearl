//! Shared native presentation around the existing Aqueous editors.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const object = @import("gobject2");
const cairo = @import("cairo1");
const m = @import("../config/aqueous_model.zig");
pub const map = @import("../config/aqueous_presentation.zig");
const w = @import("../ui/components/widgets.zig");
pub const Action = enum { refresh, validate, rebase, appearance };
pub const Control = struct { id: []const u8, widget: *gtk.Widget };
pub const Section = struct {
    state: *State,
    id: map.Group,
    box: *gtk.Box,
    body: *gtk.Box,
    button: ?*gtk.ToggleButton = null,
    arrow: ?*gtk.Label = null,
    fn changed(button: *gtk.ToggleButton, self: *Section) callconv(.c) void {
        const active = button.getActive() != 0;
        if (!self.state.filtering) self.state.expanded[@backingInt(self.id)] = active;
        self.body.as(gtk.Widget).setVisible(@intFromBool(active));
        self.arrow.?.setText(if (active) @import("i18n").dtr("pearl", "⌄") else @import("i18n").dtr("pearl", "›"));
        button.as(gtk.Accessible).updateState(.expanded, @as(c_int, @intFromBool(active)), @as(c_int, -1));
    }
    pub fn reveal(self: *Section) void {
        if (self.button) |b| b.setActive(1);
    }
};
pub const State = struct {
    expanded: [map.count]bool = @splat(false),
    sections: [map.count]?*Section = @splat(null),
    controls: std.ArrayList(Control) = .empty,
    previews: [2]?*gtk.DrawingArea = .{ null, null },
    preview_revision: ?u64 = null,
    preview_labels: [2]?*gtk.Label = .{ null, null },
    search: [256:0]u8 = @splat(0),
    search_entry: ?*gtk.Entry = null,
    search_result: ?*gtk.Label = null,
    status: ?*gtk.Label = null,
    actions: [3]?*gtk.Button = .{ null, null, null },
    raw_source: c_uint = 0,
    filtering: bool = false,
    pub fn clear(self: *State) void {
        for (self.previews) |p| if (p) |preview| preview.setDrawFunc(null, null, null);
        self.sections = @splat(null);
        self.controls = .empty;
        self.previews = .{ null, null };
        self.preview_revision = null;
        self.preview_labels = .{ null, null };
        self.search_entry = null;
        self.search_result = null;
        self.status = null;
        self.actions = .{ null, null, null };
    }
};
pub fn For(comptime View: type) type {
    return struct {
        const Callback = struct { view: *View, action: Action };
        const Preview = struct { view: *View, layout: bool };
        const Choices = struct {
            dropdown: *gtk.DropDown,
            buttons: []*gtk.CheckButton,
            fn changed(button: *gtk.CheckButton, self: *Choices) callconv(.c) void {
                if (button.getActive() == 0) return;
                for (self.buttons, 0..) |item, i| if (item == button) {
                    self.dropdown.setSelected(@intCast(i));
                    break;
                };
            }
            fn key(_: *gtk.EventControllerKey, code: c_uint, _: c_uint, modifiers: gdk.ModifierType, self: *Choices) callconv(.c) c_int {
                if (modifiers.control_mask or modifiers.alt_mask or modifiers.super_mask) return 0;
                const current: usize = self.dropdown.getSelected();
                const n = self.buttons.len;
                const index = switch (code) {
                    gdk.KEY_Left, gdk.KEY_Up => (current + n - 1) % n,
                    gdk.KEY_Right, gdk.KEY_Down => (current + 1) % n,
                    gdk.KEY_Home => 0,
                    gdk.KEY_End => n - 1,
                    else => return 0,
                };
                self.buttons[index].setActive(1);
                _ = self.buttons[index].as(gtk.Widget).grabFocus();
                return 1;
            }
        };
        pub fn choices(view: *View, row: *gtk.Box, dropdown: *gtk.DropDown, field: m.Value) !*gtk.Widget {
            const options = m.list(m.get(field, "options"));
            const data = try view.arena.allocator().create(Choices);
            data.* = .{ .dropdown = dropdown, .buttons = try view.arena.allocator().alloc(*gtk.CheckButton, options.len) };
            const flow = w.flow(3);
            for (options, 0..) |option, i| {
                const check = gtk.CheckButton.newWithLabel(view.z(@import("i18n").aqueousOption(m.str(m.get(field, "id")), m.str(option))));
                check.as(gtk.Widget).addCssClass("aqueous-mode");
                if (i > 0) check.setGroup(data.buttons[0]);
                data.buttons[i] = check;
                flow.insert(check.as(gtk.Widget), -1);
                try view.layout.controls.append(view.arena.allocator(), .{ .id = try std.fmt.allocPrint(view.arena.allocator(), "aqueous.layout.{s}", .{m.str(option)}), .widget = check.as(gtk.Widget) });
            }
            data.buttons[dropdown.getSelected()].setActive(1);
            for (data.buttons) |check| view.form_signals.add(check.as(object.Object), gtk.CheckButton.signals.toggled.connect(check, *Choices, Choices.changed, data, .{}));
            const keys = gtk.EventControllerKey.new();
            keys.as(gtk.EventController).setPropagationPhase(.capture);
            view.form_signals.add(keys.as(object.Object), gtk.EventControllerKey.signals.key_pressed.connect(keys, *Choices, Choices.key, data, .{}));
            flow.as(gtk.Widget).addController(keys.as(gtk.EventController));
            dropdown.as(gtk.Widget).setVisible(0);
            row.append(dropdown.as(gtk.Widget));
            return flow.as(gtk.Widget);
        }
        fn title(_: *View, id: map.Group) [:0]const u8 {
            const spec = map.spec(id);
            return @import("i18n").tr(spec.en);
        }
        pub fn group(view: *View, host: *gtk.Box, id: map.Group) !*gtk.Box {
            if (view.layout.sections[@backingInt(id)]) |s| return s.body;
            const spec = map.spec(id);
            const s = try view.arena.allocator().create(Section);
            const box = w.column(12);
            box.as(gtk.Widget).addCssClass("settings-card");
            box.as(gtk.Widget).addCssClass("aqueous-card");
            host.append(box.as(gtk.Widget));
            const body = w.column(12);
            s.* = .{ .state = &view.layout, .id = id, .box = box, .body = body };
            view.layout.sections[@backingInt(id)] = s;
            const heading = w.column(4);
            heading.append(w.label(title(view, id), "pearl-section-title").as(gtk.Widget));
            heading.append(w.label(@import("i18n").tr(spec.detail_en), "pearl-secondary").as(gtk.Widget));
            if (spec.collapsed) {
                const toggle = gtk.ToggleButton.new();
                toggle.as(gtk.Widget).addCssClass("aqueous-disclosure");
                const row = w.row(12);
                row.append(heading.as(gtk.Widget));
                const arrow = w.label(@import("i18n").dtr("pearl", "›"), null);
                arrow.as(gtk.Widget).setHexpand(0);
                row.append(arrow.as(gtk.Widget));
                toggle.as(gtk.Button).setChild(row.as(gtk.Widget));
                w.name(toggle.as(gtk.Widget), title(view, id));
                s.button = toggle;
                s.arrow = arrow;
                box.append(toggle.as(gtk.Widget));
                body.as(gtk.Widget).setVisible(0);
                view.form_signals.add(toggle.as(object.Object), gtk.ToggleButton.signals.toggled.connect(toggle, *Section, Section.changed, s, .{}));
                toggle.as(gtk.Accessible).updateState(.expanded, @as(c_int, 0), @as(c_int, -1));
                toggle.setActive(@intFromBool(view.layout.expanded[@backingInt(id)]));
                try view.layout.controls.append(view.arena.allocator(), .{ .id = try std.fmt.allocPrint(view.arena.allocator(), "aqueous.section.{s}", .{@tagName(id)}), .widget = toggle.as(gtk.Widget) });
            } else box.append(heading.as(gtk.Widget));
            box.append(body.as(gtk.Widget));
            return body;
        }
        pub fn render(view: *View, host: *gtk.Box, snapshot: m.Value, draft: m.Value, category: []const u8) !void {
            if (std.mem.eql(u8, category, "keybinds")) {
                const search = gtk.Entry.new();
                search.setMaxLength(255);
                search.setPlaceholderText(@import("i18n").dtr("pearl", "Search actions or shortcuts…"));
                search.as(gtk.Editable).setText(&view.layout.search);
                search.as(gtk.Widget).addCssClass("aqueous-search");
                w.name(search.as(gtk.Widget), @import("i18n").dtr("pearl", "Search shortcuts"));
                view.layout.search_entry = search;
                host.append(search.as(gtk.Widget));
                const result = w.label("", "pearl-secondary");
                view.layout.search_result = result;
                host.append(result.as(gtk.Widget));
                view.form_signals.add(search.as(object.Object), gtk.Editable.signals.changed.connect(search.as(gtk.Editable), *View, searched, view, .{}));
                try view.layout.controls.append(view.arena.allocator(), .{ .id = "aqueous.search", .widget = search.as(gtk.Widget) });
            }
            if (std.mem.eql(u8, category, "rules")) {
                const body = try group(view, host, .rules);
                if (view.rules_view == null) view.rules_view = try @import("../settings/window_rules_view.zig").For(View).create(view);
                try view.rules_view.?.render(body, snapshot);
            }
            var scalar_host = host;
            if (std.mem.eql(u8, category, "displays")) {
                if (@import("../config/aqueous_contract.zig").Capabilities.read(snapshot).display_mutations) {
                    try @import("aqueous_display_setup.zig").For(View).render(view, host, snapshot);
                } else try @import("aqueous_displays.zig").render(view, host, snapshot);
                scalar_host = view.display_advanced_box orelse host;
                const sources = try group(view, scalar_host, .display_sources);
                try view.inventory(sources, snapshot, "monitors", "Configured displays (including offline outputs)");
                try view.inventory(sources, snapshot, "live_outputs", "Connected displays and modes");
                if (!@import("../config/aqueous_contract.zig").Capabilities.read(snapshot).display_mutations) {
                    for (m.list(m.get(snapshot, "monitors"))) |monitor| try view.monitorEditor(sources, monitor, false);
                    for (m.list(m.get(snapshot, "live_outputs"))) |monitor| {
                        var configured = false;
                        for (m.list(m.get(snapshot, "monitors"))) |existing| if (std.mem.eql(u8, m.str(m.get(existing, "name")), m.str(m.get(monitor, "name")))) {
                            configured = true;
                            break;
                        };
                        if (!configured) try view.monitorEditor(sources, monitor, true);
                    }
                }
            }
            for (std.enums.values(map.Group)) |id| {
                if (!std.mem.eql(u8, map.spec(id).page, category)) continue;
                var body: ?*gtk.Box = null;
                for (m.list(m.get(snapshot, "fields"))) |field| {
                    if (!std.mem.eql(u8, m.fieldCategory(field), category) or map.group(field) != id) continue;
                    if (body == null) {
                        body = try group(view, scalar_host, id);
                        if (id == .borders or id == .layout) try preview(view, body.?, id == .layout);
                    }
                    try view.fieldEditor(body.?, field, draft, id);
                }
                if (id == .borders and body != null) {
                    const link = w.wrappingButton(@import("i18n").dtr("pearl", "Automatic border colors: open Pearl Appearance"));
                    body.?.append(link.as(gtk.Widget));
                    const callback = try view.arena.allocator().create(Callback);
                    callback.* = .{ .view = view, .action = .appearance };
                    view.form_signals.add(link.as(object.Object), gtk.Button.signals.clicked.connect(link, *Callback, action, callback, .{}));
                    link.as(gtk.Widget).setSensitive(@intFromBool(view.open_appearance != null));
                    try view.layout.controls.append(view.arena.allocator(), .{ .id = "aqueous.pearl-appearance", .widget = link.as(gtk.Widget) });
                }
            }
            if (std.mem.eql(u8, category, "appearance")) {
                const fonts = try group(view, host, .typography);
                try view.inventory(fonts, view.client.value(), "desktop_typography", "Desktop font synchronization");
                try view.inventory(fonts, view.client.value(), "desktop_cursor", "Desktop cursor synchronization");
            }
            if (std.mem.eql(u8, category, "layouts")) {
                const snap = try group(view, host, .snap);
                try @import("aqueous_snap_layouts.zig").For(View).render(view, snap, snapshot);
                try view.inventory(snap, snapshot, "snap_layouts", "Snap layouts");
                const legacy = try group(view, host, .legacy_zones);
                try @import("aqueous_collections.zig").For(View).render(view, legacy, snapshot, category);
                try view.inventory(legacy, snapshot, "snap_zones", "Snap zones");
            }
            if (std.mem.eql(u8, category, "keybinds")) {
                const custom = try group(view, host, .custom_shortcuts);
                custom.append(w.label(@import("i18n").dtr("pearl", "Recording waits for Aqueous to inhibit shortcuts. Escape cancels."), "pearl-secondary").as(gtk.Widget));
                try @import("aqueous_collections.zig").For(View).render(view, custom, snapshot, category);
                try view.inventory(custom, snapshot, "custom_keybinds", "Custom bindings");
            }
            if (std.mem.eql(u8, category, "rules")) try view.inventory(try group(view, host, .rule_sources), snapshot, "window_rules", "Saved rule inventory");
        }
        pub fn status(view: *View, host: *gtk.Box) !void {
            const body = try group(view, host, .status);
            const text = w.label("", "pearl-secondary");
            text.setSelectable(1);
            body.append(text.as(gtk.Widget));
            view.layout.status = text;
            const actions = w.flow(3);
            actions.setHomogeneous(0);
            body.append(actions.as(gtk.Widget));
            for ([_]Action{ .refresh, .validate, .rebase }, 0..) |kind, i| {
                const button = w.wrappingButton(switch (kind) {
                    .refresh => @import("i18n").dtr("pearl", "Refresh status"),
                    .validate => @import("i18n").dtr("pearl", "Validate draft"),
                    .rebase => @import("i18n").dtr("pearl", "Rebase draft"),
                    else => unreachable,
                });
                actions.insert(button.as(gtk.Widget), -1);
                view.layout.actions[i] = button;
                const callback = try view.arena.allocator().create(Callback);
                callback.* = .{ .view = view, .action = kind };
                view.form_signals.add(button.as(object.Object), gtk.Button.signals.clicked.connect(button, *Callback, action, callback, .{}));
                try view.layout.controls.append(view.arena.allocator(), .{ .id = switch (kind) {
                    .refresh => "aqueous.refresh",
                    .validate => "aqueous.validate",
                    .rebase => "aqueous.rebase",
                    else => unreachable,
                }, .widget = button.as(gtk.Widget) });
            }
        }
        fn action(_: *gtk.Button, callback: *Callback) callconv(.c) void {
            callback.view.perform(callback.action);
        }
        fn searched(input: *gtk.Editable, view: *View) callconv(.c) void {
            const query = std.mem.span(input.getText());
            @memset(&view.layout.search, 0);
            var length = @min(query.len, 255);
            while (length > 0 and !std.unicode.utf8ValidateSlice(query[0..length])) length -= 1;
            @memcpy(view.layout.search[0..length], query[0..length]);
            filter(view);
        }
        pub fn filter(view: *View) void {
            const query = std.mem.sliceTo(&view.layout.search, 0);
            var matches: [map.count]usize = @splat(0);
            var total: usize = 0;
            for (view.editors.items) |editor| {
                if (!std.mem.eql(u8, m.fieldCategory(editor.field), "keybinds")) continue;
                const value = if (object.ext.cast(gtk.Entry, editor.widget)) |entry| std.mem.span(entry.as(gtk.Editable).getText()) else "";
                const visible = map.matches(query, m.str(m.get(editor.field, "id")), m.str(m.get(editor.field, "label")), value);
                if (editor.row) |row| row.as(gtk.Widget).setVisible(@intFromBool(visible));
                if (visible) {
                    matches[@backingInt(editor.group)] += 1;
                    total += 1;
                }
            }
            view.layout.filtering = true;
            defer view.layout.filtering = false;
            for (std.enums.values(map.Group), 0..) |id, i| {
                if (!std.mem.eql(u8, map.spec(id).page, "keybinds") or id == .custom_shortcuts) continue;
                if (view.layout.sections[i]) |s| {
                    s.box.as(gtk.Widget).setVisible(@intFromBool(matches[i] > 0));
                    if (s.button) |button| button.setActive(@intFromBool(if (query.len > 0) matches[i] > 0 else view.layout.expanded[i]));
                }
            }
            if (view.layout.search_result) |label| {
                var buffer: [160]u8 = undefined;
                label.setText(if (total == 0) @import("i18n").dtr("pearl", "No matching shortcuts. Clear the search to see all actions.") else @import("i18n").fmt(&buffer, "{d} matching actions", .{total}));
            }
        }
        fn preview(view: *View, body: *gtk.Box, layout: bool) !void {
            const label = w.label(@import("i18n").dtr("pearl", "Draft illustration · Not applied"), "pearl-secondary");
            body.append(label.as(gtk.Widget));
            const canvas = gtk.DrawingArea.new();
            canvas.setContentHeight(150);
            canvas.as(gtk.Widget).setHexpand(1);
            canvas.as(gtk.Widget).addCssClass("aqueous-preview");
            w.name(canvas.as(gtk.Widget), @import("i18n").dtr("pearl", "Draft illustration"));
            const data = try view.arena.allocator().create(Preview);
            data.* = .{ .view = view, .layout = layout };
            canvas.setDrawFunc(draw, data, null);
            body.append(canvas.as(gtk.Widget));
            view.layout.previews[@intFromBool(layout)] = canvas;
            view.layout.preview_labels[@intFromBool(layout)] = label;
        }
        fn draw(area: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
            const p: *Preview = @ptrCast(@alignCast(data.?));
            const view = p.view;
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            const draft = m.parse(arena.allocator(), view.client.draft orelse "{}", m.max_request) catch .null;
            const base = view.client.baseValue();
            var color: gdk.RGBA = undefined;
            area.as(gtk.Widget).getColor(&color);
            const ww: f64 = @floatFromInt(width);
            const hh: f64 = @floatFromInt(height);
            cr.setSourceRgba(color.f_red, color.f_green, color.f_blue, 0.06);
            cr.paint();
            const mode = m.str(map.draftValue(base, draft, "layout.default"));
            const gap = if (p.layout) std.math.clamp(num(map.draftValue(base, draft, "layout.gaps_inner"), 8), 2, 28) else 14;
            const outer = if (p.layout) std.math.clamp(num(map.draftValue(base, draft, "layout.gaps_outer"), 12), 8, 28) else 18;
            const rows = std.mem.eql(u8, mode, "rows");
            const single = std.mem.eql(u8, mode, "monocle");
            const grid = p.layout and std.mem.eql(u8, mode, "grid");
            const split = p.layout and (std.mem.eql(u8, mode, "tile") or std.mem.endsWith(u8, mode, "dwindle"));
            const stack = p.layout and std.mem.eql(u8, mode, "stacking");
            const n: usize = if (p.layout and single) 1 else if (grid) 4 else if (split or stack) 3 else 2;
            for (0..n) |i| {
                const offset: f64 = @floatFromInt(i);
                var rw = if (p.layout and (rows or single)) ww - outer * 2 else (ww - outer * 2 - gap) / 2;
                var rh = if (p.layout and rows) (hh - outer * 2 - gap) / 2 else hh - outer * 2 - (if (p.layout) @as(f64, 0) else 16);
                var x = outer + (if (rows) @as(f64, 0) else offset * (rw + gap));
                var y = outer + (if (p.layout) (if (rows) offset * (rh + gap) else @as(f64, 0)) else offset * 16);
                if (grid or (split and i > 0)) {
                    rh = (hh - outer * 2 - gap) / 2;
                    x = outer + @as(f64, @floatFromInt(if (grid) i % 2 else 1)) * (rw + gap);
                    y = outer + @as(f64, @floatFromInt(if (grid) i / 2 else i - 1)) * (rh + gap);
                }
                if (split and std.mem.eql(u8, mode, "reverse-dwindle")) x = ww - x - rw;
                if (stack) {
                    rw = ww - outer * 2 - 32;
                    rh = hh - outer * 2 - 24;
                    x = outer + offset * 16;
                    y = outer + offset * 12;
                }
                cr.setSourceRgba(color.f_red, color.f_green, color.f_blue, if (i == 0) 0.18 else 0.10);
                cr.rectangle(x, y, rw, rh);
                cr.fill();
                var border = color;
                if (!p.layout) {
                    const value = map.draftValue(base, draft, if (i == 0) "layout.border_focused" else "layout.border_normal");
                    if (value == .string) {
                        if (value.string.len == 10 and std.mem.startsWith(u8, value.string, "0x")) {
                            if (std.fmt.parseInt(u32, value.string[2..], 16)) |argb| {
                                border = .{ .f_red = @as(f32, @floatFromInt((argb >> 16) & 255)) / 255, .f_green = @as(f32, @floatFromInt((argb >> 8) & 255)) / 255, .f_blue = @as(f32, @floatFromInt(argb & 255)) / 255, .f_alpha = @as(f32, @floatFromInt(argb >> 24)) / 255 };
                            } else |_| {}
                        } else {
                            const text = arena.allocator().dupeSentinel(u8, value.string, 0) catch return;
                            _ = border.parse(text);
                        }
                    }
                }
                cr.setSourceRgba(border.f_red, border.f_green, border.f_blue, border.f_alpha);
                cr.setLineWidth(if (p.layout) 1.5 else std.math.clamp(num(map.draftValue(base, draft, "layout.border_width"), 2), 0, 12));
                cr.rectangle(x + 1, y + 1, rw - 2, rh - 2);
                cr.stroke();
                cr.setSourceRgba(color.f_red, color.f_green, color.f_blue, 0.3);
                for (0..3) |line| {
                    if (18 + @as(f64, @floatFromInt(line)) * 12 + 3 > rh - 6) break;
                    cr.rectangle(x + 12, y + 18 + @as(f64, @floatFromInt(line)) * 12, @max(5, (rw - 24) * (if (line == 1) @as(f64, 0.55) else 0.8)), 3);
                    cr.fill();
                }
            }
        }
        fn num(value: m.Value, fallback: f64) f64 {
            return switch (value) {
                .integer => @floatFromInt(value.integer),
                .float => value.float,
                else => fallback,
            };
        }
        pub fn update(view: *View) void {
            if (view.layout.preview_revision == null or view.layout.preview_revision.? != view.client.revision) {
                view.layout.preview_revision = view.client.revision;
                for (view.layout.previews) |p| if (p) |preview_| preview_.as(gtk.Widget).queueDraw();
            }
            for (view.layout.actions) |b| if (b) |button| button.as(gtk.Widget).setSensitive(@intFromBool(view.client.job == null));
            if (view.layout.actions[2]) |button| button.as(gtk.Widget).setSensitive(@intFromBool(view.client.job == null and view.client.draft != null and !view.client.unresolved));
        }
    };
}
