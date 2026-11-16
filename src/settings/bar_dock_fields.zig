//! Bar & dock form field specs, kept free of GTK so the unit tests can guard
//! that every bar and dock preference stays editable in Settings. The form
//! itself lives in `preference_pages.zig`; per-widget settings live in the
//! widget editor (`bar_view.zig` with the `bar_model.zig` patches).
const std = @import("std");
const prefs = @import("../config/preferences.zig");

pub const Spec = struct { path: []const u8, label: [:0]const u8, kind: enum { text, number, percent, toggle, choice }, choices: []const [:0]const u8 = &.{}, min: f64 = 0, max: f64 = 86400 };

pub const edges: []const [:0]const u8 = &.{ "top", "bottom", "left", "right" };

pub const fields = [_]Spec{
    .{ .path = "bar.mode", .label = "Bar visibility", .kind = .choice, .choices = &.{ "always", "autohide" } },
    .{ .path = "bar.edge", .label = "Bar edge", .kind = .choice, .choices = edges },
    .{ .path = "bar.size", .label = "Bar size", .kind = .number, .min = 32, .max = 160 },
    .{ .path = "bar.radius", .label = "Bar corner radius", .kind = .number, .min = 0, .max = 48 },
    .{ .path = "bar.running_apps_per_window", .label = "One taskbar button per window", .kind = .toggle },
    .{ .path = "bar.islands", .label = "Separate bar islands", .kind = .toggle },
    .{ .path = "bar.attached", .label = "Attach bar to screen edge", .kind = .toggle },
    .{ .path = "bar.background_opacity.mode", .label = "Background opacity", .kind = .choice, .choices = &.{ "automatic", "custom" } },
    .{ .path = "bar.background_opacity.percent", .label = "Background opacity (%)", .kind = .percent, .min = 0, .max = 100 },
    .{ .path = "dock.enabled", .label = "Show dock", .kind = .toggle },
    .{ .path = "dock.edge", .label = "Dock edge", .kind = .choice, .choices = edges },
    .{ .path = "dock.mode", .label = "Dock visibility", .kind = .choice, .choices = &.{ "always", "autohide", "intelligent" } },
    .{ .path = "dock.icon_size", .label = "Dock icon size", .kind = .number, .min = 24, .max = 64 },
    .{ .path = "dock.margin", .label = "Dock margin", .kind = .number, .min = 4, .max = 32 },
    .{ .path = "dock.opacity_sync", .label = "Match bar opacity", .kind = .toggle },
    // The dock's opacity mode is shell-derived: with sync off the shell always
    // applies the percent as a custom alpha, so only the percent needs a row.
    .{ .path = "dock.background_opacity.percent", .label = "Dock opacity (%)", .kind = .percent, .min = 0, .max = 100 },
    .{ .path = "popup.dismiss_outside", .label = "Dismiss flyouts when clicking outside", .kind = .toggle },
    .{ .path = "popup.placement", .label = "Flyout placement", .kind = .choice, .choices = &.{ "anchored", "centered" } },
    .{ .path = "popup.max_width", .label = "Maximum flyout width", .kind = .number, .min = 320, .max = 1280 },
    .{ .path = "popup.max_height", .label = "Maximum flyout height", .kind = .number, .min = 320, .max = 1600 },
};

/// Bar settings edited through the widget editor instead of a form row:
/// `groups` by the ordered widget lists, `clocks` by the clock dialog,
/// `launcher_icon` by the icon picker, and the rest by the actions menus of
/// the workspaces, resources and media widgets.
pub const widget_editor = [_][]const u8{ "groups", "clocks", "launcher_icon", "workspace_mode", "resource_mode", "resource_series", "media_art" };

fn fieldType(comptime T: type, comptime name: []const u8) ?type {
    const info = @typeInfo(T);
    if (info != .@"struct") return null;
    inline for (info.@"struct".field_names, info.@"struct".field_types) |field_name, field_type| {
        if (std.mem.eql(u8, field_name, name)) return field_type;
    }
    return null;
}

fn resolve(comptime path: []const u8) ?type {
    var current: type = prefs.Preferences;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| current = fieldType(current, part) orelse return null;
    return current;
}

fn enumHas(comptime T: type, comptime name: []const u8) bool {
    inline for (@typeInfo(T).@"enum".field_names) |tag| {
        if (std.mem.eql(u8, tag, name)) return true;
    }
    return false;
}

fn covered(comptime prefix: []const u8, comptime name: []const u8) bool {
    const path = prefix ++ "." ++ name;
    for (fields) |spec| {
        if (std.mem.eql(u8, spec.path, path) or std.mem.startsWith(u8, spec.path, path ++ ".")) return true;
    }
    if (std.mem.eql(u8, prefix, "bar")) {
        for (widget_editor) |edited| if (std.mem.eql(u8, edited, name)) return true;
    }
    return false;
}

test "every bar and dock preference has a Settings control" {
    @setEvalBranchQuota(100_000);
    // Form rows must name real preference fields, and choice rows must offer
    // real enum values, so a renamed setting fails here instead of silently
    // disabling its row.
    inline for (fields) |spec| {
        const field_type = comptime resolve(spec.path) orelse @compileError("Settings row names no preference field: " ++ spec.path);
        if (spec.kind == .choice and @typeInfo(field_type) == .@"enum") {
            inline for (spec.choices) |choice| {
                if (!comptime enumHas(field_type, choice)) @compileError("Settings choice is not a valid value for " ++ spec.path ++ ": " ++ choice);
            }
        }
    }
    // A new bar or dock setting must gain a form row or widget editor coverage
    // before it ships; presets alone do not make a setting editable.
    inline for (@typeInfo(prefs.Bar).@"struct".field_names) |name| {
        if (!comptime covered("bar", name)) @compileError("bar." ++ name ++ " has no Settings control; add a form row or widget editor coverage");
    }
    inline for (@typeInfo(prefs.Dock).@"struct".field_names) |name| {
        if (!comptime covered("dock", name)) @compileError("dock." ++ name ++ " has no Settings control; add a form row or widget editor coverage");
    }
}
