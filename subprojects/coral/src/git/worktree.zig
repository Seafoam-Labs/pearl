//! Bounded, filesystem-independent parser for `git worktree list --porcelain -z`
//! and lexical validation of user-supplied worktree paths. Pure std plus the
//! shared read-only command policy's containment helper; no GTK, libc, process
//! or repository access. Existence, checked-out and clean-only enforcement
//! beyond these lexical rules belongs to worktree_controller.zig and Git itself.
//!
//! With -z every porcelain line is NUL-terminated and records are separated by
//! an empty line; paths are literal (no C-quoting) and may contain any byte
//! except NUL. Invalid UTF-8 paths, unknown lines, duplicate paths and truncated
//! framing fail closed as a whole.
const std = @import("std");
const command = @import("command.zig");
const Allocator = std.mem.Allocator;

pub const max_input_bytes = 1024 * 1024;
pub const max_worktrees = 1024;
pub const max_path_bytes = 4096;

pub const Worktree = struct {
    path: []const u8,
    /// HEAD oid; absent for bare repositories. All-zero means unborn HEAD.
    head: ?[]const u8,
    /// Full branch ref (refs/heads/…) when attached, null when detached/bare.
    branch: ?[]const u8,
    detached: bool,
    bare: bool,
    locked: bool,
    lock_reason: ?[]const u8,
    prunable: bool,
    prune_reason: ?[]const u8,
    /// Git lists the main worktree first; only it cannot be removed.
    main: bool,

    pub fn unborn(self: Worktree) bool {
        const oid = self.head orelse return false;
        for (oid) |ch| if (ch != '0') return false;
        return oid.len == 40 or oid.len == 64;
    }
};

pub const List = struct {
    arena: std.heap.ArenaAllocator,
    items: []Worktree,

    /// All slices become invalid. Do not deinitialize copies of this owner.
    pub fn deinit(self: *List) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ParseError = Allocator.Error || error{
    InputTooLarge,
    TooManyWorktrees,
    InvalidUtf8,
    TruncatedRecord,
    InvalidRecord,
    InvalidPath,
    InvalidOid,
    InvalidRef,
    DuplicatePath,
    UnknownLine,
};

pub fn parseList(allocator: Allocator, bytes: []const u8) ParseError!List {
    if (bytes.len > max_input_bytes) return error.InputTooLarge;
    var result: List = .{ .arena = std.heap.ArenaAllocator.init(allocator), .items = &.{} };
    errdefer result.deinit();
    const a = result.arena.allocator();
    var items: std.ArrayList(Worktree) = .empty;
    var current: ?Worktree = null;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, offset, 0) orelse return error.TruncatedRecord;
        const line = bytes[offset..end];
        offset = end + 1;
        if (line.len == 0) {
            const finished = current orelse return error.InvalidRecord;
            current = null;
            if (items.items.len == max_worktrees) return error.TooManyWorktrees;
            for (items.items) |existing| if (std.mem.eql(u8, existing.path, finished.path)) return error.DuplicatePath;
            try items.append(a, finished);
            continue;
        }
        if (std.mem.startsWith(u8, line, "worktree ")) {
            if (current != null) return error.InvalidRecord;
            const path = line["worktree ".len..];
            try validPathBytes(path);
            current = .{
                .path = try a.dupe(u8, path),
                .head = null,
                .branch = null,
                .detached = false,
                .bare = false,
                .locked = false,
                .lock_reason = null,
                .prunable = false,
                .prune_reason = null,
                .main = items.items.len == 0,
            };
            continue;
        }
        var entry = &(current orelse return error.InvalidRecord);
        if (std.mem.startsWith(u8, line, "HEAD ")) {
            const oid = line["HEAD ".len..];
            if (!validOid(oid)) return error.InvalidOid;
            if (entry.head != null) return error.InvalidRecord;
            entry.head = try a.dupe(u8, oid);
        } else if (std.mem.startsWith(u8, line, "branch ")) {
            const ref = line["branch ".len..];
            if (!std.mem.startsWith(u8, ref, "refs/heads/") or ref.len > max_path_bytes) return error.InvalidRef;
            if (entry.branch != null or entry.detached) return error.InvalidRecord;
            entry.branch = try a.dupe(u8, ref);
        } else if (std.mem.eql(u8, line, "detached")) {
            if (entry.detached or entry.branch != null) return error.InvalidRecord;
            entry.detached = true;
        } else if (std.mem.eql(u8, line, "bare")) {
            if (entry.bare) return error.InvalidRecord;
            entry.bare = true;
        } else if (std.mem.eql(u8, line, "locked") or std.mem.startsWith(u8, line, "locked ")) {
            if (entry.locked) return error.InvalidRecord;
            entry.locked = true;
            entry.lock_reason = if (line.len > "locked ".len) try a.dupe(u8, line["locked ".len..]) else null;
        } else if (std.mem.eql(u8, line, "prunable") or std.mem.startsWith(u8, line, "prunable ")) {
            if (entry.prunable) return error.InvalidRecord;
            entry.prunable = true;
            entry.prune_reason = if (line.len > "prunable ".len) try a.dupe(u8, line["prunable ".len..]) else null;
        } else return error.UnknownLine;
    }
    if (current != null) return error.TruncatedRecord;
    result.items = try items.toOwnedSlice(a);
    return result;
}

