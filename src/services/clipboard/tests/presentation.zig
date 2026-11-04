const std = @import("std");
const t = std.testing;
const view = @import("../presentation.zig");
const history = @import("../history.zig");
const worker = @import("../worker.zig");
const frame = @import("../../../cli/frame.zig");
const instance = "0123456789abcdef0123456789abcdef";
fn context(model: *const history.History) view.Context {
    return .{ .accessible = true, .persistent = true, .health = .durable, .message = "Ready", .entries = model.entries(), .revision = model.generation, .instance = instance };
}
fn fill(model: *history.History, count: usize) !void {
    for (0..count) |i| {
        var bytes: [32]u8 = undefined;
        _ = try model.copy(.text, try std.fmt.bufPrint(&bytes, "synthetic {d}", .{i}), 100);
    }
}
fn parsed(bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, t.allocator, bytes, .{});
}
fn value(object: std.json.Value, name: []const u8) std.json.Value {
    return object.object.get(name).?;
}

test "clipboard status defaults to a safe first page with familiar fields" {
    var model = history.History.init(t.allocator);
    defer model.deinit();
    try fill(&model, 100);
    const bytes = try view.status(t.allocator, context(&model), .{});
    defer t.allocator.free(bytes);
    const p = try parsed(bytes);
    defer p.deinit();
    try t.expectEqual(@as(i64, 100), value(p.value, "total").integer);
    try t.expectEqual(@as(i64, 0), value(p.value, "offset").integer);
    try t.expectEqual(@as(i64, 20), value(p.value, "limit").integer);
    try t.expectEqual(@as(usize, 20), value(p.value, "entries").array.items.len);
    try t.expectEqual(@as(i64, 20), value(p.value, "next_offset").integer);
    try t.expectEqualStrings(instance, value(p.value, "instance").string);
    for ([_][]const u8{ "available", "locked", "persistent", "pending", "message", "persistence", "health" }) |name| try t.expect(p.value.object.contains(name));
}

test "clipboard pages enumerate all 100 entries without duplicates or omissions" {
    var model = history.History.init(t.allocator);
    defer model.deinit();
    try fill(&model, 100);
    var offset: u16 = 0;
    var seen: usize = 0;
    while (true) {
        const bytes = try view.status(t.allocator, context(&model), .{ .offset = offset, .limit = 17, .revision = model.generation, .instance = instance });
        defer t.allocator.free(bytes);
        const p = try parsed(bytes);
        defer p.deinit();
        for (value(p.value, "entries").array.items) |entry| {
            try t.expectEqual(@as(i64, @intCast(model.entries()[seen].id)), value(entry, "id").integer);
            seen += 1;
        }
        const next = value(p.value, "next_offset");
        if (next == .null) break;
        try t.expectEqual(@as(i64, @intCast(seen)), next.integer);
        offset = @intCast(next.integer);
    }
    try t.expectEqual(@as(usize, 100), seen);
}

test "clipboard empty history at-total and beyond-total offsets have terminal pages" {
    var model = history.History.init(t.allocator);
    defer model.deinit();
    for ([_]u16{ 0, 20, 100 }) |offset| {
        const bytes = try view.status(t.allocator, context(&model), .{ .offset = offset });
        defer t.allocator.free(bytes);
        const p = try parsed(bytes);
        defer p.deinit();
        try t.expectEqual(@as(i64, 0), value(p.value, "returned").integer);
        try t.expect(!value(p.value, "has_more").bool);
        try t.expectEqual(std.json.Value.null, value(p.value, "next_offset"));
    }
    try fill(&model, 21);
    for ([_]u16{ 21, 50, 100 }) |offset| {
        const bytes = try view.status(t.allocator, context(&model), .{ .offset = offset });
        defer t.allocator.free(bytes);
        const p = try parsed(bytes);
        defer p.deinit();
        try t.expectEqual(@as(i64, offset), value(p.value, "offset").integer);
        try t.expectEqual(@as(i64, 0), value(p.value, "returned").integer);
        try t.expectEqual(std.json.Value.null, value(p.value, "next_offset"));
    }
}

