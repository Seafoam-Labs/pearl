//! Linux worker-only filesystem boundary. No GTK, subprocesses, manifest trust
//! flags, execution, or environment reads after StateHome.init(). Metadata and
//! regular-file I/O can block on a filesystem; O_NONBLOCK prevents FIFO hangs,
//! and LOCK_NB prevents indefinite waits on other trust writers. Busy is retryable.
//! Protects app-owned files from other users/accidental symlinks, NOT a malicious
//! same-uid process. Captures are snapshots, not an OS sandbox or inode leases.
const std = @import("std");
const trust = @import("trust.zig");
const dir_flags: std.c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true };
const read_flags: std.c.O = .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true };
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

/// Immutable machine configuration, never obtained from workspace data. Existing
/// state-home ancestors must be provisioned separately (as in recovery_fs).
/// Symlinked HOME/XDG components are deliberately unsupported. Only coral/trust
/// is created here. Snapshot environment on the owner before dispatching workers.
pub const StateHome = struct {
    allocator: std.mem.Allocator,
    path: []const u8,

    pub fn init(allocator: std.mem.Allocator, override: ?[]const u8) !StateHome {
        const path = if (override) |p| try allocator.dupe(u8, p) else blk: {
            if (getenv("XDG_STATE_HOME")) |p| {
                if (p[0] != 0) break :blk try allocator.dupe(u8, std.mem.span(p));
            }
            const home = getenv("HOME") orelse return error.MissingStateHome;
            if (home[0] == 0) return error.MissingStateHome;
            break :blk try std.fmt.allocPrint(allocator, "{s}/.local/state", .{std.mem.span(home)});
        };
        errdefer allocator.free(path);
        try statePath(path);
        if (path.len + "/coral/trust/pending".len > trust.limits.path_bytes) return error.InvalidPath;
        return .{ .allocator = allocator, .path = path };
    }
    pub fn deinit(self: *StateHome) void {
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

fn statePath(path: []const u8) !void {
    try trust.absolutePath(path);
    if (path.len == 1) return;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 255 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidPath;
    }
}
fn close(fd: c_int) void {
    _ = std.c.close(fd);
}
fn inspect(fd: c_int) !std.os.linux.Statx {
    var stat: std.os.linux.Statx = undefined;
    const mask: std.os.linux.STATX = .{ .TYPE = true, .MODE = true, .UID = true, .NLINK = true, .INO = true, .SIZE = true, .BTIME = true };
    while (std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, mask, &stat) != 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return error.Io;
    }
    if (!stat.mask.TYPE or !stat.mask.MODE or !stat.mask.UID or !stat.mask.NLINK or !stat.mask.INO or !stat.mask.SIZE) return error.Io;
    return stat;
}
/// Decode only a supported birth timestamp. Unset STATX_BTIME fields are not
/// evidence of incarnation, even if the kernel filled them with plausible data.
/// State-store files need not support birth time; every workspace root and
/// manifest base must. Never substitute mutable ctime/mtime or zero defaults.
pub fn directoryBirthTime(stat: std.os.linux.Statx) !trust.BirthTime {
    if (!stat.mask.BTIME) return error.UnsupportedBirthTime;
    if (stat.btime.nsec >= 1_000_000_000) return error.InvalidBirthTime;
    return .{ .seconds = stat.btime.sec, .nanoseconds = stat.btime.nsec };
}

fn sync(fd: c_int) !void {
    while (std.c.fsync(fd) != 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return error.Io;
    }
}
fn sameNode(a: std.os.linux.Statx, b: std.os.linux.Statx) bool {
    return a.dev_major == b.dev_major and a.dev_minor == b.dev_minor and a.ino == b.ino;
}
fn canonical(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    try trust.absolutePath(path);
    const z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(z);
    var buf: [4096]u8 = undefined;
    const p = std.c.realpath(z, &buf) orelse return error.UnavailableRoot;
    const resolved = std.mem.span(p);
    try trust.absolutePath(resolved);
    return allocator.dupe(u8, resolved);
}

