//! Linux WORKER-only optional folder settings. No writes, enumeration or GTK.
//! Walk every canonical root component using directory descriptors + NOFOLLOW.
//! Root aliases are canonicalized/deduplicated by the model before this boundary.
//! Only absence of .coral or settings.json is empty; every other error rejects.
//! O_NONBLOCK prevents FIFO hangs, not offline-mount latency.
const std = @import("std");
const settings = @import("settings.zig");
const fs = @import("manifest_fs.zig");
pub const Error = fs.Error;

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
fn openAt(parent: c_int, name: [*:0]const u8, flags: std.c.O) Error!c_int {
    while (true) {
        const fd = std.c.openat(parent, name, flags);
        if (fd >= 0) return fd;
        const e = std.c.errno(fd);
        if (e != .INTR) return fromErrno(e);
    }
}
fn inspect(fd: c_int) Error!std.os.linux.Statx {
    var stat: std.os.linux.Statx = undefined;
    while (std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true, .INO = true, .MTIME = true, .CTIME = true }, &stat) != 0) {
        const e = std.c.errno(@as(c_int, -1));
        if (e != .INTR) return fromErrno(e);
    }
    if (!stat.mask.TYPE or !stat.mask.SIZE or !stat.mask.INO or !stat.mask.MTIME or !stat.mask.CTIME) return error.Io;
    return stat;
}
// Traversal needs search permission, not directory listing/read permission.
// This also applies to .coral; only the pinned settings leaf is opened for I/O.
const directory_flags: std.c.O = .{ .PATH = true, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };

pub fn load(allocator: std.mem.Allocator, canonical_root: []const u8) Error!settings.Config {
    try fs.absolutePath(canonical_root);
    var root = try openAt(std.c.AT.FDCWD, "/", directory_flags);
    defer _ = std.c.close(root);
    if (canonical_root.len > 1) {
        var parts = std.mem.splitScalar(u8, canonical_root[1..], '/');
        while (parts.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidSchema;
            var name: [4096]u8 = undefined;
            @memcpy(name[0..part.len], part);
            name[part.len] = 0;
            const next = try openAt(root, @ptrCast(&name), directory_flags);
            _ = std.c.close(root);
            root = next;
        }
    }
    const dir = openAt(root, ".coral", directory_flags) catch |err| {
        if (err == error.NotFound) return .{};
        return err;
    };
    defer _ = std.c.close(dir);
    // O_PATH does not open a device/FIFO for I/O. Inspect first, then reopen the
    // pinned regular inode through procfs (not the attacker-mutable pathname).
    const pinned = openAt(dir, "settings.json", .{ .PATH = true, .NOFOLLOW = true, .CLOEXEC = true }) catch |err| {
        if (err == error.NotFound) return .{};
        return err;
    };
    defer _ = std.c.close(pinned);
    const before = try inspect(pinned);
    if (before.mode & std.c.S.IFMT == std.c.S.IFLNK) return error.SymlinkLoop;
    if (before.mode & std.c.S.IFMT != std.c.S.IFREG) return error.NotRegularFile;
    if (before.size > settings.limits.source_bytes) return error.TooLarge;
    var path_buffer: [64]u8 = undefined;
    const descriptor_path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/self/fd/{d}", .{pinned}, 0) catch unreachable;
    const fd = try openAt(std.c.AT.FDCWD, descriptor_path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true });
    defer _ = std.c.close(fd);
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    defer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0) {
            const e = std.c.errno(n);
            if (e == .INTR) continue;
            return fromErrno(e);
        }
        if (n == 0) return error.ChangedDuringRead;
        offset += @intCast(n);
    }
    var extra: [1]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &extra, 1);
        if (n < 0) {
            const e = std.c.errno(n);
            if (e == .INTR) continue;
            return fromErrno(e);
        }
        if (n != 0) return error.ChangedDuringRead;
        break;
    }
    const after = try inspect(fd);
    if (before.ino != after.ino or before.dev_major != after.dev_major or before.dev_minor != after.dev_minor or before.mode != after.mode or before.size != after.size or before.mtime.sec != after.mtime.sec or before.mtime.nsec != after.mtime.nsec or before.ctime.sec != after.ctime.sec or before.ctime.nsec != after.ctime.nsec) return error.ChangedDuringRead;
    return settings.parse(allocator, bytes);
}
