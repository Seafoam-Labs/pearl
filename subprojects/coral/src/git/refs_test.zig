//! Standalone M4 branch/tag/worktree tests: pure parser/validator roots plus
//! disposable-repository fixtures. No GTK, no app, no host repository writes:
//! every fixture commit/branch/tag/worktree lives in a private mkdtemp
//! directory under /tmp and is removed on teardown.
//!
//! The standalone test root lives in src/git, so it cannot import the shared
//! src-level transport/OS modules (module path isolation). Fixtures therefore
//! use a minimal self-contained runner: std.process.run with the SAME fixed
//! read-only argv prefix and complete environment allowlist as command.zig —
//! no shell, no PATH lookup, no inherited environment, bounded capture and a
//! 15-second deadline. Production controllers use tasks/process.zig instead.
//!
//! From subprojects/coral: zig test src/git/refs_test.zig -lc
const std = @import("std");
const t = std.testing;
const refs = @import("refs.zig");
const worktree = @import("worktree.zig");
const command = @import("command.zig");
const status = @import("status.zig");

test {
    _ = refs;
    _ = worktree;
}

// Test-only libc boundary for private temporary directories.
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn rmdir(path: [*:0]const u8) c_int;

const Fixture = struct {
    root: [:0]u8,
    threaded: std.Io.Threaded,
    env: std.process.Environ.Map,

    fn init() !*Fixture {
        var template = ("/tmp/coral-refs-test-XXXXXX" ++ "\x00").*;
        if (mkdtemp(&template) == null) return error.FixtureFailed;
        const root = try t.allocator.dupeSentinel(u8, std.mem.sliceTo(&template, 0), 0);
        errdefer t.allocator.free(root);
        errdefer _ = rmdir(root);
        const f = try t.allocator.create(Fixture);
        errdefer t.allocator.destroy(f);
        f.root = root;
        f.threaded = std.Io.Threaded.init(t.allocator, .{});
        errdefer f.threaded.deinit();
        f.env = std.process.Environ.Map.init(t.allocator);
        errdefer f.env.deinit();
        for (command.environment) |entry| try f.env.put(entry.name, entry.value);
        try f.git(&.{ "init", "-q", "--initial-branch=main" });
        try f.git(&.{ "config", "user.name", "Coral fixture" });
        try f.git(&.{ "config", "user.email", "coral-fixture@invalid" });
        return f;
    }
    fn deinit(f: *Fixture) void {
        std.Io.Dir.cwd().deleteTree(f.io(), f.root) catch {};
        _ = rmdir(f.root);
        f.env.deinit();
        f.threaded.deinit();
        t.allocator.free(f.root);
        t.allocator.destroy(f);
    }
    fn io(f: *Fixture) std.Io {
        return f.threaded.io();
    }
    fn run(f: *Fixture, args: []const []const u8, allow_one: bool) !struct { bytes: []const u8, code: u8 } {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(t.allocator);
        try argv.appendSlice(t.allocator, command.prefix);
        try argv.appendSlice(t.allocator, args);
        const result = try std.process.run(t.allocator, f.io(), .{
            .argv = argv.items,
            .cwd = .{ .path = f.root },
            .environ_map = &f.env,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(16 * 1024),
            .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = 15_000_000_000 }, .clock = .awake } },
        });
        defer t.allocator.free(result.stderr);
        const code: u8 = switch (result.term) {
            .exited => |code| code,
            else => {
                t.allocator.free(result.stdout);
                return error.FixtureFailed;
            },
        };
        if (code != 0 and !(allow_one and code == 1)) {
            t.allocator.free(result.stdout);
            return error.GitFailed;
        }
        return .{ .bytes = result.stdout, .code = code };
    }
    fn output(f: *Fixture, args: []const []const u8) ![]const u8 {
        const result = try f.run(args, false);
        return result.bytes;
    }
    fn git(f: *Fixture, args: []const []const u8) !void {
        const bytes = try f.output(args);
        t.allocator.free(bytes);
    }
    fn write(f: *Fixture, sub_path: []const u8, bytes: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(f.io(), .{ .sub_path = sub_path, .data = bytes });
    }
    fn read(f: *Fixture, sub_path: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(f.io(), sub_path, t.allocator, .limited(64 * 1024));
    }
    fn commit(f: *Fixture, name: [:0]const u8, message: []const u8) !void {
        const file_path = try f.path(name);
        defer t.allocator.free(file_path);
        try f.write(file_path, message);
        try f.git(&.{ "add", "--", name });
        try f.git(&.{ "-c", "commit.gpgsign=false", "commit", "-q", "--no-gpg-sign", "-m", message });
    }
    fn branches(f: *Fixture) !refs.Branches {
        const bytes = try f.output(&.{ "for-each-ref", "--format=" ++ refs.branch_format, "refs/heads", "refs/remotes" });
        defer t.allocator.free(bytes);
        return refs.parseBranches(t.allocator, bytes);
    }
    fn tags(f: *Fixture) !refs.Tags {
        const bytes = try f.output(&.{ "for-each-ref", "--format=" ++ refs.tag_format, "refs/tags" });
        defer t.allocator.free(bytes);
        return refs.parseTags(t.allocator, bytes);
    }
    fn worktrees(f: *Fixture) !worktree.List {
        const bytes = try f.output(&.{ "worktree", "list", "--porcelain", "-z" });
        defer t.allocator.free(bytes);
        return worktree.parseList(t.allocator, bytes);
    }
    fn path(f: *Fixture, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(t.allocator, "{s}/{s}", .{ f.root, name }, 0);
    }
};

