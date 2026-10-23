//! Scheduling profiles: named scx.service command lines read from the system's
//! scheduling-profiles.json, and the /etc/default/scx file that applies them.
//! Pure data; the privileged helper writes the file and drives systemd.
const std = @import("std");

pub const file_name = "scheduling-profiles.json";
pub const env_path = "/etc/default/scx";
pub const max_profiles = 16;
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

/// Where schedulers may run from, in the order scx.service's shell searches
/// them.
pub const scheduler_dirs = [_][]const u8{ "/usr/local/bin", "/usr/bin" };

/// A scheduler as a profile names it: an absolute path in one of
/// scheduler_dirs, or a binary name that the helper resolves to one.
pub fn validSched(sched: []const u8) bool {
    if (sched.len == 0 or sched[0] != '/') return validName(sched);
    const dir = std.fs.path.dirname(sched) orelse return false;
    for (scheduler_dirs) |allowed| if (std.mem.eql(u8, dir, allowed)) return validName(std.fs.path.basename(sched));
    return false;
}

/// The binary name of a scheduler given by path or name.
pub fn schedName(sched: []const u8) []const u8 {
    return std.fs.path.basename(sched);
}

/// Both name the same scheduler. Two paths must be equal; a bare name, as
/// older files hold, matches the path it resolves to by name.
pub fn sameSched(x: []const u8, y: []const u8) bool {
    if (x.len > 0 and y.len > 0 and x[0] == '/' and y[0] == '/') return std.mem.eql(u8, x, y);
    return std.mem.eql(u8, schedName(x), schedName(y));
}

pub const Profile = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8 = "",
    /// Scheduler binary, for example /usr/bin/scx_cosmos. Null only for stop
    /// profiles.
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
            if (!validSched(sched)) return error.InvalidProfiles;
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
    if (!sameSched(env.sched, profile.sched.?)) return false;
    var flags = std.mem.tokenizeScalar(u8, env.flags, ' ');
    for (profile.args) |arg| if (!std.mem.eql(u8, flags.next() orelse return false, arg)) return false;
    return flags.next() == null;
}

/// The profile that turns sched_ext schedulers off; parse guarantees one.
pub fn firstStop(config: Config) ?usize {
    for (config.profiles, 0..) |profile, i| if (profile.stop) return i;
    return null;
}

