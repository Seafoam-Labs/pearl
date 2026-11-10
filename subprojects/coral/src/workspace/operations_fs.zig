//! Worker-only, one-root filesystem mutations. No controller storage is borrowed.
//!
//! O_PATH descriptors pin every traversed directory and the actual source inode
//! (including unlinked sources), preventing inode reuse from passing validation.
//! Root ancestors are walked without symlinks, never resolved with realpath.
//! apply reopens the canonical pathname, checks retained descriptors and current
//! entries, then uses descriptor-relative syscalls with exclusive destinations.
//!
//! This is NOT atomic source compare-and-swap: another process can rename a
//! checked parent outside the root or replace a source name after the last check
//! and before renameat2/unlinkat. Linux offers no conditional unlink/rename by fd.
//! Path containment/revalidation is therefore best effort against external rename
//! races, not a security boundary against a concurrently hostile filesystem.
//! Metadata detects observed changes, not edits hidden by a filesystem's timestamp
//! granularity. No content hash, recursive mutation, copy fallback, or durability
//! guarantee is provided. Delete confirmation and unsaved-editor checks belong to
//! the caller; this backend only checks the on-disk snapshot.
const std = @import("std");
const c = @import("pearl_app_c");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const Stat = linux.Statx;

pub const Kind = enum { create_file, create_directory, rename, move, delete };
pub const Request = struct {
    kind: Kind,
    root: []const u8,
    source: []const u8 = "",
    destination: []const u8 = "",
};
pub const path_limit = 4095;

/// Deterministic syscall-boundary probes, absent from production builds.
pub const TestHooks = if (@import("builtin").is_test) struct {
    pub var before_mutation: ?*const fn (*c.GCancellable) void = null;
    pub var after_mutation: ?*const fn (*c.GCancellable) void = null;
} else struct {};
pub const Error = error{
    OutOfMemory,
    InvalidRequest,
    InvalidRoot,
    InvalidPath,
    RootMutation,
    GitPath,
    PathTooLong,
    Symlink,
    SpecialFile,
    NotDirectory,
    NotFound,
    AlreadyExists,
    InvalidDestination,
    StaleSnapshot,
    AlreadyApplied,
    Cancelled,
    PermissionDenied,
    ReadOnlyFilesystem,
    DirectoryNotEmpty,
    CrossDevice,
    UnsupportedFilesystem,
    ResourceLimit,
    NoSpace,
    Busy,
    Interrupted,
    Io,
};

/// Move-only by convention (Zig does not enforce linear ownership). Transfer the
/// whole value and invalidate the old owner; do not copy it or call concurrently.
/// deinit exactly once, on success or failure. A successful apply is single-use;
/// failures do not refresh the snapshot. Prepare anew after StaleSnapshot.
pub const Prepared = struct {
    allocator: Allocator,
    request: Request,
    source_parent: Chain = .{},
    destination_parent: Chain = .{},
    source_fd: c_int = -1,
    source_stat: ?Stat = null,
    committed: bool = false,

    pub fn deinit(self: *Prepared) void {
        if (self.source_fd >= 0) _ = std.c.close(self.source_fd);
        self.source_parent.deinit(self.allocator);
        self.destination_parent.deinit(self.allocator);
        self.allocator.free(self.request.root);
        self.allocator.free(self.request.source);
        self.allocator.free(self.request.destination);
        self.* = undefined;
    }
};

