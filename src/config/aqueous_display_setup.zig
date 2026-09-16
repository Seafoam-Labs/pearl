//! Pure display presentation and source-bound editing. Aqueous resolves the candidate.
const std = @import("std");
const m = @import("aqueous_model.zig");
const mutations = @import("aqueous_display_mutations.zig");
const A = std.mem.Allocator;
pub fn num(v: m.Value, fallback: f64) f64 {
    return switch (v) {
        .integer => @floatFromInt(v.integer),
        .float => if (std.math.isFinite(v.float)) v.float else fallback,
        else => fallback,
    };
}
pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 1920,
    height: f64 = 1080,
    pub fn overlaps(s: Rect, t: Rect) bool {
        return @min(s.x + s.width, t.x + t.width) > @max(s.x, t.x) and @min(s.y + s.height, t.y + t.height) > @max(s.y, t.y);
    }
    pub fn place(s: *Rect, t: Rect, side: usize, alignment: usize) void {
        const factor: f64 = switch (alignment) {
            0 => 0,
            2 => 1,
            else => 0.5,
        };
        if (side < 2) {
            s.x = if (side == 0) t.x - s.width else t.x + t.width;
            s.y = @round(t.y + (t.height - s.height) * factor);
        } else {
            s.y = if (side == 2) t.y - s.height else t.y + t.height;
            s.x = @round(t.x + (t.width - s.width) * factor);
        }
    }
    pub fn snap(s: *Rect, t: Rect, threshold: f64) void {
        var dx = threshold;
        var dy = threshold;
        var x = s.x;
        var y = s.y;
        for ([_]f64{ t.x - s.width, t.x + t.width, t.x, t.x + t.width - s.width }) |v| if (@abs(s.x - v) < dx) {
            dx = @abs(s.x - v);
            x = v;
        };
        for ([_]f64{ t.y - s.height, t.y + t.height, t.y, t.y + t.height - s.height }) |v| if (@abs(s.y - v) < dy) {
            dy = @abs(s.y - v);
            y = v;
        };
        s.x = @round(x);
        s.y = @round(y);
    }
};
pub fn outputs(base: m.Value) []const m.Value {
    return m.list(m.get(m.get(base, "display_observation"), "outputs"));
}
pub fn connector(output: m.Value) []const u8 {
    return m.str(m.get(output, "connector"));
}
fn exactName(d: m.Value, name: []const u8) bool {
    for (m.list(m.get(d, "entries"))) |e| {
        if (!std.mem.eql(u8, m.str(m.get(e, "key")), "name")) continue;
        const raw = std.mem.trim(u8, m.str(m.get(e, "raw")), " \t");
        if (raw.len >= 2 and (raw[0] == '\'' or raw[0] == '"') and raw[raw.len - 1] == raw[0]) return std.mem.eql(u8, raw[1 .. raw.len - 1], name);
    }
    return false;
}
pub fn activeParent(base: m.Value) m.Value {
    const profile = m.str(m.get(m.get(base, "display_observation"), "active_profile"));
    if (profile.len == 0) return .null;
    var result: m.Value = .null;
    for (m.list(m.get(base, "display_declarations"))) |d| {
        if (!std.mem.eql(u8, m.str(m.get(d, "kind")), "profile") or !std.mem.eql(u8, m.str(m.get(d, "source")), "outputs") or !exactName(d, profile)) continue;
        if (result != .null) return .null; // Ambiguous profile names require the advanced editor.
        result = d;
    }
    return result;
}
pub fn target(base: m.Value, output: m.Value) m.Value {
    var result: m.Value = .null;
    const parent = activeParent(base);
    for (m.list(m.get(base, "display_declarations"))) |d| {
        const kind = m.str(m.get(d, "kind"));
        const eligible = if (parent == .null) std.mem.eql(u8, kind, "output") else std.mem.eql(u8, kind, "member") and m.equal(m.get(d, "parent_id"), m.get(parent, "id"));
        if (eligible and std.mem.eql(u8, m.str(m.get(d, "source")), "outputs") and exactName(d, connector(output))) result = d;
    }
    return result;
}
pub fn reference(a: A, output: m.Value) ![]const u8 {
    return std.fmt.allocPrint(a, "pearl{X}", .{std.hash.Wyhash.hash(0, connector(output))});
}
fn matches(base: m.Value, op: m.Value, d: m.Value, output: m.Value) bool {
    if (d != .null and m.equal(m.get(op, "id"), m.get(d, "id"))) return true;
    return std.mem.eql(u8, m.str(m.get(op, "source")), "outputs") and m.equal(m.get(op, "parent"), m.get(activeParent(base), "id")) and std.mem.eql(u8, m.str(m.get(op, "op")), "add") and std.mem.eql(u8, m.str(m.get(m.get(op, "set"), "name")), connector(output));
}
pub fn value(base: m.Value, draft: m.Value, output: m.Value, key: []const u8) m.Value {
    const actual = m.get(output, "actual");
    var v = m.get(m.get(m.get(output, "configured"), key), "value");
    if (v == .null) v = m.get(actual, key);
    const d = target(base, output);
    for (m.list(m.get(m.get(draft, "display_declaration_changes"), "operations"))) |op| {
        if (!matches(base, op, d, output)) continue;
        if (m.get(m.get(op, "set"), key) != .null) v = m.get(m.get(op, "set"), key);
        if (std.mem.eql(u8, key, "x") or std.mem.eql(u8, key, "y")) {
            const pos = m.list(m.get(m.get(op, "set"), "position"));
            if (pos.len == 2) v = pos[if (std.mem.eql(u8, key, "x")) @as(usize, 0) else 1];
        }
        for (m.list(m.get(op, "unset"))) |k| if (std.mem.eql(u8, m.str(k), key)) {
            v = .null;
        };
    }
    return v;
}
pub fn geometry(base: m.Value, draft: m.Value, output: m.Value) Rect {
    return dimensions(value(base, draft, output, "mode"), num(value(base, draft, output, "scale"), 1), m.str(value(base, draft, output, "transform")), num(value(base, draft, output, "x"), 0), num(value(base, draft, output, "y"), 0));
}
pub fn resolvedGeometry(resolved: m.Value) Rect {
    return dimensions(m.get(resolved, "mode"), num(m.get(resolved, "scale"), 1), m.str(m.get(resolved, "transform")), num(m.get(resolved, "x"), 0), num(m.get(resolved, "y"), 0));
}
fn dimensions(mode: m.Value, scale_value: f64, transform: []const u8, x: f64, y: f64) Rect {
    var width = num(m.get(mode, "width"), 1920);
    var height = num(m.get(mode, "height"), 1080);
    if (mode == .string) {
        var parts = std.mem.tokenizeAny(u8, mode.string, "x@");
        width = std.fmt.parseFloat(f64, parts.next() orelse "1920") catch 1920;
        height = std.fmt.parseFloat(f64, parts.next() orelse "1080") catch 1080;
    }
    const scale = std.math.clamp(scale_value, 0.5, 3);
    if (!std.math.isFinite(width) or width <= 0 or width > 100000) width = 1920;
    if (!std.math.isFinite(height) or height <= 0 or height > 100000) height = 1080;
    if (std.mem.endsWith(u8, transform, "90") or std.mem.endsWith(u8, transform, "270")) std.mem.swap(f64, &width, &height);
    return .{ .x = x, .y = y, .width = @max(1, width / scale), .height = @max(1, height / scale) };
}
pub fn modeText(a: A, mode: m.Value) ![]const u8 {
    if (mode == .string) return mode.string;
    const hz = num(m.get(mode, "refresh_mhz"), 0) / 1000;
    if (hz <= 0) return std.fmt.allocPrint(a, "{d:.0}x{d:.0}", .{ num(m.get(mode, "width"), 1920), num(m.get(mode, "height"), 1080) });
    return std.fmt.allocPrint(a, "{d:.0}x{d:.0}@{d:.3}", .{ num(m.get(mode, "width"), 1920), num(m.get(mode, "height"), 1080), hz });
}
pub fn stage(a: A, base: m.Value, bytes: []const u8, output: m.Value, key: []const u8, v: m.Value) ![]u8 {
    if (connector(output).len == 0) return error.DisplayUnavailable;
    var req = try m.request(a, base, bytes, "");
    _ = req.object.swapRemove("backup_dir");
    const d = target(base, output);
    const profile = m.get(m.get(base, "display_observation"), "active_profile");
    if (m.str(profile).len > 0 and activeParent(base) == .null) return error.ActiveDisplayProfileNeedsAdvancedEditor;
    var batch = m.get(req, "display_declaration_changes");
    if (batch == .null) batch = try m.parse(a, "{\"version\":1,\"sources\":{},\"operations\":[]}", 1024);
    var ops = m.get(batch, "operations");
    var index: ?usize = null;
    for (ops.array.items, 0..) |op, i| if (matches(base, op, d, output)) {
        if (index != null) return error.AmbiguousDisplayDraft;
        index = i;
    };
    var op: m.Value = if (index) |i| ops.array.items[i] else try m.parse(a, "{\"source\":\"outputs\",\"set\":{},\"unset\":[]}", 1024);
    if (index == null) {
        try op.object.put(a, "op", .{ .string = if (d == .null) "add" else "update" });
        if (d == .null) {
            try op.object.put(a, "kind", .{ .string = "output" });
            try op.object.put(a, "parent", m.get(activeParent(base), "id"));
            try op.object.put(a, "ref", .{ .string = try reference(a, output) });
        } else try op.object.put(a, "id", m.get(d, "id"));
    } else if (!std.mem.eql(u8, m.str(m.get(op, "op")), "add") and !std.mem.eql(u8, m.str(m.get(op, "op")), "update")) return error.DisplayOperationAlreadyStaged;
    var set = m.get(op, "set");
    if (set == .null) set = .{ .object = .empty };
    var unset = m.get(op, "unset");
    if (unset == .null) unset = .{ .array = .init(a) };
    _ = set.object.swapRemove(key);
    var i = unset.array.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, m.str(unset.array.items[i]), key)) _ = unset.array.orderedRemove(i);
    }
    var baseline = value(base, .null, output, key);
    if (std.mem.eql(u8, key, "position")) {
        baseline = .{ .array = .init(a) };
        try baseline.array.append(.{ .integer = @intFromFloat(num(value(base, .null, output, "x"), 0)) });
        try baseline.array.append(.{ .integer = @intFromFloat(num(value(base, .null, output, "y"), 0)) });
    }
    if (std.mem.eql(u8, key, "mode")) baseline = .{ .string = try modeText(a, baseline) };
    const same = m.equal(v, baseline) or ((v == .float or v == .integer) and (baseline == .float or baseline == .integer) and num(v, 0) == num(baseline, 0));
    if (v == .null) {
        if (d != .null) try unset.array.append(.{ .string = key });
    } else if (!same) try set.object.put(a, key, v);
    if (d == .null) try set.object.put(a, "name", .{ .string = connector(output) });
    try op.object.put(a, "set", set);
    _ = op.object.swapRemove("unset");
    if (unset.array.items.len > 0) try op.object.put(a, "unset", unset);
    const empty = set.object.count() == @as(usize, if (d == .null) 1 else 0) and unset.array.items.len == 0;
    if (index) |n| {
        if (empty) _ = ops.array.orderedRemove(n) else ops.array.items[n] = op;
    } else if (!empty) try ops.array.append(op);
    if (ops.array.items.len == 0) {
        _ = req.object.swapRemove("display_declaration_changes");
    } else {
        var tokens: m.Value = .{ .object = .empty };
        for (ops.array.items) |o| {
            const src = m.str(m.get(o, "source"));
            try tokens.object.put(a, src, m.get(m.get(base, "display_source_ids"), src));
        }
        try batch.object.put(a, "sources", tokens);
        try batch.object.put(a, "operations", ops);
        try req.object.put(a, "display_declaration_changes", batch);
    }
    try mutations.check(base, req);
    return std.json.Stringify.valueAlloc(a, req, .{ .whitespace = .indent_2 });
}
pub fn changeCount(draft: m.Value) usize {
    var count: usize = m.list(m.get(draft, "monitor_changes")).len;
    for (m.list(m.get(m.get(draft, "display_declaration_changes"), "operations"))) |op| {
        const set = m.get(op, "set");
        count += if (set == .object) set.object.count() else 0;
        if (std.mem.eql(u8, m.str(m.get(op, "op")), "add") and m.get(set, "name") != .null) count -= 1;
        count += m.list(m.get(op, "unset")).len;
        if (!std.mem.eql(u8, m.str(m.get(op, "op")), "add") and !std.mem.eql(u8, m.str(m.get(op, "op")), "update")) count += 1;
    }
    return count;
}
test "logical alignment and snapping support portrait and negative coordinates" {
    var r: Rect = .{ .width = 1080, .height = 1920 };
    const t: Rect = .{ .x = -2560, .width = 2560, .height = 1440 };
    r.place(t, 0, 2);
    try std.testing.expectEqual(@as(f64, -3640), r.x);
    try std.testing.expectEqual(@as(f64, -480), r.y);
    r.x += 5;
    r.snap(t, 10);
    try std.testing.expectEqual(@as(f64, -3640), r.x);
    try std.testing.expect(!r.overlaps(t));
    r.place(t, 3, 1);
    try std.testing.expectEqual(@as(f64, 1440), r.y);
    try std.testing.expectEqual(@as(f64, -1820), r.x);
}