test "clipboard rejects invalid offsets limits and stale pinned traversal" {
    var model = history.History.init(t.allocator);
    defer model.deinit();
    try fill(&model, 30);
    for ([_]view.Page{ .{ .offset = 101 }, .{ .limit = 0 }, .{ .limit = 21 } }) |page| try t.expectError(error.InvalidRequest, view.status(t.allocator, context(&model), page));
    try t.expectError(error.StaleInstance, view.status(t.allocator, context(&model), .{ .instance = "ffffffffffffffffffffffffffffffff" }));
    const revision = model.generation;
    _ = try model.copy(.text, model.entries()[0].bytes, 100); // same time/front still refreshes
    try t.expectError(error.StaleRevision, view.status(t.allocator, context(&model), .{ .offset = 20, .revision = revision, .instance = instance }));
    const refreshed = model.generation;
    try t.expect(model.delete(model.entries()[0].id));
    try t.expectError(error.StaleRevision, view.status(t.allocator, context(&model), .{ .revision = refreshed }));
}

test "clipboard complete frames include maximum request ID escaping and newline" {
    var model = history.History.init(t.allocator);
    defer model.deinit();
    for (0..100) |i| {
        var bytes: [300]u8 = @splat('"');
        bytes[299] = @intCast(33 + i % 90);
        bytes[298] = @intCast(33 + i / 90);
        _ = try model.copy(.text, &bytes, 100);
    }
    const c = context(&model);
    const bytes = try view.status(t.allocator, c, .{});
    defer t.allocator.free(bytes);
    const encoded = try frame.success(t.allocator, "18446744073709551615", bytes);
    defer t.allocator.free(encoded);
    try t.expectEqual(frame.successLength("18446744073709551615", bytes), encoded.len);
    try t.expect(encoded.len <= frame.max_frame and encoded[encoded.len - 1] == '\n');
    const p = try parsed(bytes);
    defer p.deinit();
    for (value(p.value, "entries").array.items) |entry| try t.expect(value(entry, "preview").string.len <= 120);
    const oversized = try t.allocator.alloc(u8, frame.max_frame);
    defer t.allocator.free(oversized);
    @memset(oversized, 'x');
    try t.expectError(error.ResponseTooLarge, frame.success(t.allocator, "1", oversized));
}

test "clipboard measured reduction advances by actual returned count and cannot stall" {
    var model = history.History.init(t.allocator);
    defer model.deinit();
    try fill(&model, 100);
    var c = context(&model);
    c.message = @import("test_strings").string("x", 7000);
    const bytes = try view.status(t.allocator, c, .{});
    defer t.allocator.free(bytes);
    const p = try parsed(bytes);
    defer p.deinit();
    const count = value(p.value, "returned").integer;
    try t.expect(count > 0 and count < 20);
    try t.expectEqual(count, value(p.value, "next_offset").integer);
    try t.expect(frame.successLength("18446744073709551615", bytes) <= 8192);
    c.message = @import("test_strings").string("x", 8192);
    try t.expectError(error.ResponseTooLarge, view.status(t.allocator, c, .{}));
}

test "clipboard long UTF-8 previews stay bounded at character boundaries" {
    var model = history.History.init(t.allocator);
    defer model.deinit();
    _ = try model.copy(.text, "x" ++ @import("test_strings").string("🦪", 1000), 100);
    const bytes = try view.status(t.allocator, context(&model), .{});
    defer t.allocator.free(bytes);
    const p = try parsed(bytes);
    defer p.deinit();
    const preview = value(value(p.value, "entries").array.items[0], "preview").string;
    try t.expect(preview.len <= 120 and std.unicode.utf8ValidateSlice(preview));
    try t.expectEqual(@as(usize, 117), preview.len);
}

test "clipboard status substitutes controls and summarizes PNG without exposing image bytes" {
    var model = history.History.init(t.allocator);
    defer model.deinit();
    _ = try model.copy(.text, "synthetic\n\t\x01text", 100);
    var png: [33]u8 = @splat(0);
    @memcpy(png[0..16], "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR");
    std.mem.writeInt(u32, png[16..20], 1, .big);
    std.mem.writeInt(u32, png[20..24], 1, .big);
    _ = try model.copy(.png, &png, 100);
    const bytes = try view.status(t.allocator, context(&model), .{});
    defer t.allocator.free(bytes);
    const p = try parsed(bytes);
    defer p.deinit();
    const entries = value(p.value, "entries").array.items;
    try t.expectEqualStrings("PNG image", value(entries[0], "preview").string);
    try t.expectEqualStrings("synthetic   text", value(entries[1], "preview").string);
    for (entries) |entry| try t.expect(!entry.object.contains("payload") and !entry.object.contains("data"));
    try t.expect(std.mem.indexOf(u8, bytes, "IHDR") == null);
}