fn validOid(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

fn validPathBytes(path: []const u8) ParseError!void {
    if (path.len == 0 or path.len > max_path_bytes - 1) return error.InvalidPath;
    if (path[0] != '/') return error.InvalidPath;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidUtf8;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidPath;
    }
}

pub fn findPath(items: []const Worktree, path: []const u8) ?*const Worktree {
    for (items) |*item| if (std.mem.eql(u8, item.path, path)) return item;
    return null;
}

/// Path of the worktree that already has this full branch ref checked out.
/// Git permits a branch in only one worktree; callers refuse before writing.
pub fn checkedOutPath(items: []const Worktree, branch_ref: []const u8) ?[]const u8 {
    for (items) |item| {
        if (item.branch) |ref| if (std.mem.eql(u8, ref, branch_ref)) return item.path;
    }
    return null;
}

pub const PathError = error{
    NotAbsolute,
    InvalidPath,
    PathTooLong,
    InvalidUtf8,
    OutsideRoot,
    RootItself,
    RepositoryItself,
    GitMetadataPath,
    GitComponent,
};

/// Lexical validation of a requested new worktree path against the owning
/// workspace root and the selected repository's metadata directories. This is
/// containment policy, not symlink authorization: no filesystem resolution runs
/// here. Git additionally refuses existing non-empty paths at write time, and
/// the controller refuses already-registered worktree paths.
pub fn validatePath(owner: []const u8, repo_path: []const u8, gitdir: []const u8, commondir: []const u8, input: []const u8) PathError!void {
    if (input.len == 0) return error.InvalidPath;
    if (input.len > max_path_bytes - 1) return error.PathTooLong;
    if (input[0] != '/') return error.NotAbsolute;
    if (std.mem.indexOfScalar(u8, input, 0) != null) return error.InvalidPath;
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    if (input.len > 1 and input[input.len - 1] == '/') return error.InvalidPath;
    var components = std.mem.splitScalar(u8, input[1..], '/');
    var git_component = false;
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidPath;
        if (std.mem.eql(u8, component, ".git")) git_component = true;
    }
    if (!command.contains(owner, input)) return error.OutsideRoot;
    if (std.mem.eql(u8, owner, input)) return error.RootItself;
    if (std.mem.eql(u8, repo_path, input)) return error.RepositoryItself;
    if (gitdir.len != 0 and command.contains(gitdir, input)) return error.GitMetadataPath;
    if (commondir.len != 0 and command.contains(commondir, input)) return error.GitMetadataPath;
    if (git_component) return error.GitComponent;
}

test "parseList reads main, linked, detached, locked, prunable, unborn and bare records" {
    const t = std.testing;
    const oid = "0123456789abcdef0123456789abcdef01234567";
    const input = "worktree /repo\x00HEAD " ++ oid ++ "\x00branch refs/heads/main\x00\x00" ++
        "worktree /repo-wt\x00HEAD " ++ oid ++ "\x00detached\x00locked keep me\x00\x00" ++
        "worktree /repo-gone\x00HEAD " ++ oid ++ "\x00branch refs/heads/topic\x00prunable gitdir file points to non-existent location\x00\x00" ++
        "worktree /repo-unborn\x00HEAD 0000000000000000000000000000000000000000\x00branch refs/heads/main\x00\x00" ++
        "worktree /repo-bare\x00bare\x00\x00";
    var parsed = try parseList(t.allocator, input);
    defer parsed.deinit();
    try t.expectEqual(@as(usize, 5), parsed.items.len);
    const main = parsed.items[0];
    try t.expect(main.main and !main.bare and !main.detached);
    try t.expectEqualStrings("/repo", main.path);
    try t.expectEqualStrings("refs/heads/main", main.branch.?);
    try t.expect(!main.unborn());
    const linked = parsed.items[1];
    try t.expect(!linked.main and linked.detached and linked.locked);
    try t.expectEqualStrings("keep me", linked.lock_reason.?);
    try t.expect(linked.branch == null);
    const gone = parsed.items[2];
    try t.expect(gone.prunable);
    try t.expect(std.mem.startsWith(u8, gone.prune_reason.?, "gitdir"));
    try t.expect(parsed.items[3].unborn());
    try t.expect(parsed.items[4].bare and parsed.items[4].head == null);
}

test "parseList empty capture is an empty listing" {
    var parsed = try parseList(std.testing.allocator, "");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.items.len);
}

