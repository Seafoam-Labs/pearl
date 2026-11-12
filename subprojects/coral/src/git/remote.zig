//! Pure remote inspection and fetch/pull/push argv policy for the M4 native
//! Source Control workflows. No process spawning, GTK, filesystem or network
//! access happens here: the controller supplies env.zig's network prefix and
//! environment only after an explicit credential-helper disclosure, and the
//! read-only command.zig policy for inspection. Argv builders return the git
//! subcommand arguments (without a prefix); the caller prepends the chosen
//! prefix and owns the returned array. Element strings are either literals or
//! borrow the caller's remote/branch/refspec slices.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_remotes = 32;
pub const max_name_bytes = 256;
pub const max_url_bytes = 2048;
pub const max_branch_bytes = 256;
pub const max_input_bytes = 256 * 1024;

/// One configured remote. `push_url` falls back to `fetch_url` when Git reports
/// no separate pushurl. All slices are owned by the RemoteList arena.
pub const Remote = struct {
    name: []const u8,
    fetch_url: []const u8,
    push_url: []const u8,
};

pub const RemoteList = struct {
    arena: std.heap.ArenaAllocator,
    remotes: []Remote,

    /// All slices become invalid. Do not deinitialize copies of this owner.
    pub fn deinit(self: *RemoteList) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Coarse transport classification used for disclosure text. This is not an
/// authorization decision; the controller still requires explicit approval.
pub const UrlKind = enum { https, ssh, git, file, other };

pub const PullMode = enum { ff_only, merge, rebase };

pub const PushOptions = struct {
    /// Force pushes use --force-with-lease, never plain --force.
    force: bool = false,
    set_upstream: bool = false,
};

pub const Upstream = struct {
    remote: []const u8,
    branch: []const u8,

    /// remote and branch are independent allocations owned by the caller.
    pub fn deinit(self: Upstream, allocator: Allocator) void {
        allocator.free(self.remote);
        allocator.free(self.branch);
    }
};

pub const ParseError = Allocator.Error || error{
    InputTooLarge,
    InvalidUtf8,
    TooManyRemotes,
    InvalidRecord,
    NameTooLong,
    UrlTooLong,
    InvalidName,
    InvalidUrl,
    InvalidUpstream,
    InvalidBranch,
};

/// `git remote -v` (read-only; no network).
pub fn listArgs() []const []const u8 {
    return &.{ "remote", "-v" };
}

/// `git rev-parse --abbrev-ref HEAD` (read-only).
pub fn branchArgs() []const []const u8 {
    return &.{ "rev-parse", "--abbrev-ref", "HEAD" };
}

/// `git rev-parse --symbolic-full-name @{upstream}` (read-only; fails when the
/// current branch has no upstream).
pub fn upstreamArgs() []const []const u8 {
    return &.{ "rev-parse", "--symbolic-full-name", "@{upstream}" };
}

fn controlFree(bytes: []const u8) bool {
    for (bytes) |ch| {
        if (ch < 32 or ch == 127) return false;
    }
    return true;
}

/// Remote names are single tokens: no whitespace, controls or ':' (which Git
/// reserves for refspec/URL syntax). Bounded and non-empty.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    if (!controlFree(name)) return false;
    for (name) |ch| {
        if (ch == ' ' or ch == '\t' or ch == ':') return false;
    }
    return true;
}

/// Loose sanity for a configured remote URL: bounded, non-empty, no controls or
/// NUL. Scheme-specific trust is handled by the controller disclosure and, for
/// web permalinks, by history.validateHttpsUrl.
pub fn validUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > max_url_bytes) return false;
    if (!controlFree(url)) return false;
    if (std.mem.indexOfScalar(u8, url, ' ') != null) return false;
    return true;
}

pub fn classifyUrl(url: []const u8) UrlKind {
    if (std.mem.startsWith(u8, url, "https://")) return .https;
    if (std.mem.startsWith(u8, url, "ssh://")) return .ssh;
    if (std.mem.startsWith(u8, url, "git://")) return .git;
    if (std.mem.startsWith(u8, url, "file://")) return .file;
    // scp-like ssh syntax: user@host:path (no scheme, a single colon).
    if (std.mem.indexOfScalar(u8, url, '@') != null and std.mem.indexOfScalar(u8, url, ':') != null and
        std.mem.indexOf(u8, url, "://") == null) return .ssh;
    if (url.len > 0 and url[0] == '/') return .file;
    return .other;
}

