const std = @import("std");
pub const safe = @import("diagnostics/safe_text.zig").safe;
comptime {
    _ = @import("previews").api;
    _ = @import("file_chooser");
    _ = @import("portal/appearance.zig");
}
extern fn pearl_portal_main(argc: c_int, argv: [*:null]const ?[*:0]const u8) c_int;
pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(2);
    const argv = init.arena.allocator().allocSentinel(?[*:0]const u8, args.len, null) catch std.process.exit(2);
    for (args, 0..) |arg, i| argv[i] = arg.ptr;
    std.process.exit(@intCast(pearl_portal_main(@intCast(args.len), argv.ptr)));
}
