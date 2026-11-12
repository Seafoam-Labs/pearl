//! Standalone pure tests plus disposable-repository fixtures for the native
//! stash/conflict workflows. Run from subprojects/coral:
//!     zig test src/git/stash_test.zig -lc
//! Every Git write/fixture commit is confined to a private /tmp repository that is
//! removed on cleanup. No host repository, home directory or editor state is
//! touched. The fixtures exercise the pure planners/parsers (stash.zig,
//! conflict.zig) against real Git output using a self-contained fork/execve runner
//! (no shell, fixed /usr/bin/git, isolated environment). The GTK controllers are
//! validated separately by the application build.
const std = @import("std");
const stash = @import("stash.zig");
const conflict = @import("conflict.zig");
const t = std.testing;

test {
    _ = @import("stash.zig");
    _ = @import("conflict.zig");
}

// --- minimal libc boundary for the disposable fixture (Linux x86_64) ---------
const O_RDONLY = 0;
const O_WRONLY = 1;
const O_RDWR = 2;
const O_CREAT = 0x40;
const O_TRUNC = 0x200;
const O_DIRECTORY = 0x10000;
const O_NOFOLLOW = 0x20000;
const O_CLOEXEC = 0x80000;
const AT_REMOVEDIR = 0x200;

extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn open([*:0]const u8, c_int, ...) c_int;
extern "c" fn openat(c_int, [*:0]const u8, c_int, ...) c_int;
extern "c" fn close(c_int) c_int;
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
extern "c" fn rmdir([*:0]const u8) c_int;
extern "c" fn unlinkat(c_int, [*:0]const u8, c_int) c_int;
extern "c" fn dup(c_int) c_int;
extern "c" fn fork() c_int;
extern "c" fn execve([*:0]const u8, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8) c_int;
extern "c" fn pipe(*[2]c_int) c_int;
extern "c" fn waitpid(c_int, *c_int, c_int) c_int;
extern "c" fn dup2(c_int, c_int) c_int;
extern "c" fn chdir([*:0]const u8) c_int;
extern "c" fn _exit(c_int) noreturn;

const Run = struct { bytes: []u8, code: u8 };

