//! Declarative profile contract and pure assignment policy. Adapters own all
//! destination paths; a contributed manifest cannot execute commands.
const std = @import("std");
const model = @import("package_model.zig");
pub const Application = enum { zed, equibop, fluxer, starship, steam, gtk, qt5ct, qt6ct, kcolorscheme, ghostty, kitty, foot, alacritty, wezterm, nvim, vscode, emacs, firefox, zenbrowser, pywalfox, vesktop, vencord, fcitx5 };
pub const count = std.enums.values(Application).len;
pub const legacy_applications = [_]Application{ .zed, .equibop, .fluxer, .starship, .steam };
pub const defaults_revision: u32 = 1;
pub const Descriptor = struct {
    schema_version: u32,
    id: []const u8,
    application: Application,
    adapter: Application,
    name: []const u8,
    author: []const u8,
    license: []const u8,
    source: []const u8,
    asset_version: []const u8,
    variants: []const enum { dark, light },
    templates: []const struct { path: []const u8, output: []const u8 },
    instructions: []const u8 = "",
    pub fn validate(self: Descriptor) !void {
        if (self.schema_version != 1) return error.UnsupportedProfileSchema;
        try model.identifier(self.id);
        if (self.application != self.adapter) return error.ProfileAdapterMismatch;
        for ([_][]const u8{ self.name, self.author, self.license, self.source }) |v| try model.text(v, 256);
        _ = try model.version(self.asset_version);
        if (self.instructions.len > 0) try model.text(self.instructions, 2048);
        if (self.variants.len == 0 or self.variants.len > 2 or self.templates.len == 0 or self.templates.len > 8) return error.InvalidProfile;
        if (self.variants.len == 2 and self.variants[0] == self.variants[1]) return error.InvalidProfile;
        for (self.templates, 0..) |t, i| {
            try model.relative(t.path);
            try model.identifier(t.output);
            const suffix: []const u8 = switch (self.application) {
                .zed, .vscode, .pywalfox => ".json",
                .starship, .alacritty, .wezterm => ".toml",
                .qt5ct, .qt6ct, .ghostty, .kitty => ".conf",
                .kcolorscheme => ".colors",
                .foot => ".ini",
                .nvim => ".lua",
                .emacs => ".el",
                .fcitx5 => if (std.mem.endsWith(u8, t.output, ".svg")) ".svg" else ".conf",
                else => ".css",
            };
            if (!std.mem.endsWith(u8, t.output, suffix)) return error.InvalidProfileOutputName;
            for (self.templates[0..i]) |old| if (std.mem.eql(u8, old.output, t.output)) return error.DuplicateProfileOutput;
        }
        const expected: ?usize = switch (self.application) {
            .gtk, .qt5ct, .qt6ct, .ghostty, .foot, .alacritty, .wezterm, .emacs, .pywalfox, .starship => 1,
            .kitty, .nvim => 2,
            .kcolorscheme, .vscode, .fcitx5 => 3,
            else => null,
        };
        if (expected) |n| if (self.templates.len != n) return error.InvalidProfile;
        if (self.application == .fcitx5) {
            for (self.templates, [_][]const u8{ "theme.conf", "panel.svg", "highlight.svg" }) |t, role| if (!std.mem.eql(u8, t.output, role)) return error.InvalidProfileOutputName;
        }
        if (self.application == .vscode) {
            for (self.templates, [_][]const u8{ "vscode-color-theme-dark.json", "vscode-color-theme-light.json", "package.json" }) |t, role| if (!std.mem.eql(u8, t.output, role)) return error.InvalidProfileOutputName;
        }
    }
};
pub const Selection = struct { mode: enum { theme, profile, off } = .theme, profile_id: []const u8 = "" };
pub const Config = struct {
    enabled: bool = false,
    defaults_revision: u32 = 0,
    colors: struct { source: enum { follow_pearl, seed, wallpaper } = .follow_pearl, seed: []const u8 = "#6750a4" } = .{},
    applications: std.json.ArrayHashMap(Selection) = .{},
    snapshot_digest: []const u8 = "",
    catalog_revision: []const u8 = "",
    pub fn validate(self: Config) !void {
        if (self.defaults_revision > defaults_revision) return error.UnsupportedMaterialDefaults;
        if (!@import("../config/preferences.zig").hex(self.colors.seed)) return error.InvalidColor;
        if (self.applications.map.count() > 32) return error.TooManyApplications;
        if (self.snapshot_digest.len > 0) try model.digest(self.snapshot_digest);
        if (self.catalog_revision.len > 0) try model.digest(self.catalog_revision);
        var it = self.applications.map.iterator();
        while (it.next()) |entry| {
            _ = std.meta.stringToEnum(Application, entry.key_ptr.*) orelse return error.UnknownApplicationAdapter;
            const value = entry.value_ptr.*;
            if (value.profile_id.len > 0) try model.identifier(value.profile_id);
            if (value.mode == .profile and value.profile_id.len == 0) return error.ProfileSelectionRequired;
        }
    }
};
pub const Target = struct {
    application: ?Application = null,
    detected: bool = false,
    applied_generation: u64 = 0,
    state: enum { unmanaged, pending, generated, activation_required, applied, unavailable, unsupported, conflict, failed } = .unmanaged,
    profile: []const u8 = "",
    origin: []const u8 = "",
    error_code: ?[]const u8 = null,
    output: []const u8 = "",
    instructions: []const u8 = "",
};
pub const Status = struct {
    schema_version: u32 = 2,
    desired_generation: u64 = 0,
    applied_generation: u64 = 0,
    busy: bool = false,
    watcher_error: ?[]const u8 = null,
    desired_revision: u64 = 0,
    applied_revision: u64 = 0,
    targets: [count]Target = @splat(.{}),
};
pub fn effective(enabled: bool, choice: Selection, inherited: ?[]const u8) ?[]const u8 {
    if (!enabled) return null;
    return switch (choice.mode) {
        .off => null,
        .profile => choice.profile_id,
        .theme => inherited,
    };
}
pub fn template(bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > 131072 or !std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidProfileTemplate;
}
test "application selection keeps manual and Off precedence over theme changes" {
    try std.testing.expect(effective(false, .{ .mode = .profile, .profile_id = "manual" }, "theme") == null);
    try std.testing.expect(effective(true, .{ .mode = .off }, "theme") == null);
    try std.testing.expectEqualStrings("manual", effective(true, .{ .mode = .profile, .profile_id = "manual" }, "theme").?);
    try std.testing.expectEqualStrings("theme", effective(true, .{}, "theme").?);
    try std.testing.expect(effective(true, .{}, null) == null);
}