test "fixture branch create/list/switch/delete round-trips through the parser" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.commit("file.txt", "baseline\n");
    try f.git(&.{ "branch", "--", "topic" });
    var listing = try f.branches();
    defer listing.deinit();
    try t.expectEqual(@as(usize, 2), listing.items.len);
    var saw_main = false;
    var saw_topic = false;
    for (listing.items) |branch| {
        if (std.mem.eql(u8, branch.name, "main")) {
            saw_main = true;
            try t.expect(branch.current and !branch.remote);
        }
        if (std.mem.eql(u8, branch.name, "topic")) {
            saw_topic = true;
            try t.expect(!branch.current);
        }
    }
    try t.expect(saw_main and saw_topic);
    try f.git(&.{ "switch", "--", "topic" });
    var switched = try f.branches();
    defer switched.deinit();
    for (switched.items) |branch| {
        try t.expectEqual(std.mem.eql(u8, branch.name, "topic"), branch.current);
    }
    try f.git(&.{ "switch", "--", "main" });
    const merged = try f.run(&.{ "merge-base", "--is-ancestor", "refs/heads/topic", "HEAD" }, true);
    defer t.allocator.free(merged.bytes);
    try t.expectEqual(@as(u8, 0), merged.code);
    try f.git(&.{ "branch", "-d", "--", "topic" });
    var deleted = try f.branches();
    defer deleted.deinit();
    try t.expectEqual(@as(usize, 1), deleted.items.len);
    try t.expectEqualStrings("main", deleted.items[0].name);
}

test "fixture unmerged branch refuses safe delete; force delete is a distinct argv" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.commit("file.txt", "baseline\n");
    try f.git(&.{ "switch", "-c", "unmerged" });
    try f.commit("file.txt", "divergent\n");
    try f.git(&.{ "switch", "--", "main" });
    const ancestry = try f.run(&.{ "merge-base", "--is-ancestor", "refs/heads/unmerged", "HEAD" }, true);
    defer t.allocator.free(ancestry.bytes);
    try t.expectEqual(@as(u8, 1), ancestry.code);
    try t.expectError(error.GitFailed, f.git(&.{ "branch", "-d", "--", "unmerged" }));
    try f.git(&.{ "branch", "-D", "--", "unmerged" });
    var listing = try f.branches();
    defer listing.deinit();
    try t.expectEqual(@as(usize, 1), listing.items.len);
}

test "fixture lightweight tag creation and annotated classification" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.commit("file.txt", "baseline\n");
    try f.git(&.{ "tag", "--", "v1" });
    try f.git(&.{ "tag", "-a", "v2", "-m", "annotated fixture" });
    var listing = try f.tags();
    defer listing.deinit();
    try t.expectEqual(@as(usize, 2), listing.items.len);
    for (listing.items) |tag| {
        if (std.mem.eql(u8, tag.name, "v1")) try t.expect(tag.lightweight);
        if (std.mem.eql(u8, tag.name, "v2")) try t.expect(!tag.lightweight);
    }
    // Duplicate tag names are refused by Git, not overwritten.
    try t.expectError(error.GitFailed, f.git(&.{ "tag", "--", "v1" }));
}

