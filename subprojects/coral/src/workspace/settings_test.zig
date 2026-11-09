const std = @import("std");
const s = @import("settings.zig");
const fs = @import("settings_fs.zig");
const Fixture = @import("manifest_test_support.zig").Fixture;
const a = std.testing.allocator;

const document =
    \\{"version":1,"settings":{"lines":false,"indent":2,"languages":{"c":{"wrap":false},"z\u0069g":{"spaces":false,"indent":8}}}}
;

test "settings parser owns decoded language IDs and clone is independent" {
    const input = try a.dupe(u8, document);
    defer a.free(input);
    var config = try s.parse(a, input);
    defer config.deinit(a);
    @memset(input, 'x');
    try std.testing.expectEqual(false, config.general.lines.?);
    try std.testing.expectEqual(@as(u8, 2), config.general.indent.?);
    try std.testing.expectEqualStrings("zig", config.languages[1].id);
    var clone = try config.clone(a);
    defer clone.deinit(a);
    try std.testing.expect(clone.languages[1].id.ptr != config.languages[1].id.ptr);
    try std.testing.expectEqual(@as(u8, 8), clone.forLanguage("zig").indent.?);
}

test "safe resolution uses actual presence including explicit defaults and every origin" {
    const defaults = s.resolve(.{ .lines = false, .indent = 8 }, .{}, .{}, .{}, .{});
    try std.testing.expectEqual(s.Baseline{}, defaults.values);
    try std.testing.expectEqual(s.Origins{}, defaults.origins);
    const user = s.resolve(.{}, .{ .lines = true, .indent = true }, .{}, .{}, .{});
    try std.testing.expectEqual(s.Origin.user, user.origins.lines);
    try std.testing.expectEqual(s.Origin.user, user.origins.indent);
    try std.testing.expectEqual(s.Origin.default, user.origins.wrap);
    const workspace: s.Config = .{
        .general = .{ .lines = false, .wrap = false, .indent = 2 },
        .languages = &.{.{ .id = "zig", .patch = .{ .wrap = true, .spaces = false, .indent = 6 } }},
    };
    const folder: s.Config = .{
        .general = .{ .spaces = true, .indent = 3 },
        .languages = &.{.{ .id = "zig", .patch = .{ .indent = 8 } }},
    };
    const general = s.resolve(.{}, .{ .lines = true }, workspace, folder, .{});
    try std.testing.expectEqual(s.Origin.workspace, general.origins.lines);
    try std.testing.expectEqual(s.Origin.folder, general.origins.indent);
    const result = s.resolve(.{}, .{ .lines = true }, workspace, folder, .{ .root_path = "/root", .language = "zig" });
    try std.testing.expectEqual(s.Baseline{ .lines = false, .wrap = true, .spaces = false, .indent = 8 }, result.values);
    try std.testing.expectEqual(s.Origins{ .lines = .workspace, .wrap = .workspace_language, .spaces = .workspace_language, .indent = .folder_language }, result.origins);
    try std.testing.expectEqualStrings("/root", result.context.root_path.?);
    try std.testing.expectEqualStrings("zig", result.context.language.?);
    const unknown = s.resolve(.{}, .{}, workspace, folder, .{ .language = "Zig" });
    try std.testing.expectEqual(general.values, unknown.values);
}

