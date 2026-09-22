//! Ordered presentation of the existing comma-separated bar groups. Arena-owned.
const std = @import("std");
const policy = @import("../desktop/policy.zig");
const prefs = @import("../config/preferences.zig");
pub const Group = enum { left, center, right };
pub const groups = std.enums.values(Group);
pub const Metadata = struct { name: [:0]const u8, description: [:0]const u8, icon: [:0]const u8 };
pub fn metadata(item: policy.Item) Metadata {
    return switch (item) {
        .running_apps => .{ .name = "Running applications", .description = "Open windows across all workspaces and displays", .icon = "pearl-application-x-executable-symbolic" },
        .launcher => .{ .name = "Launcher", .description = "Open your applications · Required", .icon = @import("../desktop/launcher_icon_policy.zig").default_icon },
        .workspaces => .{ .name = "Workspaces", .description = "Switch between workspaces", .icon = "pearl-view-grid-symbolic" },
        .title => .{ .name = "Window title", .description = "Name of the active window", .icon = "pearl-window-symbolic" },
        .clock => .{ .name = "Clock", .description = "Time, date and calendar", .icon = "pearl-content-loading-symbolic" },
        .keyboard => .{ .name = "Keyboard layout", .description = "See the active keyboard layout", .icon = "pearl-emblem-system-symbolic" },
        .overview => .{ .name = "Overview", .description = "See your open windows", .icon = "pearl-view-grid-symbolic" },
        .control => .{ .name = "Control center", .description = "Quick settings and controls", .icon = "pearl-emblem-system-symbolic" },
        .audio => .{ .name = "Sound", .description = "Volume and audio devices", .icon = "pearl-audio-volume-high-symbolic" },
        .battery => .{ .name = "Battery", .description = "Charge and power status", .icon = "pearl-battery-symbolic" },
        .network => .{ .name = "Network", .description = "Connection status and networks", .icon = "pearl-network-wireless-symbolic" },
        .bluetooth => .{ .name = "Bluetooth", .description = "Connections and paired devices", .icon = "pearl-bluetooth-active-symbolic" },
        .notifications => .{ .name = "Notifications", .description = "Alerts and notification history", .icon = "pearl-notifications-symbolic" },
        .media => .{ .name = "Media", .description = "Playback and track information", .icon = "pearl-media-symbolic" },
        .tray => .{ .name = "System tray", .description = "Background application icons", .icon = "pearl-view-grid-symbolic" },
        .clipboard => .{ .name = "Clipboard", .description = "Recent copied items", .icon = "pearl-edit-copy-symbolic" },
        .wallpaper => .{ .name = "Wallpaper", .description = "Browse a folder and set the wallpaper", .icon = "pearl-image-symbolic" },
    };
}
pub fn groupLabel(group: Group, edge: prefs.Edge) [:0]const u8 {
    const vertical = edge == .left or edge == .right;
    return switch (group) {
        .left => if (vertical) "Top" else "Left",
        .center => "Center",
        .right => if (vertical) "Bottom" else "Right",
    };
}
pub const Action = union(enum) { add: Group, move: Group, earlier, later, remove };
pub const Layout = struct {
    items: [3]std.ArrayList([]const u8) = .{ .empty, .empty, .empty },
    pub fn parse(a: std.mem.Allocator, value: policy.Groups) !Layout {
        try value.validate();
        var result: Layout = .{};
        for ([_][]const u8{ value.left, value.center, value.right }, 0..) |text, i| {
            if (text.len == 0) continue;
            var parts = std.mem.splitScalar(u8, text, ',');
            while (parts.next()) |part| try result.items[i].append(a, try a.dupe(u8, part));
        }
        return result;
    }
    pub fn find(self: Layout, id: []const u8) ?struct { group: Group, index: usize } {
        for (self.items, 0..) |list, g| for (list.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, id)) return .{ .group = @enumFromInt(g), .index = i };
        };
        return null;
    }
    pub fn serialize(self: Layout, a: std.mem.Allocator) !policy.Groups {
        const value: policy.Groups = .{ .left = try std.mem.join(a, ",", self.items[0].items), .center = try std.mem.join(a, ",", self.items[1].items), .right = try std.mem.join(a, ",", self.items[2].items) };
        try value.validate();
        return value;
    }
    /// Return a new validated layout; a failed action never changes the input.
    pub fn change(self: Layout, a: std.mem.Allocator, id: []const u8, action: Action) !Layout {
        var next = try Layout.parse(a, try self.serialize(a));
        const found = next.find(id);
        switch (action) {
            .add => |to| {
                if (found != null) return error.AlreadyPlaced;
                try next.items[@intFromEnum(to)].append(a, try a.dupe(u8, id));
            },
            else => {
                const pos = found orelse return error.WidgetNotFound;
                const list = &next.items[@intFromEnum(pos.group)];
                switch (action) {
                    .remove => {
                        if (std.mem.eql(u8, id, "launcher")) return error.LauncherRequired;
                        _ = list.orderedRemove(pos.index);
                    },
                    .move => |to| {
                        if (to == pos.group) return error.SameGroup;
                        const item = list.orderedRemove(pos.index);
                        try next.items[@intFromEnum(to)].append(a, item);
                    },
                    .earlier, .later => {
                        if ((action == .earlier and pos.index == 0) or (action == .later and pos.index + 1 == list.items.len)) return error.OrderBoundary;
                        const index = if (action == .earlier) pos.index - 1 else pos.index + 1;
                        std.mem.swap([]const u8, &list.items[pos.index], &list.items[index]);
                    },
                    .add => unreachable,
                }
            },
        }
        _ = try next.serialize(a);
        return next;
    }
};
pub fn patch(a: std.mem.Allocator, text: []const u8, id: []const u8, action: Action) ![]const u8 {
    var document = try prefs.parse(a, text);
    const layout = try Layout.parse(a, document.bar.groups);
    document.bar.groups = try (try layout.change(a, id, action)).serialize(a);
    try document.validate();
    const result = try std.json.Stringify.valueAlloc(a, document, .{ .whitespace = .indent_2 });
    if (result.len > prefs.max_bytes) return error.DocumentTooLarge;
    return result;
}
pub fn patchWorkspaceMode(a: std.mem.Allocator, text: []const u8, mode: prefs.WorkspaceMode) ![]const u8 {
    var document = try prefs.parse(a, text);
    const layout = try Layout.parse(a, document.bar.groups);
    if (layout.find("workspaces") == null) return error.WidgetNotFound;
    document.bar.workspace_mode = mode;
    try document.validate();
    const result = try std.json.Stringify.valueAlloc(a, document, .{ .whitespace = .indent_2 });
    if (result.len > prefs.max_bytes) return error.DocumentTooLarge;
    return result;
}
/// Small optional backend catalog. Existing references do not depend on discovery.
pub const Plugin = struct { id: []const u8, name: []const u8, digest: []const u8, available: bool, status: []const u8 };
pub const Catalog = struct { bar_widgets: ?[]const Plugin = null };
pub fn eligible(document: prefs.Preferences, plugin: Plugin) bool {
    const config = document.plugins.find(plugin.id) orelse return false;
    return plugin.available and config.enabled and config.placement.mode == .bar and config.digest.len == 64 and std.mem.eql(u8, config.digest, plugin.digest);
}

