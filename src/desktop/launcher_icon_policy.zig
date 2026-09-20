//! Persisted launcher artwork; availability is deliberately a rendering concern.
const std = @import("std");
pub const default_icon: [:0]const u8 = "pearl-application-x-executable-symbolic";
pub const Config = struct {
    kind: enum { default, theme, file } = .default,
    value: []const u8 = "",
    pub fn eql(self: Config, other: Config) bool {
        return self.kind == other.kind and std.mem.eql(u8, self.value, other.value);
    }
    pub fn validate(self: Config) !void {
        switch (self.kind) {
            .default => if (self.value.len != 0) return error.InvalidLauncherIcon,
            .theme => {
                if (self.value.len == 0 or self.value.len > 128) return error.InvalidLauncherIcon;
                for (self.value) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-')) return error.InvalidLauncherIcon;
            },
            .file => {
                if (self.value.len == 0 or self.value.len > 1024 or self.value[0] != '/' or !std.unicode.utf8ValidateSlice(self.value)) return error.InvalidLauncherIcon;
                for (self.value) |ch| if (ch < 32 or ch == 127) return error.InvalidLauncherIcon;
            },
        }
    }
};
test "launcher icon kind and value are bounded and validated together" {
    const t = std.testing;
    try (Config{}).validate();
    try (Config{ .kind = .theme, .value = default_icon }).validate();
    try (Config{ .kind = .file, .value = "/home/user/My icon.png" }).validate();
    for ([_]Config{ .{ .value = "unexpected" }, .{ .kind = .theme }, .{ .kind = .theme, .value = "../icon" }, .{ .kind = .theme, .value = "a" ** 129 }, .{ .kind = .file, .value = "relative.png" }, .{ .kind = .file, .value = "/bad\nname" }, .{ .kind = .file, .value = "/\xff" }, .{ .kind = .file, .value = "/" ** 1025 } }) |cfg| try t.expectError(error.InvalidLauncherIcon, cfg.validate());
}
