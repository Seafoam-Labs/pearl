//! Headless integration driver; consumes explicit local config, never downloads.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const benchmark = @import("agent/benchmark.zig");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.ExpectedBenchmarkInputFile;
    const input = try @import("config/io.zig").read(a, try a.dupeZ(u8, args[1]), 65536, null);
    const options = try std.json.parseFromSliceLeaky(struct { config: @import("agent/config.zig").Config, options: benchmark.Options = .{}, cancel_after_ms: u32 = 0, skip_after_ms: u32 = 0 }, a, input.bytes, .{});
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    var progress: benchmark.Progress = .{};
    const thread = if (options.cancel_after_ms > 0) try std.Thread.spawn(.{}, cancelLater, .{ cancel, options.cancel_after_ms }) else if (options.skip_after_ms > 0) try std.Thread.spawn(.{}, skipLater, .{ &progress, options.skip_after_ms }) else null;
    defer if (thread) |t| t.join();
    const run = try benchmark.execute(a, options.config, options.options, cancel, &progress);
    const bytes = try std.json.Stringify.valueAlloc(a, run, .{ .whitespace = .indent_2 });
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(1, bytes[offset..].ptr, bytes.len - offset);
        if (n <= 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}
fn cancelLater(cancel: *gio.Cancellable, ms: u32) void {
    glib.usleep(@as(u64, ms) * 1000);
    cancel.cancel();
}
fn skipLater(progress: *benchmark.Progress, ms: u32) void {
    glib.usleep(@as(u64, ms) * 1000);
    progress.skip.store(true, .monotonic);
}