/// Fixed argv, no shell, no PATH lookup, isolated environment. stdout is captured;
/// stdin/stderr are redirected to /dev/null so Git can never prompt or pollute the
/// parsed output. The child is always reaped.
fn gitRun(a: std.mem.Allocator, cwd: [:0]const u8, args: []const []const u8) !Run {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const argv = try aa.alloc(?[*:0]const u8, args.len + 2);
    argv[0] = "/usr/bin/git";
    for (args, 0..) |arg, i| argv[i + 1] = (try aa.dupeSentinel(u8, arg, 0)).ptr;
    argv[args.len + 1] = null;
    var env: std.ArrayList(?[*:0]const u8) = .empty;
    for ([_][]const u8{
        "PATH=/usr/bin:/bin",
        "LC_ALL=C",
        "LANG=C",
        "GIT_CONFIG_NOSYSTEM=1",
        "GIT_CONFIG_GLOBAL=/dev/null",
        "GIT_CONFIG_SYSTEM=/dev/null",
        "GIT_TERMINAL_PROMPT=0",
        "GIT_EDITOR=true",
        "GIT_NO_REPLACE_OBJECTS=1",
    }) |entry| try env.append(aa, (try aa.dupeSentinel(u8, entry, 0)).ptr);
    try env.append(aa, (try std.fmt.allocPrintSentinel(aa, "HOME={s}", .{cwd}, 0)).ptr);
    try env.append(aa, null);

    var pipefd: [2]c_int = undefined;
    if (pipe(&pipefd) != 0) return error.PipeFailed;
    const pid = fork();
    if (pid < 0) {
        _ = close(pipefd[0]);
        _ = close(pipefd[1]);
        return error.ForkFailed;
    }
    if (pid == 0) {
        _ = close(pipefd[0]);
        _ = dup2(pipefd[1], 1);
        const nullfd = open("/dev/null", O_RDWR);
        if (nullfd >= 0) {
            _ = dup2(nullfd, 0);
            _ = dup2(nullfd, 2);
            _ = close(nullfd);
        }
        _ = close(pipefd[1]);
        _ = chdir(cwd);
        _ = execve("/usr/bin/git", @ptrCast(argv.ptr), @ptrCast(env.items.ptr));
        _exit(127);
    }
    _ = close(pipefd[1]);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = read(pipefd[0], &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(a, buf[0..@intCast(n)]);
    }
    _ = close(pipefd[0]);
    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
    const code: u8 = if ((status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else 255;
    return .{ .bytes = try out.toOwnedSlice(a), .code = code };
}

const Fixture = struct {
    root: [:0]u8,
    fd: c_int,

    fn init() !Fixture {
        var template = "/tmp/coral-stash-test-XXXXXX".* ++ [_]u8{0};
        if (mkdtemp(&template) == null) return error.FixtureFailed;
        const root = try t.allocator.dupeSentinel(u8, std.mem.sliceTo(&template, 0), 0);
        errdefer t.allocator.free(root);
        const fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (fd < 0) return error.FixtureFailed;
        var f = Fixture{ .root = root, .fd = fd };
        errdefer {
            removeChildren(fd);
            _ = close(fd);
            _ = rmdir(root);
        }
        try f.git(&.{ "init", "-q", "--initial-branch=main" });
        try f.git(&.{ "config", "user.name", "Coral fixture" });
        try f.git(&.{ "config", "user.email", "coral-fixture@invalid" });
        return f;
    }
    fn deinit(f: *Fixture) void {
        removeChildren(f.fd);
        _ = close(f.fd);
        _ = rmdir(f.root);
        t.allocator.free(f.root);
    }
    fn run(f: *Fixture, args: []const []const u8, allow_one: bool) !Run {
        const r = try gitRun(t.allocator, f.root, args);
        if (r.code != 0 and !(allow_one and r.code == 1)) {
            t.allocator.free(r.bytes);
            return error.GitFailed;
        }
        return r;
    }
    fn git(f: *Fixture, args: []const []const u8) !void {
        const r = try f.run(args, false);
        t.allocator.free(r.bytes);
    }
    fn output(f: *Fixture, args: []const []const u8) ![]u8 {
        const r = try f.run(args, false);
        return r.bytes;
    }
    fn commit(f: *Fixture, message: []const u8) !void {
        try f.git(&.{ "-c", "commit.gpgsign=false", "commit", "-q", "--no-gpg-sign", "-m", message });
    }
    fn writeFile(f: *Fixture, name: [:0]const u8, bytes: []const u8) !void {
        const fd = openat(f.fd, name, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, @as(c_uint, 0o644));
        if (fd < 0) return error.FixtureFailed;
        defer _ = close(fd);
        var used: usize = 0;
        while (used < bytes.len) {
            const n = write(fd, bytes[used..].ptr, bytes.len - used);
            if (n <= 0) return error.FixtureFailed;
            used += @intCast(n);
        }
    }
    fn readFile(f: *Fixture, name: [:0]const u8) ![]u8 {
        const fd = openat(f.fd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (fd < 0) return error.FixtureFailed;
        defer _ = close(fd);
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(t.allocator);
        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = read(fd, &buffer, buffer.len);
            if (n < 0) return error.FixtureFailed;
            if (n == 0) break;
            try bytes.appendSlice(t.allocator, buffer[0..@intCast(n)]);
        }
        return bytes.toOwnedSlice(t.allocator);
    }
    fn expectFile(f: *Fixture, name: [:0]const u8, expected: []const u8) !void {
        const bytes = try f.readFile(name);
        defer t.allocator.free(bytes);
        try t.expectEqualStrings(expected, bytes);
    }
    fn baseline(f: *Fixture) !void {
        try f.writeFile("f.txt", "base\n");
        try f.git(&.{ "add", "--", "f.txt" });
        try f.commit("baseline");
    }
};

fn removeChildren(fd: c_int) void {
    const dir = std.c.fdopendir(dup(fd)) orelse return;
    defer _ = std.c.closedir(dir);
    while (std.c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (child >= 0) {
            removeChildren(child);
            _ = close(child);
            _ = unlinkat(fd, name, AT_REMOVEDIR);
        } else _ = unlinkat(fd, name, 0);
    }
}

test "fixture: stash push/list/apply/drop round-trip; apply preserves the entry" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    try f.writeFile("f.txt", "base\nchanged\n");

    var buf: [stash.max_args][]const u8 = undefined;
    try f.git(try stash.pushArgs(&buf, .tracked, "my stash"));
    try f.expectFile("f.txt", "base\n");

    const list_bytes = try f.output(stash.list_args);
    defer t.allocator.free(list_bytes);
    var list = try stash.parseList(t.allocator, list_bytes);
    defer list.deinit();
    try t.expectEqual(@as(usize, 1), list.entries.len);
    try t.expect(stash.validSelector(list.entries[0].selector));
    try t.expect(std.mem.indexOf(u8, list.entries[0].message, "my stash") != null);

    try f.git(try stash.applyArgs(&buf, list.entries[0].selector));
    try f.expectFile("f.txt", "base\nchanged\n");
    const after_apply = try f.output(stash.list_args);
    defer t.allocator.free(after_apply);
    var list2 = try stash.parseList(t.allocator, after_apply);
    defer list2.deinit();
    try t.expectEqual(@as(usize, 1), list2.entries.len);

    try f.git(try stash.dropArgs(&buf, list2.entries[0].selector));
    const after_drop = try f.output(stash.list_args);
    defer t.allocator.free(after_drop);
    var list3 = try stash.parseList(t.allocator, after_drop);
    defer list3.deinit();
    try t.expectEqual(@as(usize, 0), list3.entries.len);
}

test "fixture: staged and all stash modes; staged gate matches the real Git version" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();

    const version = try f.output(&.{"--version"});
    defer t.allocator.free(version);
    const staged_ok = stash.stagedSupported(version);

    var buf: [stash.max_args][]const u8 = undefined;
    try f.writeFile("f.txt", "staged\n");
    try f.git(&.{ "add", "--", "f.txt" });
    if (staged_ok) {
        try f.git(try stash.pushArgs(&buf, .staged, "staged only"));
        try f.expectFile("f.txt", "base\n");
    }

    try f.writeFile("f.txt", "base\nagain\n");
    try f.writeFile("untracked.txt", "new\n");
    try f.git(try stash.pushArgs(&buf, .all, "with untracked"));
    try f.expectFile("f.txt", "base\n");
    const untracked_present = f.readFile("untracked.txt") catch null;
    if (untracked_present) |bytes| {
        t.allocator.free(bytes);
        return error.UntrackedNotStashed;
    }

    const list_bytes = try f.output(stash.list_args);
    defer t.allocator.free(list_bytes);
    var list = try stash.parseList(t.allocator, list_bytes);
    defer list.deinit();
    try t.expect(list.entries.len >= 1);
}

