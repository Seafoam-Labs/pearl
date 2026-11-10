//! GTK-main-thread-only command palette, independent of App.
//!
//! Integration/ownership:
//!   app.palette = try Palette.create(parent, app, onCommand, onClosed);
//!   app.palette.?.show();
//! onClosed must synchronously clear app.palette; it is called exactly once.
//! Before freeing the callback context, close the palette (also before tearing
//! down the parent). close() destroys the window and frees this object; never
//! retain/use its pointer afterwards. Reentrant close during onClosed is safe
//! and cancels dispatch. No idle/timeout callback retains the context.
//!
//! Activation destroys the window, releases modality, calls onClosed, then frees
//! Palette BEFORE calling onCommand. The latter may open a dialog, reopen the
//! palette, or destroy the owner. onClosed normally only clears the pointer; if
//! it tears down the owner it must close the palette reentrantly or destroy the
//! parent to cancel dispatch. Parent destruction/unrealization cancels as well.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const i18n = @import("i18n");
const commands = @import("commands.zig");
pub const Command = commands.Command;
pub const OnCommand = *const fn (context: *anyopaque, command: Command) void;
pub const OnClosed = *const fn (context: *anyopaque) void;

/// Pure, allocation-free ordered-subsequence matching (a substring is also a
/// subsequence). ASCII case is ignored, Unicode codepoints are not split, and
/// query whitespace is ignored. The GTK adapter additionally Unicode-casefolds
/// both strings, so translated labels remain searchable without GTK in tests.
pub fn fuzzyMatch(query: []const u8, text: []const u8) bool {
    const query_view = std.unicode.Utf8View.init(query) catch return false;
    const text_view = std.unicode.Utf8View.init(text) catch return false;
    var needle = query_view.iterator();
    var haystack = text_view.iterator();
    while (needle.nextCodepoint()) |wanted| {
        if (wanted <= 0x7f and std.ascii.isWhitespace(@intCast(wanted))) continue;
        while (haystack.nextCodepoint()) |candidate| {
            if (asciiLower(wanted) == asciiLower(candidate)) break;
        } else return false;
    }
    return true;
}

fn asciiLower(cp: u21) u21 {
    return if (cp >= 'A' and cp <= 'Z') cp + ('a' - 'A') else cp;
}

/// Search a translated label as well as stable action/source/shortcut metadata.
pub fn matches(query: []const u8, label: []const u8, entry: commands.Metadata) bool {
    return fuzzyMatch(query, label) or fuzzyMatch(query, entry.label) or
        fuzzyMatch(query, entry.action) or
        (if (entry.shortcut) |shortcut| fuzzyMatch(query, shortcut) else false);
}