/// The profiles as a profile file that parse reads back unchanged.
pub fn serialize(a: std.mem.Allocator, config: Config) ![]u8 {
    const Entry = struct {
        id: []const u8,
        label: []const u8,
        action: ?[]const u8 = null,
        sched: ?[]const u8 = null,
        args: ?[]const []const u8 = null,
        description: ?[]const u8 = null,
    };
    const entries = try a.alloc(Entry, config.profiles.len);
    for (config.profiles, entries) |profile, *entry| entry.* = .{
        .id = profile.id,
        .label = profile.label,
        .action = if (profile.stop) "stop" else null,
        .sched = profile.sched,
        .args = if (profile.stop) null else profile.args,
        .description = if (profile.description.len > 0) profile.description else null,
    };
    return std.json.Stringify.valueAlloc(a, .{ .version = 2, .profiles = entries }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
}

/// Both profiles run the same command, or both turn sched_ext off.
pub fn sameCommand(x: Profile, y: Profile) bool {
    if (x.stop or y.stop) return x.stop and y.stop;
    if (!sameSched(x.sched.?, y.sched.?) or x.args.len != y.args.len) return false;
    for (x.args, y.args) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}

/// An id for a new profile, from its label: lowercase letters, digits and
/// dashes, unique among the existing profiles.
pub fn slug(buffer: *[32]u8, label: []const u8, config: Config) []const u8 {
    var len: usize = 0;
    for (label) |c| {
        if (len == 24) break;
        if (std.ascii.isAlphanumeric(c)) {
            buffer[len] = std.ascii.toLower(c);
            len += 1;
        } else if (len > 0 and buffer[len - 1] != '-') {
            buffer[len] = '-';
            len += 1;
        }
    }
    while (len > 0 and buffer[len - 1] == '-') len -= 1;
    if (len == 0) {
        @memcpy(buffer[0..7], "profile");
        len = 7;
    }
    const base = len;
    var n: usize = 2;
    while (config.find(buffer[0..len]) != null) : (n += 1) {
        len = base + (std.fmt.bufPrint(buffer[base..], "-{d}", .{n}) catch unreachable).len;
    }
    return buffer[0..len];
}

/// The profile to apply once the list changes from before to after, so the
/// running scheduler keeps matching the selected profile: the same profile
/// when its command changed, Default when it is gone, else nothing.
pub fn reapply(before: Config, after: Config, env: Env) ?[]const u8 {
    const id = env.profile orelse return null;
    const old = before.profiles[before.find(id) orelse return null];
    // Only a profile still in effect; anything else was replaced by hand.
    if (!matches(old, env)) return null;
    if (after.find(id)) |i| return if (sameCommand(old, after.profiles[i])) null else id;
    const stop = after.profiles[firstStop(after) orelse return null];
    return if (old.stop) null else stop.id;
}

/// Edited profiles with the shipped Default in place of their own. It is what
/// a failing scheduler falls back to, so it cannot be changed; it keeps its
/// place in the edited order.
pub fn lockDefault(a: std.mem.Allocator, user: Config, system: Config) !Config {
    const default = system.profiles[firstStop(system) orelse return user];
    var profiles: std.ArrayList(Profile) = .empty;
    var placed = false;
    for (user.profiles) |profile| {
        if (profile.stop) {
            if (!placed) try profiles.append(a, default);
            placed = true;
        } else if (!std.mem.eql(u8, profile.id, default.id)) try profiles.append(a, profile);
    }
    if (!placed) try profiles.insert(a, 0, default);
    return .{ .profiles = profiles.items };
}

/// Scheduler options as typed in one line, split on whitespace.
pub fn splitArgs(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeAny(u8, line, " \t\r\n");
    while (words.next()) |word| {
        if (!validArg(word)) return error.InvalidArgument;
        if (args.items.len == max_args) return error.TooManyArguments;
        try args.append(a, word);
    }
    return args.items;
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
    const binary = schedName(sched);
    const name = if (std.mem.startsWith(u8, binary, "scx_")) binary[4..] else binary;
    return name.len > 0 and std.mem.startsWith(u8, ops, name) and (ops.len == name.len or ops[name.len] == '_');
}

/// The version an attached scheduler reports in its ops name, if any.
pub fn opsVersion(sched: []const u8, ops: []const u8) ?[]const u8 {
    if (!opsMatches(sched, ops)) return null;
    const binary = schedName(sched);
    const name_len = if (std.mem.startsWith(u8, binary, "scx_")) binary.len - 4 else binary.len;
    if (ops.len <= name_len + 1) return null;
    const rest = ops[name_len + 1 ..];
    const version = rest[0 .. std.mem.indexOfScalar(u8, rest, '_') orelse rest.len];
    return if (version.len > 0 and std.ascii.isDigit(version[0])) version else null;
}

/// Why a scheduler stopped, from its scx.service log: the sched_ext exit
/// message, else the scheduler's last error, else how systemd saw the process
/// end. A restart starts a new run; the latest run that ended with any of
/// these wins, so a successful restart does not hide why the last one ended.
pub fn exitReason(buffer: []u8, log: []const u8) ?[]const u8 {
    const Run = struct {
        exit: ?[]const u8 = null,
        failure: ?[]const u8 = null,
        ended: ?[]const u8 = null,
        fn found(run: @This()) bool {
            return run.exit != null or run.failure != null or run.ended != null;
        }
    };
    var run: Run = .{};
    var last: Run = .{};
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "Started ") or std.mem.indexOf(u8, line, "Scheduled restart job") != null) {
            if (run.found()) last = run;
            run = .{};
        } else if (std.mem.lastIndexOf(u8, line, "EXIT: ")) |i| {
            run.exit = std.mem.trim(u8, line[i + 6 ..], " ");
        } else if (std.mem.startsWith(u8, line, "Error: ")) {
            run.failure = std.mem.trim(u8, line[7..], " ");
        } else if (std.mem.indexOf(u8, line, "Main process exited, ")) |i| {
            run.ended = line[i + 21 ..];
        }
    }
    const chosen = if (run.found()) run else last;
    if (chosen.exit orelse chosen.failure) |reason| return if (reason.len > 0) reason else null;
    return endedReason(buffer, chosen.ended orelse return null);
}