test "settings rejects malformed null noninteger unknown executable and nested languages" {
    for ([_][]const u8{
        "", "{}", "[]", "null", "{\"version\":1}",
        \\{"version":1,"settings":null}
        ,
        \\{"version":1,"settings":{"wrap":null}}
        ,
        \\{"version":1,"settings":{"lines":1}}
        ,
        \\{"version":1,"settings":{"spaces":"false"}}
        ,
        \\{"version":1,"settings":{"indent":0}}
        ,
        \\{"version":1,"settings":{"indent":9}}
        ,
        \\{"version":1,"settings":{"indent":-1}}
        ,
        \\{"version":1,"settings":{"indent":4.0}}
        ,
        \\{"version":1,"settings":{"indent":4e0}}
        ,
        \\{"version":1,"settings":{"indent":"4"}}
        ,
        \\{"version":1,"settings":{"languages":[]}}
        ,
        \\{"version":1,"settings":{"languages":{"zig":null}}}
        ,
        \\{"version":1,"settings":{"languages":{"zig":{"lines":null}}}}
        ,
        \\{"version":1,"settings":{}} {}
        ,
        \\{"version":1,"settings":{},}
        ,
        \\{"version":1,"settings":{"languages":{"../zig":{}}}}
        ,
    }) |input| try std.testing.expectError(error.InvalidSchema, s.parse(a, input));
    for ([_][]const u8{ "theme", "font", "dictionary", "spelling", "trust", "command", "tasks", "unknown" }) |key| {
        const input = try std.fmt.allocPrint(a, "{{\"version\":1,\"settings\":{{\"{s}\":false}}}}", .{key});
        defer a.free(input);
        try std.testing.expectError(error.UnsupportedSettings, s.parse(a, input));
        const nested = try std.fmt.allocPrint(a, "{{\"version\":1,\"settings\":{{\"languages\":{{\"zig\":{{\"{s}\":false}}}}}}}}", .{key});
        defer a.free(nested);
        try std.testing.expectError(error.UnsupportedSettings, s.parse(a, nested));
    }
    try std.testing.expectError(error.UnsupportedSettings, s.parse(a,
        \\{"version":1,"settings":{"languages":{"zig":{"languages":{}}}}}
    ));
    try std.testing.expectError(error.UnknownField, s.parse(a, "{\"version\":1,\"settings\":{},\"trust\":true}"));
    try std.testing.expectError(error.UnsupportedVersion, s.parse(a, "{\"version\":1.0,\"settings\":{}}"));
    try std.testing.expectError(error.InvalidUtf8, s.parse(a, "\xff"));
    try std.testing.expectError(error.EmbeddedNul, s.parse(a, "\x00"));
    try std.testing.expectError(error.EmbeddedNul, s.parse(a,
        \\{"version":1,"settings":{"languages":{"z\u0000ig":{}}}}
    ));
    try std.testing.expectError(error.EmptyString, s.parse(a,
        \\{"version":1,"settings":{"languages":{"":{}}}}
    ));
}

test "settings detects escaped duplicates at every schema level" {
    for ([_][]const u8{
        \\{"version":1,"vers\u0069on":1,"settings":{}}
        ,
        \\{"version":1,"settings":{},"sett\u0069ngs":{}}
        ,
        \\{"version":1,"settings":{"lines":true,"l\u0069nes":false}}
        ,
        \\{"version":1,"settings":{"languages":{},"langu\u0061ges":{}}}
        ,
        \\{"version":1,"settings":{"languages":{"zig":{},"z\u0069g":{}}}}
        ,
        \\{"version":1,"settings":{"languages":{"zig":{"indent":2,"ind\u0065nt":3}}}}
        ,
    }) |input| try std.testing.expectError(error.DuplicateField, s.parse(a, input));
}

test "settings source language count and ID bounds are explicit" {
    const bytes = try a.alloc(u8, s.limits.source_bytes + 1);
    defer a.free(bytes);
    @memset(bytes, ' ');
    @memcpy(bytes[0..document.len], document);
    var full = try s.parse(a, bytes[0..s.limits.source_bytes]);
    full.deinit(a);
    try std.testing.expectError(error.TooLarge, s.parse(a, bytes));
    const id: [65]u8 = @splat('x');
    for ([_]usize{ 64, 65 }) |length| {
        const input = try std.fmt.allocPrint(a, "{{\"version\":1,\"settings\":{{\"languages\":{{\"{s}\":{{}}}}}}}}", .{id[0..length]});
        defer a.free(input);
        if (length == 65) {
            try std.testing.expectError(error.TooLarge, s.parse(a, input));
        } else {
            var config = try s.parse(a, input);
            config.deinit(a);
        }
    }
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try json.appendSlice(a, "{\"version\":1,\"settings\":{\"languages\":{");
    for (0..32) |i| {
        const entry = try std.fmt.allocPrint(a, "{s}\"lang{d}\":{{}}", .{ if (i == 0) "" else ",", i });
        defer a.free(entry);
        try json.appendSlice(a, entry);
    }
    const end = json.items.len;
    try json.appendSlice(a, "}}}");
    var config = try s.parse(a, json.items);
    defer config.deinit(a);
    try std.testing.expectEqual(@as(usize, 32), config.languages.len);
    json.shrinkRetainingCapacity(end);
    try json.appendSlice(a, ",\"overflow\":{}}}}");
    try std.testing.expectError(error.TooLarge, s.parse(a, json.items));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var config = try s.parse(allocator, document);
    defer config.deinit(allocator);
    var clone = try config.clone(allocator);
    defer clone.deinit(allocator);
}
test "settings parse and clone clean up all allocation failures" {
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{});
}

