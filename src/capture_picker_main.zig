const std = @import("std");
pub const safe = @import("diagnostics/safe_text.zig").safe;
pub fn main(init: std.process.Init) void {
    @import("capture/picker.zig").run(init) catch |err| {
        std.debug.print("Pearl capture picker: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
}