test "bar selections round trip and move Launcher atomically without altering unrelated preferences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const defaults: prefs.Preferences = .{ .font_size = 17, .outputs = &.{.{ .connector = "DP-1", .bar = .{ .groups = .{ .center = "plugin:missing/main" } }, .dock = .{ .enabled = false } }} };
    const text = try std.json.Stringify.valueAlloc(a, defaults, .{});
    const moved = try prefs.parse(a, try patch(a, text, "launcher", .{ .move = .right }));
    try std.testing.expectEqualStrings("workspaces,title", moved.bar.groups.left);
    try std.testing.expect(std.mem.endsWith(u8, moved.bar.groups.right, ",launcher"));
    try std.testing.expectEqualDeep(defaults.outputs, moved.outputs);
    try std.testing.expectEqual(defaults.font_size, moved.font_size);
    const roundtrip = try (try Layout.parse(a, defaults.bar.groups)).serialize(a);
    try std.testing.expectEqualDeep(defaults.bar.groups, roundtrip);
}
test "bar actions protect required controls, uniqueness, boundaries, invalid drafts and missing plugins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value: policy.Groups = .{ .left = "launcher,plugin:missing/main", .center = "", .right = "" };
    const layout = try Layout.parse(a, value);
    try std.testing.expectError(error.LauncherRequired, layout.change(a, "launcher", .remove));
    try std.testing.expectError(error.AlreadyPlaced, layout.change(a, "launcher", .{ .add = .right }));
    try std.testing.expectError(error.OrderBoundary, layout.change(a, "launcher", .earlier));
    try std.testing.expectError(error.WidgetNotFound, layout.change(a, "clock", .remove));
    try std.testing.expectError(error.InvalidGroups, layout.change(a, "unknown", .{ .add = .center }));
    const next = try (try layout.change(a, "plugin:missing/main", .{ .move = .center })).change(a, "clock", .{ .add = .center });
    const reordered = try (try next.change(a, "clock", .earlier)).serialize(a);
    try std.testing.expectEqualStrings("clock,plugin:missing/main", reordered.center);
    const removed = try (try next.change(a, "plugin:missing/main", .remove)).serialize(a);
    try std.testing.expectEqualStrings("clock", removed.center);
    try std.testing.expectEqualDeep(value, try layout.serialize(a));
    try std.testing.expectError(error.InvalidGroups, patch(a, "{\"bar\":{\"groups\":{\"left\":\"unknown\"}}}", "clock", .remove));
    try std.testing.expectError(error.UnknownField, patch(a, "{\"future\":1}", "clock", .remove));
}
test "bar operations enforce serialized byte and plugin count limits before committing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var layout = try Layout.parse(a, .{ .left = "launcher", .center = "", .right = "" });
    for (0..16) |i| layout = try layout.change(a, try std.fmt.allocPrint(a, "plugin:p{d}/main", .{i}), .{ .add = .right });
    try std.testing.expectError(error.InvalidGroups, layout.change(a, "plugin:extra/main", .{ .add = .center }));
    var large: std.ArrayList([]const u8) = .empty;
    for (0..7) |i| try large.append(a, try std.fmt.allocPrint(a, "plugin:{s}{d}/main", .{ "p" ** 57, i }));
    const text = try std.mem.join(a, ",", large.items);
    var full = try Layout.parse(a, .{ .left = "launcher", .center = "", .right = text });
    full = try full.change(a, "clock", .{ .add = .right });
    try std.testing.expectError(error.InvalidGroups, full.change(a, "plugin:overflow/main", .{ .add = .right }));
}
test "bar plugin catalog requires current approval and bar placement" {
    const plugin: Plugin = .{ .id = "demo", .name = "Demo", .digest = "a" ** 64, .available = true, .status = "active" };
    var config: @import("../plugins/model.zig").Config = .{ .id = "demo", .enabled = true, .digest = "a" ** 64 };
    try std.testing.expect(eligible(.{ .plugins = .{ .entries = (&config)[0..1] } }, plugin));
    config.placement.mode = .overlay;
    try std.testing.expect(!eligible(.{ .plugins = .{ .entries = (&config)[0..1] } }, plugin));
    config.placement.mode = .bar;
    config.digest = "b" ** 64;
    try std.testing.expect(!eligible(.{ .plugins = .{ .entries = (&config)[0..1] } }, plugin));
}

