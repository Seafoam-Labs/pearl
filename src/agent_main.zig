const std = @import("std");
const c = @cImport({
    @cInclude("sys/prctl.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
});
pub fn main(init: std.process.Init) void {
    @import("i18n").init(false);
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(2);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        @import("glib2").print("pearl-agent " ++ @import("version.zig").string ++ " (Zig 0.16.0, agent v1)\n");
        return;
    }
    if (args.len != 2 or !std.mem.eql(u8, args[1], "--shell-fd=3")) {
        @import("glib2").printerr("%s\n", @import("i18n").dtr("pearl-agent", "Open Pearl Assistant from the Super+Space launcher.").ptr);
        return;
    }
    const parent = c.getppid();
    _ = c.prctl(c.PR_SET_PDEATHSIG, @as(c_int, c.SIGKILL), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
    if (parent == 1 or c.getppid() != parent) std.process.exit(2);
    std.process.exit(@import("agent/application.zig").run() catch 3);
}
