//! Bounded, transport-independent IPC v1 decoding. No sockets, GTK or acknowledgements.
const std = @import("std");
const e = @import("entities.zig");
const Allocator = std.mem.Allocator;

pub const Limits = struct {
    request_bytes: usize = 64 * 1024,
    frame_bytes: usize = 4 * 1024 * 1024 + 64 * 1024,
    batch_bytes: usize = 4 * 1024 * 1024,
    state_bytes: usize = 2 * 1024 * 1024,
    depth: usize = 16,

    pub fn validate(self: Limits) !void {
        const hard: Limits = .{};
        inline for (@typeInfo(Limits).@"struct".fields) |f| {
            const n = @field(self, f.name);
            if (n == 0 or n > @field(hard, f.name)) return error.InvalidLimits;
        }
    }
};

/// Consume at most one frame per call. Continue with input[result.consumed..].
/// The returned frame is valid until the next push/reset/deinit. A failed stream
/// stays poisoned until reset; EOF with a partial frame is an error.
pub const Framer = struct {
    allocator: Allocator,
    limit: usize,
    buffer: std.ArrayList(u8) = .empty,
    delivered: bool = false,
    failed: bool = false,
    pub const Read = struct { consumed: usize, frame: ?[]const u8 };

    pub fn init(allocator: Allocator, limit: usize) !Framer {
        if (limit == 0 or limit > (Limits{}).frame_bytes) return error.InvalidLimits;
        return .{ .allocator = allocator, .limit = limit };
    }
    pub fn deinit(self: *Framer) void {
        self.buffer.deinit(self.allocator);
    }
    pub fn reset(self: *Framer) void {
        self.buffer.clearRetainingCapacity();
        self.delivered = false;
        self.failed = false;
    }
    pub fn push(self: *Framer, input: []const u8) !Read {
        if (self.failed) return error.FailedStream;
        errdefer self.failed = true;
        if (self.delivered) {
            self.buffer.clearRetainingCapacity();
            self.delivered = false;
        }
        const end = std.mem.indexOfScalar(u8, input, '\n');
        const count = end orelse input.len;
        if (count > self.limit - self.buffer.items.len) return error.FrameTooLarge;
        const needed = self.buffer.items.len + count;
        if (needed > self.buffer.capacity)
            try self.buffer.ensureTotalCapacityPrecise(self.allocator, @min(self.limit, @max(needed, self.buffer.capacity + self.buffer.capacity / 2 + 64)));
        self.buffer.appendSliceAssumeCapacity(input[0..count]);
        if (end != null) {
            if (needed == 0) return error.EmptyFrame;
            if (!std.unicode.utf8ValidateSlice(self.buffer.items)) return error.InvalidUtf8;
            self.delivered = true;
            return .{ .consumed = count + 1, .frame = self.buffer.items };
        }
        return .{ .consumed = count, .frame = null };
    }
    pub fn finish(self: *Framer) !void {
        if (self.failed) return error.FailedStream;
        if (!self.delivered and self.buffer.items.len != 0) {
            self.failed = true;
            return error.TruncatedFrame;
        }
    }
};

