//! Bounded CLI projections and shared, compositor-free clipboard view policy.
const std = @import("std");
const history = @import("history.zig");
const policy = @import("../clipboard_policy.zig");
const worker = @import("worker.zig");
const frame = @import("../../cli/frame.zig");
pub const capacity = history.entries_limit;
pub const page_limit = 20;
pub const Health = enum { paused, loading, enabled, pending, durable, busy, failed, uncertain, unavailable, clock_untrusted };
pub const Page = struct {
    offset: u16 = 0,
    limit: u8 = page_limit,
    revision: ?u64 = null,
    instance: ?[]const u8 = null,
    operation: ?u64 = null,
    request_id: []const u8 = "18446744073709551615",
    pub fn validate(self: Page) !void {
        if (self.offset > capacity or self.limit == 0 or self.limit > page_limit) return error.InvalidRequest;
    }
};
pub const Context = struct {
    accessible: bool,
    receipts_accessible: bool = false,
    persistent: bool = false,
    incoming_pending: bool = false,
    persistence_pending: bool = false,
    health: Health,
    code: ?[]const u8 = null,
    message: []const u8,
    entries: []const history.Entry = &.{},
    revision: u64 = 0,
    instance: []const u8,
    removal: ?worker.Receipt = null,
};

pub fn status(allocator: std.mem.Allocator, context: Context, page: Page) ![]u8 {
    try page.validate();
    if (page.operation != null) {
        if (!context.receipts_accessible) return error.Locked;
        const instance = page.instance orelse return error.InstanceRequired;
        if (!std.mem.eql(u8, instance, context.instance)) return error.StaleInstance;
    }
    if (context.accessible) {
        if (page.instance) |instance| if (!std.mem.eql(u8, instance, context.instance)) return error.StaleInstance;
        if (page.revision) |revision| if (revision != context.revision) return error.StaleRevision;
    }
    const Item = struct { id: u64, kind: history.Kind, bytes: usize, preview: []const u8, last_copy: i64 };
    var items: [page_limit]Item = undefined;
    var previews: [page_limit]?[:0]u8 = @splat(null);
    defer for (previews) |preview| if (preview) |text| {
        std.crypto.secureZero(u8, text);
        allocator.free(text);
    };
    const entries = if (context.accessible) context.entries else &.{};
    const offset = @min(page.offset, entries.len);
    var count: usize = 0;
    for (entries[offset..@min(entries.len, offset + page.limit)]) |entry| {
        const preview = if (entry.kind == .text) blk: {
            const text = try policy.preview(allocator, entry.bytes);
            previews[count] = text;
            break :blk text;
        } else "PNG image";
        items[count] = .{ .id = entry.id, .kind = entry.kind, .bytes = entry.bytes.len, .preview = preview, .last_copy = entry.last_copy };
        count += 1;
    }
    while (true) {
        const more = offset + count < entries.len;
        const result = try std.json.Stringify.valueAlloc(allocator, .{
            .available = context.accessible,
            .locked = !context.accessible,
            .persistent = context.persistent,
            .pending = context.accessible and context.incoming_pending,
            .persistence_pending = context.accessible and context.persistence_pending,
            .persistence = context.health,
            .health = .{ .state = context.health, .code = context.code },
            .message = context.message,
            .total = if (context.accessible) @as(?usize, entries.len) else null,
            .offset = if (context.accessible) @as(?u16, page.offset) else null,
            .limit = if (context.accessible) @as(?u8, page.limit) else null,
            .returned = if (context.accessible) @as(?usize, count) else null,
            .has_more = more,
            .next_offset = if (more) @as(?usize, offset + count) else null,
            .revision = if (context.accessible) @as(?u64, context.revision) else null,
            .instance = if (context.accessible) @as(?[]const u8, context.instance) else null,
            .removal = if (context.accessible or (page.operation != null and context.receipts_accessible)) context.removal else null,
            .entries = items[0..count],
        }, .{});
        if (frame.successLength(page.request_id, result) <= frame.max_frame) return result;
        std.crypto.secureZero(u8, result);
        allocator.free(result);
        // Never return an empty nonterminal page with the same continuation.
        if (count <= 1) return error.ResponseTooLarge;
        count -= 1;
    }
}

pub const Feedback = enum { paused, loading, enabled, save_pending, save_durable, busy, failed, uncertain, unavailable, clock_untrusted, removal_pending, removal_durable, removal_failed, removal_uncertain };
pub fn feedback(health: Health, removal: ?worker.Receipt, desired_revision: u64) Feedback {
    if (health == .paused) return .paused;
    if (health == .busy) return .busy;
    if (health == .clock_untrusted) return .clock_untrusted;
    if (health == .unavailable) return .unavailable;
    if (health == .loading) return .loading;
    if (removal) |receipt| switch (receipt.state) {
        .pending, .running => if (health != .failed and health != .uncertain) return .removal_pending,
        .durable => if (receipt.revision == desired_revision and health == .durable) return .removal_durable,
        .failed, .cancelled => if (health == .failed) return .removal_failed,
        .uncertain => if (health == .uncertain) return .removal_uncertain,
    };
    return switch (health) {
        .paused => .paused,
        .loading => .loading,
        .enabled => .enabled,
        .pending => .save_pending,
        .durable => .save_durable,
        .busy => .busy,
        .failed => .failed,
        .uncertain => .uncertain,
        .unavailable => .unavailable,
        .clock_untrusted => .clock_untrusted,
    };
}

pub fn stamp(entries: []const history.Entry, accessible: bool) u64 {
    var hash = std.hash.Wyhash.init(@intFromBool(accessible));
    if (accessible) for (entries) |entry| {
        hash.update(std.mem.asBytes(&entry.id));
        hash.update(std.mem.asBytes(&entry.sequence));
    };
    return hash.final();
}
/// Both inputs are already case-folded by the existing Unicode filter.
pub fn filter(records: anytype, query: []const u8, visible: *[capacity]usize) []const usize {
    var len: usize = 0;
    for (records, 0..) |record, index| {
        if (len == capacity) break;
        if (query.len != 0 and std.mem.indexOf(u8, record.folded, query) == null) continue;
        visible[len] = index;
        len += 1;
    }
    return visible[0..len];
}
pub fn entryId(records: anytype, visible: []const usize, position: usize) ?u64 {
    if (position >= visible.len or visible[position] >= records.len) return null;
    return records[visible[position]].id;
}
pub fn selection(records: anytype, visible: []const usize, id: ?u64, position: usize) ?usize {
    if (visible.len == 0) return null;
    if (id) |wanted| for (visible, 0..) |index, at| {
        if (index < records.len and records[index].id == wanted) return at;
    };
    return @min(position, visible.len - 1);
}
pub fn navigate(position: usize, len: usize, down: bool) ?usize {
    if (len == 0) return null;
    const current = @min(position, len - 1);
    return if (down) @min(current + 1, len - 1) else current -| 1;
}
