//! Headless task/matcher regressions: no GTK, display server, or application
//! shell. Matcher parsing and argv/cwd/env policy are pure; load() exercises a
//! disposable `.coral/tasks.json` under a temporary root. No host file is read or
//! written outside the temporary fixture, and no task is ever executed here.
const std = @import("std");
const task = @import("task.zig");
const matcher = @import("matcher.zig");
const a = std.testing.allocator;

// --- matcher -----------------------------------------------------------------

fn expectProblem(kind: matcher.Kind, line: []const u8, file: []const u8, line_no: u32, col: u32, severity: matcher.Severity, message: []const u8) !void {
    const p = matcher.matchLine(kind, line) orelse return error.NoMatch;
    try std.testing.expectEqualStrings(file, p.file);
    try std.testing.expectEqual(line_no, p.line);
    try std.testing.expectEqual(col, p.column);
    try std.testing.expectEqual(severity, p.severity);
    try std.testing.expectEqualStrings(message, p.message);
}

test "matcher parses zig/gcc/clang file:line:col diagnostics with severity" {
    try expectProblem(.zig, "/w/src/main.zig:12:5: error: expected ';' after statement", "/w/src/main.zig", 12, 5, .err, "expected ';' after statement");
    try expectProblem(.zig, "src/main.zig:3:1: note: referenced here", "src/main.zig", 3, 1, .note, "referenced here");
    try expectProblem(.gcc, "lib/a.c:40:9: warning: unused variable 'x' [-Wunused-variable]", "lib/a.c", 40, 9, .warning, "unused variable 'x' [-Wunused-variable]");
    try expectProblem(.clang, "lib/a.c:40:9: fatal error: 'missing.h' file not found", "lib/a.c", 40, 9, .err, "'missing.h' file not found");
    // Column-less form keeps column 0.
    try expectProblem(.gcc, "lib/a.c:40: error: something broke", "lib/a.c", 40, 0, .err, "something broke");
}

test "matcher generic form defaults to error and honors explicit severity" {
    try expectProblem(.generic, "tool/out.txt:7:2: just a message", "tool/out.txt", 7, 2, .err, "just a message");
    try expectProblem(.generic, "tool/out.txt:7:2: warning: be careful", "tool/out.txt", 7, 2, .warning, "be careful");
    try expectProblem(.generic, "tool/out.txt:7:2: info: FYI", "tool/out.txt", 7, 2, .info, "FYI");
}

test "matcher preserves paths containing other colons and rejects control bytes" {
    try expectProblem(.generic, "/odd:path/file.zig:9:1: error: boom", "/odd:path/file.zig", 9, 1, .err, "boom");
    try std.testing.expect(matcher.matchLine(.generic, "bad\x01name.zig:9:1: error: boom") == null);
    try std.testing.expect(matcher.matchLine(.generic, "no location here") == null);
    try std.testing.expect(matcher.matchLine(.generic, "file.zig:0: error: zero line") == null);
}

test "matcher parses python tracebacks and falls back to diagnostics" {
    try expectProblem(.python, "  File \"/w/app.py\", line 23, in <module>", "/w/app.py", 23, 0, .err, ", in <module>");
    try expectProblem(.python, "  File \"app.py\", line 4", "app.py", 4, 0, .err, "Python traceback");
    try expectProblem(.python, "app.py:10:1: error: tooling diagnostic", "app.py", 10, 1, .err, "tooling diagnostic");
    try std.testing.expect(matcher.matchLine(.python, "Traceback (most recent call last):") == null);
}

test "matcher parse bounds problem count and message bytes" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    for (0..matcher.limits.problems + 50) |i| {
        try buf.print(a, "f.zig:{d}:1: error: line {d}\n", .{ i + 1, i });
    }
    var problems = try matcher.parse(a, .zig, buf.items);
    defer problems.deinit();
    try std.testing.expectEqual(matcher.limits.problems, problems.items.len);
    try std.testing.expect(problems.truncated);

    const long_message = try a.alloc(u8, matcher.limits.message_bytes + 500);
    defer a.free(long_message);
    @memset(long_message, 'x');
    const line = try std.fmt.allocPrint(a, "f.zig:1:1: error: {s}", .{long_message});
    defer a.free(line);
    var bounded = try matcher.parse(a, .zig, line);
    defer bounded.deinit();
    try std.testing.expectEqual(@as(usize, 1), bounded.items.len);
    try std.testing.expect(bounded.items[0].message.len <= matcher.limits.message_bytes + 3);
}

