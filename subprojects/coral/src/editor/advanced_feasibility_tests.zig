//! M0 mechanism proofs, NOT production multicursor/folding/inlay/completion UI.
//! Display-backed import: test { _ = @import("editor/advanced_feasibility_tests.zig"); }
//! Inlays/ghost text use non-reflowing overlays, never inserted mirror characters:
//! the current projection requires a 1:1 canonical character-offset space.
const std = @import("std");
const t = std.testing;
const u = @import("../c.zig");
const c = u.c;
const Document = @import("../document.zig").Document;
const Projection = @import("projection.zig").Projection;
const tx = @import("transactions.zig");
const History = @import("history.zig").History;

const Pair = struct {
    document: *Document,
    panes: [2]*Projection,
    widgets: [2]*c.GtkWidget,
    overlays: [2]*c.GtkOverlay,
    window: *c.GtkWindow,

    fn init(text: [:0]const u8) !Pair {
        if (c.gtk_init_check() == 0) return error.SkipZigTest;
        const document = try Document.create(980, null);
        errdefer document.destroy();
        c.gtk_text_buffer_set_enable_undo(document.buffer, 0);
        c.gtk_text_buffer_set_text(document.buffer, text, -1);
        c.gtk_text_buffer_set_enable_undo(document.buffer, 1);
        c.gtk_text_buffer_set_modified(document.buffer, 0);
        const first = try Projection.create(document);
        errdefer first.destroy();
        const second = try Projection.create(document);
        const panes = [2]*Projection{ first, second };
        const window = u.cast(c.GtkWindow, c.gtk_window_new().?);
        const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12).?;
        c.gtk_window_set_child(window, box);
        c.gtk_window_set_default_size(window, 640, 180);
        var widgets: [2]*c.GtkWidget = undefined;
        var overlays: [2]*c.GtkOverlay = undefined;
        for (panes, &widgets, &overlays) |pane, *widget, *overlay| {
            widget.* = c.gtk_source_view_new_with_buffer(u.cast(c.GtkSourceBuffer, pane.buffer)).?;
            c.gtk_widget_set_hexpand(widget.*, 1);
            c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, widget.*), 1);
            overlay.* = u.cast(c.GtkOverlay, c.gtk_overlay_new().?);
            c.gtk_overlay_set_child(overlay.*, widget.*);
            c.gtk_box_append(u.cast(c.GtkBox, box), u.cast(c.GtkWidget, overlay.*));
        }
        c.gtk_window_present(window);
        settle();
        return .{ .document = document, .panes = panes, .widgets = widgets, .overlays = overlays, .window = window };
    }
    fn deinit(self: *Pair) void {
        c.gtk_window_destroy(self.window);
        for (self.panes) |pane| pane.destroy();
        self.document.destroy();
        settle();
    }
    fn target(self: *Pair) tx.Target {
        const d = self.document;
        return .{ .id = d.id, .buffer = d.buffer, .revision = &d.revision, .expected_revision = d.revision };
    }
    fn expect(self: *Pair, expected: []const u8) !void {
        try expectText(self.document.buffer, expected);
        for (self.panes) |pane| try expectText(pane.buffer, expected);
    }
};
fn settle() void {
    for (0..4) |_| {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        c.g_usleep(10000);
    }
}
fn at(buffer: *c.GtkTextBuffer, offset: c_int) c.GtkTextIter {
    var iter: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(buffer, &iter, offset);
    return iter;
}
fn expectText(buffer: *c.GtkTextBuffer, expected: []const u8) !void {
    const bytes = u.bufferText(buffer);
    defer u.a.free(bytes);
    try t.expectEqualStrings(expected, bytes);
}
fn markOffset(buffer: *c.GtkTextBuffer, mark: *c.GtkTextMark) c_int {
    var iter: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_mark(buffer, &iter, mark);
    return c.gtk_text_iter_get_offset(&iter);
}

