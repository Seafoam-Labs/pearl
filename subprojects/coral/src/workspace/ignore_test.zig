const std = @import("std");
const ig = @import("ignore.zig");
const a = std.testing.allocator;

test "wildmatch slash boundaries globstar anchors brackets escapes and native Unicode bytes" {
    const Case = struct { pattern: []const u8, path: []const u8, yes: bool };
    for ([_]Case{
        .{ .pattern = "*.zig", .path = "one.zig", .yes = true },
        .{ .pattern = "*.zig", .path = "a/one.zig", .yes = false },
        .{ .pattern = "**/x", .path = "x", .yes = true },
        .{ .pattern = "**/x", .path = "a/b/x", .yes = true },
        .{ .pattern = "**/x", .path = "abx", .yes = false },
        .{ .pattern = "**/x", .path = "a/bx", .yes = false },
        .{ .pattern = "a/**/b", .path = "a/b", .yes = true },
        .{ .pattern = "a/**/b", .path = "a/x/y/b", .yes = true },
        .{ .pattern = "a/**", .path = "a/b/c", .yes = true },
        .{ .pattern = "a/**", .path = "a", .yes = false },
        .{ .pattern = "ab**cd", .path = "ab/x/cd", .yes = false },
        .{ .pattern = "x[!a-c]?", .path = "xz1", .yes = true },
        .{ .pattern = "x[a-c]?", .path = "xb1", .yes = true },
        .{ .pattern = "x[a-c]?", .path = "xz1", .yes = false },
        .{ .pattern = "[]a]", .path = "]", .yes = true },
        .{ .pattern = "\\*literal", .path = "*literal", .yes = true },
        .{ .pattern = "[abc", .path = "[abc", .yes = false },
        .{ .pattern = "二/**/café.*", .path = "二/café.zig", .yes = true },
        .{ .pattern = "?", .path = "é", .yes = false },
        .{ .pattern = "??", .path = "é", .yes = true },
        .{ .pattern = "**/**/x", .path = "a/b/x", .yes = true },
        .{ .pattern = "[[:digit:]][[:alpha:]]", .path = "4z", .yes = true },
        .{ .pattern = "[![:digit:]]", .path = "z", .yes = true },
        .{ .pattern = "[![:digit:]]", .path = "4", .yes = false },
        .{ .pattern = "[[:space:]]", .path = "\t", .yes = true },
        .{ .pattern = "[[:xdigit:]]", .path = "F", .yes = true },
        .{ .pattern = "[a\\-c]", .path = "-", .yes = true },
        .{ .pattern = "a/**/b/**/c", .path = "a/b/c", .yes = true },
        .{ .pattern = "a/**/b/**/c", .path = "a/xb/c", .yes = false },
    }) |case| {
        const actual = try ig.match(case.pattern, case.path);
        if (actual != case.yes) std.debug.print("pattern {s} path {s}\n", .{ case.pattern, case.path });
        try std.testing.expectEqual(case.yes, actual);
    }
}

test "ignore parsing precedence scope directory-only anchors comments and whitespace" {
    var rules = ig.Rules{ .allocator = a };
    defer rules.deinit();
    try rules.append("", "\xef\xbb\xbf# comment\n*.log\n!important.log\n/root\ncache/\n\\#literal\n\\!literal\ntrimmed   \nspace\\ \n leading\ncrlf\r\n");
    try std.testing.expect(try rules.ignored("a/x.log", false));
    try std.testing.expect(!try rules.ignored("a/important.log", false));
    try std.testing.expect(try rules.ignored("root", false));
    try std.testing.expect(!try rules.ignored("a/root", false));
    try std.testing.expect(try rules.ignored("a/cache", true));
    try std.testing.expect(!try rules.ignored("a/cache", false));
    for ([_][]const u8{ "#literal", "!literal", "trimmed", "space ", " leading", "crlf" }) |path| try std.testing.expect(try rules.ignored(path, false));
    try std.testing.expect(!try rules.ignored("space", false));
    try rules.append("a", "!*.log\nimportant.log\n/local\n");
    try std.testing.expect(!try rules.ignored("a/x.log", false));
    try std.testing.expect(try rules.ignored("a/important.log", false));
    try std.testing.expect(try rules.ignored("b/x.log", false));
    try std.testing.expect(try rules.ignored("a/local", false));
    try std.testing.expect(!try rules.ignored("a/b/local", false));
}

test "explicit excludes are root relative final patterns not gitignore lines" {
    try std.testing.expect(try ig.excluded(&.{"out/**"}, "out/file", false));
    try std.testing.expect(!try ig.excluded(&.{"out/**"}, "sub/out/file", false));
    try std.testing.expect(try ig.excluded(&.{"**/out/"}, "sub/out", true));
    try std.testing.expect(!try ig.excluded(&.{"**/out/"}, "sub/out", false));
    for ([_][]const u8{ "", "!keep", "../escape", "a/../b", "a//b", "/", "a\n" }) |p| try std.testing.expectError(error.InvalidSchema, ig.validateExclude(p));
}