test "matcher kind names round-trip and unknown names fail closed" {
    const info = @typeInfo(matcher.Kind).@"enum";
    inline for (info.field_names, info.field_values) |name, value| {
        const kind: matcher.Kind = @fromBackingInt(@intCast(value));
        try std.testing.expectEqualStrings(name, matcher.kindName(kind));
        try std.testing.expectEqual(kind, matcher.parseKind(name).?);
    }
    try std.testing.expect(matcher.parseKind("shell") == null);
    try std.testing.expect(matcher.parseKind("") == null);
}

// --- task policy -------------------------------------------------------------

const root = "/workspace/project";

fn parseOk(bytes: []const u8) !task.Definitions {
    return task.parse(a, bytes, root);
}

test "task parse accepts a versioned definition and resolves cwd inside the root" {
    var defs = try parseOk(
        \\{"version":1,"tasks":[{"name":"build","argv":["/usr/bin/zig","build"],"cwd":"src","env":{"PATH":"/usr/bin:/bin"},"matcher":"zig"}]}
    );
    defer defs.deinit();
    try std.testing.expectEqual(@as(usize, 1), defs.tasks.len);
    const t = defs.tasks[0];
    try std.testing.expectEqualStrings("build", t.name);
    try std.testing.expectEqualStrings("/usr/bin/zig", t.argv[0]);
    try std.testing.expectEqualStrings("/workspace/project/src", t.cwd);
    try std.testing.expectEqualStrings(root, t.root);
    try std.testing.expectEqual(matcher.Kind.zig, t.matcher.?);
    try std.testing.expectEqual(@as(usize, 1), t.env.len);
    try std.testing.expectEqualStrings("PATH", t.env[0].name);
}

test "task parse defaults cwd to the root and matcher to null" {
    var defs = try parseOk(
        \\{"version":1,"tasks":[{"name":"run","argv":["/usr/bin/true"]}]}
    );
    defer defs.deinit();
    try std.testing.expectEqualStrings(root, defs.tasks[0].cwd);
    try std.testing.expect(defs.tasks[0].matcher == null);
    try std.testing.expectEqual(@as(usize, 0), defs.tasks[0].env.len);
}

test "task parse rejects malformed or unsafe definitions" {
    const cases = [_]struct { bytes: []const u8, err: anyerror }{
        .{ .bytes = "{\"version\":2,\"tasks\":[]}", .err = error.UnsupportedTaskVersion },
        .{ .bytes = "{\"version\":1,\"tasks\":[],\"extra\":1}", .err = error.UnknownTaskField },
        .{ .bytes = "{\"version\":1,\"tasks\":[{\"name\":\"x\",\"argv\":[\"zig\"]}]}", .err = error.ExecutableMustBeAbsolute },
        .{ .bytes = "{\"version\":1,\"tasks\":[{\"name\":\"x\",\"argv\":[]}]}", .err = error.EmptyArgv },
        .{ .bytes = "{\"version\":1,\"tasks\":[{\"name\":\"x\",\"argv\":[\"/bin/true\"],\"cwd\":\"/etc\"}]}", .err = error.CwdMustBeRelative },
        .{ .bytes = "{\"version\":1,\"tasks\":[{\"name\":\"x\",\"argv\":[\"/bin/true\"],\"cwd\":\"../../etc\"}]}", .err = error.CwdOutsideWorkspace },
        .{ .bytes = "{\"version\":1,\"tasks\":[{\"name\":\"x\",\"argv\":[\"/bin/true\"],\"matcher\":\"shell\"}]}", .err = error.UnknownMatcher },
        .{ .bytes = "{\"version\":1,\"tasks\":[{\"name\":\"x\",\"argv\":[\"/bin/true\"],\"env\":{\"BAD=NAME\":\"v\"}}]}", .err = error.InvalidTaskEnvironment },
        .{ .bytes = "{\"version\":1,\"tasks\":[{\"name\":\"a\",\"argv\":[\"/bin/true\"]},{\"name\":\"a\",\"argv\":[\"/bin/true\"]}]}", .err = error.DuplicateTaskName },
        .{ .bytes = "{\"version\":1,\"tasks\":[{\"name\":\"x\",\"argv\":[\"/bin/true\"],\"shell\":\"no\"}]}", .err = error.UnknownTaskField },
    };
    for (cases) |case| {
        try std.testing.expectError(case.err, parseOk(case.bytes));
    }
}