/// systemd's "code=killed, status=9/KILL" as "killed by SIGKILL".
fn endedReason(buffer: []u8, line: []const u8) ?[]const u8 {
    const code_at = std.mem.indexOf(u8, line, "code=") orelse return null;
    const code_text = line[code_at + 5 ..];
    const code = code_text[0 .. std.mem.indexOfScalar(u8, code_text, ',') orelse code_text.len];
    const status_at = std.mem.indexOf(u8, line, "status=") orelse return null;
    const status_text = std.mem.trim(u8, line[status_at + 7 ..], " .");
    const slash = std.mem.indexOfScalar(u8, status_text, '/');
    const number = status_text[0 .. slash orelse status_text.len];
    const name = if (slash) |i| status_text[i + 1 ..] else "";
    if (std.mem.eql(u8, code, "exited")) return std.fmt.bufPrint(buffer, "exited with status {s}", .{number}) catch null;
    const how = if (std.mem.eql(u8, code, "killed")) "killed by" else if (std.mem.eql(u8, code, "dumped")) "crashed with" else return null;
    return (if (name.len > 0) std.fmt.bufPrint(buffer, "{s} SIG{s}", .{ how, name }) else std.fmt.bufPrint(buffer, "{s} signal {s}", .{ how, number })) catch null;
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
/// stuck is true when the unit has been active too long for a scheduler that
/// still has not attached.
pub fn status(config: Config, env: Env, unit: Unit, kernel: Kernel, ops: []const u8, switching: bool, stuck: bool) Status {
    if (kernel == .unavailable or unit == .missing) return .{};
    const selected: ?usize = if (env.profile) |id| config.find(id) else null;
    const profile = if (selected) |i| config.profiles[i] else null;
    const scheduler = if (profile) |p| !p.stop and matches(p, env) else false;
    const stopping = if (profile) |p| p.stop else false;
    const settling: Status = .{ .kind = .starting, .profile = selected };
    const failed: Status = .{ .kind = .failed, .profile = selected };
    // Another scheduler is attached. Default stays selected, so it can be
    // reported as running outside the profiles.
    const custom: Status = .{ .kind = .custom, .profile = if (stopping) selected else null };
    // A scheduler no profile runs cannot be one of ours on its way out, so it
    // is reported at once instead of waiting out the switch.
    const leaving = switching and !foreign(config, ops);
    return switch (unit) {
        // Running means the kernel reports the profile's own scheduler attached.
        .active => if (scheduler) (if (kernel != .enabled or ops.len == 0) (if (stuck and !switching) failed else settling) else if (opsMatches(profile.?.sched.?, ops)) .{ .kind = .running, .profile = selected } else if (leaving) settling else custom) else if (stopping and leaving) settling else custom,
        .activating, .deactivating => if (scheduler or (stopping and leaving)) settling else custom,
        // A selected scheduler that is no longer running has failed, whether
        // systemd marked the unit failed or the scheduler exited cleanly.
        // With the unit down, an attached scheduler is not ours: schedulers
        // unregister before their process exits. Until systemd has reported
        // the unit, nothing has failed yet.
        .failed, .inactive, .unknown => if (scheduler) (if (unit == .unknown or (switching and unit != .failed)) settling else failed) else if (kernel == .enabled) custom else .{ .kind = .off, .profile = if (stopping) selected else firstStop(config) },
        .missing => unreachable,
    };
}

/// A scheduler is attached that none of the profiles runs, for example one
/// started by hand.
pub fn foreign(config: Config, ops: []const u8) bool {
    if (ops.len == 0) return false;
    for (config.profiles) |profile| if (profile.sched) |sched| if (opsMatches(sched, ops)) return false;
    return true;
}

/// Whether a kernel uevent concerns sched_ext. A message is an
/// "action@devpath" header followed by NUL-separated KEY=value fields;
/// sched_ext reports each scheduler attaching and detaching this way.
pub fn schedExtEvent(message: []const u8) bool {
    var fields = std.mem.splitScalar(u8, message, 0);
    _ = fields.next();
    while (fields.next()) |field| if (std.mem.eql(u8, field, "SUBSYSTEM=sched_ext")) return true;
    return false;
}

/// The selected scheduler has failed since it was chosen: it is no longer
/// running, or systemd restarted it after it exited. previous is the restart
/// count seen last time, null before the first observation.
pub fn crashed(current: Status, restarts: u32, previous: ?u32) bool {
    return switch (current.kind) {
        .failed => true,
        .running, .starting => if (previous) |count| restarts > count else false,
        else => false,
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
        "{\"version\":2,\"profiles\":[{\"id\":\"a\",\"label\":\"A\",\"sched\":\"/tmp/scx_lavd\"}]}",
    }) |bad| try t.expect(std.meta.isError(parse(a, bad)));
    const absolute = try parse(a, "{\"version\":2,\"profiles\":[{\"id\":\"a\",\"label\":\"A\",\"sched\":\"/usr/bin/scx_lavd\"}]}");
    try t.expectEqualStrings("/usr/bin/scx_lavd", absolute.profiles[1].sched.?);
}

