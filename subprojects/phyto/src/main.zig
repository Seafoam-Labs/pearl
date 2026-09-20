const std = @import("std");
const u = @import("ui.zig");
const gtk = u.gtk;
const gio = u.gio;
const glib = u.glib;
const gdk = @import("gdk4");
const Window = @import("window.zig").Window;
const Options = @import("window.zig").Options;
var windows: std.ArrayList(*Window) = .empty;
var initial: ?*gio.File = null;
var options: Options = .{};

pub fn newWindow(app: *gtk.Application, file: *gio.File, opts: Options) void {
    windows.append(u.a, Window.create(app, file, opts)) catch @panic("Out of memory");
}
fn activate(app: *gio.Application, _: ?*anyopaque) callconv(.c) void {
    newWindow(@ptrCast(app), initial.?, options);
}
pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return;
    var location: ?[:0]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            glib.print("Phyto — native Pearl file explorer\nUsage: phyto [--light] [--compact] [--native-theme] [--width=N] [--height=N] [PATH_OR_URI]\n\nCtrl+L location, Ctrl+F filter, Ctrl+T new tab, F3 split panes, F6 switch pane.\n");
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            glib.print("Phyto 0.1.0 (Zig 0.16.0 / GTK4)\n");
            return;
        } else if (std.mem.eql(u8, arg, "--light")) options.light = true else if (std.mem.eql(u8, arg, "--compact")) options.compact = true else if (std.mem.eql(u8, arg, "--native-theme")) options.native = true else if (std.mem.startsWith(u8, arg, "--width=")) {
            options.width = std.fmt.parseInt(c_int, arg[8..], 10) catch 1180;
            options.width = std.math.clamp(options.width, 390, 3840);
        } else if (std.mem.startsWith(u8, arg, "--height=")) {
            options.height = std.fmt.parseInt(c_int, arg[9..], 10) catch 760;
            options.height = std.math.clamp(options.height, 400, 2160);
        } else if (std.mem.startsWith(u8, arg, "--") or location != null) {
            glib.printerr("Unknown option or extra location: %s\n", arg.ptr);
            std.process.exit(2);
        } else location = init.arena.allocator().dupeZ(u8, arg) catch return;
    }
    initial = if (location) |path| gio.File.newForCommandlineArg(path) else gio.File.newForPath(glib.getHomeDir());
    defer initial.?.unref();
    // Separate instances cannot route an activation into another display/session.
    const app = gtk.Application.new("org.aqueous.Phyto", .{ .non_unique = true });
    defer app.unref();
    _ = gio.Application.signals.activate.connect(app.as(gio.Application), ?*anyopaque, activate, null, .{});
    _ = gio.Application.signals.startup.connect(app.as(gio.Application), ?*anyopaque, startup, null, .{});
    var argv = [_][*:0]u8{@constCast("phyto")};
    const code = app.as(gio.Application).run(1, &argv);
    for (windows.items) |window| window.destroy();
    windows.deinit(u.a);
    if (provider) |css| {
        if (gdk.Display.getDefault()) |display| gtk.StyleContext.removeProviderForDisplay(display, css.as(gtk.StyleProvider));
        css.unref();
    }
    if (code != 0) std.process.exit(@intCast(code));
}
var provider: ?*gtk.CssProvider = null;
fn startup(_: *gio.Application, _: ?*anyopaque) callconv(.c) void {
    const css = gtk.CssProvider.new();
    provider = css;
    const source = @embedFile("style");
    css.loadFromString(source);
    gtk.StyleContext.addProviderForDisplay(gdk.Display.getDefault().?, css.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
}
