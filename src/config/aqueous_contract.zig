//! Bounded additive contracts from Aqueous b3d4869 / helper 0.8.2.
//! JSON extensions are retained in the owning document; decisions use validated fields.
const std = @import("std");
const m = @import("aqueous_model.zig");
pub const Value = m.Value;
pub const required = [_][]const u8{ "shell_none", "schema_fields", "validate", "generation_check", "stdin_requests", "apply_result_v1", "operation_receipts_v1", "candidate_impact_v1", "recoverable_commit_v1" };
pub const Capabilities = struct {
    apply: bool = false,
    display: bool = false,
    collections: bool = false,
    protected_collections: bool = false,
    display_mutations: bool = false,
    pub fn read(v: Value) Capabilities {
        var result: Capabilities = .{ .apply = true };
        for (required) |cap| if (!m.has(v, cap)) {
            result.apply = false;
        };
        result.display = result.apply;
        for ([_][]const u8{ "display_model_v2", "display_observation_v1", "display_preview_commit_v1" }) |cap| if (!m.has(v, cap)) {
            result.display = false;
        };
        result.collections = m.has(v, "collection_schema_v1") and m.has(v, "collection_preconditions_v1") and m.has(v, "collection_identity_v1");
        result.protected_collections = result.apply and result.collections and m.has(v, "protected_collection_apply_v1") and m.has(v, "collection_preconditions_v2");
        result.display_mutations = m.has(v, "display_declaration_mutations_v1");
        return result;
    }
};
pub fn text(v: Value, key: []const u8, max: usize) ![]const u8 {
    const value = m.get(v, key);
    if (value != .string or value.string.len > max) return error.InvalidContract;
    return value.string;
}
pub fn hex(v: Value, key: []const u8, length: usize) ![]const u8 {
    const s = try text(v, key, length);
    if (s.len != length) return error.InvalidIdentity;
    for (s) |c| if (!std.ascii.isHex(c)) return error.InvalidIdentity;
    return s;
}
pub fn boolean(v: Value, key: []const u8) !bool {
    const b = m.get(v, key);
    return if (b == .bool) b.bool else error.InvalidContract;
}
pub fn version(v: Value, key: []const u8, expected: i64) !void {
    const n = m.get(v, key);
    if (n != .integer or n.integer != expected) return error.UnsupportedContractVersion;
}
pub fn decimal(v: Value, key: []const u8) ![]const u8 {
    const s = try text(v, key, 20);
    _ = std.fmt.parseInt(u64, s, 10) catch return error.InvalidIdentity;
    return s;
}
pub const Support = struct {
    store: bool,
    test_: bool,
    preview: bool,
    reason: ?[]const u8,
    pub fn read(v: Value) !Support {
        const reason = m.get(v, "reason");
        if (reason != .null and reason != .string) return error.InvalidContract;
        return .{ .store = try boolean(v, "store"), .test_ = try boolean(v, "test"), .preview = try boolean(v, "preview"), .reason = if (reason == .string) try text(v, "reason", 1024) else null };
    }
};
pub fn preconditions(v: Value) !void {
    try version(v, "version", 2);
    const sources = m.get(v, "sources");
    if (sources != .object or sources.object.count() > 3) return error.InvalidCollectionPreconditions;
    var it = sources.object.iterator();
    while (it.next()) |e| {
        if (!std.mem.eql(u8, e.key_ptr.*, "wm") and !std.mem.eql(u8, e.key_ptr.*, "rules") and !std.mem.eql(u8, e.key_ptr.*, "layout")) return error.InvalidCollectionPreconditions;
        _ = try text(e.value_ptr.*, "path", 4096);
        _ = try boolean(e.value_ptr.*, "exists");
        _ = try hex(e.value_ptr.*, "digest", 64);
    }
}
pub fn snapshot(v: Value) !void {
    if (m.get(v, "collection_preconditions_v2") != .null) try preconditions(m.get(v, "collection_preconditions_v2"));
    if (m.get(v, "display_declaration_mutations") != .null) try version(m.get(v, "display_declaration_mutations"), "version", 1);
    if (m.get(v, "display_source_ids") != .null) {
        const ids = m.get(v, "display_source_ids");
        if (ids != .object or ids.object.count() > 2) return error.InvalidContract;
        var it = ids.object.iterator();
        while (it.next()) |e| try displayId(e.value_ptr.*);
        for (m.list(m.get(v, "display_declarations"))) |d| {
            try displayId(m.get(d, "id"));
            if (m.get(d, "parent_id") != .null) try displayId(m.get(d, "parent_id"));
            const kind = try text(d, "kind", 16);
            if (!std.mem.eql(u8, kind, "output") and !std.mem.eql(u8, kind, "profile") and !std.mem.eql(u8, kind, "policy") and !std.mem.eql(u8, kind, "member")) return error.InvalidContract;
        }
    }
    for ([_][]const u8{ "window_rules", "custom_keybinds", "monitors", "display_declarations" }) |key| {
        const items = m.get(v, key);
        if (items != .null and (items != .array or m.list(items).len > 2048)) return error.InvalidContract;
    }
    const layouts = m.get(v, "snap_layouts");
    if (layouts != .null) {
        if (layouts != .array or m.list(layouts).len > 8) return error.InvalidContract;
        for (m.list(layouts)) |layout| if (m.get(layout, "zones") != .array or m.list(m.get(layout, "zones")).len > 16) return error.InvalidContract;
    }

    if (m.get(v, "display_model") != .null) {
        const d = m.get(v, "display_model");
        try version(d, "version", 2);
        _ = try hex(d, "generation", 16);
        if (m.get(d, "configured") != .object or m.get(d, "declarations") != .array or m.list(m.get(d, "declarations")).len > 2048) return error.InvalidContract;
    }
    if (m.get(v, "collection_schema") != .null) {
        const c = m.get(v, "collection_schema");
        try version(c, "version", 1);
        if (!std.mem.eql(u8, m.str(m.get(m.get(c, "identity"), "scope")), "generation")) return error.InvalidIdentity;
        const fields = m.get(m.get(c, "window_rules"), "fields");
        if (fields != .array or fields.array.items.len > 256) return error.InvalidContract;
    }
    const observation = m.get(v, "display_observation");
    if (m.get(observation, "outputs") != .null) try display(observation);
}
pub fn displayId(v: Value) !void {
    const id = m.str(v);
    if (id.len != 75 or !std.mem.startsWith(u8, id, "display-v1:")) return error.InvalidIdentity;
    for (id[11..]) |ch| if (!std.ascii.isHex(ch)) return error.InvalidIdentity;
}
pub fn display(v: Value) !void {
    try version(v, "version", 1);
    _ = try hex(v, "session", 32);
    _ = try decimal(v, "display_revision");
    const outputs = m.get(v, "outputs");
    if (outputs != .array or outputs.array.items.len > 128) return error.InvalidContract;
    for (outputs.array.items) |o| {
        _ = try decimal(o, "instance");
        _ = try text(o, "connector", 256);
        _ = try boolean(o, "connected");
        _ = try boolean(o, "enabled");
        if (m.get(o, "preview_backend") != .null) _ = try text(o, "preview_backend", 32);
        if (m.get(o, "preview_acceptance_only") != .null) _ = try boolean(o, "preview_acceptance_only");
        const support = m.get(o, "support");
        if (support != .object or support.object.count() > 64) return error.InvalidContract;
        var entries = support.object.iterator();
        while (entries.next()) |e| {
            _ = try Support.read(e.value_ptr.*);
        }
    }
}
pub const Route = enum { no_change, runtime, display, unknown };
pub const Impact = struct {
    route: Route,
    digest: []const u8,
    generation: []const u8,
    projection: Value,
    reason: []const u8,
    pub fn read(v: Value, generation: []const u8) !Impact {
        const i = m.get(v, "candidate_impact");
        try version(i, "version", 1);
        const gen = try hex(i, "original_generation", 16);
        if (!std.mem.eql(u8, gen, generation)) return error.StaleDraft;
        const digest = try hex(i, "candidate_digest", 64);
        if (!std.mem.eql(u8, digest, try hex(m.get(v, "candidate_review"), "candidate_digest", 64))) return error.CandidateMismatch;
        var route: Route = .no_change;
        const effects = m.get(i, "effects");
        if (effects != .array or effects.array.items.len == 0 or effects.array.items.len > 16) return error.InvalidContract;
        for (effects.array.items) |effect| {
            const s = m.str(effect);
            if (std.mem.eql(u8, s, "display_live") or std.mem.eql(u8, s, "display_deferred")) {
                if (route != .unknown) route = .display;
            } else if (std.mem.eql(u8, s, "runtime_non_display")) {
                if (route == .no_change) route = .runtime;
            } else if (!std.mem.eql(u8, s, "none")) route = .unknown;
        }
        if (!try boolean(i, "complete")) route = .unknown;
        const projection = m.get(i, "display");
        if (route == .display) {
            if (!try boolean(projection, "complete")) return error.UnclassifiedCandidate;
            _ = try hex(projection, "session", 32);
            _ = try decimal(projection, "display_revision");
        } else if (projection != .null and route != .unknown) return error.InvalidContract;
        return .{ .route = route, .digest = digest, .generation = gen, .projection = projection, .reason = m.str(m.get(i, "reason")) };
    }
};
pub const Save = enum { saved, unchanged, failed, uncertain, recovery_conflict, rolled_back };
pub const Reload = enum { not_requested, applied, failed, unknown };
pub const Display = enum { not_requested, kept, reverted, invalidated, failed, previewing, unknown };
pub const Receipt = enum { complete, recovered, unavailable, unknown, recovery_conflict };
pub const Result = struct {
    ok: bool,
    save: Save,
    reload: Reload,
    display: Display,
    receipt: Receipt,
    value: Value,
    pub fn read(v: Value, operation: []const u8) !Result {
        try version(v, "protocol", 1);
        try version(v, "result_version", 1);
        if (!std.mem.eql(u8, try text(v, "operation_id", 64), operation)) return error.OperationMismatch;
        return .{ .ok = try boolean(v, "ok"), .save = try enumeration(Save, v, "save"), .reload = try enumeration(Reload, v, "reload"), .display = try enumeration(Display, v, "display"), .receipt = try enumeration(Receipt, v, "receipt"), .value = v };
    }
    pub fn certain(self: Result) bool {
        return self.save != .uncertain and self.save != .recovery_conflict and self.display != .previewing and self.receipt != .unknown and self.receipt != .recovery_conflict;
    }
};
fn enumeration(comptime T: type, v: Value, key: []const u8) !T {
    return std.meta.stringToEnum(T, try text(v, key, 64)) orelse error.InvalidContract;
}
pub fn operationId(id: []const u8) bool {
    if (id.len < 32 or id.len > 64 or id[10] != '-') return false;
    _ = std.fmt.parseInt(u64, id[0..10], 10) catch return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}
test "capability omissions disable only the dependent operation" {
    const caps = Capabilities.read(.null);
    try std.testing.expect(!caps.apply and !caps.display and !caps.collections);
    try std.testing.expect(operationId("1789388195-0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!operationId("unrelated-uuid-0123456789abcdef0123456789"));
}
test "uncertain and unknown receipt outcomes never become success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try m.parse(arena.allocator(), "{\"ok\":true,\"protocol\":1,\"result_version\":1,\"operation_id\":\"op\",\"save\":\"uncertain\",\"reload\":\"unknown\",\"display\":\"unknown\",\"receipt\":\"unknown\"}", 4096);
    try std.testing.expect(!(try Result.read(v, "op")).certain());
    try std.testing.expectError(error.OperationMismatch, Result.read(v, "other"));
    try std.testing.expectError(error.InvalidContract, Support.read(.null));
}
