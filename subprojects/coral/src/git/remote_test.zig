//! Standalone libc-only tests: zig test src/git/remote_test.zig -lc
//!
//! Two layers:
//!  1. Pure URL-validation/parser tests (remote.zig + history.zig inline tests,
//!     plus cross-checks here). No GTK, no process spawning, no filesystem.
//!  2. Disposable local bare-remote fixtures that drive the real fetch/push argv
//!     builders against /usr/bin/git over the file protocol only. Every write is
//!     confined to a private std.testing.tmpDir; there is NO network access and
//!     no host repository is touched. The synchronous runner uses std.process
//!     with a complete environment allowlist (no shell, nothing inherited).
const std = @import("std");
const t = std.testing;
const remote = @import("remote.zig");
const history = @import("history.zig");
const io = std.testing.io;

test {
    _ = @import("remote.zig");
    _ = @import("history.zig");
}

// ---------------------------------------------------------------------------
// Pure cross-checks: remote classification feeds permalink construction, and
// every constructed permalink must pass the strict https launch guard.
// ---------------------------------------------------------------------------

test "remote URLs classify and feed validated host permalinks" {
    const oid = "0123456789abcdef0123456789abcdef01234567";
    const cases = [_]struct { url: []const u8, kind: remote.UrlKind, prefix: []const u8 }{
        .{ .url = "https://github.com/owner/repo.git", .kind = .https, .prefix = "https://github.com/owner/repo/blob/" },
        .{ .url = "git@github.com:owner/repo.git", .kind = .ssh, .prefix = "https://github.com/owner/repo/blob/" },
        .{ .url = "ssh://git@gitlab.com/group/proj.git", .kind = .ssh, .prefix = "https://gitlab.com/group/proj/-/blob/" },
        .{ .url = "https://codeberg.org/owner/repo.git", .kind = .https, .prefix = "https://codeberg.org/owner/repo/src/commit/" },
    };
    for (cases) |case| {
        try t.expectEqual(case.kind, remote.classifyUrl(case.url));
        const link = try history.buildPermalink(t.allocator, case.url, oid, "src/main.zig", 7);
        defer t.allocator.free(link);
        try t.expect(std.mem.startsWith(u8, link, case.prefix));
        try t.expect(std.mem.endsWith(u8, link, "/src/main.zig#L7"));
        try history.validateHttpsUrl(link);
    }
    // Non-web schemes are rejected as invalid URLs; a web URL on an unknown
    // host is rejected as unsupported. Neither is guessed into a permalink.
    try t.expectError(error.InvalidUrl, history.buildPermalink(t.allocator, "git://example.com/o/r.git", oid, "f", 1));
    try t.expectError(error.InvalidUrl, history.buildPermalink(t.allocator, "file:///srv/o/r.git", oid, "f", 1));
    try t.expectError(error.UnsupportedHost, history.buildPermalink(t.allocator, "https://example.com/o/r.git", oid, "f", 1));
}

test "parsed remote list yields force-push argv that never uses plain --force" {
    var list = try remote.parseRemotes(t.allocator, "origin\thttps://github.com/o/r.git (fetch)\norigin\tgit@github.com:o/r.git (push)\n");
    defer list.deinit();
    try t.expectEqual(@as(usize, 1), list.remotes.len);
    const push = try remote.pushArgs(t.allocator, list.remotes[0].name, "main", .{ .force = true });
    defer t.allocator.free(push);
    var saw_lease = false;
    for (push) |arg| {
        try t.expect(!std.mem.eql(u8, arg, "--force"));
        if (std.mem.eql(u8, arg, "--force-with-lease")) saw_lease = true;
    }
    try t.expect(saw_lease);
}

test "push targets the current local branch refspec; pull may follow upstream" {
    // The controller pushes refs/heads/<current local branch>, never the
    // upstream's branch name; pull is the operation allowed to follow upstream.
    const spec = try remote.pushRefspec(t.allocator, "feature");
    defer t.allocator.free(spec);
    try t.expectEqualStrings("refs/heads/feature", spec);
    const push = try remote.pushArgs(t.allocator, "origin", spec, .{});
    defer t.allocator.free(push);
    try t.expectEqualStrings("refs/heads/feature", push[push.len - 1]);
    try t.expectError(error.DetachedHead, remote.pushRefspec(t.allocator, "HEAD"));
    try t.expectError(error.UnbornHead, remote.pushRefspec(t.allocator, null));
}

