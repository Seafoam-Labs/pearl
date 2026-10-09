//! Pure scxctl contract. Catalog data is never executable command text.
const std = @import("std");
pub const max_bytes = 65536;
pub const Action = enum { refresh, apply, stop };
pub const Mode = enum {
    auto,
    gaming,
    lowlatency,
    powersave,
    server,
    pub fn field(self: Mode) []const u8 {
        return switch (self) {
            .auto => "auto_mode",
            .gaming => "gaming_mode",
            .lowlatency => "lowlatency_mode",
            .powersave => "powersave_mode",
            .server => "server_mode",
        };
    }
    pub fn parse(text: []const u8) ?Mode {
        for (std.enums.values(Mode)) |mode| if (std.ascii.eqlIgnoreCase(text, @tagName(mode))) return mode;
        return null;
    }
};
pub const Scheduler = struct {
    name: []const u8,
    installed: bool = false,
    modes: [5]?[]const []const u8 = @splat(null),
    pub fn arguments(self: Scheduler, mode: Mode) ?[]const []const u8 {
        return self.modes[@intFromEnum(mode)];
    }
};
pub const Catalog = struct {
    default_sched: ?[]const u8 = null,
    default_mode: ?Mode = null,
    schedulers: []Scheduler = &.{},
    pub fn find(self: Catalog, name: []const u8) ?Scheduler {
        for (self.schedulers) |s| if (std.mem.eql(u8, name, s.name)) return s;
        return null;
    }
};
pub const Status = struct {
    kind: enum { unknown, stopped, running } = .unknown,
    scheduler: ?[]const u8 = null,
    mode: ?Mode = null,
    detail: []const u8 = "",
};
pub const Kernel = enum { unavailable, disabled, enabled, unknown };
pub const Snapshot = struct {
    generation: []const u8 = "0",
    pending: bool = false,
    available: bool = false,
    can_stop: bool = false,
    summary: []const u8 = "Loading scheduler configuration…",
    feedback: []const u8 = "",
    catalog: Catalog = .{},
    status: Status = .{},
    kernel: Kernel = .unavailable,
};
pub fn validName(name: []const u8) bool {
    if (name.len <= 4 or name.len > 100 or !std.mem.startsWith(u8, name, "scx_")) return false;
    for (name[4..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}
fn string(v: std.json.Value) ![]const u8 {
    if (v != .string or v.string.len > 1024 or !std.unicode.utf8ValidateSlice(v.string)) return error.InvalidConfig;
    for (v.string) |c| if (c < 32 or c == 127) return error.InvalidConfig;
    return v.string;
}
pub fn parseCatalog(a: std.mem.Allocator, bytes: []const u8) !Catalog {
    if (bytes.len > max_bytes) return error.ConfigTooLarge;
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .allocate = .alloc_always });
    if (root != .object) return error.InvalidConfig;
    const scheds = root.object.get("scheds") orelse return error.InvalidConfig;
    if (scheds != .object or scheds.object.count() > 64) return error.InvalidConfig;
    var result: Catalog = .{};
    if (root.object.get("default_sched")) |v| if (v != .null) {
        result.default_sched = try string(v);
        if (!validName(result.default_sched.?)) return error.InvalidConfig;
    };
    if (root.object.get("default_mode")) |v| result.default_mode = Mode.parse(try string(v));
    result.schedulers = try a.alloc(Scheduler, scheds.object.count());
    var iter = scheds.object.iterator();
    var index: usize = 0;
    while (iter.next()) |entry| : (index += 1) {
        if (!validName(entry.key_ptr.*) or entry.value_ptr.* != .object) return error.InvalidConfig;
        var scheduler: Scheduler = .{ .name = entry.key_ptr.* };
        for (std.enums.values(Mode)) |mode| if (entry.value_ptr.object.get(mode.field())) |v| {
            if (v != .array or v.array.items.len > 128) return error.InvalidConfig;
            const args = try a.alloc([]const u8, v.array.items.len);
            for (v.array.items, args) |arg, *target| target.* = try string(arg);
            scheduler.modes[@intFromEnum(mode)] = args;
        };
        result.schedulers[index] = scheduler;
    }
    std.mem.sort(Scheduler, result.schedulers, {}, struct {
        fn less(_: void, l: Scheduler, r: Scheduler) bool {
            return std.mem.lessThan(u8, l.name, r.name);
        }
    }.less);
    return result;
}
pub fn parseStatus(a: std.mem.Allocator, bytes: []const u8, catalog: Catalog) !Status {
    if (bytes.len > 8192 or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidStatus;
    for (bytes) |c| if ((c < 32 and c != '\n' and c != '\r' and c != '\t') or c == 127) return error.InvalidStatus;
    const text = std.mem.trim(u8, bytes, " \r\n\t");
    if (std.mem.eql(u8, text, "no scx scheduler running")) return .{ .kind = .stopped };
    if (!std.mem.startsWith(u8, text, "running ") or std.mem.indexOfScalar(u8, text, '\n') != null) return error.InvalidStatus;
    const rest = text[8..];
    const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidStatus;
    const name = rest[0..space];
    var scheduler: ?[]const u8 = null;
    for (catalog.schedulers) |s| if (std.ascii.eqlIgnoreCase(name, s.name) or std.ascii.eqlIgnoreCase(name, s.name[4..])) {
        scheduler = s.name;
        break;
    };
    if (scheduler == null) return error.InvalidStatus;
    const detail = rest[space + 1 ..];
    var mode: ?Mode = null;
    if (std.mem.startsWith(u8, detail, "in ") and std.mem.endsWith(u8, detail, " mode")) {
        mode = Mode.parse(detail[3 .. detail.len - 5]);
    } else if (!std.mem.eql(u8, detail, "with its own defaults") and !(std.mem.startsWith(u8, detail, "with arguments \"") and std.mem.endsWith(u8, detail, "\""))) return error.InvalidStatus;
    return .{ .kind = .running, .scheduler = scheduler, .mode = mode, .detail = try a.dupe(u8, detail) };
}
pub fn consistent(status: Status, kernel: Kernel) bool {
    return (status.kind == .stopped and kernel == .disabled) or (status.kind == .running and kernel == .enabled);
}
pub fn command(status: Status, kernel: Kernel) ![:0]const u8 {
    if (!consistent(status, kernel)) return error.StateMismatch;
    return if (status.kind == .stopped) "start" else "switch";
}
pub fn matches(status: Status, kernel: Kernel, s: Scheduler, mode: Mode) bool {
    if (!consistent(status, kernel) or status.kind != .running or !std.mem.eql(u8, status.scheduler orelse "", s.name)) return false;
    if (status.mode) |current| return current == mode;
    return std.mem.eql(u8, status.detail, "with its own defaults") and (s.arguments(mode) orelse return false).len == 0;
}

test "catalog preserves missing and empty modes and ignores additive fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try parseCatalog(a, "{\"default_sched\":null,\"default_mode\":\"Auto\",\"future\":true,\"scheds\":{\"scx_lavd\":{\"auto_mode\":[],\"gaming_mode\":[\"--performance\"]}}}");
    try std.testing.expect(c.default_sched == null);
    try std.testing.expectEqual(Mode.auto, c.default_mode.?);
    const s = c.find("scx_lavd").?;
    try std.testing.expectEqual(@as(usize, 0), s.arguments(.auto).?.len);
    try std.testing.expect(s.arguments(.server) == null);
    try std.testing.expectEqualStrings("--performance", s.arguments(.gaming).?[0]);
    for ([_][]const u8{ "{}", "{\"scheds\":[]}", "{\"scheds\":{\"../scx_bad\":{}}}", "{\"scheds\":{\"scx_x\":{\"auto_mode\":[1]}}}" }) |bad| try std.testing.expectError(error.InvalidConfig, parseCatalog(a, bad));
    try std.testing.expectError(error.ConfigTooLarge, parseCatalog(a, "x" ** (max_bytes + 1)));
}
test "runtime parsing never treats unknown output as stopped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try parseCatalog(a, "{\"scheds\":{\"scx_bpfland\":{\"auto_mode\":[],\"gaming_mode\":[]}}}");
    const stopped = try parseStatus(a, "no scx scheduler running\n", c);
    try std.testing.expectEqualStrings("start", try command(stopped, .disabled));
    try std.testing.expectError(error.StateMismatch, command(stopped, .enabled));
    const running = try parseStatus(a, "running Bpfland in Gaming mode\n", c);
    try std.testing.expectEqualStrings("switch", try command(running, .enabled));
    try std.testing.expect(matches(running, .enabled, c.schedulers[0], .gaming));
    try std.testing.expect(!matches(running, .disabled, c.schedulers[0], .gaming));
    try std.testing.expect((try parseStatus(a, "running Bpfland with arguments \"--hello world\"", c)).mode == null);
    const defaults = try parseStatus(a, "running Bpfland with its own defaults", c);
    try std.testing.expect(matches(defaults, .enabled, c.schedulers[0], .auto));
    for ([_][]const u8{ "", "permission denied", "running unknown in Auto mode", "running Bpfland", "no scx scheduler running\nerror" }) |bad| try std.testing.expectError(error.InvalidStatus, parseStatus(a, bad, c));
}