// Multiple selections/caret painting, IME composition, rectangular selection and
// overlapping edit normalization still need an input/controller implementation.
test "M0 multicursor mechanism: pane-local marks one canonical action one native undo" {
    var pair = try Pair.init("ab cd");
    defer pair.deinit();
    const buffer = pair.panes[0].buffer;
    const a = at(buffer, 1);
    const b = at(buffer, 4);
    const carets = [2]*c.GtkTextMark{
        c.gtk_text_buffer_create_mark(buffer, null, &a, 0).?,
        c.gtk_text_buffer_create_mark(buffer, null, &b, 0).?,
    };
    defer for (carets) |mark| c.gtk_text_buffer_delete_mark(buffer, mark);
    const other = at(pair.panes[1].buffer, 0);
    c.gtk_text_buffer_place_cursor(pair.panes[1].buffer, &other);
    var edits: [2]tx.Replacement = undefined;
    for (carets, &edits) |mark, *edit| {
        const offset: usize = @intCast(markOffset(buffer, mark));
        edit.* = .{ .start = offset, .end = offset, .text = "Ω" }; // ASCII base offsets.
    }
    var plan = try tx.prepare(t.allocator, &.{.{ .target = pair.target(), .replacements = &edits }}, .{});
    defer plan.deinit();
    try plan.commit(&.{pair.target()});
    try pair.expect("aΩb cΩd");
    try t.expectEqual(@as(c_int, 2), markOffset(buffer, carets[0]));
    try t.expectEqual(@as(c_int, 6), markOffset(buffer, carets[1]));
    try t.expectEqual(@as(c_int, 0), markOffset(pair.panes[1].buffer, c.gtk_text_buffer_get_insert(pair.panes[1].buffer).?));
    c.gtk_text_buffer_undo(pair.document.buffer);
    try pair.expect("ab cd");
    try t.expectEqual(@as(c_int, 0), c.gtk_text_buffer_get_can_undo(pair.document.buffer));
    c.gtk_text_buffer_redo(pair.document.buffer);
    try pair.expect("aΩb cΩd");
}

// Invisible ranges are local, tag properties are shared. Production needs
// pane-owned tags plus explicit copy/search/navigation/unfold policies.
test "M0 folding mechanism: local invisible range retains canonical offsets and hidden text" {
    var pair = try Pair.init("a\nfold\nz");
    defer pair.deinit();
    const buffer = pair.panes[0].buffer;
    const start = at(buffer, 2);
    const end = at(buffer, 7);
    const tag = c.gtk_text_buffer_create_tag(buffer, null, "invisible", @as(c_int, 1), @as(?*anyopaque, null));
    c.gtk_text_buffer_apply_tag(buffer, tag, &start, &end);
    const revision = pair.document.revision;
    settle();
    const all_start = at(buffer, 0);
    const all_end = at(buffer, 8);
    const visible = c.gtk_text_buffer_get_text(buffer, &all_start, &all_end, 0);
    defer c.g_free(visible);
    try t.expectEqualStrings("a\nz", std.mem.span(visible));
    const other = at(pair.panes[1].buffer, 3);
    const canonical = at(pair.document.buffer, 3);
    try t.expect(c.gtk_text_iter_has_tag(&other, tag) == 0);
    try t.expect(c.gtk_text_iter_has_tag(&canonical, tag) == 0);
    c.gtk_text_buffer_select_range(buffer, &end, &start);
    try t.expectEqual(@as(c_int, 7), markOffset(buffer, c.gtk_text_buffer_get_insert(buffer).?));
    var plan = try tx.prepare(t.allocator, &.{.{ .target = pair.target(), .replacements = &.{} }}, .{});
    defer plan.deinit();
    try t.expectEqualStrings("a\nfold\nz", plan.before(0));
    try pair.expect("a\nfold\nz");
    try t.expectEqual(revision, pair.document.revision);
    try t.expect(!pair.document.dirty());
    c.gtk_text_buffer_remove_tag(buffer, tag, &start, &end);
    try pair.expect("a\nfold\nz");
}

