const std = @import("std");
pub fn main(init: std.process.Init) !void {
    // Broken readiness pipes cannot terminate an acquired locker. Never dump credentials.
    var action: std.c.Sigaction = .{ .handler = .{ .handler = std.c.SIG.IGN }, .mask = std.mem.zeroes(std.c.sigset_t), .flags = 0 };
    _ = std.c.sigaction(std.c.SIG.PIPE, &action, null);
    var limits: std.c.rlimit = .{ .cur = 0, .max = 0 };
    _ = std.c.setrlimit(.CORE, &limits);
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--pam")) {
        @import("lock/pam.zig").main();
        return;
    }
    if (args.len > 2 or (args.len == 2 and !std.mem.eql(u8, args[1], "--ready-fd=3"))) return error.InvalidArguments;
    try @import("lock/screen.zig").run(args.len == 2);
}
