//! Read immutable package snapshots through NOFOLLOW directory-relative opens.
const std = @import("std");
const m = @import("model.zig");
pub const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
    @cInclude("dirent.h");
});
const a = std.heap.c_allocator;
pub const Image = struct { id: []const u8, bytes: []const u8 };
pub const Package = struct {
    arena: std.heap.ArenaAllocator,
    manifest: m.Manifest,
    wasm: []const u8,
    images: []const Image,
    digest: [64]u8,
    pub fn destroy(self: *Package) void {
        self.arena.deinit();
        a.destroy(self);
    }
    pub fn load(path: [:0]const u8) !*Package {
        const fd = c.open(path, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (fd < 0) return error.PluginDirectory;
        defer _ = c.close(fd);
        return loadFd(fd);
    }
    pub fn loadFd(fd: c_int) !*Package {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const bytes = try read(alloc, fd, "plugin.json", m.Limits.manifest);
        try @import("../config/preferences.zig").boundedJson(bytes, m.Limits.manifest, 12);
        const manifest = try std.json.parseFromSliceLeaky(m.Manifest, alloc, bytes, .{ .allocate = .alloc_always });
        try manifest.validate();
        const wasm = try read(alloc, fd, manifest.component, m.Limits.component);
        if (wasm.len < 8 or !std.mem.eql(u8, wasm[0..8], &.{ 0, 97, 115, 109, 13, 0, 1, 0 })) return error.PluginComponentRequired;
        var sha = std.crypto.hash.sha2.Sha256.init(.{});
        hashPart(&sha, bytes);
        hashPart(&sha, wasm);
        const images = try alloc.alloc(Image, manifest.assets.len);
        var total: usize = 0;
        for (manifest.assets, images) |asset, *image| {
            const png = try read(alloc, fd, asset.path, 2 * 1024 * 1024);
            total += png.len;
            if (total > 8 * 1024 * 1024) return error.PluginImageLimit;
            if (png.len < 24 or !std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n") or !std.mem.eql(u8, png[12..16], "IHDR") or std.mem.readInt(u32, png[16..20], .big) != asset.width or std.mem.readInt(u32, png[20..24], .big) != asset.height) return error.InvalidPluginImage;
            hashPart(&sha, png);
            image.* = .{ .id = asset.id, .bytes = png };
        }
        var digest: [32]u8 = undefined;
        sha.final(&digest);
        const self = try a.create(Package);
        self.* = .{ .arena = arena, .manifest = manifest, .wasm = wasm, .images = images, .digest = std.fmt.bytesToHex(digest, .lower) };
        return self;
    }
};
fn hashPart(sha: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, bytes.len, .little);
    sha.update(&length);
    sha.update(bytes);
}
pub fn read(alloc: std.mem.Allocator, base: c_int, path: []const u8, limit: usize) ![]u8 {
    if (!m.relative(path)) return error.InvalidPluginPath;
    var current = c.dup(base);
    if (current < 0) return error.PluginDirectory;
    defer _ = c.close(current);
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        var name: [257]u8 = undefined;
        const z = try std.fmt.bufPrintZ(&name, "{s}", .{part});
        const last = parts.peek() == null;
        const next = c.openat(current, z, c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC | c.O_NONBLOCK | (if (last) @as(c_int, 0) else c.O_DIRECTORY));
        if (next < 0) return error.PluginFile;
        _ = c.close(current);
        current = next;
        if (!last) continue;
        var stat: c.struct_stat = undefined;
        if (c.fstat(current, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG or stat.st_size < 0 or stat.st_size > limit) return error.PluginFileLimit;
        const bytes = try alloc.alloc(u8, @intCast(stat.st_size));
        var pos: usize = 0;
        while (pos < bytes.len) {
            const n = c.read(current, bytes[pos..].ptr, bytes.len - pos);
            if (n <= 0) return error.PluginRead;
            pos += @intCast(n);
        }
        var extra: u8 = undefined;
        if (c.read(current, &extra, 1) != 0) return error.PluginFileChanged;
        return bytes;
    }
    return error.PluginFile;
}