test "clipboard suspended status suppresses metadata and cannot distinguish empty history" {
    var model = history.History.init(t.allocator);
    defer model.deinit();
    try fill(&model, 100);
    for ([_]view.Health{ .paused, .unavailable, .failed, .uncertain, .clock_untrusted }) |health| {
        var c = context(&model);
        c.accessible = false;
        c.health = health;
        c.incoming_pending = true;
        c.persistence_pending = true;
        c.removal = .{ .token = 987, .revision = 12, .operation = .delete, .state = .pending };
        const bytes = try view.status(t.allocator, c, .{ .offset = 80, .revision = 999, .instance = "old instance" });
        defer t.allocator.free(bytes);
        const p = try parsed(bytes);
        defer p.deinit();
        for ([_][]const u8{ "total", "offset", "limit", "returned", "next_offset", "revision", "instance", "removal" }) |name| try t.expectEqual(std.json.Value.null, value(p.value, name));
        try t.expectEqual(@as(usize, 0), value(p.value, "entries").array.items.len);
        try t.expect(!value(p.value, "has_more").bool and !value(p.value, "pending").bool and !value(p.value, "persistence_pending").bool);
        try t.expectError(error.Locked, view.status(t.allocator, c, .{ .operation = 987 }));
        c.entries = &.{};
        const empty = try view.status(t.allocator, c, .{ .offset = 80, .revision = 999, .instance = "old instance" });
        defer t.allocator.free(empty);
        try t.expectEqualStrings(bytes, empty);
    }
}

test "clipboard explicit failure receipt stays visible without exposing unavailable history" {
    var model = history.History.init(t.allocator);
    defer model.deinit();
    try fill(&model, 3);
    for ([_]worker.ReceiptState{ .failed, .uncertain }) |state| {
        var c = context(&model);
        c.accessible = false;
        c.receipts_accessible = true;
        c.health = if (state == .failed) .failed else .uncertain;
        c.incoming_pending = true;
        c.persistence_pending = true;
        c.removal = .{ .token = 987, .revision = 12, .operation = .delete, .state = state };
        const page: view.Page = .{ .operation = 987, .instance = instance };
        const bytes = try view.status(t.allocator, c, page);
        defer t.allocator.free(bytes);
        const p = try parsed(bytes);
        defer p.deinit();
        const receipt = value(p.value, "removal");
        try t.expectEqual(@as(i64, 987), value(receipt, "token").integer);
        try t.expectEqualStrings(@tagName(state), value(receipt, "state").string);
        for ([_][]const u8{ "total", "offset", "limit", "returned", "next_offset", "revision", "instance" }) |name| try t.expectEqual(std.json.Value.null, value(p.value, name));
        try t.expectEqual(@as(usize, 0), value(p.value, "entries").array.items.len);
        try t.expect(!value(p.value, "available").bool and !value(p.value, "has_more").bool and !value(p.value, "pending").bool and !value(p.value, "persistence_pending").bool);
        try t.expect(std.mem.indexOf(u8, bytes, "synthetic") == null);
        try t.expectError(error.InstanceRequired, view.status(t.allocator, c, .{ .operation = 987 }));
        try t.expectError(error.StaleInstance, view.status(t.allocator, c, .{ .operation = 987, .instance = "old instance" }));
        const ordinary = try view.status(t.allocator, c, .{});
        defer t.allocator.free(ordinary);
        const hidden = try parsed(ordinary);
        defer hidden.deinit();
        try t.expectEqual(std.json.Value.null, value(hidden.value, "removal"));
        c.receipts_accessible = false;
        c.health = .paused;
        try t.expectError(error.Locked, view.status(t.allocator, c, page));
    }
}

test "clipboard pending persistence stays distinct from incoming transfer pending" {
    var model = history.History.init(t.allocator);
    defer model.deinit();
    try fill(&model, 1);
    var c = context(&model);
    c.health = .pending;
    c.persistence_pending = true;
    const bytes = try view.status(t.allocator, c, .{});
    defer t.allocator.free(bytes);
    const p = try parsed(bytes);
    defer p.deinit();
    try t.expect(!value(p.value, "pending").bool);
    try t.expect(value(p.value, "persistence_pending").bool);
    try t.expectEqualStrings("pending", value(p.value, "health").object.get("state").?.string);
    try t.expect(value(p.value, "persistent").bool);
}

