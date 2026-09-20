//! Immutable application-profile inputs. Installed catalogs supply choices;
//! committed snapshots supply rendering and retry, including after removal.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const model = @import("package_model.zig");
const profiles = @import("matugen_profiles.zig");
const pkg = @import("package.zig");
const io = @import("../config/io.zig");
pub const Entry = struct { descriptor: profiles.Descriptor, path: [:0]const u8, origin: []const u8, digest: []const u8 };
pub const Catalog = struct {
    entries: []const Entry,
    diagnostics: []const @import("catalog.zig").Diagnostic = &.{},
    revision: [64]u8,
    pub fn get(self: Catalog, id: []const u8) !Entry {
        var found: ?Entry = null;
        for (self.entries) |entry| if (std.mem.eql(u8, entry.descriptor.id, id)) {
            if (found != null) return error.DuplicateThemeProfile;
            found = entry;
        };
        return found orelse error.ProfileUnavailable;
    }
};
pub fn roots(a: std.mem.Allocator) ![]const [:0]const u8 {
    const theme_roots = try @import("catalog.zig").roots(a);
    const paths = try a.alloc([:0]const u8, theme_roots.len);
    for (theme_roots, paths) |root, *path| path.* = try std.fmt.allocPrintSentinel(a, "{s}/matugen/profiles", .{std.fs.path.dirname(root).?}, 0);
    return paths;
}
pub fn catalog(a: std.mem.Allocator, themes: @import("catalog.zig").Catalog) !Catalog {
    var entries: std.ArrayList(Entry) = .empty;
    var diagnostics: std.ArrayList(@import("catalog.zig").Diagnostic) = .empty;
    var visited: usize = 0;
    var bytes: usize = 0;
    for (themes.entries) |entry| for (entry.package.profiles) |descriptor| {
        if (entries.items.len >= 256) return error.ProfileCatalogLimit;
        try entries.append(a, .{ .descriptor = descriptor, .path = entry.path, .origin = entry.package.manifest.id, .digest = try a.dupe(u8, &entry.package.digest) });
    };
    const c = pkg.c;
    for (try roots(a)) |root| {
        const fd = c.open(root, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (fd < 0) continue;
        const dir = c.fdopendir(fd) orelse {
            _ = c.close(fd);
            continue;
        };
        defer _ = c.closedir(dir);
        while (c.readdir(dir)) |item| {
            const name = std.mem.sliceTo(item.*.d_name[0..], 0);
            if (name.len == 0 or name[0] == '.') continue;
            visited += 1;
            if (visited > 256 or entries.items.len >= 256) return error.ProfileCatalogLimit;
            const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, name }, 0);
            var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer scratch.deinit();
            const files = pkg.remaining(scratch.allocator(), path) catch |err| {
                try diagnostics.append(a, .{ .path = path, .error_code = @errorName(err) });
                continue;
            };
            for (files) |file| bytes += file.bytes.len;
            if (bytes > 64 * 1024 * 1024) return error.ProfileCatalogLimit;
            const descriptor = readDescriptor(scratch.allocator(), files) catch |err| {
                try diagnostics.append(a, .{ .path = path, .error_code = @errorName(err) });
                continue;
            };
            const cloned = try model.parse(profiles.Descriptor, a, try std.json.Stringify.valueAlloc(scratch.allocator(), descriptor, .{}), 16384);
            try entries.append(a, .{ .descriptor = cloned, .path = path, .origin = "local", .digest = try a.dupe(u8, &hash(files)) });
        }
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, x: Entry, y: Entry) bool {
            const order = std.mem.order(u8, x.descriptor.id, y.descriptor.id);
            return if (order == .eq) std.mem.lessThan(u8, x.path, y.path) else order == .lt;
        }
    }.less);
    std.mem.sort(@import("catalog.zig").Diagnostic, diagnostics.items, {}, struct {
        fn less(_: void, x: @import("catalog.zig").Diagnostic, y: @import("catalog.zig").Diagnostic) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.less);
    return .{ .entries = entries.items, .diagnostics = diagnostics.items, .revision = model.hash(try std.json.Stringify.valueAlloc(a, .{ .entries = entries.items, .diagnostics = diagnostics.items }, .{})) };
}
fn readDescriptor(a: std.mem.Allocator, files: []const pkg.File) !profiles.Descriptor {
    const descriptor = try model.parse(profiles.Descriptor, a, try asset(files, "profile.json"), 16384);
    try descriptor.validate();
    for (descriptor.templates) |t| try profiles.template(try asset(files, t.path));
    return descriptor;
}
fn hash(files: []const pkg.File) [64]u8 {
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    for (files) |file| {
        sha.update(file.path);
        sha.update(&.{0});
        sha.update(&model.hash(file.bytes));
    }
    var raw: [32]u8 = undefined;
    sha.final(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}
fn asset(files: []const pkg.File, path: []const u8) ![]const u8 {
    for (files) |file| if (std.mem.eql(u8, file.path, path)) return file.bytes;
    return error.ProfileAssetMissing;
}
pub const Captured = struct {
    application: profiles.Application,
    id: []const u8,
    origin: []const u8 = "",
    descriptor: ?profiles.Descriptor = null,
    templates: []const pkg.File = &.{},
    error_code: ?[]const u8 = null,
};
pub const Snapshot = struct {
    schema_version: u32 = 1,
    error_code: ?[]const u8 = null,
    provider: []const u8 = "",
    catalog_revision: []const u8 = "",
    profiles: []const Captured = &.{},
    render_json: ?[]const u8 = null,
    selection_key: []const u8 = "",
    color_identity: []const u8 = "",
    variant: enum { dark, light } = .dark,
};
pub fn capture(a: std.mem.Allocator, p: Preferences, dynamic_json: ?[]const u8, image: ?[]const u8, cancel: *gio.Cancellable, scratch: [:0]const u8, context: *generator.Context) !Snapshot {
    if (!p.matugen.enabled) return .{};
    const themes = try @import("catalog.zig").scan(a);
    const choices = try catalog(a, themes);
    if (p.matugen.catalog_revision.len > 0 and !std.mem.eql(u8, p.matugen.catalog_revision, &choices.revision)) return error.ProfileCatalogChanged;
    const active = if (p.theme.mode != .gtk and p.theme.package_id.len > 0) (try themes.get(p.theme.package_id)).package else null;
    var selected: std.ArrayList(Captured) = .empty;
    for (std.enums.values(profiles.Application)) |application| {
        var inherited: ?[]const u8 = null;
        if (active) |package| for (package.manifest.defaults) |default| {
            if (std.mem.eql(u8, default.application, @tagName(application))) inherited = default.profile;
        };
        const choice = p.matugen.applications.map.get(@tagName(application)) orelse profiles.Selection{};
        const id = profiles.effective(true, choice, inherited) orelse continue;
        const entry = choices.get(id) catch |err| {
            try selected.append(a, .{ .application = application, .id = id, .error_code = @errorName(err) });
            continue;
        };
        if (entry.descriptor.application != application) return error.ProfileApplicationMismatch;
        var available = false;
        for (entry.descriptor.variants) |v| if (std.mem.eql(u8, @tagName(v), @tagName(p.theme.variant))) {
            available = true;
        };
        if (!available) {
            try selected.append(a, .{ .application = application, .id = id, .origin = entry.origin, .error_code = "UnsupportedProfileVariant" });
            continue;
        }
        const files = if (std.mem.eql(u8, entry.origin, "local")) blk: {
            const loaded = try pkg.remaining(a, entry.path);
            if (!std.mem.eql(u8, &hash(loaded), entry.digest)) return error.ProfileCatalogChanged;
            break :blk loaded;
        } else blk: {
            const loaded = try pkg.load(a, entry.path);
            if (!std.mem.eql(u8, &loaded.digest, entry.digest)) return error.ProfileCatalogChanged;
            break :blk loaded.files;
        };
        var templates: std.ArrayList(pkg.File) = .empty;
        for (entry.descriptor.templates) |t| try templates.append(a, .{ .path = t.output, .bytes = try asset(files, t.path) });
        try selected.append(a, .{ .application = application, .id = id, .origin = entry.origin, .descriptor = entry.descriptor, .templates = templates.items });
    }
    var result: Snapshot = .{ .provider = if (active) |package| package.manifest.id else "", .catalog_revision = try a.dupe(u8, &choices.revision), .profiles = selected.items, .variant = if (p.theme.variant == .dark) .dark else .light };
    result.selection_key = try selectionKey(a, p);
    if (selected.items.len == 0) return result;
    if (p.matugen.colors.source == .follow_pearl) {
        if (p.theme.mode == .dynamic) result.render_json = dynamic_json;
        if (p.theme.mode == .package) {
            const palette = try themes.get(if (p.theme.palette_id.len > 0) p.theme.palette_id else p.theme.package_id);
            if (palette.package.manifest.render_data) |data| {
                if (if (p.theme.variant == .dark) data.dark else data.light) |path| {
                    const captured = try pkg.load(a, palette.path);
                    if (!std.mem.eql(u8, &captured.digest, &palette.package.digest)) return error.ThemeCatalogChanged;
                    result.render_json = try captured.asset(path);
                }
            }
        }
    }
    try refreshColors(a, &result, p, dynamic_json, image, cancel, scratch, context);
    return result;
}

const Preferences = @import("../config/preferences.zig").Preferences;
const generator = @import("generator.zig");

/// The template selection identity deliberately excludes wallpaper bytes/path.
pub fn selectionKey(a: std.mem.Allocator, p: Preferences) ![]const u8 {
    var selections: [5]profiles.Selection = undefined;
    for (std.enums.values(profiles.Application), &selections) |application, *selection|
        selection.* = p.matugen.applications.map.get(@tagName(application)) orelse .{};
    return a.dupe(u8, &model.hash(try std.json.Stringify.valueAlloc(a, .{
        .applications = selections,
        .catalog = p.matugen.catalog_revision,
        .provider = p.theme.package_id,
        .palette = p.theme.palette_id,
        .mode = p.theme.mode,
        .variant = p.theme.variant,
        .source = p.matugen.colors.source,
    }, .{})));
}

pub fn wallpaperColors(p: Preferences) bool {
    return p.matugen.enabled and (p.matugen.colors.source == .wallpaper or
        (p.matugen.colors.source == .follow_pearl and p.theme.mode == .dynamic and p.theme.source == .wallpaper));
}

/// Refresh colors without consulting mutable catalogs or template files.
pub fn refreshColors(a: std.mem.Allocator, result: *Snapshot, p: Preferences, dynamic_json: ?[]const u8, image: ?[]const u8, cancel: *gio.Cancellable, scratch: [:0]const u8, context: *generator.Context) !void {
    if (result.profiles.len == 0) return;
    result.error_code = null;
    if (p.matugen.colors.source == .follow_pearl) {
        if (p.theme.mode == .dynamic) result.render_json = dynamic_json;
        // Package render data was captured with the committed templates.
        if (p.theme.mode == .static or p.theme.mode == .gtk) result.render_json = null;
    } else {
        var source = p;
        source.theme.source = if (p.matugen.colors.source == .seed) .seed else .wallpaper;
        source.theme.seed = p.matugen.colors.seed;
        if (p.theme.mode == .dynamic and source.theme.source == p.theme.source and
            (source.theme.source == .wallpaper or std.mem.eql(u8, source.theme.seed, p.theme.seed)))
        {
            result.render_json = dynamic_json;
        } else {
            try io.mkdir(scratch);
            var hit = false;
            result.render_json = (try generator.fullWithContext(a, source, image, scratch, cancel, &hit, context)).json;
        }
    }
    result.color_identity = try a.dupe(u8, &model.hash(try std.json.Stringify.valueAlloc(a, .{
        .api = @as(u32, 1),
        .source = p.matugen.colors.source,
        .shell_source = if (p.matugen.colors.source == .follow_pearl) @tagName(p.theme.source) else "",
        .input = if (wallpaperColors(p)) model.hash(image orelse return error.ImageRequired) else model.hash(if (p.matugen.colors.source == .follow_pearl and p.theme.mode == .dynamic) p.theme.seed else p.matugen.colors.seed),
        .variant = p.theme.variant,
        .renderer = context.version orelse "fixed",
        .render = model.hash(result.render_json orelse ""),
    }, .{})));
}

test "wallpaper refresh keeps captured templates and shares the shell render data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    var p: Preferences = .{};
    p.matugen.enabled = true;
    p.theme.mode = .dynamic;
    p.theme.source = .wallpaper;
    var snapshot: Snapshot = .{ .render_json = "old", .profiles = &.{.{ .id = "test.zed", .application = .zed, .templates = &.{.{ .path = "theme.json", .bytes = "captured" }} }} };
    // A populated renderer context proves this path needs no external process.
    var context: generator.Context = .{ .version = "matugen 4.2.0" };
    try refreshColors(a, &snapshot, p, "new", "image-a", cancel, "/unused", &context);
    try std.testing.expectEqualStrings("new", snapshot.render_json.?);
    try std.testing.expectEqualStrings("captured", snapshot.profiles[0].templates[0].bytes);
    const first = snapshot.color_identity;
    p.matugen.colors.source = .wallpaper;
    try refreshColors(a, &snapshot, p, "next", "image-b", cancel, "/unused", &context);
    try std.testing.expectEqualStrings("next", snapshot.render_json.?);
    try std.testing.expect(!std.mem.eql(u8, first, snapshot.color_identity));
    p.matugen.colors.source = .follow_pearl;
    p.theme.mode = .package;
    try refreshColors(a, &snapshot, p, "ignored", "image-c", cancel, "/unused", &context);
    try std.testing.expectEqualStrings("next", snapshot.render_json.?);
    p.theme.mode = .gtk;
    try refreshColors(a, &snapshot, p, "ignored", null, cancel, "/unused", &context);
    try std.testing.expect(snapshot.render_json == null);
}

test "selection identity excludes wallpaper path and seed but binds template choices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p: Preferences = .{};
    const first = try selectionKey(a, p);
    p.wallpaper.path = "/new.png";
    p.matugen.colors.seed = "#ff0000";
    try std.testing.expectEqualStrings(first, try selectionKey(a, p));
    p.theme.variant = .light;
    try std.testing.expect(!std.mem.eql(u8, first, try selectionKey(a, p)));
}
