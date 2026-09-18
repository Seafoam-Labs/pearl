const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const glib = @import("glib2");
const gio = @import("gio2");
const options = @import("build_options");
const startup = @import("core/startup.zig");
const application = @import("core/application.zig");
const log = std.log.scoped(.pearl);

fn env(name: [*:0]const u8) []const u8 {
    return if (glib.getenv(name)) |value| std.mem.span(value) else "";
}

fn testNumber(name: [*:0]const u8, default: u32, limit: u32) u32 {
    if (!options.test_hooks) return default;
    return @min(std.fmt.parseInt(u32, env(name), 10) catch default, limit);
}

fn endpointExists() bool {
    const file = gio.File.newForPath(glib.getenv("AQUEOUS_SOCKET").?);
    defer file.unref();
    var err: ?*glib.Error = null;
    const info = file.queryInfo("unix::mode", .{ .nofollow_symlinks = true }, null, &err) orelse {
        if (err) |owned| owned.free();
        return false;
    };
    defer info.unref();
    return info.getAttributeUint32("unix::mode") & 0xf000 == 0xc000; // Linux S_IFSOCK
}

pub fn main(init: std.process.Init) void {
    const bootstrap = @import("platform/wayland/activity_bootstrap.zig");
    bootstrap.capture(init) catch std.process.exit(1);
    defer bootstrap.close();
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        log.err("Unable to read arguments.", .{});
        std.process.exit(2);
    };
    const parsed = startup.Options.parse(args[1..]) catch |err| {
        log.err("{s}", .{startup.diagnostic(err)});
        std.process.exit(2);
    };
    if (parsed.mode == .demo or !options.wasm_plugins) bootstrap.close();
    switch (parsed.action) {
        .help => {
            glib.print("Usage: pearl [--demo] [--help] [--version] [--check-environment]\n\nDefault: Aqueous session application.\n--demo: standalone gallery with sample content (Wayland required).\n");
            return;
        },
        .version => {
            glib.print("Pearl " ++ @import("version.zig").string ++ " (Zig 0.16.0)\n");
            return;
        },
        .run, .check_environment => {},
    }
    startup.validate(parsed.mode, .{ .desktop = env("XDG_CURRENT_DESKTOP"), .runtime = env("XDG_RUNTIME_DIR"), .display = env("WAYLAND_DISPLAY"), .endpoint = env("AQUEOUS_SOCKET") }) catch |err| {
        log.err("{s}", .{startup.diagnostic(err)});
        std.process.exit(2);
    };
    if (parsed.mode == .session and !endpointExists()) {
        log.err("AQUEOUS_SOCKET is missing or is not a Unix socket. Relaunch Pearl from the current Aqueous session, or use --demo.", .{});
        std.process.exit(2);
    }
    if (parsed.action == .check_environment) {
        if (parsed.mode != .session) std.process.exit(2);
        glib.print("Aqueous session environment is valid.\n");
        return;
    }
    gdk.setAllowedBackends("wayland");
    if (gtk.initCheck() == 0) {
        log.err("Cannot connect to the selected Wayland display. Use scripts/dev-session.py for an isolated session.", .{});
        std.process.exit(2);
    }
    gtk.IconTheme.getForDisplay(gdk.Display.getDefault().?).addResourcePath("/org/aqueous/Pearl/icons");
    const hooks: application.TestHooks = .{
        .worker_delay_ms = testNumber("PEARL_TEST_WORKER_DELAY_MS", 0, 5000),
        .close_after_ms = testNumber("PEARL_TEST_CLOSE_MS", 0, 10000),
    };
    const cycles = @max(1, testNumber("PEARL_TEST_CYCLES", 1, 50));
    for (0..cycles) |_| {
        const status = application.run(parsed.mode, hooks) catch |err| {
            log.err("event=startup-failed error={s}", .{@errorName(err)});
            std.process.exit(1);
        };
        if (status != 0) std.process.exit(status);
        if (options.test_hooks) {
            var err: ?*glib.Error = null;
            const stale = gio.resourcesLookupData("/org/aqueous/Pearl/gallery.ui", .{}, &err);
            std.debug.assert(stale == null);
            if (err) |owned| owned.free();
        }
    }
    log.info("event=stopped", .{});
}
