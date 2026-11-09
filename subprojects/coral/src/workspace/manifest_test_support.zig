//! Test-only fixture: all filesystem writes live here or in the unit tests.
const std = @import("std");
const a = std.testing.allocator;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

pub const Fixture = struct {
    base: [:0]u8,
    entries: std.ArrayList(Entry) = .empty,
    const Entry = struct { path: [:0]u8, directory: bool };

    pub fn init() !Fixture {
        const base = try a.dupeSentinel(u8, "/tmp/coral-workspace-XXXXXX", 0);
        errdefer a.free(base);
        if (mkdtemp(base) == null) return error.Fixture;
        return .{ .base = base };
    }

    pub fn deinit(self: *Fixture) void {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.entries.items[i];
            const result = if (entry.directory) std.c.rmdir(entry.path) else std.c.unlink(entry.path);
            std.debug.assert(result == 0);
            a.free(entry.path);
        }
        self.entries.deinit(a);
        std.debug.assert(std.c.rmdir(self.base) == 0);
        a.free(self.base);
    }

    pub fn path(self: *const Fixture, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ self.base, name }, 0);
    }

    fn remember(self: *Fixture, name: []const u8, directory: bool) ![:0]u8 {
        const p = try self.path(name);
        errdefer a.free(p);
        try self.entries.append(a, .{ .path = p, .directory = directory });
        return p;
    }

    pub fn mkdir(self: *Fixture, name: []const u8) !void {
        const p = try self.remember(name, true);
        try std.testing.expectEqual(@as(c_int, 0), std.c.mkdir(p, 0o700));
    }

    pub fn write(self: *Fixture, name: []const u8, bytes: []const u8) !void {
        const p = try self.remember(name, false);
        const fd = std.c.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
            if (n < 0 and std.c.errno(n) == .INTR) continue;
            try std.testing.expect(n > 0);
            offset += @intCast(n);
        }
    }

    pub fn symlink(self: *Fixture, target: [:0]const u8, name: []const u8) !void {
        const p = try self.remember(name, false);
        try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(target, p));
    }

    pub fn fifo(self: *Fixture, name: []const u8) !void {
        const p = try self.remember(name, false);
        try std.testing.expectEqual(@as(c_int, 0), mkfifo(p, 0o600));
    }
};
