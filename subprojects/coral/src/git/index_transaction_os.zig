//! Small libc boundary for the Linux transaction worker (no C translation step).
//! Process transport already constrains this build to Linux x86_64.
const std = @import("std");
const process_os = @import("../terminal/posix.zig");
pub const open = process_os.open;
pub const close = process_os.close;
pub const read = process_os.read;
pub const write = process_os.write;
pub const __errno_location = process_os.__errno_location;
pub extern "c" fn openat(c_int, [*:0]const u8, c_int, ...) c_int;
pub extern "c" fn unlinkat(c_int, [*:0]const u8, c_int) c_int;
pub extern "c" fn renameat(c_int, [*:0]const u8, c_int, [*:0]const u8) c_int;
pub extern "c" fn fchmod(c_int, c_uint) c_int;
pub extern "c" fn fchmodat(c_int, [*:0]const u8, c_uint, c_int) c_int;
pub extern "c" fn fsync(c_int) c_int;
pub const Timespec = process_os.Timespec;
pub extern "c" fn futimens(c_int, *const [2]Timespec) c_int;
pub const UTIME_OMIT = 1073741822;
pub extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
pub extern "c" fn rmdir([*:0]const u8) c_int;
pub extern "c" fn getpid() c_int;
pub extern "c" fn usleep(c_uint) c_int;
pub extern "c" fn dup(c_int) c_int;
pub extern "c" fn symlinkat([*:0]const u8, c_int, [*:0]const u8) c_int;
pub extern "c" fn mkfifoat(c_int, [*:0]const u8, c_uint) c_int;
pub extern "c" fn mkdirat(c_int, [*:0]const u8, c_uint) c_int;
pub const fdopendir = std.c.fdopendir;
pub const closedir = std.c.closedir;
pub const readdir = std.c.readdir;
pub const O_RDONLY = 0;
pub const O_WRONLY = 1;
pub const O_CREAT = 0x40;
pub const O_EXCL = 0x80;
pub const O_TRUNC = 0x200;
pub const O_NONBLOCK = 0x800;
pub const O_DIRECTORY = 0x10000;
pub const O_NOFOLLOW = 0x20000;
pub const O_CLOEXEC = 0x80000;
pub const AT_FDCWD = -100;
pub const AT_SYMLINK_NOFOLLOW = 0x100;
pub const AT_REMOVEDIR = 0x200;
pub const S_IFMT = 0o170000;
pub const S_IFREG = 0o100000;
pub const S_IFDIR = 0o040000;
pub const ENOENT = 2;
pub const EINTR = 4;
pub const EEXIST = 17;
const Time = struct { tv_sec: i64, tv_nsec: u32 };
// Internal value, NOT the platform's struct stat ABI. statx avoids libc stat ABI
// differences and includes birth time where available to strengthen identity.
pub const struct_stat = struct {
    st_dev: u64,
    st_ino: u64,
    st_mode: u32,
    st_uid: u32,
    st_gid: u32,
    st_nlink: u32,
    st_size: u64,
    st_mtim: Time,
    st_ctim: Time,
    birth: Time,
};
pub fn fstat(fd: c_int, out: *struct_stat) c_int {
    return fstatat(fd, "", out, std.os.linux.AT.EMPTY_PATH);
}
pub fn fstatat(fd: c_int, name: [*:0]const u8, out: *struct_stat, flags: u32) c_int {
    var st: std.os.linux.Statx = undefined;
    while (std.c.statx(fd, name, flags, .{ .TYPE = true, .MODE = true, .UID = true, .GID = true, .INO = true, .NLINK = true, .SIZE = true, .MTIME = true, .CTIME = true, .BTIME = true }, &st) != 0) {
        if (__errno_location().* != EINTR) return -1;
    }
    if (!st.mask.TYPE or !st.mask.MODE or !st.mask.UID or !st.mask.GID or !st.mask.INO or !st.mask.NLINK or !st.mask.SIZE or !st.mask.MTIME or !st.mask.CTIME) {
        __errno_location().* = 5;
        return -1;
    }
    out.* = .{
        .st_dev = (@as(u64, st.dev_major) << 32) | st.dev_minor,
        .st_ino = st.ino,
        .st_mode = st.mode,
        .st_uid = st.uid,
        .st_gid = st.gid,
        .st_nlink = st.nlink,
        .st_size = st.size,
        .st_mtim = .{ .tv_sec = st.mtime.sec, .tv_nsec = st.mtime.nsec },
        .st_ctim = .{ .tv_sec = st.ctime.sec, .tv_nsec = st.ctime.nsec },
        .birth = .{ .tv_sec = if (st.mask.BTIME) st.btime.sec else 0, .tv_nsec = if (st.mask.BTIME) st.btime.nsec else 0 },
    };
    return 0;
}
