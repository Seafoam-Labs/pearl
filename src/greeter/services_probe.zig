//! Private-services test mode, compiled out of the installed greeter.
const std = @import("std");
const glib = @import("glib2");
const gio = @import("gio2");
const Power = @import("power.zig").Power;
const Probe = struct {
    power: Power = undefined,
    loop: *glib.MainLoop,
    updates: usize = 0,
    request: bool = false,
    fn changed(context: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.updates += 1;
        if (self.updates < 2) return;
        if (self.updates == 2 and self.power.reboot) {
            self.request = true;
            self.power.request(true) catch self.loop.quit();
            return;
        }
        self.loop.quit();
    }
};
pub fn run() !void {
    const address = std.mem.span(glib.getenv("DBUS_SYSTEM_BUS_ADDRESS") orelse return error.PrivateBusRequired);
    if (!std.mem.startsWith(u8, address, "unix:path=/tmp/pearl-")) return error.PrivateBusRequired;
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    const list = try @import("accounts.zig").load(arena.allocator(), cancel);
    if (list.len != 1 or !std.mem.eql(u8, list[0].username, "fixture-user")) return error.InvalidAccounts;
    var self: Probe = .{ .loop = glib.MainLoop.new(null, 0) };
    defer self.loop.unref();
    self.power = .{ .context = &self, .changed = Probe.changed };
    self.power.init();
    self.loop.run();
    glib.print("{\"accounts\":1,\"requested\":%s}\n", @as([*:0]const u8, if (self.request) "true" else "false"));
}
