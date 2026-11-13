//! Import from the parent-owned widget test root. No filesystem/workers needed.
const std = @import("std");
const t = std.testing;
const u = @import("../c.zig");
const c = u.c;
const Dock = @import("dock.zig").Controller;
const layout = @import("layout.zig");

fn settle() void {
    const until = c.g_get_monotonic_time() + 180_000;
    while (c.g_get_monotonic_time() < until) {
        for (0..256) |_| if (c.g_main_context_iteration(null, 0) == 0) break;
        c.g_usleep(1000);
    }
}
const Fixture = struct {
    window: u.W = undefined,
    editor: u.W = undefined,
    search: u.W = undefined,
    source_control: u.W = undefined,
    terminal: u.W = undefined,
    agent: u.W = undefined,
    dock: Dock = undefined,
    fn init(self: *Fixture) !void {
        try t.expect(c.gtk_init_check() != 0);
        self.window = c.gtk_window_new().?;
        self.editor = c.gtk_text_view_new().?;
        c.gtk_text_buffer_set_text(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, self.editor)), "preserve π🙂 selection", -1);
        self.dock = Dock.init(self.editor);
        u.append(self.dock.explorer_slot, u.button("Real explorer slot"));
        self.search = c.gtk_entry_new().?;
        u.append(self.dock.search_slot, self.search);
        self.source_control = c.gtk_entry_new().?;
        u.append(self.dock.source_control_slot, self.source_control);
        self.terminal = c.gtk_entry_new().?;
        u.append(self.dock.terminal_slot, self.terminal);
        self.agent = c.gtk_entry_new().?;
        u.append(self.dock.agent_slot, self.agent);
        c.gtk_window_set_child(u.cast(c.GtkWindow, self.window), self.dock.root);
        self.dock.attach();
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, self.window), 960, 640);
        c.gtk_window_present(u.cast(c.GtkWindow, self.window));
        settle();
        // Wayland compositors may override the initial configure. Request the
        // test's wide allocation after mapping, as the window-resize hook does.
        self.resize(1280, 800);
    }
    fn resize(self: *Fixture, width: c_int, height: c_int) void {
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, self.window), width, height);
        settle();
    }
    fn deinit(self: *Fixture) void {
        self.dock.shutdown();
        c.gtk_window_destroy(u.cast(c.GtkWindow, self.window));
        settle();
    }
};

test "docks move and hide without replacing editor parent buffer or directed selection" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const parent = c.gtk_widget_get_parent(f.editor);
    const buffer = c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, f.editor));
    var insertion: c.GtkTextIter = undefined;
    var bound: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(buffer, &insertion, 11);
    c.gtk_text_buffer_get_iter_at_offset(buffer, &bound, 3);
    c.gtk_text_buffer_select_range(buffer, &insertion, &bound);
    for ([_]layout.Dock{ .right, .bottom, .left }) |side| {
        f.dock.show(.explorer);
        f.dock.move(side);
        f.dock.hide(.explorer);
        settle();
        for (f.dock.frames) |frame| try t.expect(c.gtk_widget_get_visible(frame) == 0);
        try t.expect(c.gtk_widget_get_parent(f.editor) == parent);
        try t.expect(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, f.editor)) == buffer);
        c.gtk_text_buffer_get_iter_at_mark(buffer, &insertion, c.gtk_text_buffer_get_insert(buffer));
        c.gtk_text_buffer_get_iter_at_mark(buffer, &bound, c.gtk_text_buffer_get_selection_bound(buffer));
        try t.expectEqual(@as(c_int, 11), c.gtk_text_iter_get_offset(&insertion));
        try t.expectEqual(@as(c_int, 3), c.gtk_text_iter_get_offset(&bound));
    }
}