pub const Palette = struct {
    window: u.W,
    parent: u.W,
    search: u.W,
    list: u.W,
    scroll: u.W,
    empty: u.W,
    keys: *c.GtkEventController,
    rows: [commands.entries.len]*c.GtkListBoxRow,
    visible: [commands.entries.len]bool = @splat(true),
    context: *anyopaque,
    on_command: OnCommand,
    on_closed: OnClosed,
    closing: bool = false,
    pending: ?Command = null,

    /// Assign the returned pointer to the owner's optional before calling show.
    /// All allocations which can return an error happen before signal hookup.
    pub fn create(parent: u.W, context: *anyopaque, on_command: OnCommand, on_closed: OnClosed) !*Palette {
        const self = try u.a.create(Palette);
        const window = c.gtk_window_new().?;
        const win = u.cast(c.GtkWindow, window);
        c.gtk_window_set_title(win, i18n.dtr("coral", "Command Palette…"));
        c.gtk_window_set_transient_for(win, u.cast(c.GtkWindow, parent));
        c.gtk_window_set_destroy_with_parent(win, 1);
        c.gtk_window_set_modal(win, 1);
        c.gtk_window_set_default_size(win, 520, 420);
        c.gtk_widget_add_css_class(window, "coral");
        const root = u.box(false, 8);
        u.margin(root, 12);
        c.gtk_window_set_child(win, root);
        const search = c.gtk_search_entry_new().?;
        c.g_object_set(search, "placeholder-text", @as([*:0]const u8, i18n.dtr("coral", "Search commands…")), @as(?*anyopaque, null));
        accessibleLabel(search, i18n.dtr("coral", "Search commands"));
        u.append(root, search);
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_scrolled_window_set_policy(u.cast(c.GtkScrolledWindow, scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_widget_set_vexpand(scroll, 1);
        u.append(root, scroll);
        const list = c.gtk_list_box_new().?;
        c.gtk_list_box_set_selection_mode(u.cast(c.GtkListBox, list), c.GTK_SELECTION_SINGLE);
        c.gtk_list_box_set_activate_on_single_click(u.cast(c.GtkListBox, list), 1);
        accessibleLabel(list, i18n.dtr("coral", "Commands"));
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), list);
        const empty = u.label(i18n.dtr("coral", "No matching commands"));
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, empty), 1);
        u.margin(empty, 16);
        u.append(root, empty);
        c.gtk_widget_set_visible(empty, 0);
        const keys = c.gtk_event_controller_key_new().?;
        // Entry/IME handling gets first refusal for composition and candidate
        // navigation. Only unhandled keys reach palette navigation.
        c.gtk_event_controller_set_propagation_phase(keys, c.GTK_PHASE_BUBBLE);
        c.gtk_widget_add_controller(window, keys);
        self.* = .{
            .window = window,
            .parent = parent,
            .search = search,
            .list = list,
            .scroll = scroll,
            .empty = empty,
            .keys = keys,
            .rows = undefined,
            .context = context,
            .on_command = on_command,
            .on_closed = on_closed,
        };
        for (commands.entries, 0..) |entry, index| {
            const row = c.gtk_list_box_row_new().?;
            const content = u.box(true, 16);
            u.margin(content, 8);
            const title = u.label(entry.command.label());
            c.gtk_widget_set_hexpand(title, 1);
            c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, title), c.PANGO_ELLIPSIZE_END);
            u.append(content, title);
            if (entry.shortcut) |shortcut| {
                const hint = u.label(shortcut);
                c.gtk_widget_add_css_class(hint, "dim-label");
                u.append(content, hint);
            }
            accessibleLabel(row, entry.command.label());
            if (entry.shortcut) |shortcut| {
                c.gtk_accessible_update_property(u.cast(c.GtkAccessible, row), @as(c_int, c.GTK_ACCESSIBLE_PROPERTY_KEY_SHORTCUTS), shortcut.ptr, @as(c_int, -1));
            }
            self.rows[index] = u.cast(c.GtkListBoxRow, row);
            c.gtk_list_box_row_set_child(self.rows[index], content);
            c.gtk_list_box_append(u.cast(c.GtkListBox, list), row);
        }
        c.gtk_list_box_select_row(u.cast(c.GtkListBox, list), self.rows[0]);
        u.connect(search, "changed", &changed, self);
        u.connect(search, "activate", &activated, self);
        u.connect(search, "stop-search", &stopSearch, self);
        u.connect(list, "row-activated", &rowActivated, self);
        u.connect(keys, "key-pressed", &keyPressed, self);
        u.connect(window, "close-request", &closeRequested, self);
        // unrealize also catches gtk_window_destroy while another GObject ref
        // keeps the widget alive; destroy covers a never-presented window.
        u.connect(window, "unrealize", &windowGone, self);
        u.connect(window, "destroy", &windowGone, self);
        u.connect(parent, "unrealize", &parentGone, self);
        u.connect(parent, "destroy", &parentGone, self);
        return self;
    }

    pub fn show(self: *Palette) void {
        if (self.closing) return;
        c.gtk_window_present(u.cast(c.GtkWindow, self.window));
        _ = c.gtk_widget_grab_focus(self.search);
    }

    /// Synchronous cancellation, including on_closed. Invalidates self.
    pub fn close(self: *Palette) void {
        self.finish(null, true);
    }

    fn finish(self: *Palette, command: ?Command, destroy_window: bool) void {
        if (self.closing) {
            self.pending = null;
            return;
        }
        self.closing = true;
        self.pending = command;
        // on_closed may destroy the parent; retain it only across teardown so
        // disconnecting our cancellation handlers never touches freed memory.
        const parent = c.g_object_ref(self.parent).?;
        // The owner may disconnect its own widget callbacks in on_closed, even
        // after gtk_window_destroy drops GTK's last reference to this window.
        const window = c.g_object_ref(self.window).?;
        disconnect(self.search, self);
        disconnect(self.list, self);
        disconnect(self.keys, self);
        disconnect(self.window, self);
        c.gtk_window_set_modal(u.cast(c.GtkWindow, self.window), 0);
        if (destroy_window) c.gtk_window_destroy(u.cast(c.GtkWindow, self.window));
        // Keep the parent cancellation hooks until on_closed returns: it may
        // destroy the parent, or reenter close, in which case dispatch is unsafe.
        self.on_closed(self.context);
        disconnect(self.parent, self);
        c.g_object_unref(window);
        c.g_object_unref(parent);
        const pending = self.pending;
        const context = self.context;
        const callback = self.on_command;
        u.a.destroy(self);
        if (pending) |selected| callback(context, selected);
    }

    fn refilter(self: *Palette) void {
        const query = c.g_utf8_casefold(c.gtk_editable_get_text(u.cast(c.GtkEditable, self.search)), -1);
        defer c.g_free(query);
        var first: ?*c.GtkListBoxRow = null;
        for (commands.entries, 0..) |entry, index| {
            const label = c.g_utf8_casefold(entry.command.label(), -1);
            defer c.g_free(label);
            self.visible[index] = matches(std.mem.span(query), std.mem.span(label), entry);
            c.gtk_widget_set_visible(u.cast(c.GtkWidget, self.rows[index]), @intFromBool(self.visible[index]));
            if (self.visible[index] and first == null) first = self.rows[index];
        }
        c.gtk_list_box_select_row(u.cast(c.GtkListBox, self.list), first);
        c.gtk_widget_set_visible(self.empty, @intFromBool(first == null));
        c.gtk_widget_set_visible(self.scroll, @intFromBool(first != null));
        c.gtk_adjustment_set_value(c.gtk_scrolled_window_get_vadjustment(u.cast(c.GtkScrolledWindow, self.scroll)), 0);
    }

    fn move(self: *Palette, backwards: bool) void {
        const selected = c.gtk_list_box_get_selected_row(u.cast(c.GtkListBox, self.list));
        const current: ?usize = if (selected) |row| @intCast(c.gtk_list_box_row_get_index(row)) else null;
        const next = nextVisible(&self.visible, current, backwards) orelse return;
        c.gtk_list_box_select_row(u.cast(c.GtkListBox, self.list), self.rows[next]);
        // GTK scrolls the focused row into view. Keep typing in the search field.
        _ = c.gtk_widget_grab_focus(u.cast(c.GtkWidget, self.rows[next]));
        _ = c.gtk_widget_grab_focus(self.search);
    }

    fn activate(self: *Palette, row: ?*c.GtkListBoxRow) void {
        const selected = row orelse return;
        const index = c.gtk_list_box_row_get_index(selected);
        if (index < 0 or index >= commands.entries.len) return;
        const n: usize = @intCast(index);
        if (!self.visible[n]) return;
        self.finish(commands.entries[n].command, true);
    }
};

