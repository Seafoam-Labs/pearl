//! OpenAI-compatible embeddings against the owned loopback runtime. Vectors
//! are validated (finite, non-zero, exact width) because the model card warns
//! that unsupported precision degrades embeddings silently instead of failing.
const std = @import("std");
const gio = @import("gio2");
const Runtime = @import("runtime.zig").Runtime;
pub const dimensions = 768;
pub const alias = "pearl-embedding";

pub fn vector(a: std.mem.Allocator, runtime: *Runtime, text: []const u8, cancel: *gio.Cancellable) ![]f32 {
    const body = try std.json.Stringify.valueAlloc(a, .{ .model = alias, .input = text }, .{});
    const bytes = try post(a, runtime, body, 15, 1024 * 1024, cancel);
    const vectors = try parse(a, bytes, 1);
    return vectors[0];
}
pub fn batch(a: std.mem.Allocator, runtime: *Runtime, inputs: []const []const u8, cancel: *gio.Cancellable) ![][]f32 {
    if (inputs.len == 0) return &.{};
    const body = try std.json.Stringify.valueAlloc(a, .{ .model = alias, .input = inputs }, .{});
    const bytes = try post(a, runtime, body, 120, 16 * 1024 * 1024, cancel);
    return parse(a, bytes, inputs.len);
}
fn post(a: std.mem.Allocator, runtime: *Runtime, body: []const u8, timeout: u16, max_bytes: usize, cancel: *gio.Cancellable) ![]const u8 {
    const response = try @import("fetch.zig").request(a, .{ .url = try std.fmt.allocPrint(a, "{s}/v1/embeddings", .{runtime.base}), .headers = &.{ runtime.authorization, "Content-Type: application/json" }, .body = body, .private_endpoint = true, .timeout_seconds = timeout, .max_bytes = max_bytes, .monitor = .{ .context = runtime, .check = Runtime.monitorCallback } }, cancel);
    if (response.status != 200) return error.EmbeddingFailed;
    return response.bytes;
}
pub fn parse(a: std.mem.Allocator, bytes: []const u8, expected: usize) ![][]f32 {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    if (value != .object) return error.InvalidEmbeddingResponse;
    const data = value.object.get("data") orelse return error.InvalidEmbeddingResponse;
    if (data != .array or data.array.items.len != expected) return error.InvalidEmbeddingResponse;
    const result = try a.alloc([]f32, expected);
    @memset(result, &.{});
    var filled: usize = 0;
    for (data.array.items) |item| {
        if (item != .object) return error.InvalidEmbeddingResponse;
        const index = item.object.get("index") orelse return error.InvalidEmbeddingResponse;
        if (index != .integer or index.integer < 0 or index.integer >= expected) return error.InvalidEmbeddingResponse;
        const slot: usize = @intCast(index.integer);
        if (result[slot].len != 0) return error.InvalidEmbeddingResponse;
        const embedding = item.object.get("embedding") orelse return error.InvalidEmbeddingResponse;
        if (embedding != .array or embedding.array.items.len != dimensions) return error.InvalidEmbeddingResponse;
        const vec = try a.alloc(f32, dimensions);
        for (embedding.array.items, 0..) |component, i| {
            const number: f64 = switch (component) {
                .float => |f| f,
                .integer => |n| @floatFromInt(n),
                .number_string => |s| std.fmt.parseFloat(f64, s) catch return error.InvalidEmbeddingResponse,
                else => return error.InvalidEmbeddingResponse,
            };
            if (!std.math.isFinite(number)) return error.InvalidEmbeddingResponse;
            vec[i] = @floatCast(number);
        }
        result[slot] = vec;
        filled += 1;
    }
    if (filled != expected) return error.InvalidEmbeddingResponse;
    for (result) |vec| {
        var norm: f64 = 0;
        for (vec) |component| norm += @as(f64, component) * component;
        if (!(norm > 0)) return error.InvalidEmbeddingResponse;
    }
    return result;
}
/// Matryoshka truncation keeps the leading dimensions and MUST renormalize:
/// a sliced unit vector is no longer unit length, and skipping this silently
/// degrades ranking quality (EmbeddingGemma 2 model card).
pub fn reduce(vec: []f32, dims: usize) !void {
    if (dims == 0 or dims > vec.len) return error.InvalidEmbeddingDimension;
    var norm: f64 = 0;
    for (vec[0..dims]) |component| norm += @as(f64, component) * component;
    if (!(norm > 0) or !std.math.isFinite(norm)) return error.ZeroEmbedding;
    const scale: f32 = @floatCast(1 / @sqrt(norm));
    for (vec[0..dims]) |*component| component.* *= scale;
}
test "MRL truncation renormalizes and rejects degenerate vectors" {
    var vec = [_]f32{ 3, 4, 0, 0 };
    try reduce(&vec, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), vec[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), vec[1], 1e-6);
    var zero = [_]f32{ 0, 0, 1 };
    try std.testing.expectError(error.ZeroEmbedding, reduce(&zero, 2));
    try std.testing.expectError(error.InvalidEmbeddingDimension, reduce(&zero, 4));
    try std.testing.expectError(error.InvalidEmbeddingDimension, reduce(&zero, 0));
}
test "embedding responses require exact width, order and finite values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wide: std.ArrayList(u8) = .empty;
    try wide.appendSlice(a, "{\"data\":[{\"index\":0,\"embedding\":[");
    for (0..dimensions) |i| try wide.appendSlice(a, if (i == 0) "0.5" else ",0.5");
    try wide.appendSlice(a, "]}]}");
    const parsed = try parse(a, wide.items, 1);
    try std.testing.expectEqual(@as(usize, dimensions), parsed[0].len);
    try std.testing.expectError(error.InvalidEmbeddingResponse, parse(a, "{\"data\":[{\"index\":0,\"embedding\":[0.5]}]}", 1));
    try std.testing.expectError(error.InvalidEmbeddingResponse, parse(a, "{\"data\":[]}", 1));
    try std.testing.expectError(error.InvalidEmbeddingResponse, parse(a, "{\"data\":[{\"index\":1,\"embedding\":[0.5]}]}", 1));
    var nan: std.ArrayList(u8) = .empty;
    try nan.appendSlice(a, "{\"data\":[{\"index\":0,\"embedding\":[");
    for (0..dimensions) |i| try nan.appendSlice(a, if (i == 0) "\"nan\"" else ",0.5");
    try nan.appendSlice(a, "]}]}");
    try std.testing.expectError(error.InvalidEmbeddingResponse, parse(a, nan.items, 1));
}
