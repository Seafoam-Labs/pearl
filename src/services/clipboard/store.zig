//! Synchronous Linux text storage, deliberately disconnected from the UI/service.
//! All operational paths are anchored to validated directory descriptors. Locks
//! exclude cooperating writers; they do not isolate hostile same-UID processes.
const std = @import("std");
const linux = std.os.linux;
const codec = @import("codec.zig");
const Stat = linux.Statx;

pub const State = enum { unloaded, missing, ready, corrupt, unsupported, unsafe, failed, uncertain };
pub const Error = codec.Error || error{
    InvalidPath,
    Unsafe,
    UnsafeTemporary,
    Busy,
    Failed,
    NeedsLoad,
    Conflict,
    SyncFailed,
    PublishFailed,
    RemoveFailed,
    Uncertain,
};

/// Optional per-instance I/O seam, used by deterministic fault/race tests. No
/// global hooks, timers, jobs or environment access are installed by this module.
pub const Phase = enum { read, write, file_sync, publish, after_publish, remove, after_remove, directory_sync };
pub const Hooks = struct {
    context: ?*anyopaque = null,
    before: ?*const fn (?*anyopaque, Phase) error{InjectedFailure}!void = null,
    fn check(self: Hooks, phase: Phase) error{InjectedFailure}!void {
        if (self.before) |callback| try callback(self.context, phase);
    }
};

fn normalize(allocator: std.mem.Allocator, path: []const u8) Error![:0]u8 {
    if (path.len == 0 or path[0] != '/' or path.len >= 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    var output: [4096]u8 = undefined;
    output[0] = '/';
    var used: usize = 1;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0) {
            if (parts.peek() != null) return error.InvalidPath;
            continue;
        }
        if (part.len > 255 or std.mem.eql(u8, part, "..")) return error.InvalidPath;
        if (std.mem.eql(u8, part, ".")) continue;
        if (used > 1) {
            output[used] = '/';
            used += 1;
        }
        @memcpy(output[used..][0..part.len], part);
        used += part.len;
    }
    return allocator.dupeSentinel(u8, output[0..used], 0);
}

/// Resolve copied environment values only. Absolute but unsafe XDG paths fail;
/// missing/empty/relative XDG uses HOME. Tests inject private roots explicitly.
pub fn resolveDirectory(allocator: std.mem.Allocator, xdg: ?[]const u8, home: ?[]const u8) Error![:0]u8 {
    const use_xdg = if (xdg) |value| value.len > 0 and value[0] == '/' else false;
    const base = try normalize(allocator, if (use_xdg) xdg.? else home orelse return error.InvalidPath);
    defer allocator.free(base);
    const joined = try std.fmt.allocPrintSentinel(allocator, "{s}{s}{s}pearl/clipboard", .{
        base, if (base.len > 1) "/" else "", if (use_xdg) "" else ".local/state/",
    }, 0);
    defer allocator.free(joined);
    return normalize(allocator, joined);
}

fn statAt(fd: c_int, name: [*:0]const u8, flags: u32) Error!?Stat {
    var stat: Stat = undefined;
    const result = linux.statx(fd, name, flags, .{ .TYPE = true, .MODE = true, .UID = true, .NLINK = true, .INO = true, .SIZE = true, .MTIME = true, .CTIME = true }, &stat);
    switch (linux.errno(result)) {
        .SUCCESS => {},
        .NOENT => return null,
        .LOOP, .NOTDIR, .ACCES => return error.Unsafe,
        else => return error.Failed,
    }
    if (!stat.mask.TYPE or !stat.mask.MODE or !stat.mask.UID or !stat.mask.NLINK or !stat.mask.INO or !stat.mask.SIZE or !stat.mask.MTIME or !stat.mask.CTIME) return error.Failed;
    return stat;
}

fn fdStat(fd: c_int) Error!Stat {
    return (try statAt(fd, "", linux.AT.EMPTY_PATH)) orelse error.Conflict;
}

fn sameObject(a: Stat, b: Stat) bool {
    return a.ino == b.ino and a.dev_major == b.dev_major and a.dev_minor == b.dev_minor;
}

