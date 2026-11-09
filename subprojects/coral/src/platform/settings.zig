const u = @import("../c.zig");
const c = u.c;
const std = @import("std");
const policy = @import("../workspace/settings.zig");
pub const Settings = struct {
    /// Presence is independent of value: an explicitly chosen default is a user override.
    present: policy.KeyMask = .{},

    /// 0 Pearl dark, 1 Pearl light, 2 Native GTK, 3 Follow Pearl (default).
    theme: c_int = 3,
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

    pub fn baseline(s: Settings) policy.Baseline {
        return .{ .lines = s.lines, .wrap = s.wrap, .spaces = s.spaces, .indent = @intCast(std.math.clamp(s.indent, 1, 8)) };
    }

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
        inline for (.{ "lines", "wrap", "spaces", "indent" }) |key| {
            @field(s.present, key) = c.g_key_file_has_key(k, "Coral", key, null) != 0;
        }
        s.theme = std.math.clamp(s.theme, 0, 3);
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
        inline for (.{ "theme", "font" }) |key| c.g_key_file_set_integer(k, "Coral", key, @field(s, key));
        if (s.present.indent) c.g_key_file_set_integer(k, "Coral", "indent", s.indent);
        inline for (.{ "lines", "wrap", "spaces" }) |key| {
            if (@field(s.present, key)) c.g_key_file_set_boolean(k, "Coral", key, @intFromBool(@field(s, key)));
        }
        c.g_key_file_set_boolean(k, "Coral", "spelling", @intFromBool(s.spelling));
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
    const z = allocator.dupeSentinel(u8, path, 0) catch return;
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
    stored.present = .{ .lines = true, .wrap = true, .spaces = true, .indent = true };
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

test "missing or out-of-range theme falls back to Follow Pearl" {
    const missing = Settings.loadFrom("/nonexistent/coral/preferences.ini");
    try std.testing.expectEqual(@as(c_int, 3), missing.theme);
    const dir = try tempDir();
    defer {
        removeTree(dir);
        allocator.free(dir);
    }
    const stored: Settings = .{ .theme = 9 };
    try stored.saveIn(dir);
    const path = try joinZ(dir, "preferences.ini");
    defer allocator.free(path);
    try std.testing.expectEqual(@as(c_int, 3), Settings.loadFrom(path).theme);
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

test "absent safe keys stay absent when unrelated preferences are saved" {
    const dir = try tempDir();
    defer {
        removeTree(dir);
        allocator.free(dir);
    }
    const path = try joinZ(dir, "preferences.ini");
    defer allocator.free(path);
    if (c.g_file_set_contents(path, "[Coral]\nfont=18\nwrap=true\n", -1, null) == 0) return error.TestSetup;
    var stored = Settings.loadFrom(path);
    try std.testing.expect(stored.present.wrap);
    try std.testing.expect(!stored.present.lines and !stored.present.spaces and !stored.present.indent);
    try std.testing.expectEqual(policy.Origin.user, policy.resolve(stored.baseline(), stored.present, .{}, .{}, .{}).origins.wrap);
    stored.font = 20;
    try stored.saveIn(dir);
    const loaded = Settings.loadFrom(path);
    try std.testing.expectEqualDeep(stored.present, loaded.present);
    try std.testing.expectEqual(@as(c_int, 20), loaded.font);
}

test "explicit default safe preferences survive without serializing repository values" {
    const dir = try tempDir();
    defer {
        removeTree(dir);
        allocator.free(dir);
    }
    const path = try joinZ(dir, "preferences.ini");
    defer allocator.free(path);
    var stored: Settings = .{};
    stored.present = .{ .lines = true, .wrap = true, .spaces = true, .indent = true };
    const effective = policy.resolve(stored.baseline(), stored.present, .{ .general = .{ .indent = 8, .lines = false } }, .{}, .{});
    try std.testing.expectEqual(@as(u8, 8), effective.values.indent);
    try stored.saveIn(dir);
    const loaded = Settings.loadFrom(path);
    try std.testing.expectEqualDeep(stored.present, loaded.present);
    try std.testing.expectEqual(@as(c_int, 4), loaded.indent);
    try std.testing.expect(loaded.lines);
    try std.testing.expectEqual(policy.Origin.user, policy.resolve(loaded.baseline(), loaded.present, .{}, .{}, .{}).origins.indent);
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