// ---------------------------------------------------------------------------
// Disposable local bare-remote fixtures (file protocol only, no network).
// ---------------------------------------------------------------------------

const git_prefix = [_][]const u8{
    "/usr/bin/git", "--no-pager",           "--no-optional-locks", "--literal-pathspecs",
    "-c",           "core.fsmonitor=false", "-c",                  "core.untrackedCache=false",
};

fn gitAvailable() bool {
    return std.c.access("/usr/bin/git", 0) == 0;
}

/// Synchronous bounded git runner for fixtures. The file protocol is permitted
/// (GIT_ALLOW_PROTOCOL=file) so a local bare remote can be fetched/pushed without
/// any network. Identity is supplied via the environment; system/global config is
/// disabled and nothing is inherited from the editor. Returns owned stdout.
fn runGit(a: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv = try a.alloc([]const u8, git_prefix.len + args.len);
    defer a.free(argv);
    @memcpy(argv[0..git_prefix.len], &git_prefix);
    @memcpy(argv[git_prefix.len..], args);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("HOME", "/dev/null");
    try env.put("LC_ALL", "C");
    try env.put("LANG", "C");
    try env.put("TZ", "UTC");
    try env.put("GIT_TERMINAL_PROMPT", "0");
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_SYSTEM", "/dev/null");
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("GIT_ALLOW_PROTOCOL", "file");
    try env.put("GIT_AUTHOR_NAME", "Coral fixture");
    try env.put("GIT_AUTHOR_EMAIL", "coral-fixture@invalid");
    try env.put("GIT_COMMITTER_NAME", "Coral fixture");
    try env.put("GIT_COMMITTER_EMAIL", "coral-fixture@invalid");
    try env.put("GIT_EDITOR", "true");
    const result = try std.process.run(a, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = &env,
        .stdout_limit = .limited(1048576),
        .stderr_limit = .limited(65536),
    });
    defer a.free(result.stderr);
    if (!result.term.success()) {
        a.free(result.stdout);
        return error.GitFailed;
    }
    return result.stdout;
}

fn git(cwd: []const u8, args: []const []const u8) !void {
    const out = try runGit(t.allocator, cwd, args);
    t.allocator.free(out);
}

fn gitOut(cwd: []const u8, args: []const []const u8) ![]u8 {
    return runGit(t.allocator, cwd, args);
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    base: [:0]u8,
    bare: [:0]u8,
    work: [:0]u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const len = try tmp.dir.realPath(io, &buffer);
        const base = try t.allocator.dupeSentinel(u8, buffer[0..len], 0);
        errdefer t.allocator.free(base);
        const bare = try std.fmt.allocPrintSentinel(t.allocator, "{s}/bare.git", .{base}, 0);
        errdefer t.allocator.free(bare);
        const work = try std.fmt.allocPrintSentinel(t.allocator, "{s}/work", .{base}, 0);
        errdefer t.allocator.free(work);
        try tmp.dir.createDir(io, "bare.git", .fromMode(0o700));
        try tmp.dir.createDir(io, "work", .fromMode(0o700));
        var f = Fixture{ .tmp = tmp, .base = base, .bare = bare, .work = work };
        errdefer f.deinit();
        try git(f.bare, &.{ "init", "-q", "--bare", "--initial-branch=main" });
        try git(f.work, &.{ "init", "-q", "--initial-branch=main" });
        try git(f.work, &.{ "remote", "add", "origin", f.bare });
        return f;
    }
    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        t.allocator.free(self.base);
        t.allocator.free(self.bare);
        t.allocator.free(self.work);
    }
    fn commit(_: *Fixture, cwd: []const u8, message: []const u8) !void {
        try git(cwd, &.{ "-c", "commit.gpgsign=false", "commit", "-q", "--no-gpg-sign", "-m", message });
    }
    fn head(_: *Fixture, cwd: []const u8) ![]u8 {
        return trimmedRev(cwd, "HEAD");
    }
    fn revParse(_: *Fixture, cwd: []const u8, ref: []const u8) ![]u8 {
        return trimmedRev(cwd, ref);
    }
    /// Run a pure argv builder's result, then free the array.
    fn runArgs(_: *Fixture, cwd: []const u8, args: [][]const u8) !void {
        defer t.allocator.free(args);
        try git(cwd, args);
    }
};

