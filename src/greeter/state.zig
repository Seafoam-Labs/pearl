//! Optional, untrusted selection memory. IDs only, never launch commands or credentials.
const std = @import("std");
const glib = @import("glib2");
const cfg = @import("config.zig");
const p = @import("protocol.zig");
const a = std.heap.c_allocator;
const Record = struct { username: []const u8, session: []const u8 };
fn path() [*:0]const u8 {
    if (@import("build_options").test_hooks) if (glib.getenv("PEARL_TEST_GREETER_STATE")) |v| return v;
    return "/var/lib/pearl-greeter/selections.json";
}
fn load(allocator: std.mem.Allocator) ![]Record {
    const fd = std.c.open(path(), .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return &.{};
    defer _ = std.c.close(fd);
    var stat: std.os.linux.Statx = undefined;
    if (std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .UID = true, .MODE = true, .SIZE = true }, &stat) != 0 or !std.c.S.ISREG(stat.mode) or stat.uid != std.os.linux.getuid() or stat.mode & 0o077 != 0 or stat.size > 65536) return error.InvalidState;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    var used: usize = 0;
    while (used < bytes.len) {
        const n = std.c.read(fd, bytes[used..].ptr, bytes.len - used);
        if (n <= 0) return error.Read;
        used += @intCast(n);
    }
    try p.validateJson(bytes, 65536);
    const records = try std.json.parseFromSliceLeaky([]Record, allocator, bytes, .{ .allocate = .alloc_always });
    if (records.len > 256) return error.StateLimit;
    for (records) |record| if (!p.validText(record.username, 256) or !cfg.validId(record.session)) return error.InvalidState;
    return records;
}
pub fn remembered(allocator: std.mem.Allocator, username: []const u8) ?[]const u8 {
    const records = load(allocator) catch return null;
    for (records) |record| if (std.mem.eql(u8, record.username, username)) return record.session;
    return null;
}
pub fn save(username: []const u8, id: []const u8) !void {
    if (!p.validText(username, 256) or !cfg.validId(id)) return error.InvalidState;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const records = load(alloc) catch &.{};
    var result: std.ArrayList(Record) = .empty;
    try result.append(alloc, .{ .username = username, .session = id });
    for (records) |record| if (!std.mem.eql(u8, record.username, username) and result.items.len < 256) try result.append(alloc, record);
    const bytes = try std.json.Stringify.valueAlloc(alloc, result.items, .{});
    if (bytes.len > 65536) return error.StateLimit;
    const temporary = try std.fmt.allocPrintSentinel(alloc, "{s}.tmp.{d}", .{ std.mem.span(path()), std.os.linux.getpid() }, 0);
    const fd = std.c.open(temporary, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c_uint, 0o600));
    if (fd < 0) return error.StateWrite;
    defer _ = std.c.close(fd);
    defer _ = std.c.unlink(temporary);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return error.StateWrite;
        offset += @intCast(n);
    }
    if (std.c.fsync(fd) != 0 or std.c.rename(temporary, path()) != 0) return error.StateWrite;
}
