//! M4 commit/uncommit backend: pure Git command builders/parsers plus worker-only
//! write transactions. Read-only preparation/recheck uses the locked-down policy
//! in command.zig (via index_transaction.runGit). Repository writes use the
//! caller-supplied write policy (env.zig write prefix/environment), so configured
//! hooks and signing may execute with the user's permissions after disclosure.
//! No shell, no PATH lookup, no inherited environment, no network command.
//!
//! The write runner is policy-agnostic: the controller authorizes the exact
//! prefix/environment (env.write_prefix / env.write) and passes them in. This
//! keeps the backend free of GTK/App dependencies so it can be tested in
//! disposable repositories. Linux /proc and libc are required by the transport.
const std = @import("std");
const transport = @import("../language/transport.zig");
const command = @import("command.zig");
const status = @import("status.zig");
const tx = @import("index_transaction.zig");
const os = @import("index_transaction_os.zig");
const conflict = @import("conflict.zig");

pub const Cancel = std.atomic.Value(bool);
pub const Environment = transport.Environment;
/// Complete write allowlist plus the fixed argv prefix. Supplied by the controller
/// from env.zig; never inherited or merged with the editor environment.
pub const WritePolicy = struct {
    prefix: []const []const u8,
    environment: []const Environment,
};
pub const Run = struct { bytes: []const u8, code: u8 };

pub const max_capture = 1024 * 1024;
pub const max_message_bytes = 64 * 1024;
pub const write_output_bytes = 64 * 1024;
pub const write_timeout_ms: u32 = 15000;

// --- Fixed command builders (literal argv, never shell) ---------------------

/// Staged-only commit. Message arrives on stdin; no -a, no --allow-empty, no
/// --no-verify (hooks run and are disclosed). GIT_EDITOR is irrelevant with -F.
pub const commit_args: []const []const u8 = &.{ "commit", "-F", "-" };
/// Explicit separate command: stage every tracked modification/deletion. Untracked
/// files are never added. No pathspec means the whole tracked tree.
pub const stage_tracked_args: []const []const u8 = &.{ "add", "-u" };
/// Uncommit moves HEAD back to the reviewed parent, keeping index and worktree
/// byte-for-byte (soft-reset equivalent). It uses a compare-and-swap ref update:
/// `update-ref HEAD <parent> <expected>` only succeeds while HEAD still equals the
/// reviewed expected_head, so a concurrent HEAD move fails closed instead of
/// re-resolving HEAD~1 to a different commit. update-ref never touches the index
/// or worktree and is never --hard.
pub fn uncommitArgs(parent_oid: []const u8, expected_head: []const u8) [4][]const u8 {
    return .{ "update-ref", "HEAD", parent_oid, expected_head };
}

/// In-progress operation state refs (conflict.zig). Presence of any of these, or
/// of a rebase-merge/rebase-apply directory, means an operation is in progress.
pub const operation_order = [_]conflict.Operation{ .merge, .rebase, .cherry_pick, .revert };
pub fn operationArgs(buf: *[4][]const u8, operation: conflict.Operation) []const []const u8 {
    buf.* = .{ "rev-parse", "--verify", "--quiet", operation.stateRef().? };
    return buf[0..4];
}

