//! Linux descriptor-relative persistence. Every public operation here blocks;
//! call only at startup before presenting UI or from a worker, never autosave UI.
//! No path from a snapshot is ever passed to this module.
//! Security boundary: other Unix users and accidental symlinks, not a malicious
//! process with the same uid (which can rename owned directories or ptrace us).
const std = @import("std");
const c = @import("pearl_app_c");
const model = @import("recovery_model.zig");
const a = std.heap.c_allocator;
const dir_flags: std.c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };
pub const max_sessions = 256;
pub const Approval = enum { user_approved };
pub const Checkpoint = enum {
    durable,
    /// Rename committed a complete, file-fsynced manifest, but directory fsync
    /// failed. This is NOT a failed pre-commit write: the new snapshot is valid,
    /// but power-loss durability is unknown. Retain the journal and warn/retry.
    durability_uncertain,
};
pub const Fault = enum { none, during_write, before_rename, after_rename };
pub const Hooks = if (@import("builtin").is_test) struct { fault: Fault = .none, terminate_process: bool = false } else struct {};

pub const SessionId = struct {
    bytes: [36]u8,
    pub fn parse(input: []const u8) !SessionId {
        if (input.len != 36 or !std.mem.startsWith(u8, input, "s-")) return error.InvalidSessionId;
        // UUID without hyphens, plus two reserved hex digits (122 random bits).
        for (input[2..]) |ch| if (!std.ascii.isHex(ch) or std.ascii.isUpper(ch)) return error.InvalidSessionId;
        var id: SessionId = undefined;
        @memcpy(&id.bytes, input);
        return id;
    }
    pub fn name(self: *const SessionId) []const u8 {
        return &self.bytes;
    }
    fn terminated(self: SessionId) [37:0]u8 {
        var out: [37:0]u8 = @splat(0);
        @memcpy(out[0..36], &self.bytes);
        return out;
    }
};
pub const Candidate = struct {
    id: SessionId,
    /// Busy sessions are omitted. Unsafe entries are reported, not followed or
    /// deleted. Stale entries can still be empty/corrupt/future-version: load()
    /// determines that after claim(), and never removes evidence on failure.
    state: enum { stale, unsafe },
};
pub const Discovery = struct {
    entries: []Candidate,
    pub fn deinit(self: Discovery) void {
        a.free(self.entries);
    }
};

/// Open an existing absolute state home. Null selects XDG_STATE_HOME, falling
/// back to HOME/.local/state. Missing state-home ancestors are NOT created:
/// provision them separately, or report MissingStateHome to the user. Only
/// coral/recovery and session children are created here. State home must be
/// owned by euid and not group/world writable. Every component is O_NOFOLLOW;
/// symlinked XDG/HOME paths are intentionally unsupported, not canonicalized.
pub fn openRoot(state_home: ?[]const u8) !c_int {
    var fallback: ?[]u8 = null;
    defer if (fallback) |p| a.free(p);
    const path = state_home orelse blk: {
        const xdg = c.g_getenv("XDG_STATE_HOME");
        if (xdg != null and xdg[0] != 0) break :blk std.mem.span(xdg);
        const home = c.g_getenv("HOME");
        if (home == null or home[0] == 0) return error.MissingStateHome;
        fallback = try std.fmt.allocPrint(a, "{s}/.local/state", .{std.mem.span(home)});
        break :blk fallback.?;
    };
    try model.nativePath(path);
    var fd = std.c.open("/", dir_flags);
    if (fd < 0) return error.Io;
    defer close(fd);
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const z = try a.dupeSentinel(u8, part, 0);
        defer a.free(z);
        const next = std.c.openat(fd, z, dir_flags);
        if (next < 0) return if (std.c.errno(next) == .NOENT) error.MissingStateHome else error.UnsafeDirectory;
        close(fd);
        fd = next;
    }
    const stat = try inspect(fd);
    if (stat.st_uid != std.c.geteuid() or stat.st_mode & 0o022 != 0) return error.UnsafeDirectory;
    const coral = try privateDir(fd, "coral", true);
    defer close(coral);
    return privateDir(coral, "recovery", true);
}

