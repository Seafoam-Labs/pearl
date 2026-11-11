//! Linux worker-only automatic-LSP lifecycle persistence; link libc.
//! Snapshot Home.init(allocator, null) on the main/owner thread before workers.
//! Home is machine configuration (absolute XDG_STATE_HOME, otherwise
//! HOME/.local/state), NEVER workspace configuration. Its ancestors must already
//! exist. Only coral/language is created; no trust store is read or written.
//! Filesystem metadata, regular I/O and fsync can block: never call these APIs
//! on the UI thread. Directory flock is nonblocking; Busy is retryable.
//!
//! Keys are caller-domain-separated 32-byte digests, not paths or commands.
//! Approval and workspace pause are independent flags, NOT workspace trust or
//! permission to execute. The caller must enforce trust and invalidate cached
//! decisions on every error; an error is never an empty/allowing snapshot.
//! Serialize same-key user intents before dispatch: latest locked mutation wins,
//! not worker submission order. No snapshot writeback API is provided.
//!
//! Symlinks and other-user writable state are rejected. This is not a sandbox
//! against a malicious same-uid process, mount aliases, or filesystem failure.
//! Before queueing any operation, call the pure validateLocation with actual
//! canonical workspace roots and manifest base. Cwd is not workspace identity.
const std = @import("std");

pub const Key = [32]u8;
pub const Home = @import("../workspace/trust_fs.zig").StateHome;
const capacity = 128;
const header = "CORAL-LANGUAGE-APPROVALS 1\n";
const row_bytes = 67; // domain tag, space, lowercase hex key, newline
const checksum_prefix = "SHA256 ";
const trailer_bytes = checksum_prefix.len + 64 + 1;
const max_bytes = header.len + 2 * capacity * row_bytes + trailer_bytes;
const dir_flags: std.c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true };
const read_flags: std.c.O = .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true };

/// Owned, allocation-free value. Only the prefixes selected by the lengths are
/// populated. No eviction: the 129th distinct key in either domain is StoreFull.
pub const Snapshot = struct {
    approved: [capacity]Key = @splat(@splat(0)),
    approved_len: usize = 0,
    paused: [capacity]Key = @splat(@splat(0)),
    paused_len: usize = 0,

    pub fn isApproved(self: *const Snapshot, key: Key) bool {
        return indexOf(self.approved[0..self.approved_len], key) != null;
    }

    pub fn isPaused(self: *const Snapshot, workspaceKey: Key) bool {
        return indexOf(self.paused[0..self.paused_len], workspaceKey) != null;
    }
};

fn indexOf(keys: []const Key, key: Key) ?usize {
    for (keys, 0..) |existing, i| if (std.mem.eql(u8, &existing, &key)) return i;
    return null;
}

fn insert(keys: *[capacity]Key, len: *usize, key: Key) !void {
    if (indexOf(keys[0..len.*], key) != null) return;
    if (len.* == capacity) return error.StoreFull;
    keys[len.*] = key;
    len.* += 1;
}

/// Worker-only. Only an absent store/directory yields an empty snapshot.
/// Corruption, unsafe metadata, missing state-home ancestors and Busy propagate.
pub fn read(allocator: std.mem.Allocator, home: *const Home) !Snapshot {
    const dir = openStore(home, false) catch |err| return if (err == error.NotFound) .{} else err;
    defer close(dir);
    try lock(dir, false);
    return readLocked(allocator, dir);
}

/// Worker-only. Re-read and merge under an exclusive lock, then durably publish.
/// This records a lifecycle flag only; workspace trust remains caller-enforced.
pub fn approve(allocator: std.mem.Allocator, home: *const Home, key: Key) !void {
    const dir = try openStore(home, true);
    defer close(dir);
    try lock(dir, true);
    var snapshot = try readLocked(allocator, dir);
    try insert(&snapshot.approved, &snapshot.approved_len, key);
    try save(allocator, dir, &snapshot);
}

/// Worker-only. Idempotent, independent of approval; false removes only this
/// workspace pause. Unrelated changes from other processes are always preserved.
pub fn setPaused(allocator: std.mem.Allocator, home: *const Home, workspace: Key, paused: bool) !void {
    const dir = openStore(home, paused) catch |err| return if (!paused and err == error.NotFound) {} else err;
    defer close(dir);
    try lock(dir, true);
    var snapshot = try readLocked(allocator, dir);
    if (paused) {
        try insert(&snapshot.paused, &snapshot.paused_len, workspace);
    } else if (indexOf(snapshot.paused[0..snapshot.paused_len], workspace)) |i| {
        std.mem.copyForwards(Key, snapshot.paused[i .. snapshot.paused_len - 1], snapshot.paused[i + 1 .. snapshot.paused_len]);
        snapshot.paused_len -= 1;
        snapshot.paused[snapshot.paused_len] = @splat(0);
    }
    try save(allocator, dir, &snapshot);
}

fn close(fd: c_int) void {
    _ = std.c.close(fd);
}

