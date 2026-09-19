//! HTTPS community indexes and bounded downloads, implemented natively in Zig.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const model = @import("package_model.zig");
const io = @import("../config/io.zig");
pub const c = @cImport({
    @cInclude("curl/curl.h");
    @cInclude("pthread.h");
});
var curl_once: c.pthread_once_t = c.PTHREAD_ONCE_INIT;
var curl_ready: bool = false;
fn initializeCurl() callconv(.c) void {
    curl_ready = c.curl_global_init(c.CURL_GLOBAL_DEFAULT) == c.CURLE_OK;
}
pub const Source = struct { id: []const u8, name: []const u8, url: []const u8 };
pub const Sources = struct { schema_version: u32 = 1, sources: []const Source = &.{} };
pub const default_enabled = if (@hasDecl(@import("build_options"), "community_theme_repository")) @import("build_options").community_theme_repository else true;
pub const default_source: Source = .{ .id = "seafoam-community", .name = "Pearl community themes", .url = "https://github.com/Seafoam-Labs/pearl-community-themes" };
pub const Release = struct {
    id: []const u8,
    name: []const u8,
    author: []const u8,
    license: []const u8,
    source: []const u8,
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
    size: usize,
    requires: model.APIs,
    variants: []const []const u8,
    style: bool,
    description: []const u8 = "",
    github: ?@import("github.zig").Snapshot = null,

    pub fn jsonStringify(self: Release, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        // Archive indexes retain their schema-1/2 wire format for older clients.
        inline for (std.meta.fields(Release)) |field| {
            if (!std.mem.eql(u8, field.name, "github") or self.github != null) {
                try writer.objectField(field.name);
                try writer.write(@field(self, field.name));
            }
        }
        try writer.endObject();
    }
};
pub const Index = struct { schema_version: u32, repository_id: []const u8, releases: []const Release, next: ?[]const u8 = null };
pub const Page = struct { index: Index, offline: bool = false, error_code: ?[]const u8 = null };
pub fn url(value: []const u8) !void {
    try model.text(value, 2048);
    const parsed = std.Uri.parse(value) catch return error.InvalidRepositoryUrl;
    if (!std.mem.eql(u8, parsed.scheme, "https") or parsed.host == null or parsed.user != null or parsed.password != null or parsed.fragment != null) return error.HttpsRequired;
}
pub fn sources(a: std.mem.Allocator) !Sources {
    const path = try sourcePath(a);
    const file = try io.read(a, path, 65536, null);
    if (file.missing) return .{ .sources = if (default_enabled) &.{default_source} else &.{} };
    const result = try model.parse(Sources, a, file.bytes, 65536);
    try validateSources(result);
    return result;
}
fn validateSources(s: Sources) !void {
    if (s.schema_version != 1 or s.sources.len > 16) return error.InvalidThemeSources;
    for (s.sources, 0..) |source, i| {
        try model.identifier(source.id);
        try model.text(source.name, 128);
        try url(source.url);
        for (s.sources[0..i]) |previous| if (std.mem.eql(u8, source.id, previous.id)) return error.DuplicateRepositoryId;
    }
}
fn sourcePath(a: std.mem.Allocator) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, "{s}/pearl/theme-repositories.json", .{std.mem.span(glib.getUserConfigDir())}, 0);
}
pub fn saveSources(a: std.mem.Allocator, value: Sources) !void {
    try validateSources(value);
    const path = try sourcePath(a);
    try io.mkdir(try a.dupeZ(u8, std.fs.path.dirname(path).?));
    try io.atomic(path, try std.json.Stringify.valueAlloc(a, value, .{}), false);
}
pub fn parseIndex(a: std.mem.Allocator, bytes: []const u8, source: Source) !Index {
    const value = try model.parse(Index, a, bytes, 1048576);
    if (value.schema_version != 1 and value.schema_version != 2 and value.schema_version != 3) return error.UnsupportedRepositorySchema;
    if (!std.mem.eql(u8, value.repository_id, source.id)) return error.RepositoryIdentityMismatch;
    // Worst-case metadata must fit in one bounded Settings response. Repositories
    // publish additional pages through `next`, rather than silently truncating.
    if (value.releases.len > 16) return error.RepositoryPageLimit;
    if (value.next) |next| try url(next);
    for (value.releases, 0..) |release, i| {
        if (value.schema_version == 1 and (release.requires.style_api == 2 or release.requires.profile_api != null or release.requires.render_data_api != null)) return error.UnsupportedRepositorySchema;
        try model.identifier(release.id);
        if (std.mem.startsWith(u8, release.id, "pearl.")) return error.ReservedThemeId;
        _ = try model.version(release.version);
        for ([_][]const u8{ release.name, release.author, release.license, release.source }) |s| try model.text(s, 256);
        if (release.description.len > 0) try model.text(release.description, 1024);
        if (release.github) |snapshot| {
            if (value.schema_version != 3) return error.UnsupportedRepositorySchema;
            try @import("github.zig").validate(snapshot, release, source);
        }
        try model.digest(release.sha256);
        try url(release.url);
        if (release.size == 0 or release.size > model.max_bytes or release.variants.len > 2) return error.InvalidThemeRelease;
        for (release.variants, 0..) |v, n| {
            if (!std.mem.eql(u8, v, "dark") and !std.mem.eql(u8, v, "light")) return error.InvalidThemeVariant;
            for (release.variants[0..n]) |old| if (std.mem.eql(u8, old, v)) return error.InvalidThemeVariant;
        }
        for (value.releases[0..i]) |old| if (std.mem.eql(u8, old.id, release.id) and std.mem.eql(u8, old.version, release.version)) return error.DuplicateThemeRelease;
    }
    if ((try std.json.Stringify.valueAlloc(a, value, .{})).len > 96000) return error.RepositoryPageLimit;
    return value;
}
const Download = struct { a: std.mem.Allocator, bytes: std.ArrayList(u8) = .empty, max: usize, cancel: *gio.Cancellable, progress: ?*@import("progress.zig").Progress, failure: ?anyerror = null };
fn write(data: [*]u8, size: usize, count: usize, context: *Download) callconv(.c) usize {
    const n = std.math.mul(usize, size, count) catch return 0;
    if (context.cancel.isCancelled() != 0) {
        context.failure = error.Cancelled;
        return 0;
    }
    if (n > context.max - context.bytes.items.len) {
        context.failure = error.ThemeDownloadLimit;
        return 0;
    }
    context.bytes.appendSlice(context.a, data[0..n]) catch {
        context.failure = error.OutOfMemory;
        return 0;
    };
    return n;
}
fn progress(context: *Download, total: c.curl_off_t, received: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
    if (context.progress) |p| {
        p.received.store(@intCast(@max(0, received)), .monotonic);
        p.total.store(@intCast(@max(0, total)), .monotonic);
    }
    return context.cancel.isCancelled();
}
pub fn download(a: std.mem.Allocator, address: []const u8, max: usize, cancel: *gio.Cancellable, report: ?*@import("progress.zig").Progress) ![]const u8 {
    try url(address);
    if (c.pthread_once(&curl_once, initializeCurl) != 0 or !curl_ready) return error.NetworkUnavailable;
    const handle = c.curl_easy_init() orelse return error.NetworkUnavailable;
    defer c.curl_easy_cleanup(handle);
    var context: Download = .{ .a = a, .max = max, .cancel = cancel, .progress = report };
    const address_z = try a.dupeZ(u8, address);
    if (@import("build_options").test_hooks) {
        if (glib.getenv("PEARL_TEST_THEME_CA")) |ca| {
            if (c.curl_easy_setopt(handle, c.CURLOPT_CAINFO, ca) != c.CURLE_OK) return error.NetworkUnavailable;
        }
    }
    if (c.curl_easy_setopt(handle, c.CURLOPT_URL, address_z.ptr) != c.CURLE_OK or
        c.curl_easy_setopt(handle, c.CURLOPT_USERAGENT, @as([*:0]const u8, "Pearl/1.0")) != c.CURLE_OK or
        c.curl_easy_setopt(handle, c.CURLOPT_PROTOCOLS_STR, @as([*:0]const u8, "https")) != c.CURLE_OK or
        c.curl_easy_setopt(handle, c.CURLOPT_REDIR_PROTOCOLS_STR, @as([*:0]const u8, "https")) != c.CURLE_OK or
        c.curl_easy_setopt(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != c.CURLE_OK or
        c.curl_easy_setopt(handle, c.CURLOPT_MAXREDIRS, @as(c_long, 4)) != c.CURLE_OK or
        c.curl_easy_setopt(handle, c.CURLOPT_CONNECTTIMEOUT, @as(c_long, 10)) != c.CURLE_OK or
        c.curl_easy_setopt(handle, c.CURLOPT_TIMEOUT, @as(c_long, 45)) != c.CURLE_OK or
        c.curl_easy_setopt(handle, c.CURLOPT_NOSIGNAL, @as(c_long, 1)) != c.CURLE_OK or
        c.curl_easy_setopt(handle, c.CURLOPT_FAILONERROR, @as(c_long, 1)) != c.CURLE_OK or
        c.curl_easy_setopt(handle, c.CURLOPT_WRITEFUNCTION, &write) != c.CURLE_OK or
        c.curl_easy_setopt(handle, c.CURLOPT_WRITEDATA, &context) != c.CURLE_OK or
        c.curl_easy_setopt(handle, c.CURLOPT_NOPROGRESS, @as(c_long, 0)) != c.CURLE_OK or
        c.curl_easy_setopt(handle, c.CURLOPT_XFERINFOFUNCTION, &progress) != c.CURLE_OK or
        c.curl_easy_setopt(handle, c.CURLOPT_XFERINFODATA, &context) != c.CURLE_OK) return error.NetworkUnavailable;
    if (c.curl_easy_perform(handle) != c.CURLE_OK) return context.failure orelse (if (cancel.isCancelled() != 0) error.Cancelled else error.ThemeDownloadFailed);
    return context.bytes.items;
}
pub fn cachePath(a: std.mem.Allocator, source: Source, address: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, "{s}/pearl/theme-repositories/{s}-{s}.json", .{ std.mem.span(glib.getUserCacheDir()), source.id, model.hash(address) }, 0);
}
fn quota(directory: [:0]const u8, maximum: usize, additions: usize) !void {
    if (additions == 0) return;
    const fs = @import("package.zig").c;
    const fd = fs.open(directory, fs.O_RDONLY | fs.O_DIRECTORY | fs.O_NOFOLLOW | fs.O_CLOEXEC);
    if (fd < 0) {
        if (std.posix.errno(fd) == .NOENT) return;
        return error.ThemeRepositoryStorage;
    }
    const dir = fs.fdopendir(fd) orelse {
        _ = fs.close(fd);
        return error.ThemeRepositoryStorage;
    };
    defer _ = fs.closedir(dir);
    var count = additions;
    while (fs.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        count += 1;
        if (count > maximum) return error.ThemeRepositoryStorageLimit;
    }
}
pub fn refresh(a: std.mem.Allocator, source: Source, address: []const u8, cancel: *gio.Cancellable, report: ?*@import("progress.zig").Progress) !Page {
    const path = try cachePath(a, source, address);
    const bytes = fetchIndex(a, source, address, cancel, report) catch |err| {
        if (err == error.Cancelled) return err;
        if (try @import("github.zig").location(source.url) != null and err != error.ThemeDownloadFailed and err != error.NetworkUnavailable) return err;
        const cached = try io.read(a, path, 1048576, cancel);
        if (cached.missing) return err;
        return .{ .index = try parseIndex(a, cached.bytes, source), .offline = true, .error_code = @errorName(err) };
    };
    const value = try parseIndex(a, bytes, source);
    // Release identity survives removal from an index and movement across pages.
    // Git tree identities are independent of the old archive publication hashes.
    const history_key = if (try @import("github.zig").location(source.url) != null) try std.fmt.allocPrint(a, "github:{s}", .{source.url}) else source.url;
    const history = try std.fmt.allocPrintSentinel(a, "{s}/pearl/theme-repository-history/{s}", .{ std.mem.span(glib.getUserStateDir()), model.hash(history_key) }, 0);
    var additions: usize = 0;
    for (value.releases) |release| {
        const record = try std.fmt.allocPrintSentinel(a, "{s}/{s}-{s}.sha256", .{ history, release.id, release.version }, 0);
        const previous = try io.read(a, record, 64, cancel);
        if (!previous.missing and !std.mem.eql(u8, previous.bytes, release.sha256)) return error.MutableThemeRelease;
        if (previous.missing) additions += 1;
    }
    try quota(history, 4096, additions);
    if (glib.fileTest(history, .{ .exists = true }) == 0) try quota(try a.dupeZ(u8, std.fs.path.dirname(history).?), 64, 1);
    if (cancel.isCancelled() != 0) return error.Cancelled;
    const prior = try io.read(a, path, 1048576, cancel);
    if (prior.missing) try quota(try a.dupeZ(u8, std.fs.path.dirname(path).?), 512, 1);
    if (!prior.missing) {
        const old = try parseIndex(a, prior.bytes, source);
        for (old.releases) |previous| for (value.releases) |release| {
            if (previous.github == null and release.github != null and std.mem.eql(u8, source.url, @import("github.zig").legacy_url)) continue;
            if (std.mem.eql(u8, previous.id, release.id) and std.mem.eql(u8, previous.version, release.version) and !std.mem.eql(u8, previous.sha256, release.sha256)) return error.MutableThemeRelease;
        };
    }
    try io.mkdir(try a.dupeZ(u8, std.fs.path.dirname(path).?));
    try io.mkdir(history);
    for (value.releases) |release| {
        const record = try std.fmt.allocPrintSentinel(a, "{s}/{s}-{s}.sha256", .{ history, release.id, release.version }, 0);
        try io.atomic(record, release.sha256, false);
    }
    try io.atomic(path, bytes, false);
    return .{ .index = value };
}

fn fetchIndex(a: std.mem.Allocator, source: Source, address: []const u8, cancel: *gio.Cancellable, report: ?*@import("progress.zig").Progress) ![]const u8 {
    if (try @import("github.zig").location(source.url) != null) {
        return std.json.Stringify.valueAlloc(a, try @import("github.zig").index(a, source, address, cancel), .{});
    }
    return download(a, address, 1048576, cancel, report);
}