pub const Batch = struct {
    session: []const u8,
    sequence: []const u8,
    base_sequence: ?[]const u8,
    type: enum { snapshot, delta },
    upsert: []const e.Entity,
    removed: []const e.Key,
};
pub const Capabilities = struct {
    state: bool,
    commands: bool,
    keyboard: bool,
    overview: bool,
    workspace_switcher_v1: bool = false,
    shortcut_inhibition: bool,
    icon_metadata: bool = false,
    icon_fetch: bool = false,
    config_reload: bool = false,
};
pub const Hello = struct {
    session: []const u8,
    schema: u32,
    max_request_bytes: usize,
    max_frame_bytes: usize,
    max_batch_bytes: usize,
    max_pending_requests: usize,
    capabilities: Capabilities,
    max_clients: usize = 16,
    max_state_bytes: usize = 2 * 1024 * 1024,
    max_depth: usize = 16,

    /// Advertisements may lower, but can never raise, Pearl's hard ceilings.
    pub fn effectiveLimits(self: Hello) Limits {
        const hard: Limits = .{};
        return .{
            .request_bytes = @min(hard.request_bytes, self.max_request_bytes),
            .frame_bytes = @min(hard.frame_bytes, self.max_frame_bytes),
            .batch_bytes = @min(hard.batch_bytes, self.max_batch_bytes),
            .state_bytes = @min(hard.state_bytes, self.max_state_bytes),
            .depth = @min(hard.depth, self.max_depth),
        };
    }
};
pub const Operation = enum { hello, snapshot, subscribe, ack, command, window_icon };
pub const CommandResult = struct { status: enum { applied, accepted }, sequence: []const u8 };
pub const IconResult = struct { revision: []const u8, width: u16, height: u16, format: enum { png }, data: []const u8 };
pub const Result = union(Operation) {
    hello: Hello,
    snapshot: Batch,
    subscribe: void,
    ack: []const u8,
    command: CommandResult,
    window_icon: IconResult,
};
pub const Message = union(enum) {
    event: struct { delivery: []const u8, batch: Batch },
    response: struct { id: []const u8, result: Result },
    failure: struct { id: []const u8, code: []const u8, message: []const u8 },
};
pub const Decoded = struct {
    arena: std.heap.ArenaAllocator,
    message: Message,
    pub fn deinit(self: *Decoded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Input excludes LF and is copied into the returned arena. Responses require
/// an expected operation; request ID matching and connection state belong to T04.
pub fn decode(allocator: Allocator, bytes: []const u8, limits: Limits, expected: ?Operation) !Decoded {
    try limits.validate();
    try preflight(bytes, limits);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    // Check the exact encoded batch span, including its internal whitespace,
    // before building a DOM. Escaped field names are decoded by the scanner.
    if (try batchSpan(a, bytes)) |span| if (span.len > limits.batch_bytes) return error.BatchTooLarge;
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .max_value_len = limits.frame_bytes,
    });
    if (try e.read(u32, a, try e.field(value, "ipc")) != 1) return error.UnsupportedIpc;
    var message: Message = undefined;
    if (value.object.get("event")) |event| {
        if (value.object.contains("id") or value.object.contains("ok") or value.object.contains("result") or value.object.contains("error")) return error.InvalidEnvelope;
        if (!std.mem.eql(u8, try e.read([]const u8, a, event), "state")) return error.UnsupportedEvent;
        const delivery = try e.read([]const u8, a, try e.field(value, "delivery"));
        try e.decimal(delivery);
        message = .{ .event = .{ .delivery = delivery, .batch = try parseBatch(a, try e.field(value, "batch")) } };
    } else {
        if (value.object.contains("batch") or value.object.contains("delivery")) return error.InvalidEnvelope;
        const id = try e.read([]const u8, a, try e.field(value, "id"));
        try e.decimal(id);
        if (try e.read(bool, a, try e.field(value, "ok"))) {
            if (value.object.contains("error")) return error.InvalidEnvelope;
            const op = expected orelse return error.UnexpectedResponse;
            message = .{ .response = .{ .id = id, .result = try parseResult(a, op, try e.field(value, "result")) } };
        } else {
            if (value.object.contains("result")) return error.InvalidEnvelope;
            const failure = try e.field(value, "error");
            message = .{ .failure = .{
                .id = id,
                .code = try e.read([]const u8, a, try e.field(failure, "code")),
                .message = try e.read([]const u8, a, try e.field(failure, "message")),
            } };
        }
    }
    return .{ .arena = arena, .message = message };
}

fn parseResult(a: Allocator, op: Operation, value: std.json.Value) !Result {
    switch (op) {
        .hello => {
            const hello = try e.read(Hello, a, value);
            try e.sessionToken(hello.session);
            if (hello.schema != 1) return error.UnsupportedSchema;
            if (hello.max_pending_requests != 1 or hello.max_clients == 0) return error.UnsupportedLimits;
            try hello.effectiveLimits().validate();
            return .{ .hello = hello };
        },
        .snapshot => {
            const batch = try parseBatch(a, try e.field(value, "batch"));
            if (batch.type != .snapshot) return error.InvalidBatch;
            return .{ .snapshot = batch };
        },
        .subscribe => {
            if (!try e.read(bool, a, try e.field(value, "subscribed"))) return error.InvalidEnvelope;
            return .{ .subscribe = {} };
        },
        .ack => {
            const acked = try e.read([]const u8, a, try e.field(value, "acked"));
            try e.decimal(acked);
            return .{ .ack = acked };
        },
        .command => {
            const result = try e.read(CommandResult, a, value);
            try e.decimal(result.sequence);
            return .{ .command = result };
        },
        .window_icon => {
            const result = try e.read(IconResult, a, value);
            try e.decimal(result.revision);
            if (result.width == 0 or result.width > 256 or result.height != result.width or result.data.len > 512 * 1024) return error.InvalidRange;
            const pixel_bytes = std.base64.standard.Decoder.calcSizeForSlice(result.data) catch return error.InvalidIcon;
            const pixels = try a.alloc(u8, pixel_bytes);
            std.base64.standard.Decoder.decode(pixels, result.data) catch return error.InvalidIcon;
            // PNG decoding and matching requested dimensions/revision belong to T04.
            return .{ .window_icon = result };
        },
    }
}