fn accessibleLabel(widget: u.W, text: [:0]const u8) void {
    c.gtk_accessible_update_property(u.cast(c.GtkAccessible, widget), @as(c_int, c.GTK_ACCESSIBLE_PROPERTY_LABEL), text.ptr, @as(c_int, -1));
}

fn disconnect(object: anytype, self: *Palette) void {
    _ = c.g_signal_handlers_disconnect_matched(@ptrCast(object), c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
}

fn changed(_: ?*c.GtkEditable, data: ?*anyopaque) callconv(.c) void {
    u.cast(Palette, data.?).refilter();
}
fn activated(_: ?*c.GtkSearchEntry, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Palette, data.?);
    self.activate(c.gtk_list_box_get_selected_row(u.cast(c.GtkListBox, self.list)));
}
fn stopSearch(_: ?*c.GtkSearchEntry, data: ?*anyopaque) callconv(.c) void {
    u.cast(Palette, data.?).close();
}
fn rowActivated(_: ?*c.GtkListBox, row: ?*c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
    u.cast(Palette, data.?).activate(row);
}
fn closeRequested(_: ?*c.GtkWindow, data: ?*anyopaque) callconv(.c) c_int {
    u.cast(Palette, data.?).close();
    return 1;
}
fn windowGone(_: ?*c.GtkWidget, data: ?*anyopaque) callconv(.c) void {
    u.cast(Palette, data.?).finish(null, false);
}
fn parentGone(_: ?*c.GtkWidget, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Palette, data.?);
    self.close();
}
fn keyPressed(_: ?*c.GtkEventControllerKey, key: c_uint, _: c_uint, state: c.GdkModifierType, data: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(Palette, data.?);
    const modifiers = state & c.gtk_accelerator_get_default_mod_mask();
    if (modifiers != 0) return 0;
    switch (key) {
        c.GDK_KEY_Escape => self.close(),
        c.GDK_KEY_Up, c.GDK_KEY_KP_Up => self.move(true),
        c.GDK_KEY_Down, c.GDK_KEY_KP_Down => self.move(false),
        // Enter is handled by the entry/list's native activation signals, after
        // the input method has had a chance to commit composed text.
        else => return 0,
    }
    return 1;
}

