//! Bounded notification rules. Configuration is pure; matching uses GLib's
//! Unicode NFC + full case folding, shared by ingestion and the draft tester.
const std = @import("std");
const notes = @import("notification_policy.zig");
pub const max_rules = 32;
pub const max_conditions = 8;
pub const Field = enum { app_name, desktop_entry, summary, body, urgency };
pub const Operator = enum { equals, contains };
pub const Action = enum { block, history_only };
pub const Decision = enum { normal, history_only, block };
pub const Condition = struct { field: Field, operator: Operator = .equals, value: []const u8, case_sensitive: bool = false };
pub const Rule = struct {
    id: []const u8,
    name: []const u8,
    enabled: bool = true,
    action: Action = .block,
    match: enum { all, any } = .all,
    conditions: []const Condition,
};
pub const Config = struct {
    filters_enabled: bool = true,
    rules: []const Rule = &.{},
    pub fn validate(self: Config) !void {
        if (self.rules.len > max_rules) return error.TooManyNotificationFilters;
        for (self.rules, 0..) |r, i| {
            if (r.id.len == 0 or r.id.len > 64) return error.InvalidNotificationFilterId;
            for (r.id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidNotificationFilterId;
            for (self.rules[0..i]) |old| if (std.mem.eql(u8, old.id, r.id)) return error.DuplicateNotificationFilterId;
            try text(r.name, 80);
            if (r.conditions.len == 0 or r.conditions.len > max_conditions) return error.InvalidNotificationConditions;
            for (r.conditions) |c| {
                try text(c.value, if (c.field == .app_name) 160 else 256);
                if (c.field == .desktop_entry or c.field == .urgency) {
                    if (c.operator != .equals or !c.case_sensitive) return error.InvalidNotificationComparison;
                    if (c.field == .desktop_entry and !desktopId(c.value)) return error.InvalidNotificationDesktopId;
                    if (c.field == .urgency and !std.mem.eql(u8, c.value, "low") and !std.mem.eql(u8, c.value, "normal") and !std.mem.eql(u8, c.value, "critical")) return error.InvalidNotificationUrgency;
                }
            }
        }
    }
};
fn text(s: []const u8, limit: usize) !void {
    if (s.len == 0 or s.len > limit or !std.unicode.utf8ValidateSlice(s)) return error.InvalidNotificationFilterText;
    var iterator = (std.unicode.Utf8View.initUnchecked(s)).iterator();
    var visible = false;
    while (iterator.nextCodepoint()) |cp| {
        if (cp < 32 or (cp >= 0x7f and cp <= 0x9f) or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) return error.InvalidNotificationFilterText;
        const whitespace = cp == 32 or cp == 0xa0 or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200a) or cp == 0x2028 or cp == 0x2029 or cp == 0x202f or cp == 0x205f or cp == 0x3000;
        visible = visible or !whitespace;
    }
    if (!visible) return error.InvalidNotificationFilterText;
}
pub fn withoutSuffix(s: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, s, ".desktop")) s[0 .. s.len - 8] else s;
}
pub fn desktopId(s: []const u8) bool {
    const id = withoutSuffix(s);
    if (id.len == 0 or s.len > 256 or id[0] == '.' or id[id.len - 1] == '.') return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-') return false;
    return true;
}
pub const Sample = struct {
    app_name: []const u8 = "",
    desktop_entry: []const u8 = "",
    summary: []const u8 = "",
    body: []const u8 = "",
    urgency: enum { low, normal, critical } = .normal,
    pub fn validate(self: Sample) !void {
        inline for (.{ "app_name", "desktop_entry", "summary", "body" }) |field| {
            const s = @field(self, field);
            if (s.len > 4096 or !std.unicode.utf8ValidateSlice(s)) return error.InvalidNotificationSample;
        }
    }
    pub fn record(self: Sample) notes.Record {
        var r: notes.Record = .{ .app = notes.sanitize(160, self.app_name), .summary = notes.sanitize(256, self.summary), .body = notes.sanitize(2048, self.body), .urgency = @intFromEnum(self.urgency) };
        // Invalid/oversized hints are absent, never silently truncated identities.
        if (desktopId(self.desktop_entry)) r.desktop_entry.set(withoutSuffix(self.desktop_entry));
        return r;
    }
};
pub const Result = struct {
    decision: Decision = .normal,
    indices: [max_rules]usize = undefined,
    count: usize = 0,
};
extern "glib-2.0" fn g_utf8_normalize(str: [*]const u8, len: isize, mode: c_int) ?[*:0]u8;
extern "glib-2.0" fn g_utf8_casefold(str: [*]const u8, len: isize) ?[*:0]u8;
extern "glib-2.0" fn g_free(ptr: ?*anyopaque) void;
fn fold(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    // G_NORMALIZE_DEFAULT_COMPOSE = 1 (NFC). Inputs are validated or sanitized.
    const normalized = g_utf8_normalize(s.ptr, @intCast(s.len), 1) orelse return error.OutOfMemory;
    defer g_free(normalized);
    const folded = g_utf8_casefold(normalized, -1) orelse return error.OutOfMemory;
    defer g_free(folded);
    const value = std.mem.span(folded);
    if (value.len > 32768) return error.NotificationNormalizationLimit;
    return alloc.dupe(u8, value);
}
pub const Compiled = struct {
    arena: std.heap.ArenaAllocator,
    config: Config,
    pub fn init(alloc: std.mem.Allocator, config: Config) !Compiled {
        try config.validate();
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        const rules = try a.alloc(Rule, config.rules.len);
        for (config.rules, rules) |r, *out| {
            out.* = r;
            out.id = try a.dupe(u8, r.id);
            out.name = try a.dupe(u8, r.name);
            const conditions = try a.dupe(Condition, r.conditions);
            out.conditions = conditions;
            for (conditions) |*c| c.value = if (c.field == .desktop_entry) try a.dupe(u8, withoutSuffix(c.value)) else if (c.case_sensitive) try a.dupe(u8, c.value) else try fold(a, c.value);
        }
        return .{ .arena = arena, .config = .{ .filters_enabled = config.filters_enabled, .rules = rules } };
    }
    pub fn deinit(self: *Compiled) void {
        self.arena.deinit();
    }
    pub fn evaluate(self: *const Compiled, r: notes.Record) !Result {
        var result: Result = .{};
        if (!self.config.filters_enabled) return result;
        const values = [_][]const u8{ r.app.slice(), r.desktop_entry.slice(), r.summary.slice(), r.body.slice(), switch (r.urgency) {
            0 => "low",
            2 => "critical",
            else => "normal",
        } };
        var memory: [65536]u8 = undefined;
        var scratch = std.heap.FixedBufferAllocator.init(&memory);
        var folded: [5]?[]const u8 = @splat(null);
        for (self.config.rules, 0..) |rule, index| {
            if (!rule.enabled) continue;
            var matches = rule.match == .all;
            for (rule.conditions) |c| {
                const field = @intFromEnum(c.field);
                var actual = values[field];
                if (!c.case_sensitive) {
                    if (folded[field] == null) folded[field] = try fold(scratch.allocator(), actual);
                    actual = folded[field].?;
                }
                const hit = !(c.field == .desktop_entry and actual.len == 0) and switch (c.operator) {
                    .equals => std.mem.eql(u8, actual, c.value),
                    .contains => std.mem.indexOf(u8, actual, c.value) != null,
                };
                if (rule.match == .all) {
                    matches = matches and hit;
                } else {
                    matches = matches or hit;
                }
            }
            if (!matches) continue;
            result.indices[result.count] = index;
            result.count += 1;
            if (rule.action == .block) result.decision = .block else if (result.decision == .normal) result.decision = .history_only;
        }
        return result;
    }
};

