//! Source-bound display drafts; only aqueous-config edits or resolves TOML.
const std = @import("std");
const m = @import("aqueous_model.zig");
const c = @import("aqueous_contract.zig");
pub fn fields(a: std.mem.Allocator) !m.Value {
    return m.parse(a, @embedFile("aqueous_display_fields.json"), 16384);
}
pub fn fieldAllowed(kind: []const u8, key: []const u8) bool {
    if (std.mem.eql(u8, kind, "profile")) return std.mem.eql(u8, key, "name");
    const policy = std.mem.eql(u8, key, "apply_on_start") or std.mem.eql(u8, key, "apply_on_reload") or std.mem.eql(u8, key, "fallback_profile") or std.mem.eql(u8, key, "identify_by") or std.mem.eql(u8, key, "rollback_seconds");
    return if (std.mem.eql(u8, kind, "policy")) policy else !policy;
}
pub fn check(base: m.Value, req: m.Value) !void {
    const batch = m.get(req, "display_declaration_changes");
    if (batch == .null) return;
    if (!c.Capabilities.read(base).display_mutations) return error.DisplayMutationCapabilityUnavailable;
    try c.version(batch, "version", 1);
    const ops = m.get(batch, "operations");
    const tokens = m.get(batch, "sources");
    if (ops != .array or ops.array.items.len == 0 or ops.array.items.len > 256 or tokens != .object) return error.InvalidDisplayMutation;
    var wm = false;
    var outputs = false;
    for (ops.array.items) |op| {
        const source = try c.text(op, "source", 16);
        if (std.mem.eql(u8, source, "wm")) wm = true else if (std.mem.eql(u8, source, "outputs")) outputs = true else return error.InvalidDisplaySource;
        const token = m.get(tokens, source);
        try c.displayId(token);
        if (!m.equal(token, m.get(m.get(base, "display_source_ids"), source))) return error.StaleDraft;
        if (m.get(m.get(req, "raw_files"), source) != .null) return error.ConflictingEdits;
        for (m.list(m.get(req, "changes"))) |change| {
            const spec = m.field(base, m.str(m.get(change, "id"))) orelse return error.UnknownField;
            if (std.mem.eql(u8, source, m.str(m.get(spec, "file")))) return error.ConflictingEdits;
        }
        // Existing identities must belong to this exact base, not a candidate snapshot.
        const id = m.get(op, "id");
        if (id != .null and !std.mem.startsWith(u8, m.str(id), "new:")) {
            try c.displayId(id);
            var found = false;
            for (m.list(m.get(base, "display_declarations"))) |d| if (m.equal(id, m.get(d, "id"))) {
                found = true;
            };
            if (!found) return error.StaleDraft;
        }
    }
    if (tokens.object.count() != @as(usize, @intFromBool(wm)) + @as(usize, @intFromBool(outputs))) return error.InvalidDisplaySource;
    if (m.get(req, "monitor_changes") != .null or (wm and m.get(req, "custom_keybind_changes") != .null)) return error.ConflictingEdits;
}
pub fn stage(a: std.mem.Allocator, base: m.Value, draft: []const u8, operation: m.Value) ![]u8 {
    var req = try m.request(a, base, draft, "unused");
    _ = req.object.swapRemove("backup_dir");
    var batch = m.get(req, "display_declaration_changes");
    if (batch == .null) batch = try m.parse(a, "{\"version\":1,\"sources\":{},\"operations\":[]}", 1024);
    var ops = m.get(batch, "operations");
    if (ops != .array or ops.array.items.len >= 256) return error.InvalidDisplayMutation;
    const id = m.get(operation, "id");
    var replaced = false;
    for (ops.array.items) |*old| if (id != .null and m.equal(m.get(old.*, "id"), id)) {
        // A node is targeted once. Replace a staged edit rather than duplicating it.
        if (!std.mem.eql(u8, m.str(m.get(operation, "op")), "update") or !std.mem.eql(u8, m.str(m.get(old.*, "op")), "update")) return error.DisplayOperationAlreadyStaged;
        old.* = operation;
        replaced = true;
        break;
    };
    if (!replaced) try ops.array.append(operation);
    var tokens = m.get(batch, "sources");
    const source = m.str(m.get(operation, "source"));
    try tokens.object.put(a, source, m.get(m.get(base, "display_source_ids"), source));
    try batch.object.put(a, "sources", tokens);
    try batch.object.put(a, "operations", ops);
    try req.object.put(a, "display_declaration_changes", batch);
    try check(base, req);
    return std.json.Stringify.valueAlloc(a, req, .{ .whitespace = .indent_2 });
}
test "display field groups keep policy separate from outputs and profiles" {
    try std.testing.expect(fieldAllowed("profile", "name"));
    try std.testing.expect(!fieldAllowed("profile", "scale"));
    try std.testing.expect(fieldAllowed("policy", "fallback_profile"));
    try std.testing.expect(!fieldAllowed("output", "fallback_profile"));
    try std.testing.expect(fieldAllowed("member", "adaptive_sync"));
}

test "display source authorization and raw overlap are checked before dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try m.parse(a, "{\"generation\":\"1111111111111111\",\"capabilities\":[\"display_declaration_mutations_v1\"],\"display_source_ids\":{\"outputs\":\"display-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},\"display_declarations\":[]}", 4096);
    var req = try m.parse(a, "{\"display_declaration_changes\":{\"version\":1,\"sources\":{\"outputs\":\"display-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},\"operations\":[{\"op\":\"add\",\"source\":\"outputs\",\"kind\":\"output\",\"parent\":null,\"set\":{\"name\":\"offline\",\"enabled\":false}}]}}", 4096);
    try check(base, req);
    try req.object.put(a, "raw_files", try m.parse(a, "{\"outputs\":\"\"}", 1024));
    try std.testing.expectError(error.ConflictingEdits, check(base, req));
    _ = req.object.swapRemove("raw_files");
    var batch = m.get(req, "display_declaration_changes");
    var tokens = m.get(batch, "sources");
    try tokens.object.put(a, "outputs", .{ .string = "display-v1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" });
    try batch.object.put(a, "sources", tokens);
    try req.object.put(a, "display_declaration_changes", batch);
    try std.testing.expectError(error.StaleDraft, check(base, req));
}
