//! Shared backend/author-tool operations. Call only from a worker.
const std = @import("std");
const gio = @import("gio2");
const model = @import("package_model.zig");
const repository = @import("repository.zig");
const install = @import("install.zig");
const io = @import("../config/io.zig");
extern fn mkdtemp([*:0]u8) ?[*:0]u8;
pub const Request = struct {
    action: enum { catalog, validate, validate_index, pack, preview, preview_render, source_add, source_remove, refresh, install, import_archive, remove, rollback },
    id: []const u8 = "",
    name: []const u8 = "",
    url: []const u8 = "",
    path: []const u8 = "",
    output: []const u8 = "",
    repository: []const u8 = "",
    version: []const u8 = "",
    sha256: []const u8 = "",
    offset: u16 = 0,
    revision: []const u8 = "",
    theme: ?@import("../config/preferences.zig").Theme = null,
    wallpaper: @import("../config/preferences.zig").Wallpaper = .{},
};
pub const Entry = struct {
    id: []const u8,
    name: []const u8,
    author: []const u8,
    version: []const u8,
    digest: []const u8,
    dark: bool,
    light: bool,
    style: bool,
    error_code: ?[]const u8 = null,
};
pub fn run(a: std.mem.Allocator, request: Request, cancel: *gio.Cancellable, report: ?*@import("progress.zig").Progress) ![]const u8 {
    if (cancel.isCancelled() != 0) return error.Cancelled;
    switch (request.action) {
        .validate => {
            const package = try @import("package.zig").load(a, try a.dupeZ(u8, request.path));
            return std.json.Stringify.valueAlloc(a, package.manifest, .{});
        },
        .validate_index => {
            const file = try io.read(a, try a.dupeZ(u8, request.path), 1048576, cancel);
            if (file.missing) return error.ThemeIndexMissing;
            try model.identifier(request.id);
            return std.json.Stringify.valueAlloc(a, try repository.parseIndex(a, file.bytes, .{ .id = request.id, .name = request.id, .url = request.url }), .{});
        },
        .pack => {
            if (request.output.len == 0) return error.ThemeArchiveOutputRequired;
            const package = try @import("package.zig").load(a, try a.dupeZ(u8, request.path));
            const bytes = try @import("archive_writer.zig").pack(a, package);
            if (cancel.isCancelled() != 0) return error.Cancelled;
            try io.atomic(try a.dupeZ(u8, request.output), bytes, true);
            return std.json.Stringify.valueAlloc(a, .{ .manifest = package.manifest, .sha256 = model.hash(bytes)[0..], .size = bytes.len }, .{});
        },
        .catalog => {
            const catalog = try @import("catalog.zig").scan(a);
            if (request.revision.len > 0 and !std.mem.eql(u8, request.revision, &catalog.revision)) return error.ThemeCatalogChanged;
            if (request.offset > catalog.entries.len) return error.InvalidCatalogOffset;
            var entries: std.ArrayList(Entry) = .empty;
            var ids: std.ArrayList([]const u8) = .empty;
            for (catalog.entries) |entry| try ids.append(a, entry.package.manifest.id);
            const end = @min(catalog.entries.len, @as(usize, request.offset) + 16);
            for (catalog.entries[request.offset..end]) |entry| {
                const p = entry.package;
                var failure: ?[]const u8 = null;
                _ = catalog.get(p.manifest.id) catch |err| blk: {
                    failure = @errorName(err);
                    break :blk entry;
                };
                try entries.append(a, .{ .id = p.manifest.id, .name = p.manifest.name, .author = p.manifest.author, .version = p.manifest.asset_version, .digest = try a.dupe(u8, &p.digest), .dark = p.dark != null, .light = p.light != null, .style = p.manifest.style != null, .error_code = failure });
            }
            return std.json.Stringify.valueAlloc(a, .{ .entries = entries.items, .ids = ids.items, .next_offset = if (end < catalog.entries.len) @as(?usize, end) else null, .diagnostics = catalog.diagnostics[0..@min(8, catalog.diagnostics.len)], .diagnostic_count = catalog.diagnostics.len, .revision = catalog.revision[0..], .sources = (try repository.sources(a)).sources }, .{});
        },
        .preview, .preview_render => {
            const theme = request.theme orelse return error.ThemeSelectionRequired;
            const preferences: @import("../config/preferences.zig").Preferences = .{ .theme = theme, .wallpaper = request.wallpaper };
            try preferences.validate();
            var resolved = try @import("resolve.zig").resolve(a, theme, try @import("catalog.zig").scan(a), true);
            if (request.action == .preview_render and resolved.palette == null) {
                if (theme.mode == .gtk) return error.NativeGtkPreviewUnsupported;
                if (theme.mode == .dynamic) {
                    if (report) |p| p.set(.generating);
                    const glib = @import("glib2");
                    const root = try std.fmt.allocPrintSentinel(a, "{s}/pearl/theme-previews", .{std.mem.span(glib.getUserCacheDir())}, 0);
                    try io.mkdir(root);
                    const temporary = try std.fmt.allocPrintSentinel(a, "{s}/preview-XXXXXX", .{root}, 0);
                    if (mkdtemp(temporary) == null) return error.ThemeStagingFailed;
                    defer install.removeTree(a, temporary) catch {};
                    var image: ?[]const u8 = null;
                    if (theme.source == .wallpaper) {
                        const file = try io.read(a, try a.dupeZ(u8, request.wallpaper.path), 64 * 1024 * 1024, cancel);
                        if (file.missing or (!std.mem.startsWith(u8, file.bytes, "\x89PNG\r\n\x1a\n") and !std.mem.startsWith(u8, file.bytes, "\xff\xd8\xff"))) return error.InvalidImage;
                        image = file.bytes;
                    }
                    var hit = false;
                    resolved.palette = try @import("generator.zig").palette(a, preferences, image, temporary, cancel, &hit);
                } else resolved.palette = if (theme.variant == .dark) @import("theme.zig").dark else @import("theme.zig").light;
            }
            return std.json.Stringify.valueAlloc(a, resolved, .{});
        },
        else => {},
    }
    var store = try install.Store.init(a);
    defer store.deinit();
    switch (request.action) {
        .source_add, .source_remove => {
            try model.identifier(request.id);
            const old = try repository.sources(a);
            var next: std.ArrayList(repository.Source) = .empty;
            for (old.sources) |s| if (!std.mem.eql(u8, s.id, request.id)) {
                try next.append(a, s);
            };
            if (request.action == .source_add) {
                // Changing a source's URL is explicit and does not transfer receipts.
                try next.append(a, .{ .id = request.id, .name = request.name, .url = request.url });
            }
            const value: repository.Sources = .{ .sources = next.items };
            try repository.saveSources(a, value);
            return std.json.Stringify.valueAlloc(a, value, .{});
        },
        .refresh, .install => {
            const sources = try repository.sources(a);
            var selected: ?repository.Source = null;
            const key = if (request.action == .refresh) request.id else request.repository;
            for (sources.sources) |s| if (std.mem.eql(u8, s.id, key)) {
                selected = s;
            };
            const source = selected orelse return error.UnknownThemeRepository;
            const url = if (request.url.len == 0) source.url else request.url;
            if (request.action == .refresh) {
                if (report) |p| p.set(.fetching_index);
                return std.json.Stringify.valueAlloc(a, try repository.refresh(a, source, url, cancel, report), .{});
            }
            const cached = try io.read(a, try repository.cachePath(a, source, url), 1048576, cancel);
            if (cached.missing) return error.RefreshRepositoryFirst;
            const index = try repository.parseIndex(a, cached.bytes, source);
            var found: ?repository.Release = null;
            for (index.releases) |r| if (std.mem.eql(u8, r.id, request.id) and std.mem.eql(u8, r.version, request.version) and std.mem.eql(u8, r.sha256, request.sha256)) {
                found = r;
            };
            const release = found orelse return error.ThemeReleaseChanged;
            if ((release.requires.palette_api != null and release.requires.palette_api != 1) or (release.requires.style_api != null and release.requires.style_api != 1)) return error.UnsupportedThemeApi;
            if (report) |p| p.set(.downloading);
            const bytes = try repository.download(a, release.url, model.max_bytes, cancel, report);
            if (bytes.len != release.size or !std.mem.eql(u8, &model.hash(bytes), release.sha256)) return error.ThemeDownloadDigestMismatch;
            if (report) |p| p.set(.validating);
            const package = try store.unpack(bytes, cancel);
            const m = package.manifest;
            inline for (.{ .{ "id", "id" }, .{ "name", "name" }, .{ "author", "author" }, .{ "license", "license" }, .{ "source", "source" }, .{ "version", "asset_version" } }) |pair| {
                if (!std.mem.eql(u8, @field(release, pair[0]), @field(m, pair[1]))) return error.ThemeReleaseManifestMismatch;
            }
            if (!std.meta.eql(m.requires, release.requires) or release.style != (m.style != null)) return error.ThemeReleaseManifestMismatch;
            var dark = false;
            var light = false;
            for (release.variants) |v| {
                if (std.mem.eql(u8, v, "dark")) dark = true else light = true;
            }
            if (dark != (package.dark != null) or light != (package.light != null)) return error.ThemeReleaseManifestMismatch;
            if (cancel.isCancelled() != 0) return error.Cancelled;
            if (report) |p| p.set(.installing);
            return std.json.Stringify.valueAlloc(a, try store.publish(package, try std.fmt.allocPrint(a, "{s}:{s}", .{ source.id, source.url })), .{});
        },
        .import_archive => {
            const file = try io.read(a, try a.dupeZ(u8, request.path), model.max_bytes, cancel);
            if (file.missing) return error.ThemeArchiveMissing;
            const package = try store.unpack(file.bytes, cancel);
            if (cancel.isCancelled() != 0) return error.Cancelled;
            return std.json.Stringify.valueAlloc(a, try store.publish(package, "local"), .{});
        },
        .remove => {
            try model.identifier(request.id);
            try store.remove(request.id);
            return "{}";
        },
        .rollback => {
            try model.identifier(request.id);
            return std.json.Stringify.valueAlloc(a, try store.rollback(request.id), .{});
        },
        else => return error.UnsupportedThemeOperation,
    }
}
