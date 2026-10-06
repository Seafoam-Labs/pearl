//! Native author/administration tool. Saving an active local palette updates it live.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");

pub const std_options = @import("core/logging.zig").std_options;

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
        glib.print("Usage: pearl-themes init NAME\n       pearl-themes validate FILE_OR_PACKAGE\n       pearl-themes preview FILE [--watch] [--light]\n       pearl-themes import FILE --name NAME\n       pearl-themes export FILE --output DIRECTORY [--metadata FILE]\n       pearl-themes '{\"action\":\"catalog\"}'\nSee THEME_CREATION_TUTORIAL.md for palette creation and publication.\n");
        return;
    }
    if (args.len > 1 and args[1].len > 0 and args[1][0] != '{') {
        author(a, args[1..]) catch |err| {
            glib.printerr("%s\n", @errorName(err).ptr);
            std.process.exit(1);
        };
        return;
    }
    if (args.len != 2) {
        glib.printerr("Usage: pearl-themes '{\"action\":\"catalog\"}'\nActions: catalog, profiles_catalog, validate, verify_profiles, validate_index, pack, publish_build, preview, preview_render, source_add, source_remove, source_default, refresh, install, import_archive, remove, rollback, application_review, application_install, application_retry\n");
        std.process.exit(2);
    }
    const request = @import("theme/package_model.zig").parse(@import("theme/commands.zig").Request, a, args[1], @import("theme/commands.zig").request_limit) catch |err| {
        glib.printerr("%s\n", @errorName(err).ptr);
        std.process.exit(2);
    };
    if (request.action == .preview_render or request.action == .verify_profiles or request.action == .application_review or request.action == .application_install or request.action == .application_retry or request.action == .application_refresh) {
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

fn author(a: std.mem.Allocator, args: []const [:0]const u8) !void {
    const cmd = @import("theme/commands.zig");
    if (args.len < 2) return error.AuthorArgumentRequired;
    var request: cmd.Request = .{ .action = .palette_validate, .path = args[1] };
    var watch = false;
    var light = false;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const option = args[i];
        if (std.mem.eql(u8, option, "--watch")) watch = true else if (std.mem.eql(u8, option, "--light")) light = true else {
            i += 1;
            if (i >= args.len) return error.AuthorArgumentRequired;
            if (std.mem.eql(u8, option, "--name")) request.name = args[i] else if (std.mem.eql(u8, option, "--output")) request.output = args[i] else if (std.mem.eql(u8, option, "--metadata")) {
                const metadata = try @import("config/io.zig").read(a, args[i], 65536, null);
                if (metadata.missing) return error.PublicationMetadataRequired;
                request.publication = try @import("theme/package_model.zig").parse(@import("theme/palette_model.zig").Publication, a, metadata.bytes, 65536);
            } else return error.UnknownAuthorOption;
        }
    }
    if (std.mem.eql(u8, args[0], "init")) {
        request.action = .palette_init;
        request.name = args[1];
        request.path = "";
    } else if (std.mem.eql(u8, args[0], "validate")) {
        request.action = if (std.mem.endsWith(u8, args[1], ".json")) .palette_validate else .validate;
    } else if (std.mem.eql(u8, args[0], "import")) {
        request.action = .palette_import;
        if (request.name.len == 0) return error.PaletteNameRequired;
    } else if (std.mem.eql(u8, args[0], "export")) {
        request.action = .palette_export;
        if (request.output.len == 0) return error.ThemeArchiveOutputRequired;
    } else if (std.mem.eql(u8, args[0], "preview")) {
        return @import("theme/palette_preview.zig").run(args[1], watch, light);
    } else return error.UnknownAuthorCommand;
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    const result = try cmd.run(a, request, cancel, null);
    glib.print("%s\n", (try a.dupeZ(u8, result)).ptr);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, result, .{});
    if (value.object.get("valid")) |valid| if (valid == .bool and !valid.bool) std.process.exit(1);
}