fn sameFile(a: Stat, b: Stat) bool {
    return sameObject(a, b) and a.size == b.size and a.mtime.sec == b.mtime.sec and a.mtime.nsec == b.mtime.nsec and a.ctime.sec == b.ctime.sec and a.ctime.nsec == b.ctime.nsec;
}

fn privateFile(stat: Stat) Error!void {
    if (stat.mode & std.c.S.IFMT != std.c.S.IFREG or stat.mode & 0o7777 != 0o600 or stat.uid != std.c.getuid() or stat.nlink != 1) return error.Unsafe;
}

fn safeDirectory(stat: Stat, private: bool) Error!void {
    if (stat.mode & std.c.S.IFMT != std.c.S.IFDIR) return error.Unsafe;
    if (private) {
        if (stat.uid != std.c.getuid() or stat.mode & 0o7777 != 0o700) return error.Unsafe;
    } else {
        if (stat.uid != 0 and stat.uid != std.c.getuid()) return error.Unsafe;
        const sticky_root = stat.uid == 0 and stat.mode & 0o1000 != 0;
        if (stat.mode & 0o022 != 0 and !sticky_root) return error.Unsafe;
    }
}

fn openError(fd: c_int) Error {
    return switch (std.posix.errno(fd)) {
        .LOOP, .NOTDIR, .ACCES => error.Unsafe,
        else => error.Failed,
    };
}

fn ambiguousMutation(err: std.posix.E) bool {
    return switch (err) {
        .IO, .REMOTEIO, .TIMEDOUT, .STALE => true,
        else => false,
    };
}

fn sync(fd: c_int) Error!void {
    while (std.c.fsync(fd) != 0) {
        if (std.posix.errno(-1) != .INTR) return error.SyncFailed;
    }
}

fn lock(fd: c_int) Error!void {
    while (true) {
        switch (linux.errno(linux.flock(fd, 2 | 4))) {
            .SUCCESS => return,
            .INTR => continue,
            .AGAIN => return error.Busy,
            else => return error.Failed,
        }
    }
}

const Node = struct { fd: c_int, name: [256:0]u8 = @splat(0), identity: Stat, private: bool };

