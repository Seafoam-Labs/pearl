//! Directory-relative immutable package snapshots, including all installation assets.
const std = @import("std");
const model = @import("package_model.zig");
pub const c = @import("../plugins/package.zig").c;
const styles = @import("style.zig");
pub const File = struct { path: []const u8, bytes: []const u8 };
/// Theme paths have a separate contract from plugin IDs (including 69-byte
/// content-addressed snapshot filenames). Open every component without links.
pub fn read(a: std.mem.Allocator, base: c_int, path: []const u8, limit: usize) ![]u8 {
    try model.relative(path);
    var current = c.dup(base);
    if (current < 0) return error.ThemeDirectory;
    defer _ = c.close(current);
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        var name: [256]u8 = undefined;
        const z = try std.fmt.bufPrintZ(&name, "{s}", .{part});
        const last = parts.peek() == null;
        const next = c.openat(current, z, c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC | c.O_NONBLOCK | (if (last) @as(c_int, 0) else c.O_DIRECTORY));
        if (next < 0) return error.ThemeFile;
        _ = c.close(current);
        current = next;
        if (!last) continue;
        var before: c.struct_stat = undefined;
        if (c.fstat(current, &before) != 0 or before.st_mode & c.S_IFMT != c.S_IFREG or before.st_size < 0 or before.st_size > limit) return error.ThemeFileLimit;
        const bytes = try a.alloc(u8, @intCast(before.st_size));
        var pos: usize = 0;
        while (pos < bytes.len) {
            const n = c.read(current, bytes[pos..].ptr, bytes.len - pos);
            if (n <= 0) return error.ThemeRead;
            pos += @intCast(n);
        }
        var extra: u8 = undefined;
        if (c.read(current, &extra, 1) != 0) return error.ThemeChangedDuringRead;
        var after: c.struct_stat = undefined;
        if (c.fstat(current, &after) != 0 or before.st_ino != after.st_ino or before.st_dev != after.st_dev or before.st_size != after.st_size or !std.meta.eql(before.st_mtim, after.st_mtim) or !std.meta.eql(before.st_ctim, after.st_ctim)) return error.ThemeChangedDuringRead;
        return bytes;
    }
    return error.ThemeFile;
}
/// Used by removal recovery to check every surviving file against its journal.
/// Missing members are allowed after interrupted deletion; new/edited members
/// are rejected by the caller before any further cleanup.
pub fn remaining(a: std.mem.Allocator, path: [:0]const u8) ![]const File {
    const fd = c.open(path, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) {
        if (std.posix.errno(fd) == .NOENT) return &.{};
        return error.ThemeDirectory;
    }
    defer _ = c.close(fd);
    var files: std.ArrayList(File) = .empty;
    var total: usize = 0;
    var entries: usize = 0;
    try scan(a, fd, "", &files, &total, &entries, 0);
    std.mem.sort(File, files.items, {}, struct {
        fn less(_: void, x: File, y: File) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.less);
    return files.items;
}
pub const Package = struct {
    manifest: model.Manifest,
    files: []const File,
    digest: [64]u8,
    dark: ?@import("theme.zig").Palette = null,
    light: ?@import("theme.zig").Palette = null,
    tokens: styles.Tokens = .{},
    css: []const u8 = "",
    images: []const @import("assets.zig").Image = &.{},
    blobs: []const @import("assets.zig").Blob = &.{},
    profiles: []const @import("matugen_profiles.zig").Descriptor = &.{},
    pub fn asset(self: Package, path: []const u8) ![]const u8 {
        try model.relative(path);
        for (self.files) |file| if (std.mem.eql(u8, file.path, path)) return file.bytes;
        return error.ThemeAssetMissing;
    }
};
pub fn load(a: std.mem.Allocator, path: [:0]const u8) !Package {
    const fd = c.open(path, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return error.ThemeDirectoryMissing;
    defer _ = c.close(fd);
    var files: std.ArrayList(File) = .empty;
    var total: usize = 0;
    var entries: usize = 0;
    try scan(a, fd, "", &files, &total, &entries, 0);
    std.mem.sort(File, files.items, {}, struct {
        fn less(_: void, x: File, y: File) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.less);
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    for (files.items) |file| {
        const again = try read(a, fd, file.path, model.max_bytes);
        if (!std.mem.eql(u8, file.bytes, again)) return error.ThemeChangedDuringRead;
        a.free(again);
        sha.update(file.path);
        sha.update(&.{0});
        sha.update(&model.hash(file.bytes));
    }
    var raw: [32]u8 = undefined;
    sha.final(&raw);
    var result: Package = .{ .manifest = undefined, .files = files.items, .digest = std.fmt.bytesToHex(raw, .lower) };
    result.manifest = try model.parse(model.Manifest, a, try result.asset("theme.json"), 65536);
    try result.manifest.validate();
    if (result.manifest.palettes.dark) |p| result.dark = try model.palette(a, try result.asset(p));
    if (result.manifest.palettes.light) |p| result.light = try model.palette(a, try result.asset(p));
    const assets = @import("assets.zig");
    var images: std.ArrayList(assets.Image) = .empty;
    var blobs: std.ArrayList(assets.Blob) = .empty;
    for (result.manifest.images) |declaration| {
        const image = try assets.validate(a, declaration.id, try result.asset(declaration.path));
        try images.append(a, image.image);
        try blobs.append(a, image.blob);
        try assets.bounds(images.items);
    }
    result.images = images.items;
    result.blobs = blobs.items;
    const profiles = @import("matugen_profiles.zig");
    var descriptors: std.ArrayList(profiles.Descriptor) = .empty;
    for (result.manifest.profiles) |path_| {
        const descriptor = try model.parse(profiles.Descriptor, a, try result.asset(path_), 16384);
        try descriptor.validate();
        for (descriptors.items) |old| if (std.mem.eql(u8, old.id, descriptor.id)) return error.DuplicateThemeProfile;
        for (descriptor.templates) |template| try profiles.template(try result.asset(template.path));
        try descriptors.append(a, descriptor);
    }
    result.profiles = descriptors.items;
    for (result.manifest.defaults) |assignment| {
        var found = false;
        for (result.profiles) |profile| if (std.mem.eql(u8, profile.id, assignment.profile) and std.mem.eql(u8, @tagName(profile.application), assignment.application)) {
            found = true;
        };
        if (!found) return error.ThemeDefaultProfileMissing;
    }
    if (result.manifest.render_data) |data| {
        if (data.dark) |p| try @import("render_data.zig").validate(a, try result.asset(p), "dark", result.dark.?);
        if (data.light) |p| try @import("render_data.zig").validate(a, try result.asset(p), "light", result.light.?);
    }
    if (result.manifest.style) |style| {
        if (style.tokens) |p| result.tokens = try model.parse(styles.Tokens, a, try result.asset(p), 65536);
        try result.tokens.validate();
        if (style.css) |p| result.css = try styles.compileFilesWithImages(a, result.files, p, result.images);
    }
    return result;
}
fn scan(a: std.mem.Allocator, fd: c_int, prefix: []const u8, files: *std.ArrayList(File), total: *usize, entries: *usize, depth: usize) anyerror!void {
    if (depth > 8) return error.ThemeDirectoryDepth;
    const copy = c.openat(fd, ".", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (copy < 0) return error.ThemeDirectory;
    const dir = c.fdopendir(copy) orelse {
        _ = c.close(copy);
        return error.ThemeDirectory;
    };
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |item| {
        const name = std.mem.sliceTo(item.*.d_name[0..], 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        entries.* += 1;
        if (entries.* > model.max_entries) return error.ThemeEntryLimit;
        const z = try a.dupeZ(u8, name);
        const path = if (prefix.len == 0) try a.dupe(u8, name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, name });
        try model.relative(path);
        var info: c.struct_stat = undefined;
        if (c.fstatat(fd, z, &info, c.AT_SYMLINK_NOFOLLOW) != 0) return error.ThemeFile;
        if (info.st_mode & c.S_IFMT == c.S_IFDIR) {
            const next = c.openat(fd, z, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
            if (next < 0) return error.ThemeDirectory;
            defer _ = c.close(next);
            try scan(a, next, path, files, total, entries, depth + 1);
        } else {
            if (info.st_mode & c.S_IFMT != c.S_IFREG) return error.ThemeSpecialFile;
            const bytes = try read(a, fd, name, model.max_bytes - total.*);
            total.* += bytes.len;
            try files.append(a, .{ .path = path, .bytes = bytes });
        }
    }
}
