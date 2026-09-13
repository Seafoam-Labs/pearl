const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const glib = @import("glib2");
const glibunix = @import("glibunix2");
const gobject = @import("gobject2");
const layer = @import("gtk4layershell1");
const session_lock = @import("gtk4sessionlock1");

extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
extern "c" fn read(c_int, [*]u8, usize) isize;

var loop: *glib.MainLoop = undefined;
var bars: [16]*gtk.Window = undefined;
var monitors: [16]*gdk.Monitor = undefined;
var count: usize = 0;
var popup: ?*gtk.Window = null;
var popup_panel: *gtk.Box = undefined;
var lock_instance: ?*session_lock.Instance = null;
var command_buffer: [1024]u8 = undefined;
var command_length: usize = 0;

fn env(name: [*:0]const u8, fallback: []const u8) []const u8 {
    return if (getenv(name)) |value| std.mem.span(value) else fallback;
}

fn closePopup(reason: []const u8) void {
    const window = popup orelse return;
    popup = null;
    window.destroy();
    std.debug.print("T00 event=popup-closed reason={s}\n", .{reason});
}

fn keyPressed(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, _: gdk.ModifierType, _: ?*anyopaque) callconv(.c) c_int {
    if (key != 0xff1b) return 0;
    closePopup("escape");
    return 1;
}

fn outsideReleased(_: *gtk.GestureClick, _: c_int, x: f64, y: f64, _: ?*anyopaque) callconv(.c) void {
    const window = popup orelse return;
    const picked = window.as(gtk.Widget).pick(x, y, .{});
    const panel = popup_panel.as(gtk.Widget);
    if (picked) |widget| {
        if (widget == panel or widget.isAncestor(panel) != 0) return;
    }
    closePopup("outside-click");
}

fn textChanged(editable: *gtk.Editable, _: ?*anyopaque) callconv(.c) void {
    std.debug.print("T00 event=entry text={s}\n", .{editable.getText()});
}

fn openPopup(_: *gtk.Button, _: ?*anyopaque) callconv(.c) void {
    showPopup();
}

fn showPopup() void {
    if (popup != null or count == 0) return;
    const window = gtk.Window.new();
    popup = window;
    window.as(gtk.Widget).addCssClass("pearl-t00-popup");
    layer.initForWindow(window);
    layer.setNamespace(window, "pearl:t00-popup");
    layer.setMonitor(window, monitors[0]);
    layer.setLayer(window, .overlay);
    for ([_]layer.Edge{ .top, .right, .bottom, .left }) |edge| layer.setAnchor(window, edge, 1);
    // Ignore bar reservations: the dismissal backdrop covers the complete output.
    layer.setExclusiveZone(window, -1);
    layer.setKeyboardMode(window, .exclusive);
    const panel = gtk.Box.new(.vertical, 12);
    popup_panel = panel;
    panel.as(gtk.Widget).addCssClass("panel");
    panel.as(gtk.Widget).setHalign(.center);
    panel.as(gtk.Widget).setValign(.center);
    panel.as(gtk.Widget).setSizeRequest(440, 200);
    panel.append(gtk.Label.new("Pearl · binding and focus probe").as(gtk.Widget));
    const entry = gtk.Entry.new();
    entry.setPlaceholderText("Type here; Escape or click outside to close");
    _ = gtk.Editable.signals.changed.connect(entry.as(gtk.Editable), ?*anyopaque, textChanged, null, .{});
    panel.append(entry.as(gtk.Widget));
    panel.append(gtk.Label.new("Zig 0.16.0 · generated GTK layer-shell bindings").as(gtk.Widget));
    window.setChild(panel.as(gtk.Widget));
    const key = gtk.EventControllerKey.new().as(gtk.EventControllerKey);
    _ = gtk.EventControllerKey.signals.key_pressed.connect(key, ?*anyopaque, keyPressed, null, .{});
    window.as(gtk.Widget).addController(key.as(gtk.EventController));
    const click = gtk.GestureClick.new().as(gtk.GestureClick);
    click.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.GestureClick.signals.released.connect(click, ?*anyopaque, outsideReleased, null, .{});
    window.as(gtk.Widget).addController(click.as(gtk.EventController));
    window.present();
    _ = entry.as(gtk.Widget).grabFocus();
    std.debug.print("T00 event=popup-opened\n", .{});
}

