//! Configuration helpers belong to the compositor behind the verified IPC peer.
const std = @import("std");
const glib = @import("glib2");
const gio = @import("gio2");

pub const keys = [_][:0]const u8{
    "HOME",          "XDG_CONFIG_HOME", "AQUEOUS_CONFIG", "AQUEOUS_LAYOUT",
    "AQUEOUS_INPUT", "AQUEOUS_OUTPUTS", "AQUEOUS_RULES",  "AQUEOUS_APPEARANCE",
};
pub const Context = struct {
    helper: [:0]const u8,
    cwd: [:0]const u8,
    values: [keys.len]?[:0]const u8,

    pub fn configure(self: Context, launcher: *gio.SubprocessLauncher) void {
        launcher.setCwd(self.cwd);
        for (keys, self.values) |key, value| {
            if (value) |v| launcher.setenv(key, v, 1) else launcher.unsetenv(key);
        }
    }
};

fn link(a: std.mem.Allocator, pid: u32, name: []const u8) ![:0]const u8 {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/{s}", .{ pid, name });
    var buffer: [4096]u8 = undefined;
    const n = std.c.readlink(path, &buffer, buffer.len);
    if (n <= 0 or n == buffer.len) return error.AqueousInstanceUnavailable;
    const value = buffer[0..@intCast(n)];
    if (!std.fs.path.isAbsolute(value) or std.mem.endsWith(u8, value, " (deleted)")) return error.AqueousInstanceUnavailable;
    return a.dupeZ(u8, value);
}

pub fn read(a: std.mem.Allocator, pid: u32) !Context {
    const exe = try link(a, pid, "exe");
    const helper = try std.fmt.allocPrintSentinel(a, "{s}/aqueous-config", .{std.fs.path.dirname(exe).?}, 0);
    // Never choose a different installation merely because it precedes this one
    // on PATH. Split development builds must stage the matching helper here.
    if (glib.fileTest(helper, .{ .is_executable = true }) == 0) return error.InstanceHelperUnavailable;
    const cwd = try link(a, pid, "cwd");
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/environ", .{pid});
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.AqueousInstanceUnavailable;
    defer _ = std.c.close(fd);
    const bytes = try a.alloc(u8, 128 * 1024 + 1);
    defer {
        std.crypto.secureZero(u8, bytes);
        a.free(bytes);
    }
    var used: usize = 0;
    while (used < bytes.len) {
        const n = std.c.read(fd, bytes[used..].ptr, bytes.len - used);
        if (n < 0) return error.AqueousInstanceUnavailable;
        if (n == 0) return .{ .helper = helper, .cwd = cwd, .values = try parse(a, bytes[0..used]) };
        used += @intCast(n);
    }
    return error.EnvironmentTooLarge;
}

fn parse(a: std.mem.Allocator, bytes: []const u8) ![keys.len]?[:0]const u8 {
    if (bytes.len > 0 and bytes[bytes.len - 1] != 0) return error.IncompleteEnvironment;
    var values: [keys.len]?[:0]const u8 = @splat(null);
    var entries = std.mem.splitScalar(u8, bytes, 0);
    while (entries.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        for (keys, 0..) |key, i| {
            if (!std.mem.eql(u8, entry[0..eq], key)) continue;
            if (values[i] != null) return error.DuplicateConfigEnvironment;
            values[i] = try a.dupeZ(u8, entry[eq + 1 ..]);
        }
    }
    return values;
}

test "instance context imports only config paths, preserves empty values and rejects truncation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = try parse(a, "HOME=/home/session\x00AQUEOUS_CONFIG=relative/wm.toml\x00XDG_CONFIG_HOME=\x00PATH=/wrong/bin\x00TOKEN=private\x00");
    try std.testing.expectEqualStrings("/home/session", values[0].?);
    try std.testing.expectEqualStrings("", values[1].?);
    try std.testing.expectEqualStrings("relative/wm.toml", values[2].?);
    try std.testing.expect(values[3] == null);
    try std.testing.expectError(error.IncompleteEnvironment, parse(a, "HOME=/tmp"));
    try std.testing.expectError(error.DuplicateConfigEnvironment, parse(a, "HOME=one\x00HOME=two\x00"));
}