pub fn close(fd: c_int) void {
    _ = std.c.close(fd);
}
fn inspect(fd: c_int) !c.GStatBuf {
    var stat: c.GStatBuf = undefined;
    while (c.fstat(fd, &stat) != 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return error.Io;
    }
    return stat;
}
fn privateDir(parent: c_int, name: [*:0]const u8, create: bool) !c_int {
    var made = false;
    if (create) {
        if (std.c.mkdirat(parent, name, 0o700) == 0) made = true else if (std.c.errno(@as(c_int, -1)) != .EXIST) return error.Io;
    }
    const fd = std.c.openat(parent, name, dir_flags);
    if (fd < 0) return error.UnsafeDirectory;
    errdefer close(fd);
    const stat = try inspect(fd);
    if (stat.st_uid != std.c.geteuid() or stat.st_mode & 0o7777 != 0o700) return error.UnsafeDirectory;
    if (made) try sync(parent);
    return fd;
}
fn sync(fd: c_int) !void {
    while (std.c.fsync(fd) != 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return error.Io;
    }
}
fn lock(fd: c_int, nonblock: bool) !void {
    while (std.c.flock(fd, std.c.LOCK.EX | @as(c_int, if (nonblock) std.c.LOCK.NB else 0)) != 0) {
        const code = std.c.errno(@as(c_int, -1));
        if (code == .INTR) continue;
        if (code == .AGAIN) return error.ActiveSession;
        return error.Io;
    }
}
fn unlock(fd: c_int) void {
    _ = std.c.flock(fd, std.c.LOCK.UN);
}