/// Parse `git remote -v` output: `<name>\t<url> (fetch|push)` per line. Fails
/// closed on malformed records, controls, oversized input or too many remotes.
pub fn parseRemotes(allocator: Allocator, bytes: []const u8) ParseError!RemoteList {
    if (bytes.len > max_input_bytes) return error.InputTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    var result: RemoteList = .{ .arena = std.heap.ArenaAllocator.init(allocator), .remotes = &.{} };
    errdefer result.deinit();
    const a = result.arena.allocator();
    var list: std.ArrayList(Remote) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidRecord;
        const name = line[0..tab];
        const rest = line[tab + 1 ..];
        if (!validName(name)) return error.InvalidName;
        const is_fetch = std.mem.endsWith(u8, rest, " (fetch)");
        const is_push = std.mem.endsWith(u8, rest, " (push)");
        if (!is_fetch and !is_push) return error.InvalidRecord;
        const suffix_len: usize = if (is_fetch) " (fetch)".len else " (push)".len;
        const url = rest[0 .. rest.len - suffix_len];
        if (!validUrl(url)) return error.InvalidUrl;
        const owned_name = try a.dupe(u8, name);
        const owned_url = try a.dupe(u8, url);
        var found = false;
        for (list.items) |*entry| {
            if (std.mem.eql(u8, entry.name, owned_name)) {
                if (is_fetch) entry.fetch_url = owned_url else entry.push_url = owned_url;
                found = true;
                break;
            }
        }
        if (!found) {
            if (list.items.len >= max_remotes) return error.TooManyRemotes;
            // Both URLs default to the reported one; a later fetch/push line
            // for the same name overwrites only its own side.
            try list.append(a, .{ .name = owned_name, .fetch_url = owned_url, .push_url = owned_url });
        }
    }
    result.remotes = try list.toOwnedSlice(a);
    return result;
}

/// Trim a single trailing LF from a rev-parse result and validate the branch
/// token. Returns a slice borrowed from `bytes`; the caller owns/dupe it.
pub fn parseBranch(bytes: []const u8) ParseError![]const u8 {
    var text = bytes;
    if (text.len > 0 and text[text.len - 1] == '\n') text = text[0 .. text.len - 1];
    if (text.len == 0 or text.len > max_branch_bytes) return error.InvalidBranch;
    if (!controlFree(text)) return error.InvalidBranch;
    if (std.mem.indexOfScalar(u8, text, ' ') != null) return error.InvalidBranch;
    return text;
}

/// Parse `refs/remotes/<remote>/<branch...>` into remote + branch. The returned
/// slices are allocated from `allocator` (typically the controller arena).
pub fn parseUpstreamRef(allocator: Allocator, bytes: []const u8) ParseError!Upstream {
    var text = bytes;
    if (text.len > 0 and text[text.len - 1] == '\n') text = text[0 .. text.len - 1];
    const prefix = "refs/remotes/";
    if (!std.mem.startsWith(u8, text, prefix)) return error.InvalidUpstream;
    const rest = text[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidUpstream;
    const remote_name = rest[0..slash];
    const branch = rest[slash + 1 ..];
    if (!validName(remote_name)) return error.InvalidUpstream;
    if (branch.len == 0 or branch.len > max_branch_bytes or !controlFree(branch)) return error.InvalidUpstream;
    const owned_remote = try allocator.dupe(u8, remote_name);
    errdefer allocator.free(owned_remote);
    const owned_branch = try allocator.dupe(u8, branch);
    return .{ .remote = owned_remote, .branch = owned_branch };
}

/// `git fetch --progress --no-recurse-submodules <remote> [<refspec>]`.
/// Progress is forced so the controller can surface it from stderr.
pub fn fetchArgs(allocator: Allocator, remote_name: []const u8, refspec: ?[]const u8) Allocator.Error![][]const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "fetch", "--progress", "--no-recurse-submodules" });
    try args.append(allocator, remote_name);
    if (refspec) |spec| try args.append(allocator, spec);
    return args.toOwnedSlice(allocator);
}

/// `git pull --progress --no-recurse-submodules <mode> <remote> <branch>`.
/// ff-only is the default; merge/rebase must be chosen explicitly.
pub fn pullArgs(allocator: Allocator, remote_name: []const u8, branch: []const u8, mode: PullMode) Allocator.Error![][]const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "pull", "--progress", "--no-recurse-submodules" });
    switch (mode) {
        .ff_only => try args.append(allocator, "--ff-only"),
        .merge => try args.appendSlice(allocator, &.{ "--no-rebase", "--no-edit" }),
        .rebase => try args.append(allocator, "--rebase"),
    }
    try args.append(allocator, remote_name);
    try args.append(allocator, branch);
    return args.toOwnedSlice(allocator);
}

