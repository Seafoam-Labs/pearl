//! Display-backed tests. Run through tests/widgets.py, never the headless test step.
const std = @import("std");
const testing = std.testing;
const u = @import("c.zig");
const c = u.c;
const Document = @import("document.zig").Document;
const editor = @import("editor/view.zig");
const EditorView = editor.EditorView;
const Palette = @import("workbench/palette.zig").Palette;
const Command = @import("workbench/palette.zig").Command;

var gtk_state: enum { cold, ready, unavailable } = .cold;
fn initGtk() !void {
    // GTK is process-global; retrying after failed initialization is unsafe too.
    if (gtk_state == .cold) {
        gtk_state = .unavailable;
        if (c.gtk_init_check() != 0) {
            c.gtk_source_init();
            gtk_state = .ready;
        }
    }
    // A missing compositor is a test failure, not SkipZigTest.
    if (gtk_state != .ready) return error.PrivateDisplayRequired;
}

fn drain() void {
    // Bound each drain even if an unrelated GTK source keeps scheduling work.
    for (0..256) |_| {
        if (c.g_main_context_iteration(null, 0) == 0) break;
    }
}

fn waitMapped(widget: u.W) !void {
    const deadline = c.g_get_monotonic_time() + 5_000_000;
    while (c.gtk_widget_get_mapped(widget) == 0) {
        if (c.g_get_monotonic_time() >= deadline) return error.WidgetMappingTimedOut;
        drain();
        c.g_usleep(1_000);
    }
}

fn select(buffer: *c.GtkTextBuffer, insertion: c_int, bound: c_int) void {
    var i: c.GtkTextIter = undefined;
    var b: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(buffer, &i, insertion);
    c.gtk_text_buffer_get_iter_at_offset(buffer, &b, bound);
    c.gtk_text_buffer_select_range(buffer, &i, &b);
}

fn expectSelection(buffer: *c.GtkTextBuffer, insertion: c_int, bound: c_int) !void {
    var i: c.GtkTextIter = undefined;
    var b: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_mark(buffer, &i, c.gtk_text_buffer_get_insert(buffer));
    c.gtk_text_buffer_get_iter_at_mark(buffer, &b, c.gtk_text_buffer_get_selection_bound(buffer));
    try testing.expectEqual(insertion, c.gtk_text_iter_get_offset(&i));
    try testing.expectEqual(bound, c.gtk_text_iter_get_offset(&b));
}

const CallbackCounts = struct {
    close: usize = 0,
    context: usize = 0,
    unrelated: usize = 0,

    fn clicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const document = u.cast(Document, data.?);
        u.cast(CallbackCounts, document.context.?).close += 1;
    }
    fn pressed(_: ?*c.GtkGestureClick, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
        const document = u.cast(Document, data.?);
        u.cast(CallbackCounts, document.context.?).context += 1;
    }
    fn observer(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(CallbackCounts, data.?).unrelated += 1;
    }
};

fn emitPressed(controller: *c.GtkEventController) void {
    c.g_signal_emit_by_name(controller, "pressed", @as(c_int, 1), @as(f64, 12), @as(f64, 24));
}

fn attachContext(view: *EditorView) *c.GtkEventController {
    const controller = u.cast(c.GtkEventController, c.gtk_gesture_click_new().?);
    u.connect(controller, "pressed", &CallbackCounts.pressed, view.document);
    view.context_menu_controller = controller;
    c.gtk_widget_add_controller(view.widget, controller);
    return controller;
}

