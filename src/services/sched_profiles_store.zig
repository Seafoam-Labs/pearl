//! Files behind scheduling profiles. Profiles map to commands run as root, so
//! they come only from root-owned files: the administrator's copy in /etc,
//! written by the helper behind an administrator password, else the one the
//! package ships. Any active user may apply them.
const std = @import("std");
const glib = @import("glib2");
const io = @import("../config/io.zig");
const p = @import("sched_profiles.zig");
const distribution = @import("../settings/distribution.zig");

pub const Loaded = struct {
    path: [:0]const u8,
    config: p.Config,
    /// From the administrator's file rather than the shipped one.
    admin: bool,
};

/// The administrator's file in /etc/pearl, then the one shipped in the
/// installation's share/pearl. Works from bin/ and lib/pearl/.
pub fn paths(a: std.mem.Allocator) ![2][:0]const u8 {
    var buffer: [4096]u8 = undefined;
    const exe = try distribution.executable(&buffer);
    const dir = std.fs.path.dirname(exe).?;
    const component = std.fs.path.basename(dir);
    const in_lib = std.mem.startsWith(u8, component, "pearl");
    const name = if (in_lib) component else if (distribution.isGit(exe)) "pearl-git" else "pearl";
    return .{
        try std.fmt.allocPrintSentinel(a, "/etc/{s}/{s}", .{ name, p.file_name }, 0),
        try std.fmt.allocPrintSentinel(a, "{s}/{s}/share/{s}/{s}", .{ dir, if (in_lib) "../.." else "..", name, p.file_name }, 0),
    };
}

/// The first file found is used on its own. Null when neither exists.
pub fn load(a: std.mem.Allocator) !?Loaded {
    for (try paths(a), 0..) |path, i| {
        const file = try io.read(a, path, p.max_bytes, null);
        if (file.missing) continue;
        return .{ .path = path, .config = try p.parse(a, file.bytes), .admin = i == 0 };
    }
    return null;
}

/// The profiles the package ships, which restoring the defaults returns to.
pub fn loadShipped(a: std.mem.Allocator) !?p.Config {
    const file = try io.read(a, (try paths(a))[1], p.max_bytes, null);
    return if (file.missing) null else try p.parse(a, file.bytes);
}

/// The executable a profile's scheduler runs: its path, or for a bare name
/// the first match in the directories the unit's shell would search, so the
/// choice cannot change when another binary is installed later.
pub fn resolve(a: std.mem.Allocator, sched: []const u8) !?[:0]const u8 {
    if (!p.validSched(sched)) return null;
    if (sched[0] == '/') {
        const path = try a.dupeSentinel(u8, sched, 0);
        return if (std.c.access(path, std.c.X_OK) == 0) path else null;
    }
    for (p.scheduler_dirs) |dir| {
        const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, sched }, 0);
        if (std.c.access(path, std.c.X_OK) == 0) return path;
    }
    return null;
}

/// The sched_ext schedulers installed by packages, sorted by name. Profiles
/// may also run schedulers from /usr/local/bin, but the editor offers only
/// these.
pub fn installedSchedulers(a: std.mem.Allocator) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const dir = glib.Dir.open("/usr/bin", 0, null) orelse return names.items;
    defer dir.close();
    // GIR misses g_dir_read_name's nullable end-of-directory return.
    const read: *const fn (*glib.Dir) callconv(.c) ?[*:0]const u8 = @ptrCast(&glib.Dir.readName);
    while (read(dir)) |raw| {
        const name = std.mem.span(raw);
        // scx_loader is a daemon that runs schedulers, not one itself.
        if (!p.validName(name) or std.mem.eql(u8, name, "scx_loader")) continue;
        const full = try std.fmt.allocPrintSentinel(a, "/usr/bin/{s}", .{name}, 0);
        if (std.c.access(full, std.c.X_OK) == 0) try names.append(a, try a.dupe(u8, name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return names.items;
}

pub fn readEnv(a: std.mem.Allocator) !p.Env {
    const file = try io.read(a, p.env_path, 4096, null);
    return if (file.missing) .{} else p.parseEnv(file.bytes);
}

/// The root helper installed next to this build's other private helpers.
pub fn helperPath() [:0]const u8 {
    var buffer: [4096]u8 = undefined;
    const exe = distribution.executable(&buffer) catch return "/usr/lib/pearl/pearl-scheduling-helper";
    return if (distribution.isGit(exe)) "/usr/lib/pearl-git/pearl-scheduling-helper" else "/usr/lib/pearl/pearl-scheduling-helper";
}
