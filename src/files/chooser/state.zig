//! Bounded private view preferences. Cancel preserves the last accepted folder.
//! POSIX calls provide no-follow opens, ownership checks and a nonblocking lock;
//! GLib's existing bindings provide key files and atomic replacement.
const std = @import("std");
const glib = @import("glib2");
const a = std.heap.c_allocator;
const sys = std.c;
pub const Preferences = struct { list: bool = false, hidden: bool = false, reverse: bool = false, preview: bool = true, sort: c_uint = 0, folder: ?[*:0]u8 = null };
fn format(comptime pattern: []const u8, args: anytype) [:0]u8 {
    return std.fmt.allocPrintSentinel(a, pattern, args, 0) catch @panic("Out of memory");
}
pub fn path() ?[:0]u8 {
    const dir = format("{s}/pearl", .{glib.getUserStateDir()});
    defer a.free(dir);
    if (glib.mkdirWithParents(dir, 0o700) != 0) return null;
    var st: std.os.linux.Statx = undefined;
    if (sys.statx(sys.AT.FDCWD, dir, sys.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &st) != 0 or !st.mask.TYPE or !st.mask.MODE or !st.mask.UID or (st.mode & sys.S.IFMT) != sys.S.IFDIR or st.uid != sys.getuid()) return null;
    return format("{s}/file-chooser.ini", .{dir});
}
pub fn read(filename: [*:0]const u8) *glib.KeyFile {
    var keys = glib.KeyFile.new();
    const fd = sys.open(filename, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true });
    if (fd < 0) return keys;
    defer _ = sys.close(fd);
    var st: std.os.linux.Statx = undefined;
    if (sys.statx(fd, "", sys.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .UID = true, .SIZE = true }, &st) != 0 or !st.mask.TYPE or !st.mask.MODE or !st.mask.UID or (st.mode & sys.S.IFMT) != sys.S.IFREG or st.uid != sys.getuid() or (st.mode & 0o077) != 0 or !st.mask.SIZE or st.size == 0 or st.size > 1024 * 1024) return keys;
    const content = a.allocSentinel(u8, @intCast(st.size), 0) catch return keys;
    defer a.free(content);
    var used: usize = 0;
    while (used < content.len) {
        const count = sys.read(fd, content.ptr + used, content.len - used);
        if (count <= 0) break;
        used += @intCast(count);
    }
    if (used == content.len and keys.loadFromData(content, content.len, .{}, null) == 0) {
        keys.unref();
        keys = glib.KeyFile.new();
    }
    return keys;
}
pub fn load(group: [*:0]const u8) Preferences {
    var result = Preferences{};
    const filename = path() orelse return result;
    defer a.free(filename);
    const keys = read(filename);
    defer keys.unref();
    if (keys.hasGroup(group) == 0) return result;
    result.list = keys.getBoolean(group, "list", null) != 0;
    result.hidden = keys.getBoolean(group, "hidden", null) != 0;
    result.reverse = keys.getBoolean(group, "reverse", null) != 0;
    if (keys.hasKey(group, "preview", null) != 0) result.preview = keys.getBoolean(group, "preview", null) != 0;
    result.sort = @intCast(std.math.clamp(keys.getInteger(group, "sort", null), 0, 3));
    result.folder = keys.getString(group, "folder", null);
    if (result.folder) |folder| {
        if (std.mem.len(folder) > 4096) {
            glib.free(folder);
            result.folder = null;
        }
    }
    return result;
}
pub fn save(group: [*:0]const u8, prefs: Preferences) void {
    const filename = path() orelse return;
    defer a.free(filename);
    const lock_path = format("{s}.lock", .{filename});
    defer a.free(lock_path);
    const lock = sys.open(lock_path, .{ .CREAT = true, .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(sys.mode_t, 0o600));
    if (lock < 0) return;
    defer _ = sys.close(lock);
    var st: std.os.linux.Statx = undefined;
    if (sys.statx(lock, "", sys.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .UID = true }, &st) != 0 or !st.mask.TYPE or !st.mask.MODE or !st.mask.UID or (st.mode & sys.S.IFMT) != sys.S.IFREG or st.uid != sys.getuid() or (st.mode & 0o077) != 0 or sys.flock(lock, sys.LOCK.EX | sys.LOCK.NB) != 0) return;
    defer _ = sys.flock(lock, sys.LOCK.UN);
    const keys = read(filename);
    defer keys.unref();
    var count: usize = 0;
    const groups = keys.getGroups(&count);
    defer glib.strfreev(groups);
    const max_existing: usize = if (keys.hasGroup(group) != 0) 128 else 127;
    while (count > max_existing) {
        var oldest: ?[*:0]const u8 = null;
        var age: i64 = std.math.maxInt(i64);
        var i: usize = 0;
        while (groups[i]) |entry| : (i += 1) {
            if (keys.hasGroup(entry) == 0 or std.mem.eql(u8, std.mem.span(entry), std.mem.span(group))) continue;
            const used = keys.getInt64(entry, "used", null);
            if (oldest == null or used < age) {
                oldest = entry;
                age = used;
            }
        }
        if (oldest) |entry| {
            _ = keys.removeGroup(entry, null);
            count -= 1;
        } else break;
    }
    keys.setBoolean(group, "list", @intFromBool(prefs.list));
    keys.setBoolean(group, "hidden", @intFromBool(prefs.hidden));
    keys.setBoolean(group, "reverse", @intFromBool(prefs.reverse));
    keys.setBoolean(group, "preview", @intFromBool(prefs.preview));
    keys.setInteger(group, "sort", @intCast(prefs.sort));
    keys.setInt64(group, "used", glib.getRealTime());
    if (prefs.folder) |folder| {
        if (std.mem.len(folder) <= 4096) keys.setString(group, "folder", folder);
    }
    var size: usize = 0;
    const content = keys.toData(&size, null) orelse return;
    defer glib.free(content);
    if (size <= 1024 * 1024) _ = glib.fileSetContentsFull(filename, content, @intCast(size), .{ .consistent = true }, 0o600, null);
}