test "compact allocations preserve desired wide visibility sizes and placements" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const wanted: layout.State = .{ .explorer = .right, .search = .bottom, .search_visible = true, .active = .search, .left_size = 410, .right_size = 390, .bottom_size = 260 };
    f.dock.restore(wanted);
    settle();
    try t.expect(f.dock.effective[0] and f.dock.effective[1]);
    f.resize(650, 520);
    try t.expect(f.dock.compact);
    try t.expect(!f.dock.effective[0] and f.dock.effective[1]);
    try t.expectEqualDeep(wanted, f.dock.snapshot());
    f.resize(1280, 800);
    try t.expect(!f.dock.compact);
    try t.expect(f.dock.effective[0] and f.dock.effective[1]);
    try t.expectEqualDeep(wanted, f.dock.snapshot());
    try t.expect(c.gtk_widget_get_width(f.editor) >= 240);
    try t.expect(c.gtk_widget_get_height(f.editor) >= 160);
}

test "same dock selects panels and picker overlays without resizing central editor" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.dock.restore(.{ .search = .left, .search_visible = true, .active = .search });
    settle();
    try t.expect(!f.dock.effective[0] and f.dock.effective[1]);
    const before = f.dock.snapshot();
    const width = c.gtk_widget_get_width(f.editor);
    const height = c.gtk_widget_get_height(f.editor);
    f.dock.presentPicker();
    _ = c.gtk_widget_grab_focus(f.search);
    settle();
    try t.expect(c.gtk_widget_get_parent(f.dock.search_slot) == f.dock.picker);
    try t.expect(c.gtk_overlay_get_measure_overlay(u.cast(c.GtkOverlay, f.dock.overlay), f.dock.picker) == 0);
    try t.expectEqual(width, c.gtk_widget_get_width(f.editor));
    try t.expectEqual(height, c.gtk_widget_get_height(f.editor));
    f.dock.dismissPicker();
    settle();
    try t.expectEqualDeep(before, f.dock.snapshot());
    try t.expect(c.gtk_widget_get_parent(f.dock.search_slot) == f.dock.hosts[0]);
    try t.expectEqual(width, c.gtk_widget_get_width(f.editor));
    f.dock.show(.explorer);
    try t.expect(f.dock.effective[0] and !f.dock.effective[1]);
}

test "moving focused search keeps focus after allocation without overriding editor focus" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.dock.show(.search);
    _ = c.gtk_widget_grab_focus(f.search);
    settle();
    for ([_]layout.Dock{ .right, .left, .bottom }) |side| {
        f.dock.move(side);
        settle();
        try t.expect(@import("dock.zig").inside(c.gtk_window_get_focus(u.cast(c.GtkWindow, f.window)), f.dock.search_slot));
    }
    f.dock.move(.right);
    _ = c.gtk_widget_grab_focus(f.editor);
    settle();
    try t.expect(c.gtk_window_get_focus(u.cast(c.GtkWindow, f.window)) == f.editor);
}

test "restored sizes clamp and shutdown disconnects retained GTK controllers" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.dock.restore(.{ .left_size = 0, .right_size = 65535, .bottom_size = 65535 });
    try layout.validate(f.dock.snapshot());
    try t.expectEqual(@as(u16, 120), f.dock.snapshot().left_size);
    try t.expectEqual(@as(u16, 1200), f.dock.snapshot().right_size);
    try t.expectEqual(@as(u16, 1000), f.dock.snapshot().bottom_size);
    const controller = f.dock.controllers[0];
    _ = c.g_object_ref(controller);
    defer c.g_object_unref(controller);
    f.dock.shutdown();
    try t.expectEqual(@as(c_uint, 0), f.dock.tick_id);
    try t.expectEqual(@as(usize, 0), f.dock.controller_count);
    try t.expect(c.gtk_event_controller_get_widget(controller) == null);
    c.g_signal_emit_by_name(controller, "pressed", @as(c_int, 1), @as(f64, 100), @as(f64, 100));
    try t.expect(!f.dock.dragging[0]);
}

