//! Small compositor-free fixture. Saves are injected; no real state directory is used.
const std = @import("std");
const service = @import("../services/clipboard.zig");
const pixbuf = @import("gdkpixbuf2");

pub const Fixture = struct {
    clipboard: service.Clipboard = undefined,
    writes: usize = 0,
    fail: bool = false,
    save_error: ?anyerror = null,
    notifications: usize = 0,
    on_change: ?*const fn (*anyopaque) void = null,
    context: ?*anyopaque = null,
    pub fn init(self: *Fixture) void {
        self.* = .{};
        self.clipboard = .{ .display = undefined, .context = self, .changed = changed, .locked = false, .history_loaded = true, .test_time = 100, .test_save = save, .instance = @splat('a') };
    }
    pub fn deinit(self: *Fixture) void {
        self.clipboard.device = null;
        self.on_change = null;
        self.clipboard.stop();
    }
    pub fn copy(self: *Fixture, bytes: []const u8, seconds: i64) !u64 {
        self.clipboard.test_time = seconds;
        try self.clipboard.add(.text, bytes);
        return self.clipboard.rows[0].id;
    }
    fn changed(context: *anyopaque) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.notifications += 1;
        if (self.on_change) |notify| notify(self.context.?);
        _ = self.clipboard.entries();
    }
    fn save(clipboard: *service.Clipboard) !void {
        const self: *Fixture = @ptrCast(@alignCast(clipboard.context));
        self.writes += 1;
        if (self.save_error) |err| return err;
        if (self.fail) return error.InjectedSaveFailure;
    }
};

/// A real, tiny PNG for the service's sanitizer and duplicate comparisons.
pub fn image(color: u32) ![]u8 {
    const image_ = pixbuf.Pixbuf.new(.rgb, 0, 8, 2, 2) orelse return error.OutOfMemory;
    defer image_.unref();
    image_.fill(color);
    return service.encode(image_);
}
