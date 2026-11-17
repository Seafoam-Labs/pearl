//! Field-level search index for the settings navigation search box.
//!
//! Aqueous hits are derived from the live helper schema, so they cannot drift.
//! Pearl hits come from the static manifest below: drift is accepted for the
//! initial version and the structural fix (co-located metadata + coverage gate)
//! is deferred — see docs/SETTINGS_FIELD_SEARCH_PLAN.md.
const std = @import("std");
const nav = @import("../desktop/settings_navigation.zig");
const m = @import("../config/aqueous_model.zig");
const map = @import("../config/aqueous_presentation.zig");
const i18n = @import("i18n");

pub const Kind = enum { aqueous, pearl };

pub const Hit = struct {
    id: [:0]const u8,
    label: [:0]const u8,
    breadcrumb: [:0]const u8,
    route: nav.Route,
    /// Aqueous section id; null for Pearl hits and the shared Advanced page.
    section: ?[:0]const u8 = null,
    kind: Kind,
};

/// Case-insensitive substring match over the searchable text of a setting. The
/// needle must already be lowercased.
pub fn matches(needle_lower: []const u8, id: []const u8, label: []const u8, description: []const u8, keywords: []const u8) bool {
    if (needle_lower.len == 0) return false;
    return nav.containsIgnoreCase(id, needle_lower) or
        nav.containsIgnoreCase(label, needle_lower) or
        nav.containsIgnoreCase(description, needle_lower) or
        nav.containsIgnoreCase(keywords, needle_lower);
}

fn sectionTitle(section: []const u8) [:0]const u8 {
    if (std.mem.eql(u8, section, "appearance")) return i18n.mark("Window appearance");
    if (std.mem.eql(u8, section, "layouts")) return i18n.mark("Layouts");
    if (std.mem.eql(u8, section, "input")) return i18n.mark("Input");
    if (std.mem.eql(u8, section, "keybinds")) return i18n.mark("Shortcuts");
    if (std.mem.eql(u8, section, "rules")) return i18n.mark("Rules");
    if (std.mem.eql(u8, section, "displays")) return i18n.mark("Displays");
    return i18n.mark("Advanced");
}

/// Append every Aqueous schema field matching the needle. Strings are duplicated
/// into `alloc` so hits stay valid until the caller resets that arena.
pub fn collectAqueous(alloc: std.mem.Allocator, snapshot: m.Value, needle_lower: []const u8, out: *std.ArrayList(Hit)) !void {
    for (m.list(m.get(snapshot, "fields"))) |field| {
        const id = m.str(m.get(field, "id"));
        const label = i18n.aqueousField(id, .label, m.str(m.get(field, "label")));
        const description = i18n.aqueousField(id, .description, m.str(m.get(field, "description")));
        if (!matches(needle_lower, id, label, description, "")) continue;
        const spec = map.spec(map.group(field));
        const advanced = std.mem.eql(u8, spec.page, "advanced");
        const breadcrumb = try std.fmt.allocPrintSentinel(alloc, "{s} › {s}", .{ i18n.tr(sectionTitle(spec.page)), i18n.tr(spec.en) }, 0);
        try out.append(alloc, .{
            .id = try alloc.dupeSentinel(u8, id, 0),
            .label = try alloc.dupeSentinel(u8, label, 0),
            .breadcrumb = breadcrumb,
            .route = if (advanced) .advanced else .aqueous,
            .section = if (advanced) null else try alloc.dupeSentinel(u8, spec.page, 0),
            .kind = .aqueous,
        });
    }
}

pub const PearlEntry = struct {
    id: []const u8,
    label: [:0]const u8,
    description: [:0]const u8,
    route: nav.Route,
    breadcrumb: [:0]const u8,
    keywords: []const u8 = "",
};