fn underlyingClicked(_: *gtk.Button, _: ?*anyopaque) callconv(.c) void {
    std.debug.print("T00 event=underlying-click\n", .{});
}

fn onLockMonitor(instance: *session_lock.Instance, monitor: *gdk.Monitor, _: ?*anyopaque) callconv(.c) void {
    const window = gtk.Window.new();
    window.setChild(gtk.Label.new("ISOLATED T00 LOCK API TEST — no authentication").as(gtk.Widget));
    instance.assignWindowToMonitor(window, monitor);
    window.present();
    std.debug.print("T00 event=lock-monitor connector={s}\n", .{monitor.getConnector() orelse "unknown"});
}

fn onLocked(_: *session_lock.Instance, _: ?*anyopaque) callconv(.c) void {
    std.debug.print("T00 event=locked\n", .{});
}

fn onLockFailed(_: *session_lock.Instance, _: ?*anyopaque) callconv(.c) void {
    std.debug.print("T00 event=lock-failed\n", .{});
}

fn onUnlocked(_: *session_lock.Instance, _: ?*anyopaque) callconv(.c) void {
    std.debug.print("T00 event=unlocked\n", .{});
}

fn command(line: []const u8) void {
    if (std.mem.eql(u8, line, "popup")) {
        showPopup();
    } else if (std.mem.eql(u8, line, "close")) {
        closePopup("command");
    } else if (std.mem.eql(u8, line, "lock")) {
        if (lock_instance != null) return;
        const instance = session_lock.Instance.new();
        lock_instance = instance;
        _ = session_lock.Instance.signals.monitor.connect(instance, ?*anyopaque, onLockMonitor, null, .{});
        _ = session_lock.Instance.signals.locked.connect(instance, ?*anyopaque, onLocked, null, .{});
        _ = session_lock.Instance.signals.failed.connect(instance, ?*anyopaque, onLockFailed, null, .{});
        _ = session_lock.Instance.signals.unlocked.connect(instance, ?*anyopaque, onUnlocked, null, .{});
        _ = instance.lock();
    } else if (std.mem.eql(u8, line, "unlock")) {
        if (lock_instance) |instance| instance.unlock();
    } else if (std.mem.eql(u8, line, "quit")) {
        loop.quit();
    } else {
        std.debug.print("T00 event=invalid-command\n", .{});
    }
}

fn onInput(fd: c_int, condition: glib.IOCondition, _: ?*anyopaque) callconv(.c) c_int {
    if (condition.hup or condition.err) {
        loop.quit();
        return 0;
    }
    var buffer: [512]u8 = undefined;
    const size = read(fd, &buffer, buffer.len);
    if (size <= 0) {
        loop.quit();
        return 0;
    }
    for (buffer[0..@intCast(size)]) |byte| {
        if (byte == '\n') {
            command(command_buffer[0..command_length]);
            command_length = 0;
        } else if (command_length < command_buffer.len) {
            command_buffer[command_length] = byte;
            command_length += 1;
        } else {
            std.debug.print("T00 event=command-too-long\n", .{});
            loop.quit();
            return 0;
        }
    }
    return 1;
}