test "source control dock moves hides and tabs without disturbing explorer/search or editor" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    // Default state keeps Source Control hidden while Explorer stays visible.
    try t.expect(!f.dock.effective[2]);
    try t.expect(c.gtk_widget_get_visible(f.dock.source_control_slot) == 0);
    const parent = c.gtk_widget_get_parent(f.editor);
    const buffer = c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, f.editor));
    f.dock.show(.source_control);
    settle();
    // Source Control shares the default left dock with Explorer: the active
    // panel wins the shared dock until the panel moves elsewhere.
    try t.expect(!f.dock.effective[0] and !f.dock.effective[1] and f.dock.effective[2]);
    try t.expect(f.dock.state.active == .source_control);
    for ([_]layout.Dock{ .right, .bottom, .left }) |side| {
        f.dock.move(side);
        settle();
        try t.expect(c.gtk_widget_get_parent(f.dock.source_control_slot) == f.dock.hosts[@backingInt(side)]);
        try t.expect(f.dock.effective[0] == (side != .left));
        try t.expect(f.dock.effective[2]);
        // The Source Control tab follows the panel; the other tabs stay put.
        for (f.dock.tabs, 0..) |tabs, i| {
            try t.expect(c.gtk_widget_get_visible(tabs[2]) == @intFromBool(i == @backingInt(side)));
            try t.expect(c.gtk_widget_get_visible(tabs[0]) == @intFromBool(i == @backingInt(f.dock.state.explorer)));
        }
        try t.expect(c.gtk_widget_get_parent(f.editor) == parent);
        try t.expect(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, f.editor)) == buffer);
    }
    f.dock.hide(.source_control);
    settle();
    try t.expect(!f.dock.effective[2]);
    try t.expect(c.gtk_widget_get_visible(f.dock.source_control_slot) == 0);
    // Explorer remains visible and becomes the active fallback.
    try t.expect(f.dock.effective[0] and f.dock.state.active == .explorer);
    for (f.dock.tabs) |tabs| try t.expect(c.gtk_widget_get_visible(tabs[2]) == 0);
}

test "three visible panels compact to the active one and restore desired state" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const wanted: layout.State = .{ .explorer = .left, .search = .bottom, .source_control = .right, .explorer_visible = true, .search_visible = true, .source_control_visible = true, .active = .source_control, .left_size = 300, .right_size = 310, .bottom_size = 250 };
    f.dock.restore(wanted);
    settle();
    try t.expect(f.dock.effective[0] and f.dock.effective[1] and f.dock.effective[2]);
    f.resize(650, 520);
    try t.expect(f.dock.compact);
    try t.expect(!f.dock.effective[0] and !f.dock.effective[1] and f.dock.effective[2]);
    try t.expectEqualDeep(wanted, f.dock.snapshot());
    f.dock.show(.search);
    settle();
    try t.expect(!f.dock.effective[0] and f.dock.effective[1] and !f.dock.effective[2]);
    f.resize(1280, 800);
    try t.expect(!f.dock.compact);
    try t.expect(f.dock.effective[0] and f.dock.effective[1] and f.dock.effective[2]);
    try t.expect(c.gtk_widget_get_width(f.editor) >= 240);
    try t.expect(c.gtk_widget_get_height(f.editor) >= 160);
}

test "three panels sharing one dock keep the active panel and hide fallbacks" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.dock.restore(.{ .explorer = .left, .search = .left, .source_control = .left, .explorer_visible = true, .search_visible = true, .source_control_visible = true, .active = .search });
    settle();
    try t.expect(!f.dock.effective[0] and f.dock.effective[1] and !f.dock.effective[2]);
    try t.expect(c.gtk_widget_get_parent(f.dock.source_control_slot) == f.dock.hosts[0]);
    f.dock.show(.source_control);
    settle();
    try t.expect(!f.dock.effective[0] and !f.dock.effective[1] and f.dock.effective[2]);
    f.dock.hide(.source_control);
    settle();
    // Fallback prefers the first visible other panel in rail order.
    try t.expect(f.dock.state.active == .explorer);
    try t.expect(f.dock.effective[0] and !f.dock.effective[1] and !f.dock.effective[2]);
    // Hiding Explorer falls back to the still-visible Search panel.
    f.dock.hide(.explorer);
    settle();
    try t.expect(f.dock.state.active == .search);
    try t.expect(!f.dock.effective[0] and f.dock.effective[1] and !f.dock.effective[2]);
    // Hiding the last visible panel keeps a nominal active panel without showing it.
    f.dock.hide(.search);
    settle();
    try t.expect(f.dock.state.active == .explorer);
    for (f.dock.frames) |frame| try t.expect(c.gtk_widget_get_visible(frame) == 0);
}