/// Static Pearl manifest. `id` resolves to a live control (a bar_fields path, a
/// bar_view control id, "launchers", or "raw"); reveal falls back to the page
/// heading when a control cannot be resolved.
pub const pearl_manifest = [_]PearlEntry{
    .{ .id = "bar.widget.launcher", .label = "Launcher", .description = "Open your applications", .route = .bar, .breadcrumb = "Bar & dock › Widgets", .keywords = "launcher applications start menu app button" },
    .{ .id = "bar.icon.expand", .label = "Launcher icon", .description = "Change the launcher button icon", .route = .bar, .breadcrumb = "Bar & dock › Launcher", .keywords = "launcher icon image picture" },
    .{ .id = "launchers", .label = "Application launchers", .description = "Remove remembered launcher choices", .route = .bar, .breadcrumb = "Bar & dock › Application launchers", .keywords = "launcher remembered default applications choices" },
    .{ .id = "bar.mode", .label = "Bar visibility", .description = "Always show the bar or autohide it", .route = .bar, .breadcrumb = "Bar & dock", .keywords = "bar visibility autohide always" },
    .{ .id = "bar.edge", .label = "Bar edge", .description = "Screen edge for the bar", .route = .bar, .breadcrumb = "Bar & dock", .keywords = "bar edge top bottom left right" },
    .{ .id = "bar.size", .label = "Bar size", .description = "Bar thickness in pixels", .route = .bar, .breadcrumb = "Bar & dock", .keywords = "bar size height thickness" },
    .{ .id = "bar.radius", .label = "Bar corner radius", .description = "Round the bar corners", .route = .bar, .breadcrumb = "Bar & dock", .keywords = "bar radius corner rounded" },
    .{ .id = "bar.background_opacity.percent", .label = "Bar background opacity", .description = "Bar background transparency", .route = .bar, .breadcrumb = "Bar & dock", .keywords = "bar opacity transparency background" },
    .{ .id = "dock.enabled", .label = "Show dock", .description = "Enable the dock", .route = .bar, .breadcrumb = "Bar & dock › Dock", .keywords = "dock enable show" },
    .{ .id = "dock.edge", .label = "Dock edge", .description = "Screen edge for the dock", .route = .bar, .breadcrumb = "Bar & dock › Dock", .keywords = "dock edge position" },
    .{ .id = "dock.mode", .label = "Dock visibility", .description = "Always, autohide or intelligent dock", .route = .bar, .breadcrumb = "Bar & dock › Dock", .keywords = "dock visibility autohide intelligent" },
    .{ .id = "dock.icon_size", .label = "Dock icon size", .description = "Dock icon size in pixels", .route = .bar, .breadcrumb = "Bar & dock › Dock", .keywords = "dock icon size" },
    .{ .id = "popup.placement", .label = "Flyout placement", .description = "Anchored or centered flyouts", .route = .bar, .breadcrumb = "Bar & dock › Flyouts", .keywords = "flyout popup placement anchored centered" },
    .{ .id = "raw", .label = "Pearl preferences JSON", .description = "Edit the full preferences document", .route = .advanced, .breadcrumb = "Advanced", .keywords = "json raw preferences config document advanced" },
};

/// Append every Pearl manifest entry matching the needle. Labels and
/// breadcrumbs are localized; strings are duplicated into `alloc`.
pub fn collectPearl(alloc: std.mem.Allocator, needle_lower: []const u8, out: *std.ArrayList(Hit)) !void {
    for (pearl_manifest) |entry| {
        const label = i18n.dtr("pearl", entry.label);
        const description = i18n.dtr("pearl", entry.description);
        if (!matches(needle_lower, entry.id, label, description, entry.keywords)) continue;
        try out.append(alloc, .{
            .id = try alloc.dupeSentinel(u8, entry.id, 0),
            .label = try alloc.dupeSentinel(u8, label, 0),
            .breadcrumb = try alloc.dupeSentinel(u8, i18n.dtr("pearl", entry.breadcrumb), 0),
            .route = entry.route,
            .section = null,
            .kind = .pearl,
        });
    }
}

test "pearl manifest ids are unique and resolve to a known route" {
    const t = std.testing;
    var seen = std.StringHashMap(void).init(t.allocator);
    defer seen.deinit();
    for (pearl_manifest) |entry| {
        try t.expect(!seen.contains(entry.id));
        try seen.put(entry.id, {});
        try t.expect(entry.label.len > 0 and entry.breadcrumb.len > 0);
    }
    // The launcher acceptance example must be covered.
    try t.expect(seen.contains("bar.widget.launcher"));
    try t.expect(seen.contains("bar.icon.expand"));
    try t.expect(seen.contains("launchers"));
}

test "matches is case-insensitive across id label description and keywords" {
    const t = std.testing;
    try t.expect(matches("launcher", "bar.widget.launcher", "Launcher", "Open your applications", ""));
    try t.expect(matches("start menu", "toggle_start_menu", "Toggle start menu", "", "launcher"));
    try t.expect(matches("json", "raw", "Pearl preferences JSON", "", ""));
    try t.expect(!matches("missing", "bar.widget.launcher", "Launcher", "Open your applications", ""));
    try t.expect(!matches("", "raw", "Pearl preferences JSON", "", ""));
}