pub fn main() void {
    if (!std.mem.eql(u8, env("PEARL_T00_ISOLATED", ""), "1") or !std.mem.eql(u8, env("WLR_BACKENDS", ""), "headless")) {
        std.debug.print("Use scripts/t00.py: this probe is restricted to isolated headless test sessions.\n", .{});
        std.process.exit(2);
    }
    gtk.init();
    const instance = session_lock.Instance.new();
    defer instance.unref();
    std.debug.print("T00 layer_supported={d} protocol={d} layer_version={d}.{d}.{d} lock_supported={d} lock_monitor_api={d}\n", .{
        layer.isSupported(),                                                                        layer.getProtocolVersion(), layer.getMajorVersion(), layer.getMinorVersion(), layer.getMicroVersion(), session_lock.isSupported(),
        @intFromBool(gobject.signalLookup("monitor", session_lock.Instance.getGObjectType()) != 0),
    });
    const display = gdk.Display.getDefault().?;
    const css = gtk.CssProvider.new();
    defer css.unref();
    css.loadFromString(@embedFile("style.css"));
    gtk.StyleContext.addProviderForDisplay(display, css.as(gtk.StyleProvider), 600);
    loop = glib.MainLoop.new(null, 0);
    defer loop.unref();
    const input_source = glibunix.fdAdd(0, .{ .in = true, .hup = true, .err = true }, onInput, null);
    defer _ = glib.Source.remove(input_source);
    const model = display.getMonitors();
    count = @min(model.getNItems(), monitors.len);
    for (0..count) |i| {
        monitors[i] = @ptrCast(@alignCast(model.getItem(@intCast(i)).?));
        var rect: gdk.Rectangle = undefined;
        monitors[i].getGeometry(&rect);
        std.debug.print("T00 monitor={s} geometry={d},{d},{d},{d} scale={d}\n", .{
            monitors[i].getConnector() orelse "unknown", rect.f_x, rect.f_y, rect.f_width, rect.f_height, monitors[i].getScaleFactor(),
        });
    }
    defer for (monitors[0..count]) |monitor| monitor.unref();
    const plain = std.mem.eql(u8, env("PEARL_T00_MODE", "bars"), "plain");
    const window_count = if (plain) @as(usize, 1) else count;
    for (0..window_count) |i| {
        const window = gtk.Window.new();
        bars[i] = window;
        if (plain) {
            window.setTitle("Pearl T00 normal window");
            window.setDefaultSize(640, 360);
            const button = gtk.Button.newWithLabel("Underlying application · click-through probe");
            _ = gtk.Button.signals.clicked.connect(button, ?*anyopaque, underlyingClicked, null, .{});
            window.setChild(button.as(gtk.Widget));
        } else {
            window.as(gtk.Widget).addCssClass("pearl-t00-bar");
            window.setDefaultSize(0, 48);
            layer.initForWindow(window);
            layer.setNamespace(window, "pearl:t00-bar");
            layer.setMonitor(window, monitors[i]);
            layer.setLayer(window, .top);
            for ([_]layer.Edge{ .top, .left, .right }) |edge| layer.setAnchor(window, edge, 1);
            layer.setExclusiveZone(window, 48);
            layer.setKeyboardMode(window, .none);
            const row = gtk.Box.new(.horizontal, 12);
            const button = gtk.Button.newWithLabel("Pearl · Open popup");
            _ = gtk.Button.signals.clicked.connect(button, ?*anyopaque, openPopup, null, .{});
            row.append(button.as(gtk.Widget));
            row.append(gtk.Label.new("1   2   3     |     T00 GTK binding spike").as(gtk.Widget));
            window.setChild(row.as(gtk.Widget));
        }
        window.present();
    }
    std.debug.print("T00 event=ready mode={s}\n", .{if (plain) "plain" else "bars"});
    loop.run();
    closePopup("shutdown");
    if (lock_instance) |lock| {
        lock.unlock();
        lock.unref();
    }
    for (bars[0..window_count]) |window| window.destroy();
}

test "generated APIs share Ghostty GTK types and expose complete lock signals" {
    try std.testing.expect(@typeInfo(@TypeOf(layer.initForWindow)).@"fn".params[0].type.? == *gtk.Window);
    try std.testing.expect(@typeInfo(@TypeOf(session_lock.Instance.assignWindowToMonitor)).@"fn".params[1].type.? == *gtk.Window);
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(layer.Edge.top));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(layer.KeyboardMode.exclusive));
    std.testing.refAllDecls(layer);
    std.testing.refAllDecls(session_lock.Instance);
    std.testing.refAllDecls(session_lock.Instance.signals);
}