/// Holds BOTH root and session descriptors. Directory flock is stable across
/// manifest replacement; no removable lockfile inode race. Root flock serializes
/// create/claim/discard so a not-yet-locked new session cannot be recovered.
/// Each Journal gets a separate root open description (do not dup for locks).
/// Not thread-safe: owned exclusively by a Store worker or recovery controller.
pub const Journal = struct {
    root: c_int,
    dir: c_int,
    id: SessionId,

    pub fn create(state_home: ?[]const u8) !Journal {
        const root = try openRoot(state_home);
        errdefer close(root);
        try lock(root, false);
        defer unlock(root);
        for (0..8) |_| {
            const uuid = c.g_uuid_string_random();
            defer c.g_free(uuid);
            var bytes: [36]u8 = undefined;
            @memcpy(bytes[0..2], "s-");
            var i: usize = 2;
            for (std.mem.span(uuid)) |ch| if (ch != '-') {
                bytes[i] = ch;
                i += 1;
            };
            @memcpy(bytes[34..36], "00");
            const id = try SessionId.parse(&bytes);
            const name = id.terminated();
            if (std.c.mkdirat(root, &name, 0o700) != 0) {
                if (std.c.errno(@as(c_int, -1)) == .EXIST) continue;
                return error.Io;
            }
            errdefer _ = std.c.unlinkat(root, &name, std.c.AT.REMOVEDIR);
            const dir = try privateDir(root, &name, false);
            errdefer close(dir);
            try lock(dir, true);
            try sync(root);
            return .{ .root = root, .dir = dir, .id = id };
        }
        return error.SessionCollision;
    }

    pub fn claim(state_home: ?[]const u8, id: SessionId) !Journal {
        _ = try SessionId.parse(&id.bytes);
        const root = try openRoot(state_home);
        errdefer close(root);
        try lock(root, false);
        defer unlock(root);
        const name = id.terminated();
        const dir = try privateDir(root, &name, false);
        errdefer close(dir);
        try lock(dir, true);
        return .{ .root = root, .dir = dir, .id = id };
    }

    /// Dismissal/release retains the journal, including corrupt or unknown data.
    pub fn release(self: *Journal) void {
        close(self.dir);
        close(self.root);
        self.dir = -1;
        self.root = -1;
    }

    /// An empty, exclusively claimed session has no recovery payload. This is
    /// not discard approval: never unlink ANY entry, including pending writes,
    /// zero-length/corrupt manifests or unknown files. rmdir is the final atomic
    /// emptiness check. Keep descriptors locked until the caller releases them.
    pub fn removeIfEmpty(self: *const Journal) !bool {
        try lock(self.root, false);
        defer unlock(self.root);
        const entries = try directoryStream(self.dir);
        defer _ = std.c.closedir(entries);
        while (try nextEntry(entries)) |entry| {
            if (!std.mem.eql(u8, entry, ".") and !std.mem.eql(u8, entry, "..")) return false;
        }
        const name = self.id.terminated();
        const check = try privateDir(self.root, &name, false);
        defer close(check);
        const held = try inspect(self.dir);
        const current = try inspect(check);
        if (held.st_dev != current.st_dev or held.st_ino != current.st_ino) return error.UnsafeDirectory;
        if (std.c.unlinkat(self.root, &name, std.c.AT.REMOVEDIR) != 0) {
            if (std.c.errno(@as(c_int, -1)) == .NOTEMPTY) return false;
            return error.Io;
        }
        try sync(self.root);
        return true;
    }

    pub fn load(self: *const Journal) !*model.OwnedSnapshot {
        const fd = std.c.openat(self.dir, "manifest", .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
        if (fd < 0) return if (std.c.errno(fd) == .NOENT) error.NoCheckpoint else error.UnsafeFile;
        defer close(fd);
        const stat = try regular(fd);
        if (stat.st_size < 0 or stat.st_size > model.limits.manifest_bytes) return error.TooLarge;
        const bytes = try a.alloc(u8, @intCast(stat.st_size));
        defer a.free(bytes);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = std.c.read(fd, bytes[offset..].ptr, bytes.len - offset);
            if (n < 0) {
                if (std.c.errno(n) == .INTR) continue;
                return error.Io;
            }
            if (n == 0) return error.CorruptManifest;
            offset += @intCast(n);
        }
        var extra: [1]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &extra, 1);
            if (n < 0 and std.c.errno(n) == .INTR) continue;
            if (n != 0) return error.CorruptManifest;
            break;
        }
        return model.decode(bytes);
    }

    pub fn checkpoint(self: *const Journal, value: model.Snapshot) !Checkpoint {
        return self.checkpointWithHooks(value, .{});
    }

    /// Optional worker-only observation point after file fsync, before rename.
    /// Used by native crash tests; it never changes the commit protocol.
    pub fn checkpointObserved(self: *const Journal, value: model.Snapshot, before_commit: ?*const fn () void) !Checkpoint {
        return self.checkpointImpl(value, .{}, before_commit);
    }

    pub fn checkpointWithHooks(self: *const Journal, value: model.Snapshot, hooks: Hooks) !Checkpoint {
        return self.checkpointImpl(value, hooks, null);
    }

    fn checkpointImpl(self: *const Journal, value: model.Snapshot, hooks: Hooks, before_commit: ?*const fn () void) !Checkpoint {
        const bytes = try model.encode(a, value);
        defer a.free(bytes);
        // A crash may leave this fixed temp name. Unlink removes only this entry,
        // never a symlink target. O_EXCL prevents reopening an attacker inode.
        try removeFile(self.dir, "pending");
        const fd = std.c.openat(self.dir, "pending", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.Io;
        defer close(fd);
        defer removeFile(self.dir, "pending") catch {};
        if (std.c.fchmod(fd, 0o600) != 0) return error.Io;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(bytes.len, offset + 65536);
            const n = std.c.write(fd, bytes[offset..end].ptr, end - offset);
            if (n < 0) {
                if (std.c.errno(n) == .INTR) continue;
                return error.Io;
            }
            if (n == 0) return error.Io;
            offset += @intCast(n);
            if (@import("builtin").is_test and hooks.fault == .during_write) {
                if (hooks.terminate_process) std.c._exit(73);
                return error.InjectedFailure;
            }
        }
        try sync(fd);
        if (@import("builtin").is_test and hooks.fault == .before_rename) {
            if (hooks.terminate_process) std.c._exit(73);
            return error.InjectedFailure;
        }
        if (before_commit) |observe| observe();
        if (std.c.renameat(self.dir, "pending", self.dir, "manifest") != 0) return error.Io;
        // Never report a pre-commit failure after the rename commit point.
        if (@import("builtin").is_test and hooks.fault == .after_rename) {
            if (hooks.terminate_process) std.c._exit(73);
            return .durability_uncertain;
        }
        sync(self.dir) catch return .durability_uncertain;
        return .durable;
    }

    /// Requires explicit user approval. Removes only this claimed session, never
    /// siblings, workspace paths, unknown entries, or a recursively walked tree.
    /// Keeps the lock/descriptors held even on error; caller must release().
    pub fn discard(self: *const Journal, _: Approval) !void {
        try lock(self.root, false);
        defer unlock(self.root);
        const entries = try directoryStream(self.dir);
        defer _ = std.c.closedir(entries);
        var count: usize = 0;
        while (try nextEntry(entries)) |name| {
            count += 1;
            if (count > 4) return error.UnexpectedEntry;
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and !std.mem.eql(u8, name, "manifest") and !std.mem.eql(u8, name, "pending")) return error.UnexpectedEntry;
        }
        try removeFile(self.dir, "pending");
        try removeFile(self.dir, "manifest");
        try sync(self.dir);
        const name = self.id.terminated();
        // Ensure our root entry still names this locked inode before removal.
        const check = try privateDir(self.root, &name, false);
        defer close(check);
        const held = try inspect(self.dir);
        const current = try inspect(check);
        if (held.st_dev != current.st_dev or held.st_ino != current.st_ino) return error.UnsafeDirectory;
        if (std.c.unlinkat(self.root, &name, std.c.AT.REMOVEDIR) != 0) return error.Io;
        try sync(self.root);
    }
};

