//! Discover and install declarative themes directly from a public GitHub tree.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const model = @import("package_model.zig");
const repository = @import("repository.zig");
const io = @import("../config/io.zig");
const pkg = @import("package.zig");
const Progress = @import("progress.zig").Progress;
extern fn mkdtemp([*:0]u8) ?[*:0]u8;

pub const legacy_url = "https://raw.githubusercontent.com/Seafoam-Labs/pearl-community-themes/main/index.json";
pub const Snapshot = struct { repository: []const u8, revision: []const u8, path: []const u8, tree: []const u8 };
const Location = struct { repository: []const u8, revision: ?[]const u8 = null, offset: usize = 0 };
const Entry = struct { path: []const u8, mode: []const u8, type: []const u8, sha: []const u8, size: usize = 0 };
const Tree = struct { sha: []const u8, truncated: bool, tree: []const Entry };

fn oid(value: []const u8) !void {
    if (value.len != 40) return error.InvalidGithubObject;
    for (value) |ch| if (!(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f'))) return error.InvalidGithubObject;
}
fn repositoryName(value: []const u8) !void {
    var parts = std.mem.splitScalar(u8, value, '/');
    for (0..2) |_| {
        const part = parts.next() orelse return error.InvalidGithubRepository;
        if (part.len == 0 or part.len > 100 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidGithubRepository;
        for (part) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.')) return error.InvalidGithubRepository;
    }
    if (parts.next() != null) return error.InvalidGithubRepository;
}
pub fn location(address_: []const u8) !?Location {
    const address = if (std.mem.eql(u8, address_, legacy_url)) repository.default_source.url else address_;
    const prefix = "https://github.com/";
    if (!std.mem.startsWith(u8, address, prefix)) return null;
    var split = std.mem.splitScalar(u8, address[prefix.len..], '?');
    var name = std.mem.trimEnd(u8, split.next().?, "/");
    if (std.mem.endsWith(u8, name, ".git")) name = name[0 .. name.len - 4];
    // Longer GitHub paths may be hosted JSON release assets; keep the existing
    // HTTPS-index transport for those URLs.
    if (std.mem.count(u8, name, "/") != 1) return null;
    try repositoryName(name);
    var result: Location = .{ .repository = name };
    if (split.next()) |query| {
        if (split.next() != null or !std.mem.startsWith(u8, query, "ref=")) return error.InvalidGithubPage;
        var fields = std.mem.splitSequence(u8, query[4..], "&offset=");
        result.revision = fields.next().?;
        try oid(result.revision.?);
        const offset = fields.next() orelse return error.InvalidGithubPage;
        result.offset = std.fmt.parseInt(usize, offset, 10) catch return error.InvalidGithubPage;
        if (fields.next() != null or result.offset > 4096 or result.offset % 16 != 0) return error.InvalidGithubPage;
    }
    return result;
}
fn json(comptime T: type, a: std.mem.Allocator, bytes: []const u8) !T {
    try @import("../config/preferences.zig").boundedJson(bytes, 4 * 1024 * 1024, 24);
    return std.json.parseFromSliceLeaky(T, a, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}
fn fetch(a: std.mem.Allocator, address: []const u8, max: usize, cancel: *gio.Cancellable, progress: ?*Progress) ![]const u8 {
    // Isolated HTTPS fixture only; production always uses GitHub's public hosts.
    if (@import("build_options").test_hooks) {
        if (glib.getenv("PEARL_TEST_GITHUB_BASE")) |base| {
            const prefix = if (std.mem.startsWith(u8, address, "https://api.github.com/")) "https://api.github.com/" else "https://raw.githubusercontent.com/";
            const kind = if (std.mem.eql(u8, prefix, "https://api.github.com/")) "api" else "raw";
            return repository.download(a, try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ base, kind, address[prefix.len..] }), max, cancel, progress);
        }
    }
    return repository.download(a, address, max, cancel, progress);
}
fn tree(a: std.mem.Allocator, name: []const u8, ref: []const u8, cancel: *gio.Cancellable) !Tree {
    const address = try std.fmt.allocPrint(a, "https://api.github.com/repos/{s}/git/trees/{s}?recursive=1", .{ name, ref });
    const result = try json(Tree, a, try fetch(a, address, 4 * 1024 * 1024, cancel, null));
    try oid(result.sha);
    if (result.truncated or result.tree.len > 16384) return error.GithubTreeLimit;
    return result;
}
fn escaped(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (path) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~/", ch) != null) try bytes.append(a, ch) else try bytes.appendSlice(a, &.{ '%', hex[ch >> 4], hex[ch & 15] });
    }
    return bytes.toOwnedSlice(a);
}
fn blob(a: std.mem.Allocator, name: []const u8, revision: []const u8, path: []const u8, entry: Entry, cancel: *gio.Cancellable, progress: ?*Progress) ![]const u8 {
    try oid(entry.sha);
    if (!std.mem.eql(u8, entry.type, "blob") or (!std.mem.eql(u8, entry.mode, "100644") and !std.mem.eql(u8, entry.mode, "100755"))) return error.ThemeSpecialFile;
    if (entry.size > model.max_bytes) return error.ThemeFileLimit;
    const address = try std.fmt.allocPrint(a, "https://raw.githubusercontent.com/{s}/{s}/{s}", .{ name, revision, try escaped(a, path) });
    const bytes = try fetch(a, address, entry.size, cancel, progress);
    if (bytes.len != entry.size) return error.ThemeDownloadDigestMismatch;
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(try std.fmt.allocPrint(a, "blob {d}\x00", .{bytes.len}));
    sha.update(bytes);
    const digest = std.fmt.bytesToHex(sha.finalResult(), .lower);
    if (!std.mem.eql(u8, &digest, entry.sha)) return error.ThemeDownloadDigestMismatch;
    return bytes;
}
fn packageSize(entries: []const Entry, prefix: []const u8) !usize {
    var total: usize = 0;
    var count: usize = 0;
    for (entries) |entry| {
        if (!std.mem.startsWith(u8, entry.path, prefix)) continue;
        try model.relative(entry.path[prefix.len..]);
        try oid(entry.sha);
        count += 1;
        if (count > model.max_entries) return error.ThemeEntryLimit;
        if (std.mem.eql(u8, entry.type, "tree") and std.mem.eql(u8, entry.mode, "040000")) continue;
        if (!std.mem.eql(u8, entry.type, "blob") or (!std.mem.eql(u8, entry.mode, "100644") and !std.mem.eql(u8, entry.mode, "100755"))) return error.ThemeSpecialFile;
        if (entry.size > model.max_bytes - total) return error.ThemeFileLimit;
        total += entry.size;
    }
    return total;
}
pub fn validate(snapshot: Snapshot, release: repository.Release, source: repository.Source) !void {
    try repositoryName(snapshot.repository);
    try oid(snapshot.revision);
    try oid(snapshot.tree);
    try model.relative(snapshot.path);
    if (!std.mem.startsWith(u8, snapshot.path, "themes/") or std.mem.indexOfScalar(u8, snapshot.path[7..], '/') != null) return error.InvalidGithubThemePath;
    const origin = (try location(source.url)) orelse return error.InvalidGithubRepository;
    if (!std.mem.eql(u8, origin.repository, snapshot.repository) or !std.mem.eql(u8, release.sha256, &model.hash(snapshot.tree))) return error.ThemeDownloadDigestMismatch;
}
pub fn index(a: std.mem.Allocator, source: repository.Source, address: []const u8, cancel: *gio.Cancellable) !repository.Index {
    const target = (try location(address)) orelse return error.InvalidGithubRepository;
    const origin = (try location(source.url)) orelse return error.InvalidGithubRepository;
    if (!std.mem.eql(u8, target.repository, origin.repository)) return error.RepositoryIdentityMismatch;
    const revision = target.revision orelse blk: {
        const head = try json(struct { sha: []const u8 }, a, try fetch(a, try std.fmt.allocPrint(a, "https://api.github.com/repos/{s}/commits/HEAD", .{target.repository}), 4 * 1024 * 1024, cancel, null));
        try oid(head.sha);
        break :blk head.sha;
    };
    const listing = try tree(a, target.repository, revision, cancel);
    var manifests: std.ArrayList(Entry) = .empty;
    for (listing.tree) |entry| {
        if (!std.mem.startsWith(u8, entry.path, "themes/") or !std.mem.endsWith(u8, entry.path, "/theme.json")) continue;
        const folder = entry.path[7 .. entry.path.len - "/theme.json".len];
        if (folder.len == 0 or std.mem.indexOfScalar(u8, folder, '/') != null) continue;
        try model.relative(entry.path);
        try manifests.append(a, entry);
    }
    std.mem.sort(Entry, manifests.items, {}, struct {
        fn less(_: void, x: Entry, y: Entry) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.less);
    if (target.offset > manifests.items.len) return error.InvalidGithubPage;
    const end = @min(manifests.items.len, target.offset + 16);
    var releases: std.ArrayList(repository.Release) = .empty;
    for (manifests.items[target.offset..end]) |entry| {
        if (entry.size > 65536) return error.ThemeFileLimit;
        const m = try model.parse(model.Manifest, a, try blob(a, target.repository, revision, entry.path, entry, cancel, null), 65536);
        try m.validate();
        const path = entry.path[0 .. entry.path.len - "/theme.json".len];
        var subtree: ?[]const u8 = null;
        for (listing.tree) |node| if (std.mem.eql(u8, node.path, path) and std.mem.eql(u8, node.type, "tree")) {
            subtree = node.sha;
            break;
        };
        const hash = subtree orelse return error.InvalidGithubThemePath;
        var variants: std.ArrayList([]const u8) = .empty;
        if (m.palettes.dark != null) try variants.append(a, "dark");
        if (m.palettes.light != null) try variants.append(a, "light");
        try releases.append(a, .{ .id = m.id, .name = m.name, .author = m.author, .license = m.license, .source = m.source, .version = m.asset_version, .url = try std.fmt.allocPrint(a, "https://github.com/{s}/tree/{s}/{s}", .{ target.repository, revision, try escaped(a, path) }), .sha256 = try a.dupe(u8, &model.hash(hash)), .size = try packageSize(listing.tree, try std.fmt.allocPrint(a, "{s}/", .{path})), .requires = m.requires, .variants = variants.items, .style = m.style != null, .github = .{ .repository = target.repository, .revision = revision, .path = path, .tree = hash } });
    }
    return .{ .schema_version = 3, .repository_id = source.id, .releases = releases.items, .next = if (end < manifests.items.len) try std.fmt.allocPrint(a, "https://github.com/{s}?ref={s}&offset={d}", .{ target.repository, revision, end }) else null };
}
pub fn load(a: std.mem.Allocator, release: repository.Release, cancel: *gio.Cancellable, progress: ?*Progress) !pkg.Package {
    const snapshot = release.github orelse return error.InvalidGithubRepository;
    const listing = try tree(a, snapshot.repository, snapshot.tree, cancel);
    if (!std.mem.eql(u8, listing.sha, snapshot.tree) or try packageSize(listing.tree, "") != release.size) return error.ThemeDownloadDigestMismatch;
    const root = try std.fmt.allocPrintSentinel(a, "{s}/pearl/theme-downloads", .{std.mem.span(glib.getUserCacheDir())}, 0);
    try io.mkdir(root);
    const temporary = try std.fmt.allocPrintSentinel(a, "{s}/github-XXXXXX", .{root}, 0);
    if (mkdtemp(temporary) == null) return error.ThemeStagingFailed;
    defer @import("install.zig").removeTree(a, temporary) catch {};
    for (listing.tree) |entry| {
        if (std.mem.eql(u8, entry.type, "tree")) continue;
        const bytes = try blob(a, snapshot.repository, snapshot.revision, try std.fmt.allocPrint(a, "{s}/{s}", .{ snapshot.path, entry.path }), entry, cancel, progress);
        const destination = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ temporary, entry.path }, 0);
        try io.mkdir(try a.dupeZ(u8, std.fs.path.dirname(destination).?));
        try io.atomic(destination, bytes, true);
    }
    if (cancel.isCancelled() != 0) return error.Cancelled;
    if (progress) |p| p.set(.validating);
    return pkg.load(a, temporary);
}