fn nextVisible(visible: []const bool, current: ?usize, backwards: bool) ?usize {
    if (visible.len == 0) return null;
    const start = if (current) |index| index % visible.len else if (backwards) 0 else visible.len - 1;
    for (1..visible.len + 1) |step| {
        const index = if (backwards) (start + visible.len - step) % visible.len else (start + step) % visible.len;
        if (visible[index]) return index;
    }
    return null;
}

/// Opt-in native validation, deliberately NOT a test block: pure tests never
/// initialize GTK. Invoke from a separate display-enabled harness; absence of a
/// display is an error, not a silently skipped test.
pub fn validateGtk() !void {
    if (c.gtk_init_check() == 0) return error.NoDisplay;
    try validateOwnerCleanup();
    try std.testing.expectEqual(Command.save_as, commands.fromKey(c.GDK_KEY_S, c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK).?);
    try std.testing.expectEqual(Command.spelling, commands.fromKey(c.GDK_KEY_F10, c.GDK_SHIFT_MASK).?);
    const parent = c.gtk_window_new().?;
    _ = c.g_object_ref(parent);
    defer c.g_object_unref(parent);
    defer c.gtk_window_destroy(u.cast(c.GtkWindow, parent));
    c.gtk_window_present(u.cast(c.GtkWindow, parent));
    var fixture: GtkFixture = .{ .parent = parent };
    defer fixture.deinit();

    try fixture.open();
    var palette = fixture.palette.?;
    try std.testing.expect(c.gtk_window_get_modal(u.cast(c.GtkWindow, palette.window)) != 0);
    try std.testing.expectEqual(u.cast(c.GtkWindow, parent), c.gtk_window_get_transient_for(u.cast(c.GtkWindow, palette.window)).?);
    c.gtk_editable_set_text(u.cast(c.GtkEditable, palette.search), "zzzzzzzzzz");
    try std.testing.expect(c.gtk_widget_get_visible(palette.empty) != 0);
    activated(null, palette);
    try std.testing.expect(fixture.palette != null);
    try std.testing.expectEqual(@as(usize, 0), fixture.executed);
    c.gtk_editable_set_text(u.cast(c.GtkEditable, palette.search), "save");
    try std.testing.expectEqual(@as(?usize, 2), selectedIndex(palette));
    try std.testing.expectEqual(@as(c_int, 1), keyPressed(null, c.GDK_KEY_Down, 0, 0, palette));
    try std.testing.expectEqual(@as(?usize, 3), selectedIndex(palette));
    _ = keyPressed(null, c.GDK_KEY_Down, 0, 0, palette);
    try std.testing.expectEqual(@as(?usize, 2), selectedIndex(palette));
    _ = keyPressed(null, c.GDK_KEY_Up, 0, 0, palette);
    try std.testing.expectEqual(@as(?usize, 3), selectedIndex(palette));
    // Exercise GTK's actual signal dispatch while destroying its sender.
    c.g_signal_emit_by_name(palette.search, "activate");
    try std.testing.expectEqual(Command.save_as, fixture.last_command.?);
    try std.testing.expectEqual(@as(usize, 1), fixture.closed);
    try std.testing.expectEqual(@as(usize, 1), fixture.executed);
    try std.testing.expect(fixture.palette == null);

    try fixture.open();
    _ = keyPressed(null, c.GDK_KEY_Escape, 0, 0, fixture.palette.?);
    try std.testing.expect(fixture.palette == null);
    try fixture.open();
    c.gtk_window_close(u.cast(c.GtkWindow, fixture.palette.?.window));
    try std.testing.expect(fixture.palette == null);
    try fixture.open();
    c.gtk_window_destroy(u.cast(c.GtkWindow, fixture.palette.?.window));
    try std.testing.expect(fixture.palette == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.executed);

    try fixture.open();
    fixture.cancel_on_closed = true;
    activated(null, fixture.palette.?);
    fixture.cancel_on_closed = false;
    try std.testing.expectEqual(@as(usize, 1), fixture.executed);

    try fixture.open();
    fixture.reopen_on_command = true;
    palette = fixture.palette.?;
    c.g_signal_emit_by_name(palette.list, "row-activated", palette.rows[@backingInt(Command.command_palette)]);
    fixture.reopen_on_command = false;
    try std.testing.expectEqual(Command.command_palette, fixture.last_command.?);
    try std.testing.expect(fixture.palette != null);
    fixture.palette.?.close();
    try std.testing.expectEqual(@as(usize, 2), fixture.executed);

    // Closing before show must also notify exactly once, with no queued work.
    fixture.palette = try Palette.create(parent, &fixture, GtkFixture.command, GtkFixture.closedCallback);
    const closed = fixture.closed;
    fixture.palette.?.close();
    try std.testing.expectEqual(closed + 1, fixture.closed);
    try fixture.open();
    fixture.destroy_parent_on_closed = true;
    activated(null, fixture.palette.?);
    try std.testing.expect(fixture.palette == null);
    try std.testing.expectEqual(@as(usize, 2), fixture.executed);

    // Separate parent: test automatic cancellation rather than explicit close.
    const other_parent = c.gtk_window_new().?;
    c.gtk_window_present(u.cast(c.GtkWindow, other_parent));
    var other: GtkFixture = .{ .parent = other_parent };
    defer other.deinit();
    try other.open();
    c.gtk_window_destroy(u.cast(c.GtkWindow, other_parent));
    try std.testing.expect(other.palette == null);
    try std.testing.expectEqual(@as(usize, 1), other.closed);
    try std.testing.expectEqual(@as(usize, 0), other.executed);
    while (c.g_main_context_iteration(null, 0) != 0) {}
    try std.testing.expectEqual(@as(usize, 0), other.executed);
}