/// Owns the directory chain and both locks until close. Do not copy by value.
/// Open does not read payloads. read() must validate missing/complete history
/// before write(); corrupt/unsupported state can only be removed explicitly.
pub const Store = struct {
    allocator: std.mem.Allocator,
    nodes: [256]Node = undefined,
    len: usize = 0,
    lock_fd: c_int = -1,
    lock_identity: Stat = undefined,
    expected: ?Stat = null,
    state: State = .unloaded,
    hooks: Hooks = .{},
    cleanup_failed: bool = false,

    pub fn openEnvironment(allocator: std.mem.Allocator, xdg: ?[]const u8, home: ?[]const u8) Error!Store {
        const path = try resolveDirectory(allocator, xdg, home);
        defer allocator.free(path);
        return open(allocator, path);
    }

    pub fn open(allocator: std.mem.Allocator, directory: []const u8) Error!Store {
        const path = try normalize(allocator, directory);
        defer allocator.free(path);
        var self: Store = .{ .allocator = allocator };
        errdefer self.close();
        const root = std.c.open("/", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
        if (root < 0) return openError(root);
        self.nodes[0] = .{ .fd = root, .identity = undefined, .private = false };
        self.len = 1;
        self.nodes[0].identity = try fdStat(root);
        try safeDirectory(self.nodes[0].identity, false);
        var parts = std.mem.tokenizeScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (self.len == self.nodes.len) return error.InvalidPath;
            var name: [256:0]u8 = @splat(0);
            @memcpy(name[0..part.len], part);
            const parent = self.directoryFd();
            var child = std.c.openat(parent, &name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
            var created = false;
            if (child < 0 and std.posix.errno(child) == .NOENT) {
                if (std.c.mkdirat(parent, &name, 0o700) == 0) created = true else if (std.posix.errno(-1) != .EXIST) return error.Failed;
                child = std.c.openat(parent, &name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
                // A restrictive umask can remove owner access. O_PATH pins the
                // newly created inode; chmod only that verified owned object.
                if (child < 0 and created and std.posix.errno(child) == .ACCES) {
                    const pin = std.c.openat(parent, &name, .{ .PATH = true, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
                    if (pin < 0) return openError(pin);
                    defer _ = std.c.close(pin);
                    const st = try fdStat(pin);
                    if (st.uid != std.c.getuid() or st.mode & std.c.S.IFMT != std.c.S.IFDIR) return error.Unsafe;
                    if (linux.errno(linux.fchmodat2(pin, "", 0o700, linux.AT.EMPTY_PATH)) != .SUCCESS) return error.Failed;
                    child = std.c.openat(parent, &name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
                    if (child >= 0) {
                        const reopened = fdStat(child) catch |err| {
                            _ = std.c.close(child);
                            return err;
                        };
                        if (!sameObject(st, reopened)) {
                            _ = std.c.close(child);
                            return error.Conflict;
                        }
                    }
                }
            }
            if (child < 0) return openError(child);
            self.nodes[self.len] = .{ .fd = child, .name = name, .identity = undefined, .private = created };
            self.len += 1;
            const st = try fdStat(child);
            if (created) {
                if (st.uid != std.c.getuid()) return error.Unsafe;
                if (std.c.fchmod(child, 0o700) != 0) return error.Failed;
            }
            self.nodes[self.len - 1].identity = try fdStat(child);
            try safeDirectory(self.nodes[self.len - 1].identity, created);
            if (created) {
                try sync(child);
                try sync(parent);
            }
        }
        // Both the Pearl parent and clipboard leaf must already be private;
        // existing unsafe objects are rejected rather than chmod-repaired.
        if (self.len < 3) return error.InvalidPath;
        for (self.nodes[self.len - 2 .. self.len]) |*node| {
            node.private = true;
            try safeDirectory(try fdStat(node.fd), true);
        }
        try lock(self.directoryFd());
        var created_lock = false;
        self.lock_fd = std.c.openat(self.directoryFd(), "writer.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c_uint, 0o600));
        if (self.lock_fd >= 0) {
            created_lock = true;
            if (std.c.fchmod(self.lock_fd, 0o600) != 0) return error.Failed;
        } else if (std.posix.errno(self.lock_fd) == .EXIST) {
            self.lock_fd = std.c.openat(self.directoryFd(), "writer.lock", .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c_uint, 0));
        }
        if (self.lock_fd < 0) return openError(self.lock_fd);
        self.lock_identity = try fdStat(self.lock_fd);
        try privateFile(self.lock_identity);
        try lock(self.lock_fd);
        try self.guard();
        if (created_lock) {
            try sync(self.lock_fd);
            try sync(self.directoryFd());
        }
        return self;
    }

    pub fn directoryFd(self: *const Store) c_int {
        return self.nodes[self.len - 1].fd;
    }

    pub fn close(self: *Store) void {
        if (self.lock_fd >= 0) _ = std.c.close(self.lock_fd);
        self.lock_fd = -1;
        while (self.len > 0) {
            self.len -= 1;
            _ = std.c.close(self.nodes[self.len].fd);
        }
    }

    fn guard(self: *const Store) Error!void {
        for (self.nodes[0..self.len], 0..) |node, index| {
            const current = try fdStat(node.fd);
            try safeDirectory(current, node.private);
            if (!sameObject(node.identity, current)) return error.Conflict;
            if (index > 0) {
                const named = (try statAt(self.nodes[index - 1].fd, &node.name, linux.AT.SYMLINK_NOFOLLOW)) orelse return error.Conflict;
                if (!sameObject(current, named)) return error.Conflict;
            }
        }
        const current = try fdStat(self.lock_fd);
        try privateFile(current);
        const named = (try statAt(self.directoryFd(), "writer.lock", linux.AT.SYMLINK_NOFOLLOW)) orelse return error.Conflict;
        try privateFile(named);
        if (!sameObject(current, self.lock_identity) or !sameObject(current, named)) return error.Conflict;
    }

    fn historyFile(self: *const Store) Error!?c_int {
        const fd = std.c.openat(self.directoryFd(), "history.bin", .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c_uint, 0));
        if (fd < 0) {
            if (std.posix.errno(fd) == .NOENT) return null;
            return openError(fd);
        }
        errdefer _ = std.c.close(fd);
        const st = try fdStat(fd);
        try privateFile(st);
        const named = (try statAt(self.directoryFd(), "history.bin", linux.AT.SYMLINK_NOFOLLOW)) orelse return error.Conflict;
        if (!sameFile(st, named)) return error.Conflict;
        return fd;
    }

    fn checkExpected(self: *const Store) Error!void {
        const named = try statAt(self.directoryFd(), "history.bin", linux.AT.SYMLINK_NOFOLLOW);
        if (named) |actual| {
            try privateFile(actual);
            const expected = self.expected orelse return error.Conflict;
            if (!sameFile(expected, actual)) return error.Conflict;
        } else if (self.expected != null) return error.Conflict;
    }

    pub fn read(self: *Store) Error!?codec.Loaded {
        return self.readImpl() catch |err| {
            self.state = stateFor(err);
            return err;
        };
    }

    fn readImpl(self: *Store) Error!?codec.Loaded {
        try self.guard();
        const fd = (try self.historyFile()) orelse {
            try self.guard();
            if ((try statAt(self.directoryFd(), "history.bin", linux.AT.SYMLINK_NOFOLLOW)) != null) return error.Conflict;
            self.expected = null;
            self.state = .missing;
            return null;
        };
        defer _ = std.c.close(fd);
        const before = try fdStat(fd);
        self.expected = before;
        var reader: FileReader = .{ .fd = fd, .hooks = self.hooks };
        var loaded = codec.decode(self.allocator, &reader, before.size) catch |err| return switch (err) {
            error.Unsupported => error.Unsupported,
            error.OutOfMemory => error.OutOfMemory,
            error.ReadFailed => error.ReadFailed,
            else => error.Corrupt,
        };
        errdefer loaded.deinit();
        try self.guard();
        try self.checkExpected();
        if (!sameFile(before, try fdStat(fd))) return error.Conflict;
        self.state = .ready;
        return loaded;
    }

    pub fn write(self: *Store, snapshot: codec.Snapshot) Error!void {
        return self.writeSnapshot(snapshot, false);
    }

    /// Removal snapshots must also retire plaintext left by interrupted saves.
    pub fn writeRemoval(self: *Store, snapshot: codec.Snapshot) Error!void {
        return self.writeSnapshot(snapshot, true);
    }

    fn writeSnapshot(self: *Store, snapshot: codec.Snapshot, removal: bool) Error!void {
        switch (self.state) {
            .ready, .missing => {},
            .corrupt => return error.Corrupt,
            .unsupported => return error.Unsupported,
            .unsafe => return error.Unsafe,
            else => return error.NeedsLoad,
        }
        // Invalid caller snapshots cannot delete/replace a valid saved file.
        _ = try codec.encodedSize(snapshot);
        self.writeImpl(snapshot, removal) catch |err| {
            self.state = stateFor(err);
            return err;
        };
    }

    fn writeImpl(self: *Store, snapshot: codec.Snapshot, removal: bool) Error!void {
        self.cleanup_failed = false;
        try self.guard();
        try self.checkExpected();
        if (snapshot.records.len == 0) return self.remove();
        var name: [44:0]u8 = @splat(0);
        var temp: c_int = -1;
        for (0..8) |_| {
            var random: [16]u8 = undefined;
            var offset: usize = 0;
            while (offset < random.len) {
                const result = linux.getrandom(random[offset..].ptr, random.len - offset, 0);
                if (linux.errno(result) == .INTR) continue;
                if (linux.errno(result) != .SUCCESS or result == 0) return error.Failed;
                offset += result;
            }
            @memcpy(name[0..12], "history.tmp.");
            @memcpy(name[12..44], &std.fmt.bytesToHex(random, .lower));
            temp = std.c.openat(self.directoryFd(), &name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c_uint, 0o600));
            if (temp >= 0) break;
            if (std.posix.errno(temp) != .EXIST) return openError(temp);
        }
        if (temp < 0) return error.Failed;
        defer if (temp >= 0) {
            _ = std.c.close(temp);
        };
        const identity = fdStat(temp) catch |err| {
            self.cleanup_failed = true;
            return err;
        };
        var published = false;
        defer if (!published) {
            self.cleanupTemp(&name, identity) catch {
                self.cleanup_failed = true;
            };
        };
        if (std.c.fchmod(temp, 0o600) != 0) return error.Failed;
        try privateFile(try fdStat(temp));
        var writer: FileWriter = .{ .fd = temp, .hooks = self.hooks };
        try codec.encode(snapshot, &writer);
        self.hooks.check(.file_sync) catch return error.SyncFailed;
        try sync(temp);
        const saved = try fdStat(temp);
        try privateFile(saved);
        if (saved.size != try codec.encodedSize(snapshot)) return error.WriteFailed;
        const closing = temp;
        temp = -1;
        if (std.c.close(closing) != 0) return error.WriteFailed;
        self.hooks.check(.publish) catch return error.PublishFailed;
        try self.guard();
        try self.checkExpected();
        const named = (try statAt(self.directoryFd(), &name, linux.AT.SYMLINK_NOFOLLOW)) orelse return error.Conflict;
        try privateFile(named);
        if (!sameFile(saved, named)) return error.Conflict;
        if (std.c.renameat(self.directoryFd(), &name, self.directoryFd(), "history.bin") != 0) {
            // EIO/remote ambiguity cannot safely be classified as no mutation.
            return if (ambiguousMutation(std.posix.errno(-1))) error.Uncertain else error.PublishFailed;
        }
        published = true;
        self.hooks.check(.after_publish) catch return error.Uncertain;
        if (removal) {
            // The replacement is already published: any cleanup failure leaves
            // the overall removal uncertain, even if history.bin is now clean.
            self.guard() catch return error.Uncertain;
            var changed = false;
            self.removeTemps(&changed) catch return error.Uncertain;
        }
        self.hooks.check(.directory_sync) catch return error.Uncertain;
        sync(self.directoryFd()) catch return error.Uncertain;
        self.guard() catch return error.Uncertain;
        const final = (statAt(self.directoryFd(), "history.bin", linux.AT.SYMLINK_NOFOLLOW) catch return error.Uncertain) orelse return error.Uncertain;
        privateFile(final) catch return error.Uncertain;
        // Rename can change ctime: identity, size and mtime remain pinned.
        if (!sameObject(saved, final) or saved.size != final.size or !std.meta.eql(saved.mtime, final.mtime)) return error.Uncertain;
        self.expected = final;
        self.state = .ready;
    }

    fn cleanupTemp(self: *Store, name: [*:0]const u8, identity: Stat) Error!void {
        const named = (try statAt(self.directoryFd(), name, linux.AT.SYMLINK_NOFOLLOW)) orelse return;
        try privateFile(named);
        if (!sameObject(identity, named)) return error.Conflict;
        if (std.c.unlinkat(self.directoryFd(), name, 0) != 0) return error.RemoveFailed;
        try sync(self.directoryFd());
    }

    /// Explicit Clear is allowed for safe corrupt/unsupported payload files.
    /// It preserves directories and writer.lock. Absence still requires fsync;
    /// unlinking bytes is not a promise of forensic erasure.
    pub fn remove(self: *Store) Error!void {
        var changed = false;
        self.removeImpl(&changed) catch |err| {
            const outcome = if (changed) error.Uncertain else err;
            self.state = stateFor(outcome);
            return outcome;
        };
        self.expected = null;
        self.state = .missing;
    }

    fn removeImpl(self: *Store, changed: *bool) Error!void {
        try self.guard();
        var expected: ?Stat = null;
        if (try self.historyFile()) |fd| {
            defer _ = std.c.close(fd);
            expected = try fdStat(fd);
        }
        // Recovery may only remove the rejected file we inspected, never a
        // replacement installed between the failed load and explicit Clear.
        if (self.state == .corrupt or self.state == .unsupported) try self.checkExpected();
        self.hooks.check(.remove) catch return error.RemoveFailed;
        try self.guard();
        const named = try statAt(self.directoryFd(), "history.bin", linux.AT.SYMLINK_NOFOLLOW);
        if (named) |actual| {
            try privateFile(actual);
            if (expected == null or !sameFile(expected.?, actual)) return error.Conflict;
            if (std.c.unlinkat(self.directoryFd(), "history.bin", 0) != 0) return if (ambiguousMutation(std.posix.errno(-1))) error.Uncertain else error.RemoveFailed;
            changed.* = true;
        } else if (expected != null) return error.Conflict;
        self.hooks.check(.after_remove) catch return error.RemoveFailed;
        try self.removeTemps(changed);
        self.hooks.check(.directory_sync) catch return error.SyncFailed;
        try sync(self.directoryFd());
        try self.guard();
        if ((try statAt(self.directoryFd(), "history.bin", linux.AT.SYMLINK_NOFOLLOW)) != null) return error.Conflict;
    }

    fn removeTemps(self: *Store, changed: *bool) Error!void {
        // Reopen the directory for each pass: deletion must not skip entries
        // through reused directory offsets. Retain only one fixed name/buffer.
        while (true) {
            const fd = std.c.openat(self.directoryFd(), ".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
            if (fd < 0) return error.Failed;
            defer _ = std.c.close(fd);
            var removed = false;
            var buffer: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
            while (true) {
                const count = linux.getdents64(fd, &buffer, buffer.len);
                if (linux.errno(count) == .INTR) continue;
                if (linux.errno(count) != .SUCCESS) return error.Failed;
                if (count == 0) break;
                var pos: usize = 0;
                while (pos < count) {
                    if (count - pos < 20) return error.Failed;
                    const size = std.mem.readInt(u16, buffer[pos + 16 ..][0..2], @import("builtin").cpu.arch.endian());
                    if (size < 20 or size > count - pos) return error.Failed;
                    const field = buffer[pos + 19 .. pos + size];
                    const end = std.mem.indexOfScalar(u8, field, 0) orelse return error.Failed;
                    const name = field[0..end];
                    pos += size;
                    if (!temporaryName(name)) continue;
                    var z: [44:0]u8 = @splat(0);
                    @memcpy(z[0..44], name);
                    const st = (try statAt(self.directoryFd(), &z, linux.AT.SYMLINK_NOFOLLOW)) orelse continue;
                    privateFile(st) catch return error.UnsafeTemporary;
                    if (std.c.unlinkat(self.directoryFd(), &z, 0) != 0) return if (ambiguousMutation(std.posix.errno(-1))) error.Uncertain else error.RemoveFailed;
                    removed = true;
                    changed.* = true;
                }
            }
            if (!removed) return;
        }
    }
};

fn temporaryName(name: []const u8) bool {
    if (name.len != 44 or !std.mem.startsWith(u8, name, "history.tmp.")) return false;
    for (name[12..]) |ch| if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return false;
    return true;
}

fn stateFor(err: Error) State {
    return switch (err) {
        error.Corrupt, error.Truncated, error.TooLarge => .corrupt,
        error.Unsupported => .unsupported,
        error.Unsafe, error.UnsafeTemporary => .unsafe,
        error.Uncertain => .uncertain,
        else => .failed,
    };
}

const FileReader = struct {
    fd: c_int,
    hooks: Hooks,
    pub fn read(self: *FileReader, bytes: []u8) Error!usize {
        self.hooks.check(.read) catch return error.ReadFailed;
        while (true) {
            const count = std.c.read(self.fd, bytes.ptr, @min(bytes.len, 65536));
            if (count >= 0) return @intCast(count);
            if (std.posix.errno(count) != .INTR) return error.ReadFailed;
        }
    }
};

const FileWriter = struct {
    fd: c_int,
    hooks: Hooks,
    pub fn writeAll(self: *FileWriter, bytes: []const u8) Error!void {
        self.hooks.check(.write) catch return error.WriteFailed;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const count = std.c.write(self.fd, bytes[offset..].ptr, @min(bytes.len - offset, 65536));
            if (count < 0 and std.posix.errno(count) == .INTR) continue;
            if (count <= 0) return error.WriteFailed;
            offset += @intCast(count);
        }
    }
};