test "retained page and close button survive view destruction without document callbacks" {
    try initGtk();
    for ([_]bool{ false, true }) |with_context| {
        var counts: CallbackCounts = .{};
        const document = try Document.create(1, &counts);
        var document_alive = true;
        defer if (document_alive) document.destroy();
        const view = try EditorView.create(document);
        var view_alive = true;
        defer if (view_alive) view.destroy();
        const page = view.page;
        const button = view.close_button;
        const widget = view.widget;
        _ = c.g_object_ref(page);
        defer c.g_object_unref(page);
        _ = c.g_object_ref(button);
        defer c.g_object_unref(button);
        u.connect(button, "clicked", &CallbackCounts.clicked, document);
        u.connect(button, "clicked", &CallbackCounts.observer, &counts);
        defer _ = c.g_signal_handlers_disconnect_matched(button, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, &counts);
        const controller = if (with_context) attachContext(view) else null;
        if (controller) |p| _ = c.g_object_ref(p);
        defer if (controller) |p| c.g_object_unref(p);

        c.g_signal_emit_by_name(button, "clicked");
        try testing.expectEqual(@as(usize, 1), counts.close);
        if (controller) |p| {
            emitPressed(p);
            try testing.expectEqual(@as(usize, 1), counts.context);
        }
        view.enableFocusSelection();
        const focus_controller = view.focus_controller.?;
        _ = c.g_object_ref(focus_controller);
        defer c.g_object_unref(focus_controller);
        const mark = view.selection.insertion;
        _ = c.g_object_ref(mark);
        defer c.g_object_unref(mark);
        view.destroy();
        view_alive = false;

        try testing.expectEqual(widget, c.gtk_scrolled_window_get_child(u.cast(c.GtkScrolledWindow, page)).?);
        try testing.expectEqual(document.buffer, c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, widget)).?);
        try testing.expect(c.gtk_text_mark_get_deleted(mark) != 0);
        try testing.expect(c.gtk_event_controller_get_widget(focus_controller) == null);
        if (controller) |p| {
            try testing.expect(c.gtk_event_controller_get_widget(p) == null);
            emitPressed(p);
            try testing.expectEqual(@as(usize, 1), counts.context);
        }
        c.g_signal_emit_by_name(button, "clicked");
        try testing.expectEqual(@as(usize, 1), counts.close);
        try testing.expectEqual(@as(usize, 2), counts.unrelated);
        // The retained page keeps its buffer, not its Document or EditorView owners.
        const buffer = document.buffer;
        document.destroy();
        document_alive = false;
        c.g_signal_emit_by_name(button, "clicked");
        if (controller) |p| emitPressed(p);
        c.g_signal_emit_by_name(focus_controller, "enter");
        c.g_signal_emit_by_name(focus_controller, "leave");
        c.gtk_text_buffer_set_text(buffer, "buffer still usable", -1);
        try testing.expectEqual(@as(c_int, 19), c.gtk_text_buffer_get_char_count(buffer));
        try testing.expectEqual(@as(usize, 1), counts.close);
        try testing.expectEqual(@as(usize, 3), counts.unrelated);
    }
}

test "window teardown precedes view teardown and callback detachment is idempotent" {
    try initGtk();
    var counts: CallbackCounts = .{};
    const document = try Document.create(2, &counts);
    defer document.destroy();
    const view = try EditorView.create(document);
    defer view.destroy();
    const window = c.gtk_window_new().?;
    const win = u.cast(c.GtkWindow, window);
    // This defer runs before view.destroy even on a failed assertion.
    var window_alive = true;
    defer if (window_alive) c.gtk_window_destroy(win);
    const notebook = c.gtk_notebook_new().?;
    c.gtk_window_set_child(win, notebook);
    _ = c.gtk_notebook_append_page(u.cast(c.GtkNotebook, notebook), view.page, view.tab);
    u.connect(view.close_button, "clicked", &CallbackCounts.clicked, document);
    const controller = attachContext(view);
    _ = c.g_object_ref(controller);
    defer c.g_object_unref(controller);
    view.enableFocusSelection();
    c.gtk_window_present(win);
    try waitMapped(view.widget);
    view.disconnectDocumentCallbacks();
    view.disconnectDocumentCallbacks();
    c.gtk_window_destroy(win);
    window_alive = false;
    // Do not retain the window: its children must be usable through view ownership.
    try testing.expect(c.gtk_widget_get_parent(view.page) == null);
    try testing.expect(c.gtk_widget_get_parent(view.tab) == null);
    try testing.expect(view.context_menu_controller == null);
    try testing.expect(c.gtk_event_controller_get_widget(controller) == null);
    c.g_signal_emit_by_name(view.close_button, "clicked");
    emitPressed(controller);
    try testing.expectEqual(@as(usize, 0), counts.close);
    try testing.expectEqual(@as(usize, 0), counts.context);
    select(document.buffer, 0, 0);
    view.saveSelection();
    view.restoreSelection();
}

fn focus(win: *c.GtkWindow, widget: u.W) !void {
    try testing.expect(c.gtk_widget_grab_focus(widget) != 0);
    try testing.expectEqual(widget, c.gtk_window_get_focus(win).?);
}

fn waitScrollable(adjustment: *c.GtkAdjustment, minimum: f64) !void {
    const deadline = c.g_get_monotonic_time() + 5_000_000;
    while (c.gtk_adjustment_get_upper(adjustment) - c.gtk_adjustment_get_page_size(adjustment) < minimum) {
        if (c.g_get_monotonic_time() >= deadline) return error.ScrollAllocationTimedOut;
        drain();
        c.g_usleep(1_000);
    }
}

