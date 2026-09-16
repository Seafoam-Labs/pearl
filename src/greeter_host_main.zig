const std = @import("std");
const glib = @import("glib2");
pub fn main(init: std.process.Init) !void {
    @import("greeter/logging.zig").init();
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        glib.print("pearl-greeter-host " ++ @import("version.zig").string ++ " (Aqueous)\n");
        return;
    }
    if (@import("build_options").test_hooks and args.len >= 3 and std.mem.eql(u8, args[1], "--fixture")) return @import("greeter/host.zig").run(args[2..]);
    if (@import("build_options").test_hooks and args.len >= 3 and std.mem.eql(u8, args[1], "--fixture-host")) {
        prepareEnvironment();
        return @import("greeter/host.zig").runManaged(args[2..]);
    }
    if (args.len != 1) return error.InvalidArguments;
    if (std.os.linux.getuid() == 0) return error.UnprivilegedAccountRequired;
    const config = try @import("greeter/config.zig").load(std.heap.c_allocator);
    defer config.deinit();
    if (glib.getenv("XDG_RUNTIME_DIR") == null) return error.RuntimeDirectoryRequired;
    if (glib.getenv("GREETD_SOCK") == null) return error.GreetdSocketRequired;
    prepareEnvironment();
    try @import("greeter/host.zig").runManaged(&.{ "/usr/bin/dbus-run-session", "--", "/usr/bin/aqueous", "-no-xwayland", "-c", "/usr/lib/pearl/pearl-greeter-init" });
}
fn prepareEnvironment() void {
    // greetd supplies the account/runtime. Never reuse a previous desktop's endpoints.
    for ([_][*:0]const u8{ "WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DISPLAY", "AQUEOUS_SOCKET", "AQUEOUS_IPC_SOCKET", "DBUS_SESSION_BUS_ADDRESS" }) |key| glib.unsetenv(key);
    _ = glib.setenv("GDK_BACKEND", "wayland", 1);
    _ = glib.setenv("XDG_SESSION_TYPE", "wayland", 1);
    _ = glib.setenv("XDG_CACHE_HOME", "/var/cache/pearl-greeter", 1);
    _ = glib.setenv("XDG_STATE_HOME", "/var/lib/pearl-greeter", 1);
}
