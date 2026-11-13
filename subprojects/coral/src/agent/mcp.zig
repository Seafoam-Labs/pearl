//! Model Context Protocol (MCP) stdio client.
//!
//! initialize -> notifications/initialized -> tools/list -> tools/call.
//! Tools advertise a read-only hint; the engine requires approval for any
//! non-read-only tool before calling it. The fake MCP fixture never touches
//! the host filesystem.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const rpc = @import("rpc.zig");
const cancel = @import("cancel.zig");
const Token = cancel.Token;

pub const protocol_version = "2024-11-05";

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
    read_only: bool,

    pub fn deinit(self: *Tool, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.input_schema_json);
    }

    /// Non-read-only tools must be approved before invocation.
    pub fn requiresApproval(self: Tool) bool {
        return !self.read_only;
    }
};

pub const CallResult = struct {
    content: []const u8,
    is_error: bool,

    pub fn deinit(self: *CallResult, allocator: Allocator) void {
        allocator.free(self.content);
    }
};

pub const McpClient = struct {
    allocator: Allocator,
    io: Io,
    conn: *rpc.Connection,
    server_name: []u8,
    negotiated_version: []u8,

    pub fn start(allocator: Allocator, io: Io, argv: []const []const u8, opts: rpc.Options) !*McpClient {
        const self = try allocator.create(McpClient);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .conn = undefined,
            .server_name = try allocator.dupe(u8, ""),
            .negotiated_version = try allocator.dupe(u8, ""),
        };
        errdefer {
            allocator.free(self.server_name);
            allocator.free(self.negotiated_version);
        }
        self.conn = try rpc.Connection.start(allocator, io, argv, .{
            .ctx = self,
            .handle = handle,
        }, opts);
        return self;
    }

    pub fn initialize(self: *McpClient, timeout_ms: u32) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var info: std.json.ObjectMap = .empty;
        try info.put(a, "name", .{ .string = "coral" });
        try info.put(a, "version", .{ .string = "0.1.0" });
        var params: std.json.ObjectMap = .empty;
        try params.put(a, "protocolVersion", .{ .string = protocol_version });
        try params.put(a, "capabilities", .{ .object = .empty });
        try params.put(a, "clientInfo", .{ .object = info });

        const result = try self.conn.request(a, "initialize", .{ .object = params }, timeout_ms);
        if (result != .object) return error.InvalidResponse;
        if (result.object.get("protocolVersion")) |v| {
            if (v == .string) {
                const copy = try self.allocator.dupe(u8, v.string);
                self.allocator.free(self.negotiated_version);
                self.negotiated_version = copy;
            }
        }
        if (result.object.get("serverInfo")) |si| {
            if (si == .object) {
                if (si.object.get("name")) |n| {
                    if (n == .string) {
                        const copy = try self.allocator.dupe(u8, n.string);
                        self.allocator.free(self.server_name);
                        self.server_name = copy;
                    }
                }
            }
        }
        try self.conn.notify("notifications/initialized", .{ .object = .empty });
    }

    pub fn listTools(self: *McpClient, allocator: Allocator, timeout_ms: u32) ![]Tool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const result = try self.conn.request(a, "tools/list", .{ .object = .empty }, timeout_ms);
        if (result != .object) return error.InvalidResponse;
        const tools_val = result.object.get("tools") orelse return error.InvalidResponse;
        if (tools_val != .array) return error.InvalidResponse;

        var list: std.ArrayList(Tool) = .empty;
        errdefer {
            for (list.items) |*t| t.deinit(allocator);
            list.deinit(allocator);
        }
        for (tools_val.array.items) |item| {
            if (item != .object) continue;
            const name = blk: {
                const v = item.object.get("name") orelse continue;
                break :blk if (v == .string) v.string else continue;
            };
            var description: []const u8 = "";
            if (item.object.get("description")) |d| {
                if (d == .string) description = d.string;
            }
            var schema_json: []const u8 = "{}";
            if (item.object.get("inputSchema")) |s| {
                schema_json = try std.json.Stringify.valueAlloc(allocator, s, .{});
            } else {
                schema_json = try allocator.dupe(u8, "{}");
            }
            errdefer allocator.free(schema_json);
            var read_only = false;
            if (item.object.get("annotations")) |ann| {
                if (ann == .object) {
                    if (ann.object.get("readOnlyHint")) |ro| {
                        if (ro == .bool) read_only = ro.bool;
                    }
                }
            }
            try list.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .description = try allocator.dupe(u8, description),
                .input_schema_json = schema_json,
                .read_only = read_only,
            });
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn call(self: *McpClient, allocator: Allocator, name: []const u8, arguments_json: []const u8, token: *Token, timeout_ms: u32) !CallResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const args = try std.json.parseFromSliceLeaky(std.json.Value, a, arguments_json, .{});
        var params: std.json.ObjectMap = .empty;
        try params.put(a, "name", .{ .string = name });
        try params.put(a, "arguments", args);
        const result = try self.conn.requestCancel(a, "tools/call", .{ .object = params }, timeout_ms, token);

        var is_error = false;
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(allocator);
        if (result == .object) {
            if (result.object.get("isError")) |e| {
                if (e == .bool) is_error = e.bool;
            }
            if (result.object.get("content")) |content| {
                if (content == .array) {
                    for (content.array.items) |block| {
                        if (block != .object) continue;
                        if (block.object.get("text")) |t| {
                            if (t == .string) {
                                try text.appendSlice(allocator, t.string);
                                try text.append(allocator, '\n');
                            }
                        }
                    }
                }
            }
        }
        return .{ .content = try text.toOwnedSlice(allocator), .is_error = is_error };
    }

    pub fn isDisconnected(self: *const McpClient) bool {
        return self.conn.isDisconnected();
    }

    pub fn close(self: *McpClient) void {
        self.conn.close();
    }

    pub fn deinit(self: *McpClient) void {
        self.conn.deinit();
        self.allocator.free(self.server_name);
        self.allocator.free(self.negotiated_version);
        self.allocator.destroy(self);
    }

    fn handle(_: *anyopaque, conn: *rpc.Connection, msg: rpc.Message) void {
        // The fake server issues no requests; respond to any unexpected
        // request with method-not-found and ignore notifications.
        if (msg.id) |id| {
            conn.respondError(id, -32601, "method not found") catch {};
        }
    }
};

test "Tool.requiresApproval follows read-only hint" {
    const ro: Tool = .{ .name = "echo", .description = "", .input_schema_json = "{}", .read_only = true };
    const rw: Tool = .{ .name = "write", .description = "", .input_schema_json = "{}", .read_only = false };
    try std.testing.expect(!ro.requiresApproval());
    try std.testing.expect(rw.requiresApproval());
}