test "clipboard removal feedback distinguishes pending durable Busy failed and uncertain" {
    var receipt: worker.Receipt = .{ .token = 1, .revision = 2, .operation = .clear, .state = .pending };
    try t.expectEqual(view.Feedback.removal_pending, view.feedback(.pending, receipt, 2));
    receipt.state = .running;
    try t.expectEqual(view.Feedback.removal_pending, view.feedback(.pending, receipt, 2));
    try t.expectEqual(view.Feedback.busy, view.feedback(.busy, receipt, 2));
    try t.expectEqual(view.Feedback.clock_untrusted, view.feedback(.clock_untrusted, receipt, 2));
    try t.expectEqual(view.Feedback.unavailable, view.feedback(.unavailable, receipt, 2));
    receipt.state = .durable;
    try t.expectEqual(view.Feedback.removal_durable, view.feedback(.durable, receipt, 2));
    try t.expectEqual(view.Feedback.save_pending, view.feedback(.pending, receipt, 3));
    receipt.state = .failed;
    try t.expectEqual(view.Feedback.removal_failed, view.feedback(.failed, receipt, 2));
    receipt.state = .uncertain;
    try t.expectEqual(view.Feedback.removal_uncertain, view.feedback(.uncertain, receipt, 2));
    try t.expectEqual(view.Feedback.paused, view.feedback(.paused, receipt, 2));
}

test "clipboard UI policy navigates and filters all 100 records without stale positions" {
    const Record = struct { id: u64, folded: []const u8 };
    var records: [view.capacity]Record = undefined;
    for (&records, 0..) |*record, i| record.* = .{ .id = i + 1, .folded = if (i % 2 == 0) "text" else "png image" };
    var visible: [view.capacity]usize = undefined;
    var rows = view.filter(&records, "", &visible);
    try t.expectEqual(@as(usize, 100), rows.len);
    try t.expectEqual(@as(?u64, 100), view.entryId(&records, rows, 99));
    try t.expectEqual(@as(?usize, 99), view.navigate(99, rows.len, true));
    try t.expectEqual(@as(?usize, 0), view.navigate(0, rows.len, false));
    try t.expectEqual(@as(?usize, 98), view.navigate(99, rows.len, false));
    rows = view.filter(&records, "png", &visible);
    try t.expectEqual(@as(usize, 50), rows.len);
    try t.expectEqual(@as(?usize, 49), view.selection(&records, rows, 100, 0));
    try t.expectEqual(@as(?u64, 100), view.entryId(&records, rows, 49));
    try t.expectEqual(@as(?usize, 49), view.selection(&records, rows, 99, 99));
    rows = view.filter(&records, "no match", &visible);
    try t.expectEqual(@as(usize, 0), rows.len);
    try t.expect(view.entryId(&records, rows, 0) == null and view.navigate(0, 0, true) == null and view.selection(&records, rows, 1, 0) == null);
    try t.expectEqual(@as(usize, 100), records.len);
    try t.expect(view.entryId(records[0..1], &.{99}, 0) == null);
}

test "clipboard displayed stamp changes on front recopy deletion and expiration" {
    var model = history.History.init(t.allocator);
    defer model.deinit();
    try fill(&model, 3);
    const original = view.stamp(model.entries(), true);
    const id = model.entries()[0].id;
    _ = try model.copy(.text, model.entries()[0].bytes, 100);
    const recopy = view.stamp(model.entries(), true);
    try t.expect(original != recopy);
    try t.expect(model.delete(id));
    const deleted = view.stamp(model.entries(), true);
    try t.expect(deleted != recopy);
    for (model.entries()) |entry| try t.expect(entry.id != id);
    try t.expectEqual(@as(usize, 2), try model.prune(100 + history.lifetime_seconds));
    try t.expect(view.stamp(model.entries(), true) != deleted);
    try t.expectEqual(view.stamp(&.{}, false), view.stamp(model.entries(), false));
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    const rows: []const history.Entry = &.{.{ .id = 1, .kind = .text, .bytes = "synthetic", .last_copy = 100 }};
    const bytes = try view.status(allocator, .{ .accessible = true, .health = .enabled, .message = "Ready", .instance = instance, .entries = rows }, .{});
    allocator.free(bytes);
}
test "clipboard paginated response releases previews on every allocation failure" {
    try t.checkAllAllocationFailures(t.allocator, allocationFailure, .{});
}
