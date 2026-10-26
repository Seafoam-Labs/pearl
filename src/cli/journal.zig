//! Correlate journal records without dropping untagged GTK/Wayland failures.
const std = @import("std");
const diagnostics = @import("../diagnostics/safe_text.zig");
pub const limit = 500;
pub const Result = struct { text: []const u8, truncated: bool, unverified: usize, excluded: usize };

fn field(value: std.json.Value, name: []const u8) []const u8 {
    if (value != .object) return "";
    const item = value.object.get(name) orelse return "";
    return if (item == .string) item.string else "";
}

pub fn filter(a: std.mem.Allocator, input: []const u8, session: []const u8, compositor_pid: ?u32) !Result {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var entries: std.ArrayList(std.json.Value) = .empty;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.eql(u8, line, "-- No entries --")) continue;
        if (entries.items.len > limit) return error.TooManyJournalRecords;
        const parsed = try std.json.parseFromSlice(std.json.Value, temp, line, .{ .allocate = .alloc_always });
        if (parsed.value != .object) return error.InvalidJournalRecord;
        try entries.append(temp, parsed.value);
    }
    const fingerprint = try std.fmt.allocPrint(temp, "{f}", .{diagnostics.fingerprint(session)});
    // First pass: associate whole processes, including messages that preceded
    // their session marker. Conflicting markers make a PID untrusted.
    const Process = struct { pid: u32, invocation: u64 };
    var pids: std.AutoHashMap(Process, bool) = .init(temp);
    for (entries.items) |entry| {
        const pid = std.fmt.parseInt(u32, field(entry, "_PID"), 10) catch continue;
        const message = field(entry, "MESSAGE");
        const start = std.mem.indexOf(u8, message, "session_hash=") orelse continue;
        const hash = message[start + "session_hash=".len ..];
        const matches = hash.len >= 16 and std.mem.eql(u8, hash[0..16], fingerprint) and
            (hash.len == 16 or !std.ascii.isHex(hash[16]));
        const key: Process = .{ .pid = pid, .invocation = std.hash.Fnv1a_64.hash(field(entry, "_SYSTEMD_INVOCATION_ID")) };
        const old = pids.get(key) orelse true;
        try pids.put(key, old and matches);
    }
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var result: Result = .{ .text = "", .truncated = entries.items.len > limit, .unverified = 0, .excluded = 0 };
    const first: usize = if (result.truncated) 1 else 0;
    for (entries.items[first..]) |entry| {
        const pid = std.fmt.parseInt(u32, field(entry, "_PID"), 10) catch 0;
        const known = pids.get(.{ .pid = pid, .invocation = std.hash.Fnv1a_64.hash(field(entry, "_SYSTEMD_INVOCATION_ID")) });
        if (known != null and !known.?) {
            result.excluded += 1;
            continue;
        }
        const verified = (compositor_pid != null and pid == compositor_pid.?) or known == true;
        if (!verified) result.unverified += 1;
        try out.writer.print("time_us={f} pid={d} invocation={f} attribution={s} {f}\n", .{
            diagnostics.safe(field(entry, "__REALTIME_TIMESTAMP")), pid,                                       diagnostics.safe(field(entry, "_SYSTEMD_INVOCATION_ID")),
            if (verified) "session" else "unverified",              diagnostics.safe(field(entry, "MESSAGE")),
        });
    }
    result.text = try out.toOwnedSlice();
    return result;
}

/// /proc/PID/stat's command can contain spaces and closing parentheses.
pub fn startTicks(stat: []const u8) !u64 {
    const end = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return error.InvalidProcessStat;
    var fields = std.mem.tokenizeScalar(u8, stat[end + 1 ..], ' ');
    for (0..19) |_| _ = fields.next() orelse return error.InvalidProcessStat;
    return std.fmt.parseInt(u64, fields.next() orelse return error.InvalidProcessStat, 10);
}

test "bounded journal marks truncation and handles empty or malformed streams" {
    const a = std.testing.allocator;
    const session = "01234567890123456789012345678901";
    var input: std.Io.Writer.Allocating = .init(a);
    defer input.deinit();
    for (0..limit + 1) |_| try input.writer.writeAll("{\"_PID\":\"20\",\"MESSAGE\":\"error\\n=== injected header ===\"}\n");
    const result = try filter(a, input.written(), session, 20);
    defer a.free(result.text);
    try std.testing.expect(result.truncated);
    try std.testing.expectEqual(@as(usize, limit), std.mem.count(u8, result.text, "attribution=session"));
    try std.testing.expect(std.mem.indexOf(u8, result.text, "\n=== injected") == null);
    const empty = try filter(a, "-- No entries --\n", session, 20);
    defer a.free(empty.text);
    try std.testing.expectEqualStrings("", empty.text);
    try std.testing.expectError(error.SyntaxError, filter(a, "broken", session, 20));
}

test "session correlation preserves early GTK errors and isolates old sessions" {
    const a = std.testing.allocator;
    const session = "01234567890123456789012345678901";
    const input = try std.fmt.allocPrint(a, "{{\"_PID\":\"10\",\"MESSAGE\":\"early GTK failure\"}}\n" ++
        "{{\"_PID\":\"10\",\"MESSAGE\":\"session_hash={f}\"}}\n" ++
        "{{\"_PID\":\"11\",\"MESSAGE\":\"session_hash=0000000000000000\"}}\n" ++
        "{{\"_PID\":\"11\",\"MESSAGE\":\"foreign crash\"}}\n" ++
        "{{\"_PID\":\"12\",\"MESSAGE\":\"unknown startup failure\"}}\n" ++
        "{{\"_PID\":\"20\",\"MESSAGE\":\"buffer import failed\"}}\n", .{diagnostics.fingerprint(session)});
    defer a.free(input);
    const result = try filter(a, input, session, 20);
    defer a.free(result.text);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "attribution=session early GTK failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "foreign crash") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "attribution=session buffer import failed") != null);
    try std.testing.expectEqual(@as(usize, 1), result.unverified);
    try std.testing.expectEqual(@as(usize, 2), result.excluded);
    try std.testing.expect(!result.truncated);
    try std.testing.expectError(error.InvalidProcessStat, startTicks("invalid"));
    try std.testing.expectEqual(@as(u64, 987), try startTicks("1 (command with ) spaces) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 987 0"));
}

test "a reused PID in another invocation does not contaminate session attribution" {
    const a = std.testing.allocator;
    const session = "01234567890123456789012345678901";
    const input = try std.fmt.allocPrint(a, "{{\"_PID\":\"10\",\"_SYSTEMD_INVOCATION_ID\":\"old\",\"MESSAGE\":\"session_hash=0000000000000000\"}}\n" ++
        "{{\"_PID\":\"10\",\"_SYSTEMD_INVOCATION_ID\":\"new\",\"MESSAGE\":\"session_hash={f}\"}}\n" ++
        "{{\"_PID\":\"10\",\"_SYSTEMD_INVOCATION_ID\":\"new\",\"MESSAGE\":\"GTK failure\"}}\n", .{diagnostics.fingerprint(session)});
    defer a.free(input);
    const result = try filter(a, input, session, null);
    defer a.free(result.text);
    try std.testing.expectEqual(@as(usize, 1), result.excluded);
    try std.testing.expectEqual(@as(usize, 0), result.unverified);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "attribution=session GTK failure") != null);
}
