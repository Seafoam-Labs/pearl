//! Bar/dock and idle policy forms share the existing Pearl draft coordinator.
const std = @import("std");
const gtk = @import("gtk4");
const object = @import("gobject2");
const model = @import("../config/preferences.zig");
const w = @import("../ui/components/widgets.zig");
const Editor = @import("editor.zig").Editor;
const a = std.heap.c_allocator;
const Spec = struct { path: []const u8, label: [:0]const u8, kind: enum { text, number, toggle, choice }, choices: []const [:0]const u8 = &.{}, min: f64 = 0, max: f64 = 86400 };
const edges: []const [:0]const u8 = &.{ "top", "bottom", "left", "right" };
const bar_fields = [_]Spec{
    .{ .path = "bar.edge", .label = "Bar edge", .kind = .choice, .choices = edges },
    .{ .path = "bar.size", .label = "Bar size", .kind = .number, .min = 32, .max = 160 },
    .{ .path = "bar.islands", .label = "Separate bar islands", .kind = .toggle },
    .{ .path = "dock.enabled", .label = "Show dock", .kind = .toggle },
    .{ .path = "dock.edge", .label = "Dock edge", .kind = .choice, .choices = edges },
    .{ .path = "dock.mode", .label = "Dock visibility", .kind = .choice, .choices = &.{ "always", "autohide", "intelligent" } },
    .{ .path = "dock.icon_size", .label = "Dock icon size", .kind = .number, .min = 24, .max = 64 },
    .{ .path = "dock.margin", .label = "Dock margin", .kind = .number, .min = 4, .max = 32 },
    .{ .path = "popup.dismiss_outside", .label = "Dismiss flyouts when clicking outside", .kind = .toggle },
    .{ .path = "popup.placement", .label = "Flyout placement", .kind = .choice, .choices = &.{ "anchored", "centered" } },
    .{ .path = "popup.max_width", .label = "Maximum flyout width", .kind = .number, .min = 320, .max = 1280 },
    .{ .path = "popup.max_height", .label = "Maximum flyout height", .kind = .number, .min = 320, .max = 1600 },
};
const idle_fields = [_]Spec{
    .{ .path = "idle.ac.lock_seconds", .label = "On AC · Lock after seconds (0 disables)", .kind = .number },
    .{ .path = "idle.ac.suspend_seconds", .label = "On AC · Suspend after seconds (0 disables)", .kind = .number },
    .{ .path = "idle.battery.lock_seconds", .label = "On battery · Lock after seconds (0 disables)", .kind = .number },
    .{ .path = "idle.battery.suspend_seconds", .label = "On battery · Suspend after seconds (0 disables)", .kind = .number },
};
const Field = struct { view: *View, spec: Spec, widget: *gtk.Widget, signal: c_ulong };
pub const View = struct {
    editor: *Editor,
    host: *gtk.Box,
    fields: []Field,
    filling: bool = false,
    editing: bool = false,
    own_invalid: ?[64]u8 = null,
    bar: ?*@import("bar_view.zig").View = null,
    launchers: ?*@import("application_launchers_view.zig").View = null,
    pub fn create(host: *gtk.Box, editor: *Editor, idle: bool, context: *anyopaque, invalidate: *const fn (*anyopaque, @import("../desktop/settings_navigation.zig").Route) void) !*View {
        const self = try a.create(View);
        const specs: []const Spec = if (idle) &idle_fields else &bar_fields;
        self.* = .{ .editor = editor, .host = host, .fields = try a.alloc(Field, specs.len) };
        var card = w.column(0);
        card.as(gtk.Widget).addCssClass("settings-card");
        host.append(card.as(gtk.Widget));
        for (specs, self.fields, 0..) |spec, *field, index| {
            if (!idle and (index == 3 or index == 8)) {
                if (index == 3) self.bar = try @import("bar_view.zig").View.create(host, editor, context, invalidate);
                const expander = gtk.Expander.new(if (index == 3) "Dock" else "Flyouts");
                card = w.column(0);
                card.as(gtk.Widget).addCssClass("settings-card");
                expander.setChild(card.as(gtk.Widget));
                host.append(expander.as(gtk.Widget));
            }
            const row = w.flow(2);
            row.setHomogeneous(0);
            row.as(gtk.Widget).addCssClass("settings-form-row");
            row.insert(w.label(spec.label, "settings-row-title").as(gtk.Widget), -1);
            const widget = switch (spec.kind) {
                .text => blk: {
                    const entry = gtk.Entry.new();
                    entry.setMaxLength(512);
                    entry.as(gtk.Editable).setWidthChars(16);
                    break :blk entry.as(gtk.Widget);
                },
                .number => gtk.SpinButton.newWithRange(spec.min, spec.max, 1).as(gtk.Widget),
                .toggle => gtk.Switch.new().as(gtk.Widget),
                .choice => blk: {
                    var names: [8]?[*:0]const u8 = @splat(null);
                    for (spec.choices, 0..) |choice, i| names[i] = choice;
                    break :blk gtk.DropDown.newFromStrings(@ptrCast(&names)).as(gtk.Widget);
                },
            };
            widget.setHalign(.end);
            widget.setValign(.center);
            w.name(widget, spec.label);
            row.insert(widget, -1);
            card.append(row.as(gtk.Widget));
            field.* = .{ .view = self, .spec = spec, .widget = widget, .signal = 0 };
            field.signal = switch (spec.kind) {
                .text => gtk.Editable.signals.changed.connect(object.ext.cast(gtk.Entry, widget).?.as(gtk.Editable), *Field, textChanged, field, .{}),
                .number => gtk.SpinButton.signals.value_changed.connect(object.ext.cast(gtk.SpinButton, widget).?, *Field, numberChanged, field, .{}),
                .toggle => object.Object.signals.notify.connect(widget.as(object.Object), *Field, changed, field, .{ .detail = "active" }),
                .choice => object.Object.signals.notify.connect(widget.as(object.Object), *Field, changed, field, .{ .detail = "selected" }),
            };
        }
        if (!idle) self.launchers = try @import("application_launchers_view.zig").View.create(host, editor);
        self.update();
        return self;
    }
    pub fn destroy(self: *View) void {
        if (self.launchers) |view| view.destroy();
        if (self.bar) |bar| bar.destroy();
        for (self.fields) |field| object.signalHandlerDisconnect(field.widget.as(object.Object), field.signal);
        a.free(self.fields);
        a.destroy(self);
    }
    pub fn update(self: *View) void {
        if (self.launchers) |view| view.update();
        if (self.bar) |bar| bar.update();
        if (self.editing) return;
        self.filling = true;
        defer self.filling = false;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const document = formDocument(alloc, self.editor.text(), self.own_invalid) catch {
            for (self.fields) |field| field.widget.setSensitive(0);
            return;
        };
        for (self.fields) |field| field.widget.setSensitive(@intFromBool(self.editor.editable()));
        for (self.fields) |field| {
            const value = lookup(document, field.spec.path) orelse continue;
            // Acknowledgments must not reset the cursor in an active entry.
            if (field.widget.hasFocus() != 0 or (field.widget.getRoot() != null and field.spec.kind == .text and field.widget.getFocusChild() != null)) continue;
            switch (field.spec.kind) {
                .text => object.ext.cast(gtk.Entry, field.widget).?.as(gtk.Editable).setText(alloc.dupeZ(u8, value.string) catch continue),
                .number => object.ext.cast(gtk.SpinButton, field.widget).?.setValue(@floatFromInt(value.integer)),
                .toggle => object.ext.cast(gtk.Switch, field.widget).?.setActive(@intFromBool(value.bool)),
                .choice => for (field.spec.choices, 0..) |choice, i| {
                    if (std.mem.eql(u8, choice, value.string)) object.ext.cast(gtk.DropDown, field.widget).?.setSelected(@intCast(i));
                },
            }
        }
    }
    fn save(field: *Field) void {
        const self = field.view;
        if (self.filling or !self.editor.editable()) return;
        self.editing = true;
        defer self.editing = false;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const value: std.json.Value = switch (field.spec.kind) {
            .text => .{ .string = std.mem.span(object.ext.cast(gtk.Entry, field.widget).?.as(gtk.Editable).getText()) },
            .number => .{ .integer = object.ext.cast(gtk.SpinButton, field.widget).?.getValueAsInt() },
            .toggle => .{ .bool = object.ext.cast(gtk.Switch, field.widget).?.getActive() != 0 },
            .choice => .{ .string = field.spec.choices[object.ext.cast(gtk.DropDown, field.widget).?.getSelected()] },
        };
        const text = patch(alloc, self.editor.text(), field.spec.path, value, self.own_invalid) catch |err| {
            self.editor.error_code.set(@errorName(err));
            return;
        };
        const previous = self.own_invalid;
        self.own_invalid = @import("editor_protocol.zig").digest(text);
        self.editor.edit(text) catch |err| {
            self.own_invalid = previous;
            self.editor.error_code.set(@errorName(err));
        };
    }
    fn changed(_: *object.Object, _: *object.ParamSpec, field: *Field) callconv(.c) void {
        save(field);
    }
    fn textChanged(_: *gtk.Editable, field: *Field) callconv(.c) void {
        save(field);
    }
    fn numberChanged(_: *gtk.SpinButton, field: *Field) callconv(.c) void {
        save(field);
    }
};
fn lookup(document: std.json.Value, path: []const u8) ?std.json.Value {
    var value = document;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| value = if (value == .object) value.object.get(part) orelse return null else return null;
    return value;
}
fn formDocument(alloc: std.mem.Allocator, text: []const u8, own: ?[64]u8) !std.json.Value {
    if (own) |hash| if (std.mem.eql(u8, &hash, &@import("editor_protocol.zig").digest(text)))
        return std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{});
    const prefs = try model.parse(alloc, text);
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, try std.json.Stringify.valueAlloc(alloc, prefs, .{}), .{});
}
fn patch(alloc: std.mem.Allocator, text: []const u8, path: []const u8, value: std.json.Value, own: ?[64]u8) ![]const u8 {
    var document = try formDocument(alloc, text, own);
    var current = &document;
    var parts = std.mem.splitScalar(u8, path, '.');
    var part = parts.next().?;
    while (parts.next()) |next| {
        current = current.object.getPtr(part) orelse return error.InvalidField;
        part = next;
    }
    try current.object.put(alloc, part, value);
    return std.json.Stringify.valueAlloc(alloc, document, .{ .whitespace = .indent_2 });
}
