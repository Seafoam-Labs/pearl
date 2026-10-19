//! Scheduling profiles: named scx.service command lines read from the system's
//! scheduling-profiles.json, and the /etc/default/scx file that applies them.
//! Pure data; the privileged helper writes the file and drives systemd.
const std = @import("std");

pub const file_name = "scheduling-profiles.json";
pub const env_path = "/etc/default/scx";
pub const max_profiles = 8;
pub const max_bytes = 16384;
pub const max_args = 32;
/// The kernel's sched_ext state, from /sys/kernel/sched_ext/state.
pub const Kernel = enum { unavailable, disabled, enabled, unknown };

/// Scheduler binaries are named scx_<name>.
pub fn validName(name: []const u8) bool {
    if (name.len <= 4 or name.len > 100 or !std.mem.startsWith(u8, name, "scx_")) return false;
    for (name[4..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

pub const Profile = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8 = "",
    /// Scheduler binary, for example scx_cosmos. Null only for stop profiles.
    sched: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    /// Return to the kernel's default scheduler by disabling scx.service.
    stop: bool = false,
};

pub const Config = struct {
    profiles: []const Profile,
    pub fn find(self: Config, id: []const u8) ?usize {
        for (self.profiles, 0..) |profile, i| if (std.mem.eql(u8, profile.id, id)) return i;
        return null;
    }
};

/// The escape hatch every configuration offers, added when a file omits it.
pub const builtin_default: Profile = .{ .id = "default", .label = "Default", .description = "The kernel's built-in scheduler (EEVDF).", .stop = true };

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 32) return false;
    for (id) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return false;
    return true;
}

/// Arguments are written unquoted into /etc/default/scx and word-split by the
/// unit's shell, so they must never contain whitespace, quotes or shell syntax.
pub fn validArg(arg: []const u8) bool {
    if (arg.len == 0 or arg.len > 128) return false;
    for (arg) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-_.=,:+/%@", c) == null) return false;
    return true;
}

pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Config {
    if (bytes.len > max_bytes) return error.InvalidProfiles;
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return error.InvalidProfiles;
    if (root != .object) return error.InvalidProfiles;
    const version = root.object.get("version") orelse return error.InvalidProfiles;
    if (version != .integer or version.integer != 2) return error.UnsupportedProfilesVersion;
    const list = root.object.get("profiles") orelse return error.InvalidProfiles;
    if (list != .array or list.array.items.len == 0 or list.array.items.len > max_profiles) return error.InvalidProfiles;
    var profiles: std.ArrayList(Profile) = .empty;
    var has_stop = false;
    for (list.array.items) |item| {
        if (item != .object) return error.InvalidProfiles;
        const id = try text(item, "id") orelse return error.InvalidProfiles;
        if (!validId(id)) return error.InvalidProfiles;
        for (profiles.items) |previous| if (std.mem.eql(u8, previous.id, id)) return error.DuplicateProfile;
        const label = try text(item, "label") orelse return error.InvalidProfiles;
        if (label.len == 0 or label.len > 64) return error.InvalidProfiles;
        const description = try text(item, "description") orelse "";
        if (description.len > 256) return error.InvalidProfiles;
        var profile: Profile = .{ .id = id, .label = label, .description = description };
        if (try text(item, "action")) |action| {
            if (!std.mem.eql(u8, action, "stop") or item.object.get("sched") != null or item.object.get("args") != null) return error.InvalidProfiles;
            profile.stop = true;
            has_stop = true;
        } else {
            const sched = try text(item, "sched") orelse return error.InvalidProfiles;
            if (!validName(sched)) return error.InvalidProfiles;
            profile.sched = sched;
            if (item.object.get("args")) |args| {
                if (args != .array or args.array.items.len > max_args) return error.InvalidProfiles;
                const out = try a.alloc([]const u8, args.array.items.len);
                for (args.array.items, out) |arg, *slot| {
                    if (arg != .string or !validArg(arg.string)) return error.InvalidProfiles;
                    slot.* = arg.string;
                }
                profile.args = out;
            }
        }
        try profiles.append(a, profile);
    }
    if (!has_stop) try profiles.insert(a, 0, builtin_default);
    return .{ .profiles = profiles.items };
}

