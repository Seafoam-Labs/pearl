//! Parent-owned widget root imports this file; no native harness is run here.
const std = @import("std");
const testing = std.testing;
const u = @import("../c.zig");
const c = u.c;
const View = @import("search_view.zig").View;
// Controller routing fixtures require the full App module graph and run through
// tests/search.py's search-routing-checks hook, not this standalone widget root.

const Observer = struct {
    changes: usize = 0,
    activated: ?usize = null,
    refreshes: usize = 0,
    closes: usize = 0,
    fn changed(data: *anyopaque) void {
        u.cast(Observer, data).changes += 1;
    }
    fn activate(data: *anyopaque, index: usize) void {
        u.cast(Observer, data).activated = index;
    }
    fn refresh(data: *anyopaque) void {
        u.cast(Observer, data).refreshes += 1;
    }
    fn close(data: *anyopaque) void {
        u.cast(Observer, data).closes += 1;
    }
};
fn key(view: *View, keyval: c_uint) c_int {
    var handled: c_int = 0;
    c.g_signal_emit_by_name(view.keys, "key-pressed", keyval, @as(c_uint, 0), @as(c.GdkModifierType, 0), &handled);
    return handled;
}
fn drain() void {
    for (0..256) |_| if (c.g_main_context_iteration(null, 0) == 0) break;
}

test "native search entry arrows skip root/file headers and activate result identities" {
    try testing.expect(c.gtk_init_check() != 0);
    const window = c.gtk_window_new().?;
    const root = u.box(false, 0);
    c.gtk_window_set_child(u.cast(c.GtkWindow, window), root);
    var observer: Observer = .{};
    var view = View.init(root, &observer, &Observer.changed, &Observer.activate, &Observer.refresh, &Observer.close);
    view.attach();
    defer view.deinit();
    defer {
        c.gtk_window_destroy(u.cast(c.GtkWindow, window));
        drain();
    }
    view.append("Root A", null);
    view.append("same-name.txt", null);
    view.append("1:3 — βeta", 17);
    view.append("Root B", null);
    view.append("same-name.txt", null);
    view.append("9:2 — βeta", 23);
    view.selectFirst();
    try testing.expectEqual(@as(c_uint, 2), c.gtk_single_selection_get_selected(view.list.selection));
    try testing.expectEqual(@as(c_int, 1), key(&view, c.GDK_KEY_Down));
    c.g_signal_emit_by_name(view.entry, "activate");
    try testing.expectEqual(@as(?usize, 23), observer.activated);
    try testing.expectEqual(@as(c_int, 1), key(&view, c.GDK_KEY_Down));
    c.g_signal_emit_by_name(view.entry, "activate");
    try testing.expectEqual(@as(?usize, 17), observer.activated);
    _ = key(&view, c.GDK_KEY_Up);
    try testing.expectEqual(@as(c_uint, 5), c.gtk_single_selection_get_selected(view.list.selection));
    view.clear();
    observer.activated = null;
    _ = key(&view, c.GDK_KEY_Down);
    c.g_signal_emit_by_name(view.entry, "activate");
    try testing.expect(observer.activated == null);
    view.setQuery("quiet UTF-8 β");
    try testing.expectEqual(@as(usize, 0), observer.changes);
    c.gtk_editable_set_text(u.cast(c.GtkEditable, view.entry), "user query");
    try testing.expect(observer.changes > 0);
    c.g_signal_emit_by_name(view.refresh_button, "clicked");
    try testing.expectEqual(@as(usize, 1), observer.refreshes);
    try testing.expectEqual(@as(c_int, 1), key(&view, c.GDK_KEY_Escape));
    c.g_signal_emit_by_name(view.close_button, "clicked");
    try testing.expectEqual(@as(usize, 2), observer.closes);
}

test "workspace search result rows remain virtualized and clear without retained identities" {
    try testing.expect(c.gtk_init_check() != 0);
    const window = c.gtk_window_new().?;
    const root = u.box(false, 0);
    c.gtk_window_set_child(u.cast(c.GtkWindow, window), root);
    c.gtk_window_set_default_size(u.cast(c.GtkWindow, window), 480, 320);
    var observer: Observer = .{};
    var view = View.init(root, &observer, &Observer.changed, &Observer.activate, &Observer.refresh, &Observer.close);
    view.attach();
    defer view.deinit();
    defer {
        c.gtk_window_destroy(u.cast(c.GtkWindow, window));
        drain();
    }
    for (0..1024) |index| {
        view.append("root / file", null);
        view.append("    1:1 bounded preview", index);
    }
    view.show(.text);
    c.gtk_window_present(u.cast(c.GtkWindow, window));
    const deadline = c.g_get_monotonic_time() + 5_000_000;
    while (c.gtk_widget_get_mapped(view.list.widget) == 0) {
        if (c.g_get_monotonic_time() >= deadline) return error.MappingTimedOut;
        drain();
        c.g_usleep(1000);
    }
    drain();
    try testing.expect(view.list.live_widgets > 0 and view.list.peak_widgets < 256);
    view.clear();
    try testing.expectEqual(@as(usize, 0), view.rows.items.len);
    try testing.expectEqual(@as(c_uint, 0), c.g_list_model_get_n_items(u.cast(c.GListModel, view.list.strings)));
    observer.activated = null;
    c.g_signal_emit_by_name(view.entry, "activate");
    try testing.expect(observer.activated == null);
}
