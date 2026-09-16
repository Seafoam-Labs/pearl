//! Private integration driver; never installed by distribution packaging.
const std = @import("std");
const glib = @import("glib2");
const gio = @import("gio2");
const io = @import("config/io.zig");
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = std.mem.span(glib.getUserConfigDir());
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    const file = try io.read(a, try std.fmt.allocPrintSentinel(a, "{s}/preferences.json", .{root}, 0), 65536, cancel);
    const p = try @import("config/preferences.zig").parse(a, file.bytes);
    const palette = if (p.theme.variant == .dark) @import("theme/theme.zig").dark else @import("theme/theme.zig").light;
    if (glib.getenv("PEARL_QT_TEST_REVIEW")) |_| {
        const review = try @import("config/qt_integration.zig").review(a, root, cancel);
        glib.print("%s\n", (try a.dupeZ(u8, try std.json.Stringify.valueAlloc(a, .{ .digest = review.digest[0..], .text = review.text }, .{}))).ptr);
        return;
    }
    const reviewed: ?[64]u8 = if (glib.getenv("PEARL_QT_TEST_REAPPLY")) |raw| blk: {
        const value = std.mem.span(raw);
        if (value.len != 64) return error.InvalidDigest;
        break :blk value[0..64].*;
    } else null;
    const status = try @import("config/qt_integration.zig").reconcile(a, root, p, palette, cancel, reviewed);
    glib.print("%s\n", (try a.dupeZ(u8, try std.json.Stringify.valueAlloc(a, status, .{}))).ptr);
}