test "fixture: merge conflict listing, stage bytes, resolve planning and gitdir state" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.writeFile("f.txt", "base\n");
    try f.git(&.{ "add", "--", "f.txt" });
    try f.commit("base");
    try f.writeFile("f.txt", "ours\n");
    try f.git(&.{ "add", "--", "f.txt" });
    try f.commit("ours");
    try f.git(&.{ "checkout", "-q", "-b", "other", "HEAD~1" });
    try f.writeFile("f.txt", "theirs\n");
    try f.git(&.{ "add", "--", "f.txt" });
    try f.commit("theirs");
    try f.git(&.{ "checkout", "-q", "main" });

    const merge = try f.run(&.{ "merge", "other" }, true);
    t.allocator.free(merge.bytes);
    try t.expectEqual(@as(u8, 1), merge.code);

    const unmerged = try f.output(conflict.unmerged_args);
    defer t.allocator.free(unmerged);
    var listing = try conflict.parseUnmerged(t.allocator, unmerged);
    defer listing.deinit();
    try t.expectEqual(@as(usize, 1), listing.conflicts.len);
    const target = listing.conflicts[0];
    try t.expectEqualStrings("f.txt", target.path);
    try t.expectEqual(conflict.Kind.both_modified, target.kind);
    try t.expect(target.kind.resolvable());
    try t.expect(target.base != null and target.ours != null and target.theirs != null);

    // Merge state is read from the gitdir state ref, not from conflict markers.
    const merge_head = try f.run(&.{ "rev-parse", "--verify", "--quiet", "MERGE_HEAD" }, true);
    t.allocator.free(merge_head.bytes);
    try t.expectEqual(@as(u8, 0), merge_head.code);
    const rebase_head = try f.run(&.{ "rev-parse", "--verify", "--quiet", "REBASE_HEAD" }, true);
    t.allocator.free(rebase_head.bytes);
    try t.expectEqual(@as(u8, 1), rebase_head.code);

    var buf: [conflict.max_args][]const u8 = undefined;
    const ours = try f.output(try conflict.catFileArgs(&buf, target.ours.?.oid));
    defer t.allocator.free(ours);
    try t.expectEqualStrings("ours\n", ours);
    try conflict.text(ours);
    const theirs = try f.output(try conflict.catFileArgs(&buf, target.theirs.?.oid));
    defer t.allocator.free(theirs);
    try t.expectEqualStrings("theirs\n", theirs);
    try conflict.text(theirs);
    const both = try conflict.combineBoth(t.allocator, ours, theirs);
    defer t.allocator.free(both);
    try t.expectEqualStrings("ours\ntheirs\n", both);

    try f.git(&.{ "merge", "--abort" });
}

