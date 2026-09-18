//! Native author/administration tool. Never changes the active appearance.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        glib.print("Pearl themes " ++ @import("version.zig").string ++ " (Zig 0.16.0)\n");
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        glib.print("Usage: pearl-themes '{\"action\":\"catalog\"}'\nSee CUSTOM_THEMES.md for the versioned request and package formats.\n");
        return;
    }
    if (args.len != 2) {
        glib.printerr("Usage: pearl-themes '{\"action\":\"catalog\"}'\nActions: catalog, validate, validate_index, pack, preview, preview_render, source_add, source_remove, refresh, install, import_archive, remove, rollback\n");
        std.process.exit(2);
    }
    const request = @import("theme/package_model.zig").parse(@import("theme/commands.zig").Request, a, args[1], 16384) catch |err| {
        glib.printerr("%s\n", @errorName(err).ptr);
        std.process.exit(2);
    };
    if (request.action == .preview_render) {
        // The same worker/deadline as Settings bounds generator execution.
        const app = gio.Application.new("org.aqueous.Pearl.ThemeAuthor", .{ .non_unique = true });
        defer app.unref();
        var manager: @import("theme/jobs.zig").Manager = .{};
        defer manager.stop();
        try manager.start(app, args[1]);
        while (manager.job != null) _ = glib.MainContext.default().iteration(1);
        if (manager.error_code) |err| {
            glib.printerr("%s\n", @errorName(err).ptr);
            std.process.exit(1);
        }
        glib.print("%s\n", (try a.dupeZ(u8, manager.result orelse return error.ThemePreviewFailed)).ptr);
        return;
    }
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    const result = @import("theme/commands.zig").run(a, request, cancel, null) catch |err| {
        glib.printerr("%s\n", @errorName(err).ptr);
        std.process.exit(1);
    };
    glib.print("%s\n", (try a.dupeZ(u8, result)).ptr);
}
