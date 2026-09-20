const std = @import("std");
pub const c = @import("c.zig").c;
const m = @import("../core/model.zig");
pub fn path(comptime fmt: []const u8, args: anytype) m.Text(2048) {
    var result: m.Text(2048) = .{};
    const s = std.fmt.bufPrint(result.bytes[0..2048], fmt, args) catch return result;
    result.len = s.len;
    result.bytes[result.len] = 0;
    return result;
}
pub fn read(name: []const u8, buffer: []u8) ?[]const u8 {
    const p = m.Text(2048).init(name);
    const fd = c.open(p.z(), c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var n: usize = 0;
    while (n < buffer.len) {
        const got = c.read(fd, buffer[n..].ptr, buffer.len - n);
        if (got < 0) {
            if (c.__errno_location().* == c.EINTR) continue;
            return null;
        }
        if (got == 0) return buffer[0..n];
        n += @intCast(got);
    }
    // Reject truncation instead of parsing a partial record.
    var extra: [1]u8 = undefined;
    if (c.read(fd, &extra, 1) != 0) return null;
    return buffer[0..n];
}
pub fn text(name: []const u8) m.Name {
    var buffer: [4096]u8 = undefined;
    return m.Name.init(std.mem.trim(u8, read(name, &buffer) orelse "", " \n\t\r"));
}
pub fn number(name: []const u8) ?f64 {
    const value = text(name);
    return m.number(value.slice());
}
pub fn integer(name: []const u8) ?u64 {
    const value = text(name);
    return m.uint(value.slice());
}
pub fn exists(name: []const u8) bool {
    const p = m.Text(2048).init(name);
    return c.access(p.z(), c.F_OK) == 0;
}
pub fn link(name: []const u8) m.Path {
    var result: m.Path = .{};
    const p = m.Text(2048).init(name);
    var buffer: [512]u8 = undefined;
    const n = c.readlink(p.z(), &buffer, buffer.len);
    if (n > 0 and n < buffer.len) result.set(buffer[0..@intCast(n)]);
    return result;
}
pub fn real(name: []const u8) m.Path {
    const p = m.Text(2048).init(name);
    const value = c.realpath(p.z(), null);
    if (value == null) return .{};
    defer c.free(value);
    return m.Path.init(std.mem.span(value));
}
pub const Dir = struct {
    handle: *c.DIR,
    pub fn open(name: []const u8) ?Dir {
        const p = m.Text(2048).init(name);
        return .{ .handle = c.opendir(p.z()) orelse return null };
    }
    pub fn close(self: Dir) void {
        _ = c.closedir(self.handle);
    }
    pub fn next(self: Dir) ?[]const u8 {
        while (c.readdir(self.handle)) |entry| {
            const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
            if (name.len == 0 or name[0] == '.') continue;
            return name;
        }
        return null;
    }
};
pub fn monotonic() i64 {
    return c.g_get_monotonic_time();
}
pub fn errorMessage() []const u8 {
    return std.mem.span(c.strerror(c.__errno_location().*));
}
