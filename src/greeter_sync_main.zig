const std = @import("std");
const glib = @import("glib2");
const sync = @import("greeter/appearance_sync.zig");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        glib.print("pearl-greeter-sync " ++ @import("version.zig").string ++ "\n");
        return;
    }
    var directory: []const u8 = "/etc/pearl";
    if (@import("build_options").test_hooks and args.len == 3 and std.mem.eql(u8, args[1], "--fixture")) {
        directory = args[2];
    } else if (args.len != 2 or !std.mem.eql(u8, args[1], "--apply") or std.os.linux.getuid() != 0) return error.AdministratorRequired;
    const bytes = try sync.read(0, sync.max_request);
    defer std.heap.c_allocator.free(bytes);
    sync.apply(directory, bytes) catch |err| {
        std.log.err("{s}", .{@errorName(err)});
        std.process.exit(1);
    };
}
