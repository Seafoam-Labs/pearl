//! Native file operations for editable palettes and legacy-compatible export.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const io = @import("../config/io.zig");
const model = @import("palette_model.zig");
const compiler = @import("palette_resolver.zig");
pub const starter = "{\n  \"name\": \"Meadow\",\n  \"dark\": {\n    \"surface\": \"#101c19\",\n    \"on_surface\": \"#e8f4e9\",\n    \"primary\": \"#a4dfb0\"\n  }\n}\n";
pub const File = struct {
    id: []const u8,
    name: []const u8,
    document: compiler.Document,
};
pub fn root(a: std.mem.Allocator) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, "{s}/pearl/palettes", .{std.mem.span(glib.getUserConfigDir())}, 0);
}
pub fn filename(a: std.mem.Allocator, name: []const u8) ![:0]const u8 {
    try @import("package_model.zig").identifier(name);
    if (name.len > 80 or std.mem.startsWith(u8, name, ".")) return error.InvalidPaletteName;
    return std.fmt.allocPrintSentinel(a, "{s}/{s}.json", .{ try root(a), name }, 0);
}
pub fn selected(p: @import("../config/preferences.zig").Theme) []const u8 {
    return if (p.mode == .package) (if (p.palette_id.len > 0) p.palette_id else p.package_id) else "";
}
pub fn editable(id: []const u8) bool {
    return std.mem.startsWith(u8, id, "local.palette.");
}
pub fn load(a: std.mem.Allocator, path: [:0]const u8, cancel: ?*gio.Cancellable, diagnostic: *model.Diagnostic) !File {
    const basename = std.fs.path.basename(path);
    if (!std.mem.endsWith(u8, basename, ".json")) return error.InvalidPaletteName;
    const slug = basename[0 .. basename.len - 5];
    _ = try filename(a, slug);
    var result = try inspect(a, path, cancel, diagnostic);
    result.id = try std.fmt.allocPrint(a, "local.palette.{s}", .{slug});
    return result;
}
// Imported files need not follow Pearl's local filename convention.
pub fn inspect(a: std.mem.Allocator, path: [:0]const u8, cancel: ?*gio.Cancellable, diagnostic: *model.Diagnostic) !File {
    const file = try io.read(a, path, model.max_bytes, cancel);
    if (file.missing) return error.PaletteFileMissing;
    const document = try compiler.compile(a, file.bytes, diagnostic);
    const basename = std.fs.path.basename(path);
    const name = if (std.mem.endsWith(u8, basename, ".json")) basename[0 .. basename.len - 5] else basename;
    return .{ .id = "", .name = if (document.source.name.len > 0) document.source.name else try a.dupe(u8, name), .document = document };
}
pub fn write(a: std.mem.Allocator, name: []const u8, bytes: []const u8, expected: []const u8, cancel: *gio.Cancellable, diagnostic: *model.Diagnostic) !File {
    const path = try filename(a, name);
    _ = try compiler.compile(a, bytes, diagnostic);
    const old = try io.read(a, path, model.max_bytes, cancel);
    if (expected.len == 0) {
        if (!old.missing) return error.PaletteAlreadyExists;
    } else if (old.missing or !std.mem.eql(u8, expected, &old.hash)) return error.Conflict;
    try io.mkdir(try root(a));
    try io.replace(path, bytes, old, cancel);
    return load(a, path, cancel, diagnostic);
}
pub fn exportPackage(a: std.mem.Allocator, file: File, output: [:0]const u8, publication: model.Publication) !@import("package.zig").Package {
    try publication.validate();
    const c = @import("package.zig").c;
    if (output.len == 0) return error.ThemeArchiveOutputRequired;
    if (c.mkdir(output, 0o700) != 0) return error.PublicationOutputExists;
    errdefer @import("install.zig").removeTree(a, output) catch {};
    const manifest: @import("package_model.zig").Manifest = .{
        .schema_version = 2,
        .id = publication.id,
        .name = file.name,
        .author = publication.author,
        .license = publication.license,
        .source = publication.source,
        .asset_version = publication.version,
        .requires = .{ .palette_api = 1, .render_data_api = 1 },
        .palettes = .{ .dark = "dark.json", .light = "light.json" },
        .render_data = .{ .dark = "render-data.json", .light = "render-data.json" },
    };
    const attribution = try std.fmt.allocPrint(a, "{s}\n\nCompiled by Pearl palette compiler {d}. Semantic colors are authored or\nderived; transport tone ramps are inherited from Pearl Material defaults.\n", .{ publication.attribution, model.compiler_version });
    const names = [_][]const u8{ "theme.json", "dark.json", "light.json", "render-data.json", "LICENSE", "ATTRIBUTION.md", "palette-source.json", "palette-hover.json" };
    const contents = [_][]const u8{
        try std.json.Stringify.valueAlloc(a, manifest, .{ .whitespace = .indent_2 }),
        try std.json.Stringify.valueAlloc(a, file.document.dark, .{ .whitespace = .indent_2 }),
        try std.json.Stringify.valueAlloc(a, file.document.light, .{ .whitespace = .indent_2 }),
        file.document.render_json,
        publication.license_text,
        attribution,
        try std.json.Stringify.valueAlloc(a, file.document.source, .{ .whitespace = .indent_2 }),
        try std.json.Stringify.valueAlloc(a, .{ .dark = file.document.dark_hover, .light = file.document.light_hover }, .{}),
    };
    for (names, contents) |name, bytes| try io.atomic(try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ output, name }, 0), bytes, true);
    return @import("package.zig").load(a, output);
}
