//! Display-backed GTK tests: parent wiring should import this file from
//! widget_tests.zig and run tests/widgets.py in its private Wayland fixture.
//! No headless skip, application wiring, filesystem model, or live buffer needed.
const std = @import("std");
const t = std.testing;
const u = @import("../c.zig");
const c = u.c;
const picker = @import("workspace_picker.zig");
const Picker = picker.Picker;
const Item = picker.Item;

var gtk_state: enum { cold, ready, unavailable } = .cold;
fn initGtk() !void {
    if (gtk_state == .cold) {
        gtk_state = .unavailable;
        if (c.gtk_init_check() != 0) gtk_state = .ready;
    }
    if (gtk_state != .ready) return error.PrivateDisplayRequired;
}
fn drain() void {
    for (0..256) |_| if (c.g_main_context_iteration(null, 0) == 0) break;
}
fn waitMapped(widget: u.W) !void {
    const deadline = c.g_get_monotonic_time() + 5_000_000;
    while (c.gtk_widget_get_mapped(widget) == 0) {
        if (c.g_get_monotonic_time() >= deadline) return error.WidgetMappingTimedOut;
        drain();
        c.g_usleep(1000);
    }
}
fn key(keys: *c.GtkEventController, value: c_uint, modifiers: c.GdkModifierType) c_int {
    var handled: c_int = 0;
    c.g_signal_emit_by_name(keys, "key-pressed", value, @as(c_uint, 0), modifiers, &handled);
    return handled;
}
fn rowAt(p: *Picker, index: usize) *c.GtkListBoxRow {
    return c.gtk_list_box_get_row_at_index(u.cast(c.GtkListBox, p.list), @intCast(index)).?;
}
fn hasFocusWithin(window: u.W, widget: u.W) bool {
    const focused = c.gtk_window_get_focus(u.cast(c.GtkWindow, window)) orelse return false;
    return focused == widget or c.gtk_widget_is_ancestor(focused, widget) != 0;
}
const samples = [_]Item{
    .{ .id = 0, .label = "Coral", .detail = "/home/zoey/Projects/Coral", .dirty = true },
    .{ .id = 901, .label = "Coral", .detail = "/srv/archive/Coral" },
    .{ .id = 47, .label = "Straße", .detail = "Group 2 · /tmp/CAFÉ/main.zig" },
    .{ .id = 8000, .label = "Missing", .detail = "/offline/project", .unavailable = true },
};

