//! Editable palette author contract. Independent of GTK and filesystem access.
const std = @import("std");
const model = @import("package_model.zig");
pub const max_bytes = 65536;
pub const compiler_version = 1;
pub const Publication = struct {
    id: []const u8,
    author: []const u8,
    license: []const u8,
    source: []const u8,
    version: []const u8,
    license_text: []const u8,
    attribution: []const u8,
    pub fn validate(self: Publication) !void {
        try model.identifier(self.id);
        if (std.mem.startsWith(u8, self.id, "pearl.") or std.mem.startsWith(u8, self.id, "local.palette.")) return error.ReservedThemeId;
        _ = try model.version(self.version);
        for ([_][]const u8{ self.author, self.license, self.source }) |s| try model.text(s, 256);
        for ([_][]const u8{ self.license_text, self.attribution }) |s| if (s.len == 0 or s.len > 16384 or !std.unicode.utf8ValidateSlice(s)) return error.PublicationAttributionRequired;
    }
};
pub const Source = struct {
    name: []const u8 = "",
    dark: ?std.json.Value = null,
    light: ?std.json.Value = null,
    publication: ?Publication = null,
};
pub const Diagnostic = struct {
    path: []const u8 = "$",
    code: []const u8 = "InvalidPalette",
    value: []const u8 = "",
    background: []const u8 = "",
    ratio: ?f64 = null,
    required: ?f64 = null,
    suggested: []const u8 = "",
};
pub const roles = [_][]const u8{
    "surface",                  "on_surface",                "primary",                "on_primary",                 "primary_container",         "on_primary_container",
    "surface_container_lowest", "surface_container_low",     "surface_container",      "surface_container_high",     "surface_container_highest", "surface_dim",
    "surface_bright",           "surface_variant",           "on_surface_variant",     "background",                 "on_background",             "secondary",
    "on_secondary",             "secondary_container",       "on_secondary_container", "tertiary",                   "on_tertiary",               "tertiary_container",
    "on_tertiary_container",    "error",                     "on_error",               "error_container",            "on_error_container",        "outline",
    "outline_variant",          "shadow",                    "scrim",                  "surface_tint",               "source_color",              "inverse_surface",
    "inverse_on_surface",       "inverse_primary",           "primary_fixed",          "primary_fixed_dim",          "on_primary_fixed",          "on_primary_fixed_variant",
    "secondary_fixed",          "secondary_fixed_dim",       "on_secondary_fixed",     "on_secondary_fixed_variant", "tertiary_fixed",            "tertiary_fixed_dim",
    "on_tertiary_fixed",        "on_tertiary_fixed_variant", "hover",                  "on_hover",
};
const Alias = struct { from: []const u8, to: []const u8 };
const aliases = [_]Alias{
    .{ .from = "mPrimary", .to = "primary" },                .{ .from = "mOnPrimary", .to = "on_primary" },
    .{ .from = "mSecondary", .to = "secondary" },            .{ .from = "mOnSecondary", .to = "on_secondary" },
    .{ .from = "mTertiary", .to = "tertiary" },              .{ .from = "mOnTertiary", .to = "on_tertiary" },
    .{ .from = "mError", .to = "error" },                    .{ .from = "mOnError", .to = "on_error" },
    .{ .from = "mSurface", .to = "surface" },                .{ .from = "mOnSurface", .to = "on_surface" },
    .{ .from = "mSurfaceVariant", .to = "surface_variant" }, .{ .from = "mOnSurfaceVariant", .to = "on_surface_variant" },
    .{ .from = "mOutline", .to = "outline" },                .{ .from = "mShadow", .to = "shadow" },
    .{ .from = "mHover", .to = "hover" },                    .{ .from = "mOnHover", .to = "on_hover" },
};
pub const ansi_names = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" };
pub fn object() std.json.Value {
    return .{ .object = .empty };
}
pub fn get(v: std.json.Value, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}
pub fn set(a: std.mem.Allocator, v: *std.json.Value, key: []const u8, value: []const u8) !void {
    try v.object.put(a, key, .{ .string = value });
}
fn fail(a: std.mem.Allocator, d: *Diagnostic, variant: []const u8, key: []const u8, code: []const u8) error{ InvalidPalette, OutOfMemory } {
    d.* = .{ .path = if (key.len == 0) try std.fmt.allocPrint(a, "$.{s}", .{variant}) else try std.fmt.allocPrint(a, "$.{s}.{s}", .{ variant, key }), .code = code };
    return error.InvalidPalette;
}
fn colors(a: std.mem.Allocator, value: std.json.Value, variant: []const u8, d: *Diagnostic) !std.json.Value {
    if (value != .object) return fail(a, d, variant, "", "ExpectedObject");
    var result = object();
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        var canonical = key;
        for (aliases) |alias| if (std.mem.eql(u8, key, alias.from)) {
            canonical = alias.to;
            break;
        };
        if (std.mem.eql(u8, key, "terminal")) {
            try terminal(a, entry.value_ptr.*, variant, d);
            try result.object.put(a, key, entry.value_ptr.*);
            continue;
        }
        var known = false;
        for (roles) |role| if (std.mem.eql(u8, canonical, role)) {
            known = true;
            break;
        };
        if (!known) return fail(a, d, variant, key, "UnknownField");
        const color = entry.value_ptr.*;
        if (color != .string or !@import("../config/preferences.zig").hex(color.string)) {
            const err = fail(a, d, variant, key, "InvalidColor");
            if (color == .string) d.value = color.string;
            return err;
        }
        if (result.object.get(canonical)) |previous| if (!std.ascii.eqlIgnoreCase(previous.string, color.string)) return fail(a, d, variant, key, "ConflictingPaletteAlias");
        try result.object.put(a, canonical, color);
    }
    for ([_][]const u8{ "surface", "on_surface", "primary" }) |required| if (!result.object.contains(required)) return fail(a, d, variant, required, "MissingPaletteRole");
    return result;
}
fn terminal(a: std.mem.Allocator, value: std.json.Value, variant: []const u8, d: *Diagnostic) !void {
    if (value != .object) return fail(a, d, variant, "terminal", "ExpectedObject");
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const path = try std.fmt.allocPrint(a, "terminal.{s}", .{key});
        if (std.mem.eql(u8, key, "normal") or std.mem.eql(u8, key, "bright")) {
            if (entry.value_ptr.* != .object) return fail(a, d, variant, path, "ExpectedObject");
            var ansi = entry.value_ptr.object.iterator();
            while (ansi.next()) |item| {
                var known = false;
                for (ansi_names) |name| if (std.mem.eql(u8, name, item.key_ptr.*)) {
                    known = true;
                    break;
                };
                const field = try std.fmt.allocPrint(a, "{s}.{s}", .{ path, item.key_ptr.* });
                if (!known) return fail(a, d, variant, field, "UnknownField");
                if (item.value_ptr.* != .string or !@import("../config/preferences.zig").hex(item.value_ptr.string)) return fail(a, d, variant, field, "InvalidColor");
            }
        } else {
            var known = false;
            for ([_][]const u8{ "background", "foreground", "cursor", "cursorText", "selectionBg", "selectionFg" }) |field| if (std.mem.eql(u8, key, field)) {
                known = true;
                break;
            };
            if (!known) return fail(a, d, variant, path, "UnknownField");
            if (entry.value_ptr.* != .string or !@import("../config/preferences.zig").hex(entry.value_ptr.string)) return fail(a, d, variant, path, "InvalidColor");
        }
    }
}
pub fn parse(a: std.mem.Allocator, bytes: []const u8, d: *Diagnostic) !Source {
    var result = try model.parse(Source, a, bytes, max_bytes);
    if (result.name.len > 0) try model.text(result.name, 256);
    if (result.dark == null and result.light == null) return error.EmptyPalette;
    if (result.dark) |value| result.dark = try colors(a, value, "dark", d);
    if (result.light) |value| result.light = try colors(a, value, "light", d);
    if (result.publication) |p| try p.validate();
    return result;
}