fn text(item: std.json.Value, key: []const u8) !?[]const u8 {
    const value = item.object.get(key) orelse return null;
    if (value != .string or !std.unicode.utf8ValidateSlice(value.string)) return error.InvalidProfiles;
    for (value.string) |c| if (c < 32 or c == 127) return error.InvalidProfiles;
    return value.string;
}

/// What /etc/default/scx says. Pearl owns the file; the profile line records
/// which profile wrote it so the running scheduler can be attributed.
pub const Env = struct {
    profile: ?[]const u8 = null,
    sched: []const u8 = "",
    flags: []const u8 = "",
};

pub fn render(a: std.mem.Allocator, profile: Profile) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const writer = &out.writer;
    try writer.writeAll("# Managed by Pearl scheduling profiles; changes here are replaced when a\n# profile is selected. Edit scheduling-profiles.json to change the profiles.\n");
    try writer.print("PEARL_PROFILE={s}\nSCX_SCHEDULER={s}\nSCX_FLAGS='", .{ profile.id, profile.sched orelse "" });
    for (profile.args, 0..) |arg, i| try writer.print("{s}{s}", .{ if (i == 0) "" else " ", arg });
    try writer.writeAll("'\n");
    return out.toOwnedSlice();
}

pub fn parseEnv(bytes: []const u8) Env {
    var env: Env = .{};
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len >= 2 and (value[0] == '\'' or value[0] == '"') and value[value.len - 1] == value[0]) value = value[1 .. value.len - 1];
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (std.mem.eql(u8, key, "PEARL_PROFILE")) env.profile = value;
        if (std.mem.eql(u8, key, "SCX_SCHEDULER")) env.sched = value;
        if (std.mem.eql(u8, key, "SCX_FLAGS")) env.flags = value;
    }
    return env;
}

/// The file still holds exactly what the profile would write.
pub fn matches(profile: Profile, env: Env) bool {
    if (profile.stop) return true;
    if (!std.mem.eql(u8, env.sched, profile.sched.?)) return false;
    var flags = std.mem.tokenizeScalar(u8, env.flags, ' ');
    for (profile.args) |arg| if (!std.mem.eql(u8, flags.next() orelse return false, arg)) return false;
    return flags.next() == null;
}

/// The profile that turns sched_ext schedulers off; parse guarantees one.
fn firstStop(config: Config) ?usize {
    for (config.profiles, 0..) |profile, i| if (profile.stop) return i;
    return null;
}

pub const Unit = enum { unknown, missing, active, activating, deactivating, inactive, failed };

pub fn unitFrom(load_state: []const u8, active_state: []const u8) Unit {
    if (std.mem.eql(u8, load_state, "not-found")) return .missing;
    return std.meta.stringToEnum(Unit, active_state) orelse .unknown;
}

pub const Status = struct {
    kind: enum { unavailable, off, running, starting, failed, custom } = .unavailable,
    /// The profile selected in /etc/default/scx, for running, starting and failed.
    profile: ?usize = null,
};

/// sched_ext names an attached scheduler <name>_<version>_<target>, where
/// <name> is the binary name without its scx_ prefix.
pub fn opsMatches(sched: []const u8, ops: []const u8) bool {
    const name = if (std.mem.startsWith(u8, sched, "scx_")) sched[4..] else sched;
    return name.len > 0 and std.mem.startsWith(u8, ops, name) and (ops.len == name.len or ops[name.len] == '_');
}

/// The version an attached scheduler reports in its ops name, if any.
pub fn opsVersion(sched: []const u8, ops: []const u8) ?[]const u8 {
    if (!opsMatches(sched, ops)) return null;
    const name_len = if (std.mem.startsWith(u8, sched, "scx_")) sched.len - 4 else sched.len;
    if (ops.len <= name_len + 1) return null;
    const rest = ops[name_len + 1 ..];
    const version = rest[0 .. std.mem.indexOfScalar(u8, rest, '_') orelse rest.len];
    return if (version.len > 0 and std.ascii.isDigit(version[0])) version else null;
}

