const std = @import("std");
const u = @import("c.zig");
const c = u.c;
const build_options = @import("build_options");
const command = if (build_options.git_variant) "coral-git" else "coral";
const App = @import("app.zig").App;
const Settings = @import("platform/settings.zig").Settings;
var app: ?*App = null;
var settings: Settings = undefined;
var paths: std.ArrayList([:0]const u8) = .empty;
var width: c_int = 1000;
var height: c_int = 740;
fn activate(application: ?*c.GApplication, _: ?*anyopaque) callconv(.c) void {
    if (app) |p| {
        c.gtk_window_present(u.cast(c.GtkWindow, p.window));
        return;
    }
    app = App.create(u.cast(c.GtkApplication, application.?), settings, width, height);
    if (paths.items.len == 0) {
        _ = app.?.newDocument();
    } else for (paths.items) |path| app.?.openPath(path);
    if (app.?.docs.items.len == 0) _ = app.?.newDocument();
}
pub fn main(init: std.process.Init) void {
    settings = Settings.load();
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return;
    defer paths.deinit(u.a);
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            c.g_print("Coral 0.1.0 — Zig / GTK4 text editor\nUsage: " ++ command ++ " [--light|--dark|--native-theme] [--width=N] [--height=N] [FILE…]\nCtrl+N new, Ctrl+O open, Ctrl+S save, Ctrl+Shift+S Save As, Ctrl+F find,\nCtrl+H replace, Ctrl+G go to line, Ctrl+, preferences, Shift+F10 spelling.\n");
            return;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            c.g_print("Coral 0.1.0\n");
            return;
        }
        if (std.mem.eql(u8, arg, "--light")) settings.theme = 1 else if (std.mem.eql(u8, arg, "--dark")) settings.theme = 0 else if (std.mem.eql(u8, arg, "--native-theme")) settings.theme = 2 else if (std.mem.startsWith(u8, arg, "--width=")) width = std.math.clamp(std.fmt.parseInt(c_int, arg[8..], 10) catch 1000, 390, 3840) else if (std.mem.startsWith(u8, arg, "--height=")) height = std.math.clamp(std.fmt.parseInt(c_int, arg[9..], 10) catch 740, 400, 2160) else if (std.mem.startsWith(u8, arg, "--")) {
            c.g_printerr("Unknown option: %s\n", arg.ptr);
            std.process.exit(2);
        } else paths.append(u.a, arg) catch unreachable;
    }
    c.g_set_application_name(if (build_options.git_variant) "Coral Git" else "Coral");
    c.gtk_source_init();
    defer c.gtk_source_finalize();
    const executable = c.g_file_read_link("/proc/self/exe", null);
    if (executable != null) {
        defer c.g_free(executable);
        const styles = u.fmt("{s}/../share/" ++ command ++ "/styles", .{std.fs.path.dirname(std.mem.span(executable)) orelse "."});
        defer u.a.free(styles);
        const directory = if (c.g_file_test(styles, c.G_FILE_TEST_IS_DIR) != 0) styles else build_options.development_styles;
        const directory_z = u.z(directory);
        defer u.a.free(directory_z);
        c.gtk_source_style_scheme_manager_append_search_path(c.gtk_source_style_scheme_manager_get_default(), directory_z);
    }
    const application = c.gtk_application_new(if (build_options.git_variant) "org.aqueous.Coral.Git" else "org.aqueous.Coral", c.G_APPLICATION_NON_UNIQUE).?;
    defer c.g_object_unref(application);
    u.connect(application, "activate", &activate, null);
    var argv = [_][*:0]u8{@constCast(command)};
    const result = c.g_application_run(u.cast(c.GApplication, application), 1, @ptrCast(&argv));
    if (app) |p| p.deinit();
    if (result != 0) std.process.exit(@intCast(result));
}