fn writeFile(dir: []const u8, name: []const u8, bytes: []const u8) !void {
    const p = try std.fmt.allocPrintSentinel(t.allocator, "{s}/{s}", .{ dir, name }, 0);
    defer t.allocator.free(p);
    const fd = std.c.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o644));
    try t.expect(fd >= 0);
    defer _ = std.c.close(fd);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        try t.expect(n > 0);
        offset += @intCast(n);
    }
}

fn trimmedRev(cwd: []const u8, ref: []const u8) ![]u8 {
    const out = try gitOut(cwd, &.{ "rev-parse", ref });
    errdefer t.allocator.free(out);
    const trimmed = std.mem.trimEnd(u8, out, "\n");
    const owned = try t.allocator.dupe(u8, trimmed);
    t.allocator.free(out);
    return owned;
}

test "disposable bare remote: push publishes a ref and fetch retrieves it" {
    if (!gitAvailable()) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();

    try writeFile(f.work, "file.txt", "hello\n");
    try git(f.work, &.{ "add", "--", "file.txt" });
    try f.commit(f.work, "initial");
    const work_head = try f.head(f.work);
    defer t.allocator.free(work_head);

    // Push the CURRENT LOCAL branch via the controller's refspec builder, with
    // --set-upstream, exactly as remote_controller.startPush does.
    const refspec = try remote.pushRefspec(t.allocator, "main");
    defer t.allocator.free(refspec);
    try t.expectEqualStrings("refs/heads/main", refspec);
    try f.runArgs(f.work, try remote.pushArgs(t.allocator, "origin", refspec, .{ .set_upstream = true }));
    const bare_main = try f.revParse(f.bare, "refs/heads/main");
    defer t.allocator.free(bare_main);
    try t.expectEqualStrings(work_head, bare_main);
    // --set-upstream recorded the local branch's upstream config.
    const up_remote = try gitOut(f.work, &.{ "config", "branch.main.remote" });
    defer t.allocator.free(up_remote);
    try t.expectEqualStrings("origin", std.mem.trimEnd(u8, up_remote, "\n"));
    const up_merge = try gitOut(f.work, &.{ "config", "branch.main.merge" });
    defer t.allocator.free(up_merge);
    try t.expectEqualStrings("refs/heads/main", std.mem.trimEnd(u8, up_merge, "\n"));

    // A second repository fetches from the same bare remote (file protocol).
    const other = try std.fmt.allocPrintSentinel(t.allocator, "{s}/other", .{f.base}, 0);
    defer t.allocator.free(other);
    try f.tmp.dir.createDir(io, "other", .fromMode(0o700));
    try git(other, &.{ "init", "-q", "--initial-branch=main" });
    try git(other, &.{ "remote", "add", "origin", f.bare });
    try f.runArgs(other, try remote.fetchArgs(t.allocator, "origin", null));
    const tracking = try f.revParse(other, "refs/remotes/origin/main");
    defer t.allocator.free(tracking);
    try t.expectEqualStrings(work_head, tracking);
}

test "disposable bare remote: ff-only pull fast-forwards and refuses divergence" {
    if (!gitAvailable()) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();

    try writeFile(f.work, "file.txt", "one\n");
    try git(f.work, &.{ "add", "--", "file.txt" });
    try f.commit(f.work, "first");
    try f.runArgs(f.work, try remote.pushArgs(t.allocator, "origin", "main", .{}));

    // A second repo pulls ff-only to establish main.
    const other = try std.fmt.allocPrintSentinel(t.allocator, "{s}/other", .{f.base}, 0);
    defer t.allocator.free(other);
    try f.tmp.dir.createDir(io, "other", .fromMode(0o700));
    try git(other, &.{ "init", "-q", "--initial-branch=main" });
    try git(other, &.{ "remote", "add", "origin", f.bare });
    try f.runArgs(other, try remote.pullArgs(t.allocator, "origin", "main", .ff_only));
    const first_head = try f.head(f.work);
    defer t.allocator.free(first_head);
    const other_head = try f.head(other);
    defer t.allocator.free(other_head);
    try t.expectEqualStrings(first_head, other_head);

    // Advance the remote, then diverge locally; ff-only must refuse.
    try writeFile(f.work, "file.txt", "two\n");
    try git(f.work, &.{ "add", "--", "file.txt" });
    try f.commit(f.work, "second");
    try f.runArgs(f.work, try remote.pushArgs(t.allocator, "origin", "main", .{}));
    try writeFile(other, "other.txt", "divergent\n");
    try git(other, &.{ "add", "--", "other.txt" });
    try f.commit(other, "local divergence");
    const refused = try remote.pullArgs(t.allocator, "origin", "main", .ff_only);
    defer t.allocator.free(refused);
    try t.expectError(error.GitFailed, runGit(t.allocator, other, refused));
}

