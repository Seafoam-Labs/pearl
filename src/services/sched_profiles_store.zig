//! System files behind scheduling profiles. Profiles map to commands run as
//! root, so only administrator and installation paths are read.
const std = @import("std");
const io = @import("../config/io.zig");
const p = @import("sched_profiles.zig");
const distribution = @import("../settings/distribution.zig");

pub const Loaded = struct { path: [:0]const u8, config: p.Config };

/// /etc/pearl, then the installation's share/pearl; the first file found is
/// used on its own. Null when neither exists. Works from bin/ and lib/pearl/.
pub fn load(a: std.mem.Allocator) !?Loaded {
    var buffer: [4096]u8 = undefined;
    const exe = try distribution.executable(&buffer);
    const dir = std.fs.path.dirname(exe).?;
    const component = std.fs.path.basename(dir);
    const in_lib = std.mem.startsWith(u8, component, "pearl");
    const name = if (in_lib) component else if (distribution.isGit(exe)) "pearl-git" else "pearl";
    const paths = [_][:0]const u8{
        try std.fmt.allocPrintSentinel(a, "/etc/{s}/{s}", .{ name, p.file_name }, 0),
        try std.fmt.allocPrintSentinel(a, "{s}/{s}/share/{s}/{s}", .{ dir, if (in_lib) "../.." else "..", name, p.file_name }, 0),
    };
    for (paths) |path| {
        const file = try io.read(a, path, p.max_bytes, null);
        if (file.missing) continue;
        return .{ .path = path, .config = try p.parse(a, file.bytes) };
    }
    return null;
}

/// Profiles replace the scx_loader editor; a broken file still counts, so
/// the two never run side by side.
pub fn installed() bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const loaded = load(arena.allocator()) catch return true;
    return loaded != null;
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