/// Why a scheduler stopped, from its scx.service log: the sched_ext exit
/// message, else the scheduler's last error.
pub fn exitReason(log: []const u8) ?[]const u8 {
    var exit: ?[]const u8 = null;
    var failure: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.lastIndexOf(u8, line, "EXIT: ")) |i| {
            exit = std.mem.trim(u8, line[i + 6 ..], " ");
        } else if (std.mem.startsWith(u8, line, "Error: ")) {
            failure = std.mem.trim(u8, line[7..], " ");
        }
    }
    const reason = exit orelse failure orelse return null;
    return if (reason.len > 0) reason else null;
}

/// How systemd saw the main process end, for when the log is not readable.
/// code is the CLD_* value systemd reports in ExecMainCode.
pub fn processReason(buffer: []u8, result: []const u8, code: i32, status_code: i32) ?[]const u8 {
    const again = if (std.mem.eql(u8, result, "start-limit-hit")) " repeatedly" else "";
    const signal: []const u8 = switch (status_code) {
        6 => "SIGABRT",
        9 => "SIGKILL",
        11 => "SIGSEGV",
        15 => "SIGTERM",
        else => "",
    };
    return switch (code) {
        1 => if (status_code != 0) std.fmt.bufPrint(buffer, "exited with status {d}{s}", .{ status_code, again }) catch null else std.fmt.bufPrint(buffer, "exited{s}", .{again}) catch null,
        2, 3 => if (signal.len > 0) std.fmt.bufPrint(buffer, "{s} {s}{s}", .{ if (code == 2) "killed by" else "crashed with", signal, again }) catch null else std.fmt.bufPrint(buffer, "{s} signal {d}{s}", .{ if (code == 2) "killed by" else "crashed with", status_code, again }) catch null,
        else => if (again.len > 0) "restarted too often" else null,
    };
}

/// ops is the attached scheduler's name from /sys/kernel/sched_ext/root/ops.
/// switching is true while a profile chosen moments ago is still taking over:
/// /etc/default/scx was written after the running instance started, so the
/// previous scheduler may still be attached or the unit briefly inactive.
pub fn status(config: Config, env: Env, unit: Unit, kernel: Kernel, ops: []const u8, switching: bool) Status {
    if (kernel == .unavailable or unit == .missing) return .{};
    const selected: ?usize = if (env.profile) |id| config.find(id) else null;
    const profile = if (selected) |i| config.profiles[i] else null;
    const scheduler = if (profile) |p| !p.stop and matches(p, env) else false;
    const stopping = if (profile) |p| p.stop else false;
    const settling: Status = .{ .kind = .starting, .profile = selected };
    return switch (unit) {
        // Running means the kernel reports the profile's own scheduler attached.
        .active => if (scheduler) (if (kernel != .enabled or ops.len == 0) settling else if (opsMatches(profile.?.sched.?, ops)) .{ .kind = .running, .profile = selected } else if (switching) settling else .{ .kind = .custom }) else if (stopping and switching) settling else .{ .kind = .custom },
        .activating, .deactivating => if (scheduler or (stopping and switching)) settling else .{ .kind = .custom },
        // A selected scheduler that is no longer running has failed, whether
        // systemd marked the unit failed or the scheduler exited cleanly.
        .failed, .inactive, .unknown => if (scheduler) (if (switching and unit != .failed) settling else .{ .kind = .failed, .profile = selected }) else if (kernel == .enabled) (if (stopping and switching) settling else .{ .kind = .custom }) else .{ .kind = .off, .profile = if (stopping) selected else firstStop(config) },
        .missing => unreachable,
    };
}

const t = std.testing;
const sample =
    \\{"version":2,"profiles":[
    \\ {"id":"balanced","label":"Balanced","description":"Everyday use.","sched":"scx_cosmos"},
    \\ {"id":"latency","label":"Low latency","sched":"scx_cosmos","args":["-s","700","-m","performance","-w"]},
    \\ {"id":"powersave","label":"Power saver","sched":"scx_cosmos","args":["-m","powersave"]}]}