fn positionOverlay(overlay: *c.GtkOverlay, widget: *c.GtkWidget, buffer: *c.GtkTextBuffer, mark: *c.GtkTextMark, label: *c.GtkWidget, add: bool) void {
    const view = u.cast(c.GtkTextView, widget);
    var iter: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_mark(buffer, &iter, mark);
    var rect: c.GdkRectangle = undefined;
    c.gtk_text_view_get_iter_location(view, &iter, &rect);
    var x: c_int = 0;
    var y: c_int = 0;
    c.gtk_text_view_buffer_to_window_coords(view, c.GTK_TEXT_WINDOW_WIDGET, rect.x, rect.y, &x, &y);
    // GtkOverlay owns these children and has an explicit remove lifecycle. The
    // controller must reposition/hide them on scroll, wrap and font changes.
    c.gtk_widget_set_halign(label, c.GTK_ALIGN_START);
    c.gtk_widget_set_valign(label, c.GTK_ALIGN_START);
    c.gtk_widget_set_can_target(label, 0);
    c.gtk_widget_set_margin_start(label, @max(0, x));
    c.gtk_widget_set_margin_top(label, @max(0, y));
    if (add) c.gtk_overlay_add_overlay(overlay, label);
}

// Overlay feasibility is NOT inline layout/reflow feasibility. True occupied
// inline width requires a custom renderer or explicit presentation offset map;
// inserting a child anchor in the current projection breaks its 1:1 contract.
test "M0 inlay mechanism: mark anchored overlay tracks edits without canonical objects" {
    var pair = try Pair.init("name value");
    defer pair.deinit();
    const buffer = pair.panes[0].buffer;
    const iter = at(buffer, 4);
    const mark = c.gtk_text_buffer_create_mark(buffer, null, &iter, 0).?;
    defer c.gtk_text_buffer_delete_mark(buffer, mark);
    const label = c.gtk_label_new(": type").?;
    const revision = pair.document.revision;
    positionOverlay(pair.overlays[0], pair.widgets[0], buffer, mark, label, true);
    settle();
    try t.expect(c.gtk_widget_get_mapped(label) != 0);
    try t.expect(c.gtk_widget_get_width(label) > 0);
    try t.expectEqual(revision, pair.document.revision);
    try t.expect(!pair.document.dirty());
    var insertion = at(pair.document.buffer, 0);
    c.gtk_text_buffer_insert(pair.document.buffer, &insertion, "Ω", -1);
    try t.expectEqual(@as(c_int, 5), markOffset(buffer, mark));
    positionOverlay(pair.overlays[0], pair.widgets[0], buffer, mark, label, false);
    settle();
    try pair.expect("Ωname value");
    var plan = try tx.prepare(t.allocator, &.{.{ .target = pair.target(), .replacements = &.{} }}, .{});
    defer plan.deinit();
    try t.expectEqualStrings("Ωname value", plan.before(0));
    c.gtk_overlay_remove_overlay(pair.overlays[0], label);
}

// Acceptance uses the target captured when the suggestion was generated. A
// production controller must dismiss/recompute on intervening revisions, handle
// focus/IME/accessibility, and implement ghost text reflow separately.
test "M0 suggested text mechanism: dismiss is inert accept is checked grouped undo with ABA rejection" {
    var pair = try Pair.init("let x = ");
    defer pair.deinit();
    const buffer = pair.panes[0].buffer;
    const iter = at(buffer, 8);
    const mark = c.gtk_text_buffer_create_mark(buffer, null, &iter, 0).?;
    defer c.gtk_text_buffer_delete_mark(buffer, mark);
    var history = History.init(t.allocator, .{});
    defer history.deinit();
    const label = c.gtk_label_new("42;").?;
    const original = pair.target();
    positionOverlay(pair.overlays[0], pair.widgets[0], buffer, mark, label, true);
    settle();
    try t.expect(c.gtk_widget_get_mapped(label) != 0);
    c.gtk_overlay_remove_overlay(pair.overlays[0], label);
    try pair.expect("let x = ");
    try t.expectEqual(original.expected_revision, pair.document.revision);
    try t.expectEqual(@as(usize, 0), history.records.items.len);
    try t.expect(!pair.document.dirty());
    const changes = [_]tx.Change{.{ .target = original, .replacements = &.{.{ .start = 8, .end = 8, .text = "42;" }} }};
    try history.perform("Accept suggestion", &changes);
    try pair.expect("let x = 42;");
    try history.undo(&.{pair.target()});
    try pair.expect("let x = ");
    try t.expect(pair.document.revision > original.expected_revision);
    try t.expectError(error.StaleRevision, tx.prepare(t.allocator, &changes, .{}));
    try history.redo(&.{pair.target()});
    try pair.expect("let x = 42;");
}
