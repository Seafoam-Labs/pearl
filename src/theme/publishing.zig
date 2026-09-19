//! Offline native publication builder. Produces validated archives and a complete
//! generation of indexes in a new directory; never contacts or publishes to GitHub.
const std = @import("std");
const gio = @import("gio2");
const model = @import("package_model.zig");
const repository = @import("repository.zig");
const io = @import("../config/io.zig");
const c = @import("package.zig").c;
pub const Input = struct {
    schema_version: u32,
    repository_id: []const u8,
    index_url: []const u8,
    packages: []const struct { path: []const u8, url: []const u8, description: []const u8 = "" },
};
pub fn build(a: std.mem.Allocator, path: [:0]const u8, output: [:0]const u8, cancel: *gio.Cancellable) ![]const u8 {
    const file = try io.read(a, path, 1048576, cancel);
    if (file.missing) return error.PublicationInputMissing;
    const input = try model.parse(Input, a, file.bytes, 1048576);
    if (input.schema_version != 1 or input.packages.len == 0 or input.packages.len > 4096) return error.InvalidPublication;
    try model.identifier(input.repository_id);
    try repository.url(input.index_url);
    if (!std.mem.endsWith(u8, input.index_url, "/index.json")) return error.InvalidPublicationIndexUrl;
    if (output.len == 0 or output[0] != '/') return error.AbsolutePublicationPathRequired;
    // Exclusive creation: failed builds are reviewable and cannot replace an old publication.
    if (c.mkdir(output, 0o700) != 0) return error.PublicationOutputExists;
    const archive_root = try std.fmt.allocPrintSentinel(a, "{s}/archives", .{output}, 0);
    try io.mkdir(archive_root);
    var releases: std.ArrayList(repository.Release) = .empty;
    for (input.packages) |record| {
        if (cancel.isCancelled() != 0) return error.Cancelled;
        try repository.url(record.url);
        if (record.description.len > 0) try model.text(record.description, 1024);
        var temporary = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer temporary.deinit();
        const temp = temporary.allocator();
        const package = try @import("package.zig").load(temp, try temp.dupeZ(u8, record.path));
        const m = package.manifest;
        // Publication requires attribution even though private local packages
        // may be used without redistribution documentation.
        for ([_][]const u8{ "LICENSE", "ATTRIBUTION.md" }) |required| {
            const notice = package.asset(required) catch return error.PublicationAttributionRequired;
            if (notice.len == 0 or notice.len > 131072 or !std.unicode.utf8ValidateSlice(notice)) return error.PublicationAttributionRequired;
        }
        for (releases.items) |old| if (std.mem.eql(u8, old.id, m.id) and std.mem.eql(u8, old.version, m.asset_version)) return error.DuplicateThemeRelease;
        const archive = try @import("archive_writer.zig").pack(temp, package);
        try io.atomic(try std.fmt.allocPrintSentinel(temp, "{s}/{s}-{s}.tar.gz", .{ archive_root, m.id, m.asset_version }, 0), archive, true);
        var variants: std.ArrayList([]const u8) = .empty;
        if (package.dark != null) try variants.append(a, "dark");
        if (package.light != null) try variants.append(a, "light");
        const release: repository.Release = .{ .id = m.id, .name = m.name, .author = m.author, .license = m.license, .source = m.source, .version = m.asset_version, .url = record.url, .sha256 = &model.hash(archive), .size = archive.len, .requires = m.requires, .variants = variants.items, .style = m.style != null, .description = record.description };
        try releases.append(a, try model.parse(repository.Release, a, try std.json.Stringify.valueAlloc(temp, release, .{}), 16384));
    }
    std.mem.sort(repository.Release, releases.items, {}, struct {
        fn less(_: void, x: repository.Release, y: repository.Release) bool {
            const order = std.mem.order(u8, x.id, y.id);
            if (order != .eq) return order == .lt;
            const xv = model.version(x.version) catch unreachable;
            const yv = model.version(y.version) catch unreachable;
            for (xv, yv) |left, right| if (left != right) return left > right;
            return false;
        }
    }.less);
    const generation = model.hash(try std.json.Stringify.valueAlloc(a, releases.items, .{}));
    const directory = try std.fmt.allocPrintSentinel(a, "{s}/indexes/{s}", .{ output, generation }, 0);
    try io.mkdir(directory);
    const count = (releases.items.len + 15) / 16;
    const base = input.index_url[0 .. input.index_url.len - "/index.json".len];
    for (0..count) |page| {
        const index: repository.Index = .{ .schema_version = 2, .repository_id = input.repository_id, .releases = releases.items[page * 16 .. @min(releases.items.len, (page + 1) * 16)], .next = if (page + 1 < count) try std.fmt.allocPrint(a, "{s}/indexes/{s}/page-{d}.json", .{ base, generation, page + 1 }) else null };
        const bytes = try std.json.Stringify.valueAlloc(a, index, .{});
        _ = try repository.parseIndex(a, bytes, .{ .id = input.repository_id, .name = input.repository_id, .url = input.index_url });
        try io.atomic(try std.fmt.allocPrintSentinel(a, "{s}/page-{d}.json", .{ directory, page }, 0), bytes, true);
        if (page == 0) try io.atomic(try std.fmt.allocPrintSentinel(a, "{s}/index.json", .{output}, 0), bytes, true);
    }
    return std.json.Stringify.valueAlloc(a, .{ .generation = generation[0..], .packages = releases.items.len, .pages = count, .repository_id = input.repository_id }, .{});
}
