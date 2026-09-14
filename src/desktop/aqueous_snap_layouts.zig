//! Named snap layouts are edited as the helper's ordered replacement collection.
const std = @import("std");
const gtk = @import("gtk4");
const object = @import("gobject2");
const m = @import("../config/aqueous_model.zig");
const w = @import("../ui/components/widgets.zig");
const View = @import("aqueous_settings.zig").View;
const Form = struct {
    view: *View,
    layouts: m.Value,
    default: []const u8,
    layout: *gtk.DropDown,
    zone: *gtk.DropDown,
    id: *gtk.Entry,
    name: *gtk.Entry,
    padding: *gtk.SpinButton,
    zone_id: *gtk.Entry,
    zone_name: *gtk.Entry,
    geometry: [4]*gtk.SpinButton,
    fn current(self: *Form) m.Value {
        const i = self.layout.getSelected();
        return if (i > 0 and i <= m.list(self.layouts).len) m.list(self.layouts)[i - 1] else .null;
    }
    fn load(self: *Form) !void {
        const v = self.current();
        self.id.as(gtk.Editable).setText(self.view.z(m.str(m.get(v, "id"))));
        self.name.as(gtk.Editable).setText(self.view.z(m.str(m.get(v, "name"))));
        self.padding.setValue(number(m.get(v, "padding"), 0));
        const zones = m.list(m.get(v, "zones"));
        const a = self.view.arena.allocator();
        const names = try a.allocSentinel(?[*:0]const u8, zones.len + 1, null);
        names[0] = "New zone";
        for (zones, 0..) |z, i| names[i + 1] = self.view.z(m.str(m.get(z, "id")));
        const strings = gtk.StringList.new(@ptrCast(names.ptr));
        defer strings.unref();
        self.zone.setModel(strings.as(@import("gio2").ListModel));
        self.zone.setSelected(0);
        self.loadZone();
    }
    fn loadZone(self: *Form) void {
        const zones = m.list(m.get(self.current(), "zones"));
        const i = self.zone.getSelected();
        const v = if (i > 0 and i <= zones.len) zones[i - 1] else m.Value.null;
        self.zone_id.as(gtk.Editable).setText(self.view.z(m.str(m.get(v, "id"))));
        self.zone_name.as(gtk.Editable).setText(self.view.z(m.str(m.get(v, "name"))));
        for (self.geometry, [_][]const u8{ "x", "y", "width", "height" }, 0..) |input, key, index| input.setValue(number(m.get(v, key), if (index < 2) 0 else 1));
    }
    fn stage(self: *Form, action: usize) !void {
        const view = self.view;
        if (view.client.job != null or view.client.conflict()) return error.StaleDraft;
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var request = try m.request(a, view.client.baseValue(), view.client.draft orelse try view.client.emptyDraft(a), "unused");
        _ = request.object.swapRemove("backup_dir");
        if (m.get(m.get(request, "raw_files"), "layout") != .null) return error.ConflictingEdits;
        var layouts = try m.parse(a, try std.json.Stringify.valueAlloc(a, self.layouts, .{}), m.max_request);
        if (layouts == .null) layouts = .{ .array = .init(a) };
        const selected_index = self.layout.getSelected();
        if (action != 0 and selected_index == 0) return error.SelectExistingLayout;
        var default = self.default;
        if (action == 0) {
            const id = std.mem.span(self.id.as(gtk.Editable).getText());
            try validId(id);
            for (layouts.array.items, 0..) |existing, i| if (i + 1 != selected_index and std.mem.eql(u8, id, m.str(m.get(existing, "id")))) return error.DuplicateLayoutId;
            var layout = try m.parse(a, try std.json.Stringify.valueAlloc(a, .{ .id = id, .name = std.mem.span(self.name.as(gtk.Editable).getText()), .padding = self.padding.getValueAsInt(), .zones = if (selected_index > 0) m.get(layouts.array.items[selected_index - 1], "zones") else m.Value{ .array = .init(a) } }, .{}), m.max_request);
            if (selected_index > 0) {
                if (std.mem.eql(u8, default, m.str(m.get(layouts.array.items[selected_index - 1], "id")))) default = id;
                layouts.array.items[selected_index - 1] = layout;
            } else {
                if (layouts.array.items.len >= 8) return error.TooManyLayouts;
                try layouts.array.append(layout);
                if (layouts.array.items.len == 1) default = id;
            }
            _ = &layout;
        } else if (action == 1) {
            const old = layouts.array.orderedRemove(selected_index - 1);
            if (std.mem.eql(u8, default, m.str(m.get(old, "id")))) default = if (layouts.array.items.len > 0) m.str(m.get(layouts.array.items[0], "id")) else "";
        } else if (action == 2) default = m.str(m.get(layouts.array.items[selected_index - 1], "id")) else {
            var layout = &layouts.array.items[selected_index - 1];
            var zones = m.get(layout.*, "zones");
            const zone_index = self.zone.getSelected();
            if (action == 3) {
                const id = std.mem.span(self.zone_id.as(gtk.Editable).getText());
                try validId(id);
                for (zones.array.items, 0..) |z, i| if (i + 1 != zone_index and std.mem.eql(u8, id, m.str(m.get(z, "id")))) return error.DuplicateZoneId;
                const x = self.geometry[0].getValue();
                const y = self.geometry[1].getValue();
                const width = self.geometry[2].getValue();
                const height = self.geometry[3].getValue();
                try @import("../config/aqueous_collections.zig").geometry(x, y, width, height);
                const zone = try m.parse(a, try std.json.Stringify.valueAlloc(a, .{ .id = id, .name = std.mem.span(self.zone_name.as(gtk.Editable).getText()), .x = x, .y = y, .width = width, .height = height }, .{}), 4096);
                if (zone_index > 0) zones.array.items[zone_index - 1] = zone else {
                    if (zones.array.items.len >= 16) return error.TooManyZones;
                    try zones.array.append(zone);
                }
            } else {
                if (zone_index == 0) return error.SelectExistingZone;
                if (action == 4) _ = zones.array.orderedRemove(zone_index - 1) else {
                    const from: usize = zone_index - 1;
                    const to = if (action == 5) (if (from == 0) return error.AlreadyFirst else from - 1) else (if (from + 1 >= zones.array.items.len) return error.AlreadyLast else from + 1);
                    std.mem.swap(m.Value, &zones.array.items[from], &zones.array.items[to]);
                }
            }
            try layout.object.put(a, "zones", zones);
        }
        try request.object.put(a, "snap_layouts", layouts);
        try request.object.put(a, "default_snap_layout", .{ .string = default });
        try request.object.put(a, "collection_preconditions", m.get(view.client.baseValue(), "collection_preconditions"));
        try view.client.keepDraft(try std.json.Stringify.valueAlloc(a, request, .{ .whitespace = .indent_2 }));
        // Rebuild from the shared draft, so further operations see staged IDs and order.
        view.update();
    }
};
fn validId(id: []const u8) !void {
    if (id.len == 0 or id.len > 32) return error.InvalidSnapId;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.InvalidSnapId;
}
fn number(v: m.Value, fallback: f64) f64 {
    return switch (v) {
        .integer => @floatFromInt(v.integer),
        .float => v.float,
        else => fallback,
    };
}
fn entry(view: *View, box: *gtk.Box, label: [*:0]const u8, max: c_int) *gtk.Entry {
    _ = view;
    const input = gtk.Entry.new();
    input.setMaxLength(max);
    w.name(input.as(gtk.Widget), label);
    box.append(w.label(label, null).as(gtk.Widget));
    box.append(input.as(gtk.Widget));
    return input;
}
const Action = struct { form: *Form, index: usize };
fn clicked(_: *gtk.Button, action: *Action) callconv(.c) void {
    action.form.stage(action.index) catch |err| action.form.view.fail(err);
}
fn selected(_: *object.Object, _: *object.ParamSpec, form: *Form) callconv(.c) void {
    form.load() catch |err| form.view.fail(err);
}
fn zoneSelected(_: *object.Object, _: *object.ParamSpec, form: *Form) callconv(.c) void {
    form.loadZone();
}
pub fn render(view: *View, box: *gtk.Box, snapshot: m.Value) !void {
    if (!@import("../config/aqueous_contract.zig").Capabilities.read(snapshot).collections) return;
    const a = view.arena.allocator();
    const draft = try m.parse(a, view.client.draft orelse "{}", m.max_request);
    const layouts = if (m.get(draft, "snap_layouts") != .null) m.get(draft, "snap_layouts") else m.get(snapshot, "snap_layouts");
    if (layouts != .array or layouts.array.items.len > 8) return error.InvalidSnapLayouts;
    const default = m.str(if (m.get(draft, "default_snap_layout") != .null) m.get(draft, "default_snap_layout") else m.get(snapshot, "default_snap_layout"));
    const card = w.card();
    box.append(card.as(gtk.Widget));
    card.append(w.label("Named snap layouts", "pearl-title").as(gtk.Widget));
    card.append(w.label(view.z(try std.fmt.allocPrint(a, "Default: {s}. Stage a layout, then select it to edit its zones. Changes share the Advanced draft.", .{default})), "pearl-secondary").as(gtk.Widget));
    const names = try a.allocSentinel(?[*:0]const u8, layouts.array.items.len + 1, null);
    names[0] = "New layout";
    for (layouts.array.items, 0..) |v, i| names[i + 1] = view.z(m.str(m.get(v, "id")));
    const layout = gtk.DropDown.newFromStrings(@ptrCast(names.ptr));
    card.append(layout.as(gtk.Widget));
    w.name(layout.as(gtk.Widget), "Snap layout");
    const id = entry(view, card, "Layout ID", 32);
    const name = entry(view, card, "Layout name", 128);
    const padding = gtk.SpinButton.newWithRange(0, 512, 1);
    w.name(padding.as(gtk.Widget), "Layout padding");
    card.append(w.label("Padding", null).as(gtk.Widget));
    card.append(padding.as(gtk.Widget));
    const zone = gtk.DropDown.newFromStrings(@ptrCast(&[_:null]?[*:0]const u8{"New zone"}));
    card.append(zone.as(gtk.Widget));
    w.name(zone.as(gtk.Widget), "Snap zone");
    const zone_id = entry(view, card, "Zone ID", 32);
    const zone_name = entry(view, card, "Zone name", 128);
    var geometry: [4]*gtk.SpinButton = undefined;
    for (&geometry, [_][*:0]const u8{ "Zone x", "Zone y", "Zone width", "Zone height" }) |*input, label| {
        input.* = gtk.SpinButton.newWithRange(0, 1, 0.01);
        input.*.setDigits(3);
        w.name(input.*.as(gtk.Widget), label);
        card.append(w.label(label, null).as(gtk.Widget));
        card.append(input.*.as(gtk.Widget));
    }
    const form = try a.create(Form);
    form.* = .{ .view = view, .layouts = layouts, .default = default, .layout = layout, .zone = zone, .id = id, .name = name, .padding = padding, .zone_id = zone_id, .zone_name = zone_name, .geometry = geometry };
    for ([_][*:0]const u8{ "Stage layout", "Delete layout", "Set default layout", "Stage zone", "Delete zone", "Move zone up", "Move zone down" }, 0..) |label, i| {
        const button = gtk.Button.newWithLabel(label);
        card.append(button.as(gtk.Widget));
        const action = try a.create(Action);
        action.* = .{ .form = form, .index = i };
        view.form_signals.add(button.as(object.Object), gtk.Button.signals.clicked.connect(button, *Action, clicked, action, .{}));
    }
    view.form_signals.add(layout.as(object.Object), object.Object.signals.notify.connect(layout.as(object.Object), *Form, selected, form, .{ .detail = "selected" }));
    view.form_signals.add(zone.as(object.Object), object.Object.signals.notify.connect(zone.as(object.Object), *Form, zoneSelected, form, .{ .detail = "selected" }));
    try form.load();
}