test "ignore limits and adversarial wildcards stay bounded" {
    var rules = ig.Rules{ .allocator = a };
    defer rules.deinit();
    const long: [ig.limits.pattern_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.IgnoreTooLarge, rules.append("", &long));
    try std.testing.expectError(error.InvalidIgnore, rules.append("", "a\x00b"));
    var pattern: [401]u8 = undefined;
    for (0..200) |i| {
        pattern[i * 2] = '*';
        pattern[i * 2 + 1] = 'a';
    }
    pattern[400] = 'z';
    const path: [1000]u8 = @splat('a');
    try std.testing.expect(!try ig.match(&pattern, &path));
}

test "rule count total storage and matching work have hard limits" {
    var rules = ig.Rules{ .allocator = a };
    defer rules.deinit();
    for (0..ig.limits.rules) |_| try rules.append("", "x\n");
    try std.testing.expectError(error.IgnoreTooLarge, rules.append("", "overflow\n"));
    var total = ig.Rules{ .allocator = a };
    defer total.deinit();
    const comment: [ig.limits.file_bytes]u8 = @splat('#');
    for (0..ig.limits.total_bytes / ig.limits.file_bytes) |_| try total.append("", &comment);
    try std.testing.expectError(error.IgnoreTooLarge, total.append("", "x"));
    var expensive = ig.Rules{ .allocator = a };
    defer expensive.deinit();
    const long: [ig.limits.pattern_bytes]u8 = @splat('?');
    for (0..10) |_| try expensive.append("", &long);
    const path: [4095]u8 = @splat('a');
    try std.testing.expectError(error.MatchBudgetExceeded, expensive.ignored(&path, false));
}

test "shared budget spans excludes rules and successive filenames" {
    var rules = ig.Rules{ .allocator = a };
    defer rules.deinit();
    try rules.append("", "*\n");
    var budget = ig.Budget{ .remaining = 20, .kind = .page };
    try budget.beginPath();
    try std.testing.expect(!try ig.excludedBudget(&.{"no"}, "abc", false, &budget));
    const after_excludes = budget.remaining;
    try std.testing.expect(try rules.ignoredBudget("abc", false, &budget));
    try std.testing.expect(budget.remaining < after_excludes);
    const before = budget.remaining;
    try budget.beginPath();
    try std.testing.expectEqual(before, budget.remaining);
    try std.testing.expectError(error.PageBudgetExceeded, rules.ignoredBudget("abc", false, &budget));
    var policy = ig.Budget{ .remaining = 1, .kind = .policy };
    try std.testing.expectError(error.PolicyBudgetExceeded, rules.ignoredBudget("abc", false, &policy));
}

const CancelAfter = struct {
    polls: usize = 0,
    stop: usize,
    fn cancelled(context: *anyopaque) bool {
        const self: *CancelAfter = @ptrCast(@alignCast(context));
        self.polls += 1;
        return self.polls == self.stop;
    }
    fn cancellation(self: *CancelAfter) ig.Cancellation {
        return .{ .context = self, .is_cancelled = cancelled };
    }
};

test "cancellation interrupts a single expensive match and bounded parsing" {
    var stop = CancelAfter{ .stop = 3 };
    var budget = ig.Budget{ .kind = .page, .cancellation = stop.cancellation() };
    var pattern: [ig.limits.pattern_bytes]u8 = @splat('?');
    pattern[0] = '*';
    const path: [128]u8 = @splat('a');
    try std.testing.expectError(error.Cancelled, ig.matchBudget(&pattern, &path, &budget));
    try std.testing.expectEqual(@as(usize, 3), stop.polls);
    try std.testing.expectEqual(@as(usize, 2 * ig.limits.cancel_steps), ig.limits.page_match_steps - budget.remaining);
    stop = .{ .stop = 3 };
    var rules = ig.Rules{ .allocator = a };
    defer rules.deinit();
    try std.testing.expectError(error.Cancelled, rules.appendCancellable("", "a\nb\nc\n", stop.cancellation()));
    try std.testing.expectEqual(@as(usize, 1), rules.items.items.len);
}

test "reverse evaluation is exactly last matching rule including scopes and negation" {
    var rules = ig.Rules{ .allocator = a };
    defer rules.deinit();
    try rules.append("", "*\n!keep\nkeep\n!keep\n");
    try rules.append("other", "keep\n");
    try std.testing.expect(!try rules.ignored("keep", false));
    try std.testing.expect(try rules.ignored("other/keep", false));
    try rules.append("", "keep/\n");
    try std.testing.expect(!try rules.ignored("keep", false));
    try std.testing.expect(try rules.ignored("keep", true));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var rules = ig.Rules{ .allocator = allocator };
    defer rules.deinit();
    try rules.append("nested", "*.log\n!keep.log\n");
}
test "ignore parser allocation failures release ownership" {
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{});
}
