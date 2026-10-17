comptime {
    _ = @import("previews").api;
    _ = @import("file_chooser");
}
const std = @import("std");
const u = @import("ui.zig");
const gtk = u.gtk;
const gio = u.gio;
const glib = u.glib;
const gdk = @import("gdk4");
const Window = @import("window.zig").Window;
const Options = @import("window.zig").Options;
const logging = @import("logging");
const diagnostics = @import("diagnostics");
const log = std.log.scoped(.cli);

pub const std_options = logging.std_options;

var windows: std.ArrayList(*Window) = .empty;
var initial: ?*gio.File = null;
var options: Options = .{};

pub fn newWindow(app: *gtk.Application, file: *gio.File, opts: Options) void {
    const network = @import("platform/network_mounts.zig");
    if (network.shared == null) {
        _ = network.Manager.init(app);
        network.changed = networkChanged;
    }
    windows.append(u.a, Window.create(app, file, opts)) catch @panic("Out of memory");
    network.shared.?.startup();
}
pub fn networkChanged() void {
    for (windows.items) |window| {
        if (window.closed) continue;
        window.refreshPlaces();
        for (window.panes) |pane| for (pane.tabs.items) |tab| tab.refreshNetwork();
    }
}
pub fn networkWindowClosing(owner: *Window) void {
    var last = true;
    for (windows.items) |window| if (window != owner and !window.closed) {
        last = false;
    };
    if (@import("platform/network_mounts.zig").shared) |network| network.closeWindow(owner, last);
}
pub fn previewPreferencesChanged() void {
    for (windows.items) |window| {
        if (window.closed) continue;
        inline for (.{ "thumbnails", "preview_details" }) |name| {
            const action: *gio.SimpleAction = @ptrCast(u.object.ext.cast(gtk.ApplicationWindow, window.window).?.as(gio.ActionMap).lookupAction(name).?);
            action.setState(glib.Variant.newBoolean(@intFromBool(@field(window.preferences, name))));
        }
        window.queueUpdate();
    }
    @import("preview.zig").schedule();
}
fn activate(app: *gio.Application, _: ?*anyopaque) callconv(.c) void {
    newWindow(@ptrCast(app), initial.?, options);
}
pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return;
    if (args.len > 1 and std.mem.eql(u8, args[1], "--preview-helper")) {
        @import("previews").helper.run(args[2..]);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--preview-capabilities")) {
        @import("previews").providers.emit();
        return;
    }
    var location: ?[:0]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        switch (logging.verbosity(args[index..])) {
            .other => {},
            .applied => {
                index += 1;
                continue;
            },
            .rejected => |rejection| {
                logging.report(rejection, diagnostics.safe(rejection.value));
                std.process.exit(2);
            },
        }
        if (std.mem.eql(u8, arg, "--help")) {
            glib.print("Phyto — native Pearl file explorer\nUsage: phyto [--follow-pearl|--light|--dark|--native-theme] [--compact] [--width=N] [--height=N]\n             [--log-level LEVEL] [--log-scopes LIST] [PATH_OR_URI]\n\nCtrl+L location, Ctrl+F filter, Ctrl+T new tab, F3 split panes, F6 switch pane.\nFollow Pearl is the first-run default; without Pearl it uses Phyto's own dark palette.\n--log-level: error, warning, info or debug. Release builds default to info.\n--log-scopes: comma-separated scopes, all for every scope, ~scope to exclude.\n");
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            glib.print("Phyto 0.1.1 (Zig 0.16.0 / GTK4)\n");
            return;
        } else if (std.mem.eql(u8, arg, "--follow-pearl")) options.theme = .follow_pearl else if (std.mem.eql(u8, arg, "--light")) options.theme = .light else if (std.mem.eql(u8, arg, "--dark")) options.theme = .dark else if (std.mem.eql(u8, arg, "--compact")) options.compact = true else if (std.mem.eql(u8, arg, "--native-theme")) options.theme = .native_gtk else if (std.mem.startsWith(u8, arg, "--width=")) {
            options.width = std.fmt.parseInt(c_int, arg[8..], 10) catch 1180;
            options.width = std.math.clamp(options.width, 390, 3840);
        } else if (std.mem.startsWith(u8, arg, "--height=")) {
            options.height = std.fmt.parseInt(c_int, arg[9..], 10) catch 760;
            options.height = std.math.clamp(options.height, 400, 2160);
        } else if (std.mem.startsWith(u8, arg, "--") or location != null) {
            log.err("Unknown option or extra location: {f}", .{diagnostics.safe(arg)});
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
    @import("previews").scheduler.init(app.as(gio.Application));
    @import("previews").scheduler.changed = @import("preview.zig").schedule;
    const code = app.as(gio.Application).run(1, &argv);
    for (windows.items) |window| window.destroy();
    @import("appearance.zig").current().deinit();
    if (prefs) |preferences| preferences.release();
    if (@import("platform/network_mounts.zig").shared) |network| network.deinit();
    windows.deinit(u.a);
    @import("preview.zig").shutdown();
    @import("previews").scheduler.deinit();
    if (provider) |css| {
        if (gdk.Display.getDefault()) |display| gtk.StyleContext.removeProviderForDisplay(display, css.as(gtk.StyleProvider));
        css.unref();
    }
    if (code != 0) std.process.exit(@intCast(code));
}
var provider: ?*gtk.CssProvider = null;
var prefs: ?*@import("platform/preferences.zig").Preferences = null;
var theme_action: ?*gio.SimpleAction = null;
var appearance_context: u8 = 0;
fn startup(app: *gio.Application, _: ?*anyopaque) callconv(.c) void {
    const css = gtk.CssProvider.new();
    provider = css;
    const source = @embedFile("style");
    css.loadFromString(source);
    gtk.StyleContext.addProviderForDisplay(gdk.Display.getDefault().?, css.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
    prefs = @import("platform/preferences.zig").Preferences.acquire();
    const appearance = @import("appearance.zig");
    appearance.init(@ptrCast(&appearance_context), appearanceChanged);
    appearance.current().setMode(prefs.?.theme);
    const action = gio.SimpleAction.newStateful("theme", glib.VariantType.new("s"), glib.Variant.newString(@tagName(prefs.?.theme)));
    theme_action = action;
    _ = gio.SimpleAction.signals.activate.connect(action, ?*anyopaque, themeActivated, null, .{});
    app.as(gio.ActionMap).addAction(action.as(gio.Action));
}
fn themeActivated(_: *gio.SimpleAction, parameter: ?*glib.Variant, _: ?*anyopaque) callconv(.c) void {
    const value = parameter orelse return;
    const mode = std.meta.stringToEnum(@import("platform/preferences.zig").Theme, std.mem.span(value.getString(null))) orelse return;
    const preferences = prefs orelse return;
    if (preferences.theme == mode) return;
    preferences.theme = mode;
    preferences.save();
    @import("appearance.zig").current().setMode(mode);
    syncThemeAction();
}
pub fn syncThemeAction() void {
    if (theme_action) |action| if (prefs) |preferences| action.setState(glib.Variant.newString(@tagName(preferences.theme)));
}
fn appearanceChanged(_: *anyopaque) void {
    for (windows.items) |window| {
        if (window.closed) continue;
        window.applyTheme();
    }
}