/// Open each component relative to the held parent, not just O_NOFOLLOW on the
/// leaf. Canonical workspace paths and strict machine state paths have no '..'.
fn walk(path: []const u8, machine: bool) !c_int {
    try statePath(path);
    // Workspace identity needs only traversal and statx, not directory reads.
    // Keep machine-state descriptors readable for creation, locking and fsync.
    const flags: std.c.O = if (machine) dir_flags else .{ .PATH = true, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };
    var fd = std.c.open("/", flags);
    if (fd < 0) return error.Io;
    errdefer close(fd);
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        var name: [256:0]u8 = @splat(0);
        @memcpy(name[0..part.len], part);
        const next = std.c.openat(fd, &name, flags);
        if (next < 0) return if (std.c.errno(next) == .NOENT) error.NotFound else error.UnsafeDirectory;
        close(fd);
        fd = next;
        if (machine) {
            const st = try inspect(fd);
            // Root-owned sticky /tmp is allowed for private test/state homes.
            // Untrusted writable non-sticky ancestors permit directory swapping.
            if (st.uid != 0 and st.uid != std.c.geteuid()) return error.UnsafeDirectory;
            if (st.mode & 0o022 != 0 and !(st.uid == 0 and st.mode & 0o1000 != 0)) return error.UnsafeDirectory;
        }
    }
    return fd;
}
fn captureDirectory(allocator: std.mem.Allocator, lexical: []const u8) !trust.Directory {
    const resolved = try canonical(allocator, lexical);
    errdefer allocator.free(resolved);
    const fd = try walk(resolved, false);
    defer close(fd);
    const st = try inspect(fd);
    if (st.mode & std.c.S.IFMT != std.c.S.IFDIR) return error.UnavailableRoot;
    const birth_time = try directoryBirthTime(st);
    // Detect a symlink retarget or directory replacement across realpath/open.
    // A later replacement still requires explicit revalidation by the owner.
    const again = try canonical(allocator, lexical);
    defer allocator.free(again);
    if (!std.mem.eql(u8, resolved, again)) return error.ScopeChanged;
    const check = try walk(again, false);
    defer close(check);
    const checked = try inspect(check);
    const checked_birth_time = try directoryBirthTime(checked);
    if (!sameNode(st, checked) or !std.meta.eql(birth_time, checked_birth_time)) return error.ScopeChanged;
    return .{
        .lexical = try allocator.dupe(u8, lexical),
        .canonical = resolved,
        .dev_major = st.dev_major,
        .dev_minor = st.dev_minor,
        .inode = st.ino,
        .birth_time = birth_time,
    };
}

/// Capture all roots or fail; offline/missing roots never get invented identities.
/// UnsupportedBirthTime means this filesystem cannot provide the required stable
/// incarnation information: keep restricted, do not retry with dev/inode alone.
/// Join against the lexical manifest parent BEFORE realpath; never collapse '..'
/// across symlinks. The manifest file itself need not exist and is never read.
pub fn capture(allocator: std.mem.Allocator, inputs: *const trust.Inputs) !trust.Identity {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const input = inputs.value;
    const base = if (input.manifest_path) |path| try captureDirectory(a, std.fs.path.dirname(path) orelse return error.InvalidPath) else null;
    const roots = try a.alloc(trust.Directory, input.roots.len);
    for (input.roots, roots) |path, *root| {
        const lexical = if (path[0] == '/') path else try std.fmt.allocPrint(a, "{s}/{s}", .{ base.?.lexical, path });
        root.* = try captureDirectory(a, lexical);
    }
    return .{ .arena = arena, .manifest_base = base, .roots = roots, .policy_digest = input.policy_digest, .fingerprint = trust.fingerprint(base, roots, input.policy_digest) };
}

