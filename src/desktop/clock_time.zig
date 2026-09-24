//! GLib time conversion and bounded discovery of the installed zone database.
const std = @import("std");
const glib = @import("glib2");
pub const policy = @import("clock_policy.zig");
const a = std.heap.c_allocator;

pub fn resolve(name: []const u8) ?*glib.TimeZone {
    if (!policy.validZone(name)) return null;
    if (std.mem.eql(u8, name, "local")) return glib.TimeZone.newLocal();
    if (std.mem.eql(u8, name, "UTC")) return glib.TimeZone.newUtc();
    // Requiring an installed TZif file excludes POSIX expressions and offsets,
    // while allowing historical aliases not listed in zone.tab.
    var buffer: [160:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buffer, "/usr/share/zoneinfo/{s}", .{name}) catch return null;
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, @as(c_uint, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var magic: [4]u8 = undefined;
    if (std.c.read(fd, &magic, magic.len) != 4 or !std.mem.eql(u8, &magic, "TZif")) return null;
    const id = a.dupeZ(u8, name) catch return null;
    defer a.free(id);
    return glib.TimeZone.newIdentifier(id);
}
pub fn available(name: []const u8) bool {
    const zone = resolve(name) orelse return false;
    zone.unref();
    return true;
}
pub fn catalog(alloc: std.mem.Allocator) ![]const [:0]const u8 {
    var names: std.ArrayList([:0]const u8) = .empty;
    try names.appendSlice(alloc, &.{ "local", "UTC" });
    const fd = std.c.open("/usr/share/zoneinfo/zone.tab", .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, @as(c_uint, 0));
    if (fd < 0) return names.toOwnedSlice(alloc);
    defer _ = std.c.close(fd);
    var bytes: [65537]u8 = undefined;
    var used: usize = 0;
    while (used < bytes.len) {
        const n = std.c.read(fd, bytes[used..].ptr, bytes.len - used);
        if (n < 0) return names.toOwnedSlice(alloc);
        if (n == 0) break;
        used += @intCast(n);
    }
    if (used == bytes.len) return names.toOwnedSlice(alloc);
    var lines = std.mem.splitScalar(u8, bytes[0..used], '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        _ = fields.next();
        _ = fields.next();
        const name = fields.next() orelse continue;
        if (!policy.validZone(name)) continue;
        if (names.items.len >= 1024) break;
        try names.append(alloc, try alloc.dupeZ(u8, name));
    }
    std.mem.sort([:0]const u8, names.items[2..], {}, struct {
        fn less(_: void, lhs: [:0]const u8, rhs: [:0]const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.less);
    return names.toOwnedSlice(alloc);
}
pub const Text = struct { time: [:0]const u8, date: [:0]const u8, detail: [:0]const u8 };
pub fn format(alloc: std.mem.Allocator, d: policy.Definition, utc: *glib.DateTime, zone: *glib.TimeZone, vertical: bool) !Text {
    const local = utc.toTimezone(zone) orelse return error.ClockUnavailable;
    defer local.unref();
    const pattern: [:0]const u8 = if (d.hour_format == .@"12h") (if (vertical) "%I\n%M\n%p" else "%I:%M %p") else (if (vertical) "%H\n%M" else "%H:%M");
    const time = local.format(pattern) orelse return error.ClockUnavailable;
    defer glib.free(time);
    const date = local.format(if (vertical) "%a\n%d\n%b" else "%a %d %b") orelse return error.ClockUnavailable;
    defer glib.free(date);
    const detail = local.format("%A, %d %B %Y · %H:%M · UTC%:z") orelse return error.ClockUnavailable;
    defer glib.free(detail);
    return .{ .time = try alloc.dupeZ(u8, std.mem.span(time)), .date = try alloc.dupeZ(u8, std.mem.span(date)), .detail = try std.fmt.allocPrintSentinel(alloc, "{s} · {s} · {s}", .{ try policy.displayName(alloc, d), d.timezone, detail }, 0) };
}
/// File identity/mtime catches atomic replacement as well as in-place tzdata updates.
pub fn databaseStamp() u64 {
    var hash = std.hash.Wyhash.init(0);
    for ([_][:0]const u8{ "/etc/localtime", "/usr/share/zoneinfo/tzdata.zi", "/usr/share/zoneinfo" }) |path| {
        var stat: std.os.linux.Statx = std.mem.zeroes(std.os.linux.Statx);
        if (std.os.linux.statx(std.os.linux.AT.FDCWD, path, 0, .{ .MTIME = true, .INO = true, .SIZE = true }, &stat) == 0) {
            hash.update(std.mem.asBytes(&stat.mtime));
            hash.update(std.mem.asBytes(&stat.ino));
            hash.update(std.mem.asBytes(&stat.size));
        }
    }
    return hash.final();
}
