const std = @import("std");
const api = @import("status.zig");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const oid = "0123456789abcdef0123456789abcdef01234567";
const oid256 = "0123456789abcdef" ++ "0123456789abcdef" ++ "0123456789abcdef" ++ "0123456789abcdef";
const ordinary = "1 MM N... 100644 100644 100644 " ++ oid ++ " " ++ oid ++ " ";
const rename = "2 R. N... 100644 100644 100644 " ++ oid ++ " " ++ oid ++ " R100 ";
const conflict = "u UU N... 100644 100644 100644 100644 " ++ oid ++ " " ++ oid ++ " " ++ oid ++ " ";

test "empty snapshot and absent branch metadata" {
    var s = try api.parse(a, "");
    defer s.deinit();
    try equal(@as(usize, 0), s.entries.len);
    try expect(s.head == null and s.branch == null and s.upstream == null);
    try equal(@as(usize, 0), s.ahead);
    try equal(@as(usize, 0), s.behind);
}

test "all record kinds and independent index/worktree states" {
    var s = try api.parse(a, "# branch.oid " ++ oid ++ "\x00# branch.head topic\x00# branch.upstream origin/topic\x00# branch.ab +12 -3\x00" ++
        ordinary ++ "both\x00" ++
        "1 .M S.MU 160000 160000 160000 " ++ oid ++ " " ++ oid ++ " sub\x00" ++
        rename ++ "new\x00old\x00" ++
        conflict ++ "conflict\x00? untracked\x00! ignored/\x00");
    defer s.deinit();
    try strings(oid, s.head.?);
    try strings("topic", s.branch.?);
    try strings("origin/topic", s.upstream.?);
    try equal(@as(usize, 12), s.ahead);
    try equal(@as(usize, 3), s.behind);
    try equal(@as(usize, 6), s.entries.len);
    const both = s.entries[0];
    try equal(.ordinary, both.kind);
    try equal(@as(u8, 'M'), both.index);
    try equal(@as(u8, 'M'), both.worktree);
    try expect(!both.submodule and both.original_path == null);
    try equal(@as(u8, '.'), s.entries[1].index);
    try equal(@as(u8, 'M'), s.entries[1].worktree);
    try expect(s.entries[1].submodule);
    try equal(.rename, s.entries[2].kind);
    try strings("new", s.entries[2].path);
    try strings("old", s.entries[2].original_path.?);
    try equal(.unmerged, s.entries[3].kind);
    try equal(@as(u8, 'U'), s.entries[3].index);
    try equal(@as(u8, 'U'), s.entries[3].worktree);
    try equal(.untracked, s.entries[4].kind);
    try equal(@as(u8, '?'), s.entries[4].index);
    try equal(@as(u8, '?'), s.entries[4].worktree);
    try equal(.ignored, s.entries[5].kind);
    try equal(@as(u8, '!'), s.entries[5].index);
    try equal(@as(u8, '!'), s.entries[5].worktree);
    try strings("ignored/", s.entries[5].path);
}

test "unborn detached SHA256 and optional header order" {
    var unborn = try api.parse(a, "# branch.head main\x00# branch.oid (initial)\x00");
    defer unborn.deinit();
    try strings("(initial)", unborn.head.?);
    try strings("main", unborn.branch.?);
    var detached = try api.parse(a, "# branch.ab +0 -0\x00# branch.head (detached)\x00# branch.oid " ++ oid256 ++ "\x00" ++
        "1 A. N... 000000 100644 100644 " ++ oid256 ++ " " ++ oid256 ++ " added\x00");
    defer detached.deinit();
    try strings("(detached)", detached.branch.?);
    try strings(oid256, detached.head.?);
    try equal(@as(u8, 'A'), detached.entries[0].index);
}

test "paths retain whitespace newlines backslashes leading dashes and UTF8" {
    const path = " -dash/ \t\n\r café 日本語 😀 \\";
    var s = try api.parse(a, ordinary ++ path ++ "\x00" ++ rename ++ path ++ "\x00? old\n\t \x00? --help\x00?   \x00? a..b/.../file\x00");
    defer s.deinit();
    try strings(path, s.entries[0].path);
    try strings(path, s.entries[1].path);
    try strings("? old\n\t ", s.entries[1].original_path.?);
    try strings("--help", s.entries[2].path);
    try strings("  ", s.entries[3].path);
    try strings("a..b/.../file", s.entries[4].path);
}

test "rename original is exactly one additional NUL record even if it resembles a header" {
    var s = try api.parse(a, rename ++ "new\x00# branch.head fake\x00? next\x00");
    defer s.deinit();
    try equal(@as(usize, 2), s.entries.len);
    try expect(s.branch == null);
    try strings("# branch.head fake", s.entries[0].original_path.?);
    try strings("next", s.entries[1].path);
}

