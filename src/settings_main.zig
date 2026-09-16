const std = @import("std");
pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(2);
    const options = @import("settings/options.zig");
    const parsed = options.Options.parse(args[1..]) catch {
        @import("glib2").printerr("%s", options.usage);
        std.process.exit(2);
    };
    if (parsed.help) {
        @import("glib2").print("%s", options.usage);
        return;
    }
    if (parsed.version) {
        @import("glib2").print("pearl-settings " ++ @import("version.zig").string ++ " (Zig 0.16.0, Settings v1)\n");
        return;
    }
    const code = @import("settings/application.zig").run(parsed.target) catch |err| {
        @import("glib2").printerr("Pearl Settings: %s\n", @errorName(err).ptr);
        std.process.exit(3);
    };
    std.process.exit(code);
}