test "moving focused source control keeps focus after allocation without overriding editor focus" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.dock.show(.source_control);
    _ = c.gtk_widget_grab_focus(f.source_control);
    settle();
    for ([_]layout.Dock{ .right, .left, .bottom }) |side| {
        f.dock.move(side);
        settle();
        try t.expect(@import("dock.zig").inside(c.gtk_window_get_focus(u.cast(c.GtkWindow, f.window)), f.dock.source_control_slot));
    }
    f.dock.move(.right);
    _ = c.gtk_widget_grab_focus(f.editor);
    settle();
    try t.expect(c.gtk_window_get_focus(u.cast(c.GtkWindow, f.window)) == f.editor);
}

test "terminal defaults to a hidden bottom panel and preserves old sessions" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try t.expect(f.dock.state.terminal == .bottom);
    try t.expect(!f.dock.state.terminal_visible);
    try t.expect(!f.dock.effective[3]);
    try t.expect(c.gtk_widget_get_visible(f.dock.terminal_slot) == 0);
    // Explorer keeps its historical default while Terminal stays hidden.
    try t.expect(f.dock.effective[0]);
    try t.expect(f.dock.state.active == .explorer);
}

test "terminal dock moves hides and tabs without disturbing explorer/search/source control" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const parent = c.gtk_widget_get_parent(f.editor);
    const buffer = c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, f.editor));
    f.dock.show(.terminal);
    settle();
    // Terminal shares the default bottom dock with Search (hidden): Terminal wins.
    try t.expect(f.dock.effective[3]);
    try t.expect(f.dock.state.active == .terminal);
    try t.expect(c.gtk_widget_get_visible(f.dock.terminal_slot) != 0);
    for ([_]layout.Dock{ .right, .bottom, .left }) |side| {
        f.dock.move(side);
        settle();
        try t.expect(c.gtk_widget_get_parent(f.dock.terminal_slot) == f.dock.hosts[@backingInt(side)]);
        try t.expect(f.dock.effective[3]);
        // The Terminal tab follows the panel; the other tabs stay put.
        for (f.dock.tabs, 0..) |tabs, i| {
            try t.expect(c.gtk_widget_get_visible(tabs[3]) == @intFromBool(i == @backingInt(side)));
            try t.expect(c.gtk_widget_get_visible(tabs[0]) == @intFromBool(i == @backingInt(f.dock.state.explorer)));
        }
        try t.expect(c.gtk_widget_get_parent(f.editor) == parent);
        try t.expect(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, f.editor)) == buffer);
    }
    f.dock.hide(.terminal);
    settle();
    try t.expect(!f.dock.effective[3]);
    try t.expect(c.gtk_widget_get_visible(f.dock.terminal_slot) == 0);
    // Explorer remains visible and becomes the active fallback.
    try t.expect(f.dock.effective[0] and f.dock.state.active == .explorer);
    for (f.dock.tabs) |tabs| try t.expect(c.gtk_widget_get_visible(tabs[3]) == 0);
}

