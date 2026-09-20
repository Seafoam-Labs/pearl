const std = @import("std");
const io = @import("io.zig");
const c = io.c;
pub const Preferences = struct {
    light: bool = false,
    native: bool = false,
    compact: bool = false,
    bits: bool = false,
    per_core: bool = false,
    columns: u32 = 63,
    sort_column: u32 = 2,
    sort_descending: bool = true,
    interval: i64 = 1000000,
    duration: i64 = 120000000,
    width: c_int = 1120,
    height: c_int = 800,
    page: u32 = 0,
    pub fn load() Preferences {
        var p: Preferences = .{};
        const file = c.g_key_file_new().?;
        defer c.g_key_file_unref(file);
        const path = io.path("{s}/dome/preferences.ini", .{std.mem.span(c.g_get_user_config_dir())});
        if (c.g_key_file_load_from_file(file, path.z(), 0, null) == 0) return p;
        if (c.g_key_file_get_integer(file, "Dome", "version", null) != 1) return p;
        inline for (.{ "light", "native", "compact", "bits", "per_core" }) |key| @field(p, key) = c.g_key_file_get_boolean(file, "Dome", key, null) != 0;
        if (c.g_key_file_has_key(file, "Dome", "columns", null) != 0) p.columns = @as(u32, @intCast(std.math.clamp(c.g_key_file_get_integer(file, "Dome", "columns", null), 0, 63))) | 5;
        if (c.g_key_file_has_key(file, "Dome", "sort_column", null) != 0) {
            p.sort_column = @intCast(std.math.clamp(c.g_key_file_get_integer(file, "Dome", "sort_column", null), 0, 5));
            p.sort_descending = c.g_key_file_get_boolean(file, "Dome", "sort_descending", null) != 0;
        }
        p.interval = std.math.clamp(c.g_key_file_get_int64(file, "Dome", "interval", null), 500000, 5000000);
        p.duration = std.math.clamp(c.g_key_file_get_int64(file, "Dome", "duration", null), 120000000, 600000000);
        p.width = std.math.clamp(c.g_key_file_get_integer(file, "Dome", "width", null), 480, 3840);
        p.height = std.math.clamp(c.g_key_file_get_integer(file, "Dome", "height", null), 400, 2160);
        p.page = @intCast(std.math.clamp(c.g_key_file_get_integer(file, "Dome", "page", null), 0, 8));
        return p;
    }
    pub fn save(p: Preferences) bool {
        const dir = io.path("{s}/dome", .{std.mem.span(c.g_get_user_config_dir())});
        if (c.g_mkdir_with_parents(dir.z(), 0o700) != 0) return false;
        const path = io.path("{s}/preferences.ini", .{dir.slice()});
        const file = c.g_key_file_new().?;
        defer c.g_key_file_unref(file);
        c.g_key_file_set_integer(file, "Dome", "version", 1);
        c.g_key_file_set_integer(file, "Dome", "columns", @intCast(p.columns));
        c.g_key_file_set_integer(file, "Dome", "sort_column", @intCast(p.sort_column));
        c.g_key_file_set_boolean(file, "Dome", "sort_descending", @intFromBool(p.sort_descending));
        inline for (.{ "light", "native", "compact", "bits", "per_core" }) |key| c.g_key_file_set_boolean(file, "Dome", key, @intFromBool(@field(p, key)));
        c.g_key_file_set_int64(file, "Dome", "interval", p.interval);
        c.g_key_file_set_int64(file, "Dome", "duration", p.duration);
        c.g_key_file_set_integer(file, "Dome", "width", p.width);
        c.g_key_file_set_integer(file, "Dome", "height", p.height);
        c.g_key_file_set_integer(file, "Dome", "page", @intCast(p.page));
        var n: usize = 0;
        const text = c.g_key_file_to_data(file, &n, null);
        if (text == null) return false;
        defer c.g_free(text);
        const target = c.g_file_new_for_path(path.z()).?;
        defer c.g_object_unref(target);
        return c.g_file_replace_contents(target, text, n, null, 0, c.G_FILE_CREATE_PRIVATE, null, null, null) != 0;
    }
};