/// Every non-display edit participates in the same Aqueous transaction.
pub fn otherChanges(draft: m.Value) usize {
    if (draft != .object) return 0;
    var count: usize = 0;
    var it = draft.object.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, "protocol") or std.mem.eql(u8, e.key_ptr.*, "expected_generation") or std.mem.eql(u8, e.key_ptr.*, "display_declaration_changes") or std.mem.eql(u8, e.key_ptr.*, "monitor_changes")) continue;
        count += switch (e.value_ptr.*) {
            .array => e.value_ptr.array.items.len,
            .object => e.value_ptr.object.count(),
            .null => 0,
            .bool => @intFromBool(e.value_ptr.bool),
            else => 1,
        };
    }
    return count;
}
pub fn number(output: m.Value, fallback: usize) usize {
    return std.fmt.parseInt(usize, m.str(m.get(output, "instance")), 10) catch fallback;
}

test "simple display edits coalesce and leave unrelated fields intact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try m.parse(a,
        \\{"generation":"1111111111111111","capabilities":["display_declaration_mutations_v1"],"display_source_ids":{"outputs":"display-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"display_declarations":[]}
    , 4096);
    const output = try m.parse(a,
        \\{"connector":"DP-1","actual":{"x":0,"y":0,"scale":1,"hdr":false,"mode":{"width":1920,"height":1080,"refresh_mhz":59940}},"configured":{}}
    , 4096);
    const empty = try @import("aqueous_draft.zig").empty(a, base);
    const first = try stage(a, base, empty, output, "hdr", .{ .bool = true });
    const second = try stage(a, base, first, output, "hdr_level", .{ .string = "auto" });
    var draft = try m.parse(a, second, m.max_request);
    try std.testing.expectEqual(@as(usize, 1), m.list(m.get(m.get(draft, "display_declaration_changes"), "operations")).len);
    try std.testing.expectEqual(@as(usize, 2), changeCount(draft));
    try std.testing.expect(m.equal(value(base, draft, output, "hdr"), .{ .bool = true }));
    try std.testing.expectEqualStrings("1920x1080@59.940", try modeText(a, value(base, draft, output, "mode")));
    const third = try stage(a, base, second, output, "hdr", .{ .bool = false });
    draft = try m.parse(a, third, m.max_request);
    try std.testing.expectEqual(@as(usize, 1), changeCount(draft));
    const fourth = try stage(a, base, third, output, "hdr_level", .null);
    draft = try m.parse(a, fourth, m.max_request);
    try std.testing.expectEqual(@as(usize, 0), changeCount(draft));
    try std.testing.expect(m.get(draft, "display_declaration_changes") == .null);
    const scale_back = try stage(a, base, empty, output, "scale", .{ .float = 1 });
    try std.testing.expectEqual(@as(usize, 0), changeCount(try m.parse(a, scale_back, m.max_request)));
}

