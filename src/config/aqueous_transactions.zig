//! Canonical transaction routing. Baseline tokens are copied, never synthesized.
const std = @import("std");
const m = @import("aqueous_model.zig");
const c = @import("aqueous_contract.zig");
pub const sources = [_][2][]const u8{ .{ "window_rule_changes", "rules" }, .{ "custom_keybind_changes", "wm" }, .{ "snap_zone_changes", "layout" }, .{ "snap_layouts", "layout" } };
pub fn collectionOnly(req: m.Value) bool {
    var found = false;
    for (sources) |pair| if (m.get(req, pair[0]) != .null) {
        found = true;
    };
    if (!found or req != .object) return false;
    var it = req.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        var allowed = false;
        for (sources) |pair| if (std.mem.eql(u8, key, pair[0])) {
            allowed = true;
        };
        for ([_][]const u8{ "protocol", "expected_generation", "backup_dir", "create_user_override", "collection_preconditions", "default_snap_layout" }) |k| if (std.mem.eql(u8, key, k)) {
            allowed = true;
        };
        if (std.mem.eql(u8, key, "changes") and entry.value_ptr.* == .array and entry.value_ptr.array.items.len == 0) allowed = true;
        if (std.mem.eql(u8, key, "raw_files") and entry.value_ptr.* == .object and entry.value_ptr.object.count() == 0) allowed = true;
        if (!allowed) return false;
    }
    return true;
}
pub fn prepare(a: std.mem.Allocator, base: m.Value, req: *m.Value, caps: c.Capabilities) !bool {
    const only = collectionOnly(req.*) and caps.protected_collections;
    _ = req.object.swapRemove("collection_preconditions");
    try req.object.put(a, "protected_apply", .{ .bool = true });
    if (!only) return false;
    _ = req.object.swapRemove("changes");
    _ = req.object.swapRemove("raw_files");
    var touched: m.Value = .{ .object = .empty };
    const baseline = m.get(base, "collection_preconditions_v2");
    try c.preconditions(baseline);
    for (sources) |pair| if (m.get(req.*, pair[0]) != .null) {
        const descriptor = m.get(m.get(baseline, "sources"), pair[1]);
        if (descriptor == .null) return error.InvalidCollectionPreconditions;
        try touched.object.put(a, pair[1], descriptor);
    };
    var pre: m.Value = .{ .object = .empty };
    try pre.object.put(a, "version", .{ .integer = 2 });
    try pre.object.put(a, "sources", touched);
    try req.object.put(a, "collection_apply_version", .{ .integer = 1 });
    try req.object.put(a, "collection_preconditions_v2", pre);
    return true;
}
pub fn reviewed(a: std.mem.Allocator, req: *m.Value, candidate: m.Value) ![]const u8 {
    const tx = m.get(candidate, "collection_transaction");
    try c.version(tx, "version", 1);
    const requested = try c.hex(tx, "requested_generation", 16);
    if (!std.mem.eql(u8, requested, m.str(m.get(req.*, "expected_generation")))) return error.StaleDraft;
    const effective = try c.hex(tx, "effective_generation", 16);
    if (try c.boolean(tx, "rebased") != !std.mem.eql(u8, requested, effective)) return error.InvalidContract;
    const baseline = m.get(tx, "base_preconditions");
    try c.preconditions(baseline);
    if (!m.equal(baseline, m.get(req.*, "collection_preconditions_v2"))) return error.InvalidCollectionPreconditions;
    const digest = try c.hex(tx, "candidate_digest", 64);
    if (!std.mem.eql(u8, digest, try c.hex(m.get(candidate, "candidate_review"), "candidate_digest", 64))) return error.CandidateMismatch;
    try req.object.put(a, "expected_generation", .{ .string = effective });
    try req.object.put(a, "collection_preconditions_v2", baseline);
    return effective;
}
test "collection route excludes mixed edits and binds exactly touched sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var req = try m.parse(a, "{\"protocol\":1,\"changes\":[],\"raw_files\":{},\"window_rule_changes\":[]}", 4096);
    try std.testing.expect(collectionOnly(req));
    try req.object.put(a, "sync_cursor", .{ .bool = true });
    try std.testing.expect(!collectionOnly(req));
}

test "protected collections copy source descriptors and bind effective review generation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try m.parse(a, "{\"collection_preconditions_v2\":{\"version\":2,\"sources\":{\"rules\":{\"path\":\"/private/rules\",\"exists\":false,\"digest\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},\"wm\":{\"path\":\"/private/wm\",\"exists\":true,\"digest\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}}}}", 4096);
    var req = try m.parse(a, "{\"protocol\":1,\"expected_generation\":\"1111111111111111\",\"changes\":[],\"raw_files\":{},\"window_rule_changes\":[]}", 4096);
    try std.testing.expect(try prepare(a, base, &req, .{ .protected_collections = true }));
    try std.testing.expect(m.get(req, "raw_files") == .null);
    const pre = m.get(req, "collection_preconditions_v2");
    try std.testing.expectEqual(@as(usize, 1), m.get(pre, "sources").object.count());
    var candidate = try m.parse(a, "{\"collection_transaction\":{\"version\":1,\"requested_generation\":\"1111111111111111\",\"effective_generation\":\"2222222222222222\",\"rebased\":true,\"candidate_digest\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"},\"candidate_review\":{\"candidate_digest\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"}}", 4096);
    var tx = m.get(candidate, "collection_transaction");
    try tx.object.put(a, "base_preconditions", pre);
    try candidate.object.put(a, "collection_transaction", tx);
    try std.testing.expectEqualStrings("2222222222222222", try reviewed(a, &req, candidate));
    try std.testing.expectEqualStrings("2222222222222222", m.str(m.get(req, "expected_generation")));
    try req.object.put(a, "expected_generation", .{ .string = "1111111111111111" });
    try tx.object.put(a, "base_preconditions", m.get(base, "collection_preconditions_v2"));
    try candidate.object.put(a, "collection_transaction", tx);
    try std.testing.expectError(error.InvalidCollectionPreconditions, reviewed(a, &req, candidate));
}
