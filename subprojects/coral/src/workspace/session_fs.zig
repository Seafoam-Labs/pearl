//! Linux synchronous WORKER ONLY explicit saved-session backend. No automatic
//! checkpoint, discard, recovery, or trust integration. Call only on explicit save.
//! Protects against other users and accidental symlinks, not a malicious same UID.
//! Existing state home is required; only coral/sessions is created (0700).
//! current is a single 0600 file. Directory flock survives atomic file replacement.
const std = @import("std");
const model = @import("session_model.zig");
const recovery = @import("recovery_model.zig");
const a = std.heap.c_allocator;
const path_flags: std.c.O = .{ .PATH = true, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };
const dir_flags: std.c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true };
const read_flags: std.c.O = .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true };
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

fn close(fd: c_int) void {
    _ = std.c.close(fd);
}
fn inspect(fd: c_int) !std.os.linux.Statx {
    var st: std.os.linux.Statx = undefined;
    const mask: std.os.linux.STATX = .{ .TYPE = true, .MODE = true, .UID = true, .NLINK = true, .SIZE = true };
    while (std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, mask, &st) != 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return error.Io;
    }
    if (!st.mask.TYPE or !st.mask.MODE or !st.mask.UID or !st.mask.NLINK or !st.mask.SIZE) return error.Io;
    return st;
}
fn sync(fd: c_int) !void {
    while (std.c.fsync(fd) != 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return error.Io;
    }
}
fn ancestor(fd: c_int) !void {
    const st = try inspect(fd);
    if (st.mode & std.c.S.IFMT != std.c.S.IFDIR) return error.UnsafeDirectory;
    if (st.uid != 0 and st.uid != std.c.geteuid()) return error.UnsafeDirectory;
    // Root-owned sticky /tmp cannot have our child removed by another UID.
    if (st.mode & 0o022 != 0 and !(st.uid == 0 and st.mode & 0o1000 != 0)) return error.UnsafeDirectory;
}
fn walk(path: []const u8, create: bool) !c_int {
    try recovery.nativePath(path);
    var fd = std.c.open("/", path_flags);
    if (fd < 0) return error.Io;
    errdefer close(fd);
    try ancestor(fd);
    if (path.len > 1) {
        var parts = std.mem.splitScalar(u8, path[1..], '/');
        while (parts.next()) |part| {
            if (part.len == 0 or part.len > 255) return error.InvalidPath;
            var name: [256:0]u8 = @splat(0);
            @memcpy(name[0..part.len], part);
            const next = std.c.openat(fd, &name, path_flags);
            if (next < 0) return if (std.c.errno(next) == .NOENT) (if (create) error.MissingStateHome else error.NotFound) else error.UnsafeDirectory;
            close(fd);
            fd = next;
            try ancestor(fd);
        }
    }
    const st = try inspect(fd);
    if (st.uid != std.c.geteuid() or st.mode & 0o022 != 0) return error.UnsafeDirectory;
    return fd;
}
fn privateDir(parent: c_int, name: [*:0]const u8, create: bool) !c_int {
    if (create) {
        if (std.c.mkdirat(parent, name, 0o700) != 0 and std.c.errno(@as(c_int, -1)) != .EXIST) return error.Io;
    }
    const fd = std.c.openat(parent, name, dir_flags);
    if (fd < 0) return if (std.c.errno(fd) == .NOENT) error.NotFound else error.UnsafeDirectory;
    errdefer close(fd);
    const st = try inspect(fd);
    if (st.mode & std.c.S.IFMT != std.c.S.IFDIR or st.uid != std.c.geteuid() or st.mode & 0o7777 != 0o700) return error.UnsafeDirectory;
    // Also sync existing children: a concurrent mkdir winner may not have synced.
    if (create) try sync(parent);
    return fd;
}
fn openStore(override: ?[]const u8, create: bool) !c_int {
    var fallback: ?[]u8 = null;
    defer if (fallback) |p| a.free(p);
    const path = override orelse blk: {
        if (getenv("XDG_STATE_HOME")) |p| {
            if (p[0] != 0) break :blk std.mem.span(p);
        }
        const home = getenv("HOME") orelse return error.MissingStateHome;
        if (home[0] == 0) return error.MissingStateHome;
        fallback = try std.fmt.allocPrint(a, "{s}/.local/state", .{std.mem.span(home)});
        break :blk fallback.?;
    };
    const traversed = try walk(path, create);
    defer close(traversed);
    // Ancestors need only search permission. Reopen the already-checked state
    // home itself for fsync when saving; never reopen via its absolute pathname.
    const state = if (create) std.c.openat(traversed, ".", dir_flags) else traversed;
    if (state < 0) return error.UnsafeDirectory;
    defer if (create) close(state);
    const coral = try privateDir(state, "coral", create);
    defer close(coral);
    return privateDir(coral, "sessions", create);
}
fn lock(dir: c_int, exclusive: bool) !void {
    const kind: c_int = if (exclusive) std.c.LOCK.EX else std.c.LOCK.SH;
    if (std.c.flock(dir, kind | std.c.LOCK.NB) != 0) {
        const err = std.c.errno(@as(c_int, -1));
        return if (err == .AGAIN or err == .INTR) error.Busy else error.Io;
    }
}
fn regular(fd: c_int) !std.os.linux.Statx {
    const st = try inspect(fd);
    if (st.mode & std.c.S.IFMT != std.c.S.IFREG or st.uid != std.c.geteuid() or st.mode & 0o7777 != 0o600 or st.nlink != 1) return error.UnsafeFile;
    return st;
}
fn readCurrent(dir: c_int) !*model.Owned {
    const fd = std.c.openat(dir, "current", read_flags);
    if (fd < 0) return if (std.c.errno(fd) == .NOENT) error.NotFound else error.UnsafeFile;
    defer close(fd);
    const st = try regular(fd);
    if (st.size > model.limits.session_bytes) return error.TooLarge;
    const bytes = try a.alloc(u8, @intCast(st.size));
    defer a.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n < 0) return error.Io;
        if (n == 0) return error.CorruptSession;
        offset += @intCast(n);
    }
    var extra: [1]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &extra, 1);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n < 0) return error.Io;
        if (n != 0) return error.CorruptSession;
        break;
    }
    const after = try regular(fd);
    if (after.size != st.size) return error.CorruptSession;
    return model.decode(bytes);
}

