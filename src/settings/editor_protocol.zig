//! Shared, strictly typed Pearl editor messages. No GTK or backend authority.
const std = @import("std");
const e = @import("../aqueous/entities.zig");
const nav = @import("../desktop/settings_navigation.zig");
pub const Number = struct {
    value: u64,
    pub fn jsonStringify(self: Number, writer: *std.json.Stringify) !void {
        var buf: [20]u8 = undefined;
        try writer.write(std.fmt.bufPrint(&buf, "{d}", .{self.value}) catch unreachable);
    }
};
pub fn num(value: u64) Number {
    return .{ .value = value };
}
pub fn number(value: []const u8) !u64 {
    try e.decimal(value);
    return std.fmt.parseInt(u64, value, 10);
}
pub fn fields(comptime T: type, a: std.mem.Allocator, value: std.json.Value) !T {
    if (value != .object) return error.InvalidRequest;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, entry.key_ptr.*)) {
                if (entry.value_ptr.* == .null) return error.InvalidRequest;
                break;
            }
        } else return error.InvalidRequest;
    }
    return e.read(T, a, value) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidRequest;
}
pub const Domain = enum { pearl, aqueous };
pub const Enter = struct { page: nav.Route, section: ?[]const u8 = null };
pub const Leave = struct { view: []const u8 };
pub const GetPage = struct { view: []const u8, revision: ?[]const u8 = null };
pub const GetDocument = struct { domain: Domain, kind: enum { committed, draft, base, review, report, preview }, revision: []const u8 };
pub const ReadDocument = struct { transfer: []const u8, offset: []const u8 };
pub const BeginDocument = struct { domain: Domain, expected_draft_revision: []const u8, base_revision: []const u8, bytes: []const u8, sha256: []const u8 };
pub const WriteDocument = struct { transfer: []const u8, offset: []const u8, text: []const u8 };
pub const FinishDocument = struct { transfer: []const u8, operation: []const u8 };
pub const CancelDocument = struct { transfer: []const u8 };
pub const DraftAction = struct { domain: Domain, expected_draft_revision: []const u8, operation: []const u8 };
pub const ApplyDraft = struct { domain: Domain, expected_draft_revision: []const u8, base_revision: []const u8, operation: []const u8 };
pub const GetOperation = struct { operation: []const u8 };
pub const Close = struct { last_draft_revision: ?[]const u8 = null };
pub fn digest(bytes: []const u8) [64]u8 {
    var bytes_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &bytes_hash, .{});
    return std.fmt.bytesToHex(bytes_hash, .lower);
}
pub fn hash(value: []const u8) ![64]u8 {
    if (value.len != 64) return error.InvalidDigest;
    for (value) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.InvalidDigest;
    return value[0..64].*;
}
/// Snapshot metadata is independent of page, so one shared draft badge/footer
/// remains available while the user visits another category.
pub const Snapshot = struct {
    revision: []const u8,
    draft_revision: []const u8,
    base_revision: []const u8,
    dirty: bool,
    valid: bool,
    validation: ?[]const u8,
    conflict: bool,
    busy: bool,
    error_code: ?[]const u8,
    export_error: ?[]const u8,
    locked: bool,
};

test "editor params reject extra fields, nulls and lossy counters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"page\":\"appearance\"}", .{});
    try std.testing.expectEqual(nav.Route.appearance, (try fields(Enter, a, v)).page);
    for ([_][]const u8{ "{\"page\":\"appearance\",\"section\":null}", "{\"page\":\"appearance\",\"extra\":true}" }) |text|
        try std.testing.expectError(error.InvalidRequest, fields(Enter, a, try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{})));
    try std.testing.expectEqual(std.math.maxInt(u64), try number("18446744073709551615"));
    try std.testing.expectError(error.InvalidDecimal, number("18446744073709551616"));
}
