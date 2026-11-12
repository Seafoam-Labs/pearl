//! M4 commit/uncommit tests. Pure builder/parser tests live in commit.zig; this
//! root adds disposable-repository transaction tests. Every Git write is confined
//! to a private /tmp repository with a hermetic environment (no host config,
//! identity or signing). No host repository is ever written.
//!
//! Like index_transaction_test.zig, this file is imported by a src/-level test
//! root (wired by the parent) so ../language and ../terminal imports resolve:
//!   zig test src/git_commit_tests.zig -lc
//! The write prefix below mirrors env.write_prefix; env.zig itself pulls in the
//! GTK process module and is exercised by the controller, not this libc-only root.
const std = @import("std");
const commit = @import("commit.zig");
const conflict = @import("conflict.zig");
const tx = @import("index_transaction.zig");
const status = @import("status.zig");
const c = @import("index_transaction_os.zig");
const t = std.testing;

const write_prefix: []const []const u8 = &.{
    "/usr/bin/git", "--no-pager",           "--no-optional-locks", "--literal-pathspecs",
    "-c",           "core.fsmonitor=false", "-c",                  "core.untrackedCache=false",
};

const Fixture = struct {
    root: [:0]u8,
    gitdir: [:0]u8,
    fd: c_int,
    cancel: commit.Cancel = .init(false),
    env: []commit.Environment,
    policy: commit.WritePolicy,

    fn init() !Fixture {
        var template = "/tmp/coral-commit-test-XXXXXX".* ++ [_]u8{0};
        if (c.mkdtemp(&template) == null) return error.FixtureFailed;
        errdefer _ = c.rmdir(&template);
        const root = try t.allocator.dupeSentinel(u8, std.mem.sliceTo(&template, 0), 0);
        errdefer t.allocator.free(root);
        const gitdir = try std.fmt.allocPrintSentinel(t.allocator, "{s}/.git", .{root}, 0);
        errdefer t.allocator.free(gitdir);
        const fd = c.open(root, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
        if (fd < 0) return error.FixtureFailed;
        errdefer {
            removeChildren(fd);
            _ = c.close(fd);
        }
        const env = try hermeticEnv(root);
        errdefer freeEnv(env);
        var f = Fixture{
            .root = root,
            .gitdir = gitdir,
            .fd = fd,
            .env = env,
            .policy = .{ .prefix = write_prefix, .environment = env },
        };
        try f.git(&.{ "init", "-q", "--initial-branch=main" });
        try f.git(&.{ "config", "user.name", "Coral fixture" });
        try f.git(&.{ "config", "user.email", "coral-fixture@invalid" });
        try f.git(&.{ "config", "commit.gpgsign", "false" });
        return f;
    }
    fn deinit(f: *Fixture) void {
        removeChildren(f.fd);
        _ = c.close(f.fd);
        _ = c.rmdir(f.root);
        freeEnv(f.env);
        t.allocator.free(f.gitdir);
        t.allocator.free(f.root);
    }
    fn outputAllow(f: *Fixture, args: []const []const u8, allow_one: bool) ![]const u8 {
        const r = try tx.runGit(t.allocator, f.root, null, null, null, null, &f.cancel, args, "", commit.max_capture, allow_one);
        return r.bytes;
    }
    fn output(f: *Fixture, args: []const []const u8) ![]const u8 {
        return f.outputAllow(args, false);
    }
    fn git(f: *Fixture, args: []const []const u8) !void {
        const bytes = try f.output(args);
        t.allocator.free(bytes);
    }
    /// Run a setup command that may legitimately exit 1 (e.g. a conflicting merge).
    fn gitConflict(f: *Fixture, args: []const []const u8) !void {
        const bytes = try f.outputAllow(args, true);
        t.allocator.free(bytes);
    }
    fn write(f: *Fixture, name: [:0]const u8, bytes: []const u8) !void {
        const fd = c.openat(f.fd, name, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o644));
        if (fd < 0) return error.FixtureFailed;
        defer _ = c.close(fd);
        if (c.write(fd, bytes.ptr, bytes.len) != bytes.len) return error.FixtureFailed;
    }
    fn read(f: *Fixture, name: [:0]const u8) ![]u8 {
        const fd = c.openat(f.fd, name, c.O_RDONLY | c.O_CLOEXEC);
        if (fd < 0) return error.FixtureFailed;
        defer _ = c.close(fd);
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(t.allocator);
        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = c.read(fd, &buffer, buffer.len);
            if (n < 0) return error.FixtureFailed;
            if (n == 0) break;
            try bytes.appendSlice(t.allocator, buffer[0..@intCast(n)]);
        }
        return bytes.toOwnedSlice(t.allocator);
    }
    fn expectFile(f: *Fixture, name: [:0]const u8, expected: []const u8) !void {
        const bytes = try f.read(name);
        defer t.allocator.free(bytes);
        try t.expectEqualStrings(expected, bytes);
    }
    fn expectGit(f: *Fixture, args: []const []const u8, expected: []const u8) !void {
        const bytes = try f.output(args);
        defer t.allocator.free(bytes);
        try t.expectEqualStrings(expected, bytes);
    }
    fn head(f: *Fixture) !?[]const u8 {
        return commit.headOid(t.allocator, f.root, &f.cancel);
    }
    fn nameStatus(f: *Fixture) ![]const u8 {
        return f.output(commit.name_status_args);
    }
    fn baseline(f: *Fixture) !void {
        try f.write("a", "one\n");
        try f.write("b", "two\n");
        try f.git(&.{ "add", "--", "a", "b" });
        try commit.applyCommit(t.allocator, f.root, &f.cancel, f.policy, "fixture baseline");
    }
};

