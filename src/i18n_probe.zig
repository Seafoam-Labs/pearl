//! Headless package lifecycle probe, built only by the translation test targets.
const std = @import("std");
const i18n = @import("i18n");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len > 1 and std.mem.eql(u8, args[1], "system")) i18n.init(true);
    var buffer: [1024]u8 = undefined;
    var typed_buffer: [1024]u8 = undefined;
    const data = try std.json.Stringify.valueAlloc(a, .{
        .language = i18n.effectiveLanguage(),
        .session = i18n.sessionLanguages(),
        .rtl = i18n.rtl(),
        .settings = i18n.tr("Settings"),
        .fallback = i18n.tr("Untranslated probe"),
        .context = i18n.context("verb", "Open"),
        .plural = .{ i18n.ntr("One file", "Many files", 0), i18n.ntr("One file", "Many files", 1), i18n.ntr("One file", "Many files", 2), i18n.ntr("One file", "Many files", 11) },
        .formatted = i18n.message(&buffer, "Copied {count} files to {destination}", &.{ .{ .name = "count", .value = "2" }, .{ .name = "destination", .value = "/tmp" } }),
        .typed = i18n.dfmt("pearl", &typed_buffer, "Typed {d} at {s}", .{ @as(u32, 2), "/tmp" }),
        .packs = try i18n.installed(a),
    }, .{});
    try std.Io.File.stdout().writeStreamingAll(init.io, data);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    if (args.len > 1 and std.mem.eql(u8, args[1], "freeze")) {
        var input: [1]u8 = undefined;
        _ = std.c.read(0, &input, 1);
        try std.Io.File.stdout().writeStreamingAll(init.io, i18n.tr("Settings"));
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    }
}
