//! Native, appearance-only privileged writer. User paths never cross this boundary.
const std = @import("std");
const glib = @import("glib2");
const cfg = @import("config.zig");
const trusted = @import("trusted.zig");
const a = std.heap.c_allocator;
extern "c" fn flock(c_int, c_int) c_int;
pub const max_image = 16 * 1024 * 1024;
pub const max_request = 23 * 1024 * 1024;
pub const Request = struct {
    theme: @FieldType(cfg.Config, "theme"),
    gtk_theme: ?[]const u8 = null,
    wallpaper_fit: @FieldType(cfg.Config, "wallpaper_fit") = .cover,
    wallpaper_color: ?[]const u8 = null,
    image: ?[]const u8 = null,
};
pub fn read(fd: c_int, limit: usize) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) break;
        if (bytes.items.len + @as(usize, @intCast(n)) > limit) return error.TooLarge;
        try bytes.appendSlice(a, chunk[0..@intCast(n)]);
    }
    return bytes.toOwnedSlice(a);
}
pub fn apply(directory: []const u8, bytes: []const u8) !void {
    if (bytes.len > max_request) return error.TooLarge;
    const parsed = try std.json.parseFromSlice(Request, a, bytes, .{ .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    const request = parsed.value;
    const appearance: cfg.Config = .{ .theme = request.theme, .gtk_theme = request.gtk_theme, .wallpaper_fit = request.wallpaper_fit, .wallpaper_color = request.wallpaper_color };
    try appearance.validate();
    if (request.gtk_theme) |name| {
        if (name.len == 0 or name.len > 96) return error.InvalidTheme;
        for (name) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, " _:.+-", c) == null) return error.InvalidTheme;
        const base = name[0..(std.mem.indexOfScalar(u8, name, ':') orelse name.len)];
        var builtin = false;
        for ([_][]const u8{ "Adwaita", "Default", "HighContrast", "HighContrastInverse" }) |item| if (std.mem.eql(u8, base, item)) {
            builtin = true;
        };
        if (!builtin) {
            const path = try std.fmt.allocPrint(a, "/usr/share/themes/{s}/gtk-4.0/gtk.css", .{base});
            defer a.free(path);
            const theme_fd = trusted.open(path, false) catch return error.SystemThemeRequired;
            _ = std.c.close(theme_fd);
        }
    }
    var image: ?[]u8 = null;
    defer if (image) |data| a.free(data);
    if (request.image) |encoded| {
        const length = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
        if (length > max_image) return error.TooLarge;
        image = try a.alloc(u8, length);
        try std.base64.standard.Decoder.decode(image.?, encoded);
        if (!std.mem.startsWith(u8, image.?, "\x89PNG\r\n\x1a\n") or !@import("../services/artwork.zig").dimensions(image.?)) return error.InvalidImage;
    }
    const dir = try trusted.open(directory, true);
    defer _ = std.c.close(dir);
    const lock = std.c.openat(dir, ".greeter-appearance.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c_uint, 0o600));
    if (lock < 0) return error.LockFailed;
    defer _ = std.c.close(lock);
    if (flock(lock, 2) != 0) return error.LockFailed;
    const path = try std.fmt.allocPrint(a, "{s}/greeter.json", .{directory});
    defer a.free(path);
    const current = try trusted.read(a, path, 65536);
    defer a.free(current);
    const validated = try std.json.parseFromSlice(cfg.Config, a, current, .{ .duplicate_field_behavior = .@"error" });
    defer validated.deinit();
    try validated.value.validate();
    var document = try std.json.parseFromSlice(std.json.Value, a, current, .{ .allocate = .alloc_always });
    defer document.deinit();
    const alloc = document.arena.allocator();
    const map = &document.value.object;
    try map.put(alloc, "theme", .{ .string = @tagName(request.theme) });
    try map.put(alloc, "gtk_theme", if (request.gtk_theme) |name| .{ .string = name } else .null);
    try map.put(alloc, "wallpaper_fit", .{ .string = @tagName(request.wallpaper_fit) });
    try map.put(alloc, "wallpaper_color", if (request.wallpaper_color) |color| .{ .string = color } else .null);
    var image_path: ?[]u8 = null;
    defer if (image_path) |value| a.free(value);
    if (image) |data| {
        const assets_path = try std.fmt.allocPrint(a, "{s}/greeter-assets", .{directory});
        defer a.free(assets_path);
        if (std.c.mkdirat(dir, "greeter-assets", 0o755) != 0 and std.posix.errno(-1) != .EXIST) return error.WriteFailed;
        const assets = try trusted.open(assets_path, true);
        defer _ = std.c.close(assets);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const name = try std.fmt.allocPrintSentinel(a, "{s}.png", .{hex}, 0);
        defer a.free(name);
        try atomicWrite(assets, name, data);
        image_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ assets_path, name });
    }
    try map.put(alloc, "wallpaper", if (image_path) |value| .{ .string = value } else .null);
    const updated = try std.json.Stringify.valueAlloc(a, document.value, .{ .whitespace = .indent_2 });
    defer a.free(updated);
    if (updated.len > 65536) return error.TooLarge;
    try atomicWrite(dir, "greeter.json", updated);
}
fn atomicWrite(dir: c_int, name: [*:0]const u8, bytes: []const u8) !void {
    const random = glib.uuidStringRandom();
    defer glib.free(random);
    const temp = try std.fmt.allocPrintSentinel(a, ".appearance-{s}", .{std.mem.span(random)}, 0);
    defer a.free(temp);
    const fd = std.c.openat(dir, temp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c_uint, 0o600));
    if (fd < 0) return error.WriteFailed;
    defer _ = std.c.close(fd);
    defer _ = std.c.unlinkat(dir, temp, 0);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return error.WriteFailed;
        offset += @intCast(n);
    }
    if (std.c.fchmod(fd, 0o644) != 0 or std.c.fsync(fd) != 0) return error.WriteFailed;
    if (std.c.renameat(dir, temp, dir, name) != 0) return error.WriteFailed;
    _ = std.c.fsync(dir);
}