;

test "profiles parse command lines, add the default profile and reject unsafe entries" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parse(a, sample);
    try t.expectEqual(@as(usize, 4), config.profiles.len);
    try t.expect(config.profiles[0].stop);
    try t.expectEqualStrings("default", config.profiles[0].id);
    try t.expectEqualStrings("scx_cosmos", config.profiles[1].sched.?);
    try t.expectEqual(@as(usize, 5), config.profiles[2].args.len);
    const explicit = try parse(a, "{\"version\":2,\"profiles\":[{\"id\":\"off\",\"label\":\"Off\",\"action\":\"stop\"},{\"id\":\"a\",\"label\":\"A\",\"sched\":\"scx_lavd\"}]}");
    try t.expectEqual(@as(usize, 2), explicit.profiles.len);
    for ([_][]const u8{
        "{\"version\":1,\"profiles\":[{\"id\":\"a\",\"label\":\"A\",\"sched\":\"scx_lavd\"}]}",
        "{\"version\":2,\"profiles\":[{\"id\":\"a\",\"label\":\"A\"}]}",
        "{\"version\":2,\"profiles\":[{\"id\":\"a\",\"label\":\"A\",\"sched\":\"lavd\"}]}",
        "{\"version\":2,\"profiles\":[{\"id\":\"a\",\"label\":\"A\",\"sched\":\"scx_lavd\",\"args\":[\"-s 700\"]}]}",
        "{\"version\":2,\"profiles\":[{\"id\":\"a\",\"label\":\"A\",\"sched\":\"scx_lavd\",\"args\":[\"$(reboot)\"]}]}",
        "{\"version\":2,\"profiles\":[{\"id\":\"a\",\"label\":\"A\",\"sched\":\"scx_lavd\",\"args\":[\"'\"]}]}",
        "{\"version\":2,\"profiles\":[{\"id\":\"a\",\"label\":\"A\",\"action\":\"stop\",\"sched\":\"scx_lavd\"}]}",
    }) |bad| try t.expect(std.meta.isError(parse(a, bad)));
}

test "the environment file round-trips and attributes the running scheduler" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parse(a, sample);
    const latency = config.profiles[2];
    const env = parseEnv(try render(a, latency));
    try t.expectEqualStrings("latency", env.profile.?);
    try t.expectEqualStrings("scx_cosmos", env.sched);
    try t.expectEqualStrings("-s 700 -m performance -w", env.flags);
    try t.expect(matches(latency, env));
    try t.expect(!matches(config.profiles[1], env));
    try t.expectEqual(Status{ .kind = .running, .profile = 2 }, status(config, env, .active, .enabled, "cosmos_1.1.7_x86_64_unknown_linux_gnu", false));
    try t.expectEqual(Status{ .kind = .starting, .profile = 2 }, status(config, env, .activating, .disabled, "", false));
    try t.expectEqual(Status{ .kind = .failed, .profile = 2 }, status(config, env, .failed, .disabled, "", false));
    try t.expectEqual(Status{ .kind = .failed, .profile = 2 }, status(config, env, .inactive, .disabled, "", false));
    // A hand-edited file or another loader is not attributed to a profile.
    var edited = env;
    edited.flags = "-s 700";
    try t.expectEqual(Status{ .kind = .custom }, status(config, edited, .active, .enabled, "", false));
    try t.expectEqual(Status{ .kind = .custom }, status(config, .{}, .inactive, .enabled, "", false));
    const off = parseEnv(try render(a, config.profiles[0]));
    try t.expectEqual(Status{ .kind = .off, .profile = 0 }, status(config, off, .inactive, .disabled, "", false));
    try t.expectEqual(Status{ .kind = .off, .profile = 0 }, status(config, .{}, .inactive, .disabled, "", false));
    try t.expectEqual(Status{}, status(config, env, .missing, .disabled, "", false));
    // A file whose own profile turns scx off is shown as that profile.
    const own = try parse(a, "{\"version\":2,\"profiles\":[{\"id\":\"latency\",\"label\":\"Low latency\",\"sched\":\"scx_cosmos\"},{\"id\":\"balanced\",\"label\":\"Balanced\",\"action\":\"stop\"}]}");
    try t.expectEqual(@as(usize, 2), own.profiles.len);
    try t.expectEqual(Status{ .kind = .off, .profile = 1 }, status(own, .{}, .inactive, .disabled, "", false));
    try t.expectEqual(Status{}, status(config, env, .active, .unavailable, "", false));
    // Only the profile's own scheduler counts as running.
    try t.expectEqual(Status{ .kind = .starting, .profile = 2 }, status(config, env, .active, .enabled, "", false));
    try t.expectEqual(Status{ .kind = .custom }, status(config, env, .active, .enabled, "lavd_1.0.20_x86_64_unknown_linux_gnu", false));
    // While a profile chosen moments ago takes over, the previous scheduler
    // is still attached or the unit is briefly down; neither is custom or failed.
    const lavd = "lavd_1.0.20_x86_64_unknown_linux_gnu";
    try t.expectEqual(Status{ .kind = .starting, .profile = 2 }, status(config, env, .active, .enabled, lavd, true));
    try t.expectEqual(Status{ .kind = .starting, .profile = 2 }, status(config, env, .inactive, .disabled, "", true));
    try t.expectEqual(Status{ .kind = .failed, .profile = 2 }, status(config, env, .failed, .disabled, "", true));
    try t.expectEqual(Status{ .kind = .starting, .profile = 0 }, status(config, off, .active, .enabled, lavd, true));
    try t.expectEqual(Status{ .kind = .starting, .profile = 0 }, status(config, off, .deactivating, .enabled, lavd, true));
    try t.expectEqual(Status{ .kind = .starting, .profile = 0 }, status(config, off, .inactive, .enabled, lavd, true));
    try t.expectEqual(Status{ .kind = .off, .profile = 0 }, status(config, off, .inactive, .disabled, "", true));
    // A scheduler started after the file was written is not ours.
    try t.expectEqual(Status{ .kind = .custom }, status(config, off, .active, .enabled, lavd, false));
}