test "parseList fails closed on malformed framing and unknown lines" {
    const t = std.testing;
    const oid = "0123456789abcdef0123456789abcdef01234567";
    try t.expectError(error.TruncatedRecord, parseList(t.allocator, "worktree /repo\x00HEAD " ++ oid));
    try t.expectError(error.TruncatedRecord, parseList(t.allocator, "worktree /repo\x00HEAD " ++ oid ++ "\x00"));
    try t.expectError(error.InvalidRecord, parseList(t.allocator, "HEAD " ++ oid ++ "\x00\x00"));
    try t.expectError(error.InvalidRecord, parseList(t.allocator, "\x00"));
    try t.expectError(error.UnknownLine, parseList(t.allocator, "worktree /repo\x00surprise yes\x00\x00"));
    try t.expectError(error.InvalidPath, parseList(t.allocator, "worktree relative\x00\x00"));
    try t.expectError(error.InvalidPath, parseList(t.allocator, "worktree /repo/../x\x00\x00"));
    try t.expectError(error.InvalidUtf8, parseList(t.allocator, "worktree /\xff\x00\x00"));
    try t.expectError(error.InvalidOid, parseList(t.allocator, "worktree /repo\x00HEAD zzz\x00\x00"));
    try t.expectError(error.InvalidRef, parseList(t.allocator, "worktree /repo\x00branch refs/tags/v1\x00\x00"));
    try t.expectError(error.DuplicatePath, parseList(t.allocator, "worktree /repo\x00\x00worktree /repo\x00\x00"));
    try t.expectError(error.InvalidRecord, parseList(t.allocator, "worktree /repo\x00worktree /other\x00\x00"));
    const big = try t.allocator.alloc(u8, max_input_bytes + 1);
    defer t.allocator.free(big);
    @memset(big, 'x');
    try t.expectError(error.InputTooLarge, parseList(t.allocator, big));
}

test "findPath and checkedOutPath locate registered worktrees" {
    const t = std.testing;
    const oid = "0123456789abcdef0123456789abcdef01234567";
    var parsed = try parseList(t.allocator, "worktree /repo\x00HEAD " ++ oid ++ "\x00branch refs/heads/main\x00\x00" ++
        "worktree /wt\x00HEAD " ++ oid ++ "\x00branch refs/heads/topic\x00\x00");
    defer parsed.deinit();
    try t.expectEqualStrings("/wt", findPath(parsed.items, "/wt").?.path);
    try t.expect(findPath(parsed.items, "/missing") == null);
    try t.expectEqualStrings("/repo", checkedOutPath(parsed.items, "refs/heads/main").?);
    try t.expectEqualStrings("/wt", checkedOutPath(parsed.items, "refs/heads/topic").?);
    try t.expect(checkedOutPath(parsed.items, "refs/heads/free") == null);
}

test "validatePath enforces root containment and metadata exclusions" {
    const t = std.testing;
    const owner = "/work/project";
    const repo = "/work/project/repo";
    const gitdir = "/work/project/repo/.git";
    const common = "/work/project/repo/.git";
    try validatePath(owner, repo, gitdir, common, "/work/project/wt");
    try validatePath(owner, repo, gitdir, common, "/work/project/nested/wt-2");
    try t.expectError(error.NotAbsolute, validatePath(owner, repo, gitdir, common, "wt"));
    try t.expectError(error.InvalidPath, validatePath(owner, repo, gitdir, common, ""));
    try t.expectError(error.InvalidPath, validatePath(owner, repo, gitdir, common, "/work/project/wt/"));
    try t.expectError(error.InvalidPath, validatePath(owner, repo, gitdir, common, "/work/project/../wt"));
    try t.expectError(error.InvalidPath, validatePath(owner, repo, gitdir, common, "/work//project/wt"));
    try t.expectError(error.InvalidPath, validatePath(owner, repo, gitdir, common, "/work/project/./wt"));
    try t.expectError(error.InvalidUtf8, validatePath(owner, repo, gitdir, common, "/work/project/\xff"));
    try t.expectError(error.OutsideRoot, validatePath(owner, repo, gitdir, common, "/work/elsewhere/wt"));
    try t.expectError(error.OutsideRoot, validatePath(owner, repo, gitdir, common, "/work/project-other/wt"));
    try t.expectError(error.RootItself, validatePath(owner, repo, gitdir, common, "/work/project"));
    try t.expectError(error.RepositoryItself, validatePath(owner, repo, gitdir, common, "/work/project/repo"));
    try t.expectError(error.GitMetadataPath, validatePath(owner, repo, gitdir, common, "/work/project/repo/.git/wt"));
    try t.expectError(error.GitComponent, validatePath(owner, repo, gitdir, common, "/work/project/wt/.git"));
    var long: [max_path_bytes + 1]u8 = undefined;
    long[0] = '/';
    @memset(long[1..], 'a');
    try t.expectError(error.PathTooLong, validatePath(owner, repo, gitdir, common, &long));
    // Metadata outside the owning root can never authorize an outside path:
    // root containment is checked first.
    try t.expectError(error.OutsideRoot, validatePath(owner, repo, "/elsewhere/meta", "/elsewhere/meta", "/elsewhere/meta/wt"));
    // Empty metadata strings must not match every absolute path.
    try validatePath(owner, repo, "", "", "/work/project/wt");
}
