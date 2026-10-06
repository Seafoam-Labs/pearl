const std = @import("std");
const gio = @import("gio2");
const file = @import("palette_file.zig");
const io = @import("../config/io.zig");
const model = @import("palette_model.zig");
const compiler = @import("palette_resolver.zig");
fn failure(a: std.mem.Allocator, err: anyerror, diagnostic: model.Diagnostic) ![]const u8 {
    var d = diagnostic;
    if (std.mem.eql(u8, d.code, "InvalidPalette")) d.code = @errorName(err);
    return std.json.Stringify.valueAlloc(a, .{ .valid = false, .diagnostic = d }, .{});
}
pub fn run(a: std.mem.Allocator, request: @import("commands.zig").Request, cancel: *gio.Cancellable) ![]const u8 {
    var diagnostic: model.Diagnostic = .{};
    if (request.action == .palette_preview) {
        const document = compiler.compile(a, request.contents, &diagnostic) catch |err| return failure(a, err, diagnostic);
        const light = request.theme != null and request.theme.?.variant == .light;
        const resolved: @import("resolve.zig").Resolved = .{ .palette = if (light) document.light else document.dark, .palette_css = try compiler.shellCss(a, document, light), .digest = &document.digest };
        return std.json.Stringify.valueAlloc(a, .{ .valid = true, .resolved = resolved, .source = document.source }, .{});
    }
    const path = if (request.path.len > 0) try a.dupeZ(u8, request.path) else try file.filename(a, request.name);
    var loaded: file.File = undefined;
    switch (request.action) {
        .palette_init => loaded = file.write(a, request.name, if (request.contents.len > 0) request.contents else file.starter, "", cancel, &diagnostic) catch |err| return failure(a, err, diagnostic),
        .palette_write => loaded = file.write(a, request.name, request.contents, request.expected, cancel, &diagnostic) catch |err| return failure(a, err, diagnostic),
        .palette_import => {
            const input = io.read(a, path, model.max_bytes, cancel) catch |err| return failure(a, err, diagnostic);
            if (input.missing) return failure(a, error.PaletteFileMissing, diagnostic);
            const imported = compiler.compile(a, input.bytes, &diagnostic) catch |err| return failure(a, err, diagnostic);
            const bytes = try std.json.Stringify.valueAlloc(a, imported.source, .{ .whitespace = .indent_2 });
            loaded = file.write(a, request.name, bytes, "", cancel, &diagnostic) catch |err| return failure(a, err, diagnostic);
        },
        .palette_read => loaded = file.load(a, path, cancel, &diagnostic) catch |err| return failure(a, err, diagnostic),
        else => loaded = file.inspect(a, path, cancel, &diagnostic) catch |err| return failure(a, err, diagnostic),
    }
    if (request.action == .palette_export) {
        const publication = request.publication orelse if (request.metadata_path.len > 0) blk: {
            const metadata = try io.read(a, try a.dupeZ(u8, request.metadata_path), 65536, cancel);
            if (metadata.missing) return error.PublicationMetadataRequired;
            break :blk try @import("package_model.zig").parse(model.Publication, a, metadata.bytes, 65536);
        } else loaded.document.source.publication orelse return error.PublicationMetadataRequired;
        const exported = try file.exportPackage(a, loaded, try a.dupeZ(u8, request.output), publication);
        return std.json.Stringify.valueAlloc(a, .{ .valid = true, .path = request.output, .manifest = exported.manifest, .digest = exported.digest[0..] }, .{});
    }
    const final_path = if (request.action == .palette_init or request.action == .palette_import or request.action == .palette_write) try file.filename(a, request.name) else path;
    const saved = try io.read(a, final_path, model.max_bytes, cancel);
    return std.json.Stringify.valueAlloc(a, .{ .valid = true, .id = loaded.id, .path = final_path, .expected = saved.hash[0..], .source = loaded.document.source, .dark = loaded.document.dark, .light = loaded.document.light, .inherited_tone_ramps = true }, .{});
}