test "copy and worktree rename scores" {
    var s = try api.parse(a, "2 C. N... 100644 100644 100644 " ++ oid ++ " " ++ oid ++ " C075 copy\x00source\x00" ++
        "2 .R N... 100644 100644 100644 " ++ oid ++ " " ++ oid ++ " R0 moved\x00source\x00");
    defer s.deinit();
    try equal(.rename, s.entries[0].kind);
    try equal(@as(u8, 'C'), s.entries[0].index);
    try equal(@as(u8, 'R'), s.entries[1].worktree);
}

test "all conflict pairs and submodule indicators" {
    for ([_][]const u8{ "DD", "AU", "UD", "UA", "DU", "AA", "UU" }) |pair| {
        const input = try std.fmt.allocPrint(a, "u {s} SCMU 100644 100644 100644 100644 {s} {s} {s} p\x00", .{ pair, oid, oid, oid });
        defer a.free(input);
        var s = try api.parse(a, input);
        defer s.deinit();
        try equal(.unmerged, s.entries[0].kind);
        try expect(s.entries[0].submodule);
        try equal(pair[0], s.entries[0].index);
        try equal(pair[1], s.entries[0].worktree);
    }
    for ([_][]const u8{ "S...", "SC..", "S.M.", "S..U", "SCMU" }) |sub| {
        const input = try std.fmt.allocPrint(a, "1 .M {s} 160000 160000 160000 {s} {s} p\x00", .{ sub, oid, oid });
        defer a.free(input);
        var s = try api.parse(a, input);
        defer s.deinit();
        try expect(s.entries[0].submodule);
    }
}

test "snapshot owns every slice independently of input" {
    const input = try a.dupe(u8, "# branch.oid " ++ oid ++ "\x00# branch.head main\x00# branch.upstream origin/main\x00" ++ rename ++ "new\x00old\x00");
    var s = try api.parse(a, input);
    defer s.deinit();
    @memset(input, 'x');
    a.free(input);
    try strings(oid, s.head.?);
    try strings("main", s.branch.?);
    try strings("origin/main", s.upstream.?);
    try strings("new", s.entries[0].path);
    try strings("old", s.entries[0].original_path.?);
}

test "unknown headers are skipped but unknown record kinds fail closed" {
    var s = try api.parse(a, "# future.field anything\x00# future.flag\x00# branch.head main\x00? p\x00");
    defer s.deinit();
    try strings("main", s.branch.?);
    try equal(@as(usize, 1), s.entries.len);
    try expectError(error.UnknownRecord, api.parse(a, "3 whatever\x00"));
    try expectError(error.UnknownRecord, api.parse(a, "x whatever\x00"));
}

test "truncated records and missing rename originals" {
    for ([_][]const u8{ "? p", "# branch.head main", ordinary ++ "p", rename ++ "new\x00", rename ++ "new\x00old", "? p\x00? next" }) |input| {
        try expectError(error.TruncatedRecord, api.parse(a, input));
    }
    try expectError(error.InvalidPath, api.parse(a, rename ++ "new\x00\x00"));
    try expectError(error.InvalidRecord, api.parse(a, "\x00"));
    try expectError(error.InvalidRecord, api.parse(a, "? p\x00\x00"));
    // NUL is framing, never part of an entry path: trailing non-record bytes fail.
    try expectError(error.InvalidRecord, api.parse(a, "? p\x00suffix\x00"));
}

test "reject unsafe paths on both sides of a rename" {
    for ([_][]const u8{ "", "/absolute", "../escape", "a/../b", "..", ".", "a/./b", "a/..", "a/.", "a//b", "a//" }) |path| {
        const input = try std.fmt.allocPrint(a, "? {s}\x00", .{path});
        defer a.free(input);
        try expectError(error.InvalidPath, api.parse(a, input));
        const source = try std.fmt.allocPrint(a, rename ++ "new\x00{s}\x00", .{path});
        defer a.free(source);
        try expectError(error.InvalidPath, api.parse(a, source));
        const destination = try std.fmt.allocPrint(a, rename ++ "{s}\x00old\x00", .{path});
        defer a.free(destination);
        try expectError(error.InvalidPath, api.parse(a, destination));
    }
}

test "invalid UTF8 explicitly rejected in paths originals and headers" {
    for ([_][]const u8{ "? \xff\x00", "? \xc0\xaf\x00", "? \xed\xa0\x80\x00", rename ++ "new\x00\x80\x00", "# branch.head \xff\x00", "# future \xff\x00" }) |input| {
        try expectError(error.InvalidUtf8, api.parse(a, input));
    }
}

