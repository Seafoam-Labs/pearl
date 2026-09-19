//! Durable, bounded content-addressed image storage. Snapshot references are
//! committed only after blobs; collection follows successful snapshot pruning.
const std = @import("std");
const assets = @import("assets.zig");
const pkg = @import("package.zig");
const model = @import("package_model.zig");
const io = @import("../config/io.zig");
const c = pkg.c;
const quota = 256 * 1024 * 1024;
pub fn save(a: std.mem.Allocator, root: [:0]const u8, blobs: []const assets.Blob) !void {
    if (blobs.len == 0) return;
    const fd = try @import("../config/qt_integration.zig").directory(a, root, true);
    const dir = c.fdopendir(fd) orelse {
        _ = c.close(fd);
        return error.ThemeAssetStore;
    };
    defer _ = c.closedir(dir);
    var total: usize = 0;
    var count: usize = 0;
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        count += 1;
        if (count > 8192) return error.ThemeAssetStoreLimit;
        var info: c.struct_stat = undefined;
        if (c.fstatat(fd, @ptrCast(&entry.*.d_name), &info, c.AT_SYMLINK_NOFOLLOW) != 0 or info.st_mode & c.S_IFMT != c.S_IFREG or info.st_size < 0) return error.ThemeAssetStore;
        total += @intCast(info.st_size);
        if (total > quota) return error.ThemeAssetStoreLimit;
    }
    // Preflight the complete bundle before writing any new member.
    var missing: std.ArrayList(assets.Blob) = .empty;
    for (blobs) |blob| {
        try model.digest(blob.digest);
        if (blob.bytes.len > assets.max_image or !std.mem.eql(u8, &model.hash(blob.bytes), blob.digest)) return error.ThemeAssetDigestMismatch;
        const z = try a.dupeZ(u8, blob.digest);
        var info: c.struct_stat = undefined;
        if (c.fstatat(fd, z, &info, c.AT_SYMLINK_NOFOLLOW) == 0) {
            const old = try pkg.read(a, fd, blob.digest, assets.max_image);
            if (!std.mem.eql(u8, old, blob.bytes)) return error.ThemeAssetDigestMismatch;
        } else {
            if (std.posix.errno(-1) != .NOENT) return error.ThemeAssetStore;
            var duplicate = false;
            for (missing.items) |other| if (std.mem.eql(u8, other.digest, blob.digest)) {
                duplicate = true;
            };
            if (!duplicate) {
                total += blob.bytes.len;
                if (total > quota or count + missing.items.len >= 8192) return error.ThemeAssetStoreLimit;
                try missing.append(a, blob);
            }
        }
    }
    for (missing.items) |blob| try io.atomic(try std.fmt.allocPrintSentinel(a, "/proc/self/fd/{d}/{s}", .{ fd, blob.digest }, 0), blob.bytes, true);
}
pub fn load(a: std.mem.Allocator, root: [:0]const u8, images: []const assets.Image) ![]const assets.Blob {
    try assets.bounds(images);
    if (images.len == 0) return &.{};
    const fd = c.open(root, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return error.ThemeAssetMissing;
    defer _ = c.close(fd);
    var blobs: std.ArrayList(assets.Blob) = .empty;
    for (images) |image| {
        const bytes = try pkg.read(a, fd, image.digest, assets.max_image);
        if (bytes.len != image.size or !std.mem.eql(u8, &model.hash(bytes), image.digest)) return error.ThemeAssetDigestMismatch;
        const checked = try assets.validate(a, image.id, bytes);
        if (checked.image.width != image.width or checked.image.height != image.height) return error.ThemeImageDimensions;
        try blobs.append(a, .{ .digest = image.digest, .bytes = bytes });
    }
    return blobs.items;
}
pub fn prune(a: std.mem.Allocator, root: [:0]const u8, snapshots: [:0]const u8) !void {
    var refs: std.StringHashMap(void) = .init(a);
    const snapshot_fd = c.open(snapshots, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (snapshot_fd < 0) return;
    const snapshots_dir = c.fdopendir(snapshot_fd) orelse {
        _ = c.close(snapshot_fd);
        return;
    };
    defer _ = c.closedir(snapshots_dir);
    var count: usize = 0;
    while (c.readdir(snapshots_dir)) |entry| {
        const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
        if (name.len != 69 or !std.mem.endsWith(u8, name, ".json")) continue;
        count += 1;
        if (count > 64) return error.ThemeSnapshotLimit;
        const bytes = try pkg.read(a, snapshot_fd, name, 16384);
        if (!std.mem.eql(u8, &model.hash(bytes), name[0..64])) return error.ThemeSnapshotCorrupt;
        const snapshot = try model.parse(@import("resolve.zig").Resolved, a, bytes, 16384);
        for (snapshot.images) |image| {
            try model.digest(image.digest);
            try refs.put(image.digest, {});
        }
    }
    const fd = c.open(root, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return;
    const dir = c.fdopendir(fd) orelse {
        _ = c.close(fd);
        return;
    };
    defer _ = c.closedir(dir);
    count = 0;
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
        count += 1;
        if (count > 8194) return error.ThemeAssetStoreLimit;
        model.digest(name) catch continue;
        if (refs.contains(name)) continue;
        const bytes = pkg.read(a, fd, name, assets.max_image) catch continue;
        if (std.mem.eql(u8, &model.hash(bytes), name)) _ = c.unlinkat(fd, @ptrCast(&entry.*.d_name), 0);
    }
    _ = c.fsync(fd);
}

test "asset collection protects retained snapshots and aborts on corrupt history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try a.dupeZ(u8, "/tmp/pearl-assets-store-XXXXXX");
    const native = struct {
        extern fn mkdtemp([*:0]u8) ?[*:0]u8;
    };
    try std.testing.expect(native.mkdtemp(root) != null);
    defer @import("install.zig").removeTree(a, root) catch {};
    const store = try std.fmt.allocPrintSentinel(a, "{s}/assets", .{root}, 0);
    const snapshots = try std.fmt.allocPrintSentinel(a, "{s}/snapshots", .{root}, 0);
    try io.mkdir(snapshots);
    const kept: assets.Blob = .{ .digest = &model.hash("kept"), .bytes = "kept" };
    const unused: assets.Blob = .{ .digest = &model.hash("unused"), .bytes = "unused" };
    try save(a, store, &.{ kept, unused, kept });
    const snapshot: @import("resolve.zig").Resolved = .{ .images = &.{.{ .id = "kept", .digest = kept.digest, .size = 4, .width = 1, .height = 1 }} };
    const bytes = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    const reference = try std.fmt.allocPrintSentinel(a, "{s}/{s}.json", .{ snapshots, model.hash(bytes) }, 0);
    try io.atomic(reference, bytes, true);
    try prune(a, store, snapshots);
    try std.testing.expect(!(try io.read(a, try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ store, kept.digest }, 0), 100, null)).missing);
    try std.testing.expect((try io.read(a, try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ store, unused.digest }, 0), 100, null)).missing);
    try save(a, store, &.{unused});
    try io.atomic(reference, "corrupt", false);
    try std.testing.expectError(error.ThemeSnapshotCorrupt, prune(a, store, snapshots));
    try std.testing.expect(!(try io.read(a, try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ store, unused.digest }, 0), 100, null)).missing);
    // A sparse unowned file counts against quota; protected bytes are not deleted.
    const oversized = try std.fmt.allocPrintSentinel(a, "{s}/quota", .{store}, 0);
    const fd = c.open(oversized, c.O_WRONLY | c.O_CREAT | c.O_EXCL, @as(c_uint, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    try std.testing.expect(c.ftruncate(fd, quota + 1) == 0);
    try std.testing.expectError(error.ThemeAssetStoreLimit, save(a, store, &.{kept}));
}
