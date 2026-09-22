//! Rotates the wallpaper through a folder on a timer by committing preferences.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const policy = @import("slideshow_policy.zig");
const Service = @import("service.zig").Service;
const a = std.heap.c_allocator;
/// Upper bound on directory entries considered per rotation.
const max_entries = 4096;

pub const Engine = struct {
    service: *Service,
    timer: c_uint = 0,
    armed: bool = false,
    armed_interval: u32 = 0,

    /// Re-arms only when the enabled state or interval actually changed.
    pub fn configure(self: *Engine) void {
        const config = self.service.prefs().wallpaper.slideshow;
        const wanted = config.enabled and config.folder.len != 0;
        if (self.timer != 0 and wanted == self.armed and config.interval_seconds == self.armed_interval) return;
        self.stop();
        self.armed = wanted;
        self.armed_interval = config.interval_seconds;
        if (wanted) self.arm(config.interval_seconds);
    }
    pub fn stop(self: *Engine) void {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.timer = 0;
    }
    fn arm(self: *Engine, seconds: u32) void {
        self.timer = glib.timeoutAddSeconds(@max(1, seconds), tick, self);
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Engine = @ptrCast(@alignCast(data.?));
        self.timer = 0;
        self.advance();
        // A rejected commit (busy service, stale revision) waits for the next
        // interval instead of retrying in a tight loop.
        const config = self.service.prefs().wallpaper.slideshow;
        if (config.enabled and config.folder.len != 0) self.arm(config.interval_seconds);
        return 0;
    }
    fn advance(self: *Engine) void {
        const service = self.service;
        var prefs = service.prefs();
        const config = prefs.wallpaper.slideshow;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const names = listImages(alloc, config.folder) catch return;
        if (names.len == 0) return;
        const index = policy.next(names, std.fs.path.basename(prefs.wallpaper.path), config.order, seed());
        var buffer: [1300]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ config.folder, names[index] }) catch return;
        if (std.mem.eql(u8, prefs.wallpaper.path, path)) return;
        prefs.wallpaper.path = path;
        if (prefs.wallpaper.mode != .cover and prefs.wallpaper.mode != .contain) prefs.wallpaper.mode = .cover;
        prefs.validate() catch return;
        const json = std.json.Stringify.valueAlloc(alloc, prefs, .{}) catch return;
        service.apply(json, service.revision) catch {};
    }
};

/// Rotations are seconds apart, so the monotonic clock alone is enough entropy;
/// the counter covers two rotations landing on the same microsecond.
var counter: u64 = 0;
fn seed() u64 {
    counter +%= 1;
    const ticks: u64 = @bitCast(glib.getMonotonicTime());
    return (ticks *% 6364136223846793005) ^ counter;
}

/// First eligible image in `folder`. The settings form uses it to seed a
/// wallpaper path when a folder is chosen and nothing is selected yet.
pub fn firstImage(alloc: std.mem.Allocator, folder: []const u8) ?[:0]u8 {
    const names = listImages(alloc, folder) catch return null;
    if (names.len == 0) return null;
    var buffer: [1300]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buffer, "{s}/{s}", .{ folder, names[0] }) catch return null;
    return alloc.dupeZ(u8, path) catch null;
}

/// Sorted, decodable image basenames in `folder`. An unreadable directory yields
/// an error the caller drops; the timer simply retries on the next interval.
pub fn listImages(alloc: std.mem.Allocator, folder: []const u8) ![][]const u8 {
    const z = try alloc.dupeZ(u8, folder);
    const root = gio.File.newForPath(z);
    defer root.unref();
    var failure: ?*glib.Error = null;
    defer if (failure) |e| e.free();
    const enumerator = root.enumerateChildren("standard::name,standard::type", .{ .nofollow_symlinks = true }, null, &failure) orelse return error.Unavailable;
    defer enumerator.unref();
    var names: std.ArrayList([]const u8) = .empty;
    while (names.items.len < max_entries) {
        const info = enumerator.nextFile(null, &failure) orelse break;
        defer info.unref();
        if (failure) |e| {
            e.free();
            failure = null;
        }
        if (info.getFileType() != .regular) continue;
        const name = std.mem.span(info.getName());
        if (!policy.eligible(name)) continue;
        try names.append(alloc, try alloc.dupe(u8, name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}