test "fixture upstream tracking summaries round-trip ahead and gone" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.commit("file.txt", "baseline\n");
    try f.git(&.{ "config", "remote.origin.url", "/tmp/coral-refs-fixture-remote" });
    try f.git(&.{ "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*" });
    try f.git(&.{ "update-ref", "refs/remotes/origin/main", "HEAD" });
    try f.git(&.{ "branch", "--set-upstream-to=origin/main", "main" });
    try f.commit("file.txt", "ahead one\n");
    var ahead = try f.branches();
    defer ahead.deinit();
    try t.expectEqual(@as(usize, 2), ahead.items.len);
    for (ahead.items) |branch| {
        if (std.mem.eql(u8, branch.name, "main")) {
            try t.expectEqualStrings("refs/remotes/origin/main", branch.upstream.?);
            try t.expectEqual(@as(usize, 1), branch.track.ahead);
            try t.expectEqual(@as(usize, 0), branch.track.behind);
            try t.expect(!branch.track.gone);
        }
    }
    try f.git(&.{ "update-ref", "-d", "refs/remotes/origin/main" });
    var gone = try f.branches();
    defer gone.deinit();
    for (gone.items) |branch| {
        if (std.mem.eql(u8, branch.name, "main")) try t.expect(branch.track.gone);
    }
}

test "fixture worktree add/list/checked-out restriction and clean-only remove" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.commit("file.txt", "baseline\n");
    const wt = try f.path("wt");
    defer t.allocator.free(wt);
    try f.git(&.{ "worktree", "add", "-b", "wt-branch", "--", wt });
    var listing = try f.worktrees();
    defer listing.deinit();
    try t.expectEqual(@as(usize, 2), listing.items.len);
    try t.expect(listing.items[0].main);
    try t.expectEqualStrings(f.root, listing.items[0].path);
    try t.expectEqualStrings(wt, listing.items[1].path);
    try t.expectEqualStrings("refs/heads/wt-branch", listing.items[1].branch.?);
    try t.expectEqualStrings(wt, worktree.checkedOutPath(listing.items, "refs/heads/wt-branch").?);
    // A branch checked out in one worktree cannot be checked out in another.
    const wt2 = try f.path("wt2");
    defer t.allocator.free(wt2);
    try t.expectError(error.GitFailed, f.git(&.{ "worktree", "add", "--", wt2, "wt-branch" }));
    // Clean removal succeeds and frees the branch.
    try f.git(&.{ "worktree", "remove", "--", wt });
    var removed = try f.worktrees();
    defer removed.deinit();
    try t.expectEqual(@as(usize, 1), removed.items.len);
    try t.expect(worktree.checkedOutPath(removed.items, "refs/heads/wt-branch") == null);
    try f.git(&.{ "worktree", "add", "--", wt, "wt-branch" });
    // Dirty removal is refused without force.
    const dirty = try f.path("wt/dirty.txt");
    defer t.allocator.free(dirty);
    try f.write(dirty, "dirty");
    try t.expectError(error.GitFailed, f.git(&.{ "worktree", "remove", "--", wt }));
    try std.Io.Dir.cwd().deleteFile(f.io(), dirty);
    // Locked worktrees are refused until unlocked.
    try f.git(&.{ "worktree", "lock", wt, "--reason", "fixture lock" });
    var locked = try f.worktrees();
    defer locked.deinit();
    try t.expect(locked.items[1].locked);
    try t.expectEqualStrings("fixture lock", locked.items[1].lock_reason.?);
    try t.expectError(error.GitFailed, f.git(&.{ "worktree", "remove", "--", wt }));
    try f.git(&.{ "worktree", "unlock", wt });
    try f.git(&.{ "worktree", "remove", "--", wt });
}

test "fixture worktree add refuses existing non-empty paths (no overwrite)" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.commit("file.txt", "baseline\n");
    const wt = try f.path("wt");
    defer t.allocator.free(wt);
    const keep = try f.path("wt/keep.txt");
    defer t.allocator.free(keep);
    try std.Io.Dir.cwd().createDirPath(f.io(), wt);
    try f.write(keep, "do not overwrite");
    try t.expectError(error.GitFailed, f.git(&.{ "worktree", "add", "-b", "blocked", "--", wt }));
    const kept = try std.Io.Dir.cwd().openFile(f.io(), keep, .{});
    kept.close(f.io());
}