const Node = struct {
    fd: c_int,
    stat: Stat,
    name: []const u8,
    // Ancestors above the requested root need identity checks, not timestamp
    // checks: unrelated changes in /tmp or the user's home must not invalidate us.
    strong: bool,
};
const Chain = struct {
    nodes: std.ArrayList(Node) = .empty,

    fn deinit(self: *Chain, allocator: Allocator) void {
        for (self.nodes.items) |node| _ = std.c.close(node.fd);
        self.nodes.deinit(allocator);
    }

    fn fd(self: *const Chain) c_int {
        return self.nodes.items[self.nodes.items.len - 1].fd;
    }

    fn append(self: *Chain, allocator: Allocator, handle: c_int, name: []const u8, strong: bool) Error!void {
        errdefer _ = std.c.close(handle);
        const stat = try inspect(handle);
        try directory(stat);
        try self.nodes.append(allocator, .{ .fd = handle, .stat = stat, .name = name, .strong = strong });
    }

    fn capture(allocator: Allocator, root: []const u8, relative: []const u8, cancel: *c.GCancellable) Error!Chain {
        var result: Chain = .{};
        errdefer result.deinit(allocator);
        try cancelled(cancel);
        try result.append(allocator, try openRoot(), "", root.len == 1);
        if (root.len > 1) {
            var parts = std.mem.splitScalar(u8, root[1..], '/');
            while (parts.next()) |part| {
                try cancelled(cancel);
                try result.append(allocator, try openEntry(result.fd(), part), part, parts.peek() == null);
            }
        }
        const parent = parentPath(relative);
        if (parent.len > 0) {
            var parts = std.mem.splitScalar(u8, parent, '/');
            while (parts.next()) |part| {
                try cancelled(cancel);
                try result.append(allocator, try openEntry(result.fd(), part), part, true);
            }
        }
        return result;
    }

    /// Rewalk the canonical absolute path; return a fresh parent descriptor.
    fn reopen(self: *const Chain, cancel: *c.GCancellable) Error!c_int {
        var current = try openRoot();
        errdefer _ = std.c.close(current);
        for (self.nodes.items, 0..) |node, index| {
            try cancelled(cancel);
            if (index > 0) {
                const next = openEntry(current, node.name) catch |err| return stalePath(err);
                _ = std.c.close(current);
                current = next;
            }
            if (!same(node.stat, try inspect(current), node.strong) or
                !same(node.stat, try inspect(node.fd), node.strong)) return error.StaleSnapshot;
        }
        return current;
    }

    /// Check each retained path edge again after both parents have been reopened.
    fn validate(self: *const Chain, cancel: *c.GCancellable) Error!void {
        for (self.nodes.items, 0..) |node, index| {
            try cancelled(cancel);
            if (!same(node.stat, try inspect(node.fd), node.strong)) return error.StaleSnapshot;
            if (index > 0) {
                var buf: [path_limit + 1]u8 = undefined;
                const current = statAt(self.nodes.items[index - 1].fd, terminated(node.name, &buf), linux.AT.SYMLINK_NOFOLLOW) catch |err| return stalePath(err);
                if (!same(node.stat, current, node.strong)) return error.StaleSnapshot;
            }
        }
    }
};

/// Blocking filesystem work: invoke off the UI thread. No mutation occurs here.
/// Creates use destination only; delete uses source only; rename/move use both.
/// Rename and move deliberately have identical filesystem semantics.
pub fn prepare(allocator: Allocator, request: Request, cancel: *c.GCancellable) Error!Prepared {
    try cancelled(cancel);
    try validateRequest(request);
    const root = try allocator.dupe(u8, request.root);
    errdefer allocator.free(root);
    const source = try allocator.dupe(u8, request.source);
    errdefer allocator.free(source);
    const destination = try allocator.dupe(u8, request.destination);
    errdefer allocator.free(destination);
    var result: Prepared = .{ .allocator = allocator, .request = .{ .kind = request.kind, .root = root, .source = source, .destination = destination } };
    errdefer {
        if (result.source_fd >= 0) _ = std.c.close(result.source_fd);
        result.source_parent.deinit(allocator);
        result.destination_parent.deinit(allocator);
    }
    if (source.len > 0) {
        result.source_parent = try Chain.capture(allocator, root, source, cancel);
        result.source_fd = try openEntry(result.source_parent.fd(), basename(source));
        result.source_stat = try inspect(result.source_fd);
        try regularOrDirectory(result.source_stat.?);
    }
    if (destination.len > 0) {
        result.destination_parent = try Chain.capture(allocator, root, destination, cancel);
        try absent(result.destination_parent.fd(), basename(destination));
    }
    // Do not publish a snapshot already known to be inconsistent.
    try result.source_parent.validate(cancel);
    try result.destination_parent.validate(cancel);
    if (result.source_stat) |stat| try validateSource(&result, result.source_parent.fd(), stat);
    try cancelled(cancel);
    return result;
}

