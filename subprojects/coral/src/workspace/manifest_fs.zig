//! Linux-only, synchronous native filesystem boundary for the M2 manifest/model.
//! No creation, enumeration, URI providers, subprocesses or network clients.
//! Metadata and regular-file reads can still block on an offline mount: run on
//! a worker, not the GTK thread. O_NONBLOCK prevents FIFO-open hangs, not NFS I/O.
//! These are snapshots, not a symlink sandbox or a lock against concurrent edits.
const std = @import("std");
const manifest = @import("manifest.zig");

pub const Error = manifest.Error || error{
    AbsolutePathRequired,
    NotFound,
    NotDirectory,
    NotRegularFile,
    PermissionDenied,
    SymlinkLoop,
    ChangedDuringRead,
    Io,
};

pub fn absolutePath(path: []const u8) Error!void {
    try manifest.validateString(path, manifest.limits.path_bytes);
    if (path[0] != '/') return error.AbsolutePathRequired;
}

fn fromErrno(e: std.c.E) Error {
    return switch (e) {
        .NOENT => error.NotFound,
        .NOTDIR => error.NotDirectory,
        .ACCES, .PERM => error.PermissionDenied,
        .LOOP => error.SymlinkLoop,
        .NAMETOOLONG => error.TooLarge,
        .NOMEM => error.OutOfMemory,
        else => error.Io,
    };
}

fn inspect(fd: c_int) Error!std.os.linux.Statx {
    var stat: std.os.linux.Statx = undefined;
    while (std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true }, &stat) != 0) {
        const err = std.c.errno(@as(c_int, -1));
        if (err != .INTR) return fromErrno(err);
    }
    if (!stat.mask.TYPE or !stat.mask.SIZE) return error.Io;
    return stat;
}

/// Open first (without O_CREAT, with O_NONBLOCK), then inspect that descriptor.
/// Symlinks to regular manifests are allowed. The caller's spelling, not the
/// symlink target's parent, is the base for relative roots.
pub fn read(allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    try absolutePath(path);
    const z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(z);
    const fd = while (true) {
        const result = std.c.open(z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true });
        if (result >= 0) break result;
        const err = std.c.errno(result);
        if (err != .INTR) return fromErrno(err);
    };
    defer _ = std.c.close(fd);
    const stat = try inspect(fd);
    if (stat.mode & std.c.S.IFMT != std.c.S.IFREG) return error.NotRegularFile;
    if (stat.size > manifest.limits.manifest_bytes) return error.TooLarge;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0) {
            const err = std.c.errno(n);
            if (err == .INTR) continue;
            return fromErrno(err);
        }
        if (n == 0) return error.ChangedDuringRead;
        offset += @intCast(n);
    }
    var extra: [1]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &extra, 1);
        if (n < 0) {
            const err = std.c.errno(n);
            if (err == .INTR) continue;
            return fromErrno(err);
        }
        if (n != 0) return error.ChangedDuringRead;
        break;
    }
    return bytes;
}

/// Never lexically collapse dot-dot before realpath: link/.. has physical
/// filesystem semantics. Linux realpath's supplied buffer requires PATH_MAX.
pub fn canonical(allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    try absolutePath(path);
    const z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(z);
    var buffer: [4096]u8 = undefined;
    const result = std.c.realpath(z, &buffer) orelse return fromErrno(std.c.errno(@as(c_int, -1)));
    const resolved = std.mem.span(result);
    try absolutePath(resolved);
    return allocator.dupe(u8, resolved);
}

pub fn directory(allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    const resolved = try canonical(allocator, path);
    errdefer allocator.free(resolved);
    const z = try allocator.dupeSentinel(u8, resolved, 0);
    defer allocator.free(z);
    const fd = while (true) {
        const result = std.c.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true });
        if (result >= 0) break result;
        const err = std.c.errno(result);
        if (err != .INTR) return fromErrno(err);
    };
    defer _ = std.c.close(fd);
    return resolved;
}