fn loadAllocationCase(allocator: std.mem.Allocator, root: []const u8) !void {
    var config = try fs.load(allocator, root);
    defer config.deinit(allocator);
}
test "folder settings missing is empty and normal read is owned and allocation safe" {
    var f = try Fixture.init();
    defer f.deinit();
    var absent = try fs.load(a, f.base);
    absent.deinit(a);
    try f.mkdir(".coral");
    var missing = try fs.load(a, f.base);
    missing.deinit(a);
    try f.write(".coral/settings.json", document);
    var config = try fs.load(a, f.base);
    defer config.deinit(a);
    try std.testing.expectEqual(@as(u8, 8), config.forLanguage("zig").indent.?);
    try std.testing.checkAllAllocationFailures(a, loadAllocationCase, .{f.base});
}

test "folder settings rejects symlink directory components and root aliases" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("real");
    try f.symlink("real", ".coral");
    try std.testing.expectError(error.NotDirectory, fs.load(a, f.base));
    try f.symlink("real", "alias");
    const alias = try f.path("alias");
    defer a.free(alias);
    try std.testing.expectError(error.NotDirectory, fs.load(a, alias));
    const descendant = try f.path("alias/child");
    defer a.free(descendant);
    try std.testing.expectError(error.NotDirectory, fs.load(a, descendant));
}

test "folder settings rejects symlink files including dangling and special files without hangs" {
    for (0..5) |kind| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.mkdir(".coral");
        switch (kind) {
            0 => {
                try f.write("target", document);
                try f.symlink("../target", ".coral/settings.json");
            },
            1 => try f.symlink("absent", ".coral/settings.json"),
            2 => try f.fifo(".coral/settings.json"),
            3 => try f.mkdir(".coral/settings.json"),
            4 => try f.symlink("/dev/null", ".coral/settings.json"),
            else => unreachable,
        }
        try std.testing.expectError(if (kind == 0 or kind == 1 or kind == 4) error.SymlinkLoop else error.NotRegularFile, fs.load(a, f.base));
    }
    var f = try Fixture.init();
    defer f.deinit();
    try f.fifo(".coral");
    try std.testing.expectError(error.NotDirectory, fs.load(a, f.base));
}

test "folder settings traverses execute-only ancestors and config directory but requires readable leaf" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("ancestor");
    try f.mkdir("ancestor/root");
    try f.mkdir("ancestor/root/.coral");
    try f.write("ancestor/root/.coral/settings.json", document);
    const ancestor = try f.path("ancestor");
    defer a.free(ancestor);
    const root = try f.path("ancestor/root");
    defer a.free(root);
    const directory = try f.path("ancestor/root/.coral");
    defer a.free(directory);
    const leaf = try f.path("ancestor/root/.coral/settings.json");
    defer a.free(leaf);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(ancestor, 0o100));
    defer std.debug.assert(std.c.chmod(ancestor, 0o700) == 0);
    var config = try fs.load(a, root);
    defer config.deinit(a);
    try std.testing.expectEqual(@as(u8, 2), config.general.indent.?);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(directory, 0o100));
    defer std.debug.assert(std.c.chmod(directory, 0o700) == 0);
    var search_only = try fs.load(a, root);
    defer search_only.deinit(a);
    try std.testing.expectEqual(@as(u8, 8), search_only.forLanguage("zig").indent.?);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(leaf, 0));
    defer std.debug.assert(std.c.chmod(leaf, 0o600) == 0);
    try std.testing.expectError(error.PermissionDenied, fs.load(a, root));
}

test "folder settings unsearchable configuration directory fails closed" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir(".coral");
    const path = try f.path(".coral");
    defer a.free(path);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path, 0));
    defer std.debug.assert(std.c.chmod(path, 0o700) == 0);
    try std.testing.expectError(error.PermissionDenied, fs.load(a, f.base));
}

test "folder settings malformed oversized and unreadable fail closed" {
    for (0..3) |kind| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.mkdir(".coral");
        const large = try a.alloc(u8, s.limits.source_bytes + 1);
        defer a.free(large);
        @memset(large, ' ');
        try f.write(".coral/settings.json", if (kind == 0) "bad" else if (kind == 1) large else document);
        if (kind == 2) {
            if (std.c.geteuid() == 0) continue;
            const path = try f.path(".coral/settings.json");
            defer a.free(path);
            try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path, 0));
        }
        try std.testing.expectError(switch (kind) {
            0 => error.InvalidSchema,
            1 => error.TooLarge,
            else => error.PermissionDenied,
        }, fs.load(a, f.base));
    }
}
