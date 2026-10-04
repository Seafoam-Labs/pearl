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

    /// Why a load did not produce stored values. `first_run` (no file yet) and
    /// `loaded` are normal; the rest are degraded states worth a journal line,
    /// classified from the GError domain and code only, never from a path or a
    /// value.
    pub const LoadOutcome = enum { first_run, loaded, unreadable, malformed, version };
    pub const Loaded = struct { prefs: Preferences, outcome: LoadOutcome };

    /// Why a save failed, so the caller can name directory versus serialization
    /// versus write failure instead of collapsing them into one bool.
    pub const SaveError = error{ Directory, Serialize, Write };

    pub fn load() Loaded {
        const path = io.path("{s}/dome/preferences.ini", .{std.mem.span(c.g_get_user_config_dir())});
        return loadFrom(path.z());
    }

    /// Reads `<dir>/dome` preferences from an explicit path so tests can target a
    /// temporary file instead of the real config directory.
    pub fn loadFrom(path: [*:0]const u8) Loaded {
        var p: Preferences = .{};
        const file = c.g_key_file_new().?;
        defer c.g_key_file_unref(file);
        var err: ?*c.GError = null;
        defer if (err) |e| c.g_error_free(e);
        if (c.g_key_file_load_from_file(file, path, 0, &err) == 0) {
            return .{ .prefs = p, .outcome = classifyLoad(err) };
        }
        // A stored version other than 1 is not a format this build understands;
        // discard it rather than misreading shifted keys.
        if (c.g_key_file_get_integer(file, "Dome", "version", null) != 1) {
            return .{ .prefs = p, .outcome = .version };
        }
        inline for (.{ "light", "native", "compact", "bits", "per_core" }) |key| @field(p, key) = c.g_key_file_get_boolean(file, "Dome", key, null) != 0;
        if (has(file, "columns")) p.columns = @as(u32, @intCast(std.math.clamp(c.g_key_file_get_integer(file, "Dome", "columns", null), 0, 63))) | 5;
        if (has(file, "sort_column")) {
            p.sort_column = @intCast(std.math.clamp(c.g_key_file_get_integer(file, "Dome", "sort_column", null), 0, 5));
            p.sort_descending = c.g_key_file_get_boolean(file, "Dome", "sort_descending", null) != 0;
        }
        // Guarded so a missing key keeps the struct default instead of reading 0
        // from GLib and snapping to the clamp floor (a file with `width` deleted
        // would otherwise reload 480 rather than 1120).
        if (has(file, "interval")) p.interval = std.math.clamp(c.g_key_file_get_int64(file, "Dome", "interval", null), 500000, 5000000);
        if (has(file, "duration")) p.duration = std.math.clamp(c.g_key_file_get_int64(file, "Dome", "duration", null), 120000000, 600000000);
        if (has(file, "width")) p.width = std.math.clamp(c.g_key_file_get_integer(file, "Dome", "width", null), 480, 3840);
        if (has(file, "height")) p.height = std.math.clamp(c.g_key_file_get_integer(file, "Dome", "height", null), 400, 2160);
        if (has(file, "page")) p.page = @intCast(std.math.clamp(c.g_key_file_get_integer(file, "Dome", "page", null), 0, 8));
        return .{ .prefs = p, .outcome = .loaded };
    }

    pub fn save(p: Preferences) SaveError!void {
        const dir = io.path("{s}/dome", .{std.mem.span(c.g_get_user_config_dir())});
        return saveIn(p, dir.slice());
    }

    /// Writes `preferences.ini` into an explicit directory so tests can target a
    /// temporary path instead of the real config directory.
    pub fn saveIn(p: Preferences, dir: []const u8) SaveError!void {
        const dir_text = io.path("{s}", .{dir});
        if (c.g_mkdir_with_parents(dir_text.z(), 0o700) != 0) return error.Directory;
        const path = io.path("{s}/preferences.ini", .{dir});
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
        var serialize_err: ?*c.GError = null;
        const text = c.g_key_file_to_data(file, &n, &serialize_err);
        if (serialize_err) |e| c.g_error_free(e);
        if (text == null) return error.Serialize;
        defer c.g_free(text);
        const target = c.g_file_new_for_path(path.z()).?;
        defer c.g_object_unref(target);
        var write_err: ?*c.GError = null;
        const ok = c.g_file_replace_contents(target, text, n, null, 0, c.G_FILE_CREATE_PRIVATE, null, null, &write_err) != 0;
        if (write_err) |e| c.g_error_free(e);
        if (!ok) return error.Write;
    }
};

fn has(file: *c.GKeyFile, key: [*:0]const u8) bool {
    return c.g_key_file_has_key(file, "Dome", key, null) != 0;
}

/// GLib reports open and read failures under `G_FILE_ERROR` and parse failures
/// under `G_KEY_FILE_ERROR`; only a missing file is the normal first run.
fn classifyLoad(err: ?*c.GError) Preferences.LoadOutcome {
    const e = err orelse return .unreadable;
    if (e.domain == c.g_file_error_quark()) {
        return if (e.code == c.G_FILE_ERROR_NOENT) .first_run else .unreadable;
    }
    if (e.domain == c.g_key_file_error_quark()) return .malformed;
    return .unreadable;
}

const allocator = std.heap.c_allocator;

var temp_counter: usize = 0;