/// Read-only preparation: branch/HEAD/upstream plus tracked staged/unstaged counts.
/// Untracked files are excluded (they are never committed by a staged-only commit).
pub const status_args: []const []const u8 = &.{ "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=no", "--ignore-submodules=all", "--no-renames" };
/// Exact staged paths and statuses, NUL-framed, renames shown as add/delete.
pub const name_status_args: []const []const u8 = &.{ "diff", "--cached", "--name-status", "-z", "--no-renames", "--no-relative", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all" };
/// Human-readable staged stat; its final line is the change summary.
pub const stat_args: []const []const u8 = &.{ "diff", "--cached", "--stat", "--no-color", "--no-renames", "--no-relative", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all" };
/// HEAD oid followed by its parent oids on one line (checked HEAD for uncommit).
pub const parents_args: []const []const u8 = &.{ "rev-list", "--parents", "-n", "1", "HEAD" };
pub const head_args: []const []const u8 = &.{ "rev-parse", "--verify", "--quiet", "HEAD" };
pub fn ancestorArgs(upstream: []const u8) [4][]const u8 {
    return .{ "merge-base", "--is-ancestor", "HEAD", upstream };
}

// --- Pure parsers -----------------------------------------------------------

pub const StagedFile = struct { status: u8, path: []const u8 };
pub const Parents = struct { head: []const u8, parents: []const []const u8 };
pub const Counts = struct { staged: usize, unstaged: usize, unmerged: usize };

/// Tracked staged/unstaged/unmerged counts from a porcelain v2 snapshot. An entry
/// may be both staged and unstaged (e.g. "MM"); it counts toward both. Untracked
/// and ignored entries never count. Unmerged entries are counted separately.
pub fn counts(snapshot: *const status.Snapshot) Counts {
    var result: Counts = .{ .staged = 0, .unstaged = 0, .unmerged = 0 };
    for (snapshot.entries) |entry| {
        if (entry.kind == .unmerged) {
            result.unmerged += 1;
            continue;
        }
        if (entry.kind == .untracked or entry.kind == .ignored) continue;
        if (entry.index != '.' and entry.index != ' ') result.staged += 1;
        if (entry.worktree != '.' and entry.worktree != ' ') result.unstaged += 1;
    }
    return result;
}

/// Parse `diff --cached --name-status -z --no-renames`: repeated "X\0path\0".
/// Paths are duplicated into the allocator so the result outlives the capture.
/// Unknown status letters and malformed framing fail closed.
pub fn parseNameStatus(a: std.mem.Allocator, bytes: []const u8) ![]StagedFile {
    if (bytes.len > max_capture) return error.InputTooLarge;
    var list: std.ArrayList(StagedFile) = .empty;
    errdefer list.deinit(a);
    var i: usize = 0;
    while (i < bytes.len) {
        if (i + 1 >= bytes.len) return error.TruncatedRecord;
        const letter = bytes[i];
        if (std.mem.indexOfScalar(u8, "AMDT", letter) == null) return error.InvalidStatus;
        if (bytes[i + 1] != 0) return error.InvalidRecord;
        i += 2;
        const nul = std.mem.indexOfScalarPos(u8, bytes, i, 0) orelse return error.TruncatedRecord;
        const path = bytes[i..nul];
        try validRelPath(path);
        try list.append(a, .{ .status = letter, .path = try a.dupe(u8, path) });
        i = nul + 1;
    }
    return list.toOwnedSlice(a);
}

/// Parse `rev-list --parents -n 1 HEAD`: "<head> <parent>...\n". Head and parents
/// are duplicated into the allocator. Zero parents means an initial commit; two
/// or more means a merge. Oids must be lowercase hex (SHA-1 or SHA-256).
pub fn parseParents(a: std.mem.Allocator, bytes: []const u8) !Parents {
    if (bytes.len > 16384) return error.InputTooLarge;
    const line = std.mem.trimEnd(u8, bytes, "\n");
    if (line.len == 0 or std.mem.indexOfScalar(u8, line, '\n') != null) return error.InvalidGitOutput;
    var parts = std.mem.splitScalar(u8, line, ' ');
    const head = parts.next() orelse return error.InvalidGitOutput;
    try validOid(head);
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    while (parts.next()) |parent| {
        try validOid(parent);
        try list.append(a, try a.dupe(u8, parent));
    }
    return .{ .head = try a.dupe(u8, head), .parents = try list.toOwnedSlice(a) };
}

/// The final non-empty line of `diff --cached --stat` is the change summary
/// ("N files changed, ..."). Returns a borrowed slice of the capture ("" when
/// there is no staged change); the caller duplicates it if it must outlive it.
pub fn parseStatSummary(bytes: []const u8) ![]const u8 {
    if (bytes.len > max_capture) return error.InputTooLarge;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var last: []const u8 = "";
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0) last = trimmed;
    }
    return last;
}

