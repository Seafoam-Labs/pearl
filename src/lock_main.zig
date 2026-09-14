const std = @import("std");
pub fn main(init: std.process.Init) !void {
    // Broken readiness pipes cannot terminate an acquired locker. Never dump credentials.
    var action: std.c.Sigaction = .{ .handler = .{ .handler = std.c.SIG.IGN }, .mask = std.mem.zeroes(std.c.sigset_t), .flags = 0 };
    _ = std.c.sigaction(std.c.SIG.PIPE, &action, null);
    var limits: std.c.rlimit = .{ .cur = 0, .max = 0 };
    _ = std.c.setrlimit(.CORE, &limits);
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        @import("glib2").print("pearl-lock " ++ @import("version.zig").string ++ " (Zig 0.16.0)\n");
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--pam")) {
        @import("lock/pam.zig").main();
        return;
    }
    if (args.len > 2 or (args.len == 2 and !std.mem.eql(u8, args[1], "--ready-fd=3"))) return error.InvalidArguments;
    if (args.len == 2) {
        // Validate before GTK opens descriptors: an absent fd 3 could otherwise
        // become the Wayland socket and be mistaken for the readiness pipe.
        var stat: std.os.linux.Statx = undefined;
        const flags = std.c.fcntl(3, std.c.F.GETFL);
        if (std.os.linux.statx(3, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stat) != 0 or !stat.mask.TYPE or !std.c.S.ISFIFO(stat.mode) or flags < 0) return error.InvalidReadinessPipe;
        const access: std.c.O = @bitCast(@as(u32, @intCast(flags)));
        if (access.ACCMODE == .RDONLY) return error.InvalidReadinessPipe;
    }
    try @import("lock/screen.zig").run(args.len == 2);
}