fn parseBatch(a: Allocator, value: std.json.Value) !Batch {
    if (try e.read(u32, a, try e.field(value, "schema")) != 1) return error.UnsupportedSchema;
    var batch: Batch = .{
        .session = try e.read([]const u8, a, try e.field(value, "session")),
        .sequence = try e.read([]const u8, a, try e.field(value, "sequence")),
        .base_sequence = try e.read(?[]const u8, a, try e.field(value, "base_sequence")),
        .type = try e.read(@FieldType(Batch, "type"), a, try e.field(value, "type")),
        .upsert = undefined,
        .removed = undefined,
    };
    try e.sessionToken(batch.session);
    try e.decimal(batch.sequence);
    if (batch.base_sequence) |base| try e.decimal(base);
    const upsert = try e.field(value, "upsert");
    const removed = try e.field(value, "removed");
    if (upsert != .array or removed != .array) return error.InvalidType;
    if ((batch.type == .snapshot and (batch.base_sequence != null or removed.array.items.len != 0)) or
        (batch.type == .delta and batch.base_sequence == null)) return error.InvalidBatch;
    const entities = try a.alloc(e.Entity, upsert.array.items.len);
    for (entities, upsert.array.items) |*out, item| out.* = try e.Entity.parse(a, item);
    const keys = try a.alloc(e.Key, removed.array.items.len);
    for (keys, removed.array.items) |*out, item| out.* = try e.Key.parse(try e.read([]const u8, a, item));
    batch.upsert = entities;
    batch.removed = keys;
    return batch;
}

/// No allocation before frame/UTF-8/depth validation. Brackets in strings and
/// escaped quotes do not affect depth. The JSON parser checks full grammar next.
fn preflight(bytes: []const u8, limits: Limits) !void {
    if (bytes.len == 0) return error.EmptyFrame;
    if (bytes.len > limits.frame_bytes) return error.FrameTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    var depth: usize = 0;
    var string = false;
    var escape = false;
    for (bytes) |byte| {
        if (byte == '\n' or byte == '\r') return error.InvalidFraming;
        if (string) {
            if (escape) {
                escape = false;
            } else if (byte == '\\') {
                escape = true;
            } else if (byte == '"') {
                string = false;
            }
        } else switch (byte) {
            '"' => string = true,
            '{', '[' => {
                depth += 1;
                if (depth > limits.depth) return error.TooDeep;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            else => {},
        }
    }
    if (depth != 0 or string) return error.InvalidJson;
}

fn batchSpan(a: Allocator, bytes: []const u8) !?[]const u8 {
    var scanner = std.json.Scanner.initCompleteInput(a, bytes);
    defer scanner.deinit();
    if (try scanner.next() != .object_begin) return error.InvalidType;
    return objectBatchSpan(a, &scanner, bytes, true);
}

fn objectBatchSpan(a: Allocator, scanner: *std.json.Scanner, bytes: []const u8, root: bool) anyerror!?[]const u8 {
    while (true) {
        const token = try scanner.nextAlloc(a, .alloc_if_needed);
        const key = switch (token) {
            .object_end => return null,
            .string, .allocated_string => |s| s,
            else => return error.InvalidJson,
        };
        const next = try scanner.peekNextTokenType();
        if (next == .object_end or next == .array_end or next == .end_of_document) return error.InvalidJson;
        if (std.mem.eql(u8, key, "batch") and next == .object_begin) {
            _ = try scanner.next();
            const start = scanner.cursor - 1;
            try scanner.skipUntilStackHeight(scanner.stackHeight() - 1);
            return bytes[start..scanner.cursor];
        } else if (root and std.mem.eql(u8, key, "result") and next == .object_begin) {
            _ = try scanner.next();
            if (try objectBatchSpan(a, scanner, bytes, false)) |span| return span;
        } else try scanner.skipValue();
    }
}