/// Validate a commit message before it is sent to stdin. Empty/whitespace-only
/// messages are refused (Git would abort anyway); NUL and oversize are refused.
pub fn validateMessage(message: []const u8) !void {
    if (std.mem.trim(u8, message, " \t\r\n").len == 0) return error.EmptyMessage;
    if (message.len > max_message_bytes - 1) return error.MessageTooLarge;
    if (std.mem.indexOfScalar(u8, message, 0) != null) return error.InvalidMessage;
}

// --- Read-only recheck (worker-only, locked-down policy) --------------------

fn read(a: std.mem.Allocator, cwd: []const u8, cancel: *Cancel, args: []const []const u8, limit: usize, allow_one: bool) !Run {
    const r = try tx.runGit(a, cwd, null, null, null, null, cancel, args, "", limit, allow_one);
    return .{ .bytes = r.bytes, .code = r.code };
}

fn cancelled(cancel: *Cancel) !void {
    if (cancel.load(.acquire)) return error.Cancelled;
}

/// Current HEAD oid, or null for an unborn HEAD (initial commit pending).
pub fn headOid(a: std.mem.Allocator, cwd: []const u8, cancel: *Cancel) !?[]const u8 {
    const r = try read(a, cwd, cancel, head_args, 1024, true);
    defer a.free(r.bytes);
    if (r.code == 1) return null;
    const oid = std.mem.trimEnd(u8, r.bytes, "\n");
    try validOid(oid);
    return try a.dupe(u8, oid);
}

/// Revalidate the exact reviewed staged set immediately before committing. The
/// raw name-status capture must match byte-for-byte and HEAD must not have moved.
pub fn recheckCommit(a: std.mem.Allocator, cwd: []const u8, cancel: *Cancel, expected_head: ?[]const u8, staged_bytes: []const u8) !void {
    try cancelled(cancel);
    const head = try headOid(a, cwd, cancel);
    defer if (head) |h| a.free(h);
    if (expected_head) |expected| {
        if (head == null or !std.mem.eql(u8, head.?, expected)) return error.StaleSnapshot;
    } else if (head != null) return error.StaleSnapshot;
    const ns = try read(a, cwd, cancel, name_status_args, max_capture, false);
    defer a.free(ns.bytes);
    if (ns.bytes.len == 0) return error.EmptyStaged;
    if (!std.mem.eql(u8, ns.bytes, staged_bytes)) return error.StaleSnapshot;
    try cancelled(cancel);
}

/// Revalidate HEAD, its single parent and publication state before a soft reset.
pub fn recheckUncommit(a: std.mem.Allocator, cwd: []const u8, gitdir: []const u8, cancel: *Cancel, expected_head: []const u8, parent_oid: []const u8, upstream: ?[]const u8) !void {
    try cancelled(cancel);
    if (try detectOperation(a, cwd, gitdir, cancel) != .none) return error.OperationInProgress;
    const r = try read(a, cwd, cancel, parents_args, 16384, false);
    defer a.free(r.bytes);
    const parents = try parseParents(a, r.bytes);
    defer {
        for (parents.parents) |p| a.free(p);
        a.free(parents.parents);
        a.free(parents.head);
    }
    if (!std.mem.eql(u8, parents.head, expected_head)) return error.StaleSnapshot;
    if (parents.parents.len != 1) return error.InitialOrMergeCommit;
    if (!std.mem.eql(u8, parents.parents[0], parent_oid)) return error.StaleSnapshot;
    if (upstream) |up| {
        const args = ancestorArgs(up);
        const mb = try read(a, cwd, cancel, &args, 1024, true);
        defer a.free(mb.bytes);
        if (mb.code == 0) return error.PublishedHead;
        if (mb.code != 1) return error.GitFailed;
    }
    try cancelled(cancel);
}

/// Revalidate HEAD before staging tracked changes (broad index write).
pub fn recheckHead(a: std.mem.Allocator, cwd: []const u8, cancel: *Cancel, expected_head: ?[]const u8) !void {
    try cancelled(cancel);
    const head = try headOid(a, cwd, cancel);
    defer if (head) |h| a.free(h);
    if (expected_head) |expected| {
        if (head == null or !std.mem.eql(u8, head.?, expected)) return error.StaleSnapshot;
    } else if (head != null) return error.StaleSnapshot;
}

