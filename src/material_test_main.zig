//! Private-XDG integration driver; never installed.
const std = @import("std");
const glib = @import("glib2");
const gio = @import("gio2");
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.PreferencesRequired;
    const p = try @import("config/preferences.zig").parse(a, args[1]);
    const config = std.mem.span(glib.getUserConfigDir());
    const root = try std.fmt.allocPrint(a, "{s}/pearl", .{config});
    const scratch = try std.fmt.allocPrintSentinel(a, "{s}/pearl/matugen", .{std.mem.span(glib.getUserCacheDir())}, 0);
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    const apps = @import("theme/application_profiles.zig");
    const provider = @import("theme/theme_provider.zig");
    var context: @import("theme/generator.zig").Context = .{};
    var snapshot = if (p.matugen.snapshot_digest.len > 0) try apps.load(a, root, p.matugen.snapshot_digest) else try provider.capture(a, p, null, null, cancel, scratch, &context);
    if (p.matugen.snapshot_digest.len > 0) try provider.refreshColors(a, &snapshot, p, null, null, cancel, scratch, &context);
    const status = try apps.reconcileGuarded(a, config, p.matugen.enabled, snapshot, cancel, &context, .{});
    const digest = try apps.save(a, root, snapshot);
    const text = try std.json.Stringify.valueAlloc(a, .{ .status = status, .snapshot = digest, .captured = snapshot }, .{});
    glib.print("%s\n", (try a.dupeZ(u8, text)).ptr);
}