test "notification filters validate disabled rules, IDs, fields and bounded literal conditions" {
    const t = std.testing;
    try (Config{}).validate();
    var conditions = [_]Condition{.{ .field = .summary, .operator = .contains, .value = "ready" }};
    var rules = [_]Rule{.{ .id = "one", .name = "Ready", .enabled = false, .conditions = &conditions }};
    const config: Config = .{ .rules = &rules };
    try config.validate();
    rules[0].conditions = &.{};
    try t.expectError(error.InvalidNotificationConditions, config.validate());
    rules[0].conditions = &conditions;
    conditions[0].value = "\xe3\x80\x80";
    try t.expectError(error.InvalidNotificationFilterText, config.validate());
    conditions[0] = .{ .field = .urgency, .value = "critical" };
    try t.expectError(error.InvalidNotificationComparison, config.validate());
    conditions[0].case_sensitive = true;
    try config.validate();
    conditions[0].value = "urgent";
    try t.expectError(error.InvalidNotificationUrgency, config.validate());
    conditions[0] = .{ .field = .desktop_entry, .value = "../bad", .case_sensitive = true };
    try t.expectError(error.InvalidNotificationDesktopId, config.validate());
    conditions[0].value = "org.example.App.desktop";
    try config.validate();
    try t.expectError(error.DuplicateNotificationFilterId, (Config{ .rules = &.{ rules[0], rules[0] } }).validate());
}
