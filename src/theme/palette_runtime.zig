//! Latest accepted editable colors, bound to committed selection and style.
const std = @import("std");
const io = @import("../config/io.zig");
const prefs = @import("../config/preferences.zig");
const model = @import("package_model.zig");
pub const Record = struct {
    compiler: u32 = @import("palette_model.zig").compiler_version,
    selection: []const u8,
    source: @import("palette_model.zig").Source,
    custom: @import("resolve.zig").Resolved,
};
pub fn key(a: std.mem.Allocator, p: prefs.Theme) ![]const u8 {
    return a.dupe(u8, &model.hash(try std.json.Stringify.valueAlloc(a, .{ .mode = p.mode, .variant = p.variant, .package = p.package_id, .palette = p.palette_id, .style = p.style_id }, .{})));
}
pub fn load(a: std.mem.Allocator, dir: []const u8, p: prefs.Theme) !?Record {
    const saved = try io.read(a, try std.fmt.allocPrintSentinel(a, "{s}/local-palette-runtime.json", .{dir}, 0), 131072, null);
    if (saved.missing) return null;
    const envelope = try model.parse(struct { bytes: []const u8, digest: []const u8 }, a, saved.bytes, 131072);
    if (!std.mem.eql(u8, envelope.digest, &model.hash(envelope.bytes))) return error.ThemeSnapshotCorrupt;
    const record = try model.parse(Record, a, envelope.bytes, 131072);
    if (record.compiler != @import("palette_model.zig").compiler_version or !std.mem.eql(u8, record.selection, try key(a, p))) return null;
    return record;
}
pub fn save(a: std.mem.Allocator, dir: []const u8, p: prefs.Theme, source: @import("palette_model.zig").Source, custom: @import("resolve.zig").Resolved) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, Record{ .selection = try key(a, p), .source = source, .custom = custom }, .{});
    const envelope = try std.json.Stringify.valueAlloc(a, .{ .bytes = bytes, .digest = model.hash(bytes)[0..] }, .{});
    if (envelope.len > 131072) return error.ThemeSnapshotLimit;
    try io.atomic(try std.fmt.allocPrintSentinel(a, "{s}/local-palette-runtime.json", .{dir}, 0), envelope, false);
}
