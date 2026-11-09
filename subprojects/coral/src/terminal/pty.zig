//! M0 native PTY TRANSPORT spike, not a terminal emulator or an M5 renderer.
//! Linux, libc only. No GTK initialization, widget, VT parser, clipboard/OSC,
//! hyperlinks, font shaping, scrollback or GPU integration is implemented.
//!
//! Thread boundary: start/wait/deinit belong on a worker, never the UI thread.
//! read/write/resize are nonblocking; integrate the master fd with poll/GLib
//! before using them in an application. Serialize handle operations; a single
//! waiter may run concurrently with cancel. Caller owns bounded byte buffers.
//! Bytes (including split UTF-8 and arbitrary control sequences) are untrusted
//! opaque data. Do NOT print them to a host terminal or interpret them as UI.
//! Caller vets exact argv, cwd, and the complete environment allowlist. No
//! shell interpolation is performed by this API. This is not OS isolation.
//! Cancellation and normal leader-exit cleanup use ownership.zig's pinned
//! process group/private reaper, with the same setsid/setpgid escape limitation.
//! Interactive shell job-control groups are therefore NOT a completed lifecycle
//! feature of this spike; tests use non-interactive shell fixtures with a PTY.
const std = @import("std");
const ownership = @import("ownership.zig");
pub const os = ownership.os;
pub const Report = ownership.Report;
pub const Config = struct {
    authorization: enum { denied, approved } = .denied,
    argv: [:null]const ?[*:0]const u8,
    environment: [:null]const ?[*:0]const u8 = &.{},
    cwd: [:0]const u8,
    rows: u16 = 24,
    columns: u16 = 80,
};
pub const Error = error{ Unauthorized, InvalidConfig, SystemResources, WouldBlock, Io, Closed };
pub const Pty = struct {
    master: c_int,
    owner: ownership.Owner,
    completion: ?Report = null,

    /// Nonblocking, byte-exact transport. Linux PTY EIO after slave closure is EOF.
    pub fn read(self: *Pty, buffer: []u8) Error!usize {
        if (self.master < 0) return error.Closed;
        while (true) {
            const n = os.read(self.master, buffer.ptr, buffer.len);
            if (n >= 0) return @intCast(n);
            switch (os.errno()) {
                os.EINTR => continue,
                os.EAGAIN => return error.WouldBlock,
                os.EIO => return 0,
                else => return error.Io,
            }
        }
    }

    /// May write only a prefix; caller retries the remainder after POLLOUT.
    pub fn write(self: *Pty, bytes: []const u8) Error!usize {
        if (self.master < 0) return error.Closed;
        while (true) {
            const n = os.write(self.master, bytes.ptr, bytes.len);
            if (n >= 0) return @intCast(n);
            switch (os.errno()) {
                os.EINTR => continue,
                os.EAGAIN => return error.WouldBlock,
                else => return error.Io,
            }
        }
    }

    pub fn resize(self: *Pty, rows: u16, columns: u16) Error!void {
        if (rows == 0 or columns == 0) return error.InvalidConfig;
        if (self.master < 0) return error.Closed;
        var size = os.Winsize{ .rows = rows, .columns = columns };
        if (os.ioctl(self.master, os.TIOCSWINSZ, &size) < 0) return error.Io;
    }

    pub fn cancel(self: *Pty) void {
        self.owner.cancel();
    }

    /// Blocking. Drain output before normal wait (or cancel first); otherwise
    /// a command blocked on a full PTY may itself be waiting for the reader.
    pub fn wait(self: *Pty) Report {
        if (self.completion == null) self.completion = self.owner.wait();
        return self.completion.?;
    }

    /// Blocking cleanup for worker use. Safe even if the caller forgot cancel.
    pub fn deinit(self: *Pty) void {
        if (self.master < 0) return;
        self.cancel();
        _ = self.wait();
        self.owner.deinit();
        _ = os.close(self.master);
        self.master = -1;
    }
};

/// Request strings are borrowed only until return (fork gives the supervisor
/// its own copy). A successful start still reports exec/setup errors via wait.
pub fn start(config: Config) Error!Pty {
    if (config.authorization != .approved) return error.Unauthorized;
    if (config.argv.len == 0 or config.argv.len > 4096 or config.environment.len > 4096 or
        config.cwd.len == 0 or config.cwd[0] != '/' or config.rows == 0 or config.columns == 0)
        return error.InvalidConfig;
    for (config.argv) |arg| if (arg == null) return error.InvalidConfig;
    if (config.argv[0].?[0] != '/') return error.InvalidConfig;
    for (config.environment) |entry| {
        const text = std.mem.span(entry orelse return error.InvalidConfig);
        const equal = std.mem.indexOfScalar(u8, text, '=') orelse return error.InvalidConfig;
        if (equal == 0) return error.InvalidConfig;
    }
    var master: c_int = -1;
    var slave: c_int = -1;
    var size = os.Winsize{ .rows = config.rows, .columns = config.columns };
    if (os.openpty(&master, &slave, null, null, &size) != 0) return error.SystemResources;
    errdefer _ = os.close(master);
    defer _ = os.close(slave);
    if (os.fcntl(master, 2, @as(c_int, 1)) < 0 or os.fcntl(slave, 2, @as(c_int, 1)) < 0 or
        os.fcntl(master, 4, @as(c_int, os.NONBLOCK)) < 0) return error.SystemResources;
    const owner = try ownership.start(.{
        .argv = config.argv.ptr,
        .environment = config.environment.ptr,
        .cwd = config.cwd,
        .stdin = slave,
        .stdout = slave,
        .stderr = slave,
        .terminal = true,
    });
    return .{ .master = master, .owner = owner };
}

test {
    _ = @import("pty_test.zig");
}