test "schedulers are named by path or by binary name" {
    try t.expect(validSched("scx_lavd"));
    try t.expect(validSched("/usr/bin/scx_lavd"));
    try t.expect(validSched("/usr/local/bin/scx_lavd"));
    for ([_][]const u8{ "", "/", "lavd", "/usr/bin/lavd", "/usr/bin/", "/home/me/scx_lavd", "/usr/bin/../bin/scx_lavd", "/usr//bin/scx_lavd", "usr/bin/scx_lavd", "/usr/sbin/scx_lavd" }) |bad| try t.expect(!validSched(bad));
    try t.expectEqualStrings("scx_lavd", schedName("/usr/bin/scx_lavd"));
    try t.expect(sameSched("/usr/bin/scx_lavd", "scx_lavd"));
    try t.expect(sameSched("scx_lavd", "/usr/local/bin/scx_lavd"));
    try t.expect(!sameSched("/usr/bin/scx_lavd", "/usr/local/bin/scx_lavd"));
    try t.expect(!sameSched("/usr/bin/scx_lavd", "scx_cosmos"));
    try t.expect(opsMatches("/usr/bin/scx_cosmos", "cosmos_1.1.7_x86_64_unknown_linux_gnu"));
    try t.expectEqualStrings("1.1.7", opsVersion("/usr/bin/scx_cosmos", "cosmos_1.1.7_x86_64_unknown_linux_gnu").?);
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
    // The helper writes the path a bare name resolved to, as scxtui does.
    var resolved = env;
    resolved.sched = "/usr/bin/scx_cosmos";
    try t.expect(matches(latency, resolved));
    try t.expectEqual(Status{ .kind = .running, .profile = 2 }, status(config, env, .active, .enabled, "cosmos_1.1.7_x86_64_unknown_linux_gnu", false, false));
    try t.expectEqual(Status{ .kind = .starting, .profile = 2 }, status(config, env, .activating, .disabled, "", false, false));
    try t.expectEqual(Status{ .kind = .failed, .profile = 2 }, status(config, env, .failed, .disabled, "", false, false));
    try t.expectEqual(Status{ .kind = .failed, .profile = 2 }, status(config, env, .inactive, .disabled, "", false, false));
    // Before systemd reports the unit, the selected scheduler has not failed.
    try t.expectEqual(Status{ .kind = .starting, .profile = 2 }, status(config, env, .unknown, .enabled, "cosmos_1.1.7_x86_64_unknown_linux_gnu", false, false));
    // A hand-edited file or another loader is not attributed to a profile.
    var edited = env;
    edited.flags = "-s 700";
    try t.expectEqual(Status{ .kind = .custom }, status(config, edited, .active, .enabled, "", false, false));
    try t.expectEqual(Status{ .kind = .custom }, status(config, .{}, .inactive, .enabled, "", false, false));
    const off = parseEnv(try render(a, config.profiles[0]));
    try t.expectEqual(Status{ .kind = .off, .profile = 0 }, status(config, off, .inactive, .disabled, "", false, false));
    try t.expectEqual(Status{ .kind = .off, .profile = 0 }, status(config, .{}, .inactive, .disabled, "", false, false));
    try t.expectEqual(Status{}, status(config, env, .missing, .disabled, "", false, false));
    // A file whose own profile turns scx off is shown as that profile.
    const own = try parse(a, "{\"version\":2,\"profiles\":[{\"id\":\"latency\",\"label\":\"Low latency\",\"sched\":\"scx_cosmos\"},{\"id\":\"balanced\",\"label\":\"Balanced\",\"action\":\"stop\"}]}");
    try t.expectEqual(@as(usize, 2), own.profiles.len);
    try t.expectEqual(Status{ .kind = .off, .profile = 1 }, status(own, .{}, .inactive, .disabled, "", false, false));
    try t.expectEqual(Status{}, status(config, env, .active, .unavailable, "", false, false));
    // Only the profile's own scheduler counts as running.
    try t.expectEqual(Status{ .kind = .starting, .profile = 2 }, status(config, env, .active, .enabled, "", false, false));
    try t.expectEqual(Status{ .kind = .custom }, status(config, env, .active, .enabled, "lavd_1.0.20_x86_64_unknown_linux_gnu", false, false));
    // While a profile chosen moments ago takes over, the previous profile's
    // scheduler is still attached or the unit is briefly down; neither is
    // custom or failed.
    const mixed = try parse(a, "{\"version\":2,\"profiles\":[{\"id\":\"latency\",\"label\":\"Low latency\",\"sched\":\"scx_cosmos\",\"args\":[\"-s\",\"700\",\"-m\",\"performance\",\"-w\"]},{\"id\":\"gaming\",\"label\":\"Gaming\",\"sched\":\"scx_lavd\"}]}");
    const lavd = "lavd_1.0.20_x86_64_unknown_linux_gnu";
    const mixed_off = parseEnv(try render(a, mixed.profiles[0]));
    try t.expect(!foreign(mixed, lavd));
    try t.expectEqual(Status{ .kind = .starting, .profile = 1 }, status(mixed, env, .active, .enabled, lavd, true, false));
    try t.expectEqual(Status{ .kind = .starting, .profile = 1 }, status(mixed, env, .inactive, .disabled, "", true, false));
    try t.expectEqual(Status{ .kind = .failed, .profile = 1 }, status(mixed, env, .failed, .disabled, "", true, false));
    try t.expectEqual(Status{ .kind = .starting, .profile = 0 }, status(mixed, mixed_off, .active, .enabled, lavd, true, false));
    try t.expectEqual(Status{ .kind = .starting, .profile = 0 }, status(mixed, mixed_off, .deactivating, .enabled, lavd, true, false));
    // Once the unit is down, even a profile's own scheduler attached by hand
    // is reported at once.
    try t.expectEqual(Status{ .kind = .custom, .profile = 0 }, status(mixed, mixed_off, .inactive, .enabled, lavd, true, false));
    try t.expectEqual(Status{ .kind = .custom, .profile = 0 }, status(mixed, mixed_off, .failed, .enabled, lavd, true, false));
    try t.expectEqual(Status{ .kind = .off, .profile = 0 }, status(mixed, mixed_off, .inactive, .disabled, "", true, false));
    // Once the switch is over, a scheduler still attached is not ours.
    try t.expectEqual(Status{ .kind = .custom, .profile = 0 }, status(mixed, mixed_off, .active, .enabled, lavd, false, false));
    try t.expectEqual(Status{ .kind = .custom, .profile = 0 }, status(mixed, mixed_off, .inactive, .enabled, lavd, false, false));
    // A scheduler started by hand is reported at once, even right after a
    // switch, since no profile could have left it behind; Default stays
    // selected.
    const rburst = "rburst_0.1.0_x86_64_unknown_linux_gnu";
    try t.expect(foreign(mixed, rburst));
    try t.expect(!foreign(mixed, ""));
    try t.expectEqual(Status{ .kind = .custom, .profile = 0 }, status(mixed, mixed_off, .inactive, .enabled, rburst, true, false));
    try t.expectEqual(Status{ .kind = .custom, .profile = 0 }, status(mixed, mixed_off, .active, .enabled, rburst, true, false));
    try t.expectEqual(Status{ .kind = .custom }, status(mixed, env, .active, .enabled, rburst, true, false));
    // A scheduler that never attaches has failed, unless it was just chosen.
    try t.expectEqual(Status{ .kind = .failed, .profile = 2 }, status(config, env, .active, .disabled, "", false, true));
    try t.expectEqual(Status{ .kind = .starting, .profile = 2 }, status(config, env, .active, .disabled, "", true, true));
}

