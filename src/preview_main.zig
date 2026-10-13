const std = @import("std");
pub const std_options = @import("core/logging.zig").std_options;
pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(2);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--preview-capabilities")) {
        @import("previews").providers.emit();
    } else if (args.len > 2 and std.mem.eql(u8, args[1], "--preview-helper")) {
        @import("previews").helper.run(args[2..]);
    } else std.process.exit(2);
}
