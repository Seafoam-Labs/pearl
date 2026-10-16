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
pub const Spec = struct { page: []const u8, en: [:0]const u8, de: [:0]const u8, detail_en: [:0]const u8, detail_de: [:0]const u8, collapsed: bool = true };
pub fn spec(g: Group) Spec {
    return switch (g) {
        .borders => .{ .page = "appearance", .en = "Window appearance", .de = "Fensterdarstellung", .detail_en = "Draft preview and window borders", .detail_de = "Entwurfsvorschau und Fensterrahmen", .collapsed = false },
        .effects => .{ .page = "appearance", .en = "Window effects", .de = "Fenstereffekte", .detail_en = "Blur and transparency", .detail_de = "Unschärfe und Transparenz", .collapsed = false },
        .effect_tuning => .{ .page = "appearance", .en = "Effect tuning", .de = "Effekte anpassen", .detail_en = "Borders, blur, opacity and transitions", .detail_de = "Rahmen, Unschärfe, Deckkraft und Übergänge" },
        .typography => .{ .page = "appearance", .en = "Fonts and cursor", .de = "Schriften und Mauszeiger", .detail_en = "Desktop typography and synchronization", .detail_de = "Desktop-Schrift und Synchronisierung" },
        .desktop => .{ .page = "appearance", .en = "Desktop behavior", .de = "Desktop-Verhalten", .detail_en = "Reserved space, fullscreen and bell", .detail_de = "Reservierter Platz, Vollbild und Signalton" },
        .appearance_extra => extra("appearance"),
        .layout => .{ .page = "layouts", .en = "Default layout", .de = "Standardanordnung", .detail_en = "Choose how windows share the workspace", .detail_de = "Fenster auf der Arbeitsfläche anordnen", .collapsed = false },
        .spacing => .{ .page = "layouts", .en = "Spacing", .de = "Abstände", .detail_en = "Between windows and workspace edges", .detail_de = "Zwischen Fenstern und Arbeitsflächenrändern", .collapsed = false },
        .layout_behavior => .{ .page = "layouts", .en = "Layout behavior", .de = "Anordnungsverhalten", .detail_en = "Master area, per-layout options and inheritance", .detail_de = "Hauptbereich, Anordnungsoptionen und Vererbung" },
        .slots => .{ .page = "layouts", .en = "Layout shortcuts", .de = "Anordnungskürzel", .detail_en = "Four slots for quick switching", .detail_de = "Vier Plätze zum schnellen Wechseln" },
        .snap => .{ .page = "layouts", .en = "Snap layouts", .de = "Einrastanordnungen", .detail_en = "Named layouts, default selection and ordered zones", .detail_de = "Benannte Anordnungen, Standard und geordnete Zonen" },
        .legacy_zones => .{ .page = "layouts", .en = "Legacy snap zones", .de = "Bisherige Einrastzonen", .detail_en = "Normalized geometry and source inventory", .detail_de = "Normierte Geometrie und Quellenübersicht" },
        .layouts_extra => extra("layouts"),
        .keyboard => .{ .page = "input", .en = "Keyboard", .de = "Tastatur", .detail_en = "Layout and key repeat", .detail_de = "Belegung und Tastenwiederholung", .collapsed = false },
        .pointer => .{ .page = "input", .en = "Pointer and touchpad", .de = "Maus und Touchpad", .detail_en = "Independent scrolling and tapping preferences", .detail_de = "Unabhängige Einstellungen für Scrollen und Tippen", .collapsed = false },
        .focus => .{ .page = "input", .en = "Focus behavior", .de = "Fokusverhalten", .detail_en = "Pointer focus, new windows and raising", .detail_de = "Zeigerfokus, neue Fenster und Anheben" },
        .input_options => .{ .page = "input", .en = "More input options", .de = "Weitere Eingabeoptionen", .detail_en = "Acceleration, handedness and XKB options", .detail_de = "Beschleunigung, Händigkeit und XKB-Optionen" },
        .input_extra => extra("input"),
        .shortcuts => .{ .page = "keybinds", .en = "Launch and session", .de = "Start und Sitzung", .detail_en = "Common actions and shortcuts", .detail_de = "Häufige Aktionen und Tastenkürzel", .collapsed = false },
        .movement => .{ .page = "keybinds", .en = "Focus and movement", .de = "Fokus und Bewegung", .detail_en = "Windows, columns and viewport", .detail_de = "Fenster, Spalten und Ansichtsbereich" },
        .workspaces => .{ .page = "keybinds", .en = "Workspaces and outputs", .de = "Arbeitsflächen und Ausgaben", .detail_en = "Switch workspaces and move windows", .detail_de = "Arbeitsflächen wechseln und Fenster verschieben" },
        .window_actions => .{ .page = "keybinds", .en = "Window sizing and snapping", .de = "Fenstergröße und Einrasten", .detail_en = "Floating, resizing, stacking and snap actions", .detail_de = "Schwebende Fenster, Größen, Stapelung und Einrasten" },
        .layout_keys => .{ .page = "keybinds", .en = "Layout selection", .de = "Anordnungsauswahl", .detail_en = "Primary, secondary, tertiary and quaternary", .detail_de = "Primär, sekundär, tertiär und quartär" },
        .shortcut_options => .{ .page = "keybinds", .en = "Action commands", .de = "Aktionsbefehle", .detail_en = "Editing a command never executes it", .detail_de = "Bearbeiten führt keinen Befehl aus" },
        .custom_shortcuts => .{ .page = "keybinds", .en = "Custom shortcuts", .de = "Eigene Tastenkürzel", .detail_en = "Add, edit, delete and record custom bindings", .detail_de = "Eigene Belegungen hinzufügen, bearbeiten, löschen und aufnehmen" },
        .keybinds_extra => extra("keybinds"),
        .rules => .{ .page = "rules", .en = "Window rules", .de = "Fensterregeln", .detail_en = "Ordered conditions and effects", .detail_de = "Geordnete Bedingungen und Wirkungen", .collapsed = false },
        .game => .{ .page = "rules", .en = "Game mode", .de = "Spielmodus", .detail_en = "Remainder layout, fallback and spacing", .detail_de = "Restanordnung, Rückfall und Abstände" },
        .rule_sources => .{ .page = "rules", .en = "Saved rule inventory", .de = "Gespeicherte Regeln", .detail_en = "Source order and preserved settings", .detail_de = "Quellenreihenfolge und beibehaltene Einstellungen" },
        .rules_extra => extra("rules"),
        .display_policy => .{ .page = "displays", .en = "Display policy", .de = "Bildschirmrichtlinien", .detail_en = "Startup, reload, fallback and compatibility", .detail_de = "Start, Neuladen, Rückfall und Kompatibilität" },
        .display_sources => .{ .page = "displays", .en = "Additional display configuration", .de = "Weitere Bildschirmkonfiguration", .detail_en = "Connected and offline output declarations", .detail_de = "Deklarationen verbundener und getrennter Ausgaben" },
        .displays_extra => extra("displays"),
        .status => .{ .page = "advanced", .en = "Configuration status", .de = "Konfigurationsstatus", .detail_en = "Save, reload, synchronization and recovery", .detail_de = "Speichern, Neuladen, Synchronisierung und Wiederherstellung", .collapsed = false },
        .raw => .{ .page = "advanced", .en = "Raw configuration", .de = "Konfigurationsquellen", .detail_en = "Six sources; raw edits own the complete file", .detail_de = "Sechs Quellen; Rohänderungen betreffen die ganze Datei" },
        .request => .{ .page = "advanced", .en = "Full draft request", .de = "Vollständiger Entwurfsauftrag", .detail_en = "JSON and explicit user overrides", .detail_de = "JSON und explizite Benutzerüberschreibungen" },
        .receipts => .{ .page = "advanced", .en = "Operation details", .de = "Vorgangsdetails", .detail_en = "Candidate effects, receipts and display rollback", .detail_de = "Auswirkungen, Belege und Bildschirmrücknahme" },
    };
}
fn extra(page: []const u8) Spec {
    return .{ .page = page, .en = "Additional settings", .de = "Zusätzliche Einstellungen", .detail_en = "Further fields supplied by this Aqueous helper", .detail_de = "Weitere Felder dieses Aqueous-Helfers" };
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
        if (one(id, &.{ "layout.border_width", "layout.border_focused" })) return .borders;
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
const page_en = [_][]const u8{ "Appearance", "Layouts", "Input", "Shortcuts", "Rules", "Displays", "Advanced" };
const page_de = [_][]const u8{ "Darstellung", "Anordnungen", "Eingabe", "Tastenkürzel", "Regeln", "Bildschirme", "Erweitert" };
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
pub fn footer(a: std.mem.Allocator, base: m.Value, draft: m.Value, german: bool) ![:0]const u8 {
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
    if (german) try out.writer.print("{d} ungespeicherte Änderungen · ", .{edits}) else try out.writer.print("{d} unsaved changes · ", .{edits});
    var first = true;
    for (affected, 0..) |yes, i| if (yes) {
        if (!first) try out.writer.writeAll(", ");
        try out.writer.writeAll(if (german) page_de[i] else page_en[i]);
        first = false;
    };
    if (first) try out.writer.writeAll(if (german) "Vollständigen Entwurf prüfen" else "Review the full request");
    return a.dupeZ(u8, out.written());
}
/// Human review includes display operations too; source metadata is not an edit.
pub fn summary(a: std.mem.Allocator, base: m.Value, draft: m.Value, german: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    for (m.list(m.get(draft, "changes"))) |change| {
        const id = m.str(m.get(change, "id"));
        const f = m.field(base, id) orelse .null;
        const title = if (f == .null) id else m.str(m.get(f, "label"));
        const page = pageIndex(f);
        try out.writer.print("• {s}: {s}\n  {s} → {s}\n", .{ if (german) page_de[page] else page_en[page], title, try std.json.Stringify.valueAlloc(a, m.get(f, "value"), .{}), try std.json.Stringify.valueAlloc(a, m.get(change, "value"), .{}) });
    }
    const keys = [_][]const u8{ "display_declaration_changes", "monitor_changes", "raw_files", "custom_keybind_changes", "window_rule_changes", "snap_zone_changes", "snap_layouts", "default_snap_layout", "sync_typography", "sync_cursor", "normalize_stacking", "create_user_override" };
    const en = [_][]const u8{ "Displays: declarations and profiles", "Displays: monitor settings", "Advanced: raw configuration files", "Shortcuts: custom bindings", "Rules: window rules", "Layouts: legacy snap zones", "Layouts: named snap layouts", "Layouts: default snap layout", "Appearance: font synchronization", "Appearance: cursor synchronization", "Layouts: normalize stacking aliases", "Advanced: create user override" };
    const de = [_][]const u8{ "Bildschirme: Deklarationen und Profile", "Bildschirme: Monitoreinstellungen", "Erweitert: Konfigurationsdateien", "Tastenkürzel: eigene Belegungen", "Regeln: Fensterregeln", "Anordnungen: bisherige Einrastzonen", "Anordnungen: benannte Einrastanordnungen", "Anordnungen: Standard-Einrastanordnung", "Darstellung: Schriftsynchronisierung", "Darstellung: Zeigersynchronisierung", "Anordnungen: Stapelungsaliase vereinheitlichen", "Erweitert: Benutzerüberschreibung erstellen" };
    for (keys, 0..) |key, i| {
        if (!changed(draft, key)) continue;
        try out.writer.print("• {s}\n", .{if (german) de[i] else en[i]});
    }
    if (out.written().len == 0) try out.writer.writeAll(if (german) "Vollständigen Entwurf in Erweitert prüfen." else "Review the complete draft in Advanced.");
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
}
test "search uses id label or chord without rewriting field values" {
    try std.testing.expect(matches("TERMINAL", "spawn_terminal", "Open terminal", "Super+Return"));
    try std.testing.expect(matches("super+return", "spawn_terminal", "Open terminal", "Super+Return"));
    try std.testing.expect(!matches("missing", "spawn_terminal", "Open terminal", "Super+Return"));
}

test "review includes values and collection deletion without counting empty operation lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try m.parse(a, "{\"fields\":[{\"id\":\"input.repeat_rate\",\"category\":\"input\",\"label\":\"Repeat rate\",\"value\":25}]}", 1024);
    const draft = try m.parse(a, "{\"changes\":[{\"id\":\"input.repeat_rate\",\"value\":38}],\"monitor_changes\":[],\"raw_files\":{},\"snap_layouts\":[]}", 1024);
    try std.testing.expectEqualStrings("2 unsaved changes · Layouts, Input", try footer(a, base, draft, false));
    const review = try summary(a, base, draft, false);
    try std.testing.expect(std.mem.indexOf(u8, review, "25 → 38") != null);
    try std.testing.expect(std.mem.indexOf(u8, review, "named snap layouts") != null);
    try std.testing.expect(std.mem.indexOf(u8, review, "monitor settings") == null);
    try std.testing.expectEqual(@as(i64, 38), draftValue(base, draft, "input.repeat_rate").integer);
}