/// Plain-language disclosure for the other sections in the shared draft.
pub fn sharedSummary(a: A, base: m.Value, draft: m.Value) ![]const u8 {
    var lines: std.ArrayList(u8) = .empty;
    for (m.list(m.get(draft, "changes"))) |change| {
        const field = m.field(base, m.str(m.get(change, "id"))) orelse continue;
        try lines.appendSlice(a, try std.fmt.allocPrint(a, "• {s}: {s}\n", .{ m.str(m.get(field, "category")), m.str(m.get(field, "label")) }));
    }
    if (draft == .object) {
        var it = draft.object.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            if (std.mem.eql(u8, key, "protocol") or std.mem.eql(u8, key, "expected_generation") or std.mem.eql(u8, key, "changes") or std.mem.eql(u8, key, "display_declaration_changes") or std.mem.eql(u8, key, "monitor_changes")) continue;
            if (e.value_ptr.* == .null or (e.value_ptr.* == .object and e.value_ptr.object.count() == 0) or (e.value_ptr.* == .array and e.value_ptr.array.items.len == 0) or m.equal(e.value_ptr.*, .{ .bool = false })) continue;
            const label = if (std.mem.eql(u8, key, "raw_files")) "Advanced configuration files" else if (std.mem.eql(u8, key, "custom_keybind_changes")) "Shortcuts" else if (std.mem.eql(u8, key, "window_rule_changes")) "Window rules" else if (std.mem.startsWith(u8, key, "snap_") or std.mem.eql(u8, key, "default_snap_layout")) "Layouts" else "Aqueous preferences";
            try lines.appendSlice(a, try std.fmt.allocPrint(a, "• {s}\n", .{label}));
        }
    }
    return lines.toOwnedSlice(a);
}