test "malformed fixed fields and scores" {
    for ([_][]const u8{
        "?\x00",                                                                       "?\tp\x00",                                                                  "1 \x00",                                                                       "1 MM\x00",                                                                     "1  MM N... p\x00",
        "1 M N... 100644 100644 100644 " ++ oid ++ " " ++ oid ++ " p\x00",             "1 .. N... 100644 100644 100644 " ++ oid ++ " " ++ oid ++ " p\x00",          "1 U. N... 100644 100644 100644 " ++ oid ++ " " ++ oid ++ " p\x00",             "1 MM N..U 100644 100644 100644 " ++ oid ++ " " ++ oid ++ " p\x00",             "1 MM S.X. 100644 100644 100644 " ++ oid ++ " " ++ oid ++ " p\x00",
        "1 MM N... 100648 100644 100644 " ++ oid ++ " " ++ oid ++ " p\x00",            "1 MM N... 644 100644 100644 " ++ oid ++ " " ++ oid ++ " p\x00",             "1 MM N... 100644 100644 100644 short " ++ oid ++ " p\x00",                     "1 MM N... 100644 100644 100644 " ++ oid ++ " " ++ oid256 ++ " p\x00",          "2 R. N... 100644 100644 100644 " ++ oid ++ " " ++ oid ++ " R101 p\x00old\x00",
        "2 R. N... 100644 100644 100644 " ++ oid ++ " " ++ oid ++ " R-1 p\x00old\x00", "2 R. N... 100644 100644 100644 " ++ oid ++ " " ++ oid ++ " R p\x00old\x00", "2 R. N... 100644 100644 100644 " ++ oid ++ " " ++ oid ++ " C100 p\x00old\x00", "2 M. N... 100644 100644 100644 " ++ oid ++ " " ++ oid ++ " R100 p\x00old\x00", "u MM N... 100644 100644 100644 100644 " ++ oid ++ " " ++ oid ++ " " ++ oid ++ " p\x00",
    }) |input| try expectError(error.InvalidRecord, api.parse(a, input));
}

test "malformed duplicate and overflowing branch headers" {
    for ([_][]const u8{
        "#\x00",                "# \x00",                                    "#branch.head main\x00",                     "#  value\x00",
        "# branch.head\x00",    "# branch.upstream \x00",                    "# branch.oid short\x00",                    "# branch.ab + -1\x00",
        "# branch.ab 1 -1\x00", "# branch.ab +1 +1\x00",                     "# branch.ab +1 -1 trailing\x00",            "# branch.ab +1  -1\x00",
        "# branch.ab +1 -\x00", "# branch.ab +184467440737095516160 -0\x00", "# branch.ab +0 -184467440737095516160\x00",
    }) |input| try expectError(error.InvalidHeader, api.parse(a, input));
    for ([_][]const u8{ "# branch.head main\x00", "# branch.oid (initial)\x00", "# branch.upstream origin/main\x00", "# branch.ab +0 -0\x00" }) |header| {
        const input = try std.mem.concat(a, u8, &.{ header, header });
        defer a.free(input);
        try expectError(error.DuplicateHeader, api.parse(a, input));
    }
}

test "inclusive path and header limits" {
    const path = try a.alloc(u8, api.max_path_bytes + 1);
    defer a.free(path);
    @memset(path, 'p');
    const at_limit = try std.mem.concat(a, u8, &.{ "? ", path[0..api.max_path_bytes], "\x00" });
    defer a.free(at_limit);
    var s = try api.parse(a, at_limit);
    defer s.deinit();
    try equal(@as(usize, api.max_path_bytes), s.entries[0].path.len);
    for ([_][]const u8{ "? ", rename ++ "new\x00" }) |prefix| {
        const input = try std.mem.concat(a, u8, &.{ prefix, path, "\x00" });
        defer a.free(input);
        try expectError(error.PathTooLong, api.parse(a, input));
    }
    const header = try a.alloc(u8, api.max_header_bytes + 1);
    defer a.free(header);
    @memset(header, 'h');
    const good = try std.mem.concat(a, u8, &.{ "# branch.head ", header[0..api.max_header_bytes], "\x00" });
    defer a.free(good);
    var h = try api.parse(a, good);
    defer h.deinit();
    try equal(@as(usize, api.max_header_bytes), h.branch.?.len);
    const bad = try std.mem.concat(a, u8, &.{ "# branch.head ", header, "\x00" });
    defer a.free(bad);
    try expectError(error.InvalidHeader, api.parse(a, bad));
}

test "inclusive entry and input bounds" {
    const records = try a.alloc(u8, (api.max_entries + 1) * 4);
    defer a.free(records);
    for (0..api.max_entries + 1) |i| @memcpy(records[i * 4 ..][0..4], "? p\x00");
    var s = try api.parse(a, records[0 .. api.max_entries * 4]);
    defer s.deinit();
    try equal(@as(usize, api.max_entries), s.entries.len);
    try expectError(error.TooManyEntries, api.parse(a, records));
    const bytes = try a.alloc(u8, api.max_input_bytes + 1);
    defer a.free(bytes);
    // Unknown headers count against input, not entry capacity.
    for (0..api.max_input_bytes / 4) |i| @memcpy(bytes[i * 4 ..][0..4], "# x\x00");
    bytes[api.max_input_bytes] = 0;
    var at_limit = try api.parse(a, bytes[0..api.max_input_bytes]);
    defer at_limit.deinit();
    try expectError(error.InputTooLarge, api.parse(a, bytes));
}

