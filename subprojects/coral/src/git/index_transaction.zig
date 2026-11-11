//! Worker-only, one-shot index transactions. No worktree writes and no repository
//! writes during prepare. Call apply only after approval of before/after AND modes.
//! This protects cooperative Git writers, not malicious same-UID processes, mount
//! aliases, or adversarial ref writers racing the final recheck/rename interval.
//! Linux /proc and libc are required. Git children use held parent descriptors via
//! /proc/<our pid>/fd, not unchecked repository pathnames. Never copy a live Prepared.
const std = @import("std");
const builtin = @import("builtin");
const transport = @import("../language/transport.zig");
const command = @import("command.zig");
const c = @import("index_transaction_os.zig");

pub const Action = enum { stage, unstage };
pub const Request = struct { root: []const u8, gitdir: []const u8, commondir: []const u8, path: []const u8, action: Action };
pub const Cancel = std.atomic.Value(bool);
pub const Outcome = struct { committed: bool, durability_uncertain: bool = false };
pub const max_file_bytes = 256 * 1024;
pub const max_index_bytes = 16 * 1024 * 1024;
pub const Prepared = struct {
    before: []const u8,
    after: []const u8,
    path: []const u8,
    action: Action,
    before_exists: bool,
    after_exists: bool,
    before_mode: u32,
    after_mode: u32,
    state: *State,

    /// Worker-only; also required after apply fails. All attempts consume approval.
    pub fn deinit(self: *Prepared) void {
        self.state.destroy();
        self.* = undefined;
    }
};
const Stat = c.struct_stat;
const Dir = struct { fd: c_int, parent: ?*Dir, name: [:0]const u8, id: Stat };
const Snapshot = struct { parent: *Dir, name: [:0]const u8, id: ?Stat, bytes: []const u8, limit: usize };
const Entry = struct { mode: u32 = 0, oid: []const u8 = "", path: []const u8 = "" };
const Run = struct { bytes: []const u8, code: u8 };
pub const ObjectSyncStep = enum { file, prefix, objects };
/// Deterministic fault points, compiled out of production workers.
pub const TestHooks = struct {
    context: ?*anyopaque = null,
    before_final_recheck: ?*const fn (?*anyopaque) void = null,
    after_publish: ?*const fn (?*anyopaque) void = null,
    fail_directory_sync: bool = false,
    before_initial_lock_stat: ?*const fn (?*anyopaque) void = null,
    fail_initial_lock_stat: bool = false,
    fail_object_sync: ?ObjectSyncStep = null,
    after_object_sync: ?*const fn (?*anyopaque, ObjectSyncStep) void = null,
};
const State = struct {
    owner: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    dirs: std.ArrayList(*Dir) = .empty,
    snapshots: std.ArrayList(Snapshot) = .empty,
    root: *Dir = undefined,
    gitdir: *Dir = undefined,
    common: *Dir = undefined,
    objects: *Dir = undefined,
    temp: ?*Dir = null,
    index: Snapshot = undefined,
    disk: Snapshot = undefined,
    head: []const u8 = "",
    listing: []const u8 = "",
    target: Entry = .{},
    source: Entry = .{},
    head_entry: Entry = .{},
    hooks: if (builtin.is_test) ?*const TestHooks else void = if (builtin.is_test) null else {},
    filemode: bool = true,
    hash_bytes: usize = 20,
    used: bool = false,

    fn a(s: *State) std.mem.Allocator {
        return s.arena.allocator();
    }
    fn destroy(s: *State) void {
        if (s.temp) |tmp| {
            _ = c.unlinkat(tmp.fd, "index", 0);
            _ = c.unlinkat(tmp.fd, "index.lock", 0);
            // Only a private mkdtemp directory and its known scratch names.
            _ = c.unlinkat(tmp.parent.?.fd, tmp.name, c.AT_REMOVEDIR);
        }
        for (s.dirs.items) |d| _ = c.close(d.fd);
        const owner = s.owner;
        s.arena.deinit();
        owner.destroy(s);
    }
    fn dir(s: *State, parent: ?*Dir, name: []const u8) !*Dir {
        const z = try s.a().dupeSentinel(u8, name, 0);
        const fd = c.openat(if (parent) |p| p.fd else c.AT_FDCWD, z, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (fd < 0) return error.UnsafeDirectory;
        errdefer _ = c.close(fd);
        const d = try s.a().create(Dir);
        d.* = .{ .fd = fd, .parent = parent, .name = z, .id = try statFd(fd) };
        try s.dirs.append(s.a(), d);
        return d;
    }
    fn absolute(s: *State, path: []const u8) !*Dir {
        try validAbsolute(path);
        var d = try s.dir(null, "/");
        var parts = std.mem.tokenizeScalar(u8, path, '/');
        var depth: usize = 0;
        while (parts.next()) |part| {
            depth += 1;
            if (depth > 64) return error.UnsafePath;
            d = try s.dir(d, part);
        }
        return d;
    }
    fn proc(s: *State, d: *Dir) ![]const u8 {
        return std.fmt.allocPrint(s.a(), "/proc/{d}/fd/{d}", .{ c.getpid(), d.fd });
    }
    fn snapshot(s: *State, base: *Dir, path: []const u8, limit: usize) !Snapshot {
        try validRelative(path);
        var parent = base;
        var parts = std.mem.splitScalar(u8, path, '/');
        var part = parts.next().?;
        while (parts.next()) |next| {
            const z = try s.a().dupeSentinel(u8, part, 0);
            var st: Stat = undefined;
            if (c.fstatat(parent.fd, z, &st, c.AT_SYMLINK_NOFOLLOW) != 0) {
                if (errno() != c.ENOENT) return error.ReadFailed;
                // Missing ancestor is itself the absence witness. Creating it
                // invalidates approval even if the final file remains absent.
                const snap = Snapshot{ .parent = parent, .name = z, .id = null, .bytes = "", .limit = limit };
                try s.snapshots.append(s.a(), snap);
                return snap;
            }
            parent = try s.dir(parent, part);
            part = next;
        }
        const snap = try readSnapshot(s.a(), parent, try s.a().dupeSentinel(u8, part, 0), limit);
        try s.snapshots.append(s.a(), snap);
        return snap;
    }
    fn scratch(s: *State) !void {
        var template = "/tmp/coral-index-XXXXXX".* ++ [_]u8{0};
        if (c.mkdtemp(&template) == null) return error.TempFailed;
        errdefer _ = c.rmdir(&template);
        s.temp = try s.absolute(std.mem.sliceTo(&template, 0));
    }
    fn git(s: *State, cancel: *Cancel, args: []const []const u8, input: []const u8, limit: usize, allow_one: bool) !Run {
        const result = try runGit(s.owner, try s.proc(s.root), try s.proc(s.gitdir), try s.proc(s.common), try s.proc(s.objects), try std.fmt.allocPrint(s.a(), "{s}/index", .{try s.proc(s.temp.?)}), cancel, args, input, limit, allow_one);
        defer s.owner.free(result.bytes);
        return .{ .bytes = try s.a().dupe(u8, result.bytes), .code = result.code };
    }
    fn config(s: *State, cancel: *Cancel, key: []const u8) !?[]const u8 {
        const r = try s.git(cancel, &.{ "config", "--type=bool", "--get", key }, "", 1024, true);
        return if (r.code == 1) null else std.mem.trimEnd(u8, r.bytes, "\n");
    }
    fn policy(s: *State, cancel: *Cancel, path: []const u8, stage: bool) !bool {
        for ([_][]const u8{ "core.sparseCheckout", "index.sparse", "core.splitIndex" }) |key| {
            if (try s.config(cancel, key)) |value| if (!std.mem.eql(u8, value, "false")) return error.UnsupportedIndex;
        }
        const refs = try s.git(cancel, &.{ "config", "--get", "extensions.refStorage" }, "", 1024, true);
        if (refs.code == 0 and !std.mem.eql(u8, refs.bytes, "files\n")) return error.UnsupportedHead;
        const fm = if (try s.config(cancel, "core.filemode")) |value| std.mem.eql(u8, value, "true") else true;
        if (stage) {
            // autocrlf=input is not a bool; config rejects it, also failing closed.
            if (try s.config(cancel, "core.autocrlf")) |value| if (!std.mem.eql(u8, value, "false")) return error.ConversionUnsupported;
            // --all distinguishes an absent attribute from filter=unspecified.
            // Git's textual values "unset"/"unspecified" are otherwise ambiguous
            // with literal driver names. Conservatively refuse even -text/-filter.
            const r = try s.git(cancel, &.{ "check-attr", "--all", "-z", "--", path }, "", 16384, false);
            var fields = std.mem.splitScalar(u8, r.bytes, 0);
            while (fields.next()) |file| {
                if (file.len == 0) {
                    if (fields.next() != null) return error.InvalidGitOutput;
                    break;
                }
                if (!std.mem.eql(u8, file, path)) return error.InvalidGitOutput;
                const attribute = fields.next() orelse return error.InvalidGitOutput;
                _ = fields.next() orelse return error.InvalidGitOutput;
                for ([_][]const u8{ "filter", "text", "eol", "working-tree-encoding", "ident", "crlf" }) |name| {
                    if (std.mem.eql(u8, attribute, name)) return error.ConversionUnsupported;
                }
            }
        }
        return fm;
    }
    fn headOid(s: *State, cancel: *Cancel) ![]const u8 {
        const r = try s.git(cancel, &.{ "rev-parse", "--verify", "--quiet", "HEAD" }, "", 1024, true);
        if (r.code == 1) return "";
        return try oidLine(r.bytes, s.hash_bytes);
    }
    fn recheck(s: *State, p: *const Prepared, cancel: *Cancel) !void {
        try cancelled(cancel);
        // Subprocess checks precede the last descriptor/content checks: no Git
        // process may introduce a long window after validating the disk/index.
        if (try s.policy(cancel, p.path, p.action == .stage) != s.filemode) return error.StaleSnapshot;
        if (!std.mem.eql(u8, s.head, try s.headOid(cancel))) return error.StaleSnapshot;
        try checkDirs(s.dirs.items);
        for (s.snapshots.items) |snap| {
            const now = try readSnapshot(s.owner, snap.parent, snap.name, snap.limit);
            defer if (now.id != null) s.owner.free(now.bytes);
            if (!sameSnapshot(snap, now)) return error.StaleSnapshot;
        }
        try checkDirs(s.dirs.items);
        try cancelled(cancel);
    }
};

pub fn prepare(allocator: std.mem.Allocator, request: Request, cancel: *Cancel) !Prepared {
    try cancelled(cancel);
    try validRelative(request.path);
    var components = std.mem.splitScalar(u8, request.path, '/');
    while (components.next()) |part| if (std.ascii.eqlIgnoreCase(part, ".git")) return error.UnsafePath;
    if (!std.unicode.utf8ValidateSlice(request.path)) return error.NonUtf8;
    const s = try allocator.create(State);
    s.* = .{ .owner = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer s.destroy();
    s.root = try s.absolute(request.root);
    s.gitdir = try s.absolute(request.gitdir);
    s.common = try s.absolute(request.commondir);
    s.objects = try s.dir(s.common, "objects");
    try bindRepository(s);
    s.index = try s.snapshot(s.gitdir, "index", max_index_bytes);
    s.disk = try s.snapshot(s.root, request.path, max_file_bytes);
    try text(s.disk.bytes);
    try s.scratch();
    const format = (try s.git(cancel, &.{ "rev-parse", "--show-object-format" }, "", 128, false)).bytes;
    s.hash_bytes = if (std.mem.eql(u8, format, "sha1\n")) 20 else if (std.mem.eql(u8, format, "sha256\n")) 32 else return error.UnsupportedIndex;
    if (s.index.id) |id| {
        const scratch_index = try withoutStatCache(s.a(), s.index.bytes, s.hash_bytes);
        try writePrivate(s.temp.?, scratch_index, id);
    }
    s.filemode = try s.policy(cancel, request.path, request.action == .stage);
    s.listing = (try s.git(cancel, &.{ "ls-files", "--stage", "-z" }, "", max_index_bytes, false)).bytes;
    s.target = try selected(s.listing, request.path, s.hash_bytes);
    const before = try blob(s, cancel, s.target);
    _ = try s.snapshot(s.gitdir, "HEAD", 4096);
    _ = try s.snapshot(s.common, "packed-refs", max_index_bytes);
    const symbolic = try s.git(cancel, &.{ "symbolic-ref", "--quiet", "HEAD" }, "", 4096, true);
    if (symbolic.code == 0) {
        const ref = std.mem.trimEnd(u8, symbolic.bytes, "\n");
        // HEAD normally targets a branch. Other namespaces can have worktree-
        // specific storage rules; fail closed rather than snapshot the wrong ref.
        if (!std.mem.startsWith(u8, ref, "refs/heads/")) return error.UnsupportedHead;
        const ref_snap = try s.snapshot(s.common, ref, 4096);
        if (std.mem.startsWith(u8, ref_snap.bytes, "ref:")) return error.UnsupportedHead;
    }
    s.head = try s.headOid(cancel);
    if (s.head.len == 0 and symbolic.code != 0) return error.UnsupportedHead;
    if (s.head.len != 0) {
        const tree = (try s.git(cancel, &.{ "ls-tree", "-z", s.head, "--", request.path }, "", 8192, false)).bytes;
        if (tree.len != 0) {
            const tab = std.mem.indexOfScalar(u8, tree, '\t') orelse return error.InvalidGitOutput;
            var fields = std.mem.splitScalar(u8, tree[0..tab], ' ');
            s.head_entry.mode = try mode(fields.next() orelse return error.InvalidGitOutput);
            if (!std.mem.eql(u8, fields.next() orelse return error.InvalidGitOutput, "blob")) return error.UnsupportedEntry;
            s.head_entry.oid = fields.next() orelse return error.InvalidGitOutput;
            try validOid(s.head_entry.oid, s.hash_bytes);
            if (!std.mem.eql(u8, tree[tab + 1 ..], try std.fmt.allocPrint(s.a(), "{s}\x00", .{request.path}))) return error.UnsupportedEntry;
        }
    }
    var after: []const u8 = "";
    if (request.action == .stage) {
        if (s.disk.id) |disk| {
            s.source.mode = if (s.filemode) (if (disk.st_mode & 0o100 != 0) @as(u32, 0o100755) else 0o100644) else if (s.target.mode != 0) s.target.mode else 0o100644;
            after = s.disk.bytes;
        }
    } else {
        s.source = s.head_entry;
        after = try blob(s, cancel, s.source);
    }
    const p = Prepared{
        .before = before,
        .after = after,
        .path = try s.a().dupe(u8, request.path),
        .action = request.action,
        .before_exists = s.target.mode != 0,
        .after_exists = s.source.mode != 0,
        .before_mode = s.target.mode,
        .after_mode = s.source.mode,
        .state = s,
    };
    try s.recheck(&p, cancel);
    return p;
}

/// One-shot, worker-only. Errors are strictly pre-publication. Raw object writes
/// may remain unreachable on a pre-publication failure; disk files never change.
/// Non-deletions require a syncable local loose target object (packed/alternate-
/// only targets fail closed). Publication drops filesystem stat caches, not
/// logical index entries; subsequent Git refreshes may do additional disk reads.
pub fn apply(p: *Prepared, cancel: *Cancel) !Outcome {
    const s = p.state;
    if (s.used) return error.AlreadyApplied;
    s.used = true;
    try cancelled(cancel);
    const lock = c.openat(s.gitdir.fd, "index.lock", c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (lock < 0) return if (errno() == c.EEXIST) error.IndexLocked else error.LockFailed;
    defer _ = c.close(lock);
    var lock_id: ?Stat = null;
    var published = false;
    // Install before *any* fallible operation after O_EXCL. On a failed first
    // stat, cleanup obtains identity from the still-open descriptor, never from
    // the pathname alone (which may now name somebody else's lock).
    defer if (!published) cleanupLock(s.gitdir, lock, lock_id);
    if (builtin.is_test) if (s.hooks) |hooks| {
        if (hooks.before_initial_lock_stat) |hook| hook(hooks.context);
        if (hooks.fail_initial_lock_stat) return error.ReadFailed;
    };
    lock_id = try statFd(lock);
    try s.recheck(p, cancel);
    var oid = s.source.oid;
    if (p.action == .stage and p.after_exists) {
        oid = try oidLine((try s.git(cancel, &.{ "hash-object", "-w", "--no-filters", "--stdin" }, p.after, 1024, false)).bytes, s.hash_bytes);
    }
    // hash-object may reuse an existing object without syncing anything. Sync
    // the selected loose object and both directory entries ourselves, also for
    // HEAD objects restored by unstage. Packed/alternate-only objects fail closed.
    if (p.after_exists) try syncLooseObject(s, oid, cancel);
    if (s.index.id == null) _ = try s.git(cancel, &.{ "read-tree", "--empty" }, "", 1024, false);
    const zeros: [64]u8 = @splat('0');
    const update = try std.fmt.allocPrint(s.a(), "{o} {s}\t{s}\x00", .{ p.after_mode, if (p.after_exists) oid else zeros[0 .. s.hash_bytes * 2], p.path });
    _ = try s.git(cancel, &.{ "-c", "core.splitIndex=false", "-c", "index.sparse=false", "update-index", "-z", "--index-info" }, update, 1024, false);
    const proposal_listing = (try s.git(cancel, &.{ "ls-files", "--stage", "-z" }, "", max_index_bytes, false)).bytes;
    try verifyProposal(s.listing, proposal_listing, p.path, p.after_mode, oid, s.hash_bytes);
    const proposal = try readSnapshot(s.a(), s.temp.?, "index", max_index_bytes);
    if (proposal.id == null) return error.InvalidIndex;
    const published_index = try withoutStatCache(s.a(), proposal.bytes, s.hash_bytes);
    try writeAll(lock, published_index);
    const permissions: c_uint = if (s.index.id) |id| @intCast(id.st_mode & 0o777) else 0o600;
    if (c.fchmod(lock, permissions) != 0 or c.fsync(lock) != 0) return error.SyncFailed;
    if (builtin.is_test) if (s.hooks) |hooks| if (hooks.before_final_recheck) |hook| hook(hooks.context);
    try s.recheck(p, cancel);
    if (!ownsLock(s.gitdir, lock_id.?)) return error.LockReplaced;
    // This is the publication boundary. Never report cancellation after rename.
    try cancelled(cancel);
    if (c.renameat(s.gitdir.fd, "index.lock", s.gitdir.fd, "index") != 0) return error.PublishFailed;
    published = true;
    if (builtin.is_test) if (s.hooks) |hooks| {
        if (hooks.after_publish) |hook| hook(hooks.context);
        if (hooks.fail_directory_sync) return .{ .committed = true, .durability_uncertain = true };
    };
    return .{ .committed = true, .durability_uncertain = c.fsync(s.gitdir.fd) != 0 };
}

fn errno() c_int {
    return c.__errno_location().*;
}
fn cancelled(cancel: *Cancel) !void {
    if (cancel.load(.acquire)) return error.Cancelled;
}
fn statFd(fd: c_int) !Stat {
    var st: Stat = undefined;
    if (c.fstat(fd, &st) != 0) return error.ReadFailed;
    return st;
}
fn identity(a: Stat, b: Stat) bool {
    return a.st_dev == b.st_dev and a.st_ino == b.st_ino and a.st_mode == b.st_mode and a.st_uid == b.st_uid and a.st_gid == b.st_gid and a.birth.tv_sec == b.birth.tv_sec and a.birth.tv_nsec == b.birth.tv_nsec;
}
fn metadata(a: Stat, b: Stat) bool {
    return identity(a, b) and a.st_nlink == b.st_nlink and a.st_size == b.st_size and
        a.st_mtim.tv_sec == b.st_mtim.tv_sec and a.st_mtim.tv_nsec == b.st_mtim.tv_nsec and
        a.st_ctim.tv_sec == b.st_ctim.tv_sec and a.st_ctim.tv_nsec == b.st_ctim.tv_nsec;
}
fn checkDirs(dirs: []const *Dir) !void {
    for (dirs) |d| {
        if (!identity(d.id, try statFd(d.fd))) return error.StaleSnapshot;
        var st: Stat = undefined;
        if (c.fstatat(if (d.parent) |p| p.fd else c.AT_FDCWD, d.name, &st, c.AT_SYMLINK_NOFOLLOW) != 0 or !identity(d.id, st)) return error.StaleSnapshot;
    }
}
fn readSnapshot(a: std.mem.Allocator, parent: *Dir, name: [:0]const u8, limit: usize) !Snapshot {
    const fd = c.openat(parent.fd, name, c.O_RDONLY | c.O_NOFOLLOW | c.O_NONBLOCK | c.O_CLOEXEC);
    if (fd < 0) {
        if (errno() == c.ENOENT) return .{ .parent = parent, .name = name, .id = null, .bytes = "", .limit = limit };
        return error.UnsafeFile;
    }
    defer _ = c.close(fd);
    const st = try statFd(fd);
    if (st.st_mode & c.S_IFMT != c.S_IFREG) return error.UnsafeFile;
    if (st.st_size > limit) return error.TooLarge;
    const bytes = try a.alloc(u8, @intCast(st.st_size));
    errdefer a.free(bytes);
    var used: usize = 0;
    while (used < bytes.len) {
        const n = c.read(fd, bytes[used..].ptr, bytes.len - used);
        if (n < 0 and errno() == c.EINTR) continue;
        if (n <= 0) return error.StaleSnapshot;
        used += @intCast(n);
    }
    var extra: [1]u8 = undefined;
    if (c.read(fd, &extra, 1) != 0 or !metadata(st, try statFd(fd))) return error.StaleSnapshot;
    var named: Stat = undefined;
    if (c.fstatat(parent.fd, name, &named, c.AT_SYMLINK_NOFOLLOW) != 0 or !metadata(st, named)) return error.StaleSnapshot;
    return .{ .parent = parent, .name = name, .id = st, .bytes = bytes, .limit = limit };
}
fn sameSnapshot(a: Snapshot, b: Snapshot) bool {
    if (a.id) |id| return if (b.id) |other| metadata(id, other) and std.mem.eql(u8, a.bytes, b.bytes) else false;
    return b.id == null;
}
fn validRelative(path: []const u8) !void {
    if (path.len == 0 or path.len > 4095 or path[0] == '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.UnsafePath;
    var parts = std.mem.splitScalar(u8, path, '/');
    var depth: usize = 0;
    while (parts.next()) |part| {
        depth += 1;
        if (depth > 64 or part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafePath;
    }
}
fn validAbsolute(path: []const u8) !void {
    if (path.len == 0 or path[0] != '/') return error.UnsafePath;
    if (path.len != 1) try validRelative(path[1..]);
}
fn text(bytes: []const u8) !void {
    if (bytes.len > max_file_bytes) return error.TooLarge;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.Binary;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.NonUtf8;
}
fn bindRepository(s: *State) !void {
    var st: Stat = undefined;
    if (c.fstatat(s.root.fd, ".git", &st, c.AT_SYMLINK_NOFOLLOW) != 0) return error.RepositoryBinding;
    if (st.st_mode & c.S_IFMT == c.S_IFDIR) {
        const dotgit = try s.dir(s.root, ".git");
        if (!identity(dotgit.id, s.gitdir.id) or !identity(s.gitdir.id, s.common.id)) return error.RepositoryBinding;
        // Even an ordinary .git directory can gain a commondir redirect later.
        const common = try s.snapshot(s.gitdir, "commondir", 4096);
        if (common.id != null) return error.RepositoryBinding;
    } else {
        const link = try s.snapshot(s.root, ".git", 4096);
        if (!std.mem.startsWith(u8, link.bytes, "gitdir: ")) return error.RepositoryBinding;
        const destination = std.mem.trimEnd(u8, link.bytes[8..], "\r\n");
        const resolved = try resolveBinding(s, s.root, destination);
        if (!identity(resolved.id, s.gitdir.id)) return error.RepositoryBinding;
        const common = try s.snapshot(s.gitdir, "commondir", 4096);
        if (common.id != null) {
            const common_dir = try resolveBinding(s, s.gitdir, std.mem.trimEnd(u8, common.bytes, "\r\n"));
            if (!identity(common_dir.id, s.common.id)) return error.RepositoryBinding;
        } else if (!identity(s.gitdir.id, s.common.id)) return error.RepositoryBinding;
        _ = try s.snapshot(s.gitdir, "gitdir", 4096);
    }
}
fn resolveBinding(s: *State, base: *Dir, path: []const u8) !*Dir {
    if (path.len == 0 or path.len > 4095 or std.mem.indexOfScalar(u8, path, 0) != null) return error.RepositoryBinding;
    // Linked worktrees commonly use ../.. in commondir. Walk those components
    // using descriptors too; directory identities are retained and revalidated.
    var d = if (path[0] == '/') try s.dir(null, "/") else base;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    var depth: usize = 0;
    while (parts.next()) |part| {
        depth += 1;
        if (depth > 64) return error.RepositoryBinding;
        d = try s.dir(d, part);
    }
    return d;
}
fn writeAll(fd: c_int, bytes: []const u8) !void {
    var used: usize = 0;
    while (used < bytes.len) {
        const n = c.write(fd, bytes[used..].ptr, bytes.len - used);
        if (n < 0 and errno() == c.EINTR) continue;
        if (n <= 0) return error.WriteFailed;
        used += @intCast(n);
    }
}
fn writePrivate(dir: *Dir, bytes: []const u8, original: Stat) !void {
    const fd = c.openat(dir.fd, "index", c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.TempFailed;
    defer _ = c.close(fd);
    try writeAll(fd, bytes);
    const times = [2]c.Timespec{
        .{ .sec = 0, .nsec = c.UTIME_OMIT },
        .{ .sec = original.st_mtim.tv_sec, .nsec = original.st_mtim.tv_nsec },
    };
    if (c.futimens(fd, &times) != 0) return error.TempFailed;
}
fn cleanupLock(dir: *Dir, fd: c_int, captured: ?Stat) void {
    // If the OS persistently refuses descriptor identity, leaving the lock is
    // safer than deleting an unverified replacement. Transient first-stat errors
    // still clean up; statx's EINTR handling lives in the libc boundary.
    const id = captured orelse (statFd(fd) catch return);
    if (ownsLock(dir, id)) _ = c.unlinkat(dir.fd, "index.lock", 0);
}
fn syncObjectPart(s: *State, fd: c_int, step: ObjectSyncStep) !void {
    if (builtin.is_test) if (s.hooks) |hooks| if (hooks.fail_object_sync == step) return error.ObjectSyncFailed;
    while (c.fsync(fd) != 0) {
        if (errno() != c.EINTR) return error.ObjectSyncFailed;
    }
    if (builtin.is_test) if (s.hooks) |hooks| if (hooks.after_object_sync) |hook| hook(hooks.context, step);
}
fn syncLooseObject(s: *State, oid: []const u8, cancel: *Cancel) !void {
    try cancelled(cancel);
    try validOid(oid, s.hash_bytes);
    const prefix = s.dir(s.objects, oid[0..2]) catch return error.ObjectDurabilityUnavailable;
    const name = try s.a().dupeSentinel(u8, oid[2..], 0);
    const fd = c.openat(prefix.fd, name, c.O_RDONLY | c.O_NONBLOCK | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return error.ObjectDurabilityUnavailable;
    defer _ = c.close(fd);
    const id = try statFd(fd);
    if (id.st_mode & c.S_IFMT != c.S_IFREG) return error.ObjectDurabilityUnavailable;
    try syncObjectPart(s, fd, .file);
    try cancelled(cancel);
    try syncObjectPart(s, prefix.fd, .prefix);
    try syncObjectPart(s, s.objects.fd, .objects);
    var named: Stat = undefined;
    if (!metadata(id, try statFd(fd)) or c.fstatat(prefix.fd, name, &named, c.AT_SYMLINK_NOFOLLOW) != 0 or !metadata(id, named)) return error.StaleSnapshot;
    try cancelled(cancel);
}
fn ownsLock(dir: *Dir, id: Stat) bool {
    var st: Stat = undefined;
    return c.fstatat(dir.fd, "index.lock", &st, c.AT_SYMLINK_NOFOLLOW) == 0 and st.st_dev == id.st_dev and st.st_ino == id.st_ino;
}
fn mode(value: []const u8) !u32 {
    const m = std.fmt.parseInt(u32, value, 8) catch return error.InvalidGitOutput;
    if (m != 0o100644 and m != 0o100755) return error.UnsupportedEntry;
    return m;
}
fn validOid(oid: []const u8, hash_bytes: usize) !void {
    if (oid.len != hash_bytes * 2) return error.InvalidGitOutput;
    for (oid) |b| if (!(b >= '0' and b <= '9') and !(b >= 'a' and b <= 'f')) return error.InvalidGitOutput;
}
fn oidLine(bytes: []const u8, hash_bytes: usize) ![]const u8 {
    if (bytes.len != hash_bytes * 2 + 1 or bytes[bytes.len - 1] != '\n') return error.InvalidGitOutput;
    const oid = bytes[0 .. bytes.len - 1];
    try validOid(oid, hash_bytes);
    return oid;
}
fn parseEntry(record: []const u8, hash_bytes: usize) !Entry {
    const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return error.InvalidGitOutput;
    var fields = std.mem.splitScalar(u8, record[0..tab], ' ');
    const m = std.fmt.parseInt(u32, fields.next() orelse return error.InvalidGitOutput, 8) catch return error.InvalidGitOutput;
    const oid = fields.next() orelse return error.InvalidGitOutput;
    try validOid(oid, hash_bytes);
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidGitOutput, "0") or fields.next() != null) return error.Conflict;
    return .{ .mode = m, .oid = oid, .path = record[tab + 1 ..] };
}
fn selected(listing: []const u8, path: []const u8, hash_bytes: usize) !Entry {
    var result: Entry = .{};
    var records = std.mem.splitScalar(u8, listing, 0);
    while (records.next()) |record| {
        if (record.len == 0) {
            if (records.next() != null) return error.InvalidGitOutput;
            break;
        }
        const e = try parseEntry(record, hash_bytes);
        if (std.mem.eql(u8, e.path, path)) {
            if (result.mode != 0) return error.Conflict;
            if (e.mode != 0o100644 and e.mode != 0o100755) return error.UnsupportedEntry;
            result = e;
        }
    }
    return result;
}
fn blob(s: *State, cancel: *Cancel, entry: Entry) ![]const u8 {
    if (entry.mode == 0) return "";
    const size_out = (try s.git(cancel, &.{ "cat-file", "-s", entry.oid }, "", 128, false)).bytes;
    const size = std.fmt.parseInt(usize, std.mem.trimEnd(u8, size_out, "\n"), 10) catch return error.InvalidGitOutput;
    if (size > max_file_bytes) return error.TooLarge;
    const bytes = (try s.git(cancel, &.{ "cat-file", "blob", entry.oid }, "", max_file_bytes, false)).bytes;
    if (bytes.len != size) return error.InvalidGitOutput;
    try text(bytes);
    return bytes;
}
fn verifyProposal(before: []const u8, after: []const u8, path: []const u8, expected_mode: u32, oid: []const u8, hash_bytes: usize) !void {
    const target = try selected(after, path, hash_bytes);
    if (target.mode != expected_mode or (expected_mode != 0 and !std.mem.eql(u8, target.oid, oid))) return error.InvalidProposal;
    var a = std.mem.splitScalar(u8, before, 0);
    var b = std.mem.splitScalar(u8, after, 0);
    while (true) {
        const left = try nextOther(&a, path, hash_bytes);
        const right = try nextOther(&b, path, hash_bytes);
        if (left == null or right == null) {
            if (left != null or right != null) return error.InvalidProposal;
            return;
        }
        if (!std.mem.eql(u8, left.?, right.?)) return error.InvalidProposal;
    }
}
fn nextOther(it: *std.mem.SplitIterator(u8, .scalar), path: []const u8, hash_bytes: usize) !?[]const u8 {
    while (it.next()) |record| {
        if (record.len == 0) return null;
        const entry = try parseEntry(record, hash_bytes);
        if (!std.mem.eql(u8, entry.path, path)) return record;
    }
    return null;
}
fn be32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}
fn be16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}
/// Copying an index to a newer inode can turn a racy-clean cache entry into a
/// falsely clean one. Clear filesystem stat caches, never modes/OIDs/paths. Do
/// this before Git sees the scratch index too, so its writeback does not perform
/// implicit worktree reads/conversions to smudge unrelated racy entries. Repeat
/// on publication: its fresh mtime must not give old cached stats new validity.
fn withoutStatCache(a: std.mem.Allocator, original: []const u8, hash_bytes: usize) ![]u8 {
    try validateIndex(original, hash_bytes);
    const bytes = try a.dupe(u8, original);
    const end = bytes.len - hash_bytes;
    var offset: usize = 12;
    for (0..be32(bytes[8..])) |_| {
        const start = offset;
        @memset(bytes[start..][0..24], 0); // ctime, mtime, device, inode
        @memset(bytes[start + 28 ..][0..12], 0); // uid, gid, size (mode stays)
        offset += 42 + hash_bytes;
        offset += std.mem.indexOfScalar(u8, bytes[offset..end], 0).? + 1;
        offset = start + std.mem.alignForward(usize, offset - start, 8);
    }
    if (hash_bytes == 20) {
        std.crypto.hash.Sha1.hash(bytes[0..end], bytes[end..][0..20], .{});
    } else {
        std.crypto.hash.sha2.Sha256.hash(bytes[0..end], bytes[end..][0..32], .{});
    }
    return bytes;
}
fn validateIndex(bytes: []const u8, hash_bytes: usize) !void {
    if (bytes.len < 12 + hash_bytes or !std.mem.eql(u8, bytes[0..4], "DIRC")) return error.InvalidIndex;
    const version = be32(bytes[4..]);
    // v4 path compression is deliberately unsupported in this first slice.
    if (version != 2 and version != 3) return error.UnsupportedIndex;
    const end = bytes.len - hash_bytes;
    var offset: usize = 12;
    const count = be32(bytes[8..]);
    for (0..count) |_| {
        const start = offset;
        const fixed = 42 + hash_bytes;
        if (offset > end or end - offset < fixed) return error.InvalidIndex;
        const flags = be16(bytes[offset + 40 + hash_bytes ..]);
        if (flags & 0x3000 != 0) return error.Conflict;
        if (flags & 0xc000 != 0) return error.UnsupportedIndex; // assume-unchanged, extended (skip/intent)
        if (be32(bytes[offset + 24 ..]) == 0o040000) return error.UnsupportedIndex;
        offset += fixed;
        const nul = std.mem.indexOfScalar(u8, bytes[offset..end], 0) orelse return error.InvalidIndex;
        offset += nul + 1;
        offset = start + std.mem.alignForward(usize, offset - start, 8);
        if (offset > end) return error.InvalidIndex;
    }
    while (offset < end) {
        if (end - offset < 8) return error.InvalidIndex;
        const signature = bytes[offset..][0..4];
        const size = be32(bytes[offset + 4 ..]);
        if (signature[0] < 'A' or signature[0] > 'Z') return error.UnsupportedIndex; // link, sdir, unknown mandatory
        offset += 8;
        if (size > end - offset) return error.InvalidIndex;
        offset += size;
    }
}

/// Synchronous worker wrapper. All exits drain and reap before releasing transport.
/// Kept public for isolated fixture commands; production only uses the fixed Git
/// argv prefix and complete allowlist below. No shell or inherited environment.
pub fn runGit(a: std.mem.Allocator, cwd: []const u8, gitdir: ?[]const u8, common: ?[]const u8, objects: ?[]const u8, index: ?[]const u8, cancel: *Cancel, args: []const []const u8, input: []const u8, limit: usize, allow_one: bool) !Run {
    try cancelled(cancel);
    if (input.len > max_file_bytes or limit > max_index_bytes) return error.TooLarge;
    // Transport deliberately drops overflow rather than blocking its supervisor.
    // Fit the entire bounded response even if this submitting worker is descheduled.
    const output_capacity = try std.math.ceilPowerOfTwo(usize, @max(@as(usize, 4096), limit));
    // Do not override core.attributesFile here: silently disabling a configured
    // filter attribute would make our no-conversion assertion untrue.
    const prefix = command.prefix[0 .. command.prefix.len - 2];
    const argv = try a.alloc([]const u8, prefix.len + args.len);
    defer a.free(argv);
    @memcpy(argv[0..prefix.len], prefix);
    @memcpy(argv[prefix.len..], args);
    var env: [command.environment.len + 7]transport.Environment = undefined;
    for (command.environment, 0..) |e, i| env[i] = .{ .name = e.name, .value = e.value };
    var n: usize = command.environment.len;
    const extra = [_]?[]const u8{ gitdir, common, objects, index, if (gitdir != null) cwd else null, "true", "1" };
    // Replacement refs must not substitute different bytes for a reviewed OID.
    const names = [_][]const u8{ "GIT_DIR", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_INDEX_FILE", "GIT_WORK_TREE", "GIT_EDITOR", "GIT_NO_REPLACE_OBJECTS" };
    for (extra, names) |value, name| if (value) |v| {
        env[n] = .{ .name = name, .value = v };
        n += 1;
    };
    const job = try transport.start(a, .{ .authorization = .approved, .argv = argv, .cwd = cwd, .environment = env[0..n], .input_limit = max_file_bytes, .output_limit = output_capacity, .stderr_limit = 16384, .timeout_ms = 15000 });
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
            if (result.outcome != .success and !(allow_one and result.outcome == .nonzero and result.exit_code == 1)) return error.GitFailed;
            return .{ .bytes = try output.toOwnedSlice(a), .code = result.exit_code orelse return error.GitFailed };
        }
        if (got == 0) _ = c.usleep(1000);
    }
}