test "task parse enforces the 64-task bound and rejects duplicate JSON keys" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "{\"version\":1,\"tasks\":[");
    for (0..task.limits.tasks + 1) |i| {
        if (i != 0) try buf.append(a, ',');
        try buf.print(a, "{{\"name\":\"t{d}\",\"argv\":[\"/bin/true\"]}}", .{i});
    }
    try buf.appendSlice(a, "]}");
    try std.testing.expectError(error.TaskLimitExceeded, parseOk(buf.items));
    try std.testing.expectError(error.DuplicateField, parseOk("{\"version\":1,\"version\":1,\"tasks\":[]}"));
}

test "task parse rejects oversized and over-deep files before allocation" {
    const big = try a.alloc(u8, task.limits.file_bytes + 1);
    defer a.free(big);
    @memset(big, ' ');
    try std.testing.expectError(error.TaskFileTooLarge, parseOk(big));
    try std.testing.expectError(error.JsonTooDeep, parseOk("{\"version\":1,\"tasks\":[{\"name\":\"x\",\"argv\":[\"/bin/true\"],\"env\":{\"A\":{\"B\":{\"C\":{\"D\":{\"E\":{\"F\":{\"G\":{\"H\":1}}}}}}}}}]}"));
}

test "resolveCwd stays inside the root and normalizes dot components" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectEqualStrings("/w", try task.resolveCwd(alloc, "/w", ""));
    try std.testing.expectEqualStrings("/w/a/b", try task.resolveCwd(alloc, "/w", "a/b"));
    try std.testing.expectEqualStrings("/w/b", try task.resolveCwd(alloc, "/w", "a/../b"));
    try std.testing.expectEqualStrings("/w", try task.resolveCwd(alloc, "/w", "a/.."));
    try std.testing.expectEqualStrings("/", try task.resolveCwd(alloc, "/", ""));
    try std.testing.expectEqualStrings("/x", try task.resolveCwd(alloc, "/", "x"));
    try std.testing.expectError(error.CwdOutsideWorkspace, task.resolveCwd(alloc, "/w", ".."));
    try std.testing.expectError(error.CwdOutsideWorkspace, task.resolveCwd(alloc, "/w", "a/../../b"));
    try std.testing.expectError(error.CwdMustBeRelative, task.resolveCwd(alloc, "/w", "/etc"));
}

test "task digest binds content and changes when bytes change" {
    var first = try parseOk("{\"version\":1,\"tasks\":[{\"name\":\"a\",\"argv\":[\"/bin/true\"]}]}");
    defer first.deinit();
    var second = try parseOk("{\"version\":1,\"tasks\":[{\"name\":\"b\",\"argv\":[\"/bin/true\"]}]}");
    defer second.deinit();
    try std.testing.expect(!std.mem.eql(u8, &first.digest, &second.digest));
}

// --- loader ------------------------------------------------------------------

extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;

