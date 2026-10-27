//! Presentation only. The live helper remains the authority for fields and values.
const std = @import("std");
const m = @import("aqueous_model.zig");
pub const Group = enum {
    borders,
    effects,
    effect_tuning,
    typography,
    desktop,
    appearance_extra,
    layout,
    spacing,
    layout_behavior,
    slots,
    snap,
    legacy_zones,
    layouts_extra,
    keyboard,
    pointer,
    focus,
    input_options,
    input_extra,
    shortcuts,
    movement,
    workspaces,
    window_actions,
    layout_keys,
    shortcut_options,
    custom_shortcuts,
    keybinds_extra,
    rules,
    game,
    rule_sources,
    rules_extra,
    display_policy,
    display_sources,
    displays_extra,
    status,
    raw,
    request,
    receipts,
};
pub const count = @typeInfo(Group).@"enum".fields.len;
pub const Spec = struct { page: []const u8, en: [:0]const u8, detail_en: [:0]const u8, collapsed: bool = true };
pub fn spec(g: Group) Spec {
    return switch (g) {
        .borders => .{ .page = "appearance", .en = @import("i18n").mark("Window appearance"), .detail_en = @import("i18n").mark("Draft preview and window borders"), .collapsed = false },
        .effects => .{ .page = "appearance", .en = @import("i18n").mark("Window effects"), .detail_en = @import("i18n").mark("Blur and transparency"), .collapsed = false },
        .effect_tuning => .{ .page = "appearance", .en = @import("i18n").mark("Effect tuning"), .detail_en = @import("i18n").mark("Borders, blur, opacity and transitions") },
        .typography => .{ .page = "appearance", .en = @import("i18n").mark("Fonts and cursor"), .detail_en = @import("i18n").mark("Desktop typography and synchronization") },
        .desktop => .{ .page = "appearance", .en = @import("i18n").mark("Desktop behavior"), .detail_en = @import("i18n").mark("Reserved space, fullscreen and bell") },
        .appearance_extra => extra("appearance"),
        .layout => .{ .page = "layouts", .en = @import("i18n").mark("Default layout"), .detail_en = @import("i18n").mark("Choose how windows share the workspace"), .collapsed = false },
        .spacing => .{ .page = "layouts", .en = @import("i18n").mark("Spacing"), .detail_en = @import("i18n").mark("Between windows and workspace edges"), .collapsed = false },
        .layout_behavior => .{ .page = "layouts", .en = @import("i18n").mark("Layout behavior"), .detail_en = @import("i18n").mark("Master area, per-layout options and inheritance") },
        .slots => .{ .page = "layouts", .en = @import("i18n").mark("Layout shortcuts"), .detail_en = @import("i18n").mark("Four slots for quick switching") },
        .snap => .{ .page = "layouts", .en = @import("i18n").mark("Snap layouts"), .detail_en = @import("i18n").mark("Named layouts, default selection and ordered zones") },
        .legacy_zones => .{ .page = "layouts", .en = @import("i18n").mark("Legacy snap zones"), .detail_en = @import("i18n").mark("Normalized geometry and source inventory") },
        .layouts_extra => extra("layouts"),
        .keyboard => .{ .page = "input", .en = @import("i18n").mark("Keyboard"), .detail_en = @import("i18n").mark("Layout and key repeat"), .collapsed = false },
        .pointer => .{ .page = "input", .en = @import("i18n").mark("Pointer and touchpad"), .detail_en = @import("i18n").mark("Independent scrolling and tapping preferences"), .collapsed = false },
        .focus => .{ .page = "input", .en = @import("i18n").mark("Focus behavior"), .detail_en = @import("i18n").mark("Pointer focus, new windows and raising") },
        .input_options => .{ .page = "input", .en = @import("i18n").mark("More input options"), .detail_en = @import("i18n").mark("Acceleration, handedness and XKB options") },
        .input_extra => extra("input"),
        .shortcuts => .{ .page = "keybinds", .en = @import("i18n").mark("Launch and session"), .detail_en = @import("i18n").mark("Common actions and shortcuts"), .collapsed = false },
        .movement => .{ .page = "keybinds", .en = @import("i18n").mark("Focus and movement"), .detail_en = @import("i18n").mark("Windows, columns and viewport") },
        .workspaces => .{ .page = "keybinds", .en = @import("i18n").mark("Workspaces and outputs"), .detail_en = @import("i18n").mark("Switch workspaces and move windows") },
        .window_actions => .{ .page = "keybinds", .en = @import("i18n").mark("Window sizing and snapping"), .detail_en = @import("i18n").mark("Floating, resizing, stacking and snap actions") },
        .layout_keys => .{ .page = "keybinds", .en = @import("i18n").mark("Layout selection"), .detail_en = @import("i18n").mark("Primary, secondary, tertiary and quaternary") },
        .shortcut_options => .{ .page = "keybinds", .en = @import("i18n").mark("Action commands"), .detail_en = @import("i18n").mark("Editing a command never executes it") },
        .custom_shortcuts => .{ .page = "keybinds", .en = @import("i18n").mark("Custom shortcuts"), .detail_en = @import("i18n").mark("Add, edit, delete and record custom bindings") },
        .keybinds_extra => extra("keybinds"),
        .rules => .{ .page = "rules", .en = @import("i18n").mark("Window rules"), .detail_en = @import("i18n").mark("Ordered conditions and effects"), .collapsed = false },
        .game => .{ .page = "rules", .en = @import("i18n").mark("Game mode"), .detail_en = @import("i18n").mark("Remainder layout, fallback and spacing") },
        .rule_sources => .{ .page = "rules", .en = @import("i18n").mark("Saved rule inventory"), .detail_en = @import("i18n").mark("Source order and preserved settings") },
        .rules_extra => extra("rules"),
        .display_policy => .{ .page = "displays", .en = @import("i18n").mark("Display policy"), .detail_en = @import("i18n").mark("Startup, reload, fallback and compatibility") },
        .display_sources => .{ .page = "displays", .en = @import("i18n").mark("Additional display configuration"), .detail_en = @import("i18n").mark("Connected and offline output declarations") },
        .displays_extra => extra("displays"),
        .status => .{ .page = "advanced", .en = @import("i18n").mark("Configuration status"), .detail_en = @import("i18n").mark("Save, reload, synchronization and recovery"), .collapsed = false },
        .raw => .{ .page = "advanced", .en = @import("i18n").mark("Raw configuration"), .detail_en = @import("i18n").mark("Six sources; raw edits own the complete file") },
        .request => .{ .page = "advanced", .en = @import("i18n").mark("Full draft request"), .detail_en = @import("i18n").mark("JSON and explicit user overrides") },
        .receipts => .{ .page = "advanced", .en = @import("i18n").mark("Operation details"), .detail_en = @import("i18n").mark("Candidate effects, receipts and display rollback") },
    };
}
fn extra(page: []const u8) Spec {
    return .{ .page = page, .en = @import("i18n").mark("Additional settings"), .detail_en = @import("i18n").mark("Further fields supplied by this Aqueous helper") };
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn one(id: []const u8, keys: []const []const u8) bool {
    for (keys) |key| if (eq(id, key)) return true;
    return false;
}
fn prefix(id: []const u8, keys: []const []const u8) bool {
    for (keys) |key| if (std.mem.startsWith(u8, id, key)) return true;
    return false;
}
pub fn group(field: m.Value) Group {
    const id = m.str(m.get(field, "id"));
    const page = m.fieldCategory(field);
    if (eq(page, "appearance")) {
        if (one(id, &.{ "layout.border_width", "layout.border_focused", "decoration.corner_radius" })) return .borders;
        if (one(id, &.{ "blur.enabled", "opacity.enabled" })) return .effects;
        if (prefix(id, &.{ "blur.", "opacity.", "workspace_transition.", "layout.border_" })) return .effect_tuning;
        if (prefix(id, &.{ "desktop.font.", "desktop.cursor." })) return .typography;
        if (prefix(id, &.{ "struts.", "state.", "bell." })) return .desktop;
        return .appearance_extra;
    }
    if (eq(page, "layouts")) {
        if (eq(id, "layout.default")) return .layout;
        if (one(id, &.{ "layout.gaps_inner", "layout.gaps_outer" })) return .spacing;
        if (prefix(id, &.{"layout.slots."})) return .slots;
        if (prefix(id, &.{"layout.options."}) or one(id, &.{ "layout.master_ratio", "layout.master_count", "layout.force_ssd", "layout.center_single_window", "layout.single_window_aspect_ratio" })) return .layout_behavior;
        return .layouts_extra;
    }
    if (eq(page, "input")) {
        if (one(id, &.{ "input.xkb_layout", "input.repeat_rate", "input.repeat_delay" })) return .keyboard;
        if (one(id, &.{ "input.mouse.natural_scroll", "input.touchpad.natural_scroll", "input.touchpad.tap" })) return .pointer;
        if (one(id, &.{ "input.focus_follows_mouse", "input.mouse_follows_focus", "input.focus_new_windows", "input.raise_on_focus", "input.raise_on_focus_delay_ms" })) return .focus;
        if (prefix(id, &.{ "input.mouse.", "input.touchpad.", "input.xkb_", "input.pointer_acceleration" })) return .input_options;
        return .input_extra;
    }
    if (eq(page, "keybinds")) {
        if (prefix(id, &.{"actions."})) return .shortcut_options;
        if (one(id, &.{ "toggle_start_menu", "spawn_terminal", "screenshot", "close_focused", "toggle_overview", "reload_config", "reload_rules", "lock_screen", "untrap_pointer" })) return .shortcuts;
        if (prefix(id, &.{ "focus_workspace_", "move_to_workspace_", "focus_output_", "move_to_output_", "focus_previous_workspace" })) return .workspaces;
        if (prefix(id, &.{"set_layout_"})) return .layout_keys;
        if (prefix(id, &.{ "cycle_focus", "focus_", "scroll_", "wheel_scroll_", "consume_window_", "expel_window_", "move_window_", "move_column_" })) return .movement;
        if (prefix(id, &.{ "toggle_", "raise_", "lower_", "nudge_", "resize_", "shrink_", "snap_", "unsnap", "cycle_snap_", "fit_floating_", "move_floating_", "grow_floating_", "unminimize_" })) return .window_actions;
        return .keybinds_extra;
    }
    if (eq(page, "rules")) return if (prefix(id, &.{"game_mode."})) .game else .rules_extra;
    if (eq(page, "displays")) return if (prefix(id, &.{"display."})) .display_policy else .displays_extra;
    // Unexpected schema categories remain visible in Advanced rather than disappearing.
    return .request;
}
pub fn matches(query: []const u8, id: []const u8, label: []const u8, value: []const u8) bool {
    const q = std.mem.trim(u8, query, " \t\r\n");
    return q.len == 0 or std.ascii.indexOfIgnoreCase(id, q) != null or std.ascii.indexOfIgnoreCase(label, q) != null or std.ascii.indexOfIgnoreCase(value, q) != null;
}
pub fn draftValue(base: m.Value, draft: m.Value, id: []const u8) m.Value {
    for (m.list(m.get(draft, "changes"))) |change| if (eq(m.str(m.get(change, "id")), id)) return m.get(change, "value");
    return m.get(m.field(base, id) orelse .null, "value");
}
const pages = [_][]const u8{ "appearance", "layouts", "input", "keybinds", "rules", "displays", "advanced" };
const page_en = [_][:0]const u8{ @import("i18n").mark("Appearance"), @import("i18n").mark("Layouts"), @import("i18n").mark("Input"), @import("i18n").mark("Shortcuts"), @import("i18n").mark("Rules"), @import("i18n").mark("Displays"), @import("i18n").mark("Advanced") };
const collections = [_][]const u8{ "display_declaration_changes", "monitor_changes", "raw_files", "custom_keybind_changes", "window_rule_changes", "snap_zone_changes", "snap_layouts", "default_snap_layout", "sync_typography", "sync_cursor", "normalize_stacking", "create_user_override" };
const collection_pages = [_]usize{ 5, 5, 6, 3, 4, 1, 1, 1, 0, 0, 1, 6 };
fn pageIndex(field: m.Value) usize {
    for (pages, 0..) |page, i| if (eq(page, m.fieldCategory(field))) return i;
    return 6;
}
fn changed(draft: m.Value, key: []const u8) bool {
    const v = m.get(draft, key);
    if (v == .null or m.equal(v, .{ .bool = false })) return false;
    if (v == .object and v.object.count() == 0) return false;
    if (v == .array and v.array.items.len == 0 and !eq(key, "snap_layouts")) return false;
    return true;
}
pub fn footer(a: std.mem.Allocator, base: m.Value, draft: m.Value) ![:0]const u8 {
    var affected: [7]bool = @splat(false);
    var edits: usize = 0;
    for (m.list(m.get(draft, "changes"))) |change| {
        affected[pageIndex(m.field(base, m.str(m.get(change, "id"))) orelse .null)] = true;
        edits += 1;
    }
    for (collections, collection_pages) |key, page| if (changed(draft, key)) {
        affected[page] = true;
        edits += 1;
    };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var buffer: [128]u8 = undefined;
    try out.writer.writeAll(@import("i18n").fmt(&buffer, "{d} unsaved changes · ", .{edits}));
    var first = true;
    for (affected, 0..) |yes, i| if (yes) {
        if (!first) try out.writer.writeAll(", ");
        try out.writer.writeAll(@import("i18n").tr(page_en[i]));
        first = false;
    };
    if (first) try out.writer.writeAll(@import("i18n").dtr("pearl", "Review the full request"));
    return a.dupeZ(u8, out.written());
}
/// Human review includes display operations too; source metadata is not an edit.
pub fn summary(a: std.mem.Allocator, base: m.Value, draft: m.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    for (m.list(m.get(draft, "changes"))) |change| {
        const id = m.str(m.get(change, "id"));
        const f = m.field(base, id) orelse .null;
        const title = if (f == .null) id else m.str(m.get(f, "label"));
        const page = pageIndex(f);
        try out.writer.print("• {s}: {s}\n  {s} → {s}\n", .{ @import("i18n").tr(page_en[page]), title, try std.json.Stringify.valueAlloc(a, m.get(f, "value"), .{}), try std.json.Stringify.valueAlloc(a, m.get(change, "value"), .{}) });
    }
    const keys = [_][]const u8{ "display_declaration_changes", "monitor_changes", "raw_files", "custom_keybind_changes", "window_rule_changes", "snap_zone_changes", "snap_layouts", "default_snap_layout", "sync_typography", "sync_cursor", "normalize_stacking", "create_user_override" };
    const en = [_][:0]const u8{ @import("i18n").mark("Displays: declarations and profiles"), @import("i18n").mark("Displays: monitor settings"), @import("i18n").mark("Advanced: raw configuration files"), @import("i18n").mark("Shortcuts: custom bindings"), @import("i18n").mark("Rules: window rules"), @import("i18n").mark("Layouts: legacy snap zones"), @import("i18n").mark("Layouts: named snap layouts"), @import("i18n").mark("Layouts: default snap layout"), @import("i18n").mark("Appearance: font synchronization"), @import("i18n").mark("Appearance: cursor synchronization"), @import("i18n").mark("Layouts: normalize stacking aliases"), @import("i18n").mark("Advanced: create user override") };
    for (keys, 0..) |key, i| {
        if (!changed(draft, key)) continue;
        try out.writer.print("• {s}\n", .{@import("i18n").tr(en[i])});
    }
    if (out.written().len == 0) try out.writer.writeAll(@import("i18n").dtr("pearl", "Review the complete draft in Advanced."));
    return out.toOwnedSlice();
}
test "all pinned scalar fields have exactly one section and future fields remain reachable" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(m.Value, a, @embedFile("aqueous_presentation_fixture"), .{});
    defer parsed.deinit();
    const fields = m.list(m.get(parsed.value, "fields"));
    try std.testing.expectEqual(@as(usize, 221), fields.len);
    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();
    for (fields) |f| {
        const id = m.str(m.get(f, "id"));
        try std.testing.expect(!seen.contains(id));
        try seen.put(id, {});
        try std.testing.expectEqualStrings(m.fieldCategory(f), spec(group(f)).page);
        try std.testing.expect(!std.mem.endsWith(u8, @tagName(group(f)), "_extra"));
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const future = try m.parse(arena.allocator(), "{\"id\":\"future.setting\",\"category\":\"input\"}", 1024);
    try std.testing.expectEqual(Group.input_extra, group(future));
    const centering = try m.parse(arena.allocator(), "{\"id\":\"layout.options.grid.center_single_window\",\"category\":\"layouts\"}", 1024);
    try std.testing.expectEqual(Group.layout_behavior, group(centering));
    const corners = try m.parse(arena.allocator(), "{\"id\":\"decoration.corner_radius\",\"category\":\"appearance\"}", 1024);
    try std.testing.expectEqual(Group.borders, group(corners));
}
test "search uses id label or chord without rewriting field values" {
    try std.testing.expect(matches("TERMINAL", "spawn_terminal", @import("i18n").dtr("pearl", "Open terminal"), "Super+Return"));
    try std.testing.expect(matches("super+return", "spawn_terminal", @import("i18n").dtr("pearl", "Open terminal"), "Super+Return"));
    try std.testing.expect(!matches("missing", "spawn_terminal", @import("i18n").dtr("pearl", "Open terminal"), "Super+Return"));
}

test "review includes values and collection deletion without counting empty operation lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try m.parse(a, "{\"fields\":[{\"id\":\"input.repeat_rate\",\"category\":\"input\",\"label\":\"Repeat rate\",\"value\":25}]}", 1024);
    const draft = try m.parse(a, "{\"changes\":[{\"id\":\"input.repeat_rate\",\"value\":38}],\"monitor_changes\":[],\"raw_files\":{},\"snap_layouts\":[]}", 1024);
    try std.testing.expectEqualStrings("2 unsaved changes · Layouts, Input", try footer(a, base, draft));
    const review = try summary(a, base, draft);
    try std.testing.expect(std.mem.indexOf(u8, review, "25 → 38") != null);
    try std.testing.expect(std.mem.indexOf(u8, review, "named snap layouts") != null);
    try std.testing.expect(std.mem.indexOf(u8, review, "monitor settings") == null);
    try std.testing.expectEqual(@as(i64, 38), draftValue(base, draft, "input.repeat_rate").integer);
}
