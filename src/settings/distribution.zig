//! Package identities follow the installed executable name, including co-installed -git builds.
const std = @import("std");
pub fn isGit(path: []const u8) bool {
    return std.mem.endsWith(u8, std.fs.path.basename(path), "-git");
}
pub fn executable(buffer: []u8) ![]const u8 {
    const n = std.c.readlink("/proc/self/exe", buffer.ptr, buffer.len);
    if (n <= 0 or n == buffer.len) return error.ExecutableUnavailable;
    return buffer[0..@intCast(n)];
}
pub fn appId() [:0]const u8 {
    var buffer: [4096]u8 = undefined;
    const path = executable(&buffer) catch return "org.aqueous.Pearl.Settings";
    return if (isGit(path)) "org.aqueous.Pearl.Git.Settings" else "org.aqueous.Pearl.Settings";
}
pub fn sibling(a: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(a, "{s}/pearl-settings{s}", .{ std.fs.path.dirname(path) orelse return error.ExecutableUnavailable, if (isGit(path)) "-git" else "" }, 0);
}
test "installed settings identity and sibling preserve package separation" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "/usr/bin/pearl", "/tmp/stage with spaces/bin/pearlctl", "/usr/bin/pearl-git", "/usr/bin/pearlctl-git" }, [_][]const u8{ "/usr/bin/pearl-settings", "/tmp/stage with spaces/bin/pearl-settings", "/usr/bin/pearl-settings-git", "/usr/bin/pearl-settings-git" }) |path, expected| {
        const result = try sibling(a, path);
        defer a.free(result);
        try std.testing.expectEqualStrings(expected, result);
    }
}
