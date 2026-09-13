const std = @import("std");
pub const Security = enum { open, psk, sae, advanced };
pub fn security(flags: u32, wpa: u32, rsn: u32) Security {
    const bits = wpa | rsn;
    if (bits & 0x100 != 0) return .psk;
    if (bits & 0x400 != 0) return .sae;
    if (bits != 0 or flags & 1 != 0) return .advanced;
    return .open;
}
pub fn password(value: []const u8, kind: Security) bool {
    if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return false;
    if (kind == .sae) return value.len >= 1 and value.len <= 63;
    if (kind != .psk) return false;
    if (value.len >= 8 and value.len <= 63) return true;
    if (value.len != 64) return false;
    for (value) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}
pub fn passkey(value: []const u8) ?u32 {
    if (value.len == 0 or value.len > 6) return null;
    for (value) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, value, 10) catch null;
}
pub fn pin(value: []const u8) bool {
    if (value.len == 0 or value.len > 16) return false;
    for (value) |c| if (c < 32 or c > 126) return false;
    return true;
}
pub fn ssidLabel(bytes: []const u8, output: []u8) []const u8 {
    if (bytes.len > 0 and bytes.len <= 32 and std.unicode.utf8ValidateSlice(bytes)) {
        var clean = true;
        for (bytes) |c| if (c < 32 or c == 127) {
            clean = false;
        };
        if (clean) {
            @memcpy(output[0..bytes.len], bytes);
            return output[0..bytes.len];
        }
    }
    if (bytes.len == 0) return "Hidden network · use network editor";
    var pos: usize = 0;
    for (bytes[0..@min(32, bytes.len)]) |b| {
        const pair = std.fmt.bufPrint(output[pos..], "{x:0>2}", .{b}) catch break;
        pos += pair.len;
    }
    return output[0..pos];
}
test "Wi-Fi security does not downgrade enterprise or WEP to open" {
    const t = std.testing;
    try t.expectEqual(Security.advanced, security(1, 0, 0));
    try t.expectEqual(Security.advanced, security(1, 0, 0x200));
    try t.expectEqual(Security.sae, security(1, 0, 0x400));
    try t.expectEqual(Security.psk, security(1, 0, 0x500));
    try t.expectEqual(Security.open, security(0, 0, 0));
}
test "passwords, PINs and passkeys validate without retaining inputs" {
    const t = std.testing;
    try t.expect(!password("short", .psk));
    try t.expect(password("abcdefgh", .psk));
    try t.expect(password("a" ** 64, .psk));
    try t.expect(!password("z" ** 64, .psk));
    try t.expect(password("x", .sae));
    try t.expectEqual(@as(?u32, 42), passkey("000042"));
    try t.expect(passkey("-1") == null and passkey("1000000") == null);
    try t.expect(pin("000042") and !pin("line\nbreak"));
}
test "binary and control-containing SSIDs receive safe deterministic labels" {
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("610062", ssidLabel("a\x00b", &out));
    try std.testing.expectEqualStrings("cafe", ssidLabel("cafe", &out));
}
