const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const pixbuf = @import("gdkpixbuf2");
const pkg = @import("package.zig");
const m = @import("model.zig");
const c = pkg.c;
const a = std.heap.c_allocator;
pub const Entry = struct { path: [:0]u8, package: *pkg.Package, images: []*pixbuf.Pixbuf };
pub const Registry = struct {
    entries: std.ArrayList(Entry) = .empty,
    rejected: usize = 0,
    bytes: usize = 0,
    pub fn destroy(self: *Registry) void {
        for (self.entries.items) |entry| {
            a.free(entry.path);
            entry.package.destroy();
            for (entry.images) |image| image.unref();
            a.free(entry.images);
        }
        self.entries.deinit(a);
        a.destroy(self);
    }
    pub fn scan(roots: []const [:0]const u8, cancel: *gio.Cancellable) !*Registry {
        const self = try a.create(Registry);
        self.* = .{};
        errdefer self.destroy();
        for (roots) |root| {
            if (cancel.isCancelled() != 0) return error.Cancelled;
            const fd = c.open(root, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
            if (fd < 0) continue;
            defer _ = c.close(fd);
            try self.walk(fd, root, 0, cancel);
        }
        return self;
    }
    fn walk(self: *Registry, fd: c_int, path: [:0]const u8, depth: u8, cancel: *gio.Cancellable) !void {
        if (depth > 2 or self.entries.items.len == m.Limits.packages) return;
        var st: c.struct_stat = undefined;
        if (c.fstatat(fd, "plugin.json", &st, c.AT_SYMLINK_NOFOLLOW) == 0) {
            self.admit(fd, path) catch {
                self.rejected += 1;
            };
            return;
        }

        const copy = c.dup(fd);
        if (copy < 0) return error.PluginDirectory;
        const dir = c.fdopendir(copy) orelse {
            _ = c.close(copy);
            return error.PluginDirectory;
        };
        defer _ = c.closedir(dir);
        var count: usize = 0;
        while (c.readdir(dir)) |entry| {
            if (cancel.isCancelled() != 0) return error.Cancelled;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            if (!m.identifier(name)) continue;
            count += 1;
            if (count > 64) {
                self.rejected += 1;
                break;
            }
            const child = c.openat(fd, @as([*:0]const u8, @ptrCast(&entry.*.d_name)), c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
            if (child < 0) continue;
            defer _ = c.close(child);
            const next = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ path, name }, 0);
            defer a.free(next);
            try self.walk(child, next, depth + 1, cancel);
        }
    }
    fn admit(self: *Registry, fd: c_int, path: [:0]const u8) !void {
        const loaded = try pkg.Package.loadFd(fd);
        errdefer loaded.destroy();
        var size = loaded.wasm.len;
        for (loaded.images, loaded.manifest.assets) |image, asset| size += image.bytes.len + @as(usize, asset.width) * asset.height * 4;
        if (self.bytes + size > 64 * 1024 * 1024) {
            loaded.destroy();
            self.rejected += 1;
            return;
        }
        for (self.entries.items) |old| if (std.mem.eql(u8, old.package.manifest.id, loaded.manifest.id) and std.mem.eql(u8, old.package.manifest.version, loaded.manifest.version)) {
            loaded.destroy();
            self.rejected += 1;
            return;
        };
        const images = try a.alloc(*pixbuf.Pixbuf, loaded.images.len);
        var decoded: usize = 0;
        errdefer {
            for (images[0..decoded]) |image| image.unref();
            a.free(images);
        }
        for (loaded.images) |image| {
            const loader = pixbuf.PixbufLoader.newWithType("png", null) orelse return error.InvalidPluginImage;
            defer loader.unref();
            const written = loader.write(image.bytes.ptr, image.bytes.len, null);
            const closed = loader.close(null);
            if (written == 0 or closed == 0) return error.InvalidPluginImage;
            const value = loader.getPixbuf() orelse return error.InvalidPluginImage;
            _ = value.ref();
            images[decoded] = value;
            decoded += 1;
        }
        const owned = try a.dupeZ(u8, path);
        errdefer a.free(owned);
        try self.entries.append(a, .{ .path = owned, .package = loaded, .images = images });
        self.bytes += size;
        return;
    }
};