test "HDR automatic reset preserves unrelated profile member edits and source binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try m.parse(a,
        \\{"generation":"1111111111111111","capabilities":["display_declaration_mutations_v1"],"display_source_ids":{"outputs":"display-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"display_observation":{"active_profile":"desk"},"display_declarations":[{"id":"display-v1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","kind":"profile","source":"outputs","entries":[{"key":"name","raw":"'desk'"}]},{"id":"display-v1:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","parent_id":"display-v1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","kind":"member","source":"outputs","entries":[{"key":"name","raw":"'DP-1'"},{"key":"hdr_level","raw":"'400'"},{"key":"sdr_white_level","raw":"200"}]}]}
    , 8192);
    const output = try m.parse(a,
        \\{"connector":"DP-1","actual":{"scale":1,"hdr":false,"auto_hdr":false,"hdr_level":400,"sdr_white_level":200},"configured":{"hdr_level":{"value":"400"},"sdr_white_level":{"value":200}}}
    , 4096);
    const d = target(base, output);
    try std.testing.expectEqualStrings("member", m.str(m.get(d, "kind")));
    var bytes = try @import("aqueous_draft.zig").empty(a, base);
    bytes = try stage(a, base, bytes, output, "scale", .{ .float = 1.25 });
    bytes = try stage(a, base, bytes, output, "hdr", .{ .bool = true });
    var draft = try m.parse(a, bytes, m.max_request);
    try std.testing.expectEqualStrings("400", m.str(value(base, draft, output, "hdr_level")));
    bytes = try stage(a, base, bytes, output, "hdr_level", .{ .string = "auto" });
    bytes = try stage(a, base, bytes, output, "sdr_white_level", .null);
    draft = try m.parse(a, bytes, m.max_request);
    const ops = m.list(m.get(m.get(draft, "display_declaration_changes"), "operations"));
    try std.testing.expectEqual(@as(usize, 1), ops.len);
    try std.testing.expect(m.equal(m.get(ops[0], "id"), m.get(d, "id")));
    const set = m.get(ops[0], "set");
    try std.testing.expectEqual(@as(f64, 1.25), num(m.get(set, "scale"), 0));
    try std.testing.expectEqualStrings("auto", m.str(m.get(set, "hdr_level")));
    try std.testing.expect(m.get(set, "auto_hdr") == .null);
    try std.testing.expect(m.get(set, "sdr_white_level") == .null);
    try std.testing.expectEqualStrings("sdr_white_level", m.str(m.list(m.get(ops[0], "unset"))[0]));
    // Exact connectors without a local declaration become narrowly matched members,
    // never edits to the shared profile itself.
    const another = try m.parse(a, "{\"connector\":\"DP-2\",\"actual\":{\"scale\":1}}", 1024);
    bytes = try stage(a, base, bytes, another, "scale", .{ .float = 1.5 });
    const both = m.list(m.get(m.get(try m.parse(a, bytes, m.max_request), "display_declaration_changes"), "operations"));
    try std.testing.expectEqual(@as(usize, 2), both.len);
    try std.testing.expect(m.equal(m.get(both[1], "parent"), m.get(activeParent(base), "id")));
    const raw = "{\"protocol\":1,\"expected_generation\":\"1111111111111111\",\"raw_files\":{\"outputs\":\"# raw edit\"}}";
    try std.testing.expectError(error.ConflictingEdits, stage(a, base, raw, output, "hdr", .{ .bool = true }));
    const stale = "{\"protocol\":1,\"expected_generation\":\"2222222222222222\"}";
    try std.testing.expectError(error.StaleDraft, stage(a, base, stale, output, "hdr", .{ .bool = true }));
}

test "canonical geometry uses fractional scale and reflected portrait transforms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try m.parse(arena.allocator(), "{\"x\":-100,\"y\":50,\"mode\":{\"width\":2560,\"height\":1440},\"scale\":1.25,\"transform\":\"flipped-90\"}", 1024);
    const r = resolvedGeometry(v);
    try std.testing.expectEqual(@as(f64, -100), r.x);
    try std.testing.expectEqual(@as(f64, 1152), r.width);
    try std.testing.expectEqual(@as(f64, 2048), r.height);
}