test "only sched_ext uevents are relevant" {
    try t.expect(schedExtEvent("add@/kernel/sched_ext/root\x00ACTION=add\x00DEVPATH=/kernel/sched_ext/root\x00SUBSYSTEM=sched_ext\x00SCXOPS=cake_1.2.2_x86_64_unknown_linux_gnu\x00SEQNUM=5181\x00"));
    try t.expect(schedExtEvent("remove@/kernel/sched_ext/root\x00ACTION=remove\x00SUBSYSTEM=sched_ext"));
    try t.expect(!schedExtEvent("change@/devices/LNXSYSTM:00/ACPI0003:00/power_supply/AC\x00ACTION=change\x00SUBSYSTEM=power_supply\x00"));
    // The header alone does not count, nor a value that merely mentions it.
    try t.expect(!schedExtEvent("add@/SUBSYSTEM=sched_ext"));
    try t.expect(!schedExtEvent("add@/x\x00DEVPATH=/SUBSYSTEM=sched_ext\x00"));
}

test "a restart counts as a crash of the selected scheduler" {
    const at = struct {
        fn kind(k: @FieldType(Status, "kind")) Status {
            return .{ .kind = k, .profile = 1 };
        }
    }.kind;
    try t.expect(crashed(at(.failed), 0, null));
    try t.expect(crashed(at(.running), 3, 2));
    try t.expect(crashed(at(.starting), 1, 0));
    try t.expect(!crashed(at(.running), 2, 2));
    try t.expect(!crashed(at(.running), 5, null));
    // A manual restart resets the count.
    try t.expect(!crashed(at(.running), 0, 4));
    try t.expect(!crashed(at(.off), 3, 2));
    try t.expect(!crashed(at(.custom), 3, 2));
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
    var buffer: [64]u8 = undefined;
    try t.expectEqualStrings("runnable task stall (khugepaged[77] failed to run for 5.631s) on CPU 6", exitReason(&buffer, log).?);
    try t.expectEqualStrings("Failed to open BPF object", exitReason(&buffer, "Error: Failed to open BPF object\n").?);
    try t.expect(exitReason(&buffer, "13:41:25 [INFO] scheduler options: scx_cosmos\n") == null);
    // A killed scheduler leaves only systemd's line, and the run systemd
    // restarted afterwards does not hide it.
    const killed =
        \\EXIT: unregistered from user space
        \\Started Start scx_scheduler.
        \\13:50:00 [INFO] scheduler options: scx_cosmos
        \\scx.service: Main process exited, code=killed, status=9/KILL
        \\scx.service: Failed with result 'signal'.
        \\scx.service: Scheduled restart job, restart counter is at 1.
        \\Started Start scx_scheduler.
        \\13:50:01 [INFO] scheduler options: scx_cosmos
    ;
    try t.expectEqualStrings("killed by SIGKILL", exitReason(&buffer, killed).?);
    // The exit message arrives just after systemd's line and still wins.
    try t.expectEqualStrings("runnable task stall (kworker/0:1[1291618] failed to run for 5.251s) on CPU 0", exitReason(&buffer,
        \\scx.service: Main process exited, code=exited, status=1/FAILURE
        \\scx.service: Failed with result 'exit-code'.
        \\Error: EXIT: runnable task stall (kworker/0:1[1291618] failed to run for 5.251s) on CPU 0
        \\scx.service: Scheduled restart job, restart counter is at 5.
    ).?);
    try t.expectEqualStrings("crashed with SIGSEGV", exitReason(&buffer, "scx.service: Main process exited, code=dumped, status=11/SEGV\n").?);
    try t.expectEqualStrings("exited with status 2", exitReason(&buffer, "scx.service: Main process exited, code=exited, status=2/INVALIDARGUMENT\n").?);
    try t.expectEqualStrings("killed by SIGKILL", processReason(&buffer, "signal", 2, 9).?);
    try t.expectEqualStrings("crashed with signal 7", processReason(&buffer, "core-dump", 3, 7).?);
    try t.expectEqualStrings("exited with status 1", processReason(&buffer, "exit-code", 1, 1).?);
    try t.expectEqualStrings("killed by SIGKILL repeatedly", processReason(&buffer, "start-limit-hit", 2, 9).?);
    try t.expectEqualStrings("restarted too often", processReason(&buffer, "start-limit-hit", 0, 0).?);
}

