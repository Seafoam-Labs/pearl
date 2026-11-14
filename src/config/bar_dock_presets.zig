//! Shipped bar and dock layouts. A preset owns only the bar and dock settings it
//! names, so everything else in the document — and every display override — is
//! left alone. Adding a bar or dock setting, or a new builtin widget, needs no
//! change here: `bar` and `dock` keys are matched against the live struct fields
//! and `widgets` against the live widget enum.
const std = @import("std");
const prefs = @import("preferences.zig");
const policy = @import("../desktop/policy.zig");
const clock_policy = @import("../desktop/clock_policy.zig");

const source = @embedFile("bar_dock_presets.json");

/// Widget references a preset may not carry: they belong to the user, not to a
/// shipped layout. `groups` is expressed as `widgets` so plugin and clock
/// references survive, `clocks` are the user's own definitions (timezones) and
/// `launcher_icon` is the user's chosen artwork.
const user_owned = [_][]const u8{ "groups", "clocks", "launcher_icon" };

pub const Widgets = struct {
    left: []const []const u8 = &.{},
    center: []const []const u8 = &.{},
    right: []const []const u8 = &.{},
};

pub const Preset = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8 = "",
    /// Keys are `prefs.Bar` field names, values are parsed into that field's type.
    bar: ?std.json.ObjectMap = null,
    /// Keys are `prefs.Dock` field names.
    dock: ?std.json.ObjectMap = null,
    /// Builtin widget ids per group; null leaves the current layout untouched.
    widgets: ?Widgets = null,
};

const Wire = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8 = "",
    bar: ?std.json.Value = null,
    dock: ?std.json.Value = null,
    widgets: ?Widgets = null,
};

fn objectOf(value: ?std.json.Value) !?std.json.ObjectMap {
    const found = value orelse return null;
    if (found != .object) return error.InvalidPreset;
    return found.object;
}