/// Revalidate HEAD and refuse staging while any unmerged conflict remains, so
/// `git add -u` can never stage conflict markers and silently resolve a conflict.
pub fn recheckStage(a: std.mem.Allocator, cwd: []const u8, cancel: *Cancel, expected_head: ?[]const u8) !void {
    try recheckHead(a, cwd, cancel, expected_head);
    const r = try read(a, cwd, cancel, status_args, max_capture, false);
    defer a.free(r.bytes);
    var snapshot = try status.parse(a, r.bytes);
    defer snapshot.deinit();
    if (counts(&snapshot).unmerged != 0) return error.UnmergedConflict;
}

/// Read-only detection of an in-progress merge/rebase/cherry-pick/revert. Checks
/// the gitdir state refs and the rebase-merge/rebase-apply directories (an
/// interrupted rebase may lack REBASE_HEAD). Worker-only; never writes.
pub fn detectOperation(a: std.mem.Allocator, cwd: []const u8, gitdir: []const u8, cancel: *Cancel) !conflict.Operation {
    for (operation_order) |operation| {
        var buf: [4][]const u8 = undefined;
        const args = operationArgs(&buf, operation);
        const r = try read(a, cwd, cancel, args, 1024, true);
        defer a.free(r.bytes);
        if (r.code == 0) return operation;
        if (r.code != 1) return error.GitFailed;
    }
    if (try rebaseDirExists(a, gitdir, cancel)) return .rebase;
    return .none;
}

fn rebaseDirExists(a: std.mem.Allocator, gitdir: []const u8, cancel: *Cancel) !bool {
    try cancelled(cancel);
    const z = try a.dupeSentinel(u8, gitdir, 0);
    defer a.free(z);
    const fd = os.open(z, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC);
    if (fd < 0) return error.GitFailed;
    defer _ = os.close(fd);
    for ([_][]const u8{ "rebase-merge", "rebase-apply" }) |name| {
        const nz = try a.dupeSentinel(u8, name, 0);
        defer a.free(nz);
        var st: os.struct_stat = undefined;
        if (os.fstatat(fd, nz, &st, os.AT_SYMLINK_NOFOLLOW) == 0 and st.st_mode & os.S_IFMT == os.S_IFDIR) return true;
    }
    return false;
}

// --- Write transactions (worker-only, disclosed write policy) ---------------

/// Synchronous worker wrapper around the bounded stdio transport. All exits drain
/// and reap before returning. The complete environment allowlist and fixed argv
/// prefix come from the caller's WritePolicy; nothing is inherited. No shell.
pub fn runWrite(a: std.mem.Allocator, cwd: []const u8, cancel: *Cancel, policy: WritePolicy, args: []const []const u8, input: []const u8, limit: usize, timeout_ms: u32) !Run {
    try cancelled(cancel);
    if (input.len > max_message_bytes or limit > max_capture) return error.TooLarge;
    if (cwd.len == 0 or cwd[0] != '/') return error.InvalidConfig;
    const output_capacity = try std.math.ceilPowerOfTwo(usize, @max(@as(usize, 4096), limit));
    const argv = try a.alloc([]const u8, policy.prefix.len + args.len);
    defer a.free(argv);
    @memcpy(argv[0..policy.prefix.len], policy.prefix);
    @memcpy(argv[policy.prefix.len..], args);
    const job = try transport.start(a, .{
        .authorization = .approved,
        .argv = argv,
        .cwd = cwd,
        .environment = policy.environment,
        .input_limit = max_message_bytes,
        .output_limit = output_capacity,
        .stderr_limit = 16384,
        .timeout_ms = timeout_ms,
    });
    defer job.destroy();
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    var failure: ?anyerror = null;
    job.send(input) catch |err| {
        failure = err;
        job.stop();
    };
    job.closeInput();
    var buffer: [16384]u8 = undefined;
    while (true) {
        if (cancel.load(.acquire)) {
            failure = error.Cancelled;
            job.stop();
        }
        const got = job.read(&buffer);
        if (got != 0 and failure == null) {
            if (got > limit - output.items.len) {
                failure = error.TooLarge;
                job.stop();
            } else output.appendSlice(a, buffer[0..got]) catch |err| {
                failure = err;
                job.stop();
            };
        }
        if (job.result()) |result| {
            if (failure) |err| return err;
            if (!result.reaped or result.stdout_discarded) return error.GitFailed;
            if (result.outcome == .timed_out) return error.GitTimedOut;
            if (result.outcome != .success) return error.GitFailed;
            return .{ .bytes = try output.toOwnedSlice(a), .code = result.exit_code orelse return error.GitFailed };
        }
        if (got == 0) _ = os.usleep(1000);
    }
}