fn tempDir() ![:0]u8 {
    temp_counter += 1;
    const path = try std.fmt.allocPrintSentinel(allocator, "/tmp/dome-prefs-{d}-{d}", .{ std.os.linux.getpid(), temp_counter }, 0);
    if (c.g_mkdir_with_parents(path, 0o700) != 0) {
        allocator.free(path);
        return error.TempDir;
    }
    return path;
}

fn removeTree(path: []const u8) void {
    if (io.Dir.open(path)) |dir| {
        defer dir.close();
        while (dir.next()) |name| {
            const child = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ path, name }, 0) catch continue;
            removeTree(child);
            allocator.free(child);
        }
    }
    const z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(z);
    _ = c.unlink(z);
    _ = c.rmdir(z);
}

fn writeFile(path: [:0]const u8, contents: []const u8) !void {
    if (c.g_file_set_contents(path, contents.ptr, @intCast(contents.len), null) == 0) return error.WriteFile;
}

fn joinZ(dir: []const u8, name: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, name }, 0);
}

test "preferences round-trip through save and load, including the version key" {
    const dir = try tempDir();
    defer {
        removeTree(dir);
        allocator.free(dir);
    }
    var stored: Preferences = .{ .light = true, .compact = true, .columns = 55, .sort_column = 4, .sort_descending = false, .interval = 2500000, .duration = 600000000, .width = 1440, .height = 900, .page = 3 };
    try stored.saveIn(dir);
    const path = try joinZ(dir, "preferences.ini");
    defer allocator.free(path);
    const loaded = Preferences.loadFrom(path);
    try std.testing.expectEqual(Preferences.LoadOutcome.loaded, loaded.outcome);
    const p = loaded.prefs;
    try std.testing.expectEqual(stored.light, p.light);
    try std.testing.expectEqual(stored.compact, p.compact);
    try std.testing.expectEqual(stored.columns, p.columns);
    try std.testing.expectEqual(stored.sort_column, p.sort_column);
    try std.testing.expectEqual(stored.sort_descending, p.sort_descending);
    try std.testing.expectEqual(stored.interval, p.interval);
    try std.testing.expectEqual(stored.duration, p.duration);
    try std.testing.expectEqual(stored.width, p.width);
    try std.testing.expectEqual(stored.height, p.height);
    try std.testing.expectEqual(stored.page, p.page);
}

test "a missing file is the normal first run and yields defaults" {
    const dir = try tempDir();
    defer {
        removeTree(dir);
        allocator.free(dir);
    }
    const path = try joinZ(dir, "absent.ini");
    defer allocator.free(path);
    const loaded = Preferences.loadFrom(path);
    try std.testing.expectEqual(Preferences.LoadOutcome.first_run, loaded.outcome);
    try std.testing.expectEqual(@as(c_int, 1120), loaded.prefs.width);
    try std.testing.expectEqual(@as(i64, 1000000), loaded.prefs.interval);
}

test "a malformed file is classified, not silently defaulted" {
    const dir = try tempDir();
    defer {
        removeTree(dir);
        allocator.free(dir);
    }
    const path = try joinZ(dir, "preferences.ini");
    defer allocator.free(path);
    try writeFile(path, "[Dome\nthis is not a key file\n");
    const loaded = Preferences.loadFrom(path);
    try std.testing.expectEqual(Preferences.LoadOutcome.malformed, loaded.outcome);
}

test "a stored version other than 1 is rejected" {
    const dir = try tempDir();
    defer {
        removeTree(dir);
        allocator.free(dir);
    }
    const path = try joinZ(dir, "preferences.ini");
    defer allocator.free(path);
    try writeFile(path, "[Dome]\nversion=2\nwidth=2000\n");
    const loaded = Preferences.loadFrom(path);
    try std.testing.expectEqual(Preferences.LoadOutcome.version, loaded.outcome);
    // Discarded, so the stale width never leaks through.
    try std.testing.expectEqual(@as(c_int, 1120), loaded.prefs.width);
}

test "a missing scalar keeps its default instead of snapping to the clamp floor" {
    const dir = try tempDir();
    defer {
        removeTree(dir);
        allocator.free(dir);
    }
    const path = try joinZ(dir, "preferences.ini");
    defer allocator.free(path);
    // version=1 with width and interval omitted entirely.
    try writeFile(path, "[Dome]\nversion=1\nheight=1000\n");
    const loaded = Preferences.loadFrom(path);
    try std.testing.expectEqual(Preferences.LoadOutcome.loaded, loaded.outcome);
    try std.testing.expectEqual(@as(c_int, 1120), loaded.prefs.width);
    try std.testing.expectEqual(@as(i64, 1000000), loaded.prefs.interval);
    // The present key still loads.
    try std.testing.expectEqual(@as(c_int, 1000), loaded.prefs.height);
}

test "saving over an unwritable target reports a write failure" {
    const dir = try tempDir();
    defer {
        removeTree(dir);
        allocator.free(dir);
    }
    // Put a directory where preferences.ini must go: the parent directory is
    // created fine, but the file cannot be replaced, so the write step fails.
    // This exercises the write branch without depending on permissions, which
    // root would bypass.
    const blocked = try joinZ(dir, "preferences.ini");
    defer allocator.free(blocked);
    if (c.g_mkdir_with_parents(blocked, 0o700) != 0) return error.TestSetup;
    const empty: Preferences = .{};
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
    try writeFile(file, "x");
    // mkdir_with_parents cannot traverse a regular file, so the directory step
    // fails before any serialization.
    const blocked = try joinZ(file, "nested");
    defer allocator.free(blocked);
    const empty: Preferences = .{};
    try std.testing.expectError(error.Directory, empty.saveIn(blocked));
}