/// Every shipped preset. Strings belong to `alloc`.
pub fn catalog(alloc: std.mem.Allocator) ![]const Preset {
    const wire = try std.json.parseFromSliceLeaky([]Wire, alloc, source, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
    const result = try alloc.alloc(Preset, wire.len);
    for (wire, result) |entry, *out| {
        if (!identifier(entry.id) or entry.name.len == 0) return error.InvalidPreset;
        out.* = .{ .id = entry.id, .name = entry.name, .description = entry.description, .bar = try objectOf(entry.bar), .dock = try objectOf(entry.dock), .widgets = entry.widgets };
    }
    return result;
}

pub fn find(alloc: std.mem.Allocator, id: []const u8) !?Preset {
    for (try catalog(alloc)) |preset| if (std.mem.eql(u8, preset.id, id)) return preset;
    return null;
}

/// Preset identifiers are recorded in the preferences document, so they follow
/// the same conservative charset as other stored ids.
pub fn identifier(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

fn userOwned(comptime name: []const u8) bool {
    for (user_owned) |owned| if (std.mem.eql(u8, name, owned)) return true;
    return false;
}

fn mergeFields(alloc: std.mem.Allocator, comptime T: type, target: anytype, overrides: std.json.ObjectMap) !void {
    const info = comptime @typeInfo(T).@"struct";
    var matched: usize = 0;
    inline for (info.field_names, info.field_types) |name, field_type| {
        if (overrides.get(name)) |value| {
            if (comptime userOwned(name)) return error.PresetFieldNotEditable;
            matched += 1;
            @field(target, name) = try std.json.parseFromValueLeaky(field_type, alloc, value, .{ .allocate = .alloc_always });
        }
    }
    // A key that names no field is a typo in the shipped catalog, not a preset
    // from a newer Pearl; refuse it instead of silently ignoring the layout.
    if (matched != overrides.count()) return error.UnknownPresetField;
}

/// Builtin references a preset may list. Anything else — `plugin:<id>/main` or a
/// `clock:<id>` definition — is user content and is carried over unchanged.
fn builtin(id: []const u8) bool {
    return std.meta.stringToEnum(policy.Item, id) != null;
}

fn mergedGroups(alloc: std.mem.Allocator, current: policy.Groups, widgets: Widgets) !policy.Groups {
    const shipped = [_][]const []const u8{ widgets.left, widgets.center, widgets.right };
    const kept = [_][]const u8{ current.left, current.center, current.right };
    var result: policy.Groups = .{ .left = "", .center = "", .right = "" };
    var parts: [3]std.ArrayList([]const u8) = .{ .empty, .empty, .empty };
    for (0..3) |index| {
        try parts[index].appendSlice(alloc, shipped[index]);
        var references = std.mem.splitScalar(u8, kept[index], ',');
        while (references.next()) |reference| {
            if (reference.len == 0 or builtin(reference)) continue;
            try parts[index].append(alloc, reference);
        }
        const text = try std.mem.join(alloc, ",", parts[index].items);
        switch (index) {
            0 => result.left = text,
            1 => result.center = text,
            else => result.right = text,
        }
    }
    try result.validate();
    return result;
}

/// Rewrite the bar and dock settings the preset owns. The caller's document is
/// modified in place; strings are allocated from `alloc`.
pub fn merge(alloc: std.mem.Allocator, document: *prefs.Preferences, preset: Preset) !void {
    if (preset.bar) |bar| try mergeFields(alloc, prefs.Bar, &document.bar, bar);
    if (preset.dock) |dock| try mergeFields(alloc, prefs.Dock, &document.dock, dock);
    if (preset.widgets) |widgets| document.bar.groups = try mergedGroups(alloc, document.bar.groups, widgets);
    document.bar_dock_preset = try alloc.dupe(u8, preset.id);
}

/// Apply a shipped preset to a preferences document and return the new text.
pub fn apply(alloc: std.mem.Allocator, text: []const u8, id: []const u8) ![]const u8 {
    var document = try prefs.parse(alloc, text);
    const preset = try find(alloc, id) orelse return error.UnknownPreset;
    try merge(alloc, &document, preset);
    try document.validate();
    const result = try std.json.Stringify.valueAlloc(alloc, document, .{ .whitespace = .indent_2 });
    if (result.len > prefs.max_bytes) return error.DocumentTooLarge;
    return result;
}

fn edgeName(object: ?std.json.ObjectMap) ?[]const u8 {
    const value = (object orelse return null).get("edge") orelse return null;
    return if (value == .string) value.string else null;
}

/// One line describing what a preset changes, for the settings summary and tests.
pub fn summary(alloc: std.mem.Allocator, preset: Preset) ![]const u8 {
    var items = std.ArrayList([]const u8).empty;
    if (edgeName(preset.bar)) |edge| try items.append(alloc, try std.fmt.allocPrint(alloc, "Bar {s}", .{edge}));
    // A preset that switches the standalone dock off hosts the applications
    // strip in the bar instead.
    const standalone = if (preset.dock) |dock| blk: {
        const enabled = dock.get("enabled") orelse break :blk true;
        break :blk enabled != .bool or enabled.bool;
    } else true;
    if (!standalone) try items.append(alloc, "Applications in bar");
    if (standalone) if (edgeName(preset.dock)) |edge|
        try items.append(alloc, try std.fmt.allocPrint(alloc, "Dock {s}", .{edge}));
    return std.mem.join(alloc, " · ", items.items);
}

test "shipped presets are well formed and only name real bar and dock settings" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const presets = try catalog(alloc);
    try t.expect(presets.len >= 2);
    for (presets, 0..) |preset, i| {
        for (presets[0..i]) |old| try t.expect(!std.mem.eql(u8, old.id, preset.id));
        try t.expect(identifier(preset.id));
        try t.expect(preset.name.len > 0 and preset.widgets != null);
        for ([_]?std.json.ObjectMap{ preset.bar, preset.dock }) |overrides| {
            const listed = overrides orelse continue;
            try t.expect(listed.count() > 0);
            for (user_owned) |name| try t.expect(!listed.contains(name));
        }
        // The catalog must produce a document that passes the strict validator.
        const applied = try apply(alloc, "{}", preset.id);
        const document = try prefs.parse(alloc, applied);
        try t.expectEqualStrings(preset.id, document.bar_dock_preset);
        try t.expectEqualStrings(preset.id, (try find(alloc, preset.id)).?.id);
        try t.expect((try summary(alloc, preset)).len > 0);
    }
    try t.expect((try find(alloc, "nope")) == null);
    try t.expectError(error.UnknownPreset, apply(alloc, "{}", "nope"));
    try t.expectError(error.UnknownField, apply(alloc, "{\"future\":1}", "macos"));
}

test "the macOS and Windows presets describe their layouts" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const macos = try prefs.parse(alloc, try apply(alloc, "{}", "macos"));
    try t.expectEqual(prefs.Edge.top, macos.bar.edge);
    try t.expectEqual(@as(u16, 32), macos.bar.size);
    try t.expect(macos.bar.attached and !macos.bar.islands);
    try t.expectEqualStrings("workspaces,title", macos.bar.groups.left);
    try t.expectEqualStrings("", macos.bar.groups.center);
    try t.expect(macos.dock.enabled);
    try t.expectEqual(prefs.Edge.bottom, macos.dock.edge);
    try t.expectEqual(@as(u8, 48), macos.dock.icon_size);
    const windows = try prefs.parse(alloc, try apply(alloc, "{}", "windows"));
    try t.expectEqual(prefs.Edge.bottom, windows.bar.edge);
    try t.expectEqualStrings("launcher,dock", windows.bar.groups.center);
    // The taskbar hosts the applications strip, so the standalone dock is off.
    try t.expect(!windows.dock.enabled);
    try t.expectEqual(@as(u8, 32), windows.dock.icon_size);
    try t.expectEqualStrings("Bar bottom · Applications in bar", try summary(alloc, (try find(alloc, "windows")).?));
    try t.expectEqualStrings("Bar top · Dock bottom", try summary(alloc, (try find(alloc, "macos")).?));
}

