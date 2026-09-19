const std = @import("std");
const glib = @import("glib2");
const pkg = @import("package.zig");
const model = @import("package_model.zig");
const c = pkg.c;
pub const Entry = struct { path: [:0]const u8, package: pkg.Package };
pub const Diagnostic = struct { path: []const u8, error_code: []const u8 };
pub const Catalog = struct {
    entries: []const Entry,
    diagnostics: []const Diagnostic,
    revision: [64]u8,
    pub fn get(self: Catalog, id: []const u8) !Entry {
        var found: ?Entry = null;
        for (self.entries) |entry| if (std.mem.eql(u8, entry.package.manifest.id, id)) {
            if (found != null) return error.DuplicateThemeId;
            found = entry;
        };
        return found orelse error.ThemeUnavailable;
    }
};
pub fn roots(a: std.mem.Allocator) ![]const [:0]const u8 {
    var result: std.ArrayList([:0]const u8) = .empty;
    try result.append(a, try std.fmt.allocPrintSentinel(a, "{s}/pearl/themes", .{std.mem.span(glib.getUserDataDir())}, 0));
    const dirs: [*:null]const ?[*:0]const u8 = @ptrCast(glib.getSystemDataDirs());
    var i: usize = 0;
    while (dirs[i]) |dir| : (i += 1) {
        const path = try std.fmt.allocPrintSentinel(a, "{s}/pearl/themes", .{std.mem.span(dir)}, 0);
        var duplicate = false;
        for (result.items) |old| if (std.mem.eql(u8, path, old)) {
            duplicate = true;
        };
        if (!duplicate) try result.append(a, path);
    }
    return result.items;
}
pub fn scan(a: std.mem.Allocator) !Catalog {
    var entries: std.ArrayList(Entry) = .empty;
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    var count: usize = 0;
    var bytes: usize = 0;
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
            count += 1;
            if (count > 256) return error.ThemeCatalogLimit;
            const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, name }, 0);
            var temporary = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer temporary.deinit();
            const package = pkg.load(temporary.allocator(), path) catch |err| {
                try diagnostics.append(a, .{ .path = path, .error_code = @errorName(err) });
                continue;
            };
            for (package.files) |file| bytes += file.bytes.len;
            if (bytes > 64 * 1024 * 1024) return error.ThemeCatalogBytesLimit;
            // Catalogs retain resolved data, not entire archives or failed
            // validation buffers. Assets have already contributed to the digest.
            var metadata = package;
            metadata.files = &.{};
            metadata.blobs = &.{};
            const retained = model.parse(pkg.Package, a, try std.json.Stringify.valueAlloc(temporary.allocator(), metadata, .{}), 131072) catch |err| {
                try diagnostics.append(a, .{ .path = path, .error_code = @errorName(err) });
                continue;
            };
            try entries.append(a, .{ .path = path, .package = retained });
        }
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, x: Entry, y: Entry) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.less);
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    for (entries.items) |entry| {
        sha.update(entry.path);
        sha.update(&.{0});
        sha.update(&entry.package.digest);
    }
    var raw: [32]u8 = undefined;
    sha.final(&raw);
    return .{ .entries = entries.items, .diagnostics = diagnostics.items, .revision = std.fmt.bytesToHex(raw, .lower) };
}
