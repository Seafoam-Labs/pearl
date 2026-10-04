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

    /// Why a save failed, so the call sites that previously discarded the bool
    /// (the font-zoom shortcuts) can name the cause instead of losing the change
    /// silently.
    pub const SaveError = error{ Directory, Serialize, Write };

    pub fn load() Settings {
        const p = u.fmt("{s}/coral/preferences.ini", .{std.mem.span(c.g_get_user_config_dir())});
        defer u.a.free(p);
        return loadFrom(p);
    }

    /// Reads preferences from an explicit path so tests can target a temporary
    /// file instead of the real config directory.
    pub fn loadFrom(path: [*:0]const u8) Settings {
        var s: Settings = .{};
        const k = c.g_key_file_new().?;
        defer c.g_key_file_unref(k);
        if (c.g_key_file_load_from_file(k, path, 0, null) == 0) return s;
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
    pub fn save(s: Settings) SaveError!void {
        const dir = u.fmt("{s}/coral", .{std.mem.span(c.g_get_user_config_dir())});
        defer u.a.free(dir);
        return saveIn(s, dir);
    }
    /// Writes `preferences.ini` into an explicit directory so tests can target a
    /// temporary path instead of the real config directory.
    pub fn saveIn(s: Settings, dir: [:0]const u8) SaveError!void {
        if (c.g_mkdir_with_parents(dir, 0o700) != 0) return error.Directory;
        const path = u.fmt("{s}/preferences.ini", .{dir});
        defer u.a.free(path);
        const k = c.g_key_file_new().?;
        defer c.g_key_file_unref(k);
        inline for (.{ "theme", "font", "indent" }) |key| c.g_key_file_set_integer(k, "Coral", key, @field(s, key));
        inline for (.{ "lines", "wrap", "spaces", "spelling" }) |key| c.g_key_file_set_boolean(k, "Coral", key, @intFromBool(@field(s, key)));
        c.g_key_file_set_string(k, "Coral", "language", &s.language);
        var n: usize = 0;
        var serialize_err: ?*c.GError = null;
        const data = c.g_key_file_to_data(k, &n, &serialize_err);
        if (serialize_err) |e| c.g_error_free(e);
        if (data == null) return error.Serialize;
        defer c.g_free(data);
        const file = c.g_file_new_for_path(path).?;
        defer c.g_object_unref(file);
        var write_err: ?*c.GError = null;
        const ok = c.g_file_replace_contents(file, data, n, null, 0, c.G_FILE_CREATE_PRIVATE, null, null, &write_err) != 0;
        if (write_err) |e| c.g_error_free(e);
        if (!ok) return error.Write;
    }
};

const allocator = std.heap.c_allocator;
var temp_counter: usize = 0;

fn tempDir() ![:0]u8 {
    temp_counter += 1;
    const path = try std.fmt.allocPrintSentinel(allocator, "/tmp/coral-prefs-{d}-{d}", .{ std.os.linux.getpid(), temp_counter }, 0);
    if (c.g_mkdir_with_parents(path, 0o700) != 0) {
        allocator.free(path);
        return error.TempDir;
    }
    return path;
}

fn removeTree(path: []const u8) void {
    const z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(z);
    if (c.g_dir_open(z, 0, null)) |dir| {
        defer c.g_dir_close(dir);
        while (c.g_dir_read_name(dir)) |name| {
            const child = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ path, std.mem.span(name) }, 0) catch continue;
            removeTree(child);
            allocator.free(child);
        }
    }
    _ = c.g_remove(z);
    _ = c.g_rmdir(z);
}

fn joinZ(dir: []const u8, name: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, name }, 0);
}

test "settings round-trip through save and load" {
    const dir = try tempDir();
    defer {
        removeTree(dir);
        allocator.free(dir);
    }
    var stored: Settings = .{ .theme = 2, .font = 20, .lines = false, .wrap = false, .spaces = false, .indent = 8, .spelling = false };
    stored.setLanguage("en_US");
    try stored.saveIn(dir);
    const path = try joinZ(dir, "preferences.ini");
    defer allocator.free(path);
    const loaded = Settings.loadFrom(path);
    try std.testing.expectEqual(stored.theme, loaded.theme);
    try std.testing.expectEqual(stored.font, loaded.font);
    try std.testing.expectEqual(stored.lines, loaded.lines);
    try std.testing.expectEqual(stored.wrap, loaded.wrap);
    try std.testing.expectEqual(stored.spaces, loaded.spaces);
    try std.testing.expectEqual(stored.indent, loaded.indent);
    try std.testing.expectEqual(stored.spelling, loaded.spelling);
    try std.testing.expectEqualStrings("en_US", std.mem.sliceTo(&loaded.language, 0));
}

test "saving over an unwritable target reports a write failure" {
    const dir = try tempDir();
    defer {
        removeTree(dir);
        allocator.free(dir);
    }
    // A directory where preferences.ini must go: the parent is created, but the
    // file cannot be replaced. Avoids permissions, which root would bypass.
    const blocked = try joinZ(dir, "preferences.ini");
    defer allocator.free(blocked);
    if (c.g_mkdir_with_parents(blocked, 0o700) != 0) return error.TestSetup;
    const empty: Settings = .{};
    try std.testing.expectError(error.Write, empty.saveIn(dir));
}

test "saving under a path whose parent is a file reports a directory failure" {
    const dir = try tempDir();
    defer {
        removeTree(dir);
        allocator.free(dir);
    }
    const file = try joinZ(dir, "afile");
    defer allocator.free(file);
    if (c.g_file_set_contents(file, "x", 1, null) == 0) return error.TestSetup;
    // mkdir_with_parents cannot traverse a regular file, so the directory step
    // fails before any serialization.
    const blocked = try joinZ(file, "nested");
    defer allocator.free(blocked);
    const empty: Settings = .{};
    try std.testing.expectError(error.Directory, empty.saveIn(blocked));
}
