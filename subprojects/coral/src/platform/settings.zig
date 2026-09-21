const u = @import("../c.zig");
const c = u.c;
const std = @import("std");
pub const Settings = struct {
    theme: c_int = 0,
    font: c_int = 14,
    lines: bool = true,
    wrap: bool = true,
    spaces: bool = true,
    indent: c_int = 4,
    spelling: bool = true,
    language: [64:0]u8 = std.mem.zeroes([64:0]u8),
    pub fn load() Settings {
        var s: Settings = .{};
        const k = c.g_key_file_new().?;
        defer c.g_key_file_unref(k);
        const p = u.fmt("{s}/coral/preferences.ini", .{std.mem.span(c.g_get_user_config_dir())});
        defer u.a.free(p);
        if (c.g_key_file_load_from_file(k, p, 0, null) == 0) return s;
        inline for (.{ "theme", "font", "indent" }) |key| {
            if (c.g_key_file_has_key(k, "Coral", key, null) != 0) @field(s, key) = c.g_key_file_get_integer(k, "Coral", key, null);
        }
        inline for (.{ "lines", "wrap", "spaces", "spelling" }) |key| {
            if (c.g_key_file_has_key(k, "Coral", key, null) != 0) @field(s, key) = c.g_key_file_get_boolean(k, "Coral", key, null) != 0;
        }
        s.theme = std.math.clamp(s.theme, 0, 2);
        s.font = std.math.clamp(s.font, 8, 32);
        s.indent = std.math.clamp(s.indent, 1, 8);
        const lang = c.g_key_file_get_string(k, "Coral", "language", null);
        if (lang != null) {
            s.setLanguage(std.mem.span(lang));
            c.g_free(lang);
        }
        return s;
    }
    pub fn setLanguage(s: *Settings, text: []const u8) void {
        @memset(&s.language, 0);
        const n = @min(text.len, 63);
        @memcpy(s.language[0..n], text[0..n]);
    }
    pub fn save(s: Settings) bool {
        const dir = u.fmt("{s}/coral", .{std.mem.span(c.g_get_user_config_dir())});
        defer u.a.free(dir);
        if (c.g_mkdir_with_parents(dir, 0o700) != 0) return false;
        const path = u.fmt("{s}/preferences.ini", .{dir});
        defer u.a.free(path);
        const k = c.g_key_file_new().?;
        defer c.g_key_file_unref(k);
        inline for (.{ "theme", "font", "indent" }) |key| c.g_key_file_set_integer(k, "Coral", key, @field(s, key));
        inline for (.{ "lines", "wrap", "spaces", "spelling" }) |key| c.g_key_file_set_boolean(k, "Coral", key, @intFromBool(@field(s, key)));
        c.g_key_file_set_string(k, "Coral", "language", &s.language);
        var n: usize = 0;
        const data = c.g_key_file_to_data(k, &n, null);
        defer c.g_free(data);
        const file = c.g_file_new_for_path(path).?;
        defer c.g_object_unref(file);
        return c.g_file_replace_contents(file, data, n, null, 0, c.G_FILE_CREATE_PRIVATE, null, null, null) != 0;
    }
};