const Fixture = struct {
    root: [:0]u8,

    fn init() !Fixture {
        var template = "/tmp/coral-tasks-test-XXXXXX".* ++ [_]u8{0};
        if (mkdtemp(&template) == null) return error.FixtureFailed;
        const root_path = try a.dupeSentinel(u8, std.mem.sliceTo(&template, 0), 0);
        return .{ .root = root_path };
    }
    fn deinit(self: *Fixture) void {
        self.unlink(".coral/tasks.json");
        self.unlink("target.json");
        const dir = self.path(".coral") catch return;
        defer a.free(dir);
        _ = std.c.rmdir(dir);
        _ = std.c.rmdir(self.root);
        a.free(self.root);
    }
    fn path(self: *const Fixture, rel: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ self.root, rel }, 0);
    }
    fn unlink(self: *Fixture, rel: []const u8) void {
        const p = self.path(rel) catch return;
        defer a.free(p);
        _ = std.c.unlink(p);
    }
    fn write(self: *Fixture, bytes: []const u8) !void {
        const dir = try self.path(".coral");
        defer a.free(dir);
        const rc = std.c.mkdir(dir, 0o755);
        if (rc < 0 and std.c.errno(rc) != .EXIST) return error.FixtureFailed;
        const file = try self.path(".coral/tasks.json");
        defer a.free(file);
        const fd = std.c.open(file, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o644));
        if (fd < 0) return error.FixtureFailed;
        defer _ = std.c.close(fd);
        var used: usize = 0;
        while (used < bytes.len) {
            const n = std.c.write(fd, bytes[used..].ptr, bytes.len - used);
            if (n <= 0) return error.FixtureFailed;
            used += @intCast(n);
        }
    }
    fn chmod(self: *Fixture, mode: u32) !void {
        const p = try self.path(".coral/tasks.json");
        defer a.free(p);
        try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(p, mode));
    }
};

test "load reads a disposable tasks.json and yields an empty list when absent" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var absent = try task.load(a, fixture.root);
    defer absent.deinit();
    try std.testing.expectEqual(@as(usize, 0), absent.tasks.len);

    try fixture.write("{\"version\":1,\"tasks\":[{\"name\":\"build\",\"argv\":[\"/usr/bin/zig\",\"build\"],\"cwd\":\"src\"}]}");
    var defs = try task.load(a, fixture.root);
    defer defs.deinit();
    try std.testing.expectEqual(@as(usize, 1), defs.tasks.len);
    const expected = try std.fmt.allocPrint(a, "{s}/src", .{fixture.root});
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, defs.tasks[0].cwd);
}

test "load refuses world-writable and symlinked executable configuration" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("{\"version\":1,\"tasks\":[{\"name\":\"x\",\"argv\":[\"/bin/true\"]}]}");
    try fixture.chmod(0o666);
    try std.testing.expectError(error.TaskConfigWritableByOthers, task.load(a, fixture.root));
    try fixture.chmod(0o644);

    // Replace the regular file with a symlink to a disposable target.
    const target = try fixture.path("target.json");
    defer a.free(target);
    const link = try fixture.path(".coral/tasks.json");
    defer a.free(link);
    try std.testing.expectEqual(@as(c_int, 0), std.c.rename(link, target));
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(target, link));
    try std.testing.expectError(error.TaskConfigUnreadable, task.load(a, fixture.root));
}

test "loadRoots merges definitions per root and enforces the combined bound" {
    var left = try Fixture.init();
    defer left.deinit();
    var right = try Fixture.init();
    defer right.deinit();
    try left.write("{\"version\":1,\"tasks\":[{\"name\":\"build\",\"argv\":[\"/usr/bin/zig\",\"build\"],\"cwd\":\"src\"}]}");
    try right.write("{\"version\":1,\"tasks\":[{\"name\":\"test\",\"argv\":[\"/usr/bin/zig\",\"build\",\"test\"]}]}");
    const roots = [_][]const u8{ left.root, right.root };
    var merged = try task.loadRoots(a, &roots);
    defer merged.deinit();
    try std.testing.expectEqual(@as(usize, 2), merged.tasks.len);
    const expect_left = try std.fmt.allocPrint(a, "{s}/src", .{left.root});
    defer a.free(expect_left);
    try std.testing.expectEqualStrings(expect_left, merged.tasks[0].cwd);
    try std.testing.expectEqualStrings(right.root, merged.tasks[1].cwd);
    try std.testing.expectEqualStrings(left.root, merged.tasks[0].root);
    try std.testing.expectEqualStrings(right.root, merged.tasks[1].root);

    // 64 tasks in one root plus one in another exceeds the combined cap.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "{\"version\":1,\"tasks\":[");
    for (0..task.limits.tasks) |i| {
        if (i != 0) try buf.append(a, ',');
        try buf.print(a, "{{\"name\":\"t{d}\",\"argv\":[\"/bin/true\"]}}", .{i});
    }
    try buf.appendSlice(a, "]}");
    try left.write(buf.items);
    try std.testing.expectError(error.TaskLimitExceeded, task.loadRoots(a, &roots));
}
