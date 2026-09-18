//! Bound durable theme history while retaining current and last active snapshots.
const std = @import("std");
const c = @import("package.zig").c;
const io = @import("../config/io.zig");
const model = @import("package_model.zig");
pub fn write(a: std.mem.Allocator, directory: [:0]const u8, digest: []const u8, bytes: []const u8) !void {
    try model.digest(digest);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}.json", .{ directory, digest }, 0);
    const old = try io.read(a, path, 16384, null);
    if (!old.missing) {
        if (!std.mem.eql(u8, bytes, old.bytes)) return error.ThemeSnapshotCorrupt;
        return;
    }
    const fd = c.open(directory, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return error.ThemeSnapshotDirectory;
    const dir = c.fdopendir(fd) orelse {
        _ = c.close(fd);
        return error.ThemeSnapshotDirectory;
    };
    defer _ = c.closedir(dir);
    var count: usize = 0;
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        count += 1;
        if (count >= 64) return error.ThemeSnapshotLimit;
    }
    try io.atomic(path, bytes, true);
}
pub fn prune(a: std.mem.Allocator, directory: [:0]const u8, current: []const u8, previous: []const u8) !void {
    const fd = c.open(directory, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return;
    const dir = c.fdopendir(fd) orelse {
        _ = c.close(fd);
        return;
    };
    defer _ = c.closedir(dir);
    const Item = struct { name: [:0]const u8, modified: i64 };
    var items: std.ArrayList(Item) = .empty;
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
        if (name.len != 69 or !std.mem.endsWith(u8, name, ".json")) continue;
        model.digest(name[0..64]) catch continue;
        if (std.mem.eql(u8, current, name[0..64]) or std.mem.eql(u8, previous, name[0..64])) continue;
        if (items.items.len >= 1024) break;
        const z = try a.dupeZ(u8, name);
        var info: c.struct_stat = undefined;
        if (c.fstatat(fd, z, &info, c.AT_SYMLINK_NOFOLLOW) != 0 or info.st_mode & c.S_IFMT != c.S_IFREG) continue;
        try items.append(a, .{ .name = z, .modified = info.st_mtim.tv_sec });
    }
    std.mem.sort(Item, items.items, {}, struct {
        fn less(_: void, x: Item, y: Item) bool {
            return x.modified > y.modified;
        }
    }.less);
    for (items.items[@min(14, items.items.len)..]) |item| {
        const bytes = @import("package.zig").read(a, fd, item.name, 16384) catch continue;
        if (std.mem.eql(u8, &io.digest(bytes), item.name[0..64])) _ = c.unlinkat(fd, item.name, 0);
    }
}