test "presets leave unrelated preferences, display overrides and user widgets alone" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const before: prefs.Preferences = .{
        .font_size = 19,
        .weather = .{ .location = "Berlin", .latitude = 52.52, .longitude = 13.405, .units = .fahrenheit },
        .pinned_apps = &.{"org.example.App.desktop"},
        .bar = .{ .clocks = &.{.{ .id = "berlin", .timezone = "Europe/Berlin" }}, .launcher_icon = .{ .kind = .theme, .value = "start-here" }, .groups = .{ .left = "launcher,plugin:demo/main", .center = "clock:berlin", .right = "media,tray,audio,network,battery,notifications,clipboard,keyboard,control" } },
        .outputs = &.{.{ .connector = "DP-1", .bar = .{ .size = 64 }, .dock = .{ .edge = .left, .icon_size = 64 } }},
        .bar_hidden_outputs = &.{"DP-2"},
    };
    const text = try std.json.Stringify.valueAlloc(alloc, before, .{});
    const after = try prefs.parse(alloc, try apply(alloc, text, "macos"));
    try t.expectEqual(@as(u8, 19), after.font_size);
    // Location-bearing widgets keep the user's own data.
    try t.expectEqualDeep(before.weather, after.weather);
    try t.expectEqualDeep(before.bar.clocks, after.bar.clocks);
    try t.expectEqualDeep(before.bar.launcher_icon, after.bar.launcher_icon);
    try t.expectEqualDeep(before.pinned_apps, after.pinned_apps);
    // Plugin and clock references survive in the group they were in.
    try t.expectEqualStrings("workspaces,title,plugin:demo/main", after.bar.groups.left);
    try t.expectEqualStrings("clock:berlin", after.bar.groups.center);
    try t.expect(std.mem.endsWith(u8, after.bar.groups.right, ",clock"));
    // Display overrides and hidden bars are untouched: they still take priority.
    try t.expectEqualDeep(before.outputs, after.outputs);
    try t.expectEqualDeep(before.bar_hidden_outputs, after.bar_hidden_outputs);
    try t.expectEqual(@as(u16, 64), after.forOutput("DP-1").size);
    try t.expectEqual(prefs.Edge.left, after.dockForOutput("DP-1").edge);
}

test "applying a preset twice is stable and rejects keys that are not settings" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const once = try apply(alloc, "{}", "windows");
    try t.expectEqualStrings(once, try apply(alloc, once, "windows"));
    var document = try prefs.parse(alloc, "{}");
    // A typo in the shipped catalog is refused rather than silently ignored.
    const typo: Preset = .{ .id = "typo", .name = "Typo", .bar = (try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"edg\":\"top\"}", .{})).object };
    try t.expectError(error.UnknownPresetField, merge(alloc, &document, typo));
    // Settings that belong to the user are never preset-owned.
    const artwork: Preset = .{ .id = "artwork", .name = "Artwork", .bar = (try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"launcher_icon\":{\"kind\":\"default\"}}", .{})).object };
    try t.expectError(error.PresetFieldNotEditable, merge(alloc, &document, artwork));
    try t.expectEqualStrings("", document.bar_dock_preset);
}

test "preset identifiers reject paths, spaces and control characters" {
    for ([_][]const u8{ "macos", "windows-11", "a_b" }) |id| try std.testing.expect(identifier(id));
    for ([_][]const u8{ "", "../macos", "mac os", "a/b", "a\x00", @import("test_strings").string("a", 65) }) |id| try std.testing.expect(!identifier(id));
}
