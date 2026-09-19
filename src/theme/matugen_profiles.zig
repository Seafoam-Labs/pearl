//! Declarative profile contract and pure assignment policy. Adapters own all
//! destination paths; a contributed manifest cannot execute commands.
const std = @import("std");
const model = @import("package_model.zig");
pub const Application = enum { zed, equibop, fluxer, starship, steam };
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
                .zed => ".json",
                .starship => ".toml",
                else => ".css",
            };
            if (!std.mem.endsWith(u8, t.output, suffix)) return error.InvalidProfileOutputName;
            for (self.templates[0..i]) |old| if (std.mem.eql(u8, old.output, t.output)) return error.DuplicateProfileOutput;
        }
        if (self.application == .starship and self.templates.len != 1) return error.InvalidProfile;
    }
};
pub const Selection = struct { mode: enum { theme, profile, off } = .theme, profile_id: []const u8 = "" };
pub const Config = struct {
    enabled: bool = false,
    colors: struct { source: enum { follow_pearl, seed, wallpaper } = .follow_pearl, seed: []const u8 = "#6750a4" } = .{},
    applications: std.json.ArrayHashMap(Selection) = .{},
    snapshot_digest: []const u8 = "",
    catalog_revision: []const u8 = "",
    pub fn validate(self: Config) !void {
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
    state: enum { unmanaged, pending, generated, activation_required, applied, unavailable, unsupported, conflict, failed } = .unmanaged,
    profile: []const u8 = "",
    origin: []const u8 = "",
    error_code: ?[]const u8 = null,
    output: []const u8 = "",
    instructions: []const u8 = "",
};
pub const Status = struct {
    desired_revision: u64 = 0,
    applied_revision: u64 = 0,
    targets: [5]Target = @splat(.{}),
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