/// `git push --progress --no-recurse-submodules [--force-with-lease]
/// [--set-upstream] <remote> <refspec>`. Force never uses plain --force.
pub fn pushArgs(allocator: Allocator, remote_name: []const u8, refspec: []const u8, options: PushOptions) Allocator.Error![][]const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "push", "--progress", "--no-recurse-submodules" });
    if (options.force) try args.append(allocator, "--force-with-lease");
    if (options.set_upstream) try args.append(allocator, "--set-upstream");
    try args.append(allocator, remote_name);
    try args.append(allocator, refspec);
    return args.toOwnedSlice(allocator);
}

pub const PushBranchError = error{ DetachedHead, UnbornHead, InvalidBranch };

/// Push must target the CURRENT LOCAL branch, never the upstream's branch (the
/// upstream may name a differently named remote branch). Refuse detached HEAD
/// ("HEAD") and unborn (null) repositories. The returned refspec is fully
/// qualified so a same-named tag cannot be pushed by accident. Owned by caller.
pub fn pushRefspec(allocator: Allocator, branch: ?[]const u8) (Allocator.Error || PushBranchError)![]u8 {
    const name = branch orelse return error.UnbornHead;
    if (std.mem.eql(u8, name, "HEAD")) return error.DetachedHead;
    if (!validName(name)) return error.InvalidBranch;
    return std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
}

test "remote name/url sanity and transport classification" {
    const t = std.testing;
    try t.expect(validName("origin"));
    try t.expect(validName("up-stream_2.x"));
    try t.expect(!validName(""));
    try t.expect(!validName("bad name"));
    try t.expect(!validName("bad:name"));
    try t.expect(!validName("bad\tname"));
    try t.expect(validUrl("https://example.com/repo.git"));
    try t.expect(!validUrl(""));
    try t.expect(!validUrl("https://example.com/\nrepo"));
    try t.expectEqual(UrlKind.https, classifyUrl("https://github.com/o/r.git"));
    try t.expectEqual(UrlKind.ssh, classifyUrl("git@github.com:o/r.git"));
    try t.expectEqual(UrlKind.ssh, classifyUrl("ssh://git@github.com/o/r.git"));
    try t.expectEqual(UrlKind.git, classifyUrl("git://example.com/o/r.git"));
    try t.expectEqual(UrlKind.file, classifyUrl("file:///srv/repo.git"));
    try t.expectEqual(UrlKind.file, classifyUrl("/srv/repo.git"));
    try t.expectEqual(UrlKind.other, classifyUrl("ftp://example.com/o/r"));
}

test "parseRemotes groups fetch/push, honors separate pushurl and fails closed" {
    const t = std.testing;
    var list = try parseRemotes(t.allocator, "origin\tgit@github.com:o/r.git (fetch)\norigin\tgit@github.com:o/r.git (push)\nup\thttps://example.com/u.git (fetch)\nup\tssh://example.com/p.git (push)\n");
    defer list.deinit();
    try t.expectEqual(@as(usize, 2), list.remotes.len);
    try t.expectEqualStrings("origin", list.remotes[0].name);
    try t.expectEqualStrings("git@github.com:o/r.git", list.remotes[0].fetch_url);
    try t.expectEqualStrings("git@github.com:o/r.git", list.remotes[0].push_url);
    try t.expectEqualStrings("https://example.com/u.git", list.remotes[1].fetch_url);
    try t.expectEqualStrings("ssh://example.com/p.git", list.remotes[1].push_url);

    var empty = try parseRemotes(t.allocator, "");
    defer empty.deinit();
    try t.expectEqual(@as(usize, 0), empty.remotes.len);

    try t.expectError(error.InvalidRecord, parseRemotes(t.allocator, "origin no-tab (fetch)\n"));
    try t.expectError(error.InvalidRecord, parseRemotes(t.allocator, "origin\thttps://x (bogus)\n"));
    try t.expectError(error.InvalidName, parseRemotes(t.allocator, "bad name\thttps://x (fetch)\n"));
    try t.expectError(error.InvalidUrl, parseRemotes(t.allocator, "origin\thttps://x y (fetch)\n"));
    try t.expectError(error.InvalidRecord, parseRemotes(t.allocator, "origin\thttps://x\ny (fetch)\n"));
    try t.expectError(error.InvalidUtf8, parseRemotes(t.allocator, "origin\thttps://\xff (fetch)\n"));
}

