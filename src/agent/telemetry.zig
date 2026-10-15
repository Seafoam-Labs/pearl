//! Optional runtime observations. Missing counters remain unavailable.
const std = @import("std");
const glib = @import("glib2");
const fields = @import("providers.zig");
const memory = @import("memory.zig");
pub const Tokens = struct {
    prompt: ?u64 = null,
    generated: ?u64 = null,
    reasoning: ?u64 = null,
    prompt_ms: ?f64 = null,
    generation_ms: ?f64 = null,
    requests: u32 = 0,
    reported_requests: u32 = 0,
    timed_requests: u32 = 0,
    pub fn parse(self: *Tokens, value: std.json.Value) void {
        if (fields.field(value, "timings")) |timings| {
            if (integer(timings, "prompt_n")) |n| self.prompt = n;
            if (integer(timings, "predicted_n")) |n| self.generated = n;
            if (number(timings, "prompt_ms")) |n| self.prompt_ms = n;
            if (number(timings, "predicted_ms")) |n| self.generation_ms = n;
        }
        if (fields.field(value, "usage")) |usage| {
            if (integer(usage, "prompt_tokens")) |n| self.prompt = n;
            if (integer(usage, "completion_tokens")) |n| self.generated = n;
            if (fields.field(usage, "completion_tokens_details")) |details| {
                if (integer(details, "reasoning_tokens")) |n| self.reasoning = n;
            }
        }
    }
    pub fn add(self: *Tokens, other: Tokens) void {
        self.requests += 1;
        if (other.prompt != null or other.generated != null) self.reported_requests += 1;
        if (other.prompt_ms != null and other.generation_ms != null) self.timed_requests += 1;
        inline for (.{ "prompt", "generated", "reasoning", "prompt_ms", "generation_ms" }) |field| {
            if (@field(other, field)) |n| @field(self, field) = (@field(self, field) orelse 0) + n;
        }
    }
    pub fn rate(self: Tokens, prompt: bool) ?f64 {
        if (self.requests == 0 or self.reported_requests != self.requests or self.timed_requests != self.requests) return null;
        const count = (if (prompt) self.prompt else self.generated) orelse return null;
        const ms = (if (prompt) self.prompt_ms else self.generation_ms) orelse return null;
        if (ms <= 0) return null;
        return @as(f64, @floatFromInt(count)) * 1000 / ms;
    }
};
fn integer(value: std.json.Value, key: []const u8) ?u64 {
    const v = fields.field(value, key) orelse return null;
    return if (v == .integer and v.integer >= 0) @intCast(v.integer) else null;
}
fn number(value: std.json.Value, key: []const u8) ?f64 {
    const v = fields.field(value, key) orelse return null;
    const n: f64 = switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => return null,
    };
    return if (std.math.isFinite(n) and n >= 0) n else null;
}
pub const Metrics = struct {
    skip: ?*std.atomic.Value(bool) = null,
    verification_us: i64 = 0,
    load_us: i64 = 0,
    peak_rss_kib: ?u64 = null,
    high_water_kib: ?u64 = null,
    last_sample_us: i64 = 0,
    samples: u32 = 0,
    tokens: Tokens = .{},
    pub fn sample(self: *Metrics, pid: c_int) void {
        const now = glib.getMonotonicTime();
        if (pid <= 0 or now - self.last_sample_us < 100000) return;
        self.last_sample_us = now;
        const usage = processTree(pid, 0) orelse return;
        self.peak_rss_kib = @max(self.peak_rss_kib orelse 0, usage.rss);
        self.high_water_kib = @max(self.high_water_kib orelse 0, usage.hwm);
        self.samples += 1;
    }
};
const Usage = struct { rss: u64, hwm: u64 };
fn processTree(pid: c_int, depth: u8) ?Usage {
    var path: [128]u8 = undefined;
    var bytes: [8192]u8 = undefined;
    const status = memory.read(std.fmt.bufPrintZ(&path, "/proc/{d}/status", .{pid}) catch return null, &bytes) catch return null;
    var usage: Usage = .{ .rss = memory.kibField(status, "VmRSS:") orelse return null, .hwm = memory.kibField(status, "VmHWM:") orelse 0 };
    if (depth >= 16) return usage;
    const children = memory.read(std.fmt.bufPrintZ(&path, "/proc/{d}/task/{d}/children", .{ pid, pid }) catch return usage, &bytes) catch return usage;
    var tokens = std.mem.tokenizeAny(u8, children, " \n");
    while (tokens.next()) |child| {
        const id = std.fmt.parseInt(c_int, child, 10) catch continue;
        if (processTree(id, depth + 1)) |part| {
            usage.rss += part.rss;
            usage.hwm += part.hwm;
        }
    }
    return usage;
}
test "runtime timing and usage are optional and reasoning is separate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"usage":{"prompt_tokens":20,"completion_tokens":30,"completion_tokens_details":{"reasoning_tokens":22}},"timings":{"prompt_ms":2.5,"predicted_ms":100}}
    , .{});
    var tokens: Tokens = .{};
    tokens.parse(v);
    try std.testing.expectEqual(@as(?u64, 22), tokens.reasoning);
    var total: Tokens = .{};
    total.add(tokens);
    total.add(.{});
    try std.testing.expectEqual(@as(u32, 1), total.reported_requests);
    try std.testing.expectEqual(@as(u32, 2), total.requests);
    try std.testing.expectEqual(@as(?u64, 30), total.generated);
    var metrics: Metrics = .{};
    metrics.sample(std.c.getpid());
    try std.testing.expect((metrics.peak_rss_kib orelse 0) > 0);
}