/// Commit the staged index with the reviewed message on stdin. The caller must
/// have rechecked the exact staged set first. Empty staged is refused upstream.
pub fn applyCommit(a: std.mem.Allocator, cwd: []const u8, cancel: *Cancel, policy: WritePolicy, message: []const u8) !void {
    try validateMessage(message);
    const input = if (message[message.len - 1] == '\n') message else try std.fmt.allocPrint(a, "{s}\n", .{message});
    defer if (input.ptr != message.ptr) a.free(input);
    const r = try runWrite(a, cwd, cancel, policy, commit_args, input, write_output_bytes, write_timeout_ms);
    a.free(r.bytes);
}

/// Stage all tracked modifications/deletions (git add -u). Untracked is excluded.
pub fn applyStage(a: std.mem.Allocator, cwd: []const u8, cancel: *Cancel, policy: WritePolicy) !void {
    const r = try runWrite(a, cwd, cancel, policy, stage_tracked_args, "", write_output_bytes, write_timeout_ms);
    a.free(r.bytes);
}

/// Uncommit HEAD via a compare-and-swap ref update to the pinned parent,
/// preserving index and worktree (soft-reset equivalent). Fails closed if HEAD
/// moved since review. Never hard.
pub fn applyUncommit(a: std.mem.Allocator, cwd: []const u8, cancel: *Cancel, policy: WritePolicy, parent_oid: []const u8, expected_head: []const u8) !void {
    const args = uncommitArgs(parent_oid, expected_head);
    const r = try runWrite(a, cwd, cancel, policy, &args, "", write_output_bytes, write_timeout_ms);
    a.free(r.bytes);
}

// --- Lexical validation -----------------------------------------------------

fn validOid(oid: []const u8) !void {
    if (oid.len != 40 and oid.len != 64) return error.InvalidGitOutput;
    for (oid) |ch| {
        if (std.mem.indexOfScalar(u8, "0123456789abcdef", ch) == null) return error.InvalidGitOutput;
    }
}

fn validRelPath(path: []const u8) !void {
    if (path.len == 0 or path.len > status.max_path_bytes) return error.InvalidPath;
    if (path[0] == '/') return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidPath;
    }
}

// --- Pure unit tests (no repository, no GTK) --------------------------------

test "command builders are literal, staged-only and never hard reset" {
    const t = std.testing;
    try t.expectEqualStrings("commit", commit_args[0]);
    try t.expectEqualStrings("-F", commit_args[1]);
    try t.expectEqualStrings("-", commit_args[2]);
    try t.expectEqual(@as(usize, 3), commit_args.len);
    try t.expectEqualStrings("add", stage_tracked_args[0]);
    try t.expectEqualStrings("-u", stage_tracked_args[1]);
    const parent = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const expected = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const uncommit = uncommitArgs(parent, expected);
    try t.expectEqualStrings("update-ref", uncommit[0]);
    try t.expectEqualStrings("HEAD", uncommit[1]);
    try t.expectEqualStrings(parent, uncommit[2]);
    try t.expectEqualStrings(expected, uncommit[3]);
    for (uncommit) |arg| try t.expect(!std.mem.eql(u8, arg, "--hard"));
    var buf: [4][]const u8 = undefined;
    try t.expectEqualStrings("rev-parse", operationArgs(&buf, .merge)[0]);
    try t.expectEqualStrings("MERGE_HEAD", operationArgs(&buf, .merge)[3]);
    try t.expectEqualStrings("REBASE_HEAD", operationArgs(&buf, .rebase)[3]);
    try t.expectEqualStrings("CHERRY_PICK_HEAD", operationArgs(&buf, .cherry_pick)[3]);
    try t.expectEqualStrings("REVERT_HEAD", operationArgs(&buf, .revert)[3]);
    const ancestor = ancestorArgs("origin/main");
    try t.expectEqualStrings("merge-base", ancestor[0]);
    try t.expectEqualStrings("--is-ancestor", ancestor[1]);
    try t.expectEqualStrings("HEAD", ancestor[2]);
    try t.expectEqualStrings("origin/main", ancestor[3]);
}