test "parseRemotes enforces the remote count bound" {
    const t = std.testing;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(t.allocator);
    for (0..max_remotes + 1) |i| {
        const line = try std.fmt.allocPrint(t.allocator, "r{d}\thttps://example.com/{d}.git (fetch)\n", .{ i, i });
        defer t.allocator.free(line);
        try bytes.appendSlice(t.allocator, line);
    }
    try t.expectError(error.TooManyRemotes, parseRemotes(t.allocator, bytes.items));
}

test "branch and upstream ref parsing" {
    const t = std.testing;
    try t.expectEqualStrings("main", try parseBranch("main\n"));
    try t.expectEqualStrings("HEAD", try parseBranch("HEAD\n"));
    try t.expectError(error.InvalidBranch, parseBranch("\n"));
    try t.expectError(error.InvalidBranch, parseBranch("bad branch\n"));
    const up = try parseUpstreamRef(t.allocator, "refs/remotes/origin/topic/feature\n");
    defer up.deinit(t.allocator);
    try t.expectEqualStrings("origin", up.remote);
    try t.expectEqualStrings("topic/feature", up.branch);
    try t.expectError(error.InvalidUpstream, parseUpstreamRef(t.allocator, "refs/heads/main\n"));
    try t.expectError(error.InvalidUpstream, parseUpstreamRef(t.allocator, "refs/remotes/onlyremote\n"));
}

test "pushRefspec targets the current local branch and refuses detached/unborn" {
    const t = std.testing;
    const spec = try pushRefspec(t.allocator, "main");
    defer t.allocator.free(spec);
    try t.expectEqualStrings("refs/heads/main", spec);
    const topic = try pushRefspec(t.allocator, "topic/feature");
    defer t.allocator.free(topic);
    try t.expectEqualStrings("refs/heads/topic/feature", topic);
    try t.expectError(error.DetachedHead, pushRefspec(t.allocator, "HEAD"));
    try t.expectError(error.UnbornHead, pushRefspec(t.allocator, null));
    try t.expectError(error.InvalidBranch, pushRefspec(t.allocator, "bad name"));
    try t.expectError(error.InvalidBranch, pushRefspec(t.allocator, ""));
}

test "fetch/pull/push argv policy forces progress and safe force semantics" {
    const t = std.testing;
    const hasArg = struct {
        fn f(args: []const []const u8, needle: []const u8) bool {
            for (args) |arg| if (std.mem.eql(u8, arg, needle)) return true;
            return false;
        }
    }.f;
    const fetch = try fetchArgs(t.allocator, "origin", null);
    defer t.allocator.free(fetch);
    try t.expectEqualStrings("fetch", fetch[0]);
    try t.expectEqualStrings("--progress", fetch[1]);
    try t.expectEqualStrings("--no-recurse-submodules", fetch[2]);
    try t.expectEqualStrings("origin", fetch[3]);
    try t.expectEqual(@as(usize, 4), fetch.len);

    const ff = try pullArgs(t.allocator, "origin", "main", .ff_only);
    defer t.allocator.free(ff);
    try t.expect(hasArg(ff, "--ff-only"));
    const merge = try pullArgs(t.allocator, "origin", "main", .merge);
    defer t.allocator.free(merge);
    try t.expect(hasArg(merge, "--no-rebase"));
    const rebase = try pullArgs(t.allocator, "origin", "main", .rebase);
    defer t.allocator.free(rebase);
    try t.expect(hasArg(rebase, "--rebase"));

    const normal = try pushArgs(t.allocator, "origin", "main", .{});
    defer t.allocator.free(normal);
    try t.expect(!hasArg(normal, "--force-with-lease"));
    try t.expect(!hasArg(normal, "--force"));
    const force = try pushArgs(t.allocator, "origin", "main", .{ .force = true, .set_upstream = true });
    defer t.allocator.free(force);
    try t.expect(hasArg(force, "--force-with-lease"));
    try t.expect(hasArg(force, "--set-upstream"));
    // Plain --force must never be emitted, even alongside --force-with-lease.
    for (force) |arg| try t.expect(!std.mem.eql(u8, arg, "--force"));
}