// Unlike GtkFixture, this owner deliberately holds no strong window reference.
// Model App's cleanup during external Quit All and reentrant parent teardown.
fn validateOwnerCleanup() !void {
    for ([_]bool{ false, true }) |show| {
        for ([_]bool{ false, true }) |cancel| {
            const parent = c.gtk_window_new().?;
            _ = c.g_object_ref(parent);
            defer c.g_object_unref(parent);
            defer c.gtk_window_destroy(u.cast(c.GtkWindow, parent));
            var owner: CleanupFixture = .{ .parent = parent, .cancel = cancel };
            owner.palette = try Palette.create(parent, &owner, CleanupFixture.command, CleanupFixture.closed);
            const window = owner.palette.?.window;
            c.g_object_weak_ref(u.cast(c.GObject, window), &CleanupFixture.finalized, &owner);
            defer if (!owner.gone) c.g_object_weak_unref(u.cast(c.GObject, window), &CleanupFixture.finalized, &owner);
            if (show) {
                c.gtk_window_present(u.cast(c.GtkWindow, parent));
                owner.palette.?.show();
            }
            if (cancel) activated(null, owner.palette.?) else owner.palette.?.close();
            try std.testing.expect(owner.cleaned);
            try std.testing.expect(owner.palette == null);
            try std.testing.expectEqual(@as(usize, 0), owner.executed);
            while (c.g_main_context_iteration(null, 0) != 0) {}
            try std.testing.expect(owner.gone);
        }
    }
}