/// Cancellation is observed only before mutation. Once a syscall succeeds, this
/// returns success even if cancellation arrives concurrently (including at close).
/// Creation modes are 0600/0700, further restricted by the process umask.
pub fn apply(prepared: *Prepared, cancel: *c.GCancellable) Error!void {
    if (prepared.committed) return error.AlreadyApplied;
    try cancelled(cancel);
    const request = prepared.request;
    const source_parent = if (request.source.len > 0) try prepared.source_parent.reopen(cancel) else -1;
    defer if (source_parent >= 0) {
        _ = std.c.close(source_parent);
    };
    const destination_parent = if (request.destination.len > 0) try prepared.destination_parent.reopen(cancel) else -1;
    defer if (destination_parent >= 0) {
        _ = std.c.close(destination_parent);
    };
    if (destination_parent >= 0) try absent(destination_parent, basename(request.destination));
    try prepared.source_parent.validate(cancel);
    try prepared.destination_parent.validate(cancel);
    if (prepared.source_stat) |stat| try validateSource(prepared, source_parent, stat);
    var source_buf: [path_limit + 1]u8 = undefined;
    var destination_buf: [path_limit + 1]u8 = undefined;
    const source = terminated(basename(request.source), &source_buf);
    const destination = terminated(basename(request.destination), &destination_buf);
    if (@import("builtin").is_test) {
        if (TestHooks.before_mutation) |hook| hook(cancel);
    }
    try cancelled(cancel);
    switch (request.kind) {
        .create_file => {
            const fd = std.c.openat(destination_parent, destination, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
            if (fd < 0) return osError(std.c.errno(fd));
            // Creation committed. Do not report close errors as mutation failure
            // or attempt rollback: the pathname may already have been replaced.
            _ = std.c.close(fd);
        },
        .create_directory => {
            const rc = std.c.mkdirat(destination_parent, destination, 0o700);
            if (rc != 0) return osError(std.c.errno(rc));
        },
        .rename, .move => {
            const rc = linux.renameat2(source_parent, source, destination_parent, destination, .{ .NOREPLACE = true });
            const err = linux.errno(rc);
            if (err != .SUCCESS) return osError(err);
        },
        .delete => {
            const flags: c_uint = if (prepared.source_stat.?.mode & std.c.S.IFMT == std.c.S.IFDIR) linux.AT.REMOVEDIR else 0;
            const rc = std.c.unlinkat(source_parent, source, flags);
            if (rc != 0) return osError(std.c.errno(rc));
        },
    }
    prepared.committed = true;
    if (@import("builtin").is_test) {
        if (TestHooks.after_mutation) |hook| hook(cancel);
    }
}

fn validateSource(prepared: *const Prepared, parent: c_int, snapshot: Stat) Error!void {
    if (!same(snapshot, try inspect(prepared.source_fd), true)) return error.StaleSnapshot;
    const current = openEntry(parent, basename(prepared.request.source)) catch |err| return stalePath(err);
    defer _ = std.c.close(current);
    if (!same(snapshot, try inspect(current), true)) return error.StaleSnapshot;
}

fn validateRequest(request: Request) Error!void {
    if (request.root.len == 0 or request.root[0] != '/') return error.InvalidRoot;
    if (request.root.len > path_limit) return error.PathTooLong;
    if (request.root.len > 1) try relativePath(request.root[1..]);
    switch (request.kind) {
        .create_file, .create_directory => {
            if (request.source.len != 0) return error.InvalidRequest;
            try withinRoot(request.root, request.destination);
        },
        .delete => {
            if (request.destination.len != 0) return error.InvalidRequest;
            try withinRoot(request.root, request.source);
        },
        .rename, .move => {
            try withinRoot(request.root, request.source);
            try withinRoot(request.root, request.destination);
            if (std.mem.eql(u8, request.source, request.destination) or
                (std.mem.startsWith(u8, request.destination, request.source) and request.destination[request.source.len] == '/')) return error.InvalidDestination;
        },
    }
}

fn withinRoot(root: []const u8, relative: []const u8) Error!void {
    if (relative.len == 0) return error.RootMutation;
    try relativePath(relative);
    if (root.len + @intFromBool(root.len > 1) + relative.len > path_limit) return error.PathTooLong;
}

fn relativePath(path: []const u8) Error!void {
    if (path.len > path_limit) return error.PathTooLong;
    if (std.mem.indexOfScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidPath;
        if (std.mem.eql(u8, part, ".git")) return error.GitPath;
    }
}

fn basename(path: []const u8) []const u8 {
    return path[if (std.mem.lastIndexOfScalar(u8, path, '/')) |at| at + 1 else 0..];
}
fn parentPath(path: []const u8) []const u8 {
    return path[0 .. std.mem.lastIndexOfScalar(u8, path, '/') orelse 0];
}
fn terminated(path: []const u8, buf: *[path_limit + 1]u8) [:0]const u8 {
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}
fn cancelled(cancel: *c.GCancellable) Error!void {
    if (c.g_cancellable_is_cancelled(cancel) != 0) return error.Cancelled;
}
fn openRoot() Error!c_int {
    const fd = std.c.open("/", .{ .PATH = true, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) return osError(std.c.errno(fd));
    return fd;
}
fn openEntry(parent: c_int, name: []const u8) Error!c_int {
    var buf: [path_limit + 1]u8 = undefined;
    // O_PATH does not open devices or block on FIFOs, and NOFOLLOW opens the
    // symlink itself for explicit type rejection rather than following it.
    const fd = std.c.openat(parent, terminated(name, &buf), .{ .PATH = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) return osError(std.c.errno(fd));
    return fd;
}
fn directory(stat: Stat) Error!void {
    try regularOrDirectory(stat);
    if (stat.mode & std.c.S.IFMT != std.c.S.IFDIR) return error.NotDirectory;
}
fn regularOrDirectory(stat: Stat) Error!void {
    switch (stat.mode & std.c.S.IFMT) {
        std.c.S.IFREG, std.c.S.IFDIR => {},
        std.c.S.IFLNK => return error.Symlink,
        else => return error.SpecialFile,
    }
}
fn statAt(fd: c_int, name: [*:0]const u8, flags: u32) Error!Stat {
    var stat: Stat = undefined;
    if (std.c.statx(fd, name, flags, .{ .TYPE = true, .MODE = true, .INO = true, .SIZE = true, .MTIME = true, .CTIME = true, .BTIME = true, .MNT_ID = true, .NLINK = true }, &stat) != 0) return osError(std.c.errno(@as(c_int, -1)));
    if (!stat.mask.TYPE or !stat.mask.MODE or !stat.mask.INO or !stat.mask.SIZE or !stat.mask.MTIME or !stat.mask.CTIME or !stat.mask.NLINK) return error.UnsupportedFilesystem;
    return stat;
}
fn inspect(fd: c_int) Error!Stat {
    return statAt(fd, "", linux.AT.EMPTY_PATH);
}
fn same(a: Stat, b: Stat, strong: bool) bool {
    if (a.dev_major != b.dev_major or a.dev_minor != b.dev_minor or a.ino != b.ino or
        a.mode & std.c.S.IFMT != b.mode & std.c.S.IFMT or
        a.mask.MNT_ID != b.mask.MNT_ID or (a.mask.MNT_ID and a.mnt_id != b.mnt_id) or
        a.mask.BTIME != b.mask.BTIME or (a.mask.BTIME and !timestamp(a.btime, b.btime))) return false;
    return !strong or (a.mode == b.mode and a.nlink == b.nlink and a.size == b.size and timestamp(a.ctime, b.ctime) and timestamp(a.mtime, b.mtime));
}
fn timestamp(a: linux.statx_timestamp, b: linux.statx_timestamp) bool {
    return a.sec == b.sec and a.nsec == b.nsec;
}
fn absent(parent: c_int, name: []const u8) Error!void {
    const fd = openEntry(parent, name) catch |err| {
        if (err == error.NotFound) return;
        return err;
    };
    defer _ = std.c.close(fd);
    try regularOrDirectory(try inspect(fd));
    return error.AlreadyExists;
}
fn stalePath(err: Error) Error {
    return switch (err) {
        error.NotFound, error.NotDirectory, error.Symlink, error.SpecialFile => error.StaleSnapshot,
        else => err,
    };
}
fn osError(err: linux.E) Error {
    return switch (err) {
        .ACCES, .PERM => error.PermissionDenied,
        .NOENT => error.NotFound,
        .NOTDIR => error.NotDirectory,
        .LOOP => error.Symlink,
        .EXIST => error.AlreadyExists,
        .NOTEMPTY => error.DirectoryNotEmpty,
        .XDEV => error.CrossDevice,
        .ROFS => error.ReadOnlyFilesystem,
        .NAMETOOLONG => error.PathTooLong,
        .NOSYS, .OPNOTSUPP, .INVAL => error.UnsupportedFilesystem,
        .MFILE, .NFILE, .NOMEM => error.ResourceLimit,
        .NOSPC, .DQUOT => error.NoSpace,
        .BUSY, .TXTBSY => error.Busy,
        .INTR => error.Interrupted,
        else => error.Io,
    };
}