test "name-status parser frames NUL records, duplicates paths and fails closed" {
    const t = std.testing;
    const files = try parseNameStatus(t.allocator, "M\x00src/a.zig\x00A\x00new file\x00D\x00gone\x00");
    defer {
        for (files) |f| t.allocator.free(f.path);
        t.allocator.free(files);
    }
    try t.expectEqual(@as(usize, 3), files.len);
    try t.expectEqual(@as(u8, 'M'), files[0].status);
    try t.expectEqualStrings("src/a.zig", files[0].path);
    try t.expectEqualStrings("new file", files[1].path);
    try t.expectEqual(@as(u8, 'D'), files[2].status);
    try t.expectEqual(@as(usize, 0), (try parseNameStatus(t.allocator, "")).len);
    try t.expectError(error.InvalidStatus, parseNameStatus(t.allocator, "R\x00x\x00"));
    try t.expectError(error.TruncatedRecord, parseNameStatus(t.allocator, "M\x00unterminated"));
    try t.expectError(error.InvalidRecord, parseNameStatus(t.allocator, "Mx\x00path\x00"));
    try t.expectError(error.InvalidPath, parseNameStatus(t.allocator, "M\x00../escape\x00"));
    try t.expectError(error.InvalidPath, parseNameStatus(t.allocator, "M\x00/absolute\x00"));
}

test "parents parser distinguishes initial, normal and merge commits" {
    const t = std.testing;
    const head = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const p1 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const p2 = "cccccccccccccccccccccccccccccccccccccccc";
    const normal = try parseParents(t.allocator, head ++ " " ++ p1 ++ "\n");
    defer {
        t.allocator.free(normal.head);
        for (normal.parents) |p| t.allocator.free(p);
        t.allocator.free(normal.parents);
    }
    try t.expectEqualStrings(head, normal.head);
    try t.expectEqual(@as(usize, 1), normal.parents.len);
    try t.expectEqualStrings(p1, normal.parents[0]);
    const initial = try parseParents(t.allocator, head ++ "\n");
    defer {
        t.allocator.free(initial.head);
        t.allocator.free(initial.parents);
    }
    try t.expectEqual(@as(usize, 0), initial.parents.len);
    const merge = try parseParents(t.allocator, head ++ " " ++ p1 ++ " " ++ p2 ++ "\n");
    defer {
        t.allocator.free(merge.head);
        for (merge.parents) |p| t.allocator.free(p);
        t.allocator.free(merge.parents);
    }
    try t.expectEqual(@as(usize, 2), merge.parents.len);
    try t.expectError(error.InvalidGitOutput, parseParents(t.allocator, "not-an-oid\n"));
    try t.expectError(error.InvalidGitOutput, parseParents(t.allocator, ""));
}

test "stat summary takes the final non-empty line and message validation refuses empty" {
    const t = std.testing;
    try t.expectEqualStrings("2 files changed, 3 insertions(+), 1 deletion(-)", try parseStatSummary(" a | 2 +-\n b | 1 +\n 2 files changed, 3 insertions(+), 1 deletion(-)\n"));
    try t.expectEqualStrings("", try parseStatSummary(""));
    try t.expectEqualStrings("", try parseStatSummary("   \n\t\n"));
    try validateMessage("subject");
    try validateMessage("subject\n\nbody\n");
    try t.expectError(error.EmptyMessage, validateMessage(""));
    try t.expectError(error.EmptyMessage, validateMessage("  \t\r\n"));
    try t.expectError(error.InvalidMessage, validateMessage("a\x00b"));
    const long: [max_message_bytes]u8 = @splat('x');
    try t.expectError(error.MessageTooLarge, validateMessage(&long));
}
