const std = @import("std");
const glib = @import("glib2");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        glib.print("pearl-greeter-host " ++ @import("version.zig").string ++ " (restricted Aqueous gate pending)\n");
        return;
    }
    if (@import("build_options").test_hooks and args.len >= 3 and std.mem.eql(u8, args[1], "--fixture")) return @import("greeter/host.zig").run(args[2..]);
    // Do not invent an Aqueous --greeter flag or certify ordinary startup profiles.
    std.log.err("Restricted Aqueous host contract is not available; see docs/AQUEOUS_GREETER_REQUIREMENTS.md", .{});
    return error.RestrictedHostNotVerified;
}