fn hermeticEnv(root: []const u8) ![]commit.Environment {
    var list: std.ArrayList(commit.Environment) = .empty;
    errdefer list.deinit(t.allocator);
    const entries = [_]commit.Environment{
        .{ .name = "PATH", .value = "/usr/bin:/bin" },
        .{ .name = "HOME", .value = root },
        .{ .name = "LC_ALL", .value = "C" },
        .{ .name = "LANG", .value = "C" },
        .{ .name = "TZ", .value = "UTC" },
        .{ .name = "GIT_CONFIG_NOSYSTEM", .value = "1" },
        .{ .name = "GIT_CONFIG_SYSTEM", .value = "/dev/null" },
        .{ .name = "GIT_CONFIG_GLOBAL", .value = "/dev/null" },
        .{ .name = "GIT_TERMINAL_PROMPT", .value = "0" },
        .{ .name = "GIT_EDITOR", .value = "true" },
        .{ .name = "GIT_NO_REPLACE_OBJECTS", .value = "1" },
    };
    for (entries) |e| try list.append(t.allocator, .{ .name = e.name, .value = try t.allocator.dupe(u8, e.value) });
    return list.toOwnedSlice(t.allocator);
}
fn freeEnv(env: []commit.Environment) void {
    for (env) |e| t.allocator.free(e.value);
    t.allocator.free(env);
}
fn removeChildren(fd: c_int) void {
    const dir = c.fdopendir(c.dup(fd)) orelse return;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const child = c.openat(fd, name, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (child >= 0) {
            removeChildren(child);
            _ = c.close(child);
            _ = c.unlinkat(fd, name, c.AT_REMOVEDIR);
        } else _ = c.unlinkat(fd, name, 0);
    }
}