test "fixture: rebase state is detected from REBASE_HEAD, not markers" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.writeFile("f.txt", "base\n");
    try f.git(&.{ "add", "--", "f.txt" });
    try f.commit("base");
    try f.git(&.{ "checkout", "-q", "-b", "side", "HEAD" });
    try f.writeFile("f.txt", "side\n");
    try f.git(&.{ "add", "--", "f.txt" });
    try f.commit("side");
    try f.git(&.{ "checkout", "-q", "main" });
    try f.writeFile("f.txt", "main\n");
    try f.git(&.{ "add", "--", "f.txt" });
    try f.commit("main2");

    const rebase = try f.run(&.{ "rebase", "side" }, true);
    t.allocator.free(rebase.bytes);
    try t.expectEqual(@as(u8, 1), rebase.code);

    const rebase_head = try f.run(&.{ "rev-parse", "--verify", "--quiet", "REBASE_HEAD" }, true);
    t.allocator.free(rebase_head.bytes);
    try t.expectEqual(@as(u8, 0), rebase_head.code);
    const merge_head = try f.run(&.{ "rev-parse", "--verify", "--quiet", "MERGE_HEAD" }, true);
    t.allocator.free(merge_head.bytes);
    try t.expectEqual(@as(u8, 1), merge_head.code);

    const unmerged = try f.output(conflict.unmerged_args);
    defer t.allocator.free(unmerged);
    var listing = try conflict.parseUnmerged(t.allocator, unmerged);
    defer listing.deinit();
    try t.expect(listing.conflicts.len >= 1);

    try f.git(&.{ "rebase", "--abort" });
}