fn inspect(fd: c_int) !std.os.linux.Statx {
    var st: std.os.linux.Statx = undefined;
    const mask: std.os.linux.STATX = .{ .TYPE = true, .MODE = true, .UID = true, .NLINK = true, .INO = true, .SIZE = true };
    while (std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, mask, &st) != 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return error.Io;
    }
    if (!st.mask.TYPE or !st.mask.MODE or !st.mask.UID or !st.mask.NLINK or !st.mask.INO or !st.mask.SIZE) return error.Io;
    return st;
}

fn sync(fd: c_int) !void {
    while (std.c.fsync(fd) != 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return error.Io;
    }
}

fn validatePath(path: []const u8) !void {
    try validateCanonicalPath(path);
    if (path.len + "/coral/language/uncertain".len >= 4096) return error.InvalidPath;
}

fn validateCanonicalPath(path: []const u8) !void {
    if (path.len == 0 or path.len >= 4096 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
    if (path.len == 1) return;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 255 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidPath;
    }
}

/// Pure, allocation-free owner-thread guard for EVERY operation, including pause
/// and unpause. Reject the actual coral/language target inside any configured
/// workspace root or manifest base, not the process cwd or the state home alone.
/// Callers supply canonical filesystem identities captured off-thread; this
/// checks path syntax/boundaries, not symlink resolution or workspace trust.
/// Workers still check every state component without following symlinks.
pub fn validateLocation(home: *const Home, canonical_roots: []const []const u8, manifest_base: ?[]const u8) !void {
    try validatePath(home.path);
    var target_buffer: [4096]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "{s}{s}coral/language", .{ home.path, if (home.path.len == 1) "" else "/" });
    for (canonical_roots) |root| try outside(target, root);
    if (manifest_base) |base| try outside(target, base);
}

fn outside(target: []const u8, forbidden: []const u8) !void {
    try validateCanonicalPath(forbidden);
    if (std.mem.startsWith(u8, target, forbidden) and (forbidden.len == 1 or target.len == forbidden.len or target[forbidden.len] == '/')) return error.StateInsideWorkspace;
}

fn safeAncestor(fd: c_int) !void {
    const st = try inspect(fd);
    if (st.mode & std.c.S.IFMT != std.c.S.IFDIR or (st.uid != 0 and st.uid != std.c.geteuid())) return error.UnsafeDirectory;
    // Root-owned sticky /tmp is safe for a private, user-owned state home.
    if (st.mode & 0o022 != 0 and !(st.uid == 0 and st.mode & 0o1000 != 0)) return error.UnsafeDirectory;
}

fn walk(path: []const u8) !c_int {
    var fd = std.c.open("/", dir_flags);
    if (fd < 0) return error.Io;
    errdefer close(fd);
    try safeAncestor(fd);
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        var name: [256:0]u8 = @splat(0);
        @memcpy(name[0..part.len], part);
        const next = std.c.openat(fd, &name, dir_flags);
        if (next < 0) return if (std.c.errno(next) == .NOENT) error.MissingStateHome else error.UnsafeDirectory;
        close(fd);
        fd = next;
        try safeAncestor(fd);
    }
    const st = try inspect(fd);
    if (st.uid != std.c.geteuid() or st.mode & 0o022 != 0) return error.UnsafeDirectory;
    return fd;
}

fn privateDir(parent: c_int, name: [*:0]const u8, create: bool) !c_int {
    if (create and std.c.mkdirat(parent, name, 0o700) != 0 and std.c.errno(@as(c_int, -1)) != .EXIST) return error.Io;
    const fd = std.c.openat(parent, name, dir_flags);
    if (fd < 0) return if (std.c.errno(fd) == .NOENT) error.NotFound else error.UnsafeDirectory;
    errdefer close(fd);
    const st = try inspect(fd);
    if (st.mode & std.c.S.IFMT != std.c.S.IFDIR or st.uid != std.c.geteuid() or st.mode & 0o7777 != 0o700) return error.UnsafeDirectory;
    // Also sync an existing child: a concurrent creator may not have synced yet.
    if (create) try sync(parent);
    return fd;
}

fn openStore(home: *const Home, create: bool) !c_int {
    try validatePath(home.path);
    const state = try walk(home.path);
    defer close(state);
    const coral = try privateDir(state, "coral", create);
    defer close(coral);
    return privateDir(coral, "language", create);
}

fn lock(dir: c_int, exclusive: bool) !void {
    if (std.c.flock(dir, (if (exclusive) @as(c_int, std.c.LOCK.EX) else @as(c_int, std.c.LOCK.SH)) | std.c.LOCK.NB) != 0) {
        const err = std.c.errno(@as(c_int, -1));
        return if (err == .AGAIN or err == .INTR) error.Busy else error.Io;
    }
}

fn regular(fd: c_int) !std.os.linux.Statx {
    const st = try inspect(fd);
    if (st.mode & std.c.S.IFMT != std.c.S.IFREG or st.uid != std.c.geteuid() or st.mode & 0o7777 != 0o600 or st.nlink != 1) return error.UnsafeFile;
    return st;
}