test "shared document views preserve directed selections, opt-in focus and independent scroll" {
    try initGtk();
    const document = try Document.create(3, null);
    defer document.destroy();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..300) |_| {
        try text.appendSlice(testing.allocator, "aé🌱");
        for (0..16) |_| try text.appendSlice(testing.allocator, "abcdefghij");
        try text.append(testing.allocator, '\n');
    }
    c.gtk_text_buffer_set_text(document.buffer, text.items.ptr, @intCast(text.items.len));
    c.gtk_text_buffer_set_modified(document.buffer, 0);
    const revision = document.revision;
    const can_undo = c.gtk_text_buffer_get_can_undo(document.buffer);
    select(document.buffer, 1, 4);
    const first = try EditorView.create(document);
    defer first.destroy();
    select(document.buffer, 12, 8);
    const second = try EditorView.create(document);
    defer second.destroy();
    try testing.expect(first.id != second.id);
    try testing.expect(first.focus_controller == null and second.focus_controller == null);
    try testing.expectEqual(document.buffer, c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, first.widget)).?);
    try testing.expectEqual(document.buffer, c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, second.widget)).?);
    first.restoreSelection();
    try expectSelection(document.buffer, 1, 4);
    second.restoreSelection();
    try expectSelection(document.buffer, 12, 8);

    const window = c.gtk_window_new().?;
    const win = u.cast(c.GtkWindow, window);
    defer c.gtk_window_destroy(win);
    const root = u.box(false, 0);
    const panes = u.box(true, 0);
    const outside = c.gtk_entry_new().?;
    c.gtk_window_set_default_size(win, 720, 360);
    c.gtk_window_set_child(win, root);
    u.append(root, outside);
    u.append(root, panes);
    u.append(panes, first.page);
    u.append(panes, second.page);
    c.gtk_scrolled_window_set_policy(u.cast(c.GtkScrolledWindow, first.page), c.GTK_POLICY_AUTOMATIC, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_policy(u.cast(c.GtkScrolledWindow, second.page), c.GTK_POLICY_AUTOMATIC, c.GTK_POLICY_AUTOMATIC);
    first.enableFocusSelection();
    const first_controller = first.focus_controller;
    first.enableFocusSelection();
    try testing.expectEqual(first_controller, first.focus_controller);
    second.enableFocusSelection();
    c.gtk_window_present(win);
    try waitMapped(first.widget);
    try waitMapped(second.widget);
    try focus(win, first.widget);
    try expectSelection(document.buffer, 1, 4);
    select(document.buffer, 6, 2); // Leave must save this, not the original range.
    try focus(win, second.widget);
    try expectSelection(document.buffer, 12, 8);
    select(document.buffer, 20, 20);
    try focus(win, first.widget);
    try expectSelection(document.buffer, 6, 2);
    try focus(win, second.widget);
    try expectSelection(document.buffer, 20, 20);
    // Navigation from another control must explicitly adopt the destination.
    try testing.expect(c.gtk_widget_grab_focus(outside) != 0);
    select(document.buffer, 30, 25);
    first.saveSelection();
    try focus(win, first.widget);
    try expectSelection(document.buffer, 30, 25);
    try focus(win, second.widget);
    try expectSelection(document.buffer, 20, 20);
    try testing.expect(c.gtk_widget_grab_focus(outside) != 0);
    drain();

    const first_scroll = u.cast(c.GtkScrolledWindow, first.page);
    const second_scroll = u.cast(c.GtkScrolledWindow, second.page);
    const first_axes = [_]*c.GtkAdjustment{ c.gtk_scrolled_window_get_hadjustment(first_scroll).?, c.gtk_scrolled_window_get_vadjustment(first_scroll).? };
    const second_axes = [_]*c.GtkAdjustment{ c.gtk_scrolled_window_get_hadjustment(second_scroll).?, c.gtk_scrolled_window_get_vadjustment(second_scroll).? };
    for (first_axes, second_axes) |a, b| {
        try testing.expect(a != b);
        try waitScrollable(a, 200);
        try waitScrollable(b, 200);
        c.gtk_adjustment_set_value(a, 40);
        c.gtk_adjustment_set_value(b, 160);
    }
    first.restoreSelection();
    try expectSelection(document.buffer, 30, 25);
    second.restoreSelection();
    try expectSelection(document.buffer, 20, 20);
    drain();
    for (first_axes, second_axes) |a, b| {
        try testing.expectApproxEqAbs(@as(f64, 40), c.gtk_adjustment_get_value(a), 0.01);
        try testing.expectApproxEqAbs(@as(f64, 160), c.gtk_adjustment_get_value(b), 0.01);
    }
    try testing.expectEqual(revision, document.revision);
    try testing.expect(!document.dirty());
    try testing.expectEqual(can_undo, c.gtk_text_buffer_get_can_undo(document.buffer));
}