test "fixture: delete/modify conflict is classified non-resolvable" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.writeFile("f.txt", "base\n");
    try f.git(&.{ "add", "--", "f.txt" });
    try f.commit("base");
    try f.git(&.{ "checkout", "-q", "-b", "other", "HEAD" });
    try f.git(&.{ "rm", "-q", "f.txt" });
    try f.commit("delete on other");
    try f.git(&.{ "checkout", "-q", "main" });
    try f.writeFile("f.txt", "modified\n");
    try f.git(&.{ "add", "--", "f.txt" });
    try f.commit("modify on main");

    const merge = try f.run(&.{ "merge", "other" }, true);
    t.allocator.free(merge.bytes);
    try t.expectEqual(@as(u8, 1), merge.code);

    const unmerged = try f.output(conflict.unmerged_args);
    defer t.allocator.free(unmerged);
    var listing = try conflict.parseUnmerged(t.allocator, unmerged);
    defer listing.deinit();
    try t.expectEqual(@as(usize, 1), listing.conflicts.len);
    const target = listing.conflicts[0];
    try t.expect(target.kind == .deleted_by_them or target.kind == .deleted_by_us);
    try t.expect(!target.kind.resolvable());

    try f.git(&.{ "merge", "--abort" });
}

test "fixture: a failed apply preserves the stash entry" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    try f.writeFile("f.txt", "stashed\n");
    var buf: [stash.max_args][]const u8 = undefined;
    try f.git(try stash.pushArgs(&buf, .tracked, "keep me"));
    try f.expectFile("f.txt", "base\n");
    // An uncommitted local change the apply would overwrite: apply must fail and
    // must not drop or lose the entry.
    try f.writeFile("f.txt", "local\n");
    const apply = try gitRun(t.allocator, f.root, try stash.applyArgs(&buf, "stash@{0}"));
    t.allocator.free(apply.bytes);
    try t.expect(apply.code != 0);
    const list_bytes = try f.output(stash.list_args);
    defer t.allocator.free(list_bytes);
    var list = try stash.parseList(t.allocator, list_bytes);
    defer list.deinit();
    try t.expectEqual(@as(usize, 1), list.entries.len);
    try t.expect(std.mem.indexOf(u8, list.entries[0].message, "keep me") != null);
}

test "fixture: both-side resolution bytes write and stage cleanly" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.writeFile("f.txt", "base\n");
    try f.git(&.{ "add", "--", "f.txt" });
    try f.commit("base");
    try f.writeFile("f.txt", "ours\n");
    try f.git(&.{ "add", "--", "f.txt" });
    try f.commit("ours");
    try f.git(&.{ "checkout", "-q", "-b", "other", "HEAD~1" });
    try f.writeFile("f.txt", "theirs\n");
    try f.git(&.{ "add", "--", "f.txt" });
    try f.commit("theirs");
    try f.git(&.{ "checkout", "-q", "main" });
    const merge = try f.run(&.{ "merge", "other" }, true);
    t.allocator.free(merge.bytes);
    try t.expectEqual(@as(u8, 1), merge.code);

    const unmerged = try f.output(conflict.unmerged_args);
    defer t.allocator.free(unmerged);
    var listing = try conflict.parseUnmerged(t.allocator, unmerged);
    defer listing.deinit();
    const target = listing.conflicts[0];
    var buf: [conflict.max_args][]const u8 = undefined;
    const ours = try f.output(try conflict.catFileArgs(&buf, target.ours.?.oid));
    defer t.allocator.free(ours);
    const theirs = try f.output(try conflict.catFileArgs(&buf, target.theirs.?.oid));
    defer t.allocator.free(theirs);
    const both = try conflict.combineBoth(t.allocator, ours, theirs);
    defer t.allocator.free(both);
    try t.expectEqualStrings("ours\ntheirs\n", both);

    // The resolve sequence: write the reviewed bytes to the worktree, then git add.
    try f.writeFile("f.txt", both);
    try f.git(try conflict.addArgs(&buf, target.path));
    const after = try f.output(conflict.unmerged_args);
    defer t.allocator.free(after);
    try t.expectEqual(@as(usize, 0), after.len);
    const staged = try f.output(&.{ "show", ":0:f.txt" });
    defer t.allocator.free(staged);
    try t.expectEqualStrings(both, staged);
    try f.git(&.{ "merge", "--abort" });
}
