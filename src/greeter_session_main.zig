//! Runs only after greetd establishes the selected user's login session.
const std = @import("std");
const glib = @import("glib2");
const cfg = @import("greeter/config.zig");
const sessions = @import("greeter/sessions.zig");
const a = std.heap.c_allocator;
pub fn main(init: std.process.Init) !void {
    @import("greeter/logging.zig").init();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        glib.print("pearl-greeter-session " ++ @import("version.zig").string ++ "\n");
        return;
    }
    const x11_client = args.len == 2 and std.mem.eql(u8, args[1], "--x11-client");
    if (args.len != 1 and !x11_client) return error.InvalidArguments;
    if (std.os.linux.getuid() == 0) return error.UnprivilegedUserRequired;
    const id = std.mem.span(glib.getenv("PEARL_SESSION_ID") orelse return error.MissingSession);
    const fingerprint = std.mem.span(glib.getenv("PEARL_SESSION_FINGERPRINT") orelse return error.MissingFingerprint);
    if (!cfg.validId(id) or fingerprint.len != 64) return error.InvalidSelection;
    const config = try cfg.load(a);
    defer config.deinit();
    var catalog = try sessions.load(a, config.value, "C");
    defer catalog.deinit();
    const selected = catalog.find(id) orelse return error.SessionRemoved;
    if (!selected.available or !std.mem.eql(u8, fingerprint, &selected.fingerprint)) return error.SessionChanged;
    for ([_][*:0]const u8{ "GREETD_SOCK", "WAYLAND_DISPLAY", "WAYLAND_SOCKET", "AQUEOUS_SOCKET", "AQUEOUS_IPC_SOCKET", "DBUS_SESSION_BUS_ADDRESS", "LD_PRELOAD", "LD_LIBRARY_PATH", "GTK_PATH", "GTK_MODULES" }) |key| glib.unsetenv(key);
    if (!x11_client) {
        glib.unsetenv("DISPLAY");
        glib.unsetenv("XAUTHORITY");
    }
    try userBus();
    try set("PATH", "/usr/local/bin:/usr/bin:/bin");
    try set("XDG_SESSION_TYPE", selected.kind);
    try set("XDG_SESSION_DESKTOP", std.fs.path.stem(std.mem.sliceTo(selected.id[std.mem.indexOfScalar(u8, selected.id, ':').? + 1 ..], 0)));
    try set("DESKTOP_SESSION", std.fs.path.stem(selected.path));
    const desktop = try std.mem.replaceOwned(u8, a, std.mem.trimEnd(u8, selected.desktops, ";"), ";", ":");
    defer a.free(desktop);
    if (desktop.len != 0) try set("XDG_CURRENT_DESKTOP", desktop) else glib.unsetenv("XDG_CURRENT_DESKTOP");
    if (std.mem.eql(u8, selected.kind, "x11") and !x11_client) return execute(&.{"/usr/lib/pearl/pearl-greeter-x11"});
    if (x11_client and !std.mem.eql(u8, selected.kind, "x11")) return error.InvalidSessionType;
    glib.unsetenv("PEARL_SESSION_ID");
    glib.unsetenv("PEARL_SESSION_FINGERPRINT");
    try execute(selected.argv);
}
fn set(key: [*:0]const u8, value: []const u8) !void {
    const z = try a.dupeZ(u8, value);
    defer a.free(z);
    if (glib.setenv(key, z, 1) == 0) return error.Environment;
}
fn execute(args: []const []const u8) !void {
    var argv: [257:null]?[*:0]const u8 = @splat(null);
    if (args.len > 256) return error.Arguments;
    for (args, 0..) |arg, i| argv[i] = (try a.dupeZ(u8, arg)).ptr;
    _ = std.c.execve(argv[0].?, @ptrCast(&argv), @ptrCast(std.c.environ));
    return error.SessionExecFailed;
}

fn userBus() !void {
    const runtime = glib.getenv("XDG_RUNTIME_DIR") orelse return error.MissingUserRuntime;
    const fd = std.c.open(runtime, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.InvalidUserRuntime;
    defer _ = std.c.close(fd);
    var stat: std.os.linux.Statx = undefined;
    if (std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .UID = true, .MODE = true }, &stat) != 0 or stat.uid != std.os.linux.getuid() or stat.mode & 0o077 != 0) return error.InvalidUserRuntime;
    if (std.os.linux.statx(fd, "bus", std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .UID = true, .TYPE = true }, &stat) == 0) {
        if (stat.uid != std.os.linux.getuid() or !std.c.S.ISSOCK(stat.mode)) return error.InvalidUserBus;
        const address = try std.fmt.allocPrint(a, "unix:path={s}/bus", .{std.mem.span(runtime)});
        defer a.free(address);
        try set("DBUS_SESSION_BUS_ADDRESS", address);
    }
    // If PAM did not establish a user bus, the selected desktop's verified
    // packaged launcher owns bus creation. Never create an untested extra bus.
}