fn beneath(path: []const u8, root: []const u8) bool {
    return std.mem.startsWith(u8, path, root) and (root.len == 1 or path.len == root.len or path[root.len] == '/');
}
fn outsideWorkspace(home: *const StateHome, identity: *const trust.Identity) !void {
    // StateHome paths cannot contain aliases, dots, or redundant separators; walk
    // rejects all symlinks. Reject even a state home inside a declared root rather
    // than allowing project-local files to become the machine trust authority.
    var buffer: [trust.limits.path_bytes]u8 = undefined;
    const target = try std.fmt.bufPrint(&buffer, "{s}{s}coral/trust", .{ home.path, if (home.path.len == 1) "" else "/" });
    for (identity.roots) |root| if (beneath(target, root.canonical)) return error.StateInsideWorkspace;
    if (identity.manifest_base) |base| {
        if (beneath(target, base.canonical)) return error.StateInsideWorkspace;
    }
}
fn privateDir(parent: c_int, name: [*:0]const u8, create: bool) !c_int {
    if (create) {
        if (std.c.mkdirat(parent, name, 0o700) != 0 and std.c.errno(@as(c_int, -1)) != .EXIST) return error.Io;
    }
    const fd = std.c.openat(parent, name, dir_flags);
    if (fd < 0) return if (std.c.errno(fd) == .NOENT) error.NotFound else error.UnsafeDirectory;
    errdefer close(fd);
    const st = try inspect(fd);
    if (st.uid != std.c.geteuid() or st.mode & 0o7777 != 0o700) return error.UnsafeDirectory;
    // Sync even existing children: another concurrent opener may have just made
    // one but not yet synced its parent. Do not rely on mkdir's winner alone.
    if (create) try sync(parent);
    return fd;
}
fn openStore(home: *const StateHome, create: bool) !c_int {
    const state = try walk(home.path, true);
    defer close(state);
    const st = try inspect(state);
    if (st.uid != std.c.geteuid() or st.mode & 0o022 != 0) return error.UnsafeDirectory;
    const coral = try privateDir(state, "coral", create);
    defer close(coral);
    return privateDir(coral, "trust", create);
}
fn lock(dir: c_int, exclusive: bool) !void {
    if (std.c.flock(dir, (if (exclusive) @as(c_int, std.c.LOCK.EX) else @as(c_int, std.c.LOCK.SH)) | std.c.LOCK.NB) != 0) {
        const err = std.c.errno(@as(c_int, -1));
        // Interrupted acquisition is retryable, never a blocking retry loop.
        return if (err == .AGAIN or err == .INTR) error.Busy else error.Io;
    }
}
fn regular(fd: c_int) !std.os.linux.Statx {
    const st = try inspect(fd);
    if (st.mode & std.c.S.IFMT != std.c.S.IFREG or st.uid != std.c.geteuid() or st.mode & 0o7777 != 0o600 or st.nlink != 1) return error.UnsafeFile;
    return st;
}
fn readRecords(allocator: std.mem.Allocator, dir: c_int) !trust.Records {
    // Any marker object (including a symlink/FIFO) fails closed. Never wait on it.
    const marker = std.c.openat(dir, "uncertain", read_flags);
    if (marker >= 0) {
        close(marker);
        return error.DurabilityUncertain;
    }
    if (std.c.errno(marker) != .NOENT) return error.DurabilityUncertain;
    const fd = std.c.openat(dir, "store", read_flags);
    if (fd < 0) return if (std.c.errno(fd) == .NOENT) trust.Records{} else error.UnsafeFile;
    defer close(fd);
    const st = try regular(fd);
    if (st.size > trust.limits.store_bytes) return error.TooLarge;
    const bytes = try allocator.alloc(u8, @intCast(st.size));
    defer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) return error.CorruptStore;
        offset += @intCast(n);
    }
    var extra: [1]u8 = undefined;
    if (std.c.read(fd, &extra, 1) != 0) return error.CorruptStore;
    const after = try regular(fd);
    if (after.size != st.size or !sameNode(st, after)) return error.CorruptStore;
    return trust.Records.decode(bytes);
}

pub const Decision = struct {
    fingerprint: trust.Fingerprint,
    state: trust.State,
    pub fn approvedKey(self: Decision) ?trust.Fingerprint {
        return if (self.state == .trusted) self.fingerprint else null;
    }
};

/// Errors are intentionally visible (Busy, unsafe mode, corrupt store, OOM, ...).
/// Every error means restricted, NEVER retain an earlier trusted decision. Call
/// Policy.begin before dispatch and Policy.complete(..., null) on error.
pub fn load(allocator: std.mem.Allocator, home: *const StateHome, inputs: *const trust.Inputs) !Decision {
    var identity = try capture(allocator, inputs);
    defer identity.deinit();
    try outsideWorkspace(home, &identity);
    const restricted: Decision = .{ .fingerprint = identity.fingerprint, .state = .restricted };
    const dir = openStore(home, false) catch |err| return if (err == error.NotFound) restricted else err;
    defer close(dir);
    try lock(dir, false);
    const records = try readRecords(allocator, dir);
    return .{ .fingerprint = identity.fingerprint, .state = if (records.contains(identity.fingerprint)) .trusted else .restricted };
}

/// Explicit revalidation always recaptures paths/dev/inodes and re-reads policy.
/// An expected-key mismatch is restricted even if the new scope was approved in
/// another instance; present the new fingerprint for a fresh owner decision.
pub fn revalidate(allocator: std.mem.Allocator, home: *const StateHome, inputs: *const trust.Inputs, expected: trust.Fingerprint) !Decision {
    var result = try load(allocator, home, inputs);
    if (!trust.same(result.fingerprint, expected)) result.state = .restricted;
    return result;
}

pub const Fault = enum { none, during_write, before_rename, after_rename, after_marker_remove };
pub const Hooks = if (@import("builtin").is_test) struct { fault: Fault = .none } else struct {};

