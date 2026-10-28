//! Compile-time repeated strings for boundary and parser fixtures.
pub fn string(comptime value: []const u8, comptime count: usize) *const [value.len * count:0]u8 {
    const result = comptime blk: {
        var bytes: [value.len * count:0]u8 = undefined;
        if (bytes.len != 0) {
            @memcpy(bytes[0..value.len], value);
            var filled = value.len;
            while (filled < bytes.len) {
                const amount = @min(filled, bytes.len - filled);
                @memcpy(bytes[filled..][0..amount], bytes[0..amount]);
                filled += amount;
            }
        }
        bytes[bytes.len] = 0;
        break :blk bytes;
    };
    return &result;
}
