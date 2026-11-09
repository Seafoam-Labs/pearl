//! Descriptor-only ignore reads. Missing is the only non-error absence. Symlink,
//! FIFO, device, unreadable and over-budget ignore files fail visibly/closed.
const std = @import("std");
const ignore = @import("ignore.zig");
const c = @import("pearl_app_c");
pub const TestHooks = if (@import("builtin").is_test) struct {
    pub var after_read: ?*const fn (*c.GCancellable) void = null;
    pub var before_cancel_check: ?*const fn (*c.GCancellable) void = null;
} else struct {};
pub const Hash = std.crypto.hash.sha2.Sha256;
pub const Generation = [Hash.digest_length]u8;
pub const Identity = struct { device_major: u32, device_minor: u32, inode: u64, mount: u64 };

pub fn cancellation(cancel: *c.GCancellable) ignore.Cancellation {
    return .{ .context = cancel, .is_cancelled = struct {
        fn check(context: *anyopaque) bool {
            const value: *c.GCancellable = @ptrCast(@alignCast(context));
            if (@import("builtin").is_test) {
                if (TestHooks.before_cancel_check) |hook| hook(value);
            }
            return c.g_cancellable_is_cancelled(value) != 0;
        }
    }.check };
}

pub fn cancelled(cancel: *c.GCancellable) !void {
    if (c.g_cancellable_is_cancelled(cancel) != 0) return error.Cancelled;
}

pub fn inspect(fd: c_int) !std.os.linux.Statx {
    var stat: std.os.linux.Statx = undefined;
    while (std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .INO = true, .SIZE = true, .MTIME = true, .CTIME = true, .MNT_ID = true }, &stat) != 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return error.Io;
    }
    if (!stat.mask.TYPE or !stat.mask.INO or !stat.mask.SIZE or !stat.mask.MTIME or !stat.mask.CTIME) return error.UnsupportedGeneration;
    return stat;
}
pub fn identity(stat: std.os.linux.Statx) Identity {
    return .{ .device_major = stat.dev_major, .device_minor = stat.dev_minor, .inode = stat.ino, .mount = if (stat.mask.MNT_ID) stat.mnt_id else 0 };
}
pub fn stamp(hash: *Hash, stat: std.os.linux.Statx) void {
    // Never hash struct padding or atime (our own read can change atime).
    inline for (.{ stat.dev_major, stat.dev_minor, stat.ino, if (stat.mask.MNT_ID) stat.mnt_id else @as(u64, 0), stat.mode, stat.size, stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec }) |value| hash.update(std.mem.asBytes(&value));
}
pub fn same(a: std.os.linux.Statx, b: std.os.linux.Statx) bool {
    var x = Hash.init(.{});
    var y = Hash.init(.{});
    stamp(&x, a);
    stamp(&y, b);
    return std.mem.eql(u8, &x.finalResult(), &y.finalResult());
}
pub fn field(hash: *Hash, bytes: []const u8) void {
    const len: u64 = bytes.len;
    hash.update(std.mem.asBytes(&len));
    hash.update(bytes);
}

/// Caller supplies the remaining aggregate source budget, checked before any
/// allocation/read. This also avoids reading a whole extra file after the rule
/// storage cap has already been reached.
pub fn read(allocator: std.mem.Allocator, parent: c_int, hash: *Hash, cancel: *c.GCancellable, maximum_bytes: usize) !?[]u8 {
    try cancelled(cancel);
    const fd = while (true) {
        const result = std.c.openat(parent, ".gitignore", .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true });
        if (result >= 0) break result;
        switch (std.c.errno(result)) {
            .INTR => try cancelled(cancel),
            .NOENT => {
                field(hash, "absent");
                return null;
            },
            else => return error.IgnoreUnavailable,
        }
    };
    defer _ = std.c.close(fd);
    const before = try inspect(fd);
    if (before.mode & std.c.S.IFMT != std.c.S.IFREG) return error.IgnoreNotRegular;
    if (before.size > ignore.limits.file_bytes or before.size > maximum_bytes) return error.IgnoreTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    errdefer allocator.free(bytes);
    var at: usize = 0;
    while (at < bytes.len) {
        try cancelled(cancel);
        const n = std.c.read(fd, bytes[at..].ptr, @min(4096, bytes.len - at));
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return error.IgnoreUnavailable;
        }
        if (n == 0) return error.DirectoryChanged;
        at += @intCast(n);
        if (@import("builtin").is_test) {
            if (TestHooks.after_read) |hook| hook(cancel);
        }
    }
    var extra: [1]u8 = undefined;
    while (true) {
        try cancelled(cancel);
        const n = std.c.read(fd, &extra, 1);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n < 0) return error.IgnoreUnavailable;
        if (n != 0) return error.DirectoryChanged;
        break;
    }
    if (!same(before, try inspect(fd))) return error.DirectoryChanged;
    stamp(hash, before);
    field(hash, bytes);
    return bytes;
}
