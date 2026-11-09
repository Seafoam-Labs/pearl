//! Search-private allocation and regular-file reads; never resolves a file path.
const std = @import("std");
const c = @import("pearl_app_c");
const checked = @import("ignore_fs.zig");

pub const TestHooks = if (@import("builtin").is_test) struct {
    pub var after_read: ?*const fn (*c.GCancellable) void = null;
} else struct {};

pub const Memory = struct {
    backing: std.mem.Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,
    hit: bool = false,

    pub fn allocator(self: *Memory) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Memory = @ptrCast(@alignCast(context));
        if (len > self.limit - self.live) {
            self.hit = true;
            return null;
        }
        const memory = self.backing.rawAlloc(len, alignment, ret) orelse return null;
        self.live += len;
        self.peak = @max(self.peak, self.live);
        return memory;
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.backing.rawFree(bytes, alignment, ret);
        self.live -= bytes.len;
    }
};

/// Move-only pin retained while buffered text is matched across worker batches.
/// Directory generations do not detect in-place writes to this file.
pub const PinnedFile = struct {
    fd: c_int,
    stamp: std.os.linux.Statx,

    pub fn validate(self: *const PinnedFile, cancel: *c.GCancellable) !void {
        try checked.cancelled(cancel);
        if (!checked.same(self.stamp, try checked.inspect(self.fd))) return error.DirectoryChanged;
    }

    pub fn deinit(self: *PinnedFile) void {
        _ = std.c.close(self.fd);
        self.* = undefined;
    }
};

/// fd is already descriptor-checked. Charges successful bytes, including EOF
/// probes, and polls every chunk. The caller budgets size+1 before starting.
pub fn read(allocator: std.mem.Allocator, fd: c_int, before: std.os.linux.Statx, cancel: *c.GCancellable, scanned: *usize) ![]u8 {
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    errdefer allocator.free(bytes);
    var at: usize = 0;
    while (at < bytes.len) {
        try checked.cancelled(cancel);
        const n = std.c.read(fd, bytes[at..].ptr, @min(4096, bytes.len - at));
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return error.Io;
        }
        if (n == 0) return error.DirectoryChanged;
        at += @intCast(n);
        scanned.* += @intCast(n);
        if (@import("builtin").is_test) {
            if (TestHooks.after_read) |hook| hook(cancel);
        }
    }
    var probe: [1]u8 = undefined;
    while (true) {
        try checked.cancelled(cancel);
        const n = std.c.read(fd, &probe, 1);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n < 0) return error.Io;
        scanned.* += 1; // Account for the EOF probe even when it reads zero bytes.
        if (n != 0) return error.DirectoryChanged;
        break;
    }
    if (!checked.same(before, try checked.inspect(fd))) return error.DirectoryChanged;
    return bytes;
}