test "fixture unborn repository has empty branch/tag listings and zero worktree HEAD" {
    const f = try Fixture.init();
    defer f.deinit();
    var branches = try f.branches();
    defer branches.deinit();
    try t.expectEqual(@as(usize, 0), branches.items.len);
    var tags = try f.tags();
    defer tags.deinit();
    try t.expectEqual(@as(usize, 0), tags.items.len);
    var listing = try f.worktrees();
    defer listing.deinit();
    try t.expectEqual(@as(usize, 1), listing.items.len);
    try t.expect(listing.items[0].unborn());
    try t.expectEqualStrings("refs/heads/main", listing.items[0].branch.?);
    // Branch/tag writes on unborn HEAD fail closed; the controller pre-refuses.
    try t.expectError(error.GitFailed, f.git(&.{ "branch", "--", "too-early" }));
    try t.expectError(error.GitFailed, f.git(&.{ "tag", "--", "too-early" }));
}

test "fixture detached HEAD has no current branch marker" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.commit("file.txt", "baseline\n");
    try f.git(&.{ "checkout", "-q", "--detach", "HEAD" });
    var listing = try f.branches();
    defer listing.deinit();
    try t.expectEqual(@as(usize, 1), listing.items.len);
    try t.expect(!listing.items[0].current);
    const head = try f.output(&.{ "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal", "--ignore-submodules=all", "--no-renames" });
    defer t.allocator.free(head);
    var snapshot = try status.parse(t.allocator, head);
    defer snapshot.deinit();
    try t.expectEqual(refs.HeadState.detached, refs.headState(snapshot.head, snapshot.branch));
}

test "fixture hostile names are refused by Git as literal argv" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.commit("file.txt", "baseline\n");
    try t.expect(!refs.validName("bad name"));
    try t.expectError(error.GitFailed, f.git(&.{ "branch", "--", "bad name" }));
    try t.expect(!refs.validName("-leading"));
    try t.expectError(error.GitFailed, f.git(&.{ "branch", "--", "-leading" }));
    var listing = try f.branches();
    defer listing.deinit();
    try t.expectEqual(@as(usize, 1), listing.items.len);
}

test "fixture write classes: ref-only writes keep worktree bytes; switch and worktree writes change the tree" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.commit("file.txt", "baseline\n");
    const file = try f.path("file.txt");
    defer t.allocator.free(file);

    // Ref-only creation/deletion (branch, lightweight tag) must not touch the
    // worktree: these writes do not need an affected-tree barrier scope.
    try f.git(&.{ "branch", "--", "topic" });
    try f.git(&.{ "tag", "--", "v1" });
    try f.git(&.{ "branch", "-d", "--", "topic" });
    const after_refs = try f.read(file);
    defer t.allocator.free(after_refs);
    try t.expectEqualStrings("baseline\n", after_refs);

    // A switch rewrites tracked worktree bytes: the whole repository tree is
    // the affected scope, so open documents under it must refuse the write.
    try f.git(&.{ "switch", "-c", "divergent" });
    try f.commit("file.txt", "divergent\n");
    try f.git(&.{ "switch", "--", "main" });
    const back = try f.read(file);
    defer t.allocator.free(back);
    try t.expectEqualStrings("baseline\n", back);
    try f.git(&.{ "switch", "--", "divergent" });
    const switched = try f.read(file);
    defer t.allocator.free(switched);
    try t.expectEqualStrings("divergent\n", switched);
    try f.git(&.{ "switch", "--", "main" });

    // Worktree add creates a new destination tree; remove deletes exactly that
    // tree, never the main worktree's bytes.
    const wt = try f.path("wt");
    defer t.allocator.free(wt);
    try f.git(&.{ "worktree", "add", "-b", "wt-branch", "--", wt });
    const wt_file = try f.path("wt/file.txt");
    defer t.allocator.free(wt_file);
    const checked_out = try f.read(wt_file);
    defer t.allocator.free(checked_out);
    try t.expectEqualStrings("baseline\n", checked_out);
    try f.git(&.{ "worktree", "remove", "--", wt });
    const main_after = try f.read(file);
    defer t.allocator.free(main_after);
    try t.expectEqualStrings("baseline\n", main_after);
}