const CleanupFixture = struct {
    parent: u.W,
    palette: ?*Palette = null,
    cancel: bool,
    gone: bool = false,
    cleaned: bool = false,
    executed: usize = 0,

    fn finalized(data: ?*anyopaque, _: ?*c.GObject) callconv(.c) void {
        u.cast(CleanupFixture, data.?).gone = true;
    }
    fn closed(context: *anyopaque) void {
        const self = u.cast(CleanupFixture, context);
        const palette = self.palette.?;
        self.palette = null;
        if (!self.gone) {
            _ = c.g_signal_handlers_disconnect_matched(palette.window, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            c.gtk_widget_insert_action_group(palette.window, "win", null);
            const controllers = c.gtk_widget_observe_controllers(palette.window).?;
            c.g_object_unref(controllers);
            self.cleaned = true;
        }
        if (self.cancel) {
            palette.close();
            c.gtk_window_destroy(u.cast(c.GtkWindow, self.parent));
        }
    }
    fn command(context: *anyopaque, _: Command) void {
        u.cast(CleanupFixture, context).executed += 1;
    }
};

fn selectedIndex(palette: *Palette) ?usize {
    const row = c.gtk_list_box_get_selected_row(u.cast(c.GtkListBox, palette.list)) orelse return null;
    return @intCast(c.gtk_list_box_row_get_index(row));
}

const GtkFixture = struct {
    parent: u.W,
    palette: ?*Palette = null,
    window_ref: ?u.W = null,
    closed: usize = 0,
    executed: usize = 0,
    last_command: ?Command = null,
    cancel_on_closed: bool = false,
    reopen_on_command: bool = false,
    destroy_parent_on_closed: bool = false,

    fn open(self: *GtkFixture) !void {
        if (self.window_ref) |window| c.g_object_unref(window);
        self.window_ref = null;
        self.palette = try Palette.create(self.parent, self, command, closedCallback);
        self.window_ref = u.cast(c.GtkWidget, c.g_object_ref(self.palette.?.window).?);
        self.palette.?.show();
    }
    fn deinit(self: *GtkFixture) void {
        if (self.palette) |palette| palette.close();
        if (self.window_ref) |window| c.g_object_unref(window);
    }
    fn closedCallback(context: *anyopaque) void {
        const self = u.cast(GtkFixture, context);
        const palette = self.palette.?;
        self.palette = null;
        self.closed += 1;
        if (self.cancel_on_closed) palette.close();
        if (self.destroy_parent_on_closed) c.gtk_window_destroy(u.cast(c.GtkWindow, self.parent));
    }
    fn command(context: *anyopaque, selected: Command) void {
        const self = u.cast(GtkFixture, context);
        std.debug.assert(self.palette == null and self.closed > self.executed);
        if (self.window_ref) |window| {
            std.debug.assert(c.gtk_window_get_modal(u.cast(c.GtkWindow, window)) == 0);
            std.debug.assert(c.gtk_widget_get_realized(window) == 0);
        }
        self.executed += 1;
        self.last_command = selected;
        if (self.reopen_on_command) self.open() catch unreachable;
    }
};

test "filter handles substring, fuzzy, whitespace, metadata and empty results" {
    const save_as = Command.save_as.metadata();
    for ([_][]const u8{ "", " \t\n", "SAVE", "svas", "save-as", "ctrlshifts", "  S A  " }) |query| {
        try std.testing.expect(matches(query, "Enregistrer sous…", save_as));
    }
    try std.testing.expect(matches("enrs", "Enregistrer sous…", save_as));
    try std.testing.expect(!matches("terminal", "Enregistrer sous…", save_as));
    try std.testing.expect(!fuzzyMatch("savex", "Save"));
    try std.testing.expect(!fuzzyMatch("asave", "Save As"));
    try std.testing.expect(fuzzyMatch("行", "移動する行"));
    try std.testing.expect(!fuzzyMatch("\xff", "Save"));
    try std.testing.expect(!fuzzyMatch("save", "\xff"));
    var count: usize = 0;
    for (commands.entries) |entry| {
        if (matches("command-palette", entry.label, entry)) count += 1;
        try std.testing.expect(!matches("zzzzzzzzzz", entry.label, entry));
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "selection wraps visible rows and handles no matches" {
    const visible = [_]bool{ true, false, true, false };
    try std.testing.expectEqual(@as(?usize, 0), nextVisible(&visible, null, false));
    try std.testing.expectEqual(@as(?usize, 2), nextVisible(&visible, null, true));
    try std.testing.expectEqual(@as(?usize, 2), nextVisible(&visible, 0, false));
    try std.testing.expectEqual(@as(?usize, 0), nextVisible(&visible, 2, false));
    try std.testing.expectEqual(@as(?usize, 2), nextVisible(&visible, 0, true));
    try std.testing.expectEqual(@as(?usize, 0), nextVisible(&.{true}, 0, true));
    try std.testing.expectEqual(@as(?usize, null), nextVisible(&.{ false, false }, 0, false));
    try std.testing.expectEqual(@as(?usize, null), nextVisible(&.{}, null, true));
}
