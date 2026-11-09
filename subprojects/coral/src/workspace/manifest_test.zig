const std = @import("std");
const m = @import("manifest.zig");
const a = std.testing.allocator;

test "manifest owns UTF-8 strings and accepts only version one and empty settings" {
    const input = try a.dupe(u8,
        \\{"version":1,"roots":[{"name":"café","path":"../src"},{"path":"/tmp/二"}],"settings":{}}
    );
    defer a.free(input);
    var parsed = try m.parse(a, input);
    defer parsed.deinit();
    @memset(input, 'x');
    try std.testing.expectEqual(@as(usize, 2), parsed.roots.len);
    try std.testing.expectEqualStrings("café", parsed.roots[0].name.?);
    try std.testing.expectEqualStrings("../src", parsed.roots[0].path);
    try std.testing.expectEqualStrings("/tmp/二", parsed.roots[1].path);
    try std.testing.expect(parsed.roots[1].name == null);
    var empty = try m.parse(a, "{\"roots\":[],\"version\":1}");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.roots.len);
}

test "manifest strict schema rejects unknown keys and trust or executable configuration" {
    for ([_][]const u8{
        \\{"version":1,"roots":[],"future":0}
        ,
        \\{"version":1,"roots":[],"trust":"trusted"}
        ,
        \\{"version":1,"roots":[],"tasks":[]}
        ,
        \\{"version":1,"roots":[{"path":".","trusted":true}]}
        ,
        \\{"version":1,"roots":[{"path":".","future":{}}]}
        ,
    }) |bytes| try std.testing.expectError(error.UnknownField, m.parse(a, bytes));
    for ([_][]const u8{
        \\{"version":1,"roots":[],"settings":{"trust":"trusted"}}
        ,
        \\{"version":1,"roots":[],"settings":{"command":"touch /tmp/no"}}
        ,
        \\{"version":1,"roots":[],"settings":{"editor.tabSize":4}}
        ,
        \\{"version":1,"roots":[],"settings":{"tasks":[]}}
        ,
    }) |bytes| try std.testing.expectError(error.UnsupportedSettings, m.parse(a, bytes));
    for ([_][]const u8{
        \\{"version":2,"roots":[]}
        ,
        \\{"version":1.0,"roots":[]}
        ,
        \\{"version":1e0,"roots":[]}
        ,
        \\{"version":-1,"roots":[]}
        ,
    }) |bytes| try std.testing.expectError(error.UnsupportedVersion, m.parse(a, bytes));
}

test "manifest rejects duplicate keys including escaped names at every schema level" {
    for ([_][]const u8{
        \\{"version":1,"version":1,"roots":[]}
        ,
        \\{"version":1,"roots":[],"roots":[]}
        ,
        \\{"version":1,"roots":[],"settings":{},"settings":{}}
        ,
        \\{"version":1,"roots":[{"path":".","p\u0061th":".."}]}
        ,
        \\{"version":1,"roots":[{"path":".","name":"one","name":"two"}]}
        ,
    }) |bytes| try std.testing.expectError(error.DuplicateField, m.parse(a, bytes));
    // No settings member is supported, so even its first occurrence fails closed.
    try std.testing.expectError(error.UnsupportedSettings, m.parse(a,
        \\{"version":1,"roots":[],"settings":{"trust":false,"trust":true}}
    ));
}

test "manifest rejects malformed shapes nulls trailing data and missing fields" {
    for ([_][]const u8{
        "", "[]", "{}", "null", "{\"version\":1}",
        \\{"version":"1","roots":[]}
        ,
        \\{"version":1,"roots":null}
        ,
        \\{"version":1,"roots":[{}]}
        ,
        \\{"version":1,"roots":["."]}
        ,
        \\{"version":1,"roots":[{"path":null}]}
        ,
        \\{"version":1,"roots":[{"path":".","name":null}]}
        ,
        \\{"version":1,"roots":[],"settings":null}
        ,
        \\{"version":1,"roots":[],"settings":[]}
        ,
        \\{"version":1,"roots":[]} {}
        ,
        \\{"version":1,"roots":[],}
        ,
    }) |bytes| try std.testing.expectError(error.InvalidSchema, m.parse(a, bytes));
}

test "manifest enforces UTF-8 NUL empty string and decoded field bounds" {
    try std.testing.expectError(error.InvalidUtf8, m.parse(a, "\xff"));
    try std.testing.expectError(error.EmbeddedNul, m.parse(a, "\x00"));
    try std.testing.expectError(error.EmbeddedNul, m.parse(a,
        \\{"version":1,"roots":[{"path":"foo\u0000bar"}]}
    ));
    try std.testing.expectError(error.EmbeddedNul, m.parse(a,
        \\{"version":1,"roots":[{"path":".","name":"foo\u0000bar"}]}
    ));
    for ([_][]const u8{
        \\{"version":1,"roots":[{"path":""}]}
        ,
        \\{"version":1,"roots":[{"path":".","name":""}]}
        ,
    }) |bytes| try std.testing.expectError(error.EmptyString, m.parse(a, bytes));
    inline for (.{ .{ "path", m.limits.path_bytes }, .{ "name", m.limits.name_bytes } }) |entry| {
        const value = try a.alloc(u8, entry[1] + 1);
        defer a.free(value);
        @memset(value, 'x');
        const prefix = if (std.mem.eql(u8, entry[0], "name")) "\"path\":\".\"," else "";
        const bytes = try std.fmt.allocPrint(a, "{{\"version\":1,\"roots\":[{{{s}\"{s}\":\"{s}\"}}]}}", .{ prefix, entry[0], value });
        defer a.free(bytes);
        try std.testing.expectError(error.TooLarge, m.parse(a, bytes));
    }
}

test "manifest caps bytes and root count before unbounded collection allocation" {
    const bytes = try a.alloc(u8, m.limits.manifest_bytes + 1);
    defer a.free(bytes);
    @memset(bytes, ' ');
    const small = "{\"version\":1,\"roots\":[]}";
    @memcpy(bytes[0..small.len], small);
    var at_limit = try m.parse(a, bytes[0..m.limits.manifest_bytes]);
    at_limit.deinit();
    try std.testing.expectError(error.TooLarge, m.parse(a, bytes));
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(a);
    try list.appendSlice(a, "{\"version\":1,\"roots\":[");
    for (0..m.limits.roots) |i| {
        if (i != 0) try list.append(a, ',');
        try list.appendSlice(a, "{\"path\":\".\"}");
    }
    const end = list.items.len;
    try list.appendSlice(a, "]}");
    var full = try m.parse(a, list.items);
    defer full.deinit();
    try std.testing.expectEqual(m.limits.roots, full.roots.len);
    list.shrinkRetainingCapacity(end);
    try list.appendSlice(a, ",{\"path\":\".\"}]}");
    try std.testing.expectError(error.TooLarge, m.parse(a, list.items));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var parsed = try m.parse(allocator,
        \\{"version":1,"roots":[{"name":"caf\u00e9","path":"../src"},{"path":"/tmp/other"}],"settings":{}}
    );
    defer parsed.deinit();
}

test "manifest cleans up every caller allocation failure" {
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{});
}