const Fixture = struct {
    parent: u.W = undefined,
    editor: u.W = undefined,
    picker: ?*Picker = null,
    closed: usize = 0,
    dispatched: usize = 0,
    last_id: ?usize = null,
    alive: bool = true,
    violation: bool = false,
    cancel_on_closed: bool = false,
    destroy_parent_on_closed: bool = false,
    reopen_on_activate: bool = false,
    window_finalized: bool = false,
    check_window_lifetime: bool = false,

    fn init(self: *Fixture) !void {
        try initGtk();
        self.parent = c.gtk_window_new().?;
        _ = c.g_object_ref(self.parent);
        self.editor = c.gtk_text_view_new().?;
        c.gtk_window_set_child(u.cast(c.GtkWindow, self.parent), self.editor);
        c.gtk_window_present(u.cast(c.GtkWindow, self.parent));
        try waitMapped(self.parent);
    }
    fn open(self: *Fixture, items: []const Item) !*Picker {
        const p = try Picker.create(self.parent, self, "Recent Projects / Open Buffers", "Nothing matches this filter", items, &onActivate, &onClosed);
        self.picker = p;
        return p;
    }
    fn deinit(self: *Fixture) void {
        if (self.picker) |p| p.close();
        c.gtk_window_destroy(u.cast(c.GtkWindow, self.parent));
        c.g_object_unref(self.parent);
        drain();
    }
    fn onClosed(context: *anyopaque) void {
        const self = u.cast(Fixture, context);
        self.violation = self.violation or !self.alive or self.picker == null;
        const p = self.picker.?;
        self.picker = null;
        self.closed += 1;
        self.violation = self.violation or c.gtk_window_get_modal(u.cast(c.GtkWindow, p.window)) != 0;
        if (self.check_window_lifetime) {
            self.violation = self.violation or self.window_finalized;
            _ = c.g_signal_handlers_disconnect_matched(p.window, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        }
        if (self.cancel_on_closed) p.close();
        if (self.destroy_parent_on_closed) {
            c.gtk_window_destroy(u.cast(c.GtkWindow, self.parent));
        } else {
            _ = c.gtk_widget_grab_focus(self.editor);
        }
    }
    fn onActivate(context: *anyopaque, id: usize) void {
        const self = u.cast(Fixture, context);
        self.violation = self.violation or !self.alive or self.picker != null or self.closed == 0;
        self.dispatched += 1;
        self.last_id = id;
        if (self.reopen_on_activate) {
            self.reopen_on_activate = false;
            const reopened = self.open(&samples) catch {
                self.violation = true;
                return;
            };
            reopened.show();
        }
    }
    fn finalized(context: ?*anyopaque, _: ?*c.GObject) callconv(.c) void {
        u.cast(Fixture, context.?).window_finalized = true;
    }
};

test "workspace picker owns snapshots and filters Unicode labels and full qualifiers" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var label = "Straße".*;
    var detail = "Group 2 · /tmp/CAFÉ/main.zig".*;
    var title = "Open Buffers".*;
    var empty_text = "No buffers match".*;
    var input = [_]Item{.{ .id = 782, .label = &label, .detail = &detail, .dirty = true }};
    const p = try Picker.create(f.parent, &f, &title, &empty_text, &input, &Fixture.onActivate, &Fixture.onClosed);
    f.picker = p;
    @memset(&label, 'x');
    @memset(&detail, 'x');
    @memset(&title, 'x');
    @memset(&empty_text, 'x');
    input[0].id = 99;
    p.show();
    try waitMapped(p.window);
    try t.expectEqualStrings("Open Buffers", std.mem.span(c.gtk_window_get_title(u.cast(c.GtkWindow, p.window))));
    try t.expectEqualStrings("No buffers match", std.mem.span(c.gtk_label_get_text(u.cast(c.GtkLabel, p.empty))));
    try t.expect(hasFocusWithin(p.window, p.entry));
    try p.setFilter("STRASSE");
    try t.expectEqualStrings("STRASSE", p.query());
    try t.expectEqual(@as(?usize, 782), p.selectedId());
    try p.setFilter("café");
    try t.expectEqual(@as(usize, 1), p.matchCount());
    try p.setFilter("group 2");
    try t.expectEqual(@as(?usize, 782), p.visibleId(0));
    const row = rowAt(p, 0);
    try t.expectEqualStrings("Group 2 · /tmp/CAFÉ/main.zig", std.mem.span(c.gtk_widget_get_tooltip_text(u.cast(c.GtkWidget, row))));
    try t.expectEqual(@as(usize, 0), f.dispatched);
    c.g_signal_emit_by_name(p.entry, "activate");
    try t.expectEqual(@as(?usize, 782), f.last_id);
    try t.expectEqual(@as(usize, 1), f.closed);
    try t.expect(!f.violation);
}

test "workspace picker distinguishes basenames and never activates empty or unavailable selections" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const p = try f.open(&samples);
    try t.expectEqual(@as(?usize, 0), p.selectedId());
    try p.setFilter("coral");
    try t.expectEqual(@as(usize, 2), p.matchCount());
    try t.expect(p.select(901));
    try t.expectEqual(@as(?usize, 901), p.selectedId());
    try t.expect(!p.select(123456));
    try t.expectEqual(@as(?usize, 901), p.selectedId());
    try t.expect(p.select(null));
    p.activate();
    try p.setFilter("not present");
    try t.expectEqual(@as(?usize, null), p.selectedId());
    try t.expect(c.gtk_widget_get_visible(p.empty) != 0);
    try t.expect(c.gtk_widget_get_visible(p.scroll) == 0);
    // A hidden retained row must not dispatch either.
    c.g_signal_emit_by_name(p.list, "row-activated", rowAt(p, 0));
    c.g_signal_emit_by_name(p.entry, "activate");
    try p.setFilter("offline");
    try t.expectEqual(@as(?usize, 8000), p.selectedId());
    try t.expect(c.gtk_list_box_row_get_activatable(rowAt(p, 0)) == 0);
    p.activate();
    c.g_signal_emit_by_name(p.list, "row-activated", rowAt(p, 0));
    try t.expectEqual(@as(usize, 0), f.closed);
    try t.expectEqual(@as(usize, 0), f.dispatched);
    try p.setFilter("/srv/archive");
    try t.expectEqual(@as(?usize, 901), p.selectedId());
    p.activate();
    try t.expectEqual(@as(?usize, 901), f.last_id);
    try t.expect(!f.violation);
}