test "custom profiles serialize, get ids and split options" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parse(a, sample);
    const again = try parse(a, try serialize(a, config));
    try t.expectEqual(config.profiles.len, again.profiles.len);
    for (config.profiles, again.profiles) |x, y| {
        try t.expectEqualStrings(x.id, y.id);
        try t.expectEqualStrings(x.label, y.label);
        try t.expectEqualStrings(x.description, y.description);
        try t.expect(sameCommand(x, y));
    }

    var edited = config.profiles[1];
    edited.args = &.{"--powersave"};
    try t.expect(!sameCommand(config.profiles[1], edited));
    var moved = config.profiles[1];
    moved.sched = "/usr/bin/scx_cosmos";
    try t.expect(sameCommand(config.profiles[1], moved));

    var buffer: [32]u8 = undefined;
    try t.expectEqualStrings("my-lavd-2", slug(&buffer, "  My LAVD #2! ", config));
    try t.expectEqualStrings("profile", slug(&buffer, "!!!", config));
    try t.expectEqualStrings("default-2", slug(&buffer, "Default", config));
    try t.expectEqualStrings("abcdefghijklmnopqrstuvwx", slug(&buffer, "abcdefghijklmnopqrstuvwxyz", config));

    const args = try splitArgs(a, "  --slice-us 1600\t--disable-cgroups ");
    try t.expectEqual(@as(usize, 3), args.len);
    try t.expectEqualStrings("1600", args[1]);
    try t.expectEqual(@as(usize, 0), (try splitArgs(a, "   ")).len);
    try t.expectError(error.InvalidArgument, splitArgs(a, "--log $(reboot)"));
    try t.expectError(error.InvalidArgument, splitArgs(a, "-s '700'"));
}

