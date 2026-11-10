//! Linux synchronous WORKER ONLY automatic project/session storage, independent
//! of sessions/current, recovery and trust. No project paths are ever followed.
//! Every live window must use a fresh newId(), including windows cloned from a
//! saved record. An ID's (source, path) is immutable; switching projects needs a
//! new ID. Identity uses exact native bytes, never lexical or filesystem aliases.
//!
//! A small checksummed index references immutable, checksummed session revisions.
//! Shared/exclusive nonblocking directory flock covers the ENTIRE operation.
//! Lifetime leases exclude cooperating writers, startup claimers and forgetters.
//! All lease opens/probes/reclamation run under that same directory lock; only
//! unreferenced UNLOCKED lease files can be unlinked. No blocking lease waiters
//! or opens outside that lock are allowed (otherwise unlink can split ownership).
//! Publication: fsync(snapshot temp), rename to revision, fsync(dir), fsync(index
//! temp), rename to index (COMMIT), fsync(dir). Precommit failures retain the old
//! index and snapshots. DurabilityUncertain means commit occurred: refresh rather
//! than assuming failure. Readers never promote orphan snapshots or temp files.
//!
//! No silent eviction or truncation. TooManySessions / TooManyStartupWindows /
//! ByteBudgetExceeded require explicit user management (setReopen or forget).
//! Budget includes old+new revisions during publication and reserves two maximum
//! indexes. Cleanup visits at most limits.directory_entries and removes only
//! validated unreferenced revisions or checked, reserved writer temporary files.
//! Empty lease files are capped at limits.leases (80). Unreferenced inactive
//! leases are reclaimed on subsequent acquisition/writes; active reservations
//! are never unlinked. TooManyLeases requires releasing reservations, not eviction.
//! Unknown, unsafe, corrupt or future revisions/indexes are preserved and block
//! mutation. Missing referenced snapshots also block replacement/forget.
//!
//! c_allocator ownership can cross threads. Borrowed input must be immutable
//! until return. Prefer an explicit copied state_home; null reads XDG_STATE_HOME
//! then HOME/.local/state (environment must not be concurrently mutated).
//! State home must already exist. Only private coral/projects is created. Safety
//! protects against other UIDs/accidental symlinks, not malicious same-UID races.
const std = @import("std");
const model = @import("session_model.zig");
const recovery = @import("recovery_model.zig");
const a = std.heap.c_allocator;
pub const Id = [32]u8;
pub const Source = @FieldType(model.Workspace, "source");
pub const limits = struct {
    pub const sessions = 64;
    pub const startup_windows = 16;
    pub const bytes = 256 * 1024 * 1024;
    pub const index_bytes = 1024 * 1024;
    pub const leases = sessions + startup_windows;
    pub const directory_entries = sessions * 2 + 4 + leases;
};
pub const Record = struct {
    id: Id,
    label: []const u8,
    source: ?Source,
    path: ?[]const u8,
    root_count: usize,
    reopen: bool,
    /// Ephemeral ownership probe, never persisted. Includes this process's own
    /// lease. UI may skip its own IDs; other live records must not be restored,
    /// suppressed or forgotten. claim/writer checks, not this hint, arbitrate.
    live: bool = false,
    /// Strictly increasing snapshot sequence, NOT a wall-clock timestamp.
    /// Also the expected generation for saveIfUnchanged. Membership edits do not
    /// change it, so they cannot make an older snapshot the latest for a project.
    updated: i64,
};
pub const Catalog = struct {
    /// Newest snapshot first. First exact (source,path) match is that project's
    /// latest snapshot. Null identities represent independent untitled windows.
    records: []const Record,
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn getrandom(buffer: [*]u8, size: usize, flags: c_uint) isize;

/// 128 cryptographically random bits, encoded as 32 lowercase hexadecimal bytes.
/// Nonblocking: EntropyUnavailable is retryable; there is no weak fallback.
pub fn newId() !Id {
    var bytes: [16]u8 = undefined;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = getrandom(bytes[offset..].ptr, bytes.len - offset, 1); // GRND_NONBLOCK
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n < 0 and std.c.errno(n) == .AGAIN) return error.EntropyUnavailable;
        if (n <= 0) return error.Io;
        offset += @intCast(n);
    }
    return std.fmt.bytesToHex(bytes, .lower);
}
fn validId(id: []const u8) bool {
    if (id.len != 32) return false;
    for (id) |ch| if (!(ch >= '0' and ch <= '9') and !(ch >= 'a' and ch <= 'f')) return false;
    return true;
}
fn checkId(id: Id) !void {
    if (!validId(&id)) return error.InvalidId;
}
const path_flags: std.c.O = .{ .PATH = true, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };
const dir_flags: std.c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true };
const read_flags: std.c.O = .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true };
fn close(fd: c_int) void {
    _ = std.c.close(fd);
}
fn inspect(fd: c_int) !std.os.linux.Statx {
    var st: std.os.linux.Statx = undefined;
    const mask: std.os.linux.STATX = .{ .TYPE = true, .MODE = true, .UID = true, .NLINK = true, .SIZE = true, .INO = true };
    while (std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, mask, &st) != 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return error.Io;
    }
    if (!st.mask.TYPE or !st.mask.MODE or !st.mask.UID or !st.mask.NLINK or !st.mask.SIZE or !st.mask.INO) return error.Io;
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
    if (create and std.c.mkdirat(parent, name, 0o700) != 0 and std.c.errno(@as(c_int, -1)) != .EXIST) return error.Io;
    const fd = std.c.openat(parent, name, dir_flags);
    if (fd < 0) return if (std.c.errno(fd) == .NOENT) error.NotFound else error.UnsafeDirectory;
    errdefer close(fd);
    const st = try inspect(fd);
    if (st.mode & std.c.S.IFMT != std.c.S.IFDIR or st.uid != std.c.geteuid() or st.mode & 0o7777 != 0o700) return error.UnsafeDirectory;
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
    const state = if (create) std.c.openat(traversed, ".", dir_flags) else traversed;
    if (state < 0) return error.UnsafeDirectory;
    defer if (create) close(state);
    const coral = try privateDir(state, "coral", create);
    defer close(coral);
    return privateDir(coral, "projects", create);
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
fn openFile(dir: c_int, name: [*:0]const u8) !c_int {
    const fd = std.c.openat(dir, name, read_flags);
    if (fd < 0) return if (std.c.errno(fd) == .NOENT) error.NotFound else error.UnsafeFile;
    return fd;
}
fn readFile(dir: c_int, name: [*:0]const u8, cap: usize) ![]u8 {
    const fd = try openFile(dir, name);
    defer close(fd);
    const st = try regular(fd);
    if (st.size > cap) return error.TooLarge;
    const bytes = try a.alloc(u8, @intCast(st.size));
    errdefer a.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n < 0) return error.Io;
        if (n == 0) return error.CorruptStore;
        offset += @intCast(n);
    }
    var extra: [1]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &extra, 1);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n < 0) return error.Io;
        if (n != 0) return error.CorruptStore;
        break;
    }
    if ((try regular(fd)).size != st.size) return error.CorruptStore;
    return bytes;
}
fn digest(bytes: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return hash;
}
const Entry = struct { record: Record, revision: Id, hash: [32]u8, size: u64 };
const Index = struct {
    arena: std.heap.ArenaAllocator = .init(a),
    entries: std.ArrayList(Entry) = .empty,
    clock: i64 = 0,
    fn deinit(self: *Index) void {
        self.arena.deinit();
    }
    fn find(self: *const Index, id: Id) ?usize {
        for (self.entries.items, 0..) |entry, i| if (std.mem.eql(u8, &entry.record.id, &id)) return i;
        return null;
    }
};
const FileIdentity = struct {
    ino: u64,
    major: u32,
    minor: u32,
    fn of(st: std.os.linux.Statx) FileIdentity {
        return .{ .ino = st.ino, .major = st.dev_major, .minor = st.dev_minor };
    }
    fn eql(x: FileIdentity, y: FileIdentity) bool {
        return x.ino == y.ino and x.major == y.major and x.minor == y.minor;
    }
};