test "workspace picker keyboard navigation wraps keeps typing focus and Escape cancels" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const p = try f.open(&samples);
    p.show();
    try waitMapped(p.window);
    try t.expectEqual(@as(c_int, 1), key(p.keys, c.GDK_KEY_Down, 0));
    try t.expectEqual(@as(?usize, 901), p.selectedId());
    try t.expectEqual(@as(c_int, 1), key(p.keys, c.GDK_KEY_Up, 0));
    try t.expectEqual(@as(?usize, 0), p.selectedId());
    _ = key(p.keys, c.GDK_KEY_KP_Up, 0);
    try t.expectEqual(@as(?usize, 8000), p.selectedId());
    _ = key(p.keys, c.GDK_KEY_KP_Down, 0);
    try t.expectEqual(@as(?usize, 0), p.selectedId());
    try t.expectEqual(@as(c_int, 0), key(p.keys, c.GDK_KEY_Down, c.GDK_CONTROL_MASK));
    try t.expect(hasFocusWithin(p.window, p.entry));
    // Use the actual editable changed signal, not just the public test helper.
    c.gtk_editable_set_text(u.cast(c.GtkEditable, p.entry), "archive");
    try t.expectEqual(@as(?usize, 901), p.selectedId());
    try t.expectEqual(@as(usize, 0), f.dispatched);
    try p.setFilter("no matches");
    _ = key(p.keys, c.GDK_KEY_Down, 0);
    try t.expectEqual(@as(?usize, null), p.selectedId());
    try t.expectEqual(@as(c_int, 1), key(p.keys, c.GDK_KEY_Escape, 0));
    try t.expect(f.picker == null);
    try t.expectEqual(@as(usize, 1), f.closed);
    try t.expectEqual(@as(usize, 0), f.dispatched);
    try t.expect(hasFocusWithin(f.parent, f.editor));
}

test "workspace picker bounds widgets but searches the entire admitted snapshot" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var items: [picker.max_items]Item = undefined;
    for (&items, 0..) |*item, index| item.* = .{ .id = index + 700, .label = "Shared", .detail = "/project/common" };
    items[items.len - 1].detail = "/project/last-only";
    const p = try f.open(&items);
    const first_row = rowAt(p, 0);
    try t.expectEqual(@as(usize, 512), p.matchCount());
    try t.expectEqual(@as(usize, 50), p.visibleCount());
    try t.expectEqual(@as(?usize, null), p.visibleId(50));
    try t.expect(c.gtk_list_box_get_row_at_index(u.cast(c.GtkListBox, p.list), 50) == null);
    try t.expect(!p.select(1211));
    try p.setFilter("last-only");
    try t.expectEqual(@as(usize, 1), p.matchCount());
    try t.expectEqual(@as(?usize, 1211), p.selectedId());
    try t.expectEqual(first_row, rowAt(p, 0));
    // Previously-visible pooled rows are not valid activation targets now.
    c.g_signal_emit_by_name(p.list, "row-activated", rowAt(p, 49));
    try t.expectEqual(@as(usize, 0), f.dispatched);
    try p.setFilter("  \t");
    try t.expectEqual(@as(usize, 512), p.matchCount());
    try t.expectEqual(@as(?usize, 700), p.selectedId());
    p.close();
    const empty = try f.open(&.{});
    try t.expectEqual(@as(usize, 0), empty.visibleCount());
    empty.activate();
    _ = key(empty.keys, c.GDK_KEY_Up, 0);
    try t.expectEqual(@as(usize, 0), f.dispatched);
}

test "workspace picker rejects ambiguous IDs invalid text and excess items before callbacks" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const duplicate = [_]Item{ samples[0], samples[0] };
    try t.expectError(error.DuplicateId, f.open(&duplicate));
    var too_many: [picker.max_items + 1]Item = undefined;
    for (&too_many, 0..) |*item, index| item.* = .{ .id = index, .label = "a", .detail = "b" };
    try t.expectError(error.TooManyItems, f.open(&too_many));
    try t.expectError(error.InvalidText, f.open(&.{.{ .id = 1, .label = "bad\x00label", .detail = "path" }}));
    try t.expectError(error.InvalidText, f.open(&.{.{ .id = 1, .label = "label", .detail = "\xff" }}));
    try t.expectEqual(@as(usize, 0), f.closed);
    const p = try f.open(&samples);
    try p.setFilter("archive");
    try t.expectError(error.InvalidText, p.setFilter("\xff"));
    try t.expectEqualStrings("archive", p.query());
}