test "commit is staged-only and preserves unstaged/untracked; uncommit soft-resets preserving index and worktree" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    const base = (try f.head()).?;
    defer t.allocator.free(base);

    // Stage a change to 'a', then leave a further unstaged edit on top, plus an
    // untracked file. Only the staged snapshot may be committed.
    try f.write("a", "staged\n");
    try f.git(&.{ "add", "--", "a" });
    try f.write("a", "staged+unstaged\n");
    try f.write("u", "untracked\n");

    const staged = try f.nameStatus();
    defer t.allocator.free(staged);
    try t.expectEqualStrings("M\x00a\x00", staged);
    try commit.recheckCommit(t.allocator, f.root, &f.cancel, base, staged);
    try commit.applyCommit(t.allocator, f.root, &f.cancel, f.policy, "second commit");

    const second = (try f.head()).?;
    defer t.allocator.free(second);
    try t.expect(!std.mem.eql(u8, base, second));
    // Unstaged worktree edit and untracked file survive the commit untouched.
    try f.expectFile("a", "staged+unstaged\n");
    try f.expectFile("u", "untracked\n");
    try f.expectFile("b", "two\n");
    // The committed blob is the staged snapshot, not the worktree edit.
    try f.expectGit(&.{ "show", "HEAD:a" }, "staged\n");

    // Uncommit: soft reset back to baseline keeps index and worktree.
    try commit.recheckUncommit(t.allocator, f.root, f.gitdir, &f.cancel, second, base, null);
    try commit.applyUncommit(t.allocator, f.root, &f.cancel, f.policy, base, second);
    const after = (try f.head()).?;
    defer t.allocator.free(after);
    try t.expectEqualStrings(base, after);
    try f.expectFile("a", "staged+unstaged\n");
    try f.expectFile("u", "untracked\n");
    // The staged change remains staged after the soft reset (index preserved).
    const restaged = try f.nameStatus();
    defer t.allocator.free(restaged);
    try t.expectEqualStrings("M\x00a\x00", restaged);
}

test "empty staged set is refused before any commit" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    const base = (try f.head()).?;
    defer t.allocator.free(base);
    // The recheck must refuse an empty staged capture.
    try t.expectError(error.EmptyStaged, commit.recheckCommit(t.allocator, f.root, &f.cancel, base, ""));
    // Git itself also aborts an empty commit (no --allow-empty).
    try t.expectError(error.GitFailed, commit.applyCommit(t.allocator, f.root, &f.cancel, f.policy, "should not commit"));
    const still = (try f.head()).?;
    defer t.allocator.free(still);
    try t.expectEqualStrings(base, still);
}

test "uncommit refuses initial, merge and published HEAD" {
    var f = try Fixture.init();
    defer f.deinit();
    // Initial: unborn HEAD has no commit to uncommit.
    try t.expect((try f.head()) == null);
    try t.expectError(error.GitFailed, commit.recheckUncommit(t.allocator, f.root, f.gitdir, &f.cancel, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", null));

    try f.baseline();
    const base = (try f.head()).?;
    defer t.allocator.free(base);

    // Give HEAD a single parent so the publication check is reachable.
    try f.write("a", "second\n");
    try f.git(&.{ "add", "--", "a" });
    try commit.applyCommit(t.allocator, f.root, &f.cancel, f.policy, "second commit");
    const second = (try f.head()).?;
    defer t.allocator.free(second);

    // Published: a remote-tracking ref at HEAD makes HEAD an ancestor of upstream.
    try f.git(&.{ "update-ref", "refs/remotes/origin/main", second });
    try t.expectError(error.PublishedHead, commit.recheckUncommit(t.allocator, f.root, f.gitdir, &f.cancel, second, base, "origin/main"));

    // Ahead of upstream (upstream is an ancestor of HEAD) is NOT published.
    try f.write("a", "ahead\n");
    try f.git(&.{ "add", "--", "a" });
    try commit.applyCommit(t.allocator, f.root, &f.cancel, f.policy, "ahead commit");
    const ahead = (try f.head()).?;
    defer t.allocator.free(ahead);
    try commit.recheckUncommit(t.allocator, f.root, f.gitdir, &f.cancel, ahead, second, "origin/main");

    // Merge: two parents must be refused.
    try f.git(&.{ "checkout", "-q", "-b", "side", base });
    try f.write("b", "side\n");
    try f.git(&.{ "add", "--", "b" });
    try commit.applyCommit(t.allocator, f.root, &f.cancel, f.policy, "side commit");
    try f.git(&.{ "checkout", "-q", "main" });
    try f.git(&.{ "merge", "--no-ff", "-q", "-m", "merge side", "side" });
    const merge = (try f.head()).?;
    defer t.allocator.free(merge);
    const parents = try f.output(commit.parents_args);
    defer t.allocator.free(parents);
    const parsed = try commit.parseParents(t.allocator, parents);
    defer {
        t.allocator.free(parsed.head);
        for (parsed.parents) |p| t.allocator.free(p);
        t.allocator.free(parsed.parents);
    }
    try t.expectEqual(@as(usize, 2), parsed.parents.len);
    try t.expectError(error.InitialOrMergeCommit, commit.recheckUncommit(t.allocator, f.root, f.gitdir, &f.cancel, merge, parsed.parents[0], null));
}

test "stage tracked stages modifications but never untracked files" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    const base = (try f.head()).?;
    defer t.allocator.free(base);
    try f.write("a", "modified\n");
    try f.write("u", "untracked\n");
    try commit.recheckStage(t.allocator, f.root, &f.cancel, base);
    try commit.applyStage(t.allocator, f.root, &f.cancel, f.policy);
    const staged = try f.nameStatus();
    defer t.allocator.free(staged);
    try t.expectEqualStrings("M\x00a\x00", staged);
    // Untracked file remains untracked (not added by add -u).
    try f.expectGit(&.{ "status", "--porcelain=v1", "--untracked-files=normal", "--", "u" }, "?? u\n");
}

test "recheck detects a moved HEAD and a changed staged set" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    const base = (try f.head()).?;
    defer t.allocator.free(base);
    try f.write("a", "staged\n");
    try f.git(&.{ "add", "--", "a" });
    const staged = try f.nameStatus();
    defer t.allocator.free(staged);

    // A different staged set than reviewed fails closed.
    try f.write("b", "also staged\n");
    try f.git(&.{ "add", "--", "b" });
    try t.expectError(error.StaleSnapshot, commit.recheckCommit(t.allocator, f.root, &f.cancel, base, staged));

    // A moved HEAD fails closed even if the staged bytes were restored.
    try f.git(&.{ "reset", "-q", "--", "b" });
    try commit.applyCommit(t.allocator, f.root, &f.cancel, f.policy, "move head");
    const moved = (try f.head()).?;
    defer t.allocator.free(moved);
    try t.expectError(error.StaleSnapshot, commit.recheckCommit(t.allocator, f.root, &f.cancel, base, staged));
}