test "display escapes controls bidi and backslashes but leaves original untouched" {
    const raw = "café/\n\t\r\x1b\x7f\u{85}\u{61c}\u{200e}\u{200f}\u{2028}\u{202e}\u{2066}\\";
    const label = try api.displayLabel(a, raw);
    defer a.free(label);
    try strings("café/\\u{a}\\u{9}\\u{d}\\u{1b}\\u{7f}\\u{85}\\u{61c}\\u{200e}\\u{200f}\\u{2028}\\u{202e}\\u{2066}\\\\", label);
    var s = try api.parse(a, "? " ++ raw ++ "\x00");
    defer s.deinit();
    try strings(raw, s.entries[0].path);
    try expectError(error.InvalidUtf8, api.displayLabel(a, "\xff"));
    const nul = try api.displayLabel(a, "\x00");
    defer a.free(nul);
    try strings("\\u{0}", nul);
}

fn allocationSuccess(allocator: std.mem.Allocator) !void {
    var s = try api.parse(allocator, "# branch.oid " ++ oid ++ "\x00# branch.head main\x00# branch.upstream origin/main\x00" ++ ordinary ++ "p\x00" ++ rename ++ "new\x00old\x00" ++ conflict ++ "conflict\x00? untracked\x00! ignored\x00");
    defer s.deinit();
    try equal(@as(usize, 5), s.entries.len);
    const label = try api.displayLabel(allocator, "path\n\u{202e}");
    defer allocator.free(label);
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    var s = api.parse(allocator, "# branch.head main\x00" ++ rename ++ "new\x00old\x00" ++ ordinary ++ "p\x00? ../bad\x00") catch |err| switch (err) {
        error.InvalidPath => return,
        else => return err,
    };
    defer s.deinit();
    return error.ExpectedRejection;
}

fn allocationGrowth(allocator: std.mem.Allocator) !void {
    var input: [512 * 4]u8 = undefined;
    for (0..512) |i| @memcpy(input[i * 4 ..][0..4], "? p\x00");
    var s = try api.parse(allocator, &input);
    defer s.deinit();
    try equal(@as(usize, 512), s.entries.len);
    const controls: [api.max_path_bytes]u8 = @splat('\n');
    const label = try api.displayLabel(allocator, &controls);
    defer allocator.free(label);
    try equal(@as(usize, api.max_path_bytes * 5), label.len);
}

test "all allocation failures clean up success growth and malformed input paths" {
    try std.testing.checkAllAllocationFailures(a, allocationSuccess, .{});
    try std.testing.checkAllAllocationFailures(a, allocationFailure, .{});
    try std.testing.checkAllAllocationFailures(a, allocationGrowth, .{});
}

test "every nonempty proper prefix of each record is truncated" {
    for ([_][]const u8{ ordinary ++ "file\x00", rename ++ "new\x00old\x00", conflict ++ "file\x00", "? file\x00", "! dir/\x00", "# branch.head main\x00" }) |input| {
        for (1..input.len) |end| {
            try expectError(error.TruncatedRecord, api.parse(a, input[0..end]));
        }
    }
}

test "single byte mutations never panic or leak" {
    const sample = "# branch.oid " ++ oid ++ "\x00# branch.head main\x00" ++ ordinary ++ "file\x00" ++ rename ++ "new\x00old\x00" ++ conflict ++ "file\x00? dir/\x00! ignored\x00";
    var input: [sample.len]u8 = undefined;
    for (0..sample.len) |position| {
        for ([_]u8{ 0, ' ', '.', '/', 0xff, '1', '2', 'u', '?', '!', '#', '\n' }) |byte| {
            @memcpy(&input, sample);
            input[position] = byte;
            var s = api.parse(a, &input) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            defer s.deinit();
            for (s.entries) |entry| {
                try expect(entry.path.len > 0 and entry.path.len <= api.max_path_bytes);
                try expect(std.unicode.utf8ValidateSlice(entry.path));
                try expect(std.mem.indexOfScalar(u8, entry.path, 0) == null);
            }
        }
    }
}

test "display label inclusive size bound" {
    const text: [api.max_path_bytes + 1]u8 = @splat('x');
    const label = try api.displayLabel(a, text[0..api.max_path_bytes]);
    defer a.free(label);
    try strings(text[0..api.max_path_bytes], label);
    try expectError(error.PathTooLong, api.displayLabel(a, &text));
}
