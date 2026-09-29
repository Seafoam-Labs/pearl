//! Runtime logging control plane. Filtering happens here rather than in
//! std.log so every level stays compiled in and a support session can raise
//! verbosity without a rebuild.
const std = @import("std");

/// Every scope label used in the tree must be a member: a `std.log.scoped`
/// label that is not declared here fails to compile at its call site. Add new
/// scopes only when filtering on them is meaningful.
pub const Scope = enum {
    default,
    core,
    desktop,
    ui,
    settings,
    lock,
    greeter,
    config,
    services,
    platform,
    aqueous,
    theme,
    plugins,
    cli,
    pearl,
    gallery,
};

pub var runtime_level: std.log.Level = std.log.default_level;
pub var runtime_scopes: std.EnumSet(Scope) = .full;

pub const std_options: std.Options = .{ .log_level = .debug, .logFn = logFn };

pub fn parseLevel(text: []const u8) ?std.log.Level {
    if (std.mem.eql(u8, text, "error")) return .err;
    if (std.mem.eql(u8, text, "warning")) return .warn;
    if (std.mem.eql(u8, text, "info")) return .info;
    if (std.mem.eql(u8, text, "debug")) return .debug;
    return null;
}

/// Accepts `all`, a comma-separated list, and `~scope` exclusions, in any
/// order, so `all,~gallery` means every scope except `gallery`.
pub fn parseScopes(text: []const u8) ?std.EnumSet(Scope) {
    var scopes: std.EnumSet(Scope) = .empty;
    var items = std.mem.splitScalar(u8, text, ',');
    while (items.next()) |item| {
        if (std.mem.eql(u8, item, "all")) {
            scopes = .full;
        } else if (item.len > 1 and item[0] == '~') {
            scopes.remove(std.meta.stringToEnum(Scope, item[1..]) orelse return null);
        } else {
            scopes.insert(std.meta.stringToEnum(Scope, item) orelse return null);
        }
    }
    return scopes;
}

pub fn apply(level: ?std.log.Level, scopes: ?std.EnumSet(Scope)) void {
    if (level) |value| runtime_level = value;
    if (scopes) |value| runtime_scopes = value;
}

/// Outcome of matching the two verbosity flags against the remaining arguments
/// of an executable that parses its own command line.
pub const Verbosity = union(enum) {
    /// Neither flag: the caller's argument loop keeps ownership of the argument.
    other,
    /// Applied; the value behind the flag is consumed with it.
    applied,
    rejected: Rejection,
};

pub const Rejection = struct {
    pub const Flag = enum { level, scopes };

    flag: Flag,
    /// Empty when the flag arrived without a value.
    value: []const u8,
};

/// Recognises `--log-level LEVEL` and `--log-scopes LIST` at the head of the
/// remaining arguments and applies them, so any executable can offer the same
/// verbosity control without a shared argument parser.
pub fn verbosity(args: []const []const u8) Verbosity {
    if (args.len == 0) return .other;
    const flag: Rejection.Flag = if (std.mem.eql(u8, args[0], "--log-level"))
        .level
    else if (std.mem.eql(u8, args[0], "--log-scopes"))
        .scopes
    else
        return .other;
    if (args.len < 2) return .{ .rejected = .{ .flag = flag, .value = "" } };
    const value = args[1];
    if (flag == .level) {
        const parsed = parseLevel(value) orelse return .{ .rejected = .{ .flag = flag, .value = value } };
        apply(parsed, null);
    } else {
        const parsed = parseScopes(value) orelse return .{ .rejected = .{ .flag = flag, .value = value } };
        apply(null, parsed);
    }
    return .applied;
}

/// Renders a rejected flag on the `cli` scope. `value` is the rejected text as
/// the caller wants it written, already wrapped for redaction: this module
/// depends on nothing but std so any executable can wire it as a module. The
/// exit code stays with the caller, which owns its own usage contract.
pub fn report(rejection: Rejection, value: anytype) void {
    const cli = std.log.scoped(.cli);
    const flag = switch (rejection.flag) {
        .level => "--log-level",
        .scopes => "--log-scopes",
    };
    if (rejection.value.len == 0) {
        cli.err("Missing value for {s}.", .{flag});
        return;
    }
    switch (rejection.flag) {
        .level => cli.err("Unknown log level {f}; expected error, warning, info or debug.", .{value}),
        .scopes => cli.err("Unknown log scope in {f}.", .{value}),
    }
}

/// Unscoped `.default` lines always pass: they are the unconverted and
/// third-party sites a scope filter must never hide.
fn passes(comptime level: std.log.Level, comptime scope: Scope) bool {
    if (@intFromEnum(level) > @intFromEnum(runtime_level)) return false;
    return scope == .default or runtime_scopes.contains(scope);
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!passes(level, scope)) return;
    const io = std.Options.debug_io;
    const previous = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous);
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    // One lock for envelope and body, so a line is never interleaved.
    writeEnvelope(stderr.writer, nowSeconds(), @intCast(std.os.linux.getpid())) catch {};
    std.log.defaultLogFileTerminal(level, scope, format, args, stderr) catch {};
}

