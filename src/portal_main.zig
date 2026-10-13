const std = @import("std");
pub const safe = @import("diagnostics/safe_text.zig").safe;
comptime {
    _ = @import("previews").api;
    _ = @import("file_chooser");
    _ = @import("portal/appearance.zig");
}
const backend = @import("portal/backend.zig");
pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(2);
    const argv = init.arena.allocator().allocSentinel(?[*:0]const u8, args.len, null) catch std.process.exit(2);
    for (args, 0..) |arg, i| argv[i] = arg.ptr;
    std.process.exit(@intCast(backend.run(@intCast(args.len), @ptrCast(argv.ptr))));
}
