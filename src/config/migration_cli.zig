//! Offline dry-run import. A bundle is a new private directory, never a live config.
const std = @import("std");
const glib = @import("glib2");
const io = @import("io.zig");
const prefs = @import("preferences.zig");
pub fn file(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    const result = try io.read(alloc, try alloc.dupeZ(u8, path), prefs.max_bytes, null);
    if (result.missing) return error.FileNotFound;
    return result.bytes;
}
pub fn run(alloc: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "dms")) return error.Usage;
    var input: ?[]const u8 = null;
    var session: ?[]const u8 = null;
    var base: ?[]const u8 = null;
    var bundle: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.Usage;
        if (std.mem.eql(u8, args[i], "--input") and input == null) input = args[i + 1] else if (std.mem.eql(u8, args[i], "--session-file") and session == null) session = args[i + 1] else if (std.mem.eql(u8, args[i], "--base") and base == null) base = args[i + 1] else if (std.mem.eql(u8, args[i], "--bundle") and bundle == null) bundle = args[i + 1] else return error.Usage;
    }
    const source = try file(alloc, input orelse return error.Usage);
    const old = if (base) |path| try file(alloc, path) else "{}";
    const state = if (session) |path| try file(alloc, path) else null;
    const report = try @import("dms_import.zig").plan(alloc, source, state, try prefs.parse(alloc, old));
    const bytes = try std.json.Stringify.valueAlloc(alloc, .{ .format = report.format, .dry_run = true, .source_sha256 = io.digest(source), .session_sha256 = if (state) |value| @as(?[64]u8, io.digest(value)) else null, .base_sha256 = io.digest(old), .preferences = report.preferences, .mapped = report.mapped.items, .unsupported = report.unsupported.items, .notes = report.notes.items }, .{ .whitespace = .indent_2 });
    if (bundle) |directory| {
        const dir = try alloc.dupeZ(u8, directory);
        if (std.c.mkdir(dir, 0o700) != 0) return error.BundleMustBeNewDirectory;
        // Publishing report.json last marks a complete bundle. Partial failures
        // leave a private directory for inspection; they never touch source files.
        try io.atomic(try std.fmt.allocPrintSentinel(alloc, "{s}/previous.json", .{directory}, 0), old, true);
        try io.atomic(try std.fmt.allocPrintSentinel(alloc, "{s}/preferences.json", .{directory}, 0), try std.json.Stringify.valueAlloc(alloc, report.preferences, .{ .whitespace = .indent_2 }), true);
        try io.atomic(try std.fmt.allocPrintSentinel(alloc, "{s}/report.json", .{directory}, 0), bytes, true);
    }
    const output = try alloc.dupeZ(u8, bytes);
    glib.print("%s\n", output.ptr);
}