test "disposable bare remote: force-with-lease push updates a matching lease" {
    if (!gitAvailable()) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();

    try writeFile(f.work, "file.txt", "one\n");
    try git(f.work, &.{ "add", "--", "file.txt" });
    try f.commit(f.work, "first");
    try f.runArgs(f.work, try remote.pushArgs(t.allocator, "origin", "main", .{ .set_upstream = true }));

    // Rewrite history locally; the remote still matches the fetched lease.
    try writeFile(f.work, "file.txt", "rewritten\n");
    try git(f.work, &.{ "add", "--", "file.txt" });
    try git(f.work, &.{ "-c", "commit.gpgsign=false", "commit", "-q", "--no-gpg-sign", "--amend", "-m", "rewritten" });
    const amended = try f.head(f.work);
    defer t.allocator.free(amended);
    try f.runArgs(f.work, try remote.pushArgs(t.allocator, "origin", "main", .{ .force = true }));
    const bare_main = try f.revParse(f.bare, "refs/heads/main");
    defer t.allocator.free(bare_main);
    try t.expectEqualStrings(amended, bare_main);
}

test "disposable bare remote: history log and blame parse real repository output" {
    if (!gitAvailable()) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();

    try writeFile(f.work, "file.txt", "alpha\nbeta\n");
    try git(f.work, &.{ "add", "--", "file.txt" });
    try f.commit(f.work, "add file");
    try writeFile(f.work, "file.txt", "alpha\nbeta\ngamma\n");
    try git(f.work, &.{ "add", "--", "file.txt" });
    try f.commit(f.work, "extend file");

    const log_args = try history.logArgs(t.allocator, "file.txt", 50);
    defer {
        t.allocator.free(log_args[6]);
        t.allocator.free(log_args);
    }
    const log_bytes = try runGit(t.allocator, f.work, log_args);
    defer t.allocator.free(log_bytes);
    var log = try history.parseLog(t.allocator, log_bytes);
    defer log.deinit();
    try t.expectEqual(@as(usize, 2), log.entries.len);
    try t.expectEqualStrings("extend file", log.entries[0].subject);
    try t.expectEqualStrings("add file", log.entries[1].subject);
    try t.expect(history.validOid(log.entries[0].oid));

    const blame_args = try history.blameArgs(t.allocator, "HEAD", "file.txt");
    defer t.allocator.free(blame_args);
    const blame_bytes = try runGit(t.allocator, f.work, blame_args);
    defer t.allocator.free(blame_bytes);
    var blame = try history.parseBlame(t.allocator, blame_bytes);
    defer blame.deinit();
    try t.expectEqual(@as(usize, 3), blame.lines.len);
    try t.expectEqualStrings("alpha", blame.lines[0].text);
    try t.expectEqualStrings("gamma", blame.lines[2].text);
    try t.expectEqual(@as(usize, 3), blame.lines[2].line_no);
    // The newest line is blamed to the most recent commit.
    try t.expectEqualStrings(log.entries[0].oid, blame.lines[2].oid);

    // A permalink for the selected commit/line validates for an https remote.
    const link = try history.buildPermalink(t.allocator, "https://github.com/owner/repo.git", log.entries[0].oid, "file.txt", blame.lines[2].line_no);
    defer t.allocator.free(link);
    try history.validateHttpsUrl(link);
    try t.expect(std.mem.endsWith(u8, link, "/file.txt#L3"));
}
