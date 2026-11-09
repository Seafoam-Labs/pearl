//! Minimal Linux libc ABI for the ownership/PTY spike; no new link dependency.
//! Linux x86_64/glibc ABI, measured on glibc 2.44. Requires glibc >= 2.34
//! (_Fork/openpty in libc) and Linux >= 5.9 (close_range). Fail closed elsewhere.
const builtin = @import("builtin");
comptime {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64)
        @compileError("The native process/PTY spike currently supports Linux x86_64 only");
}
pub const pid_t = c_int;
pub const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short = 0 };
pub const Timespec = extern struct { sec: c_long, nsec: c_long };
pub const Winsize = extern struct { rows: u16, columns: u16, xpixel: u16 = 0, ypixel: u16 = 0 };
// Unlike fork, _Fork skips inherited pthread_atfork callbacks, which may
// allocate or acquire application locks in this multithreaded host.
pub extern "c" fn _Fork() pid_t;
pub extern "c" fn setsid() pid_t;
pub extern "c" fn prctl(c_int, ...) c_int;
pub extern "c" fn close_range(c_uint, c_uint, c_int) c_int;
pub extern "c" fn pipe2(*[2]c_int, c_int) c_int;
pub extern "c" fn fcntl(c_int, c_int, ...) c_int;
pub extern "c" fn open([*:0]const u8, c_int, ...) c_int;
pub extern "c" fn close(c_int) c_int;
pub extern "c" fn dup2(c_int, c_int) c_int;
pub extern "c" fn chdir([*:0]const u8) c_int;
pub extern "c" fn execve([*:0]const u8, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8) c_int;
pub extern "c" fn _exit(c_int) noreturn;
pub extern "c" fn read(c_int, [*]u8, usize) isize;
pub extern "c" fn write(c_int, [*]const u8, usize) isize;
pub extern "c" fn poll([*]PollFd, c_ulong, c_int) c_int;
pub extern "c" fn waitpid(pid_t, ?*c_int, c_int) pid_t;
pub extern "c" fn waitid(c_int, c_uint, *[32]c_int, c_int) c_int;
pub extern "c" fn kill(pid_t, c_int) c_int;
pub extern "c" fn clock_gettime(c_int, *Timespec) c_int;
pub extern "c" fn __errno_location() *c_int;
pub extern "c" fn sigemptyset(*[16]c_ulong) c_int;
pub extern "c" fn sigfillset(*[16]c_ulong) c_int;
pub extern "c" fn sigprocmask(c_int, *const [16]c_ulong, ?*[16]c_ulong) c_int;
pub extern "c" fn signal(c_int, ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;
pub extern "c" fn openpty(*c_int, *c_int, ?[*]u8, ?*const anyopaque, ?*const Winsize) c_int;
pub extern "c" fn ioctl(c_int, c_ulong, ...) c_int;
pub extern "c" fn isatty(c_int) c_int;
pub const CLOEXEC = 0x80000;
pub const NONBLOCK = 0x800;
pub const EINTR = 4;
pub const EAGAIN = 11;
pub const EIO = 5;
pub const ECHILD = 10;
pub const TERM = 15;
pub const KILL = 9;
pub const POLLIN = 1;
pub const POLLOUT = 4;
pub const POLLHUP = 16;
pub const TIOCSCTTY = 0x540e;
pub const TIOCSWINSZ = 0x5414;
pub const TIOCGWINSZ = 0x5413;
pub fn errno() c_int {
    return __errno_location().*;
}
pub fn nowMs() i64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(1, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}
