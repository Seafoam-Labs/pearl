//! Aqueous-compatible monitor identity and deterministic login-card placement.
const std = @import("std");
pub const Digest = [32]u8;
pub const Output = struct { name: ?[]const u8 = null, digest: ?Digest = null };

pub fn parseHash(value: []const u8) !Digest {
    const hex = if (std.mem.startsWith(u8, value, "sha256:")) value[7..] else value;
    if (hex.len != 64) return error.InvalidOutputEdid;
    var result: Digest = undefined;
    _ = std.fmt.hexToBytes(&result, hex) catch return error.InvalidOutputEdid;
    return result;
}

/// Matches aqueousctl's edid_sha256: SHA-256 of make|model|serial, not raw EDID.
pub fn hash(make: ?[]const u8, model: ?[]const u8, serial: ?[]const u8) ?Digest {
    if (make == null and model == null and serial == null) return null;
    var buffer: [768]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buffer, "{s}|{s}|{s}", .{ make orelse "", model orelse "", serial orelse "" }) catch return null;
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

/// EDID first, connector fallback, then compositor order. For duplicate identities,
/// prefer the configured connector, then lexical connector order.
pub fn select(outputs: []const Output, preferred: ?[]const u8, edid: ?Digest) ?usize {
    var fallback: ?usize = null;
    var match: ?usize = null;
    for (outputs, 0..) |output, i| {
        const name = output.name orelse continue;
        const connector_match = if (preferred) |wanted| std.mem.eql(u8, name, wanted) else false;
        if (connector_match) fallback = i;
        if (edid) |wanted| if (output.digest) |digest| if (std.mem.eql(u8, &wanted, &digest)) {
            if (match) |old| {
                const old_name = outputs[old].name.?;
                const old_preferred = if (preferred) |p| std.mem.eql(u8, old_name, p) else false;
                if (connector_match or (!old_preferred and std.mem.order(u8, name, old_name) == .lt)) match = i;
            } else match = i;
        };
    }
    return match orelse fallback orelse if (outputs.len > 0) @as(usize, 0) else null;
}

test "Aqueous identity compatibility and strict hash syntax" {
    const digest = hash("Acme", "Panel", "ABC123").?;
    try std.testing.expectEqual(try parseHash("sha256:daf5f59252c5a28c00c8f13b516d7ccb8afdce47b8f664ff18f3059e18f3057e"), digest);
    try std.testing.expectEqual(digest, try parseHash("DAF5F59252C5A28C00C8F13B516D7CCB8AFDCE47B8F664FF18F3059E18F3057E"));
    for ([_][]const u8{ "", "sha256:", "DP-1", "g" ** 64, "0" ** 65 }) |invalid| try std.testing.expectError(error.InvalidOutputEdid, parseHash(invalid));
    try std.testing.expect(hash(null, null, null) == null);
    try std.testing.expect(hash("x" ** 769, null, null) == null);
}

test "identity survives port changes, connector fallback and duplicate identities" {
    const wanted = hash("Acme", "Panel", "ABC123").?;
    const other = hash("Acme", "Panel", "Other").?;
    var outputs = [_]Output{
        .{ .name = "DP-1", .digest = other },
        .{ .name = "HDMI-A-1", .digest = wanted },
        .{ .name = "DP-3", .digest = wanted },
    };
    try std.testing.expectEqual(@as(?usize, 2), select(&outputs, "DP-1", wanted));
    try std.testing.expectEqual(@as(?usize, 1), select(&outputs, "HDMI-A-1", wanted));
    outputs[2].digest = null;
    try std.testing.expectEqual(@as(?usize, 1), select(&outputs, "DP-1", wanted));
    outputs[1].name = "DP-9";
    try std.testing.expectEqual(@as(?usize, 1), select(&outputs, "DP-1", wanted));
    outputs[1].digest = null;
    try std.testing.expectEqual(@as(?usize, 2), select(&outputs, "DP-3", wanted));
    try std.testing.expectEqual(@as(?usize, 0), select(&outputs, "missing", wanted));
    try std.testing.expectEqual(@as(?usize, 2), select(&outputs, "DP-3", null));
    try std.testing.expectEqual(@as(?usize, null), select(&.{}, null, wanted));
}
