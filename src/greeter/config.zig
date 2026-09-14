//! Administrator-only greeter configuration. Never imports Pearl user preferences.
const std = @import("std");
const glib = @import("glib2");
const p = @import("protocol.zig");
const trusted = @import("trusted.zig");
const options = @import("build_options");
pub const Root = struct { path: []const u8, type: enum { wayland, x11 } };
pub const Config = struct {
    version: u8 = 1,
    theme: enum { material_dark, material_light, gtk } = .material_dark,
    gtk_theme: ?[]const u8 = null,
    wallpaper: ?[]const u8 = null,
    font_size: u8 = 16,
    reduced_motion: bool = true,
    preferred_output: ?[]const u8 = null,
    default_session: ?[]const u8 = null,
    force_session: ?[]const u8 = null,
    allow: []const []const u8 = &.{},
    deny: []const []const u8 = &.{},
    roots: []const Root = &.{ .{ .path = "/usr/share/wayland-sessions", .type = .wayland }, .{ .path = "/usr/share/xsessions", .type = .x11 } },
    allow_uwsm: bool = false,
    x11: bool = false,
    remember_session: bool = false,
    accounts: bool = true,
    power: bool = true,
    screen_reader: bool = false,
    auth_timeout_seconds: u16 = 120,
    pub fn validate(self: Config) !void {
        if (self.version != 1 or self.font_size < 12 or self.font_size > 32 or self.auth_timeout_seconds < 30 or self.auth_timeout_seconds > 300 or self.roots.len > 16 or self.roots.len == 0 or self.allow.len > 256 or self.deny.len > 256) return error.InvalidConfig;
        for (self.roots) |root| if (root.path.len == 0 or root.path[0] != '/' or !p.validText(root.path, 4096)) return error.InvalidRoot;
        for ([_]?[]const u8{ self.gtk_theme, self.wallpaper, self.preferred_output, self.default_session, self.force_session }) |value| if (value) |v| if (!p.validText(v, 4096)) return error.InvalidConfig;
        for (self.allow) |id| if (!validId(id)) return error.InvalidSessionId;
        for (self.deny) |id| if (!validId(id)) return error.InvalidSessionId;
        if (self.default_session) |id| if (!validId(id)) return error.InvalidSessionId;
        if (self.force_session) |id| if (!validId(id)) return error.InvalidSessionId;
    }
};
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 256) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-_.:", c) == null) return false;
    return true;
}
pub fn path() []const u8 {
    if (options.test_hooks) if (glib.getenv("PEARL_TEST_GREETER_CONFIG")) |v| return std.mem.span(v);
    return "/etc/pearl/greeter.json";
}
pub fn load(a: std.mem.Allocator) !std.json.Parsed(Config) {
    const bytes = try trusted.read(a, path(), 65536);
    defer a.free(bytes);
    try p.validateJson(bytes, 65536);
    const parsed = try std.json.parseFromSlice(Config, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}
