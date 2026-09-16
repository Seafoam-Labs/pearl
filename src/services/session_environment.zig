//! Read only the session hint from an already credential-checked compositor PID.
const std = @import("std");
pub const Id = @import("policy.zig").Text(128);

pub fn read(pid: u32) !?Id {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/environ", .{pid});
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    // Restricted procfs may hide other processes, including same-user ones.
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const bytes = try std.heap.c_allocator.alloc(u8, 128 * 1024 + 1);
    defer {
        std.crypto.secureZero(u8, bytes);
        std.heap.c_allocator.free(bytes);
    }
    var used: usize = 0;
    while (used < bytes.len) {
        const n = std.c.read(fd, bytes[used..].ptr, bytes.len - used);
        if (n < 0) return error.ReadFailed;
        if (n == 0) return parse(bytes[0..used]);
        used += @intCast(n);
    }
    return error.EnvironmentTooLarge;
}

fn parse(bytes: []const u8) !?Id {
    if (bytes.len > 0 and bytes[bytes.len - 1] != 0) return error.IncompleteEnvironment;
    var result: ?Id = null;
    var entries = std.mem.splitScalar(u8, bytes, 0);
    while (entries.next()) |entry| {
        const prefix = "XDG_SESSION_ID=";
        if (!std.mem.startsWith(u8, entry, prefix)) continue;
        if (result != null) return error.DuplicateSession;
        const value = entry[prefix.len..];
        if (value.len == 0) continue;
        if (value.len >= 128 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidSession;
        var id: Id = .{};
        id.set(value);
        result = id;
    }
    return result;
}

test "extract only a complete bounded session hint from procfs environment" {
    try std.testing.expectEqualStrings("5", (try parse("PATH=/usr/bin\x00XDG_SESSION_ID=5\x00UNRELATED=value\x00")).?.slice());
    try std.testing.expect(try parse("OTHER_XDG_SESSION_ID=3\x00XDG_SESSION_ID=\x00") == null);
    try std.testing.expectError(error.IncompleteEnvironment, parse("XDG_SESSION_ID=5"));
    try std.testing.expectError(error.DuplicateSession, parse("XDG_SESSION_ID=3\x00XDG_SESSION_ID=5\x00"));
    try std.testing.expectError(error.InvalidSession, parse("XDG_SESSION_ID=" ++ "5" ** 128 ++ "\x00"));
}