/// Synchronous WORKER ONLY. Missing slot returns NotFound, without creating dirs.
/// Caller owns the result. Workspace paths are metadata, never followed here.
/// Prefer a copied explicit state_home; null reads XDG_STATE_HOME/HOME, which the
/// caller must not concurrently mutate. The default follows the XDG fallback.
pub fn load(state_home: ?[]const u8) !*model.Owned {
    const dir = try openStore(state_home, false);
    defer close(dir);
    try lock(dir, false);
    return readCurrent(dir);
}

pub const Fault = enum { none, during_write, before_rename, after_rename };
pub const Hooks = if (@import("builtin").is_test) struct { fault: Fault = .none, terminate_process: bool = false } else struct {};
fn inject(hooks: Hooks, fault: Fault) !void {
    if (@import("builtin").is_test and hooks.fault == fault) {
        if (hooks.terminate_process) std.c._exit(73);
        return if (fault == .after_rename) error.DurabilityUncertain else error.InjectedFailure;
    }
}
fn removePending(dir: c_int) !void {
    if (std.c.unlinkat(dir, "pending", 0) != 0 and std.c.errno(@as(c_int, -1)) != .NOENT) return error.Io;
}

/// Synchronous WORKER ONLY. Borrowed value must remain immutable until return.
/// Serializes validation + replacement under nonblocking flock; Busy is retryable.
/// Last accepted explicit save wins. This ABI has no expected generation/hash,
/// so it cannot detect a stale edit captured before a different completed save.
/// Pre-rename errors retain current; DurabilityUncertain means rename committed
/// but persistence is unconfirmed. Do not treat that as an uncommitted save.
pub fn save(state_home: ?[]const u8, value: model.Value) !void {
    return saveWithHooks(state_home, value, .{});
}
pub fn saveWithHooks(state_home: ?[]const u8, value: model.Value, hooks: Hooks) !void {
    const bytes = try model.encode(a, value);
    defer a.free(bytes);
    const dir = try openStore(state_home, true);
    defer close(dir);
    try lock(dir, true);
    // Only a genuinely absent slot can skip validation. Preserve every corrupt,
    // unsupported, oversized, or unsafe current entry, including symlinks.
    const previous = readCurrent(dir) catch |err| switch (err) {
        error.NotFound => null,
        else => return err,
    };
    if (previous) |owned| owned.deinit();
    // A crashed writer can leave pending. Unlink the entry, never its target.
    try removePending(dir);
    const fd = std.c.openat(dir, "pending", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.Io;
    defer close(fd);
    defer removePending(dir) catch {};
    if (std.c.fchmod(fd, 0o600) != 0) return error.Io;
    _ = try regular(fd);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(bytes.len, offset + 65536);
        const n = std.c.write(fd, bytes[offset..end].ptr, end - offset);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) return error.Io;
        offset += @intCast(n);
        try inject(hooks, .during_write);
    }
    try sync(fd);
    try inject(hooks, .before_rename);
    if (std.c.renameat(dir, "pending", dir, "current") != 0) return error.Io;
    try inject(hooks, .after_rename);
    sync(dir) catch return error.DurabilityUncertain;
}
