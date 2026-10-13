const std = @import("std");
const chooser = @import("file_chooser");
pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(2);
    std.process.exit(chooser.harness.run(args));
}