test "attached schedulers and exit reasons are read from kernel and log text" {
    try t.expect(opsMatches("scx_cosmos", "cosmos_1.1.7_x86_64_unknown_linux_gnu"));
    try t.expect(opsMatches("scx_eevdf", "eevdf"));
    try t.expect(!opsMatches("scx_cosmos", "cosmosx_1.0"));
    try t.expect(!opsMatches("scx_lavd", "cosmos_1.1.7"));
    try t.expectEqualStrings("1.1.7", opsVersion("scx_cosmos", "cosmos_1.1.7_x86_64_unknown_linux_gnu").?);
    try t.expect(opsVersion("scx_eevdf", "eevdf") == null);
    const log =
        \\13:41:25 [INFO] scheduler options: scx_cosmos
        \\EXIT: unregistered from user space
        \\13:50:00 [INFO] scheduler options: scx_cosmos
        \\Error: EXIT: runnable task stall (khugepaged[77] failed to run for 5.631s) on CPU 6
        \\scx.service: Main process exited, code=exited, status=1/FAILURE
    ;
    try t.expectEqualStrings("runnable task stall (khugepaged[77] failed to run for 5.631s) on CPU 6", exitReason(log).?);
    try t.expectEqualStrings("Failed to open BPF object", exitReason("Error: Failed to open BPF object\n").?);
    try t.expect(exitReason("13:41:25 [INFO] scheduler options: scx_cosmos\n") == null);
    var buffer: [64]u8 = undefined;
    try t.expectEqualStrings("killed by SIGKILL", processReason(&buffer, "signal", 2, 9).?);
    try t.expectEqualStrings("crashed with signal 7", processReason(&buffer, "core-dump", 3, 7).?);
    try t.expectEqualStrings("exited with status 1", processReason(&buffer, "exit-code", 1, 1).?);
    try t.expectEqualStrings("killed by SIGKILL repeatedly", processReason(&buffer, "start-limit-hit", 2, 9).?);
    try t.expectEqualStrings("restarted too often", processReason(&buffer, "start-limit-hit", 0, 0).?);
}
