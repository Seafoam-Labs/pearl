//! Display-backed tests. Run through tests/widgets.py, never the headless test step.
const std = @import("std");
const testing = std.testing;
const u = @import("c.zig");
const c = u.c;
const Document = @import("document.zig").Document;
const editor = @import("editor/view.zig");
const EditorView = editor.EditorView;
test {
    _ = @import("workspace/explorer_widget_test.zig");
    _ = @import("workspace/search_widget_test.zig");
    _ = @import("workbench/dock_widget_test.zig");
    _ = @import("workbench/workspace_picker_test.zig");
    _ = @import("workspace/explorer_watch.zig");
}
const Palette = @import("workbench/palette.zig").Palette;
const Command = @import("workbench/palette.zig").Command;

test {
    _ = @import("editor/projection_test.zig");
    _ = @import("editor/excerpt_editor_tests.zig");
}

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
        const buffer = view.buffer;
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
        try testing.expectEqual(buffer, c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, widget)).?);
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
        // Canonical callbacks must also be gone while the document is still live.
        c.gtk_text_buffer_set_text(document.buffer, "canonical only", -1);
        try testing.expectEqual(@as(c_int, 0), c.gtk_text_buffer_get_char_count(buffer));
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

const FocusOwner = struct {
    active: ?*EditorView = null,
    fn enter(view: *EditorView) void {
        const self = u.cast(FocusOwner, view.focus_context.?);
        self.active = view;
        // Bridges are in place before owner routing/status observers run.
        var local: c.GtkTextIter = undefined;
        var canonical: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_mark(view.buffer, &local, c.gtk_text_buffer_get_insert(view.buffer));
        c.gtk_text_buffer_get_iter_at_mark(view.document.buffer, &canonical, c.gtk_text_buffer_get_insert(view.document.buffer));
        std.debug.assert(c.gtk_text_iter_get_offset(&local) == c.gtk_text_iter_get_offset(&canonical));
    }
};

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

test "independent rendered buffers preserve directed selections, focus routing and scroll" {
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
    try testing.expect(first.focus_controller != null and second.focus_controller != null);
    try testing.expect(first.buffer != second.buffer and first.buffer != document.buffer);
    try testing.expectEqual(first.buffer, c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, first.widget)).?);
    try testing.expectEqual(second.buffer, c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, second.widget)).?);
    try expectSelection(first.buffer, 1, 4);
    try expectSelection(second.buffer, 12, 8);
    var owner: FocusOwner = .{};
    first.focus_context = &owner;
    first.on_focus = &FocusOwner.enter;
    second.focus_context = &owner;
    second.on_focus = &FocusOwner.enter;

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
    try testing.expectEqual(first, owner.active.?);
    select(first.buffer, 6, 2);
    try focus(win, second.widget);
    try expectSelection(document.buffer, 12, 8);
    try testing.expectEqual(second, owner.active.?);
    select(second.buffer, 20, 20);
    try focus(win, first.widget);
    try expectSelection(document.buffer, 6, 2);
    try focus(win, second.widget);
    try expectSelection(document.buffer, 20, 20);
    // Navigation from another control must explicitly adopt the destination.
    try testing.expect(c.gtk_widget_grab_focus(outside) != 0);
    select(document.buffer, 30, 25);
    first.syncSelectionFromDocument();
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
    try expectSelection(first.buffer, 30, 25);
    second.restoreSelection();
    try expectSelection(second.buffer, 20, 20);
    // Actual GtkTextView buffers simultaneously retain different visible marks.
    try expectSelection(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, first.widget)).?, 30, 25);
    try expectSelection(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, second.widget)).?, 20, 20);
    drain();
    for (first_axes, second_axes) |a, b| {
        try testing.expectApproxEqAbs(@as(f64, 40), c.gtk_adjustment_get_value(a), 0.01);
        try testing.expectApproxEqAbs(@as(f64, 160), c.gtk_adjustment_get_value(b), 0.01);
    }
    try testing.expectEqual(revision, document.revision);
    try testing.expect(!document.dirty());
    try testing.expectEqual(can_undo, c.gtk_text_buffer_get_can_undo(document.buffer));
}