test "cancellation refuses the write before publication" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    const base = (try f.head()).?;
    defer t.allocator.free(base);
    try f.write("a", "staged\n");
    try f.git(&.{ "add", "--", "a" });
    f.cancel.store(true, .release);
    try t.expectError(error.Cancelled, commit.applyCommit(t.allocator, f.root, &f.cancel, f.policy, "cancelled"));
    try t.expectError(error.Cancelled, commit.applyUncommit(t.allocator, f.root, &f.cancel, f.policy, base, base));
    f.cancel.store(false, .release);
    const still = (try f.head()).?;
    defer t.allocator.free(still);
    try t.expectEqualStrings(base, still);
}

test "counts separate staged, unstaged and unmerged tracked entries" {
    const oid_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const oid_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    var snap = try status.parse(t.allocator, "# branch.oid 1234567890123456789012345678901234567890\x00" ++
        "# branch.head main\x00" ++
        "1 MM N... 100644 100644 100644 " ++ oid_a ++ " " ++ oid_b ++ " both\x00" ++
        "1 .M N... 100644 100644 100644 " ++ oid_a ++ " " ++ oid_b ++ " unstaged\x00" ++
        "1 M. N... 100644 100644 100644 " ++ oid_a ++ " " ++ oid_b ++ " staged\x00");
    defer snap.deinit();
    const counts = commit.counts(&snap);
    try t.expectEqual(@as(usize, 2), counts.staged);
    try t.expectEqual(@as(usize, 2), counts.unstaged);
    try t.expectEqual(@as(usize, 0), counts.unmerged);
}

/// Create divergent side/main commits so a merge/cherry-pick/rebase conflicts.
/// Leaves HEAD on main with a clean tree; no operation started yet.
fn diverge(f: *Fixture) !void {
    try f.git(&.{ "checkout", "-q", "-b", "side" });
    try f.write("a", "side\n");
    try f.git(&.{ "add", "--", "a" });
    try commit.applyCommit(t.allocator, f.root, &f.cancel, f.policy, "side");
    try f.git(&.{ "checkout", "-q", "main" });
    try f.write("a", "main\n");
    try f.git(&.{ "add", "--", "a" });
    try commit.applyCommit(t.allocator, f.root, &f.cancel, f.policy, "main");
}

