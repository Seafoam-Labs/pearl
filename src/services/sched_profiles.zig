//! Scheduling profiles: named scx.service command lines read from the system's
//! scheduling-profiles.json, and the /etc/default/scx file that applies them.
//! Pure data; the privileged helper writes the file and drives systemd.
const std = @import("std");
const m = @import("sched_ext_model.zig");

pub const file_name = "scheduling-profiles.json";
pub const env_path = "/etc/default/scx";
pub const max_profiles = 8;
pub const max_bytes = 16384;
pub const max_args = 32;

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
            if (!m.validName(sched)) return error.InvalidProfiles;
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

pub fn status(config: Config, env: Env, unit: Unit, kernel: m.Kernel) Status {
    if (kernel == .unavailable or unit == .missing) return .{};
    const selected: ?usize = if (env.profile) |id| config.find(id) else null;
    const profile = if (selected) |i| config.profiles[i] else null;
    const scheduler = if (profile) |p| !p.stop and matches(p, env) else false;
    return switch (unit) {
        .active => if (scheduler) .{ .kind = if (kernel == .enabled) .running else .starting, .profile = selected } else .{ .kind = .custom },
        .activating, .deactivating => if (scheduler) .{ .kind = .starting, .profile = selected } else .{ .kind = .custom },
        // A selected scheduler that is no longer running has failed, whether
        // systemd marked the unit failed or the scheduler exited cleanly.
        .failed, .inactive, .unknown => if (scheduler) .{ .kind = .failed, .profile = selected } else if (kernel == .enabled) .{ .kind = .custom } else .{ .kind = .off, .profile = if (profile != null and profile.?.stop) selected else firstStop(config) },
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
    try t.expectEqual(Status{ .kind = .running, .profile = 2 }, status(config, env, .active, .enabled));
    try t.expectEqual(Status{ .kind = .starting, .profile = 2 }, status(config, env, .activating, .disabled));
    try t.expectEqual(Status{ .kind = .failed, .profile = 2 }, status(config, env, .failed, .disabled));
    try t.expectEqual(Status{ .kind = .failed, .profile = 2 }, status(config, env, .inactive, .disabled));
    // A hand-edited file or another loader is not attributed to a profile.
    var edited = env;
    edited.flags = "-s 700";
    try t.expectEqual(Status{ .kind = .custom }, status(config, edited, .active, .enabled));
    try t.expectEqual(Status{ .kind = .custom }, status(config, .{}, .inactive, .enabled));
    const off = parseEnv(try render(a, config.profiles[0]));
    try t.expectEqual(Status{ .kind = .off, .profile = 0 }, status(config, off, .inactive, .disabled));
    try t.expectEqual(Status{ .kind = .off, .profile = 0 }, status(config, .{}, .inactive, .disabled));
    try t.expectEqual(Status{}, status(config, env, .missing, .disabled));
    // A file whose own profile turns scx off is shown as that profile.
    const own = try parse(a, "{\"version\":2,\"profiles\":[{\"id\":\"latency\",\"label\":\"Low latency\",\"sched\":\"scx_cosmos\"},{\"id\":\"balanced\",\"label\":\"Balanced\",\"action\":\"stop\"}]}");
    try t.expectEqual(@as(usize, 2), own.profiles.len);
    try t.expectEqual(Status{ .kind = .off, .profile = 1 }, status(own, .{}, .inactive, .disabled));
    try t.expectEqual(Status{}, status(config, env, .active, .unavailable));
}