fn nowSeconds() u64 {
    const seconds = std.Io.Clock.real.now(std.Options.debug_io).toSeconds();
    // A wrong wall clock must not trap inside the logger.
    return if (seconds > 0) @intCast(seconds) else 0;
}

/// `ts=<iso8601 utc> pid=<n> ` written ahead of the standard body.
fn writeEnvelope(writer: *std.Io.Writer, seconds: u64, pid: u64) std.Io.Writer.Error!void {
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    try writer.print("ts={:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}Z pid={} ", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
        pid,
    });
}

fn envelope(storage: *[64]u8, seconds: u64, pid: u64) []const u8 {
    var writer = std.Io.Writer.fixed(storage);
    writeEnvelope(&writer, seconds, pid) catch unreachable;
    return writer.buffered();
}

test "envelope renders iso8601 utc and pid" {
    var storage: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ts=1970-01-01T00:00:00Z pid=1 ", envelope(&storage, 0, 1));
    try std.testing.expectEqualStrings("ts=2001-09-09T01:46:40Z pid=4242 ", envelope(&storage, 1_000_000_000, 4242));
    try std.testing.expectEqualStrings("ts=2024-02-29T00:00:00Z pid=7 ", envelope(&storage, 1_709_164_800, 7));
}

test "parseLevel accepts the documented spellings only" {
    try std.testing.expectEqual(std.log.Level.err, parseLevel("error").?);
    try std.testing.expectEqual(std.log.Level.warn, parseLevel("warning").?);
    try std.testing.expectEqual(std.log.Level.info, parseLevel("info").?);
    try std.testing.expectEqual(std.log.Level.debug, parseLevel("debug").?);
    for ([_][]const u8{ "", "Error", "warn", "verbose", "debug " }) |text|
        try std.testing.expectEqual(null, parseLevel(text));
}

test "parseScopes handles all, lists and exclusions" {
    try std.testing.expectEqual(std.EnumSet(Scope).full, parseScopes("all").?);
    const listed = parseScopes("core,ui").?;
    try std.testing.expect(listed.contains(.core) and listed.contains(.ui));
    try std.testing.expectEqual(@as(usize, 2), listed.count());
    const excluded = parseScopes("all,~gallery,~ui").?;
    try std.testing.expect(!excluded.contains(.gallery) and !excluded.contains(.ui));
    try std.testing.expect(excluded.contains(.core));
    for ([_][]const u8{ "", "bogus", "~bogus", "~", "core,,ui" }) |text|
        try std.testing.expectEqual(null, parseScopes(text));
}

test "verbosity flags are recognised, applied and rejected" {
    const saved_level = runtime_level;
    const saved_scopes = runtime_scopes;
    defer {
        runtime_level = saved_level;
        runtime_scopes = saved_scopes;
    }
    for ([_][]const []const u8{ &.{}, &.{"--width=100"}, &.{"--log-levels"}, &.{ "--log-levelx", "debug" } }) |args|
        try std.testing.expectEqual(Verbosity.other, verbosity(args));
    try std.testing.expectEqual(Verbosity.applied, verbosity(&.{ "--log-level", "debug" }));
    try std.testing.expectEqual(std.log.Level.debug, runtime_level);
    try std.testing.expectEqual(Verbosity.applied, verbosity(&.{ "--log-scopes", "all,~cli" }));
    try std.testing.expect(!runtime_scopes.contains(.cli) and runtime_scopes.contains(.ui));
    const cases = [_]struct { args: []const []const u8, flag: Rejection.Flag, value: []const u8 }{
        .{ .args = &.{"--log-level"}, .flag = .level, .value = "" },
        .{ .args = &.{ "--log-level", "bogus" }, .flag = .level, .value = "bogus" },
        .{ .args = &.{"--log-scopes"}, .flag = .scopes, .value = "" },
        .{ .args = &.{ "--log-scopes", "" }, .flag = .scopes, .value = "" },
    };
    for (cases) |case| {
        const rejected = verbosity(case.args).rejected;
        try std.testing.expectEqual(case.flag, rejected.flag);
        try std.testing.expectEqualStrings(case.value, rejected.value);
    }
}

test "level gate admits only configured severity" {
    const saved_level = runtime_level;
    defer runtime_level = saved_level;
    runtime_level = .err;
    try std.testing.expect(passes(.err, .core));
    try std.testing.expect(!passes(.warn, .core));
    runtime_level = .debug;
    try std.testing.expect(passes(.debug, .core));
    try std.testing.expect(passes(.info, .core));
}

test "scope filter exempts the default scope" {
    const saved_level = runtime_level;
    const saved_scopes = runtime_scopes;
    defer {
        runtime_level = saved_level;
        runtime_scopes = saved_scopes;
    }
    runtime_level = .debug;
    runtime_scopes = .empty;
    try std.testing.expect(passes(.err, .default));
    try std.testing.expect(!passes(.err, .core));
    runtime_scopes = .full;
    try std.testing.expect(passes(.err, .core));
}