test "bar catalog is optional and unavailable or unapproved plugins cannot be added" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const legacy = try std.json.parseFromSliceLeaky(Catalog, alloc, "{\"summary\":\"\",\"rows\":[]}", .{ .ignore_unknown_fields = true });
    try std.testing.expect(legacy.bar_widgets == null);
    var plugin: Plugin = .{ .id = "demo", .name = "Demo", .digest = "a" ** 64, .available = false, .status = "unavailable" };
    var config: @import("../plugins/model.zig").Config = .{ .id = "demo", .enabled = true, .digest = "a" ** 64 };
    try std.testing.expect(!eligible(.{ .plugins = .{ .entries = (&config)[0..1] } }, plugin));
    plugin.available = true;
    config.enabled = false;
    try std.testing.expect(!eligible(.{ .plugins = .{ .entries = (&config)[0..1] } }, plugin));
    config.enabled = true;
    config.digest = "";
    try std.testing.expect(!eligible(.{ .plugins = .{ .entries = (&config)[0..1] } }, plugin));
    try std.testing.expect(!eligible(.{}, plugin));
}

test "running applications is an optional singleton preserved across groups and overrides" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = "{\"bar\":{\"groups\":{\"left\":\"launcher\",\"center\":\"clock\",\"right\":\"control\"}},\"outputs\":[{\"connector\":\"OTHER\",\"bar\":{\"groups\":{\"left\":\"launcher,running_apps\",\"center\":\"clock\",\"right\":\"control\"}}}]}";
    const added = try patch(a, input, "running_apps", .{ .add = .left });
    try t.expectError(error.AlreadyPlaced, patch(a, added, "running_apps", .{ .add = .right }));
    const moved = try patch(a, added, "running_apps", .{ .move = .center });
    const parsed = try prefs.parse(a, moved);
    try t.expectEqualStrings("clock,running_apps", parsed.bar.groups.center);
    try t.expectEqualStrings("launcher,running_apps", parsed.outputs[0].bar.groups.left);
}

