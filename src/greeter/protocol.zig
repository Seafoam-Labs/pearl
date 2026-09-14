//! greetd 0.10.3 framed JSON. Independent of Aqueous and PAM wire formats.
const std = @import("std");
const endian = @import("builtin").cpu.arch.endian();
pub const max_frame = 65536;
pub const Prompt = enum { visible, secret, info, @"error" };
pub const Kind = enum { success, auth_message, @"error" };
pub const ErrorType = enum { auth_error, @"error" };
pub const Response = struct {
    kind: Kind,
    prompt: Prompt = .info,
    authentication_error: bool = false,
    text: [16385:0]u8 = @splat(0),
    len: usize = 0,
    pub fn z(self: *const Response) [*:0]const u8 {
        return @ptrCast(&self.text);
    }
};
pub fn validText(s: []const u8, max: usize) bool {
    return s.len <= max and std.mem.indexOfScalar(u8, s, 0) == null and std.unicode.utf8ValidateSlice(s);
}
pub fn validateJson(bytes: []const u8, limit: usize) !void {
    if (!validText(bytes, limit)) return error.InvalidJson;
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |c| {
        if (quoted) {
            if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') quoted = false;
        } else switch (c) {
            '"' => quoted = true,
            '{', '[' => {
                depth += 1;
                if (depth > 16) return error.JsonDepth;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            else => {},
        }
    }
    if (depth != 0 or quoted) return error.InvalidJson;
}
pub fn decode(bytes: []const u8) !Response {
    try validateJson(bytes, max_frame);
    var storage: [256 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &storage);
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    const Wire = struct { type: Kind, auth_message_type: ?Prompt = null, auth_message: ?[]const u8 = null, error_type: ?ErrorType = null, description: ?[]const u8 = null };
    const p = try std.json.parseFromSlice(Wire, fba.allocator(), bytes, .{ .ignore_unknown_fields = true, .duplicate_field_behavior = .@"error", .allocate = .alloc_always });
    defer p.deinit();
    const v = p.value;
    var out: Response = .{ .kind = v.type };
    const s: []const u8 = switch (v.type) {
        .success => "",
        .auth_message => blk: {
            out.prompt = v.auth_message_type orelse return error.MissingPrompt;
            break :blk v.auth_message orelse return error.MissingPrompt;
        },
        .@"error" => blk: {
            out.authentication_error = (v.error_type orelse return error.MissingErrorType) == .auth_error;
            break :blk v.description orelse return error.MissingDescription;
        },
    };
    if (!validText(s, 16384)) return error.InvalidPrompt;
    @memcpy(out.text[0..s.len], s);
    out.len = s.len;
    return out;
}
pub const Frame = struct {
    bytes: [max_frame + 4]u8 = undefined,
    len: usize = 0,
    pub fn encode(self: *Frame, value: anytype) !void {
        self.wipe();
        errdefer self.wipe();
        var writer = std.Io.Writer.fixed(self.bytes[4..]);
        try std.json.Stringify.value(value, .{}, &writer);
        self.len = writer.end + 4;
        std.mem.writeInt(u32, self.bytes[0..4], @intCast(writer.end), endian);
    }
    pub fn create(self: *Frame, username: []const u8) !void {
        if (username.len == 0 or !validText(username, 256)) return error.InvalidUsername;
        try self.encode(.{ .type = "create_session", .username = username });
    }
    pub fn answer(self: *Frame, response: ?[]const u8) !void {
        if (response) |s| if (!validText(s, 4096)) return error.InvalidResponse;
        try self.encode(.{ .type = "post_auth_message_response", .response = response });
    }
    pub fn cancel(self: *Frame) !void {
        try self.encode(.{ .type = "cancel_session" });
    }
    pub fn start(self: *Frame, env: []const []const u8) !void {
        try self.encode(.{ .type = "start_session", .cmd = [_][]const u8{"/usr/lib/pearl/pearl-greeter-session"}, .env = env });
    }
    pub fn slice(self: *const Frame) []const u8 {
        return self.bytes[0..self.len];
    }
    pub fn wipe(self: *Frame) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.len = 0;
    }
};
pub const Framer = struct {
    bytes: [max_frame + 4]u8 = undefined,
    used: usize = 0,
    total: usize = 4,
    delivered: bool = false,
    failed: bool = false,
    pub fn reset(self: *Framer) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.used = 0;
        self.total = 4;
        self.delivered = false;
        self.failed = false;
    }
    pub fn push(self: *Framer, input: []const u8) !struct { consumed: usize, frame: ?[]const u8 } {
        if (self.failed) return error.FailedStream;
        if (self.delivered) self.reset();
        errdefer self.failed = true;
        var count: usize = 0;
        while (count < input.len and self.used < self.total) {
            const n = @min(input.len - count, self.total - self.used);
            @memcpy(self.bytes[self.used..][0..n], input[count..][0..n]);
            self.used += n;
            count += n;
            if (self.used == 4 and self.total == 4) {
                const size = std.mem.readInt(u32, self.bytes[0..4], endian);
                if (size == 0 or size > max_frame) return error.FrameSize;
                self.total = size + 4;
            }
        }
        self.delivered = self.used == self.total;
        return .{ .consumed = count, .frame = if (self.delivered) self.bytes[4..self.total] else null };
    }
    pub fn finish(self: *Framer) !void {
        if (self.failed or (self.used != 0 and !self.delivered)) return error.TruncatedFrame;
    }
};
test "native length framing survives every split and rejects huge header" {
    var frame: Frame = .{};
    defer frame.wipe();
    try frame.encode(.{ .type = "success" });
    for (0..frame.len) |cut| {
        var framer: Framer = .{};
        defer framer.reset();
        _ = try framer.push(frame.slice()[0..cut]);
        const last = try framer.push(frame.slice()[cut..]);
        try std.testing.expectEqual(Kind.success, (try decode(last.frame.?)).kind);
        try framer.finish();
    }
    var bad: Framer = .{};
    defer bad.reset();
    try std.testing.expectError(error.FrameSize, bad.push(&.{ 255, 255, 255, 255 }));
    try std.testing.expectError(error.FailedStream, bad.push("x"));
}
test "schema rejects aliases duplicates invalid strings and oversized secrets" {
    try std.testing.expectError(error.DuplicateField, decode("{\"type\":\"success\",\"type\":\"success\"}"));
    try std.testing.expectError(error.MissingPrompt, decode("{\"type\":\"auth_message\",\"message\":\"Password\"}"));
    try std.testing.expectError(error.InvalidPrompt, decode("{\"type\":\"auth_message\",\"auth_message_type\":\"secret\",\"auth_message\":\"a\\u0000b\"}"));
    var frame: Frame = .{};
    defer frame.wipe();
    try frame.answer("");
    try std.testing.expect(std.mem.indexOf(u8, frame.slice(), "\"response\":\"\"") != null);
    try frame.answer(null);
    try std.testing.expect(std.mem.indexOf(u8, frame.slice(), "\"response\":null") != null);
    try std.testing.expectError(error.InvalidResponse, frame.answer(&(@as([4097]u8, @splat('x')))));
}

test "JSON depth prompts Unicode and unknown response types are bounded" {
    var storage: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&storage);
    try w.writeAll("{\"type\":\"success\",\"extra\":");
    for (0..16) |_| try w.writeByte('[');
    for (0..16) |_| try w.writeByte(']');
    try w.writeByte('}');
    try std.testing.expectError(error.JsonDepth, decode(w.buffered()));
    try std.testing.expectError(error.InvalidEnumTag, decode("{\"type\":\"unknown\"}"));
    const response = try decode("{\"type\":\"auth_message\",\"auth_message_type\":\"visible\",\"auth_message\":\"登录\"}");
    try std.testing.expectEqualStrings("登录", response.text[0..response.len]);
    var framer: Framer = .{};
    defer framer.reset();
    _ = try framer.push(&.{ 1, 0 });
    try std.testing.expectError(error.TruncatedFrame, framer.finish());
}
