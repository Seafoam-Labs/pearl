const std = @import("std");
const u = @import("ui/widgets.zig");
const c = u.c;
const App = @import("app.zig").App;
const Preferences = @import("platform/preferences.zig").Preferences;
const options = @import("build_options");
pub const identity = if (options.git_variant) "org.aqueous.Dome.Git" else "org.aqueous.Dome";
var prefs: Preferences = undefined;
var instance: ?*App = null;
var css: ?*c.GtkCssProvider = null;
fn activate(application: ?*c.GApplication, _: ?*anyopaque) callconv(.c) void {
    if (instance) |app| {
        c.gtk_window_present(u.cast(c.GtkWindow, app.window));
        return;
    }
    instance = App.create(u.cast(c.GtkApplication, application), prefs);
}
fn startup(_: ?*c.GApplication, _: ?*anyopaque) callconv(.c) void {
    css = c.gtk_css_provider_new().?;
    c.gtk_css_provider_load_from_string(css, @embedFile("style"));
    c.gtk_style_context_add_provider_for_display(c.gdk_display_get_default(), @ptrCast(css), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}
pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return;
    prefs = Preferences.load();
    var dump = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            c.g_print("Dome — native Linux system monitor\nUsage: dome [--light|--dark|--native-theme] [--compact] [--page=0..8] [--width=N] [--height=N]\n       dome --dump  (one read-only JSON snapshot)\nCtrl+1 Overview, Ctrl+2 Processes, Ctrl+P pause, F5 sample, Ctrl+F search, Ctrl+W close.\n");
            return;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            c.g_print("Dome 0.1.0 (Zig 0.16.0 / GTK4)\n");
            return;
        }
        if (std.mem.eql(u8, arg, "--dump")) {
            dump = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--gpu-probe")) {
            @import("platform/nvml.zig").probe();
            return;
        }
        if (std.mem.eql(u8, arg, "--light")) {
            prefs.light = true;
            prefs.native = false;
        } else if (std.mem.eql(u8, arg, "--dark")) {
            prefs.light = false;
            prefs.native = false;
        } else if (std.mem.eql(u8, arg, "--native-theme")) prefs.native = true else if (std.mem.eql(u8, arg, "--compact")) prefs.compact = true else if (std.mem.startsWith(u8, arg, "--width=")) prefs.width = std.math.clamp(std.fmt.parseInt(c_int, arg[8..], 10) catch 1120, 390, 3840) else if (std.mem.startsWith(u8, arg, "--height=")) prefs.height = std.math.clamp(std.fmt.parseInt(c_int, arg[9..], 10) catch 800, 400, 2160) else if (std.mem.startsWith(u8, arg, "--page=")) prefs.page = std.math.clamp(std.fmt.parseInt(u32, arg[7..], 10) catch 0, 0, 8) else {
            c.g_printerr("Unknown option: %s\n", arg.ptr);
            std.process.exit(2);
        }
    }
    if (dump) {
        const s = @import("collectors/linux.zig").collect(null, 1);
        defer s.unref();
        c.g_print("{\"processes\":%zu,\"logical_cpus\":%zu,\"memory_total\":%llu,\"disks\":%zu,\"networks\":%zu,\"gpus\":%zu,\"sensors\":%zu,\"collection_us\":%lld}\n", s.processes.len, s.cpus.len -| 1, @as(c_ulonglong, s.memory.total), s.disks.len, s.networks.len, s.gpus.len, s.sensors.len, @as(c_longlong, s.duration));
        return;
    }
    const app = c.gtk_application_new(identity, c.G_APPLICATION_NON_UNIQUE).?;
    defer c.g_object_unref(app);
    u.connect(app, "activate", &activate, null);
    u.connect(app, "startup", &startup, null);
    var argv = [_][*:0]u8{@constCast("dome")};
    const result = c.g_application_run(@ptrCast(app), 1, @ptrCast(&argv));
    if (instance) |i| i.destroy();
    if (css) |provider| {
        c.gtk_style_context_remove_provider_for_display(c.gdk_display_get_default(), @ptrCast(provider));
        c.g_object_unref(provider);
    }
    if (result != 0) std.process.exit(@intCast(result));
}