test "isolated state, cancellation, bounded eviction, corrupt and symlink recovery" {
    const t = std.testing;
    const dir = glib.Dir.makeTmp("pearl-zig-chooser-state-XXXXXX", null) orelse return error.TempDirectoryFailed;
    defer glib.free(dir);
    try t.expect(glib.setenv("XDG_STATE_HOME", dir, 1) != 0);
    var prefs = Preferences{ .list = true, .hidden = true, .preview = true, .sort = 2, .folder = @constCast("file:///tmp/accepted-folder") };
    save("caller-a", prefs);
    var loaded = load("caller-a");
    try t.expect(loaded.list and loaded.hidden and loaded.preview);
    try t.expectEqualStrings("file:///tmp/accepted-folder", std.mem.span(loaded.folder.?));
    glib.free(loaded.folder);
    prefs.folder = null;
    prefs.list = false;
    save("caller-a", prefs);
    loaded = load("caller-a");
    try t.expect(!loaded.list);
    try t.expectEqualStrings("file:///tmp/accepted-folder", std.mem.span(loaded.folder.?));
    glib.free(loaded.folder);
    loaded = load("caller-b");
    try t.expect(loaded.folder == null and !loaded.hidden);
    for (0..130) |i| {
        const group = format("caller-{d:0>3}", .{i});
        defer a.free(group);
        save(group, prefs);
    }
    const filename = path().?;
    defer a.free(filename);
    const keys = read(filename);
    defer keys.unref();
    var count: usize = 0;
    const groups = keys.getGroups(&count);
    defer glib.strfreev(groups);
    try t.expectEqual(@as(usize, 128), count);
    try t.expect(keys.hasGroup("caller-a") == 0 and keys.hasGroup("caller-129") != 0);
    try t.expect(glib.fileSetContents(filename, "invalid", -1, null) != 0);
    loaded = load("caller-129");
    try t.expect(loaded.folder == null);
    const other = format("{s}.other", .{filename});
    defer a.free(other);
    try t.expect(glib.fileSetContents(other, "[caller-a]\nhidden=true\n", -1, null) != 0);
    try t.expectEqual(@as(c_int, 0), sys.unlink(filename));
    try t.expectEqual(@as(c_int, 0), sys.symlink(other, filename));
    loaded = load("caller-a");
    try t.expect(!loaded.hidden);
    save("caller-b", prefs);
    var contents: ?[*:0]u8 = null;
    try t.expect(glib.fileGetContents(other, @ptrCast(&contents), null, null) != 0);
    defer glib.free(contents);
    try t.expectEqualStrings("[caller-a]\nhidden=true\n", std.mem.span(contents.?));
    _ = sys.unlink(other);
    _ = sys.unlink(filename);
    const lock = format("{s}.lock", .{filename});
    defer a.free(lock);
    _ = sys.unlink(lock);
    const state_dir = format("{s}/pearl", .{dir});
    defer a.free(state_dir);
    _ = sys.rmdir(state_dir);
    _ = sys.rmdir(dir);
}
