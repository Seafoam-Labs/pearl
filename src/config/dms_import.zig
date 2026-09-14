//! Conservative import of the pinned DMS settings v18 / session v4 format.
//! Only appearance/bar/dock preferences are mapped; source objects never change.
const std = @import("std");
const model = @import("preferences.zig");
const Value = std.json.Value;
pub const Report = struct {
    format: u8 = 1,
    dry_run: bool = true,
    preferences: model.Preferences,
    mapped: std.ArrayList([]const u8) = .empty,
    unsupported: std.ArrayList([]const u8) = .empty,
    notes: std.ArrayList([]const u8) = .empty,
};
fn read(alloc: std.mem.Allocator, bytes: []const u8, version: i64) !Value {
    try model.boundedJson(bytes, model.max_bytes, 8);
    const v = try std.json.parseFromSliceLeaky(Value, alloc, bytes, .{});
    if (v != .object) return error.InvalidDmsConfig;
    if (v.object.get("configVersion")) |n| if (n != .integer or n.integer != version) return error.UnsupportedDmsVersion;
    return v;
}
fn boolean(v: Value) !bool {
    return if (v == .bool) v.bool else error.InvalidDmsValue;
}
fn string(v: Value) ![]const u8 {
    return if (v == .string) v.string else error.InvalidDmsValue;
}
fn number(v: Value) !f64 {
    return switch (v) {
        .integer => @floatFromInt(v.integer),
        .float => v.float,
        else => error.InvalidDmsValue,
    };
}
fn edge(v: Value) !model.Edge {
    if (v != .integer) return error.InvalidDmsValue;
    return switch (v.integer) {
        0 => .top,
        1 => .bottom,
        2 => .left,
        3 => .right,
        else => error.UnsupportedDmsPosition,
    };
}
const widget_names = .{
    .{ "launcherButton", "launcher" },     .{ "workspaceSwitcher", "workspaces" },     .{ "focusedWindow", "title" },
    .{ "music", "media" },                 .{ "clock", "clock" },                      .{ "systemTray", "tray" },
    .{ "clipboard", "clipboard" },         .{ "notificationButton", "notifications" }, .{ "battery", "battery" },
    .{ "controlCenterButton", "control" },
};
fn widgets(alloc: std.mem.Allocator, report: *Report, list: Value, path: []const u8, seen: *std.StringHashMap(void)) ![]const u8 {
    if (list != .array or list.array.items.len > 128) return error.InvalidDmsValue;
    var names: std.ArrayList([]const u8) = .empty;
    for (list.array.items, 0..) |item, i| {
        const key = try string(item);
        var mapped: ?[]const u8 = null;
        inline for (widget_names) |pair| if (std.mem.eql(u8, pair[0], key)) {
            mapped = pair[1];
        };
        const field = try std.fmt.allocPrint(alloc, "{s}[{d}]:{s}", .{ path, i, key });
        if (mapped) |name| {
            if (seen.contains(name)) {
                try report.unsupported.append(alloc, field);
                continue;
            }
            try seen.put(name, {});
            try names.append(alloc, name);
            try report.mapped.append(alloc, field);
        } else try report.unsupported.append(alloc, field);
    }
    return std.mem.join(alloc, ",", names.items);
}
pub fn plan(alloc: std.mem.Allocator, settings: []const u8, session: ?[]const u8, base: model.Preferences) !Report {
    const root = try read(alloc, settings, 18);
    var report: Report = .{ .preferences = base };
    const p = &report.preferences;
    var it = root.object.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const v = kv.value_ptr.*;
        if (std.mem.eql(u8, key, "configVersion")) continue;
        if (std.mem.eql(u8, key, "barConfigs")) continue;
        if (std.mem.eql(u8, key, "fontFamily")) p.font = try string(v) else if (std.mem.eql(u8, key, "fontScale")) {
            const size = @round(14 * try number(v));
            if (!std.math.isFinite(size) or size < 10 or size > 24) return error.InvalidDmsFontScale;
            p.font_size = @intFromFloat(size);
        } else if (std.mem.eql(u8, key, "reduceMotion")) p.reduced_motion = try boolean(v) else if (std.mem.eql(u8, key, "showDock")) p.dock.enabled = try boolean(v) else if (std.mem.eql(u8, key, "dockAutoHide")) p.dock.mode = if (try boolean(v)) .autohide else .always else if (std.mem.eql(u8, key, "dockPosition")) p.dock.edge = try edge(v) else if (std.mem.eql(u8, key, "dockIconSize")) {
            const size = try number(v);
            if (!std.math.isFinite(size) or size < 24 or size > 64 or @floor(size) != size) return error.InvalidDmsIconSize;
            p.dock.icon_size = @intFromFloat(size);
        } else {
            try report.unsupported.append(alloc, key);
            continue;
        }
        try report.mapped.append(alloc, key);
    }
    if (root.object.get("barConfigs")) |bars| {
        if (bars != .array or bars.array.items.len > 16) return error.InvalidDmsBars;
        var selected = false;
        for (bars.array.items, 0..) |bar, index| {
            if (bar != .object) return error.InvalidDmsBars;
            const path = try std.fmt.allocPrint(alloc, "barConfigs[{d}]", .{index});
            const enabled = if (bar.object.get("enabled")) |v| try boolean(v) else true;
            const screens = bar.object.get("screenPreferences");
            const all = screens == null or (screens.? == .array and screens.?.array.items.len == 1 and screens.?.array.items[0] == .string and std.mem.eql(u8, screens.?.array.items[0].string, "all"));
            if (!enabled or !all or selected) {
                try report.unsupported.append(alloc, path);
                continue;
            }
            selected = true;
            var fields = bar.object.iterator();
            var seen = std.StringHashMap(void).init(alloc);
            // Preserve absent groups, counting their items when deduplicating.
            const group_keys = [_][]const u8{ "leftWidgets", "centerWidgets", "rightWidgets" };
            var groups = [_][]const u8{ p.bar.groups.left, p.bar.groups.center, p.bar.groups.right };
            for (group_keys, 0..) |name, i| if (!bar.object.contains(name)) {
                var parts = std.mem.splitScalar(u8, groups[i], ',');
                while (parts.next()) |part| if (part.len != 0) {
                    try seen.put(part, {});
                };
            };
            // Stable order avoids JSON object-order-dependent deduplication.
            for (group_keys, 0..) |name, i| if (bar.object.get(name)) |list| {
                groups[i] = try widgets(alloc, &report, list, try std.fmt.allocPrint(alloc, "{s}.{s}", .{ path, name }), &seen);
            };
            if (!seen.contains("launcher")) {
                groups[0] = try std.fmt.allocPrint(alloc, "launcher{s}{s}", .{ if (groups[0].len > 0) "," else "", groups[0] });
                try report.notes.append(alloc, "Pearl requires a launcher; it was added to the left group.");
            }
            p.bar.groups = .{ .left = groups[0], .center = groups[1], .right = groups[2] };
            while (fields.next()) |kv| {
                const name = kv.key_ptr.*;
                if (std.mem.eql(u8, name, "leftWidgets") or std.mem.eql(u8, name, "centerWidgets") or std.mem.eql(u8, name, "rightWidgets")) continue;
                const field = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ path, name });
                if (std.mem.eql(u8, name, "position")) {
                    p.bar.edge = try edge(kv.value_ptr.*);
                    try report.mapped.append(alloc, field);
                } else try report.unsupported.append(alloc, field);
            }
        }
        try report.notes.append(alloc, "Only the first enabled all-output bar is imported. Per-output bars, frames, spacing and custom widgets remain unchanged in DMS.");
    }
    if (session) |bytes| {
        const state = try read(alloc, bytes, 4);
        var fields = state.object.iterator();
        while (fields.next()) |kv| {
            const name = kv.key_ptr.*;
            const v = kv.value_ptr.*;
            if (std.mem.eql(u8, name, "configVersion")) continue;
            const path = try std.fmt.allocPrint(alloc, "session.{s}", .{name});
            if (std.mem.eql(u8, name, "isLightMode")) p.theme.variant = if (try boolean(v)) .light else .dark else if (std.mem.eql(u8, name, "wallpaperPath")) {
                const value = try string(v);
                if (model.hex(value)) {
                    p.wallpaper.mode = .solid;
                    p.wallpaper.color = value;
                    p.wallpaper.path = "";
                } else if (value.len > 0 and value[0] == '/') {
                    p.wallpaper.mode = .cover;
                    p.wallpaper.path = value;
                } else {
                    try report.unsupported.append(alloc, path);
                    continue;
                }
            } else if (std.mem.eql(u8, name, "pinnedApps")) {
                if (v != .array or v.array.items.len > 16) return error.InvalidDmsPins;
                var pins: std.ArrayList([]const u8) = .empty;
                for (v.array.items) |item| {
                    const raw = try string(item);
                    const id = if (std.mem.endsWith(u8, raw, ".desktop")) raw else try std.fmt.allocPrint(alloc, "{s}.desktop", .{raw});
                    if (!@import("../desktop/dock_policy.zig").desktopId(id)) return error.InvalidDmsPins;
                    var duplicate = false;
                    for (pins.items) |old| if (std.mem.eql(u8, old, id)) {
                        duplicate = true;
                    };
                    if (!duplicate) try pins.append(alloc, id);
                }
                p.pinned_apps = pins.items;
            } else {
                try report.unsupported.append(alloc, path);
                continue;
            }
            try report.mapped.append(alloc, path);
        }
    }
    try p.validate();
    try report.notes.append(alloc, "No DMS files, services, compositor settings, external themes or live Pearl preferences were changed. Apply this candidate explicitly through Pearl's revision-checked preferences API.");
    return report;
}
test "DMS mapping preserves unrelated Pearl state and reports unsupported fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try plan(arena.allocator(),
        \\{"configVersion":18,"fontScale":1.25,"showDock":true,"barConfigs":[{"position":1,"leftWidgets":["workspaceSwitcher"],"centerWidgets":["clock","weather"],"rightWidgets":["clock","controlCenterButton"]}],"secretPlugin":{"value":"not-copied"}}
    , "{\"configVersion\":4,\"isLightMode\":true,\"pinnedApps\":[\"App\",\"App.desktop\"]}", .{ .idle = .{}, .reduced_motion = true });
    try std.testing.expectEqual(model.Edge.bottom, r.preferences.bar.edge);
    try std.testing.expectEqualStrings("launcher,workspaces", r.preferences.bar.groups.left);
    try std.testing.expectEqualStrings("control", r.preferences.bar.groups.right);
    try std.testing.expectEqual(@as(usize, 1), r.preferences.pinned_apps.len);
    try std.testing.expect(r.preferences.reduced_motion and r.unsupported.items.len >= 3);
}
test "unknown DMS versions and invalid values cannot produce an import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.UnsupportedDmsVersion, plan(a, "{\"configVersion\":99}", null, .{}));
    try std.testing.expectError(error.InvalidDmsValue, plan(a, "{\"showDock\":\"yes\"}", null, .{}));
    try std.testing.expectError(error.UnsupportedDmsPosition, plan(a, "{\"dockPosition\":4}", null, .{}));
    try std.testing.expectError(error.InvalidDmsPins, plan(a, "{}", "{\"pinnedApps\":[\"../bad\"]}", .{}));
}