/// Move-only lifetime ownership of one ID. Keep through App lifetime and drain
/// borrowed worker jobs before deinit. Never copy, manually unlock/close the fd,
/// or use an inherited lease in a fork child. deinit closes without LOCK_UN so a
/// child's close cannot unlock its parent's shared open-file description.
/// Inactive files persist until bounded, directory-locked reclamation. No I/O
/// except close is needed on release; acquisition and leased writes are workers.
pub const Lease = struct {
    fd: c_int,
    id: Id,
    store_identity: FileIdentity,
    file_identity: FileIdentity,
    process: std.c.pid_t,

    pub fn deinit(self: *Lease) void {
        if (self.fd >= 0) close(self.fd);
        self.fd = -1;
    }
};
fn leaseName(id: Id) [38:0]u8 {
    var name: [38:0]u8 = undefined;
    @memcpy(name[0..32], &id);
    @memcpy(name[32..38], ".lease");
    name[38] = 0;
    return name;
}
fn isLeaseName(name: []const u8) bool {
    return name.len == 38 and std.mem.endsWith(u8, name, ".lease") and validId(name[0..32]);
}
fn leaseStat(fd: c_int) !std.os.linux.Statx {
    const st = try regular(fd);
    // Empty-file protocol: never truncate unexpected or future lock contents.
    if (st.size != 0) return error.CorruptStore;
    return st;
}
/// SH or EX directory lock required. No creation, unlink or payload reads.
fn leaseLive(dir: c_int, id: Id) !bool {
    const fd = openFile(dir, &leaseName(id)) catch |err| switch (err) {
        error.NotFound => return false,
        else => return err,
    };
    defer close(fd);
    _ = try leaseStat(fd);
    // SH probes coexist with other catalog readers, but conflict with EX owners.
    lock(fd, false) catch |err| switch (err) {
        error.Busy => return true,
        else => return err,
    };
    return false;
}
/// EX directory lock required. Nobody may open a lease and then wait for the
/// directory lock: that would allow an unlocked but already-open inode to be
/// unlinked here. All backend callers obey directory-before-open ordering.
fn sweepLeases(dir: c_int, index: *const Index) !usize {
    const entries = try scan(dir);
    var retained: usize = 0;
    for (entries.names[0..entries.len]) |name| {
        const text = std.mem.sliceTo(&name, 0);
        if (!std.mem.endsWith(u8, text, ".lease")) continue;
        if (!isLeaseName(text)) return error.UnexpectedEntry;
        const fd = try openFile(dir, &name);
        defer close(fd);
        _ = try leaseStat(fd);
        if (index.find(text[0..32].*) == null) {
            lock(fd, true) catch |err| switch (err) {
                error.Busy => {
                    retained += 1;
                    continue;
                },
                else => return err,
            };
            // Both directory and inode are exclusively locked. Existing lifetime
            // holders cannot be here, and no cooperating opener can race unlink.
            try unlink(dir, &name);
        } else retained += 1;
    }
    if (retained > limits.leases) return error.TooManyLeases;
    try sync(dir);
    return retained;
}
fn acquireLease(dir: c_int, index: *const Index, id: Id) !c_int {
    const retained = try sweepLeases(dir, index);
    const name = leaseName(id);
    const existing = openFile(dir, &name) catch |err| switch (err) {
        error.NotFound => null,
        else => return err,
    };
    if (existing) |fd| {
        errdefer close(fd);
        _ = try leaseStat(fd);
        try lock(fd, true);
        return fd;
    }
    if (retained >= limits.leases) return error.TooManyLeases;
    const fd = std.c.openat(dir, &name, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.UnsafeFile;
    errdefer close(fd);
    if (std.c.fchmod(fd, 0o600) != 0) return error.Io;
    _ = try leaseStat(fd);
    try lock(fd, true);
    try sync(fd);
    try sync(dir);
    return fd;
}
/// Nonblocking ownership reservation, with no catalog entry and no reservation
/// of session/startup/byte capacity. Perform save/clone on a worker successfully
/// BEFORE restoring documents into UI. Busy means an owner already holds this ID.
pub fn claim(state_home: ?[]const u8, id: Id) !Lease {
    try checkId(id);
    const dir = try openStore(state_home, true);
    defer close(dir);
    try lock(dir, true);
    var index = try readIndex(dir);
    defer index.deinit();
    const fd = try acquireLease(dir, &index, id);
    errdefer close(fd);
    return .{ .fd = fd, .id = id, .store_identity = FileIdentity.of(try inspect(dir)), .file_identity = FileIdentity.of(try leaseStat(fd)), .process = std.c.getpid() };
}
fn verifyLease(dir: c_int, id: Id, lease: *const Lease) !void {
    if (lease.fd < 0 or lease.process != std.c.getpid() or !std.mem.eql(u8, &id, &lease.id)) return error.InvalidLease;
    if (!lease.store_identity.eql(FileIdentity.of(try inspect(dir)))) return error.InvalidLease;
    if (!lease.file_identity.eql(FileIdentity.of(try leaseStat(lease.fd)))) return error.InvalidLease;
    const current = openFile(dir, &leaseName(id)) catch |err| switch (err) {
        error.NotFound => return error.InvalidLease,
        else => return err,
    };
    defer close(current);
    if (!lease.file_identity.eql(FileIdentity.of(try leaseStat(current)))) return error.InvalidLease;
    // An accidental unlocked descriptor must still win exclusion, not bypass it.
    try lock(lease.fd, true);
}
/// Null result borrows a verified lifetime lease; non-null owns a temporary fd.
fn writerLease(dir: c_int, index: *const Index, id: Id, held: ?*const Lease) !?c_int {
    if (held) |lease| {
        try verifyLease(dir, id, lease);
        return null;
    }
    return try acquireLease(dir, index, id);
}
const Ownership = struct { target: ?*const Lease = null, from: ?*const Lease = null };

const magic = "CORAL-PROJECTS ";
const header = magic ++ "1\n";
const prefix = header.len + 32;
// Binary v1: header + raw SHA256(payload), then LE i64 clock, u16 count;
// each entry: id[32], revision[32], SHA256(session)[32], u64 size,
// i64 updated, u8 source(0=null,1=folder,2=manifest), u8 reopen, u8 roots,
// u16 label length + UTF8 label, u16 path length + native path (0=null).
// All fields required; no unknown flags, duplicate IDs/generations or tail bytes.
const Reader = struct {
    bytes: []const u8,
    fn take(self: *Reader, len: usize) ![]const u8 {
        if (len > self.bytes.len) return error.CorruptStore;
        const out = self.bytes[0..len];
        self.bytes = self.bytes[len..];
        return out;
    }
    fn int(self: *Reader, comptime T: type) !T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
    fn string(self: *Reader, alloc: std.mem.Allocator) ![]const u8 {
        return alloc.dupe(u8, try self.take(try self.int(u16)));
    }
};
fn appendInt(out: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try out.appendSlice(a, &buf);
}
fn appendString(out: *std.ArrayList(u8), bytes: []const u8) !void {
    try appendInt(out, u16, @intCast(bytes.len));
    try out.appendSlice(a, bytes);
}
fn validateIndex(index: *const Index) !void {
    if (index.entries.items.len > limits.sessions) return error.TooManySessions;
    if (index.clock < 0) return error.CorruptStore;
    var startup: usize = 0;
    var total: u64 = 2 * limits.index_bytes;
    for (index.entries.items, 0..) |entry, i| {
        const r = entry.record;
        if (!validId(&r.id) or !validId(&entry.revision)) return error.CorruptStore;
        if (r.updated <= 0 or r.updated > index.clock) return error.CorruptStore;
        if (entry.size == 0 or entry.size > model.limits.session_bytes) return error.TooLarge;
        total += entry.size;
        if (r.root_count > model.limits.roots or r.label.len > model.limits.name_bytes) return error.TooLarge;
        if (!std.unicode.utf8ValidateSlice(r.label)) return error.CorruptStore;
        if (r.path) |path| {
            if (r.source == null or path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.CorruptStore;
            if (path.len > model.limits.path_bytes) return error.TooLarge;
        } else if (r.source != null or r.root_count != 0) return error.CorruptStore;
        if (r.reopen) startup += 1;
        for (index.entries.items[0..i]) |other| {
            if (std.mem.eql(u8, &r.id, &other.record.id) or std.mem.eql(u8, &entry.revision, &other.revision) or r.updated == other.record.updated) return error.CorruptStore;
        }
    }
    if (startup > limits.startup_windows) return error.TooManyStartupWindows;
    if (total > limits.bytes) return error.ByteBudgetExceeded;
}
fn decodeIndex(bytes: []const u8) !Index {
    if (bytes.len > limits.index_bytes) return error.TooLarge;
    if (!std.mem.startsWith(u8, bytes, magic)) return error.CorruptStore;
    if (!std.mem.startsWith(u8, bytes, header)) return error.UnsupportedVersion;
    if (bytes.len < prefix or !std.mem.eql(u8, bytes[header.len..prefix], &digest(bytes[prefix..]))) return error.CorruptStore;
    var reader: Reader = .{ .bytes = bytes[prefix..] };
    var index: Index = .{};
    errdefer index.deinit();
    const alloc = index.arena.allocator();
    index.clock = try reader.int(i64);
    const count = try reader.int(u16);
    if (count > limits.sessions) return error.TooManySessions;
    for (0..count) |_| {
        const id: Id = (try reader.take(32))[0..32].*;
        const revision: Id = (try reader.take(32))[0..32].*;
        const hash: [32]u8 = (try reader.take(32))[0..32].*;
        const size = try reader.int(u64);
        const updated = try reader.int(i64);
        const source: ?Source = switch (try reader.int(u8)) {
            0 => null,
            1 => .folder,
            2 => .manifest,
            else => return error.CorruptStore,
        };
        const reopen = switch (try reader.int(u8)) {
            0 => false,
            1 => true,
            else => return error.CorruptStore,
        };
        const roots = try reader.int(u8);
        const label = try reader.string(alloc);
        const path = try reader.string(alloc);
        try index.entries.append(alloc, .{ .record = .{ .id = id, .source = source, .path = if (path.len == 0) null else path, .label = label, .root_count = roots, .updated = updated, .reopen = reopen }, .revision = revision, .hash = hash, .size = size });
    }
    if (reader.bytes.len != 0) return error.CorruptStore;
    try validateIndex(&index);
    return index;
}
fn encodeIndex(index: *const Index) ![]u8 {
    try validateIndex(index);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, header);
    try out.appendNTimes(a, 0, 32);
    try appendInt(&out, i64, index.clock);
    try appendInt(&out, u16, @intCast(index.entries.items.len));
    for (index.entries.items) |entry| {
        const r = entry.record;
        try out.appendSlice(a, &r.id);
        try out.appendSlice(a, &entry.revision);
        try out.appendSlice(a, &entry.hash);
        try appendInt(&out, u64, entry.size);
        try appendInt(&out, i64, r.updated);
        try appendInt(&out, u8, if (r.source) |s| (if (s == .folder) 1 else 2) else 0);
        try appendInt(&out, u8, @intFromBool(r.reopen));
        try appendInt(&out, u8, @intCast(r.root_count));
        try appendString(&out, r.label);
        try appendString(&out, r.path orelse "");
    }
    if (out.items.len > limits.index_bytes) return error.TooLarge;
    @memcpy(out.items[header.len..prefix], &digest(out.items[prefix..]));
    return out.toOwnedSlice(a);
}
fn readIndex(dir: c_int) !Index {
    const bytes = readFile(dir, "index", limits.index_bytes) catch |err| switch (err) {
        error.NotFound => return .{},
        else => return err,
    };
    defer a.free(bytes);
    return decodeIndex(bytes);
}
fn revisionName(revision: Id) [37:0]u8 {
    var name: [37:0]u8 = undefined;
    @memcpy(name[0..32], &revision);
    @memcpy(name[32..37], ".snap");
    name[37] = 0;
    return name;
}
fn metadata(id: Id, value: model.Value, reopen: bool, updated: i64) Record {
    const w = value.workspace;
    return .{
        .id = id,
        .source = if (w) |v| v.source else null,
        .path = if (w) |v| v.path else null,
        .label = if (w) |v| (if (v.roots.len > 0 and v.roots[0].name.len > 0) v.roots[0].name else if (v.source == .folder) "Folder" else "Workspace") else "Untitled",
        .root_count = if (w) |v| v.roots.len else 0,
        .reopen = reopen,
        .updated = updated,
    };
}
fn sameIdentity(x: Record, y: Record) bool {
    if (x.source != y.source) return false;
    if (x.path) |p| return y.path != null and std.mem.eql(u8, p, y.path.?);
    return y.path == null;
}
fn readSnapshot(dir: c_int, entry: Entry) !*model.Owned {
    const bytes = readFile(dir, &revisionName(entry.revision), model.limits.session_bytes) catch |err| switch (err) {
        error.NotFound => return error.MissingSnapshot,
        else => return err,
    };
    defer a.free(bytes);
    // Decode first to distinguish future session versions from corruption.
    const owned = try model.decode(bytes);
    errdefer owned.deinit();
    if (bytes.len != entry.size or !std.mem.eql(u8, &digest(bytes), &entry.hash)) return error.CorruptStore;
    const r = metadata(entry.record.id, owned.value, entry.record.reopen, entry.record.updated);
    if (!sameIdentity(r, entry.record) or r.root_count != entry.record.root_count or !std.mem.eql(u8, r.label, entry.record.label)) return error.CorruptStore;
    return owned;
}
fn newer(_: void, x: Record, y: Record) bool {
    return x.updated > y.updated;
}
/// Missing directories/index yield an empty catalog, without creating anything.
/// Reads at most index_bytes plus empty lease-file probes; no snapshot payloads.
pub fn list(state_home: ?[]const u8) !Catalog {
    const dir = openStore(state_home, false) catch |err| switch (err) {
        error.NotFound => return .{ .records = &.{}, .arena = .init(a) },
        else => return err,
    };
    defer close(dir);
    try lock(dir, false);
    var index = try readIndex(dir);
    errdefer index.deinit();
    const records = try index.arena.allocator().alloc(Record, index.entries.items.len);
    for (records, index.entries.items) |*r, entry| {
        r.* = entry.record;
        r.live = try leaseLive(dir, r.id);
    }
    std.mem.sort(Record, records, {}, newer);
    return .{ .records = records, .arena = index.arena };
}
/// Caller owns result. Holds shared lock until selected payload is fully decoded.
pub fn load(state_home: ?[]const u8, id: Id) !*model.Owned {
    try checkId(id);
    const dir = try openStore(state_home, false);
    defer close(dir);
    try lock(dir, false);
    var index = try readIndex(dir);
    defer index.deinit();
    const i = index.find(id) orelse return error.NotFound;
    return readSnapshot(dir, index.entries.items[i]);
}

pub const Fault = enum { none, during_snapshot, after_snapshot, during_index, before_commit, after_commit };
pub const Hooks = if (@import("builtin").is_test) struct {
    fault: Fault = .none,
    terminate_process: bool = false,
    byte_budget: usize = limits.bytes,
} else struct {};
fn inject(hooks: Hooks, fault: Fault) !void {
    if (@import("builtin").is_test and hooks.fault == fault) {
        if (hooks.terminate_process) std.c._exit(73);
        return if (fault == .after_commit) error.DurabilityUncertain else error.InjectedFailure;
    }
}
fn unlink(dir: c_int, name: [*:0]const u8) !void {
    if (std.c.unlinkat(dir, name, 0) != 0) return error.Io;
}
fn writeTemp(dir: c_int, name: [*:0]const u8, bytes: []const u8, hooks: Hooks, fault: Fault) !void {
    const fd = std.c.openat(dir, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.Io;
    defer close(fd);
    errdefer unlink(dir, name) catch {};
    if (std.c.fchmod(fd, 0o600) != 0) return error.Io;
    _ = try regular(fd);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(bytes.len, offset + 65536);
        const n = std.c.write(fd, bytes[offset..end].ptr, end - offset);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) return error.Io;
        offset += @intCast(n);
        try inject(hooks, fault);
    }
    try sync(fd);
}
const Scan = struct { names: [limits.directory_entries][256:0]u8 = undefined, len: usize = 0 };
fn scan(dir: c_int) !Scan {
    const copy = std.c.openat(dir, ".", dir_flags);
    if (copy < 0) return error.Io;
    const stream = std.c.fdopendir(copy) orelse {
        close(copy);
        return error.Io;
    };
    defer _ = std.c.closedir(stream);
    var result: Scan = .{};
    while (true) {
        std.c._errno().* = 0;
        const entry = std.c.readdir(stream) orelse {
            if (std.c._errno().* != 0) return error.Io;
            break;
        };
        const name = std.mem.sliceTo(&entry.name, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (result.len == result.names.len) return error.TooManyStoreFiles;
        if (name.len > 255) return error.UnexpectedEntry;
        result.names[result.len] = @splat(0);
        @memcpy(result.names[result.len][0..name.len], name);
        result.len += 1;
    }
    return result;
}
fn referenced(index: *const Index, name: []const u8) bool {
    for (index.entries.items) |entry| if (std.mem.eql(u8, &revisionName(entry.revision), name)) return true;
    return false;
}
/// Only called under EX lock, with a validated index. Temporary names are a
/// reserved scratch protocol, not recovery candidates; incomplete writes there
/// are disposable. Complete future-version scratch files are still preserved.
fn cleanup(dir: c_int, index: *const Index) !void {
    // A prior process may have returned DurabilityUncertain or died immediately
    // after index rename. Stabilize that index BEFORE reclaiming its predecessors.
    try sync(dir);
    _ = try sweepLeases(dir, index);
    const entries = try scan(dir);
    for (entries.names[0..entries.len]) |name| {
        const text = std.mem.sliceTo(&name, 0);
        if (std.mem.eql(u8, text, "index") or isLeaseName(text)) continue;
        const snapshot_temp = std.mem.eql(u8, text, "snapshot.pending");
        const index_temp = std.mem.eql(u8, text, "index.pending");
        const revision = text.len == 37 and std.mem.endsWith(u8, text, ".snap") and validId(text[0..32]);
        if (!snapshot_temp and !index_temp and !revision) return error.UnexpectedEntry;
        if (referenced(index, text)) continue;
        const bytes = try readFile(dir, &name, if (index_temp) limits.index_bytes else model.limits.session_bytes);
        defer a.free(bytes);
        if (revision) {
            const owned = try model.decode(bytes);
            owned.deinit();
        } else if (index_temp) {
            var pending = decodeIndex(bytes) catch |err| switch (err) {
                error.UnsupportedVersion, error.OutOfMemory => return err,
                else => null, // Interrupted reserved scratch is disposable.
            };
            if (pending) |*decoded| decoded.deinit();
        } else {
            const pending = model.decode(bytes) catch |err| switch (err) {
                error.UnsupportedVersion, error.OutOfMemory => return err,
                else => null,
            };
            if (pending) |owned| owned.deinit();
        }
        try unlink(dir, &name);
    }
    // Make reclamation durable before using its space for another transaction.
    try sync(dir);
}
fn diskBytes(dir: c_int, index: *const Index) !u64 {
    var total: u64 = 2 * limits.index_bytes;
    for (index.entries.items) |entry| {
        const fd = openFile(dir, &revisionName(entry.revision)) catch |err| switch (err) {
            error.NotFound => return error.MissingSnapshot,
            else => return err,
        };
        defer close(fd);
        const st = try regular(fd);
        if (st.size != entry.size) return error.CorruptStore;
        total += st.size;
    }
    return total;
}
fn publish(dir: c_int, index: *const Index, hooks: Hooks) !void {
    const bytes = try encodeIndex(index);
    defer a.free(bytes);
    try writeTemp(dir, "index.pending", bytes, hooks, .during_index);
    defer unlink(dir, "index.pending") catch {};
    try inject(hooks, .before_commit);
    if (std.c.renameat(dir, "index.pending", dir, "index") != 0) return error.Io;
    try inject(hooks, .after_commit);
    sync(dir) catch return error.DurabilityUncertain;
    // Do not reclaim old revisions until this commit is durably recorded.
    // Leave postcommit cleanup to the NEXT writer. Cleanup errors must never
    // misreport a successful commit as a failed transaction.
}
/// Last accepted save wins for this ID; Busy is retryable. Use a fresh ID for each
/// window, or saveIfUnchanged to detect snapshots captured before another save.
pub fn save(state_home: ?[]const u8, id: Id, value: model.Value, reopen: bool) !void {
    _ = try saveImpl(state_home, id, value, reopen, .any, .{}, .{});
}
/// expected_updated=null requires an absent ID (collision-safe first save).
/// A non-null generation must equal Record.updated under the writer lock.
/// Membership-only edits do not conflict; save explicitly supplies membership.
pub fn saveIfUnchanged(state_home: ?[]const u8, id: Id, value: model.Value, reopen: bool, expected_updated: ?i64) !void {
    _ = try saveImpl(state_home, id, value, reopen, .{ .generation = expected_updated }, .{}, .{});
}
/// Atomically consume from_id's startup membership and save a fresh window ID.
/// The predecessor remains in recents, with reopen=false and its snapshot intact.
/// Requires an absent new ID, matching source generation/identity, and an enabled
/// predecessor. Concurrent startup claimers therefore get Conflict, not duplicate
/// windows. Works at the 16-window bound without a membership-loss crash gap;
/// still requires a free catalog slot and transaction byte headroom. Obtain the
/// expected generation from list BEFORE load; on Conflict refresh, never guess.
pub fn saveClone(state_home: ?[]const u8, id: Id, from_id: Id, value: model.Value, expected_updated: i64) !void {
    _ = try saveImpl(state_home, id, value, true, .{ .clone = .{ .id = from_id, .updated = expected_updated } }, .{}, .{});
}
pub fn saveWithHooks(state_home: ?[]const u8, id: Id, value: model.Value, reopen: bool, hooks: Hooks) !void {
    _ = try saveImpl(state_home, id, value, reopen, .any, hooks, .{});
}
/// Lifetime-holder CAS save. null requires absence; a non-null generation must
/// still exist and match (never resurrect a forgotten record). Returns the exact
/// committed snapshot generation; DurabilityUncertain requires list reconciliation.
pub fn saveLeased(state_home: ?[]const u8, id: Id, value: model.Value, reopen: bool, expected_updated: ?i64, lease: *const Lease) !i64 {
    return saveImpl(state_home, id, value, reopen, .{ .generation = expected_updated }, .{}, .{ .target = lease });
}
/// Both leases must remain held throughout the membership-transfer transaction.
/// from_id must have matching generation and enabled startup membership. Release
/// its lease after success; keep new_lease through the new App's lifetime.
pub fn saveCloneLeased(state_home: ?[]const u8, new_id: Id, from_id: Id, value: model.Value, expected_updated: i64, new_lease: *const Lease, from_lease: *const Lease) !i64 {
    return saveImpl(state_home, new_id, value, true, .{ .clone = .{ .id = from_id, .updated = expected_updated } }, .{}, .{ .target = new_lease, .from = from_lease });
}
const Expected = union(enum) { any, generation: ?i64, clone: struct { id: Id, updated: i64 } };
fn saveImpl(state_home: ?[]const u8, id: Id, value: model.Value, reopen: bool, expected: Expected, hooks: Hooks, ownership: Ownership) !i64 {
    try checkId(id);
    if (expected == .clone) try checkId(expected.clone.id);
    const bytes = try model.encode(a, value);
    defer a.free(bytes);
    const dir = try openStore(state_home, true);
    defer close(dir);
    try lock(dir, true);
    var index = try readIndex(dir);
    defer index.deinit();
    const temporary = try writerLease(dir, &index, id, ownership.target);
    defer if (temporary) |fd| close(fd);
    // Reject self-clones before opening the same lock through a second descriptor.
    if (expected == .clone and std.mem.eql(u8, &id, &expected.clone.id)) return error.Conflict;
    const from_temporary = if (expected == .clone) try writerLease(dir, &index, expected.clone.id, ownership.from) else null;
    defer if (from_temporary) |fd| close(fd);
    const found = index.find(id);
    var predecessor: ?usize = null;
    switch (expected) {
        .any => {},
        .generation => |generation| {
            const actual: ?i64 = if (found) |i| index.entries.items[i].record.updated else null;
            if (generation != actual) return error.Conflict;
        },
        .clone => |from| {
            if (found != null) return error.Conflict;
            const i = index.find(from.id) orelse return error.Conflict;
            const r = index.entries.items[i].record;
            if (r.updated != from.updated or !r.reopen) return error.Conflict;
            predecessor = i;
        },
    }
    if (index.clock == std.math.maxInt(i64)) return error.GenerationExhausted;
    const record = metadata(id, value, reopen, index.clock + 1);
    if (found) |i| {
        const previous = try readSnapshot(dir, index.entries.items[i]);
        defer previous.deinit();
        if (!sameIdentity(record, index.entries.items[i].record)) return error.IdentityMismatch;
    } else if (index.entries.items.len == limits.sessions) return error.TooManySessions;
    if (predecessor) |i| {
        const previous = try readSnapshot(dir, index.entries.items[i]);
        defer previous.deinit();
        if (!sameIdentity(record, index.entries.items[i].record)) return error.IdentityMismatch;
    }
    var startup: usize = @intFromBool(reopen);
    for (index.entries.items, 0..) |entry, i| {
        if (predecessor != null and predecessor.? == i) continue;
        if (!std.mem.eql(u8, &entry.record.id, &id) and entry.record.reopen) startup += 1;
    }
    if (startup > limits.startup_windows) return error.TooManyStartupWindows;
    const used = try diskBytes(dir, &index);
    const budget = if (@import("builtin").is_test) @min(hooks.byte_budget, limits.bytes) else limits.bytes;
    if (used + bytes.len > budget) return error.ByteBudgetExceeded;
    try cleanup(dir, &index);
    const revision = try newId();
    const name = revisionName(revision);
    // Never replace even an astronomically unlikely colliding immutable revision.
    // EX flock excludes cooperating creators; same-UID malicious races are out of scope.
    const collision = std.c.openat(dir, &name, .{ .PATH = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (collision >= 0) {
        close(collision);
        return error.IdCollision;
    }
    if (std.c.errno(collision) != .NOENT) return error.UnsafeFile;
    const entry: Entry = .{ .record = record, .revision = revision, .hash = digest(bytes), .size = bytes.len };
    if (predecessor) |i| index.entries.items[i].record.reopen = false;
    if (found) |i| index.entries.items[i] = entry else try index.entries.append(index.arena.allocator(), entry);
    index.clock += 1;
    try validateIndex(&index);
    try writeTemp(dir, "snapshot.pending", bytes, hooks, .during_snapshot);
    defer unlink(dir, "snapshot.pending") catch {};
    if (std.c.renameat(dir, "snapshot.pending", dir, &name) != 0) return error.Io;
    try sync(dir);
    try inject(hooks, .after_snapshot);
    // On any failure the revision remains an unreferenced, validated orphan;
    // removing it here would be wrong if publish returned DurabilityUncertain.
    try publish(dir, &index, hooks);
    return index.clock;
}
/// Changes only startup membership, not snapshot recency. No-op still validates
/// the target snapshot; corrupt/future data is never silently acknowledged.
pub fn setReopen(state_home: ?[]const u8, id: Id, reopen: bool) !void {
    return changeMembership(state_home, id, reopen, null, null, .{});
}
/// Explicit removal only. Unsupported/corrupt/unsafe targets are preserved.
/// Snapshot deletion is deferred to the next writer after a durable index commit.
pub fn forget(state_home: ?[]const u8, id: Id) !void {
    return changeMembership(state_home, id, null, null, null, .{});
}
pub fn setReopenLeased(state_home: ?[]const u8, id: Id, reopen: bool, lease: *const Lease) !void {
    return changeMembership(state_home, id, reopen, null, lease, .{});
}
/// Compare generation AND remove in one EX-directory-lock transaction, with a
/// temporary lease excluding live owners. A stale/missing record is Conflict;
/// Busy means ownership is live. No separate list/check/forget race is possible.
pub fn forgetIfUnchanged(state_home: ?[]const u8, id: Id, expected_updated: i64) !void {
    return changeMembership(state_home, id, null, expected_updated, null, .{});
}
fn changeMembership(state_home: ?[]const u8, id: Id, reopen: ?bool, expected_updated: ?i64, held: ?*const Lease, hooks: Hooks) !void {
    try checkId(id);
    const dir = openStore(state_home, false) catch |err| switch (err) {
        error.NotFound => return if (expected_updated != null) error.Conflict else error.NotFound,
        else => return err,
    };
    defer close(dir);
    try lock(dir, true);
    var index = try readIndex(dir);
    defer index.deinit();
    const temporary = try writerLease(dir, &index, id, held);
    defer if (temporary) |fd| close(fd);
    const i = index.find(id) orelse return if (expected_updated != null) error.Conflict else error.NotFound;
    if (expected_updated) |generation| {
        if (index.entries.items[i].record.updated != generation) return error.Conflict;
    }
    const previous = try readSnapshot(dir, index.entries.items[i]);
    previous.deinit();
    _ = try diskBytes(dir, &index);
    // Reclaim against the OLD index, never an unpublished removal.
    try cleanup(dir, &index);
    if (reopen) |enabled| {
        if (index.entries.items[i].record.reopen == enabled) return;
        index.entries.items[i].record.reopen = enabled;
    } else _ = index.entries.orderedRemove(i);
    try validateIndex(&index);
    try publish(dir, &index, hooks);
}

/// Format access for standalone adversarial tests, absent from production builds.
pub const testing = if (@import("builtin").is_test) struct {
    pub const index_prefix = prefix;
    pub fn cloneWithHooks(state_home: ?[]const u8, id: Id, from_id: Id, value: model.Value, expected_updated: i64, hooks: Hooks) !void {
        _ = try saveImpl(state_home, id, value, true, .{ .clone = .{ .id = from_id, .updated = expected_updated } }, hooks, .{});
    }
    pub fn membershipWithHooks(state_home: ?[]const u8, id: Id, reopen: ?bool, hooks: Hooks) !void {
        return changeMembership(state_home, id, reopen, null, null, hooks);
    }
    pub fn snapshotName(state_home: []const u8, id: Id) ![37:0]u8 {
        const dir = try openStore(state_home, false);
        defer close(dir);
        try lock(dir, false);
        var index = try readIndex(dir);
        defer index.deinit();
        return revisionName(index.entries.items[index.find(id) orelse return error.NotFound].revision);
    }
    pub fn rechecksum(bytes: []u8) void {
        @memcpy(bytes[header.len..prefix], &digest(bytes[prefix..]));
    }
} else struct {};
