//! Shared response framing: the byte budget includes the final newline.
const std = @import("std");
pub const max_frame = 8192;
const prefix = "{\"pearl\":1,\"id\":\"";
const middle = "\",\"ok\":true,\"result\":";
const suffix = "}\n";
pub fn successLength(id: []const u8, result: []const u8) usize {
    return prefix.len + id.len + middle.len + result.len + suffix.len;
}
pub fn success(allocator: std.mem.Allocator, id: []const u8, result: []const u8) ![]u8 {
    if (successLength(id, result) > max_frame) return error.ResponseTooLarge;
    // The protocol has already restricted IDs to at most 20 decimal digits.
    return std.mem.concat(allocator, u8, &.{ prefix, id, middle, result, suffix });
}
