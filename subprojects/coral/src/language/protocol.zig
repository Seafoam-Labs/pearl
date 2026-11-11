//! Bounded LSP Content-Length framing and JSON-RPC helpers (pure std).
//! Encoders return owned JSON bodies, not framed bytes; encodeFrame adds headers.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_header_bytes = 8 * 1024; // Includes the final CRLF CRLF.
pub const max_message_bytes = 4 * 1024 * 1024;
pub const max_json_depth = 64;
pub const max_pending_messages = 64;

/// Owns at most max_message_bytes of body allocations (queued + in progress),
/// a fixed header buffer, and a bounded queue. Drain next() between feed() calls.
/// Every feed error, including OOM, discards pending data and permanently poisons
/// this instance. Returned messages belong to the caller, using init's allocator.
/// No EOF is implied by feed(""); finish() detects a truncated final frame.
pub const Framer = struct {
    allocator: Allocator,
    header: [max_header_bytes]u8 = undefined,
    header_len: usize = 0,
    body: ?[]u8 = null,
    body_len: usize = 0,
    queue: std.ArrayList([]u8) = .empty,
    retained: usize = 0,
    failed: bool = false,

    pub fn init(allocator: Allocator) Framer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Framer) void {
        self.clear();
        self.* = undefined;
    }

    fn clear(self: *Framer) void {
        if (self.body) |body| self.allocator.free(body);
        for (self.queue.items) |body| self.allocator.free(body);
        self.queue.deinit(self.allocator);
        self.queue = .empty;
        self.body = null;
        self.body_len = 0;
        self.header_len = 0;
        self.retained = 0;
    }

    fn poison(self: *Framer) void {
        self.clear();
        self.failed = true;
    }

    pub fn feed(self: *Framer, bytes: []const u8) !void {
        if (self.failed) return error.FramerFailed;
        errdefer self.poison();
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (self.body) |body| {
                const n = @min(body.len - self.body_len, bytes.len - offset);
                @memcpy(body[self.body_len..][0..n], bytes[offset..][0..n]);
                self.body_len += n;
                offset += n;
                if (self.body_len == body.len) {
                    try boundedJson(body, max_message_bytes, max_json_depth);
                    try self.queue.append(self.allocator, body);
                    self.body = null;
                    self.body_len = 0;
                }
            } else {
                if (self.header_len == max_header_bytes) return error.HeaderTooLarge;
                const ch = bytes[offset];
                // Headers are ASCII, with CRLF only; folding is rejected below.
                if ((ch < 0x20 and ch != '\r' and ch != '\n' and ch != '\t') or ch > 0x7e)
                    return error.InvalidHeader;
                if (ch == '\n' and (self.header_len == 0 or self.header[self.header_len - 1] != '\r'))
                    return error.InvalidHeader;
                if (self.header_len > 0 and self.header[self.header_len - 1] == '\r' and ch != '\n')
                    return error.InvalidHeader;
                self.header[self.header_len] = ch;
                self.header_len += 1;
                offset += 1;
                if (std.mem.endsWith(u8, self.header[0..self.header_len], "\r\n\r\n")) {
                    const length = try contentLength(self.header[0 .. self.header_len - 4]);
                    if (self.queue.items.len == max_pending_messages or length > max_message_bytes - self.retained)
                        return error.PendingLimitExceeded;
                    self.body = try self.allocator.alloc(u8, length);
                    self.retained += length;
                    self.header_len = 0;
                } else if (self.header_len == max_header_bytes) return error.HeaderTooLarge;
            }
        }
    }

    pub fn next(self: *Framer) !?[]u8 {
        if (self.failed) return error.FramerFailed;
        if (self.queue.items.len == 0) return null;
        const body = self.queue.orderedRemove(0);
        self.retained -= body.len;
        return body;
    }

    pub fn finish(self: *Framer) !void {
        if (self.failed) return error.FramerFailed;
        if (self.body != null or self.header_len != 0) {
            self.poison();
            return error.TruncatedFrame;
        }
    }
};

fn headerToken(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", ch) != null;
}

