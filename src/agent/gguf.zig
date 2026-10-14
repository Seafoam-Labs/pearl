//! Read only bounded metadata; inference remains the external runtime's job.
const std = @import("std");
const Reader = struct {
    fd: c_int,
    offset: u64 = 0,
    fn bytes(self: *Reader, out: []u8) !void {
        if (self.offset + out.len > 32 * 1024 * 1024) return error.ModelMetadataTooLarge;
        var n: usize = 0;
        while (n < out.len) {
            const got = std.c.read(self.fd, out[n..].ptr, out.len - n);
            if (got <= 0) return error.InvalidModelMetadata;
            n += @intCast(got);
        }
        self.offset += out.len;
    }
    fn uint(self: *Reader, comptime T: type) !T {
        var data: [@sizeOf(T)]u8 = undefined;
        try self.bytes(&data);
        return std.mem.readInt(T, &data, .little);
    }
    fn skip(self: *Reader, n: u64) !void {
        if (n > 32 * 1024 * 1024 or self.offset + n > 32 * 1024 * 1024) return error.ModelMetadataTooLarge;
        if (std.c.lseek(self.fd, @intCast(n), std.c.SEEK.CUR) < 0) return error.InvalidModelMetadata;
        self.offset += n;
    }
    fn value(self: *Reader, kind: u32, depth: u8) !void {
        switch (kind) {
            0, 1, 7 => try self.skip(1),
            2, 3 => try self.skip(2),
            4, 5, 6 => try self.skip(4),
            10, 11, 12 => try self.skip(8),
            8 => try self.skip(try self.uint(u64)),
            9 => {
                if (depth != 0) return error.InvalidModelMetadata;
                const child = try self.uint(u32);
                const count = try self.uint(u64);
                if (count > 1000000) return error.ModelMetadataTooLarge;
                for (0..@intCast(count)) |_| try self.value(child, 1);
            },
            else => return error.InvalidModelMetadata,
        }
    }
};
pub fn layers(path: [:0]const u8) !u16 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.ModelNotInstalled;
    defer _ = std.c.close(fd);
    var reader: Reader = .{ .fd = fd };
    if (try reader.uint(u32) != 0x46554747 or try reader.uint(u32) != 3) return error.InvalidModelMetadata;
    _ = try reader.uint(u64);
    const count = try reader.uint(u64);
    if (count > 100000) return error.ModelMetadataTooLarge;
    for (0..@intCast(count)) |_| {
        const len = try reader.uint(u64);
        if (len > 512) return error.InvalidModelMetadata;
        var key: [512]u8 = undefined;
        try reader.bytes(key[0..@intCast(len)]);
        const kind = try reader.uint(u32);
        if (std.mem.endsWith(u8, key[0..@intCast(len)], ".block_count") and kind == 4) {
            const n = try reader.uint(u32);
            if (n == 0 or n >= 1024) return error.InvalidModelMetadata;
            return @intCast(n + 1); // include the output layer
        }
        try reader.value(kind, 0);
    }
    return error.ModelLayerCountUnavailable;
}