/// Caller must explicitly approve the displayed expected fingerprint and call
/// Policy.beginApproval BEFORE dispatch. Capture checks current scope, not just a saved
/// Identity. No policy pointer crosses to this worker. The returned fingerprint
/// must also pass the owner's ticket/model/settings-generation checks.
pub fn approve(allocator: std.mem.Allocator, home: *const StateHome, inputs: *const trust.Inputs, expected: trust.Fingerprint, approval: trust.Approval) !Decision {
    return approveWithHooks(allocator, home, inputs, expected, approval, .{});
}
pub fn approveWithHooks(allocator: std.mem.Allocator, home: *const StateHome, inputs: *const trust.Inputs, expected: trust.Fingerprint, _: trust.Approval, hooks: Hooks) !Decision {
    var identity = try capture(allocator, inputs);
    defer identity.deinit();
    if (!trust.same(expected, identity.fingerprint)) return error.ScopeChanged;
    try outsideWorkspace(home, &identity);
    // Do potentially slow workspace capture BEFORE taking the store lock.
    const dir = try openStore(home, true);
    defer close(dir);
    try lock(dir, true);
    var records = try readRecords(allocator, dir); // re-read/merge under lock
    try records.approve(identity.fingerprint);
    try save(allocator, dir, &records, hooks);
    return .{ .fingerprint = identity.fingerprint, .state = .trusted };
}

/// FIRST call Policy.revoke on the owner (invalidates pending permits/results),
/// then dispatch this worker. On EVERY error keep that local policy restricted
/// and surface a retry: old persistent approval may remain. Revoke the previously
/// approved key even when its roots no longer exist; no workspace I/O is needed.
/// Other running instances must explicitly revalidate to observe this revocation.
/// The caller must serialize its own mutations: drain any already-dispatched
/// approval before dispatching revoke, so that an old worker cannot persist a
/// later approval. Generation checks alone protect local state, not disk order.
pub fn revoke(allocator: std.mem.Allocator, home: *const StateHome, key: trust.Fingerprint) !void {
    return revokeWithHooks(allocator, home, key, .{});
}
pub fn revokeWithHooks(allocator: std.mem.Allocator, home: *const StateHome, key: trust.Fingerprint, hooks: Hooks) !void {
    const dir = openStore(home, false) catch |err| return if (err == error.NotFound) {} else err;
    defer close(dir);
    try lock(dir, true);
    var records = try readRecords(allocator, dir);
    records.revoke(key);
    try save(allocator, dir, &records, hooks);
}

fn remove(dir: c_int, name: [*:0]const u8) !void {
    if (std.c.unlinkat(dir, name, 0) != 0 and std.c.errno(@as(c_int, -1)) != .NOENT) return error.Io;
}
fn createFile(dir: c_int, name: [*:0]const u8) !c_int {
    const fd = std.c.openat(dir, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.UnsafeFile;
    errdefer close(fd);
    if (std.c.fchmod(fd, 0o600) != 0) return error.Io;
    _ = try regular(fd);
    return fd;
}
fn quarantine(dir: c_int) !void {
    const fd = try createFile(dir, "uncertain");
    defer close(fd);
    try sync(fd);
    try sync(dir);
}
fn save(allocator: std.mem.Allocator, dir: c_int, records: *const trust.Records, hooks: Hooks) !void {
    const bytes = try records.encode(allocator);
    defer allocator.free(bytes);
    // A crash can leave pending. Unlink only the entry, never follow its target.
    // The stable directory lock serializes writers across atomic store renames.
    try remove(dir, "pending");
    const fd = try createFile(dir, "pending");
    defer close(fd);
    defer remove(dir, "pending") catch {};
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) return error.Io;
        offset += @intCast(n);
        if (@import("builtin").is_test and hooks.fault == .during_write) return error.InjectedFailure;
    }
    try sync(fd);
    if (@import("builtin").is_test and hooks.fault == .before_rename) return error.InjectedFailure;
    // Durable fail-closed marker BEFORE commit. Any crash/failed sync thereafter
    // prevents future loads from silently accepting an uncertain approval.
    // A quarantined store requires explicit machine-owner repair, not an automatic
    // retry that could resurrect approvals. Never discard corrupt-store evidence.
    try quarantine(dir);
    if (std.c.renameat(dir, "pending", dir, "store") != 0) return error.Io;
    if (@import("builtin").is_test and hooks.fault == .after_rename) return error.DurabilityUncertain;
    sync(dir) catch return error.DurabilityUncertain;
    try remove(dir, "uncertain");
    if (@import("builtin").is_test and hooks.fault == .after_marker_remove) {
        quarantine(dir) catch {};
        return error.DurabilityUncertain;
    }
    sync(dir) catch {
        // Best-effort re-quarantine after failed marker-deletion durability. No
        // filesystem protocol can promise persistence when subsequent I/O also
        // fails; report uncertainty and NEVER grant locally in that case.
        quarantine(dir) catch {};
        return error.DurabilityUncertain;
    };
}