test "workspace picker tears down exactly once and disconnects retained GTK callback senders" {
    const Exit = enum { before_show, stop_search, window_close, window_destroy, parent_destroy, activate, row_activate, reentrant_cancel, parent_cancel };
    for (std.enums.values(Exit)) |exit| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        const p = try f.open(&samples);
        const window = p.window;
        const entry = p.entry;
        const list = p.list;
        const keys = p.keys;
        const row = rowAt(p, 1);
        for ([_]u.W{ window, entry, list, u.cast(c.GtkWidget, row) }) |object| _ = c.g_object_ref(object);
        defer for ([_]u.W{ window, entry, list, u.cast(c.GtkWidget, row) }) |object| c.g_object_unref(object);
        _ = c.g_object_ref(keys);
        defer c.g_object_unref(keys);
        if (exit != .before_show) {
            p.show();
            try waitMapped(window);
        }
        try t.expectEqual(u.cast(c.GtkWindow, f.parent), c.gtk_window_get_transient_for(u.cast(c.GtkWindow, window)).?);
        try t.expect(p.select(901));
        switch (exit) {
            .before_show => p.close(),
            .stop_search => c.g_signal_emit_by_name(entry, "stop-search"),
            .window_close => c.gtk_window_close(u.cast(c.GtkWindow, window)),
            .window_destroy => c.gtk_window_destroy(u.cast(c.GtkWindow, window)),
            .parent_destroy => c.gtk_window_destroy(u.cast(c.GtkWindow, f.parent)),
            .activate => c.g_signal_emit_by_name(entry, "activate"),
            .row_activate => c.g_signal_emit_by_name(list, "row-activated", row),
            .reentrant_cancel => {
                f.cancel_on_closed = true;
                p.activate();
            },
            .parent_cancel => {
                f.destroy_parent_on_closed = true;
                p.activate();
            },
        }
        const expected: usize = if (exit == .activate or exit == .row_activate) 1 else 0;
        try t.expect(f.picker == null);
        try t.expectEqual(@as(usize, 1), f.closed);
        try t.expectEqual(expected, f.dispatched);
        if (expected != 0) try t.expectEqual(@as(?usize, 901), f.last_id);
        try t.expect(c.gtk_window_get_modal(u.cast(c.GtkWindow, window)) == 0);
        try t.expect(c.gtk_widget_get_realized(window) == 0);
        f.alive = false;
        c.gtk_editable_set_text(u.cast(c.GtkEditable, entry), "late change");
        c.g_signal_emit_by_name(entry, "activate");
        c.g_signal_emit_by_name(entry, "stop-search");
        c.g_signal_emit_by_name(list, "row-activated", row);
        _ = key(keys, c.GDK_KEY_Escape, 0);
        c.gtk_window_destroy(u.cast(c.GtkWindow, f.parent));
        drain();
        try t.expectEqual(@as(usize, 1), f.closed);
        try t.expectEqual(expected, f.dispatched);
        try t.expect(!f.violation);
    }
}

test "workspace picker holds destroyed window through owner cleanup and can reopen during activation" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const p = try f.open(&samples);
    f.check_window_lifetime = true;
    c.g_object_weak_ref(@ptrCast(p.window), &Fixture.finalized, &f);
    // Deliberately no extra window reference: finish must provide that hold.
    p.close();
    try t.expect(!f.violation);
    try t.expect(f.window_finalized);
    f.check_window_lifetime = false;
    const next = try f.open(&samples);
    f.reopen_on_activate = true;
    next.activate();
    try t.expectEqual(@as(?usize, 0), f.last_id);
    try t.expectEqual(@as(usize, 1), f.dispatched);
    try t.expectEqual(@as(usize, 2), f.closed);
    try t.expect(f.picker != null);
    try waitMapped(f.picker.?.window);
    try t.expect(!f.violation);
}
