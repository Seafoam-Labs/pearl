//! Descriptor-bound execution identity. Metadata is not a content snapshot or a
//! sandbox: in-place writes after validation and mutable dependencies are outside
//! this guarantee. No pathname is reopened at the execution boundary.
const std = @import("std");
const os = @import("posix.zig");

pub const Identity = struct {
    major: u32,
    minor: u32,
    inode: u64,
    birth_seconds: i64,
    birth_nanoseconds: u32,
    modified_seconds: i64,
    modified_nanoseconds: u32,
    changed_seconds: i64,
    changed_nanoseconds: u32,
    size: u64,
    mode: u16,
    uid: u32,

    /// Syscall-only, allocation-free; also used in the post-fork child.
    pub fn capture(fd: c_int) !Identity {
        var st: std.os.linux.Statx = undefined;
        const mask: std.os.linux.STATX = .{ .TYPE = true, .MODE = true, .UID = true, .INO = true, .BTIME = true, .MTIME = true, .CTIME = true, .SIZE = true };
        if (std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, mask, &st) != 0 or
            !st.mask.TYPE or !st.mask.MODE or !st.mask.UID or !st.mask.INO or !st.mask.BTIME or !st.mask.MTIME or !st.mask.CTIME or !st.mask.SIZE) return error.LanguageExecutableIdentityUnavailable;
        if (st.mode & std.c.S.IFMT != std.c.S.IFREG or st.mode & 0o111 == 0 or st.mode & 0o022 != 0 or
            (st.uid != 0 and st.uid != std.c.geteuid())) return error.LanguageExecutableUnsafe;
        return .{ .major = st.dev_major, .minor = st.dev_minor, .inode = st.ino, .birth_seconds = st.btime.sec, .birth_nanoseconds = st.btime.nsec, .modified_seconds = st.mtime.sec, .modified_nanoseconds = st.mtime.nsec, .changed_seconds = st.ctime.sec, .changed_nanoseconds = st.ctime.nsec, .size = st.size, .mode = st.mode, .uid = st.uid };
    }

    pub fn matches(self: Identity, fd: c_int) bool {
        const current = capture(fd) catch return false;
        return std.meta.eql(self, current);
    }
};

/// Ownership is explicit at call sites: Config owns its handle, transport.start
/// borrows and duplicates it, and ownership.start borrows it through fork.
pub const Verified = struct {
    fd: c_int,
    identity: Identity,

    pub fn duplicate(self: Verified) error{SystemResources}!Verified {
        const fd = os.fcntl(self.fd, 1030, @as(c_int, 10)); // F_DUPFD_CLOEXEC
        if (fd < 0) return error.SystemResources;
        return .{ .fd = fd, .identity = self.identity };
    }

    pub fn close(self: Verified) void {
        _ = os.close(self.fd);
    }
};
