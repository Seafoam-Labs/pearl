//! Screensaver preview harness: drives the real src/services/screensaver.zig
//! in an ordinary window so modes can be compared without locking or idling
//! the session. Dev tool only; never installed by the default build.
//!
//!   zig build build-saver-preview
//!   PEARL_SAVER_MODE=qix ./zig-out/bin/pearl-saver-preview
//!
//! Keys: n / space / right cycles modes, Esc or q quits. The window title
//! always names the running mode. PEARL_SAVER_SECONDS=N advances automatically
//! every N seconds and quits after the last mode, for hands-free comparison.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const glib = @import("glib2");
const saver_mod = @import("screensaver");

const order = [_]saver_mod.Mode{ .starfield, .matrix, .mystify, .pipes, .qix, .maze, .life, .ocean_fall };

var saver: saver_mod.Saver = .{};
var area: *gtk.DrawingArea = undefined;
var window: *gtk.Window = undefined;
var main_loop: *glib.MainLoop = undefined;
var key_ctx: u8 = 0;

fn title(mode: saver_mod.Mode) [:0]const u8 {
    return switch (mode) {
        .off => "Pearl screensaver preview · off",
        .starfield => "Pearl screensaver preview · starfield",
        .matrix => "Pearl screensaver preview · matrix",
        .mystify => "Pearl screensaver preview · mystify",
        .pipes => "Pearl screensaver preview · pipes",
        .qix => "Pearl screensaver preview · qix",
        .maze => "Pearl screensaver preview · maze",
        .life => "Pearl screensaver preview · life",
        .ocean_fall => "Pearl screensaver preview · ocean fall",
    };
}
fn setMode(mode: saver_mod.Mode) void {
    saver.stop();
    saver.start(mode);
    window.setTitle(title(mode));
}
fn cycle() void {
    const current = @backingInt(saver.mode);
    var index: usize = 0;
    for (order, 0..) |mode, i| {
        if (@backingInt(mode) == current) index = i;
    }
    setMode(order[(index + 1) % order.len]);
}
fn key(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, _: *u8) callconv(.c) c_int {
    switch (keyval) {
        0xff1b, 'q' => {
            main_loop.quit();
            return 1;
        },
        'n', 0x20, 0xff53 => {
            cycle();
            return 1;
        },
        else => return 0,
    }
}
var auto_index: usize = 0;
fn autoNext(_: ?*anyopaque) callconv(.c) c_int {
    auto_index += 1;
    if (auto_index >= order.len) {
        main_loop.quit();
        return 0;
    }
    setMode(order[auto_index]);
    return 1;
}

pub fn main() !void {
    var mode: saver_mod.Mode = .starfield;
    if (glib.getenv("PEARL_SAVER_MODE")) |raw| mode = std.meta.stringToEnum(saver_mod.Mode, std.mem.span(raw)) orelse .starfield;
    if (mode == .off) mode = .starfield;
    gtk.init();
    window = gtk.Window.new();
    window.setDefaultSize(1280, 800);
    area = gtk.DrawingArea.new();
    area.as(gtk.Widget).setHexpand(1);
    area.as(gtk.Widget).setVexpand(1);
    area.setDrawFunc(saver_mod.Saver.draw, &saver, null);
    window.setChild(area.as(gtk.Widget));
    const keys = gtk.EventControllerKey.new();
    _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *u8, key, &key_ctx, .{});
    window.as(gtk.Widget).addController(keys.as(gtk.EventController));
    saver.attach(area);
    window.present();
    setMode(mode);
    if (glib.getenv("PEARL_SAVER_SECONDS")) |raw| {
        const seconds = std.fmt.parseInt(u32, std.mem.span(raw), 10) catch 0;
        if (seconds > 0) {
            for (order, 0..) |m, i| {
                if (m == mode) auto_index = i;
            }
            _ = glib.timeoutAddSeconds(seconds, autoNext, null);
        }
    }
    main_loop = glib.MainLoop.new(null, 0);
    defer main_loop.unref();
    main_loop.run();
    saver.stop();
    saver.detach(area);
    area.setDrawFunc(null, null, null);
    window.destroy();
}