test "terminal and search share the bottom dock keeping the active panel" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.dock.restore(.{ .search = .bottom, .terminal = .bottom, .search_visible = true, .terminal_visible = true, .active = .terminal });
    settle();
    try t.expect(!f.dock.effective[1] and f.dock.effective[3]);
    f.dock.show(.search);
    settle();
    try t.expect(f.dock.effective[1] and !f.dock.effective[3]);
    // Desired state survives the shared-dock presentation collapse.
    try t.expect(f.dock.state.search_visible and f.dock.state.terminal_visible);
}

test "agent defaults to a hidden right panel and preserves old sessions" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try t.expect(f.dock.state.agent == .right);
    try t.expect(!f.dock.state.agent_visible);
    try t.expect(!f.dock.effective[4]);
    try t.expect(c.gtk_widget_get_visible(f.dock.agent_slot) == 0);
    // Explorer keeps its historical default while Agent stays hidden.
    try t.expect(f.dock.effective[0]);
    try t.expect(f.dock.state.active == .explorer);
    try t.expect(c.gtk_widget_get_visible(f.dock.frames[1]) == 0);
}

test "agent dock moves hides and tabs without disturbing the other four panels" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const parent = c.gtk_widget_get_parent(f.editor);
    const buffer = c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, f.editor));
    f.dock.show(.agent);
    // effective/visibility/parent/tab assertions are synchronous in apply();
    // no per-move settle is needed (keeps the widget suite within its budget).
    try t.expect(f.dock.effective[4]);
    try t.expect(f.dock.effective[0]);
    try t.expect(f.dock.state.active == .agent);
    try t.expect(c.gtk_widget_get_visible(f.dock.agent_slot) != 0);
    for ([_]layout.Dock{ .right, .bottom, .left }) |side| {
        f.dock.move(side);
        try t.expect(c.gtk_widget_get_parent(f.dock.agent_slot) == f.dock.hosts[@backingInt(side)]);
        try t.expect(f.dock.effective[4]);
        // The Agent tab follows the panel; the other tabs stay put.
        for (f.dock.tabs, 0..) |tabs, i| {
            try t.expect(c.gtk_widget_get_visible(tabs[4]) == @intFromBool(i == @backingInt(side)));
            try t.expect(c.gtk_widget_get_visible(tabs[0]) == @intFromBool(i == @backingInt(f.dock.state.explorer)));
        }
        try t.expect(c.gtk_widget_get_parent(f.editor) == parent);
        try t.expect(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, f.editor)) == buffer);
    }
    f.dock.hide(.agent);
    try t.expect(!f.dock.effective[4]);
    try t.expect(c.gtk_widget_get_visible(f.dock.agent_slot) == 0);
    // Explorer remains visible and becomes the active fallback.
    try t.expect(f.dock.effective[0] and f.dock.state.active == .explorer);
    for (f.dock.tabs) |tabs| try t.expect(c.gtk_widget_get_visible(tabs[4]) == 0);
}

test "agent and explorer share one dock keeping the active panel" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.dock.restore(.{ .explorer = .left, .agent = .left, .explorer_visible = true, .agent_visible = true, .active = .agent });
    try t.expect(!f.dock.effective[0] and f.dock.effective[4]);
    f.dock.show(.explorer);
    try t.expect(f.dock.effective[0] and !f.dock.effective[4]);
    // Desired state survives the shared-dock presentation collapse.
    try t.expect(f.dock.state.explorer_visible and f.dock.state.agent_visible);
}

test "moving focused agent keeps focus after allocation without overriding editor focus" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.dock.show(.agent);
    _ = c.gtk_widget_grab_focus(f.agent);
    settle();
    for ([_]layout.Dock{ .left, .bottom }) |side| {
        f.dock.move(side);
        settle();
        try t.expect(@import("dock.zig").inside(c.gtk_window_get_focus(u.cast(c.GtkWindow, f.window)), f.dock.agent_slot));
    }
    f.dock.move(.right);
    _ = c.gtk_widget_grab_focus(f.editor);
    settle();
    try t.expect(c.gtk_window_get_focus(u.cast(c.GtkWindow, f.window)) == f.editor);
}