test "edited profiles always use the shipped Default" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const system = try parse(a, sample);
    var renamed = system.profiles[0];
    renamed.label = "Kernel";
    renamed.description = "Changed by hand.";
    const other: Profile = .{ .id = "off", .label = "Off", .stop = true };
    const clash: Profile = .{ .id = "default", .label = "Not off", .sched = "scx_lavd" };
    const locked = try lockDefault(a, .{ .profiles = &.{ system.profiles[2], renamed, other, clash } }, system);
    try t.expectEqual(@as(usize, 2), locked.profiles.len);
    try t.expectEqualStrings("latency", locked.profiles[0].id);
    try t.expectEqualStrings(system.profiles[0].label, locked.profiles[1].label);
    try t.expectEqualStrings(system.profiles[0].description, locked.profiles[1].description);
    const missing = try lockDefault(a, .{ .profiles = &.{system.profiles[2]} }, system);
    try t.expect(missing.profiles[0].stop);
}

test "editing or restoring profiles reapplies the selected one when its command changes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try parse(a, sample);
    const running = parseEnv(try render(a, before.profiles[2]));
    // Unchanged, or only renamed: nothing to do.
    try t.expect(reapply(before, before, running) == null);
    var profiles = try a.dupe(Profile, before.profiles);
    profiles[2].label = "Fast";
    try t.expect(reapply(before, .{ .profiles = profiles }, running) == null);
    // New options: apply the profile again.
    profiles[2].args = &.{"-w"};
    try t.expectEqualStrings("latency", reapply(before, .{ .profiles = profiles }, running).?);
    // Deleted: back to Default.
    const without: Config = .{ .profiles = &.{ before.profiles[0], before.profiles[1] } };
    try t.expectEqualStrings("default", reapply(before, without, running).?);
    // Default stays off, and a hand-edited file is left alone.
    const off = parseEnv(try render(a, before.profiles[0]));
    try t.expect(reapply(before, .{ .profiles = &.{before.profiles[1]} }, off) == null);
    var edited = running;
    edited.flags = "-s 700";
    try t.expect(reapply(before, without, edited) == null);
    try t.expect(reapply(before, without, .{}) == null);
}
