//! One private durable intent, serialized across Pearl instances. No request contents.
const std = @import("std");
const glib = @import("glib2");
extern fn getrandom(*[16]u8, usize, c_uint) isize;
const io = @import("io.zig");
const m = @import("aqueous_model.zig");
const c = @import("aqueous_contract.zig");
extern fn flock(c_int, c_int) c_int;
pub const Store = struct {
    fd: c_int,
    path: [:0]const u8,
    a: std.mem.Allocator,
    pub fn open(a: std.mem.Allocator) !Store {
        const root = try std.fmt.allocPrintSentinel(a, "{s}/pearl/aqueous-operations", .{std.mem.span(glib.getUserStateDir())}, 0);
        try io.mkdir(root);
        const lock = try std.fmt.allocPrintSentinel(a, "{s}/writer.lock", .{root}, 0);
        const fd = std.c.open(lock, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o600));
        if (fd < 0) return error.OperationStoreUnavailable;
        errdefer _ = std.c.close(fd);
        if (flock(fd, 2 | 4) != 0) return error.OperationBusy;
        return .{ .fd = fd, .path = try std.fmt.allocPrintSentinel(a, "{s}/pending.json", .{root}, 0), .a = a };
    }
    pub fn close(self: Store) void {
        _ = flock(self.fd, 8);
        _ = std.c.close(self.fd);
    }
    pub fn pending(self: Store) !?m.Value {
        const file = try io.read(self.a, self.path, 4096, null);
        if (file.missing) return null;
        const v = try m.parse(self.a, file.bytes, 4096);
        try c.version(v, "version", 1);
        if (!try c.boolean(v, "pending")) return null;
        if (!c.operationId(try c.text(v, "operation_id", 64))) return error.InvalidOperationRecord;
        _ = try c.hex(v, "candidate_digest", 64);
        _ = try c.hex(v, "generation", 16);
        _ = try c.hex(v, "request_sha256", 64);
        return v;
    }
    pub fn begin(self: Store, helper: []const u8, helper_version: []const u8, request: []const u8, impact: c.Impact) ![]const u8 {
        if (try self.pending() != null) return error.SaveUncertain;
        var random: [16]u8 = undefined;
        if (getrandom(&random, random.len, 0) != random.len) return error.RandomUnavailable;
        const id = try std.fmt.allocPrint(self.a, "{d:0>10}-{s}", .{ @as(u64, @intCast(@divTrunc(glib.getRealTime(), 1000000))), std.fmt.bytesToHex(random, .lower) });
        if (!c.operationId(id)) return error.InvalidOperationId;
        const hash = io.digest(request);
        const bytes = try std.json.Stringify.valueAlloc(self.a, .{ .version = 1, .pending = true, .operation_id = id, .helper = helper, .helper_version = helper_version, .request_sha256 = &hash, .generation = impact.generation, .candidate_digest = impact.digest, .session = m.get(impact.projection, "session") }, .{});
        if (bytes.len > 4096) return error.InvalidOperationRecord;
        try io.atomic(self.path, bytes, false);
        return id;
    }
    pub fn resolved(self: Store, id: []const u8) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.a, .{ .version = 1, .pending = false, .operation_id = id }, .{});
        try io.atomic(self.path, bytes, false);
    }
};
