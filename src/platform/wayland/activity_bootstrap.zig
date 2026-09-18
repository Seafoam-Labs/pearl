//! Capture before GTK/worker startup. Only the broker may consume this descriptor.
const std = @import("std");
const glib = @import("glib2");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});
var proof: c_int = -1;
pub fn capture(init: std.process.Init) !void {
    const value = glib.getenv("AQUEOUS_INPUT_ACTIVITY_FD") orelse return;
    const fd = std.fmt.parseInt(c_int, std.mem.span(value), 10) catch -1;
    if (fd >= 3) {
        const flags = c.fcntl(fd, c.F_GETFD);
        if (flags >= 0) {
            if (c.fcntl(fd, c.F_SETFD, flags | c.FD_CLOEXEC) >= 0) proof = fd else _ = c.close(fd);
        }
    }
    // libc unsetenv compacts its pointer array. Zig 0.16 retains the original
    // array with its original length for lazy Io initialization. Give libc its
    // own array first, then scrub the retained entry without shortening it.
    const live = std.mem.span(std.c.environ);
    // libc and shared-library destructors use this after main returns.
    // Keep the small pointer array for the lifetime of the process.
    const copy = try std.heap.c_allocator.allocSentinel(?[*:0]u8, live.len, null);
    @memcpy(copy, live);
    std.c.environ = copy.ptr;
    glib.unsetenv("AQUEOUS_INPUT_ACTIVITY_FD");
    for (@constCast(init.minimal.environ.block.slice)) |*entry| {
        if (entry.*) |text| if (std.mem.startsWith(u8, std.mem.span(text), "AQUEOUS_INPUT_ACTIVITY_FD=")) {
            entry.* = "PEARL_BOOTSTRAP_CONSUMED=1";
        };
    }
    _ = init.environ_map.swapRemove("AQUEOUS_INPUT_ACTIVITY_FD");
}
pub fn take() c_int {
    const fd = proof;
    proof = -1;
    return fd;
}
pub fn close() void {
    if (proof >= 0) _ = c.close(proof);
    proof = -1;
}
