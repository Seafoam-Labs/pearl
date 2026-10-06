//! Local login candidates used when AccountsService has no cached users.
//! Discovery is presentation only; greetd still authenticates every selection.
const std = @import("std");
pub const Account = struct { username: []const u8, label: []const u8 };

pub fn parse(a: std.mem.Allocator, passwd: []const u8, login_defs: []const u8) ![]const Account {
    var minimum: u32 = 1000;
    var definitions = std.mem.tokenizeScalar(u8, login_defs, '\n');
    while (definitions.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        if (!std.mem.eql(u8, words.next() orelse continue, "UID_MIN")) continue;
        minimum = std.fmt.parseInt(u32, words.next() orelse continue, 10) catch minimum;
    }
    var result: std.ArrayList(Account) = .empty;
    var lines = std.mem.tokenizeScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const name = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const uid = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        _ = fields.next() orelse continue; // gid
        _ = fields.next() orelse continue; // gecos
        _ = fields.next() orelse continue; // home
        const shell = fields.next() orelse continue;
        if (fields.next() != null or uid == 0 or uid < minimum or uid == 65534 or uid == std.math.maxInt(u32)) continue;
        if (shell.len == 0 or shell[0] != '/' or std.mem.eql(u8, std.fs.path.basename(shell), "nologin") or std.mem.eql(u8, std.fs.path.basename(shell), "false")) continue;
        if (name.len == 0 or !@import("protocol.zig").validText(name, 256)) continue;
        const owned = try a.dupe(u8, name);
        try result.append(a, .{ .username = owned, .label = owned });
        if (result.items.len == 256) break;
    }
    return result.toOwnedSlice(a);
}

test "local candidates preserve discovery order and exclude service accounts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const users = try parse(arena.allocator(), "root:x:0:0::/root:/bin/sh\n" ++
        "service:x:999:999::/:/bin/sh\n" ++
        "zoe:x:1001:1001::/home/zoe:/bin/zsh\n" ++
        "blocked:x:1002:1002::/:/usr/sbin/nologin\n" ++
        "disabled:x:1003:1003::/:/bin/false\n" ++
        "nobody:x:65534:65534::/:/bin/sh\n" ++
        "amy:x:1000:1000::/home/amy:/bin/bash\n" ++
        "broken\n", "");
    try std.testing.expectEqual(@as(usize, 2), users.len);
    try std.testing.expectEqualStrings("zoe", users[0].username);
    try std.testing.expectEqualStrings("amy", users[1].username);
    const custom = try parse(arena.allocator(), "legacy:x:500:500::/home/legacy:/bin/sh\n", "# UID_MIN 1000\nUID_MIN 500\n");
    try std.testing.expectEqual(@as(usize, 1), custom.len);
}