const PaletteOwner = struct {
    palette: ?*Palette = null,
    window: ?u.W = null,
    alive: bool = true,
    closed: usize = 0,
    dispatched: usize = 0,
    selected: ?Command = null,
    violation: bool = false,
    cancel_reentrantly: bool = false,
    destroy_parent_on_close: ?*c.GtkWindow = null,

    fn onClosed(context: *anyopaque) void {
        const self = u.cast(PaletteOwner, context);
        self.violation = self.violation or !self.alive or self.palette == null;
        const palette = self.palette;
        self.palette = null;
        self.closed += 1;
        if (self.cancel_reentrantly) if (palette) |p| p.close();
        if (self.destroy_parent_on_close) |parent| c.gtk_window_destroy(parent);
    }
    fn onCommand(context: *anyopaque, command: Command) void {
        const self = u.cast(PaletteOwner, context);
        self.violation = self.violation or !self.alive or self.palette != null or self.closed != 1;
        if (self.window) |window| {
            self.violation = self.violation or c.gtk_window_get_modal(u.cast(c.GtkWindow, window)) != 0 or c.gtk_widget_get_realized(window) != 0;
        }
        self.dispatched += 1;
        self.selected = command;
    }
};

test "palette cancellation and dispatch notify exactly once while owner context is alive" {
    try initGtk();
    const Exit = enum { before_show, stop_search, window_close, window_destroy, parent_destroy, activate, row_activate, reentrant_cancel, parent_cancel };
    for (std.enums.values(Exit)) |exit| {
        const parent = c.gtk_window_new().?;
        const parent_win = u.cast(c.GtkWindow, parent);
        _ = c.g_object_ref(parent);
        defer c.g_object_unref(parent);
        defer c.gtk_window_destroy(parent_win);
        c.gtk_window_present(parent_win);
        try waitMapped(parent);
        var owner: PaletteOwner = .{};
        defer if (owner.palette) |p| p.close();
        const palette = try Palette.create(parent, &owner, &PaletteOwner.onCommand, &PaletteOwner.onClosed);
        owner.palette = palette;
        // Keep signal senders alive beyond Palette, as accessibility may do.
        const window = palette.window;
        const search = palette.search;
        const list = palette.list;
        const row = palette.rows[@backingInt(Command.save_as)];
        for ([_]u.W{ window, search, list, u.cast(c.GtkWidget, row) }) |object| _ = c.g_object_ref(object);
        defer for ([_]u.W{ window, search, list, u.cast(c.GtkWidget, row) }) |object| c.g_object_unref(object);
        owner.window = window;
        if (exit != .before_show) {
            palette.show();
            try waitMapped(window);
        }
        try testing.expect(c.gtk_window_get_modal(u.cast(c.GtkWindow, window)) != 0);
        try testing.expectEqual(parent_win, c.gtk_window_get_transient_for(u.cast(c.GtkWindow, window)).?);
        // Empty results cannot dispatch, even when the entry emits activate.
        c.gtk_editable_set_text(u.cast(c.GtkEditable, search), "zzzzzzzzzzzz");
        c.g_signal_emit_by_name(search, "activate");
        try testing.expect(owner.palette != null);
        try testing.expectEqual(@as(usize, 0), owner.closed);
        try testing.expectEqual(@as(usize, 0), owner.dispatched);
        c.gtk_editable_set_text(u.cast(c.GtkEditable, search), "save-as");
        try testing.expectEqual(row, c.gtk_list_box_get_selected_row(u.cast(c.GtkListBox, list)).?);
        switch (exit) {
            .before_show => palette.close(),
            .stop_search => c.g_signal_emit_by_name(search, "stop-search"),
            .window_close => c.gtk_window_close(u.cast(c.GtkWindow, window)),
            .window_destroy => c.gtk_window_destroy(u.cast(c.GtkWindow, window)),
            .parent_destroy => c.gtk_window_destroy(parent_win),
            .activate => c.g_signal_emit_by_name(search, "activate"),
            .row_activate => c.g_signal_emit_by_name(list, "row-activated", row),
            .reentrant_cancel => {
                owner.cancel_reentrantly = true;
                c.g_signal_emit_by_name(search, "activate");
            },
            .parent_cancel => {
                owner.destroy_parent_on_close = parent_win;
                c.g_signal_emit_by_name(search, "activate");
            },
        }
        try testing.expect(owner.palette == null);
        try testing.expectEqual(@as(usize, 1), owner.closed);
        const dispatches: usize = if (exit == .activate or exit == .row_activate) 1 else 0;
        try testing.expectEqual(dispatches, owner.dispatched);
        if (dispatches != 0) try testing.expectEqual(Command.save_as, owner.selected.?);
        try testing.expect(!owner.violation);
        // A logically dead owner remains allocated as a tripwire for late callbacks.
        owner.alive = false;
        c.g_signal_emit_by_name(search, "activate");
        c.g_signal_emit_by_name(search, "stop-search");
        c.g_signal_emit_by_name(list, "row-activated", row);
        c.gtk_window_destroy(parent_win);
        drain();
        try testing.expectEqual(@as(usize, 1), owner.closed);
        try testing.expectEqual(dispatches, owner.dispatched);
        try testing.expect(!owner.violation);
    }
}