test "stage tracked refuses unmerged conflicts before add -u (P1)" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    try diverge(&f);
    const main_head = (try f.head()).?;
    defer t.allocator.free(main_head);
    try f.gitConflict(&.{ "merge", "--no-ff", "-m", "merge", "side" });
    // Unmerged entries exist; the stage recheck must refuse before any add -u.
    try t.expectError(error.UnmergedConflict, commit.recheckStage(t.allocator, f.root, &f.cancel, main_head));
    // HEAD is unchanged and the conflict was never silently resolved/staged.
    const still = (try f.head()).?;
    defer t.allocator.free(still);
    try t.expectEqualStrings(main_head, still);
}

test "operation state is detected read-only and blocks uncommit (P3)" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    const base = (try f.head()).?;
    defer t.allocator.free(base);
    try t.expectEqual(conflict.Operation.none, try commit.detectOperation(t.allocator, f.root, f.gitdir, &f.cancel));

    try diverge(&f);
    const main_head = (try f.head()).?;
    defer t.allocator.free(main_head);

    // Merge in progress: MERGE_HEAD present, uncommit refused.
    try f.gitConflict(&.{ "merge", "--no-ff", "-m", "merge", "side" });
    try t.expectEqual(conflict.Operation.merge, try commit.detectOperation(t.allocator, f.root, f.gitdir, &f.cancel));
    try t.expectError(error.OperationInProgress, commit.recheckUncommit(t.allocator, f.root, f.gitdir, &f.cancel, main_head, base, null));
    try f.git(&.{ "merge", "--abort" });
    try t.expectEqual(conflict.Operation.none, try commit.detectOperation(t.allocator, f.root, f.gitdir, &f.cancel));

    // Cherry-pick in progress: CHERRY_PICK_HEAD present.
    try f.gitConflict(&.{ "cherry-pick", "side" });
    try t.expectEqual(conflict.Operation.cherry_pick, try commit.detectOperation(t.allocator, f.root, f.gitdir, &f.cancel));
    try t.expectError(error.OperationInProgress, commit.recheckUncommit(t.allocator, f.root, f.gitdir, &f.cancel, main_head, base, null));
    try f.git(&.{ "cherry-pick", "--abort" });

    // Rebase in progress: REBASE_HEAD and the rebase-merge directory present.
    try f.gitConflict(&.{ "rebase", "side" });
    try t.expectEqual(conflict.Operation.rebase, try commit.detectOperation(t.allocator, f.root, f.gitdir, &f.cancel));
    try t.expectError(error.OperationInProgress, commit.recheckUncommit(t.allocator, f.root, f.gitdir, &f.cancel, main_head, base, null));
    try f.git(&.{ "rebase", "--abort" });
    try t.expectEqual(conflict.Operation.none, try commit.detectOperation(t.allocator, f.root, f.gitdir, &f.cancel));
}

test "uncommit CAS fails closed on a HEAD race and pins the reviewed parent" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    const base = (try f.head()).?;
    defer t.allocator.free(base);
    try f.write("a", "second\n");
    try f.git(&.{ "add", "--", "a" });
    try commit.applyCommit(t.allocator, f.root, &f.cancel, f.policy, "second");
    const second = (try f.head()).?;
    defer t.allocator.free(second);

    // A wrong expected HEAD (a concurrent move) must fail closed, leaving HEAD put.
    try t.expectError(error.GitFailed, commit.applyUncommit(t.allocator, f.root, &f.cancel, f.policy, base, "0000000000000000000000000000000000000000"));
    const unchanged = (try f.head()).?;
    defer t.allocator.free(unchanged);
    try t.expectEqualStrings(second, unchanged);

    // The correct CAS moves HEAD to the pinned parent, preserving index/worktree.
    try f.write("a", "second+unstaged\n");
    try commit.applyUncommit(t.allocator, f.root, &f.cancel, f.policy, base, second);
    const after = (try f.head()).?;
    defer t.allocator.free(after);
    try t.expectEqualStrings(base, after);
    try f.expectFile("a", "second+unstaged\n");
    const restaged = try f.nameStatus();
    defer t.allocator.free(restaged);
    try t.expectEqualStrings("M\x00a\x00", restaged);
}
