//! Fixed argv dispatch with synchronous exec failure reporting and GDK activation context.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("spawn.h");
});
const nav = @import("../desktop/settings_navigation.zig");
const distribution = @import("distribution.zig");
const a = std.heap.c_allocator;
pub fn path() ![:0]u8 {
    var buffer: [4096]u8 = undefined;
    const result = try distribution.sibling(a, try distribution.executable(&buffer));
    errdefer a.free(result);
    if (std.c.access(result, std.c.X_OK) != 0) return error.SettingsNotInstalled;
    return result;
}
pub fn available() bool {
    const result = path() catch return false;
    a.free(result);
    return true;
}
pub fn open(target: nav.Target, context: *gio.AppLaunchContext, activation: ?[]const u8) !void {
    try target.validate();
    const program = try path();
    defer a.free(program);
    // AppInfo is used only to obtain native activation context, never to spawn.
    const quoted = glib.shellQuote(program);
    defer glib.free(quoted);
    var err: ?*glib.Error = null;
    const info = gio.AppInfo.createFromCommandline(quoted, "Pearl Settings", .{ .supports_startup_notification = true }, &err) orelse {
        if (err) |e| e.free();
        return error.SettingsLaunchFailed;
    };
    defer info.unref();
    const generated = if (activation == null) context.getStartupNotifyId(info, null) else null;
    defer if (generated) |token| glib.free(token);
    const token = activation orelse if (generated) |value| std.mem.span(value) else null;
    const startup: ?[:0]u8 = if (token) |value| blk: {
        if (value.len == 0 or value.len > 4096 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidActivation;
        break :blk try a.dupeZ(u8, value);
    } else null;
    defer if (startup) |value| a.free(value);
    if (startup) |value| {
        context.setenv("XDG_ACTIVATION_TOKEN", value);
        context.setenv("DESKTOP_STARTUP_ID", value);
    }
    errdefer if (startup) |value| context.launchFailed(value);
    const environment = context.getEnvironment();
    defer glib.strfreev(@ptrCast(environment));
    const section = if (target.section) |value| try a.dupeZ(u8, value) else null;
    defer if (section) |value| a.free(value);
    const argv = [_:null]?[*:0]const u8{ program, "--page", target.page.id(), if (section != null) "--section" else null, if (section) |value| value.ptr else null };
    var actions: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&actions) != 0) return error.SettingsLaunchFailed;
    defer _ = c.posix_spawn_file_actions_destroy(&actions);
    // Shell service connections must never leak into the independent frontend.
    if (c.posix_spawn_file_actions_addclosefrom_np(&actions, 3) != 0) return error.SettingsLaunchFailed;
    var pid: c.pid_t = 0;
    if (c.posix_spawn(&pid, program, &actions, null, @ptrCast(@constCast(&argv)), @ptrCast(environment)) != 0) return error.SettingsLaunchFailed;
    _ = glib.childWatchAdd(pid, reaped, null);
}
fn reaped(pid: glib.Pid, _: c_int, _: ?*anyopaque) callconv(.c) void {
    glib.spawnClosePid(pid);
}