test "workspace mode patch preserves layout and unrelated preferences and survives removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var expected: prefs.Preferences = .{ .font_size = 19, .outputs = &.{.{ .connector = "DP-1", .bar = .{ .workspace_mode = .small } }} };
    const text = try std.json.Stringify.valueAlloc(a, expected, .{});
    for (std.enums.values(prefs.WorkspaceMode)) |mode| {
        expected.bar.workspace_mode = mode;
        const changed = try patchWorkspaceMode(a, text, mode);
        try std.testing.expectEqualDeep(expected, try prefs.parse(a, changed));
        const removed = try patch(a, changed, "workspaces", .remove);
        try std.testing.expectError(error.WidgetNotFound, patchWorkspaceMode(a, removed, .large));
        const restored = try patch(a, removed, "workspaces", .{ .add = .center });
        try std.testing.expectEqual(mode, (try prefs.parse(a, restored)).bar.workspace_mode);
    }
}

pub fn patchLauncherIcon(a: std.mem.Allocator, text: []const u8, icon: @import("../desktop/launcher_icon_policy.zig").Config) ![]const u8 {
    var document = try prefs.parse(a, text);
    document.bar.launcher_icon = icon;
    try document.validate();
    const result = try std.json.Stringify.valueAlloc(a, document, .{ .whitespace = .indent_2 });
    if (result.len > prefs.max_bytes) return error.DocumentTooLarge;
    return result;
}
test "launcher icon patch roundtrips and preserves unrelated preferences and output replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var expected: prefs.Preferences = .{ .font_size = 19, .outputs = &.{.{ .connector = "DP-1" }} };
    const text = try std.json.Stringify.valueAlloc(a, expected, .{});
    try std.testing.expectEqualDeep(@import("../desktop/launcher_icon_policy.zig").Config{}, (try prefs.parse(a, "{}")).bar.launcher_icon);
    for ([_]@import("../desktop/launcher_icon_policy.zig").Config{ .{}, .{ .kind = .theme, .value = "pearl-view-grid-symbolic" }, .{ .kind = .file, .value = "/tmp/icon.png" } }) |cfg| {
        expected.bar.launcher_icon = cfg;
        const changed = try prefs.parse(a, try patchLauncherIcon(a, text, cfg));
        try std.testing.expectEqualDeep(expected, changed);
        try std.testing.expectEqualDeep(cfg, changed.forOutput("OTHER").launcher_icon);
        try std.testing.expectEqualDeep(@import("../desktop/launcher_icon_policy.zig").Config{}, changed.forOutput("DP-1").launcher_icon);
    }
}