fn contentLength(headers: []const u8) !usize {
    var length: ?usize = null;
    var content_type_seen = false;
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        const name = line[0..colon];
        if (name.len == 0) return error.InvalidHeader;
        for (name) |ch| if (!headerToken(ch)) return error.InvalidHeader;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            if (length != null) return error.DuplicateContentLength;
            if (value.len == 0) return error.InvalidContentLength;
            var n: usize = 0;
            for (value) |ch| {
                if (!std.ascii.isDigit(ch)) return error.InvalidContentLength;
                n = std.math.mul(usize, n, 10) catch return error.InvalidContentLength;
                n = std.math.add(usize, n, ch - '0') catch return error.InvalidContentLength;
            }
            if (n == 0) return error.InvalidContentLength;
            if (n > max_message_bytes) return error.MessageTooLarge;
            length = n;
        } else if (std.ascii.eqlIgnoreCase(name, "Content-Type")) {
            if (content_type_seen) return error.InvalidHeader;
            content_type_seen = true;
            var parts = std.mem.splitScalar(u8, value, ';');
            const media = std.mem.trim(u8, parts.next().?, " \t");
            if (!std.ascii.eqlIgnoreCase(media, "application/vscode-jsonrpc") and !std.ascii.eqlIgnoreCase(media, "application/json"))
                return error.UnsupportedContentType;
            var charset_seen = false;
            while (parts.next()) |part| {
                const eq = std.mem.indexOfScalar(u8, part, '=') orelse return error.UnsupportedContentType;
                if (charset_seen or !std.ascii.eqlIgnoreCase(std.mem.trim(u8, part[0..eq], " \t"), "charset"))
                    return error.UnsupportedContentType;
                charset_seen = true;
                const charset = std.mem.trim(u8, part[eq + 1 ..], " \t");
                if (!std.ascii.eqlIgnoreCase(charset, "utf-8") and !std.ascii.eqlIgnoreCase(charset, "utf8"))
                    return error.UnsupportedContentType;
            }
        }
    }
    return length orelse error.MissingContentLength;
}

/// Quote/escape-aware preflight, following preferences.boundedJson's pattern.
/// This is NOT a JSON grammar validator; parseMessage performs full validation.
/// Framing checks UTF-8 and nesting without allocating a DOM for every message.
pub fn boundedJson(bytes: []const u8, max_bytes: usize, max_depth: usize) !void {
    if (bytes.len > max_bytes) return error.MessageTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |ch| {
        if (quoted) {
            if (escaped) escaped = false else if (ch == '\\') escaped = true else if (ch == '"') quoted = false;
        } else switch (ch) {
            '"' => quoted = true,
            '{', '[' => {
                if (depth == max_depth) return error.JsonTooDeep;
                depth += 1;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            else => {},
        }
    }
    if (quoted or depth != 0) return error.InvalidJson;
}

/// Owns its DOM and strings independently of bytes; caller must deinit().
/// Duplicate keys are rejected. Envelope/schema validation is the controller's job.
pub fn parseMessage(allocator: Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    try boundedJson(bytes, max_message_bytes, max_json_depth);
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_message_bytes,
    });
}

pub fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(name) else null;
}

pub fn string(value: std.json.Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}

pub fn integer(value: std.json.Value) ?i64 {
    return if (value == .integer) value.integer else null;
}

/// IDs are signed 64-bit integers or UTF-8 strings. No floats, null, or coercion.
/// String IDs returned by responseId borrow storage from the parsed DOM.
pub const Id = union(enum) {
    integer: i64,
    string: []const u8,

    fn value(self: Id) !std.json.Value {
        return switch (self) {
            .integer => |n| .{ .integer = n },
            .string => |s| if (std.unicode.utf8ValidateSlice(s)) .{ .string = s } else error.InvalidId,
        };
    }
};

pub fn responseId(value: std.json.Value) !Id {
    const id = field(value, "id") orelse return error.InvalidId;
    return switch (id) {
        .integer => |n| .{ .integer = n },
        .string => |s| if (std.unicode.utf8ValidateSlice(s)) .{ .string = s } else error.InvalidId,
        else => error.InvalidId,
    };
}

fn encode(allocator: Allocator, value: anytype) ![]u8 {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    errdefer allocator.free(bytes);
    try boundedJson(bytes, max_message_bytes, max_json_depth);
    return bytes;
}

pub fn encodeRequest(allocator: Allocator, id: Id, method: []const u8, params: anytype) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(method)) return error.InvalidUtf8;
    return encode(allocator, .{ .jsonrpc = "2.0", .id = try id.value(), .method = method, .params = params });
}

pub fn encodeNotification(allocator: Allocator, method: []const u8, params: anytype) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(method)) return error.InvalidUtf8;
    return encode(allocator, .{ .jsonrpc = "2.0", .method = method, .params = params });
}

pub fn encodeResponse(allocator: Allocator, id: Id, result: anytype) ![]u8 {
    return encode(allocator, .{ .jsonrpc = "2.0", .id = try id.value(), .result = result });
}

pub fn encodeErrorResponse(allocator: Allocator, id: Id, code: i64, message: []const u8, data: anytype) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(message)) return error.InvalidUtf8;
    return encode(allocator, .{ .jsonrpc = "2.0", .id = try id.value(), .@"error" = .{ .code = code, .message = message, .data = data } });
}

pub fn encodeFrame(allocator: Allocator, body: []const u8) ![]u8 {
    if (body.len == 0) return error.InvalidContentLength;
    try boundedJson(body, max_message_bytes, max_json_depth);
    return std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}
