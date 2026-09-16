const std = @import("std");
const glib = @import("glib2");
const cfg = @import("greeter/config.zig");
const sessions = @import("greeter/sessions.zig");
const options = @import("build_options");
pub fn main(init: std.process.Init) !void {
    @import("greeter/logging.zig").init();
    var action: std.c.Sigaction = .{ .handler = .{ .handler = std.c.SIG.IGN }, .mask = std.mem.zeroes(std.c.sigset_t), .flags = 0 };
    _ = std.c.sigaction(std.c.SIG.PIPE, &action, null);
    var limits: std.c.rlimit = .{ .cur = 0, .max = 0 };
    _ = std.c.setrlimit(.CORE, &limits);
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        glib.print("pearl-greeter " ++ @import("version.zig").string ++ " (Zig 0.16.0)\n");
        return;
    }
    if (options.test_hooks and args.len == 2 and std.mem.eql(u8, args[1], "--services-probe")) return @import("greeter/services_probe.zig").run();
    if (options.test_hooks and args.len == 2 and std.mem.eql(u8, args[1], "--probe")) return @import("greeter/probe.zig").run();
    if (args.len == 2 and std.mem.eql(u8, args[1], "--catalog")) {
        const config = try cfg.load(std.heap.c_allocator);
        defer config.deinit();
        var catalog = try sessions.load(std.heap.c_allocator, config.value, "C");
        defer catalog.deinit();
        const json = try std.json.Stringify.valueAlloc(std.heap.c_allocator, .{ .sessions = catalog.entries.items, .skipped = catalog.skipped }, .{});
        defer std.heap.c_allocator.free(json);
        const z = try std.heap.c_allocator.dupeZ(u8, json);
        defer std.heap.c_allocator.free(z);
        glib.print("%s\n", z.ptr);
        return;
    }
    if (args.len != 1) return error.InvalidArguments;
    if (!options.test_hooks and std.os.linux.getuid() == 0) return error.UnprivilegedAccountRequired;
    try @import("greeter/screen.zig").run();
}