fn readLocked(allocator: std.mem.Allocator, dir: c_int) !Snapshot {
    // Any marker object fails closed, including dangling links and FIFOs.
    const marker = std.c.openat(dir, "uncertain", read_flags);
    if (marker >= 0) {
        close(marker);
        return error.DurabilityUncertain;
    }
    if (std.c.errno(marker) != .NOENT) return error.DurabilityUncertain;
    const fd = std.c.openat(dir, "store", read_flags);
    if (fd < 0) return if (std.c.errno(fd) == .NOENT) .{} else error.UnsafeFile;
    defer close(fd);
    const st = try regular(fd);
    if (st.size > max_bytes) return error.TooLarge;
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
    while (true) {
        const n = std.c.read(fd, &extra, 1);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n != 0) return error.CorruptStore;
        break;
    }
    const after = try regular(fd);
    if (after.size != st.size or after.ino != st.ino or after.dev_major != st.dev_major or after.dev_minor != st.dev_minor) return error.CorruptStore;
    return decode(bytes);
}

fn unhex(bytes: []const u8) !Key {
    if (bytes.len != 64) return error.CorruptStore;
    var key: Key = undefined;
    for (bytes) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return error.CorruptStore;
    _ = std.fmt.hexToBytes(&key, bytes) catch return error.CorruptStore;
    return key;
}

fn digest(bytes: []const u8) Key {
    var result: Key = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn decode(bytes: []const u8) !Snapshot {
    if (bytes.len > max_bytes) return error.TooLarge;
    if (bytes.len < header.len + trailer_bytes or !std.mem.startsWith(u8, bytes, header)) return error.CorruptStore;
    const end = bytes.len - trailer_bytes;
    if ((end - header.len) % row_bytes != 0 or !std.mem.startsWith(u8, bytes[end..], checksum_prefix) or bytes[bytes.len - 1] != '\n') return error.CorruptStore;
    const checksum = try unhex(bytes[end + checksum_prefix.len .. bytes.len - 1]);
    const expected = digest(bytes[0..end]);
    if (!std.mem.eql(u8, &checksum, &expected)) return error.CorruptStore;
    var result: Snapshot = .{};
    var offset: usize = header.len;
    var pauses = false;
    while (offset < end) : (offset += row_bytes) {
        const row = bytes[offset .. offset + row_bytes];
        if (row[1] != ' ' or row[66] != '\n') return error.CorruptStore;
        const key = try unhex(row[2..66]);
        switch (row[0]) {
            'A' => {
                if (pauses or result.isApproved(key)) return error.CorruptStore;
                insert(&result.approved, &result.approved_len, key) catch return error.CorruptStore;
            },
            'P' => {
                pauses = true;
                if (result.isPaused(key)) return error.CorruptStore;
                insert(&result.paused, &result.paused_len, key) catch return error.CorruptStore;
            },
            else => return error.CorruptStore,
        }
    }
    return result;
}

fn encode(allocator: std.mem.Allocator, snapshot: *const Snapshot) ![]u8 {
    const end = header.len + (snapshot.approved_len + snapshot.paused_len) * row_bytes;
    const bytes = try allocator.alloc(u8, end + trailer_bytes);
    @memcpy(bytes[0..header.len], header);
    var offset: usize = header.len;
    for ([_][]const Key{ snapshot.approved[0..snapshot.approved_len], snapshot.paused[0..snapshot.paused_len] }, [_]u8{ 'A', 'P' }) |keys, tag| {
        for (keys) |key| {
            bytes[offset] = tag;
            bytes[offset + 1] = ' ';
            bytes[offset + 2 ..][0..64].* = std.fmt.bytesToHex(key, .lower);
            bytes[offset + 66] = '\n';
            offset += row_bytes;
        }
    }
    @memcpy(bytes[end..][0..checksum_prefix.len], checksum_prefix);
    bytes[end + checksum_prefix.len ..][0..64].* = std.fmt.bytesToHex(digest(bytes[0..end]), .lower);
    bytes[bytes.len - 1] = '\n';
    return bytes;
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

fn save(allocator: std.mem.Allocator, dir: c_int, snapshot: *const Snapshot) !void {
    const bytes = try encode(allocator, snapshot);
    defer allocator.free(bytes);
    // Never promote an abandoned temporary. Unlink its entry, not its target.
    // Lock the stable directory, not the store inode replaced by rename.
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
    }
    try sync(fd);
    // A durable marker precedes publication. Interrupted/uncertain commits
    // require explicit owner repair, never an automatic empty-store reset.
    try quarantine(dir);
    if (std.c.renameat(dir, "pending", dir, "store") != 0) return error.DurabilityUncertain;
    sync(dir) catch return error.DurabilityUncertain;
    remove(dir, "uncertain") catch return error.DurabilityUncertain;
    sync(dir) catch {
        // Best effort only: no protocol can guarantee persistence after I/O
        // failure. The caller must remain stopped/restricted on every error.
        quarantine(dir) catch {};
        return error.DurabilityUncertain;
    };
}
