//! Reads user artwork overrides through NOFOLLOW opens. Host-owned presentation
//! only: artwork never enters the package digest and never reaches a guest.
const std = @import("std");
const pixbuf = @import("gdkpixbuf2");
const m = @import("model.zig");
const policy = @import("artwork_policy.zig");
pub const c = @import("pearl_libc");
const a = std.heap.c_allocator;
const Dir = @TypeOf(c.fdopendir(std.math.maxInt(c_int)));

fn openDir(path: [:0]const u8) Dir {
    const fd = c.open(path, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return null;
    const dir = c.fdopendir(fd);
    if (dir == null) _ = c.close(fd);
    return dir;
}

fn read(alloc: std.mem.Allocator, dir: Dir, name: [:0]const u8) ![]u8 {
    const fd = c.openat(c.dirfd(dir), name, c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return error.PluginFile;
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG or stat.st_size < 0 or stat.st_size > m.Limits.artwork_bytes) return error.PluginFileLimit;
    const bytes = try alloc.alloc(u8, @intCast(stat.st_size));
    errdefer alloc.free(bytes);
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = c.read(fd, bytes[pos..].ptr, bytes.len - pos);
        if (n <= 0) return error.PluginRead;
        pos += @intCast(n);
    }
    return bytes;
}

/// PNG names in `dir` that keep `asset`'s declared geometry, sorted and bounded.
/// A missing folder is the normal case and simply offers no choices.
pub fn candidates(alloc: std.mem.Allocator, dir: [:0]const u8, asset: m.Asset) ![]const [:0]u8 {
    var names: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    }
    const handle = openDir(dir) orelse return names.items;
    defer _ = c.closedir(handle);
    while (names.items.len < m.Limits.artwork_files) {
        const entry = c.readdir(handle) orelse break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (!m.artworkFile(name)) continue;
        const owned = try alloc.dupeSentinel(u8, name, 0);
        errdefer alloc.free(owned);
        const bytes = read(alloc, handle, owned) catch {
            alloc.free(owned);
            continue;
        };
        defer alloc.free(bytes);
        if (!policy.replaces(bytes, asset)) {
            alloc.free(owned);
            continue;
        }
        try names.append(alloc, owned);
    }
    std.mem.sort([:0]u8, names.items, {}, less);
    return names.items;
}

fn less(_: void, lhs: [:0]const u8, rhs: [:0]const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

/// Decode one chosen file. The caller owns the returned pixbuf.
pub fn decode(dir: [:0]const u8, file: [:0]const u8, asset: m.Asset) !*pixbuf.Pixbuf {
    if (!m.artworkFile(file)) return error.InvalidPluginArtwork;
    const handle = openDir(dir) orelse return error.PluginFile;
    defer _ = c.closedir(handle);
    const bytes = try read(a, handle, file);
    defer a.free(bytes);
    if (!policy.replaces(bytes, asset)) return error.InvalidPluginArtwork;
    const loader = pixbuf.PixbufLoader.newWithType("png", null) orelse return error.InvalidPluginImage;
    defer loader.unref();
    if (loader.write(bytes.ptr, bytes.len, null) == 0 or loader.close(null) == 0) return error.InvalidPluginImage;
    const value = loader.getPixbuf() orelse return error.InvalidPluginImage;
    if (value.getWidth() != asset.width or value.getHeight() != asset.height) {
        value.unref();
        return error.InvalidPluginArtwork;
    }
    return value;
}
