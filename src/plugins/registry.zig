//! Worker-owned immutable snapshots; entries may outlive their discovery index.
const std = @import("std");
const gio = @import("gio2");
const pixbuf = @import("gdkpixbuf2");
const pkg = @import("package.zig");
const m = @import("model.zig");
const c = pkg.c;
const a = std.heap.c_allocator;
var retained_bytes = std.atomic.Value(usize).init(0);
pub const Entry = struct {
    refs: usize = 1,
    path: [:0]u8,
    root: usize,
    package: *pkg.Package,
    images: []*pixbuf.Pixbuf,
    bytes: usize,
    pub fn retain(self: *Entry) void {
        self.refs += 1;
    }
    pub fn release(self: *Entry) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        _ = retained_bytes.fetchSub(self.bytes, .monotonic);
        a.free(self.path);
        self.package.destroy();
        for (self.images) |image| image.unref();
        a.free(self.images);
        a.destroy(self);
    }
};
pub const Issue = struct { path: [:0]u8, code: []const u8 };
pub const Registry = struct {
    entries: std.ArrayList(*Entry) = .empty,
    directories: std.ArrayList([:0]u8) = .empty,
    issues: std.ArrayList(Issue) = .empty,
    rejected: usize = 0,
    bytes: usize = 0,
    visited: usize = 0,
    pub fn retainedBytes() usize {
        return retained_bytes.load(.monotonic);
    }
    pub fn destroy(self: *Registry) void {
        for (self.entries.items) |entry| entry.release();
        for (self.directories.items) |path| a.free(path);
        for (self.issues.items) |item| a.free(item.path);
        self.entries.deinit(a);
        self.directories.deinit(a);
        self.issues.deinit(a);
        a.destroy(self);
    }
    pub fn issue(self: *const Registry, path: []const u8) ?[]const u8 {
        for (self.issues.items) |item| if (std.mem.eql(u8, path, item.path)) return item.code;
        return null;
    }
    pub fn containsDirectory(self: *const Registry, path: []const u8) bool {
        for (self.directories.items) |item| if (std.mem.eql(u8, path, item)) return true;
        return false;
    }
    pub fn directory(self: *Registry, path: []const u8) !void {
        if (self.containsDirectory(path)) return;
        if (self.directories.items.len >= 512) return error.PluginTraversalLimit;
        const copy = try a.dupeZ(u8, path);
        errdefer a.free(copy);
        try self.directories.append(a, copy);
    }
    pub fn scan(roots: []const [:0]const u8, cancel: *gio.Cancellable) !*Registry {
        const self = try a.create(Registry);
        self.* = .{};
        errdefer self.destroy();
        for (roots, 0..) |root, index| {
            if (cancel.isCancelled() != 0) return error.Cancelled;
            const fd = c.open(root, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
            if (fd < 0) {
                if (std.c._errno().* == c.ENOENT) continue;
                return error.PluginRootUnreadable;
            }
            defer _ = c.close(fd);
            try self.walk(fd, root, index, 0, cancel);
        }
        std.mem.sort(*Entry, self.entries.items, {}, less);
        return self;
    }
    pub fn less(_: void, lhs: *Entry, rhs: *Entry) bool {
        const order = std.mem.order(u8, lhs.package.manifest.id, rhs.package.manifest.id);
        if (order != .eq) return order == .lt;
        return @import("discovery_policy.zig").priority(lhs.root, lhs.path, rhs.root, rhs.path);
    }
    fn walk(self: *Registry, fd: c_int, path: [:0]const u8, root: usize, depth: u8, cancel: *gio.Cancellable) !void {
        if (depth > 2) return;
        try self.directory(path);
        var st: c.struct_stat = undefined;
        if (c.fstatat(fd, "plugin.json", &st, c.AT_SYMLINK_NOFOLLOW) == 0) {
            if (self.entries.items.len + self.rejected >= m.Limits.packages) return error.PluginPackageLimit;
            self.admit(fd, path, root) catch |err| {
                switch (err) {
                    error.OutOfMemory, error.PluginMemoryLimit, error.PluginTraversalLimit => return err,
                    else => {},
                }
                self.rejected += 1;
                const copy = try a.dupeZ(u8, path);
                errdefer a.free(copy);
                try self.issues.append(a, .{ .path = copy, .code = @errorName(err) });
            };
            return;
        }
        if (std.c._errno().* != c.ENOENT) return error.PluginDirectoryUnreadable;
        const copy = c.dup(fd);
        if (copy < 0) return error.PluginDirectory;
        const dir = c.fdopendir(copy) orelse {
            _ = c.close(copy);
            return error.PluginDirectory;
        };
        defer _ = c.closedir(dir);
        while (true) {
            std.c._errno().* = 0;
            const entry = c.readdir(dir) orelse {
                if (std.c._errno().* != 0) return error.PluginDirectoryUnreadable;
                break;
            };
            if (cancel.isCancelled() != 0) return error.Cancelled;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            self.visited += 1;
            if (self.visited > 2048) return error.PluginTraversalLimit;
            if (!m.identifier(name)) continue;
            const child = c.openat(fd, @as([*:0]const u8, @ptrCast(&entry.*.d_name)), c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
            if (child < 0) {
                const err = std.c._errno().*;
                if (err == c.ENOTDIR or err == c.ELOOP) continue;
                return error.PluginDirectoryUnreadable;
            }
            defer _ = c.close(child);
            const next = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ path, name }, 0);
            defer a.free(next);
            try self.walk(child, next, root, depth + 1, cancel);
        }
    }
    fn nested(self: *Registry, path: []const u8, relative: []const u8) !void {
        var it = std.mem.splitScalar(u8, relative, '/');
        while (it.next()) |_| {
            if (it.peek() == null) break;
            const joined = try std.fmt.allocPrint(a, "{s}/{s}", .{ path, relative[0 .. it.index.? - 1] });
            defer a.free(joined);
            try self.directory(joined);
        }
    }
    fn admit(self: *Registry, fd: c_int, path: [:0]const u8, root: usize) !void {
        const loaded = try pkg.Package.loadFd(fd);
        errdefer loaded.destroy();
        var size = loaded.wasm.len + m.Limits.manifest;
        for (loaded.images, loaded.manifest.assets) |image, asset| size += image.bytes.len + @as(usize, asset.width) * asset.height * 4;
        if (self.bytes + size > 64 * 1024 * 1024) return error.PluginMemoryLimit;
        const previous = retained_bytes.fetchAdd(size, .monotonic);
        if (previous + size > 128 * 1024 * 1024) {
            _ = retained_bytes.fetchSub(size, .monotonic);
            return error.PluginMemoryLimit;
        }
        errdefer _ = retained_bytes.fetchSub(size, .monotonic);
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
        try self.nested(path, loaded.manifest.component);
        for (loaded.manifest.assets) |asset| try self.nested(path, asset.path);
        const owned = try a.dupeZ(u8, path);
        errdefer a.free(owned);
        const record = try a.create(Entry);
        errdefer a.destroy(record);
        record.* = .{ .path = owned, .root = root, .package = loaded, .images = images, .bytes = size };
        try self.entries.append(a, record);
        self.bytes += size;
    }
};
