const std = @import("std");
const runner = @import("preview_runner.zig");
const providers = @import("preview_providers.zig");
pub fn render(fd: c_int, edge: u32, timeout: u32) runner.Result {
    var prefix: [1024]u8 = undefined;
    const n = std.c.pread(fd, &prefix, prefix.len, 0);
    if (n < 5 or std.mem.indexOf(u8, prefix[0..@intCast(n)], "%PDF-") == null) return .{ .status = .unsupported };
    var number: [16]u8 = undefined;
    const size = std.fmt.bufPrintZ(&number, "{d}", .{edge}) catch unreachable;
    return runner.run(providers.tool("pdftoppm"), &.{ "-f", "1", "-l", "1", "-singlefile", "-cropbox", "-scale-to", size, "-png", "/input/source" }, fd, timeout, 20 * 1024 * 1024);
}