fn regular(fd: c_int) !c.GStatBuf {
    const stat = try inspect(fd);
    if (stat.st_mode & c.S_IFMT != c.S_IFREG or stat.st_uid != std.c.geteuid() or stat.st_mode & 0o7777 != 0o600 or stat.st_nlink != 1) return error.UnsafeFile;
    return stat;
}
fn removeFile(dir: c_int, name: [*:0]const u8) !void {
    if (std.c.unlinkat(dir, name, 0) != 0 and std.c.errno(@as(c_int, -1)) != .NOENT) return error.Io;
}
fn directoryStream(fd: c_int) !*std.c.DIR {
    // openat rather than dup: separate directory offset for each enumeration.
    const copy = std.c.openat(fd, ".", dir_flags);
    if (copy < 0) return error.Io;
    return std.c.fdopendir(copy) orelse {
        close(copy);
        return error.Io;
    };
}
fn nextEntry(stream: *std.c.DIR) !?[]const u8 {
    std.c._errno().* = 0;
    const entry = std.c.readdir(stream) orelse {
        if (std.c._errno().* != 0) return error.Io;
        return null;
    };
    return std.mem.sliceTo(&entry.name, 0);
}

/// Caller owns returned list (deinit). Discovery only probes locks; it doesn't
/// reserve a session. claim() is authoritative and may return ActiveSession.
/// No automatic deletion, age expiry, or silently truncated discovery.
pub fn discover(state_home: ?[]const u8) !Discovery {
    const root = try openRoot(state_home);
    defer close(root);
    try lock(root, false);
    defer unlock(root);
    const stream = try directoryStream(root);
    defer _ = std.c.closedir(stream);
    var list: std.ArrayList(Candidate) = .empty;
    errdefer list.deinit(a);
    var scanned: usize = 0;
    while (try nextEntry(stream)) |name| {
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        scanned += 1;
        if (scanned > max_sessions) return error.TooManySessions;
        const id = SessionId.parse(name) catch return error.UnexpectedEntry;
        const z = id.terminated();
        const dir = privateDir(root, &z, false) catch {
            try list.append(a, .{ .id = id, .state = .unsafe });
            continue;
        };
        defer close(dir);
        lock(dir, true) catch |err| {
            if (err == error.ActiveSession) continue;
            return err;
        };
        try list.append(a, .{ .id = id, .state = .stale });
    }
    return .{ .entries = try list.toOwnedSlice(a) };
}