fn expectViewText(view: *EditorView, expected: []const u8) !void {
    const text = u.bufferText(view.buffer);
    defer u.a.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "native text view typing backspace and clipboard paste use canonical history" {
    try initGtk();
    const document = try Document.create(5, null);
    defer document.destroy();
    const first = try EditorView.create(document);
    defer first.destroy();
    const second = try EditorView.create(document);
    defer second.destroy();
    const window = c.gtk_window_new().?;
    const win = u.cast(c.GtkWindow, window);
    defer c.gtk_window_destroy(win);
    const panes = u.box(true, 0);
    c.gtk_window_set_child(win, panes);
    u.append(panes, first.page);
    u.append(panes, second.page);
    c.gtk_window_present(win);
    try waitMapped(first.widget);
    try waitMapped(second.widget);
    try focus(win, first.widget);
    c.g_signal_emit_by_name(first.widget, "insert-at-cursor", @as([*:0]const u8, "aé"));
    try expectViewText(first, "aé");
    try expectViewText(second, "aé");
    try testing.expect(!first.projection.user_action);
    try testing.expect(c.gtk_text_buffer_get_can_undo(document.buffer) != 0);
    c.gtk_text_buffer_undo(document.buffer);
    try expectViewText(first, "");
    try expectViewText(second, "");
    c.gtk_text_buffer_redo(document.buffer);
    try expectViewText(first, "aé");
    try focus(win, second.widget);
    c.g_signal_emit_by_name(second.widget, "backspace");
    try expectViewText(first, "a");
    try expectViewText(second, "a");
    c.gtk_text_buffer_set_enable_undo(document.buffer, 0);
    c.gtk_text_buffer_set_enable_undo(document.buffer, 1);
    const clipboard = c.gtk_widget_get_clipboard(second.widget).?;
    c.gdk_clipboard_set_text(clipboard, "🌱\npaste");
    c.g_signal_emit_by_name(second.widget, "paste-clipboard");
    const deadline = c.g_get_monotonic_time() + 5_000_000;
    while (c.gtk_text_buffer_get_char_count(document.buffer) != 8) {
        if (c.g_get_monotonic_time() >= deadline) return error.ClipboardPasteTimedOut;
        drain();
        c.g_usleep(1_000);
    }
    try expectViewText(first, "a🌱\npaste");
    try expectViewText(second, "a🌱\npaste");
    try testing.expect(!second.projection.user_action);
    c.gtk_text_buffer_undo(document.buffer);
    try expectViewText(first, "a");
    try expectViewText(second, "a");
    try testing.expectEqual(@as(c_int, 0), c.gtk_text_buffer_get_can_undo(document.buffer));
    document.loading = true;
    first.setEditable(false);
    second.setEditable(false);
    for ([_]*EditorView{ first, second }) |view| {
        try testing.expectEqual(@as(c_int, 0), c.gtk_text_view_get_editable(u.cast(c.GtkTextView, view.widget)));
        c.g_signal_emit_by_name(view.widget, "insert-at-cursor", @as([*:0]const u8, "blocked"));
        try expectViewText(view, "a");
    }
    document.loading = false;
    first.setEditable(true);
    second.setEditable(true);
    c.g_signal_emit_by_name(second.widget, "insert-at-cursor", @as([*:0]const u8, "!"));
    try expectViewText(first, "a!");
    try expectViewText(second, "a!");
}

fn hasStyledTag(buffer: *c.GtkTextBuffer, offset: c_int, property: [*:0]const u8) bool {
    var at: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(buffer, &at, offset);
    const tags = c.gtk_text_iter_get_tags(&at);
    defer c.g_slist_free(tags);
    var next = tags;
    while (next != null) : (next = next.*.next) {
        var set: c_int = 0;
        c.g_object_get(next.*.data, property, &set, @as(?*anyopaque, null));
        if (set != 0) return true;
    }
    return false;
}

fn ensureHighlight(buffer: *c.GtkTextBuffer) void {
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_bounds(buffer, &start, &end);
    c.gtk_source_buffer_ensure_highlight(u.cast(c.GtkSourceBuffer, buffer), &start, &end);
}

test "mirror source views render syntax search and spelling and follow theme changes" {
    try initGtk();
    const document = try Document.create(4, null);
    defer document.destroy();
    c.gtk_text_buffer_set_text(document.buffer, "int main(void) { return 1; }\n// spelling\n", -1);
    const source = u.cast(c.GtkSourceBuffer, document.buffer);
    const language = c.gtk_source_language_manager_get_language(c.gtk_source_language_manager_get_default(), "c").?;
    const manager = c.gtk_source_style_scheme_manager_get_default();
    const scheme = c.gtk_source_style_scheme_manager_get_scheme(manager, "Adwaita").?;
    c.gtk_source_buffer_set_language(source, language);
    c.gtk_source_buffer_set_style_scheme(source, scheme);
    c.gtk_source_search_settings_set_search_text(document.search_settings, "main");
    const first = try EditorView.create(document);
    defer first.destroy();
    const second = try EditorView.create(document);
    defer second.destroy();
    const window = c.gtk_window_new().?;
    const win = u.cast(c.GtkWindow, window);
    defer c.gtk_window_destroy(win);
    const panes = u.box(true, 0);
    c.gtk_window_set_child(win, panes);
    u.append(panes, first.page);
    u.append(panes, second.page);
    c.gtk_window_present(win);
    try waitMapped(first.widget);
    try waitMapped(second.widget);

    for ([_]*EditorView{ first, second }) |view| {
        const mirror_source = u.cast(c.GtkSourceBuffer, view.buffer);
        try testing.expectEqual(language, c.gtk_source_buffer_get_language(mirror_source).?);
        try testing.expectEqual(scheme, c.gtk_source_buffer_get_style_scheme(mirror_source).?);
        ensureHighlight(view.buffer);
        try testing.expect(hasStyledTag(view.buffer, 0, "foreground-set"));
        // Search is evaluated on EACH rendered buffer, using shared settings.
        var at: c.GtkTextIter = undefined;
        var start: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_start_iter(view.buffer, &at);
        try testing.expect(c.gtk_source_search_context_forward(view.projection.search, &at, &start, &end, null) != 0);
        try testing.expectEqual(@as(c_int, 4), c.gtk_text_iter_get_offset(&start));
        try testing.expect(hasStyledTag(view.buffer, 4, "background-set"));
    }
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(document.buffer, &start, 30);
    c.gtk_text_buffer_get_iter_at_offset(document.buffer, &end, 38);
    c.gtk_text_buffer_apply_tag(document.buffer, document.tag, &start, &end);
    for ([_]*EditorView{ first, second }) |view| try testing.expect(hasStyledTag(view.buffer, 30, "underline-set"));

    const dark = c.gtk_source_style_scheme_manager_get_scheme(manager, "Adwaita-dark").?;
    c.gtk_source_buffer_set_style_scheme(source, dark);
    c.gtk_source_buffer_set_highlight_syntax(source, 0);
    c.gtk_source_search_context_set_highlight(document.search, 0);
    for ([_]*EditorView{ first, second }) |view| {
        try testing.expectEqual(dark, c.gtk_source_buffer_get_style_scheme(u.cast(c.GtkSourceBuffer, view.buffer)).?);
        try testing.expectEqual(@as(c_int, 0), c.gtk_source_buffer_get_highlight_syntax(u.cast(c.GtkSourceBuffer, view.buffer)));
        try testing.expectEqual(@as(c_int, 0), c.gtk_source_search_context_get_highlight(view.projection.search));
    }
    c.gtk_source_buffer_set_highlight_syntax(source, 1);
    c.gtk_source_search_context_set_highlight(document.search, 1);
    c.gtk_source_search_settings_set_search_text(document.search_settings, "return");
    select(second.buffer, 0, 0);
    c.gtk_text_buffer_insert_at_cursor(second.buffer, "// prefix\n", -1);
    for ([_]*EditorView{ first, second }) |view| {
        ensureHighlight(view.buffer);
        var at: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_start_iter(view.buffer, &at);
        try testing.expect(c.gtk_source_search_context_forward(view.projection.search, &at, &start, &end, null) != 0);
        try testing.expectEqual(@as(c_int, 27), c.gtk_text_iter_get_offset(&start));
        try testing.expect(hasStyledTag(view.buffer, 27, "background-set"));
    }
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
