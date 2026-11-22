//! Scheduling profiles from the scx scheduler catalog, as scxcli lists them.
//!
//! scx owns the catalog (`/usr/share/scx/catalog.json`, overridden by
//! `/etc/scx/catalog.json`), the unit's environment file and the rules for
//! both; scxcli is the one tool that reads and writes them, and its JSON
//! output is the contract between scx and its clients (scx's
//! services/CATALOG.md). Pearl is such a client: this file reads that output
//! and decides what to show. It holds no data of its own about schedulers.
//! Pure data; the service runs scxcli.
const std = @import("std");

/// Where pkexec expects scxcli: its polkit actions name this path.
pub const scxcli = "/usr/bin/scxcli";
/// The JSON output version scxcli prints; fields are only added within it.
pub const output_version = 2;
/// The catalog format version Pearl writes when it saves the profiles.
pub const catalog_version = 2;
/// The administrator's catalog, which `catalog save` writes and `catalog
/// reset` removes, and the one scx ships. Clients watch both.
pub const admin_catalog = "/etc/scx/catalog.json";
pub const shipped_catalog = "/usr/share/scx/catalog.json";
/// scx.service's environment file, when the listing names none.
pub const default_config = "/etc/default/scx";
/// The profile that turns sched_ext schedulers off. It is always first.
pub const default_id = "default";
/// Limits of the catalog format.
pub const max_args = 32;
pub const max_label = 64;
pub const max_description = 256;
pub const max_id = 64;
/// scxcli prints at most this much for a listing or a catalog.
pub const max_bytes = 1 << 20;
/// `scxcli catalog save` reads at most this much (scx_catalog's
/// MAX_CATALOG_BYTES); a larger catalog is refused before any password is
/// asked for.
pub const max_save_bytes = 64 * 1024;
/// The kernel's sched_ext state, from /sys/kernel/sched_ext/state.
pub const Kernel = enum { unavailable, disabled, enabled, unknown };

/// A scheduler's name: scx_ followed by ASCII letters, digits, `_` and `-`,
/// at most 64 characters, never a path.
pub fn validName(name: []const u8) bool {
    if (name.len <= 4 or name.len > max_id or !std.mem.startsWith(u8, name, "scx_")) return false;
    for (name[4..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}

/// A custom profile's id: lowercase ASCII letters, digits, `_` and `-`,
/// starting with a letter or digit, at most 64 characters, neither
/// `default` nor an scx_* name, so `start ID` can never be read as anything
/// else.
pub fn validProfileId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id) return false;
    if (!std.ascii.isLower(id[0]) and !std.ascii.isDigit(id[0])) return false;
    for (id) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_' and c != '-') return false;
    return !std.mem.eql(u8, id, default_id) and !std.mem.startsWith(u8, id, "scx_");
}

/// Options are written unquoted into the unit's environment file and split
/// by its shell, so scx allows only characters that survive that: 1 to 256
/// ASCII letters, digits and `-_=.,:/+`.
pub fn validArg(arg: []const u8) bool {
    if (arg.len == 0 or arg.len > 256) return false;
    for (arg) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-_=.,:/+", c) == null) return false;
    return true;
}

/// A label or description: `min` to `max` characters of UTF-8 without
/// control characters, counted the way scx counts them.
pub fn validText(text: []const u8, min: usize, max: usize) bool {
    const view = std.unicode.Utf8View.init(text) catch return false;
    var it = view.iterator();
    var count: usize = 0;
    while (it.nextCodepoint()) |c| {
        if (c < 0x20 or (c >= 0x7f and c < 0xa0)) return false;
        count += 1;
    }
    return count >= min and count <= max;
}

/// The binary name of a scheduler given by path or name.
pub fn schedName(sched: []const u8) []const u8 {
    return std.fs.path.basename(sched);
}

pub const Profile = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8 = "",
    /// The scheduler of a custom profile, by name. Null for Default and for
    /// a plain profile, whose id is its scheduler.
    sched: ?[]const u8 = null,
    /// A custom profile's options. Plain profiles have none.
    args: []const []const u8 = &.{},
    /// The installed executable; null when the scheduler is not installed.
    path: ?[]const u8 = null,
    /// It can be started here: Default always, a scheduler when installed.
    available: bool = true,

    pub fn isDefault(self: Profile) bool {
        return std.mem.eql(u8, self.id, default_id);
    }

    /// A scheduler with options of an administrator's choosing, under an id
    /// of its own.
    pub fn custom(self: Profile) bool {
        return self.sched != null;
    }

    /// The scheduler the profile starts, by name; null for Default.
    pub fn scheduler(self: Profile) ?[]const u8 {
        if (self.isDefault()) return null;
        return self.sched orelse self.id;
    }
};

pub const Tier = enum { stable, experimental, unknown };

/// An installed scheduler the catalog does not hide.
pub const Installed = struct {
    name: []const u8,
    path: []const u8 = "",
    /// A plain profile starts it.
    recommended: bool = false,
    /// The maintainers recommend it; it counts as stable.
    featured: bool = false,
    tier: Tier = .unknown,
};

pub const Command = struct {
    sched: []const u8,
    args: []const []const u8 = &.{},
};

/// What the next start of scx.service runs, as its environment says.
pub const Next = struct {
    /// As the file holds it: the resolved path when scxcli wrote it.
    sched: []const u8,
    args: []const []const u8 = &.{},
    /// An SCX_SCHEDULER_OVERRIDE or SCX_FLAGS_OVERRIDE decided it.
    override: bool = false,
};

pub const Failure = struct {
    message: []const u8 = "",
    status: []const u8 = "",
};

/// `scxcli get --json`: what runs and what the next start runs.
pub const Current = struct {
    /// The running scheduler; `default` when the kernel's own runs; null
    /// while starting, or when what is attached is not the unit's.
    scheduler: ?[]const u8 = null,
    unit_active: bool = false,
    unit_enabled: bool = false,
    /// Enabled for the current boot only (`systemctl enable --runtime`).
    unit_enabled_runtime: bool = false,
    running: ?Command = null,
    /// Null when nothing is configured, as after `start default`.
    next: ?Next = null,
    /// /sys/kernel/sched_ext; null on a kernel without sched_ext.
    kernel_state: ?[]const u8 = null,
    ops: ?[]const u8 = null,
    failure: ?Failure = null,
    /// The unit's environment could not be fully resolved; next is then
    /// incomplete.
    config_error: ?[]const u8 = null,
};

/// `scxcli list --json`.
pub const Listing = struct {
    /// The catalog file in use.
    source: []const u8 = "",
    /// It is the administrator's catalog, which `catalog reset` removes.
    customized: bool = false,
    /// The catalog's recommended entries, Default first, in its order.
    profiles: []const Profile,
    /// Installed schedulers that are not hidden, in the order to show them.
    all: []const Installed = &.{},
    /// The unit's environment file, which starting writes.
    config: ?[]const u8 = null,
    current: Current = .{},

    pub fn find(self: Listing, id: []const u8) ?usize {
        return findIn(self.profiles, id);
    }

    pub fn configPath(self: Listing) []const u8 {
        return self.config orelse default_config;
    }
};

/// Identifies everything a view or an editor builds from a listing: the
/// profiles as listed and the installed schedulers offered, each field and
/// each entry separated so no two different listings run together. What
/// runs is left out; it changes the status, not the list. Never 0.
pub fn signature(listing: Listing) u64 {
    var hash = std.hash.Wyhash.init(1);
    const Hash = struct {
        fn text(h: *std.hash.Wyhash, value: []const u8) void {
            h.update(std.mem.asBytes(&value.len));
            h.update(value);
        }
    };
    hash.update(std.mem.asBytes(&listing.profiles.len));
    for (listing.profiles) |entry| {
        for ([_][]const u8{ entry.id, entry.label, entry.description, entry.sched orelse "", entry.path orelse "" }) |value| Hash.text(&hash, value);
        hash.update(&.{ @intFromBool(entry.sched != null), @intFromBool(entry.path != null), @intFromBool(entry.available) });
        hash.update(std.mem.asBytes(&entry.args.len));
        for (entry.args) |arg| Hash.text(&hash, arg);
    }
    hash.update(std.mem.asBytes(&listing.all.len));
    for (listing.all) |entry| {
        Hash.text(&hash, entry.name);
        Hash.text(&hash, entry.path);
        hash.update(&.{ @intFromBool(entry.recommended), @intFromBool(entry.featured), @intFromEnum(entry.tier) });
    }
    hash.update(&.{@intFromBool(listing.customized)});
    return hash.final() | 1;
}

pub fn findIn(profiles: []const Profile, id: []const u8) ?usize {
    for (profiles, 0..) |profile, i| if (std.mem.eql(u8, profile.id, id)) return i;
    return null;
}

/// The wire format of scxcli's output, read leniently: clients ignore
/// fields they do not know.
const Wire = struct {
    const Pick = struct {
        id: []const u8,
        label: []const u8,
        description: []const u8 = "",
        sched: ?[]const u8 = null,
        args: []const []const u8 = &.{},
        path: ?[]const u8 = null,
        available: bool = false,
    };
    const Shown = struct {
        name: []const u8,
        path: []const u8 = "",
        recommended: bool = false,
        featured: bool = false,
        tier: []const u8 = "unknown",
    };
    const UnitState = struct { active: bool = false, enabled: bool = false, enabled_runtime: bool = false };
    const KernelState = struct { state: []const u8 = "", ops: ?[]const u8 = null };
    const State = struct {
        scheduler: ?[]const u8 = null,
        unit: UnitState = .{},
        running: ?Command = null,
        next: ?Next = null,
        kernel: ?KernelState = null,
        failure: ?Failure = null,
        config_error: ?[]const u8 = null,
    };
    const List = struct {
        source: []const u8 = "",
        customized: bool = false,
        recommended: []const Pick,
        all: []const Shown = &.{},
        config: ?[]const u8 = null,
        current: State = .{},
    };
    const Entry = struct {
        id: []const u8,
        label: []const u8,
        description: []const u8 = "",
        sched: ?[]const u8 = null,
        args: []const []const u8 = &.{},
    };
    const Catalog = struct { recommended: []const Entry };
};

/// The output must be an object of the version this client reads.
fn versioned(a: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    if (bytes.len > max_bytes) return error.InvalidOutput;
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return error.InvalidOutput;
    if (root != .object) return error.InvalidOutput;
    const version = root.object.get("version") orelse return error.InvalidOutput;
    if (version != .integer) return error.InvalidOutput;
    if (version.integer != output_version) return error.UnsupportedVersion;
    return root;
}

fn current(state: Wire.State) Current {
    return .{
        .scheduler = state.scheduler,
        .unit_active = state.unit.active,
        .unit_enabled = state.unit.enabled,
        .unit_enabled_runtime = state.unit.enabled_runtime,
        .running = state.running,
        .next = state.next,
        .kernel_state = if (state.kernel) |k| k.state else null,
        .ops = if (state.kernel) |k| k.ops else null,
        .failure = state.failure,
        .config_error = state.config_error,
    };
}

/// `scxcli list --json`.
pub fn parseListing(a: std.mem.Allocator, bytes: []const u8) !Listing {
    const root = try versioned(a, bytes);
    const wire = std.json.parseFromValueLeaky(Wire.List, a, root, .{ .ignore_unknown_fields = true }) catch return error.InvalidOutput;
    // The catalog guarantees Default first; a listing without it is not one
    // this client can offer.
    if (wire.recommended.len == 0 or !std.mem.eql(u8, wire.recommended[0].id, default_id)) return error.InvalidOutput;
    const profiles = try a.alloc(Profile, wire.recommended.len);
    for (wire.recommended, profiles) |pick, *profile| profile.* = .{
        .id = pick.id,
        .label = pick.label,
        .description = pick.description,
        .sched = pick.sched,
        .args = pick.args,
        .path = pick.path,
        .available = pick.available,
    };
    const all = try a.alloc(Installed, wire.all.len);
    for (wire.all, all) |shown, *entry| entry.* = .{
        .name = shown.name,
        .path = shown.path,
        .recommended = shown.recommended,
        .featured = shown.featured,
        // Output without the field, or with a tier this client does not
        // know, makes no statement.
        .tier = std.meta.stringToEnum(Tier, shown.tier) orelse .unknown,
    };
    return .{
        .source = wire.source,
        .customized = wire.customized,
        .profiles = profiles,
        .all = all,
        .config = wire.config,
        .current = current(wire.current),
    };
}

/// `scxcli get --json`.
pub fn parseCurrent(a: std.mem.Allocator, bytes: []const u8) !Current {
    const root = try versioned(a, bytes);
    return current(std.json.parseFromValueLeaky(Wire.State, a, root, .{ .ignore_unknown_fields = true }) catch return error.InvalidOutput);
}

/// The profiles of a catalog file as `scxcli catalog show` prints it.
pub fn parseCatalog(a: std.mem.Allocator, bytes: []const u8) ![]const Profile {
    if (bytes.len > max_bytes) return error.InvalidCatalog;
    const wire = std.json.parseFromSliceLeaky(Wire.Catalog, a, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidCatalog;
    const profiles = try a.alloc(Profile, wire.recommended.len);
    for (wire.recommended, profiles) |entry, *profile| profile.* = .{ .id = entry.id, .label = entry.label, .description = entry.description, .sched = entry.sched, .args = entry.args };
    return profiles;
}

/// The catalog in use with its recommended list replaced by `profiles`,
/// for `scxcli catalog save`. Every other list (featured, hidden, stable,
/// experimental) and key is kept as it was, so the maintainers' word on
/// the schedulers survives an edit of the profiles.
pub fn renderCatalog(a: std.mem.Allocator, catalog: []const u8, profiles: []const Profile) ![]u8 {
    try validate(profiles);
    if (catalog.len > max_bytes) return error.InvalidCatalog;
    var root = std.json.parseFromSliceLeaky(std.json.Value, a, catalog, .{}) catch return error.InvalidCatalog;
    if (root != .object or root.object.get("recommended") == null) return error.InvalidCatalog;
    var list = std.json.Array.init(a);
    for (profiles) |profile| {
        var entry: std.json.ObjectMap = .empty;
        try entry.put(a, "id", .{ .string = profile.id });
        try entry.put(a, "label", .{ .string = profile.label });
        if (profile.description.len > 0) try entry.put(a, "description", .{ .string = profile.description });
        if (profile.sched) |sched| {
            try entry.put(a, "sched", .{ .string = sched });
            var args = std.json.Array.init(a);
            for (profile.args) |arg| try args.append(.{ .string = arg });
            try entry.put(a, "args", .{ .array = args });
        }
        try list.append(.{ .object = entry });
    }
    try root.object.put(a, "recommended", .{ .array = list });
    const version = root.object.get("version") orelse return error.InvalidCatalog;
    if (version != .integer) return error.InvalidCatalog;
    // Custom profiles are a version 2 key; a version 1 file without them
    // stays as it is.
    var custom_profiles = false;
    for (profiles) |profile| custom_profiles = custom_profiles or profile.custom();
    if (custom_profiles and version.integer < catalog_version) {
        // Version 1 derives the featured list from the plain profiles and
        // lets it overlap stable; version 2 holds a derived list to its own
        // rule. Writing the list out keeps the file valid and its meaning:
        // a stable scheduler is no less stable for not being featured.
        if (root.object.get("featured") == null) {
            const stable = root.object.get("stable");
            var featured = std.json.Array.init(a);
            for (profiles) |profile| {
                if (profile.isDefault() or profile.custom()) continue;
                var listed = false;
                if (stable) |value| if (value == .array) for (value.array.items) |item| {
                    listed = listed or (item == .string and std.mem.eql(u8, item.string, profile.id));
                };
                if (!listed) try featured.append(.{ .string = profile.id });
            }
            try root.object.put(a, "featured", .{ .array = featured });
        }
        try root.object.put(a, "version", .{ .integer = catalog_version });
    }
    const rendered = try std.json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
    if (rendered.len > max_save_bytes) return error.CatalogTooLarge;
    return rendered;
}

/// The rules of the catalog format that concern the recommended list, so
/// that Pearl never sends a list scxcli would reject for its profiles.
/// scxcli checks the whole file again before it writes anything.
pub fn validate(profiles: []const Profile) !void {
    if (profiles.len == 0 or !profiles[0].isDefault()) return error.DefaultNotFirst;
    for (profiles, 0..) |profile, i| {
        if (findIn(profiles[0..i], profile.id) != null) return error.DuplicateProfile;
        if (!validText(profile.label, 1, max_label)) return error.InvalidLabel;
        if (!validText(profile.description, 0, max_description)) return error.InvalidDescription;
        if (profile.sched) |sched| {
            if (!validProfileId(profile.id) or !validName(sched)) return error.InvalidProfile;
            if (profile.args.len > max_args) return error.TooManyArguments;
            for (profile.args) |arg| if (!validArg(arg)) return error.InvalidArgument;
        } else {
            if (!profile.isDefault() and !validName(profile.id)) return error.InvalidProfile;
            if (profile.args.len > 0) return error.InvalidProfile;
        }
    }
}

fn sameArgs(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}

/// How a profile's command compares with one the unit's file holds.
/// `exact` is the same executable by its resolved path; `name` is the same
/// scheduler by name only, because the file holds a bare name or the
/// profile's scheduler is not installed. Only an exact match is enough to
/// act on.
pub const Match = enum { none, name, exact };

/// The command a profile stands for is its scheduler with exactly its
/// options; a plain profile has none. scxcli writes the resolved path into
/// the file and lists each profile's resolved executable, so when both are
/// known they must be the same file.
pub fn matchNext(profile: Profile, next: Next) Match {
    const name = profile.scheduler() orelse return .none;
    if (!std.mem.eql(u8, schedName(next.sched), name) or !sameArgs(next.args, profile.args)) return .none;
    if (next.sched.len > 0 and next.sched[0] == '/') if (profile.path) |path| return if (std.mem.eql(u8, path, next.sched)) .exact else .none;
    return .name;
}

/// The unit's main process, which scxcli gives by its basename: a profile
/// stands for it when it starts that scheduler with exactly those options.
pub fn matchRunning(profile: Profile, process: Command) bool {
    const name = profile.scheduler() orelse return false;
    return std.mem.eql(u8, schedName(process.sched), name) and sameArgs(process.args, profile.args);
}

/// The profiles that stand for one command. The unit's file holds a
/// command, not an id, so when several profiles share it every one of them
/// matches and none can be said to be the one picked.
pub const Matches = struct {
    first: ?usize = null,
    count: usize = 0,
    /// Every match is by resolved path.
    exact: bool = false,

    /// The profile, when exactly one stands for the command.
    pub fn only(self: Matches) ?usize {
        return if (self.count == 1) self.first else null;
    }
};

/// The profiles standing for what the next start of the unit runs. Nothing
/// configured is Default. None when the command comes from an override or
/// the environment could not be read whole.
pub fn selection(listing: Listing) Matches {
    if (listing.current.config_error != null) return .{};
    const next = listing.current.next orelse {
        const i = listing.find(default_id) orelse return .{};
        return .{ .first = i, .count = 1, .exact = true };
    };
    if (next.override) return .{};
    var pick: Matches = .{ .exact = true };
    for (listing.profiles, 0..) |profile, i| switch (matchNext(profile, next)) {
        .none => {},
        else => |m| {
            if (pick.first == null) pick.first = i;
            pick.count += 1;
            pick.exact = pick.exact and m == .exact;
        },
    };
    if (pick.count == 0) pick.exact = false;
    return pick;
}

/// What the unit actually runs, as scxcli says: its main process, once the
/// kernel reports that process's scheduler attached. Null when nothing
/// does, while starting, or when what is attached is not the unit's.
pub fn active(listing: Listing) ?Command {
    const name = listing.current.scheduler orelse return null;
    if (std.mem.eql(u8, name, default_id)) return null;
    return listing.current.running;
}

/// The unit still runs `expected`, as `active` says: what an edit decided
/// to restart is restarted only if nothing else (scxcli, scxtui, another
/// session) started, switched or stopped a scheduler meanwhile.
pub fn stillRuns(listing: Listing, expected: Command) bool {
    const command = active(listing) orelse return false;
    return std.mem.eql(u8, schedName(command.sched), schedName(expected.sched)) and sameArgs(command.args, expected.args);
}

/// The profiles standing for what the unit actually runs.
pub fn runningMatches(listing: Listing) Matches {
    const command = active(listing) orelse return .{};
    var pick: Matches = .{};
    for (listing.profiles, 0..) |profile, i| if (matchRunning(profile, command)) {
        if (pick.first == null) pick.first = i;
        pick.count += 1;
    };
    return pick;
}

/// Both profiles run the same command, or both are Default.
pub fn sameCommand(x: Profile, y: Profile) bool {
    if (x.isDefault() or y.isDefault()) return x.isDefault() and y.isDefault();
    if (!std.mem.eql(u8, x.scheduler().?, y.scheduler().?) or x.args.len != y.args.len) return false;
    for (x.args, y.args) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}

/// An id for a new custom profile, from its label: lowercase letters,
/// digits and dashes, unique among the existing profiles. It never starts
/// with scx_, since it holds no underscore, and is never Default's.
pub fn slug(buffer: *[max_id]u8, label: []const u8, profiles: []const Profile) []const u8 {
    var len: usize = 0;
    for (label) |c| {
        if (len == 48) break;
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
    while (findIn(profiles, buffer[0..len]) != null or std.mem.eql(u8, buffer[0..len], default_id)) : (n += 1) {
        len = base + (std.fmt.bufPrint(buffer[base..], "-{d}", .{n}) catch unreachable).len;
    }
    return buffer[0..len];
}

/// An edit gave a profile a new id: a plain profile whose scheduler or
/// options changed becomes a custom one.
pub const Rename = struct { from: []const u8, to: []const u8 };

/// The profile to start once the list changes from before to after, so the
/// scheduler the unit actually runs keeps matching a profile: the profile
/// that ran it, under its new id if the edit gave it one, when its command
/// changed; Default when it is gone; else nothing. command is what the unit
/// runs (`active`). A selection that is stopped or failed is never started
/// by an edit: `scxcli stop` keeps the selection for later on purpose. A
/// command several profiles stood for is followed only while one of them
/// still stands for it; otherwise which one was picked is not on record,
/// and nothing is started.
pub fn reapply(before: []const Profile, after: []const Profile, command: ?Command, renamed: ?Rename) ?[]const u8 {
    const runs = command orelse return null;
    for (after) |profile| if (matchRunning(profile, runs)) return null;
    var found: ?Profile = null;
    var count: usize = 0;
    for (before) |profile| if (matchRunning(profile, runs)) {
        found = profile;
        count += 1;
    };
    if (count != 1) return null;
    const id = found.?.id;
    const target = if (renamed) |r| (if (std.mem.eql(u8, r.from, id)) r.to else id) else id;
    return if (findIn(after, target) != null) target else default_id;
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

/// The first line scxcli or pkexec wrote to stderr, without scxcli's
/// prefix: scxcli prints one line of error, usage errors add the usage.
pub fn errorLine(stderr: []const u8) []const u8 {
    var lines = std.mem.tokenizeAny(u8, stderr, "\r\n");
    const line = std.mem.trim(u8, lines.next() orelse return "", " \t");
    return if (std.mem.startsWith(u8, line, "scxcli: ")) line[8..] else line;
}

pub const Unit = enum { unknown, missing, active, activating, deactivating, inactive, failed };

pub fn unitFrom(load_state: []const u8, active_state: []const u8) Unit {
    if (std.mem.eql(u8, load_state, "not-found")) return .missing;
    return std.meta.stringToEnum(Unit, active_state) orelse .unknown;
}

pub const Status = struct {
    kind: enum { unavailable, off, running, starting, stopped, failed, custom } = .unavailable,
    /// The profile the status is about: the one the unit runs, for running;
    /// otherwise the one the next start runs. With several profiles for one
    /// command, the first of them.
    profile: ?usize = null,
    /// More than one profile stands for that command.
    ambiguous: bool = false,
    /// Worked out from the last state scxcli gave, which it could not be
    /// asked for again since: shown, but not taken as confirmed.
    stale: bool = false,
    /// Default runs while scx.service is configured to run a command that
    /// nothing starts: the unit is inactive, not enabled, and did not fail.
    /// scx's shipped file leaves a fresh system like this.
    idle: bool = false,
};

/// The command an idle scx.service would run (`Status.idle`).
pub fn idleNext(listing: Listing, now: Status) ?Next {
    return if (now.idle) listing.current.next else null;
}

/// How a profile row shows: what runs, a selection stopped while the unit
/// stays enabled, or the command an idle unit would run.
pub const Mark = enum { none, current, stopped, configured };

pub fn mark(listing: Listing, now: Status, index: usize) Mark {
    const profile = listing.profiles[index];
    return switch (now.kind) {
        .running => if (active(listing)) |command| (if (matchRunning(profile, command)) .current else .none) else .none,
        // Default stays marked while a scheduler outside the profiles runs.
        .off, .custom => blk: {
            if (now.profile) |i| if (i == index and profile.isDefault()) break :blk .current;
            if (idleNext(listing, now)) |next| if (matchNext(profile, next) != .none) break :blk .configured;
            break :blk .none;
        },
        .stopped => if (listing.current.next) |next| (if (matchNext(profile, next) != .none) .stopped else .none) else .none,
        else => .none,
    };
}

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

/// The status from scxcli's own verdict on what runs (`current`), with
/// systemd's live unit state for what scxcli cannot know yet. switching is
/// true while a profile chosen moments ago is still taking over: the
/// environment file was written after the running instance started, so the
/// previous scheduler may still be running or the unit briefly inactive.
/// stuck is true when the unit has been active too long for a scheduler
/// that still has not attached.
pub fn status(listing: Listing, unit: Unit, switching: bool, stuck: bool) Status {
    const now = listing.current;
    if (now.kernel_state == null or unit == .missing) return .{};
    const pick = selection(listing);
    const chosen = pick.first;
    const ambiguous = pick.count > 1;
    const scheduler = if (chosen) |i| !listing.profiles[i].isDefault() else false;
    const stopping = if (chosen) |i| listing.profiles[i].isDefault() else false;
    const settling: Status = .{ .kind = .starting, .profile = chosen, .ambiguous = ambiguous };
    // Default stays selected while another scheduler runs, so it can be
    // reported as running outside the profiles.
    const custom: Status = .{ .kind = .custom, .profile = if (stopping) chosen else null };
    const ops = now.ops orelse "";
    // A scheduler no profile runs cannot be one of ours on its way out, so it
    // is reported at once instead of waiting out the switch.
    const leaving = switching and !foreign(listing, ops);
    const name = now.scheduler orelse {
        // Something is attached that the unit did not start.
        if (ops.len > 0) return if (leaving and (scheduler or stopping)) settling else custom;
        // The unit is active and nothing is attached yet.
        if (scheduler) return if (stuck and !switching) .{ .kind = .failed, .profile = chosen, .ambiguous = ambiguous } else settling;
        return if (stopping and switching) settling else custom;
    };
    if (std.mem.eql(u8, name, default_id)) {
        // The kernel's own scheduler runs and the unit is not active.
        // Idle: systemd reports the unit inactive, nothing enables it, it
        // did not fail, and its environment was read whole.
        const enabled = now.unit_enabled or now.unit_enabled_runtime;
        const dormant = unit == .inactive and !now.unit_active and now.next != null and now.config_error == null and !enabled and now.failure == null;
        if (!scheduler) return .{ .kind = .off, .profile = if (stopping) chosen else listing.find(default_id), .idle = dormant };
        if (unit == .activating or (switching and unit != .failed)) return settling;
        // A run that failed is a failure of that profile, enabled or not.
        if (unit == .failed or now.failure != null) return .{ .kind = .failed, .profile = chosen, .ambiguous = ambiguous };
        if (dormant) return .{ .kind = .off, .profile = listing.find(default_id), .idle = true };
        // Just started, by hand say; scxcli's next answer says what attached.
        if (unit == .active) return settling;
        // systemd has not reported yet: only that Default runs is known.
        if (unit == .unknown and !enabled) return .{ .kind = .off, .profile = listing.find(default_id) };
        // Stopped with the selection kept: the unit is still enabled.
        return .{ .kind = .stopped, .profile = chosen, .ambiguous = ambiguous };
    }
    // The unit runs a scheduler and the kernel reports it attached.
    const runs = runningMatches(listing);
    if (runs.first) |i| {
        // The file names another profile than the one running, written
        // moments ago: the switch is under way.
        const switched = if (chosen) |c| !matchRunning(listing.profiles[c], active(listing).?) else false;
        if (switching and switched) return settling;
        return .{ .kind = .running, .profile = i, .ambiguous = runs.count > 1 };
    }
    return if (leaving and scheduler) settling else custom;
}

/// A scheduler is attached that none of the profiles runs, for example one
/// started by hand or with `scxcli run`.
pub fn foreign(listing: Listing, ops: []const u8) bool {
    if (ops.len == 0) return false;
    for (listing.profiles) |profile| if (profile.scheduler()) |sched| if (opsMatches(sched, ops)) return false;
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

/// The scheduler the status is about ended in failure, as a confirmed
/// status says. While scxcli cannot be asked, what runs may have changed
/// outside Pearl since its last answer, so nothing is concluded. Restarts
/// systemd counted are `Restarts`' to judge.
pub fn crashed(now: Status) bool {
    return !now.stale and now.kind == .failed;
}

/// A command, to tell one from another without keeping it: the scheduler
/// by name and its options, each with its length.
pub fn identify(command: Command) u64 {
    var hash = std.hash.Wyhash.init(2);
    const name = schedName(command.sched);
    hash.update(std.mem.asBytes(&name.len));
    hash.update(name);
    hash.update(std.mem.asBytes(&command.args.len));
    for (command.args) |arg| {
        hash.update(std.mem.asBytes(&arg.len));
        hash.update(arg);
    }
    return hash.final();
}

/// systemd's automatic restart count, judged at the states scxcli confirms.
/// A restart is the crash of a profile only when the count grew between two
/// confirmed states in which the unit's main process ran the same command:
/// systemd counts restarts of the unit, not of a command, and between two
/// answers the file may have been switched and a crash brought up the next
/// command, or someone started another. When the command differs, a period
/// without a confirmed state came between, or the listing was lost, the
/// count is a new starting point and nobody is blamed. A scheduler that
/// keeps failing is still caught at its next restart, or when the unit ends
/// in failure (`crashed`).
pub const Restarts = struct {
    /// The count at the last confirmed state; null before the first, or
    /// when it could not be read.
    baseline: ?u32 = null,
    /// The command the unit's main process ran then (`identify`).
    command: ?u64 = null,

    /// What the count is compared with is no longer known to belong to the
    /// command that runs: a state was not confirmed, or the listing is gone.
    pub fn invalidate(self: *Restarts) void {
        self.baseline = null;
        self.command = null;
    }

    /// At a state scxcli just confirmed: whether systemd restarted the
    /// profile's scheduler since the last one. process is the unit's main
    /// process as scxcli gave it (`current.running`), count systemd's
    /// NRestarts.
    pub fn observe(self: *Restarts, now: Status, process: ?Command, count: ?u32) bool {
        if (now.stale) {
            self.invalidate();
            return false;
        }
        // Between runs nothing says which command comes next; keep what
        // there is, so a restart in the gap is seen when the process is back.
        const run = process orelse return false;
        const id = identify(run);
        const same = self.command != null and self.command.? == id;
        const restarted = same and self.baseline != null and count != null and count.? > self.baseline.?;
        self.baseline = count;
        self.command = id;
        return restarted and (now.kind == .running or now.kind == .starting);
    }
};

/// What a refresh may conclude about a failure. The service refreshes on
/// every systemd signal, uevent and timer, but only right after scxcli
/// answered does it hold a state that belongs together: before that, a
/// fresh unit state from systemd is paired with scxcli's previous answer,
/// whose selection and process may no longer be what the unit is about
/// (someone ran `scxcli start` with another scheduler, say). So a failure is
/// concluded, and restarts are judged, only at the first refresh after an
/// answer; and while scxcli cannot answer, whatever the status shows, the
/// restart history is dropped.
pub const Tracker = struct {
    restarts: Restarts = .{},
    /// scxcli answered and that state has not been judged yet.
    pending: bool = false,

    /// scxcli just answered (`get` or `list`). superseded is whether
    /// something changed while it was being asked, so that another answer
    /// is on its way: this one may predate the change, and paired with the
    /// unit state after it would put the change on the wrong profile. It is
    /// shown, but not judged; the next answer is.
    pub fn answered(self: *Tracker, superseded: bool) void {
        self.pending = !superseded;
    }

    /// The listing is gone, or the history otherwise no longer belongs to
    /// what runs.
    pub fn invalidate(self: *Tracker) void {
        self.restarts.invalidate();
        self.pending = false;
    }

    /// One refresh. unconfirmed is whether scxcli's last attempt to answer
    /// failed, whatever the status shown (it may be unavailable, and not
    /// marked stale). process is the unit's main process from the state
    /// shown, count systemd's NRestarts. Returns whether the status shows a
    /// crash of its profile to act on.
    pub fn judge(self: *Tracker, now: Status, unconfirmed: bool, process: ?Command, count: ?u32) bool {
        const fresh = self.pending;
        self.pending = false;
        if (unconfirmed) {
            self.restarts.invalidate();
            return false;
        }
        if (!fresh) return false;
        const restarted = self.restarts.observe(now, process, count);
        return crashed(now) or restarted;
    }
};

/// When to ask scxcli again while the state is not confirmed: after 1, 2, 4
/// and 8 seconds, then every 16 seconds until it answers, so Pearl recovers
/// on its own once scxcli works again without polling while it does.
pub const Retry = struct {
    attempts: u8 = 0,

    /// Seconds until the next attempt.
    pub fn next(self: *Retry) u32 {
        const exponent: u5 = @intCast(@min(self.attempts, 4));
        if (self.attempts < 5) self.attempts += 1;
        return @as(u32, 1) << exponent;
    }

    pub fn reset(self: *Retry) void {
        self.attempts = 0;
    }
};

const t = std.testing;
const fixtures = @import("scx_fixtures");

test "the listing scxcli prints is read, Default first, tiers and state included" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const listing = try parseListing(a, fixtures.listing);
    try t.expectEqualStrings("default", listing.profiles[0].id);
    try t.expect(listing.profiles[0].isDefault());
    try t.expect(listing.profiles[0].scheduler() == null);
    const cosmos = listing.profiles[listing.find("scx_cosmos").?];
    try t.expect(!cosmos.custom());
    try t.expectEqualStrings("scx_cosmos", cosmos.scheduler().?);
    const latency = listing.profiles[listing.find("latency").?];
    try t.expect(latency.custom());
    try t.expectEqualStrings("scx_eevdf", latency.scheduler().?);
    try t.expectEqual(@as(usize, 3), latency.args.len);
    try t.expect(listing.customized);
    try t.expectEqualStrings("/etc/default/scx", listing.configPath());
    try t.expect(listing.all.len > 0);
    for (listing.all) |entry| try t.expect(validName(entry.name));
    try t.expectEqual(Tier.stable, listing.all[0].tier);
    try t.expect(listing.all[0].featured);
    // Unknown fields are ignored, an unknown version is not.
    _ = try parseListing(a, "{\"version\":2,\"future\":1,\"recommended\":[{\"id\":\"default\",\"label\":\"D\",\"available\":true,\"new\":[]}],\"current\":{\"version\":2,\"scheduler\":\"default\",\"unit\":{\"active\":false,\"enabled\":false},\"running\":null,\"next\":null,\"kernel\":null,\"failure\":null}}");
    try t.expectError(error.UnsupportedVersion, parseListing(a, "{\"version\":3,\"recommended\":[]}"));
    try t.expectError(error.InvalidOutput, parseListing(a, "{\"version\":2,\"recommended\":[{\"id\":\"scx_cosmos\",\"label\":\"C\"}]}"));
    try t.expectError(error.InvalidOutput, parseListing(a, "not json"));
}

fn expectArgs(expected: std.json.Value, actual: []const []const u8) !void {
    try t.expectEqual(expected.array.items.len, actual.len);
    for (expected.array.items, actual) |x, y| try t.expectEqualStrings(x.string, y);
}

fn expectText(expected: std.json.Value, actual: ?[]const u8) !void {
    if (expected == .null) return t.expect(actual == null);
    try t.expectEqualStrings(expected.string, actual.?);
}

test "scxcli get output is read field by field as scx's detection fixtures give it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (fixtures.detection) |fixture| {
        errdefer std.debug.print("fixture {s}\n", .{fixture.name});
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, fixture.bytes, .{});
        const expected = root.object.get("expected").?.object;
        const state = try parseCurrent(a, try std.json.Stringify.valueAlloc(a, root.object.get("expected").?, .{}));
        try expectText(expected.get("scheduler").?, state.scheduler);
        const unit = expected.get("unit").?.object;
        try t.expectEqual(unit.get("active").?.bool, state.unit_active);
        try t.expectEqual(unit.get("enabled").?.bool, state.unit_enabled);
        // Written only when true; absent reads as false.
        try t.expectEqual(if (unit.get("enabled_runtime")) |v| v.bool else false, state.unit_enabled_runtime);
        const running_ = expected.get("running").?;
        if (running_ == .null) try t.expect(state.running == null) else {
            try t.expectEqualStrings(running_.object.get("sched").?.string, state.running.?.sched);
            try expectArgs(running_.object.get("args").?, state.running.?.args);
        }
        const next = expected.get("next").?;
        if (next == .null) try t.expect(state.next == null) else {
            try t.expectEqualStrings(next.object.get("sched").?.string, state.next.?.sched);
            try expectArgs(next.object.get("args").?, state.next.?.args);
            try t.expectEqual(next.object.get("override").?.bool, state.next.?.override);
        }
        const kernel = expected.get("kernel").?;
        if (kernel == .null) try t.expect(state.kernel_state == null) else {
            try t.expectEqualStrings(kernel.object.get("state").?.string, state.kernel_state.?);
            try expectText(kernel.object.get("ops").?, state.ops);
        }
        const failure = expected.get("failure").?;
        if (failure == .null) try t.expect(state.failure == null) else {
            try t.expectEqualStrings(failure.object.get("message").?.string, state.failure.?.message);
            try t.expectEqualStrings(failure.object.get("status").?.string, state.failure.?.status);
        }
    }
}

/// The fixture listing with what scxcli reports for one of scx's
/// detection cases, and the unit state that case describes.
const Case = struct { listing: Listing, unit: Unit };

fn detected(a: std.mem.Allocator, name: []const u8) !Case {
    var listing = try parseListing(a, fixtures.listing);
    for (fixtures.detection) |fixture| if (std.mem.eql(u8, fixture.name, name)) {
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, fixture.bytes, .{});
        const expected = try std.json.Stringify.valueAlloc(a, root.object.get("expected").?, .{});
        listing.current = try parseCurrent(a, expected);
        const unit = root.object.get("unit").?.string;
        return .{ .listing = listing, .unit = if (std.mem.startsWith(u8, unit, "active")) .active else unitFrom("loaded", unit) };
    };
    return error.NoSuchFixture;
}

/// The fixture listing with a second profile for scx_cosmos's own command.
fn twin(a: std.mem.Allocator, listing: Listing) !Listing {
    var copy = listing;
    const profiles = try a.alloc(Profile, listing.profiles.len + 1);
    @memcpy(profiles[0..listing.profiles.len], listing.profiles);
    profiles[listing.profiles.len] = .{ .id = "cosmos-too", .label = "Cosmos too", .sched = "scx_cosmos", .path = "/usr/bin/scx_cosmos" };
    copy.profiles = profiles;
    return copy;
}

test "the selected profiles are those whose command the unit's file holds" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Nothing configured is Default.
    const nothing = (try detected(a, "03-nothing-configured")).listing;
    try t.expectEqual(@as(?usize, 0), selection(nothing).only());
    // scxcli writes the resolved path, and the profile's executable is that
    // file: an exact match.
    var listing = (try detected(a, "01-cosmos-running")).listing;
    const cosmos = listing.find("scx_cosmos").?;
    try t.expectEqual(@as(?usize, cosmos), selection(listing).only());
    try t.expect(selection(listing).exact);
    // Another executable of the same name is another command.
    listing.current.next = .{ .sched = "/usr/local/bin/scx_cosmos" };
    try t.expectEqual(@as(usize, 0), selection(listing).count);
    // A bare name, or a profile whose scheduler is not installed, matches
    // by name only, which is not enough to act on.
    listing.current.next = .{ .sched = "scx_cosmos" };
    try t.expectEqual(Match.name, matchNext(listing.profiles[cosmos], listing.current.next.?));
    try t.expect(!selection(listing).exact);
    listing.current.next = .{ .sched = "/usr/bin/scx_eevdf", .args = &.{ "--slice-us", "1600", "--disable-cgroups" } };
    try t.expectEqualStrings("latency", listing.profiles[selection(listing).only().?].id);
    try t.expect(!selection(listing).exact);
    // Other options, an override or an unreadable environment select none.
    listing.current.next = .{ .sched = "/usr/bin/scx_eevdf", .args = &.{ "--slice-us", "1600" } };
    try t.expectEqual(@as(usize, 0), selection(listing).count);
    try t.expectEqual(@as(usize, 0), selection((try detected(a, "07-override-pending")).listing).count);
    var broken = (try detected(a, "01-cosmos-running")).listing;
    broken.current.config_error = "missing /etc/default/scx";
    try t.expectEqual(@as(usize, 0), selection(broken).count);
    // Two profiles for one command both match, and neither is the one picked.
    const both = try twin(a, (try detected(a, "01-cosmos-running")).listing);
    try t.expectEqual(@as(usize, 2), selection(both).count);
    try t.expect(selection(both).only() == null);
}

test "a command nothing starts leaves Default as the state and stays on show as configured" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const State = @FieldType(Status, "kind");
    // A fresh system: scx ships SCX_SCHEDULER=scx_cosmos, unit disabled.
    var fresh = (try detected(a, "03-nothing-configured")).listing;
    fresh.current.next = .{ .sched = "scx_cosmos" };
    const cosmos = fresh.find("scx_cosmos").?;
    try t.expectEqual(@as(?usize, cosmos), selection(fresh).only());
    var now = status(fresh, .inactive, false, false);
    try t.expectEqual(State.off, now.kind);
    try t.expect(now.idle);
    try t.expectEqualStrings("default", fresh.profiles[now.profile.?].id);
    try t.expectEqual(Mark.current, mark(fresh, now, 0));
    try t.expectEqual(Mark.configured, mark(fresh, now, cosmos));
    try t.expectEqualStrings("scx_cosmos", idleNext(fresh, now).?.sched);
    try t.expect(!crashed(now));

    // A manual start that failed is a failure of Cosmos, not Default.
    now = status(fresh, .failed, false, false);
    try t.expectEqual(State.failed, now.kind);
    try t.expectEqual(@as(?usize, cosmos), now.profile);
    try t.expect(crashed(now));
    var failed = fresh;
    failed.current.failure = .{ .message = "Error: scheduler exited", .status = "exit-code/1" };
    try t.expectEqual(State.failed, status(failed, .inactive, false, false).kind);
    // While it is being started by hand, it is starting.
    try t.expectEqual(State.starting, status(fresh, .activating, false, false).kind);

    // A hand-written command is handled alike, bare name or absolute path.
    for ([_][]const u8{ "scx_eevdf", "/usr/bin/scx_cosmos" }) |sched| {
        var manual = fresh;
        manual.current.next = .{ .sched = sched };
        const off = status(manual, .inactive, false, false);
        try t.expectEqual(State.off, off.kind);
        try t.expectEqualStrings(sched, idleNext(manual, off).?.sched);
    }
    // So is a command no profile stands for.
    var options = fresh;
    options.current.next = .{ .sched = "scx_lavd", .args = &.{"--performance"} };
    const off = status(options, .inactive, false, false);
    try t.expectEqual(State.off, off.kind);
    try t.expectEqualStrings("scx_lavd", idleNext(options, off).?.sched);

    // Stopped with the unit disabled (fixture 04): the command stays on show.
    const stopped = (try detected(a, "04-stopped-selection-kept")).listing;
    const kept = status(stopped, .inactive, false, false);
    try t.expectEqual(State.off, kept.kind);
    try t.expectEqual(Mark.configured, mark(stopped, kept, stopped.find("scx_cosmos").?));

    // Enabled, even for the current boot only: a stopped selection.
    fresh.current.unit_enabled_runtime = true;
    now = status(fresh, .inactive, false, false);
    try t.expectEqual(State.stopped, now.kind);
    try t.expect(!now.idle);
    try t.expectEqual(Mark.stopped, mark(fresh, now, cosmos));
    fresh.current.unit_enabled_runtime = false;
    fresh.current.unit_enabled = true;
    try t.expectEqual(State.stopped, status(fresh, .inactive, false, false).kind);
    // With a config_error `next` is incomplete: nothing shown as configured.
    var broken = (try detected(a, "03-nothing-configured")).listing;
    broken.current.next = .{ .sched = "scx_cosmos" };
    broken.current.config_error = "cannot read /etc/default/scx.d/local";
    now = status(broken, .inactive, false, false);
    try t.expectEqual(State.off, now.kind);
    try t.expect(!now.idle);
    try t.expect(idleNext(broken, now) == null);
    try t.expectEqual(Mark.none, mark(broken, now, cosmos));
    // Not idle unless systemd reports inactive: active is starting, unknown
    // is plain Default.
    var started = (try detected(a, "03-nothing-configured")).listing;
    started.current.next = .{ .sched = "scx_cosmos" };
    now = status(started, .active, false, false);
    try t.expect(!now.idle);
    try t.expectEqual(State.starting, now.kind);
    try t.expectEqual(@as(?usize, cosmos), now.profile);
    now = status(started, .unknown, false, false);
    try t.expect(!now.idle);
    try t.expectEqual(State.off, now.kind);
    try t.expectEqual(Mark.none, mark(started, now, cosmos));
    // Nor when scxcli itself says the unit is active.
    started.current.unit_active = true;
    try t.expect(!status(started, .inactive, false, false).idle);
    // A command no profile stands for is not idle while the unit is up either.
    var other = (try detected(a, "03-nothing-configured")).listing;
    other.current.next = .{ .sched = "scx_lavd", .args = &.{"--performance"} };
    try t.expect(!status(other, .active, false, false).idle);
    try t.expect(!status(other, .unknown, false, false).idle);
    // A unit still on its way down is not yet idle.
    var leaving = (try detected(a, "03-nothing-configured")).listing;
    leaving.current.next = .{ .sched = "scx_cosmos" };
    try t.expect(!status(leaving, .deactivating, false, false).idle);
    try t.expect(status(leaving, .inactive, false, false).idle);
    // Nothing configured is plain Default.
    try t.expect(!status((try detected(a, "03-nothing-configured")).listing, .inactive, false, false).idle);
}

test "status is what scxcli says runs, with the unit's live state" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const State = @FieldType(Status, "kind");
    const Expect = struct { fixture: []const u8, kind: State, profile: ?[]const u8 };
    for ([_]Expect{
        .{ .fixture = "01-cosmos-running", .kind = .running, .profile = "scx_cosmos" },
        .{ .fixture = "02-selected-but-failed", .kind = .failed, .profile = "scx_cosmos" },
        .{ .fixture = "03-nothing-configured", .kind = .off, .profile = "default" },
        // Stopped with the unit disabled: Default, idle.
        .{ .fixture = "04-stopped-selection-kept", .kind = .off, .profile = "default" },
        // A command no profile has.
        .{ .fixture = "05-run-with-options", .kind = .custom, .profile = null },
        .{ .fixture = "06-attached-outside-the-unit", .kind = .custom, .profile = null },
        // What runs counts, not what an override says the next start runs.
        .{ .fixture = "07-override-pending", .kind = .running, .profile = "scx_cosmos" },
        .{ .fixture = "08-no-sched-ext", .kind = .unavailable, .profile = null },
        .{ .fixture = "09-unit-active-not-yet-attached", .kind = .starting, .profile = "scx_cosmos" },
        .{ .fixture = "10-later-file-overrides", .kind = .custom, .profile = null },
        .{ .fixture = "11-hidden-started-by-run", .kind = .custom, .profile = null },
        .{ .fixture = "12-hand-written-name", .kind = .custom, .profile = null },
        .{ .fixture = "13-enabled-runtime", .kind = .running, .profile = "scx_cosmos" },
    }) |case| {
        const c = try detected(a, case.fixture);
        const now = status(c.listing, c.unit, false, false);
        t.expectEqual(case.kind, now.kind) catch |err| {
            std.debug.print("{s}: {t}\n", .{ case.fixture, now.kind });
            return err;
        };
        if (case.profile) |id| try t.expectEqualStrings(id, c.listing.profiles[now.profile.?].id) else try t.expect(now.profile == null);
    }
    // A scheduler that never attaches has failed, unless it was just chosen.
    const waiting = try detected(a, "09-unit-active-not-yet-attached");
    try t.expectEqual(State.failed, status(waiting.listing, .active, false, true).kind);
    try t.expectEqual(State.starting, status(waiting.listing, .active, true, true).kind);
    // A stopped unit starting again, or just switched, is starting.
    // With the unit enabled, `scxcli stop` keeps a stopped selection.
    var stopped = try detected(a, "04-stopped-selection-kept");
    stopped.listing.current.unit_enabled = true;
    try t.expectEqual(State.stopped, status(stopped.listing, .inactive, false, false).kind);
    try t.expectEqual(State.starting, status(stopped.listing, .activating, false, false).kind);
    try t.expectEqual(State.starting, status(stopped.listing, .inactive, true, false).kind);
    try t.expectEqual(State.failed, status((try detected(a, "02-selected-but-failed")).listing, .failed, true, false).kind);
    // The stopped selection stays marked as stopped, and is not "current".
    const cosmos = stopped.listing.find("scx_cosmos").?;
    try t.expectEqual(Mark.stopped, mark(stopped.listing, status(stopped.listing, .inactive, false, false), cosmos));
    try t.expectEqual(Mark.none, mark(stopped.listing, status(stopped.listing, .inactive, false, false), 0));

    // The file changed while the unit runs the old command: what runs is
    // shown, and while the change is fresh, it is a switch under way.
    var changed = (try detected(a, "01-cosmos-running")).listing;
    changed.current.next = .{ .sched = "/usr/bin/scx_eevdf", .args = &.{ "--slice-us", "1600", "--disable-cgroups" } };
    const now = status(changed, .active, false, false);
    try t.expectEqual(State.running, now.kind);
    try t.expectEqualStrings("scx_cosmos", changed.profiles[now.profile.?].id);
    const switching = status(changed, .active, true, false);
    try t.expectEqual(State.starting, switching.kind);
    try t.expectEqualStrings("latency", changed.profiles[switching.profile.?].id);
    // Default selected with a scheduler attached outside the unit: Default
    // stays marked, the status says custom.
    var outside = (try detected(a, "06-attached-outside-the-unit")).listing;
    outside.current.next = null;
    const custom = status(outside, .inactive, false, false);
    try t.expectEqual(State.custom, custom.kind);
    try t.expectEqual(Mark.current, mark(outside, custom, 0));

    // Two profiles for the command that runs: both are marked running.
    const both = try twin(a, (try detected(a, "01-cosmos-running")).listing);
    const shared = status(both, .active, false, false);
    try t.expectEqual(State.running, shared.kind);
    try t.expect(shared.ambiguous);
    try t.expectEqual(Mark.current, mark(both, shared, both.find("scx_cosmos").?));
    try t.expectEqual(Mark.current, mark(both, shared, both.find("cosmos-too").?));
    try t.expectEqual(Mark.none, mark(both, shared, 0));
}

test "schedulers are recognized by name and by the ops the kernel reports" {
    try t.expect(validName("scx_lavd"));
    try t.expect(validName("scx_my-sched_2"));
    for ([_][]const u8{ "", "scx_", "lavd", "/usr/bin/scx_lavd", "scx_la vd", "scx_lavd!" }) |bad| try t.expect(!validName(bad));
    try t.expect(validProfileId("latency"));
    try t.expect(validProfileId("gaming_2-fast"));
    for ([_][]const u8{ "", "default", "scx_lavd", "-latency", "_x", "Latency", "a b" }) |bad| try t.expect(!validProfileId(bad));
    try t.expect(validArg("--slice-us=1600"));
    try t.expect(validArg("/usr/share/scx/layered.json"));
    for ([_][]const u8{ "", "-s 700", "$(reboot)", "'", "50%", "a@b" }) |bad| try t.expect(!validArg(bad));
    try t.expectEqualStrings("scx_lavd", schedName("/usr/bin/scx_lavd"));
    try t.expect(opsMatches("/usr/bin/scx_cosmos", "cosmos_1.1.7_x86_64_unknown_linux_gnu"));
    try t.expect(opsMatches("scx_eevdf", "eevdf"));
    try t.expect(!opsMatches("scx_cosmos", "cosmosx_1.0"));
    try t.expect(!opsMatches("scx_lavd", "cosmos_1.1.7"));
    try t.expectEqualStrings("1.1.7", opsVersion("scx_cosmos", "cosmos_1.1.7_x86_64_unknown_linux_gnu").?);
    try t.expect(opsVersion("scx_eevdf", "eevdf") == null);
    try t.expect(validText("Ünïcode ✓", 1, 9));
    try t.expect(!validText("", 1, 64));
    try t.expect(!validText("tab\there", 0, 64));
    try t.expect(!validText("\xff", 0, 64));
}

test "only sched_ext uevents are relevant" {
    try t.expect(schedExtEvent("add@/kernel/sched_ext/root\x00ACTION=add\x00DEVPATH=/kernel/sched_ext/root\x00SUBSYSTEM=sched_ext\x00SCXOPS=cake_1.2.2_x86_64_unknown_linux_gnu\x00SEQNUM=5181\x00"));
    try t.expect(schedExtEvent("remove@/kernel/sched_ext/root\x00ACTION=remove\x00SUBSYSTEM=sched_ext"));
    try t.expect(!schedExtEvent("change@/devices/LNXSYSTM:00/ACPI0003:00/power_supply/AC\x00ACTION=change\x00SUBSYSTEM=power_supply\x00"));
    // The header alone does not count, nor a value that merely mentions it.
    try t.expect(!schedExtEvent("add@/SUBSYSTEM=sched_ext"));
    try t.expect(!schedExtEvent("add@/x\x00DEVPATH=/SUBSYSTEM=sched_ext\x00"));
}

test "only a confirmed failed status is a failure" {
    const at = struct {
        fn kind(k: @FieldType(Status, "kind")) Status {
            return .{ .kind = k, .profile = 1 };
        }
    }.kind;
    try t.expect(crashed(at(.failed)));
    for ([_]@FieldType(Status, "kind"){ .running, .starting, .off, .stopped, .custom, .unavailable }) |kind| try t.expect(!crashed(at(kind)));
    // Worked out from a state scxcli could not be asked for again, a failure
    // is not confirmed.
    var old = at(.failed);
    old.stale = true;
    try t.expect(!crashed(old));
}

test "a restart is a crash only of the command that ran at both confirmed states" {
    const cosmos_run: Command = .{ .sched = "scx_cosmos" };
    const lavd_run: Command = .{ .sched = "scx_lavd" };
    const cosmos: Status = .{ .kind = .running, .profile = 1 };
    const lavd: Status = .{ .kind = .running, .profile = 2 };
    var restarts: Restarts = .{};
    // Cosmos is confirmed running; systemd's count is 2. The first state is
    // a starting point.
    try t.expect(!restarts.observe(cosmos, cosmos_run, 2));
    // The next confirmed state names LAVD, count 3: the file was switched
    // and a crash brought it up, or someone started it. Who restarted is
    // not on record, so LAVD is not blamed.
    try t.expect(!restarts.observe(lavd, lavd_run, 3));
    // From there, a restart while LAVD keeps running is LAVD's own.
    try t.expect(restarts.observe(lavd, lavd_run, 4));
    try t.expect(!restarts.observe(lavd, lavd_run, 4));
    // A manual restart resets systemd's count: no crash.
    try t.expect(!restarts.observe(lavd, lavd_run, 0));
    // Same scheduler, other options: another command.
    try t.expect(!restarts.observe(lavd, .{ .sched = "/usr/bin/scx_lavd", .args = &.{"--performance"} }, 1));
    // The path does not make another command, the options do.
    try t.expect(identify(.{ .sched = "/usr/bin/scx_lavd" }) == identify(lavd_run));

    // A restart caught between runs (no process yet) is seen once the same
    // command is back.
    var gap: Restarts = .{};
    try t.expect(!gap.observe(cosmos, cosmos_run, 2));
    try t.expect(!gap.observe(.{ .kind = .starting, .profile = 1 }, null, 3));
    try t.expect(gap.observe(.{ .kind = .starting, .profile = 1 }, cosmos_run, 3));

    // Not attributed to a profile when the command runs outside them.
    var outside: Restarts = .{};
    try t.expect(!outside.observe(.{ .kind = .custom }, lavd_run, 2));
    try t.expect(!outside.observe(.{ .kind = .custom }, lavd_run, 3));
    // Without a readable count nothing is concluded from it.
    var unread: Restarts = .{};
    try t.expect(!unread.observe(cosmos, cosmos_run, null));
    try t.expect(!unread.observe(cosmos, cosmos_run, 5));
    try t.expect(unread.observe(cosmos, cosmos_run, 6));
}

test "restarts while scxcli could not be asked, or the listing was lost, are put on nobody" {
    const cosmos_run: Command = .{ .sched = "scx_cosmos" };
    const cosmos: Status = .{ .kind = .running, .profile = 1 };
    var restarts: Restarts = .{};
    try t.expect(!restarts.observe(cosmos, cosmos_run, 2));
    // scxcli cannot be asked; the status shown is the old one.
    var stale = cosmos;
    stale.stale = true;
    try t.expect(!restarts.observe(stale, cosmos_run, 3));
    // Even the same command when scxcli answers again: what ran in between
    // is not on record. The count is a new starting point.
    try t.expect(!restarts.observe(cosmos, cosmos_run, 3));
    try t.expect(restarts.observe(cosmos, cosmos_run, 4));
    // The listing lost (scxcli list failed) breaks the run of confirmed
    // states the same way.
    restarts.invalidate();
    try t.expect(!restarts.observe(cosmos, cosmos_run, 5));
}

test "a failure is concluded only from a state scxcli just gave" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const State = @FieldType(Status, "kind");
    // Cosmos is selected but stopped; scxcli's last answer says so.
    var listing = (try detected(a, "04-stopped-selection-kept")).listing;
    var tracker: Tracker = .{};
    tracker.answered(false);
    try t.expect(!tracker.judge(status(listing, .inactive, false, false), false, listing.current.running, 0));
    // Someone runs `scxcli start scx_lavd`, which fails: systemd signals the
    // unit failed, and the service refreshes before scxcli is asked again.
    // That refresh pairs the new unit state with the old answer, whose
    // selection is still Cosmos.
    const early = status(listing, .failed, false, false);
    try t.expectEqual(State.failed, early.kind);
    try t.expectEqualStrings("scx_cosmos", listing.profiles[early.profile.?].id);
    // Not concluded: the state is not scxcli's.
    try t.expect(!tracker.judge(early, false, listing.current.running, 0));
    // scxcli answers: the file now selects LAVD with options, which no
    // profile stands for, and the unit failed. Cosmos is not blamed, and
    // nothing outside the profiles is.
    listing.current.next = .{ .sched = "/usr/bin/scx_lavd", .args = &.{"--performance"} };
    listing.current.failure = .{ .message = "scx.service ended with result exit-code", .status = "exit-code/1" };
    tracker.answered(false);
    const later = status(listing, .failed, false, false);
    try t.expect(later.kind != State.failed);
    try t.expect(!tracker.judge(later, false, listing.current.running, 0));
    // Had it been Cosmos that failed, the answer says so, and that is a
    // failure of Cosmos.
    listing.current.next = .{ .sched = "/usr/bin/scx_cosmos" };
    tracker.answered(false);
    const cosmos = status(listing, .failed, false, false);
    try t.expectEqual(State.failed, cosmos.kind);
    try t.expect(tracker.judge(cosmos, false, listing.current.running, 0));
    // The same state judged again, by a later refresh with no new answer,
    // concludes nothing more.
    try t.expect(!tracker.judge(cosmos, false, listing.current.running, 0));
}

test "an answer overtaken by a change while it was asked for concludes nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Cosmos is selected but stopped.
    var listing = (try detected(a, "04-stopped-selection-kept")).listing;
    var tracker: Tracker = .{};
    tracker.answered(false);
    _ = tracker.judge(status(listing, .inactive, false, false), false, listing.current.running, 0);
    // Answer A is being asked for when another client's `scxcli start
    // scx_lavd` fails and systemd signals the unit failed. A arrives with
    // the state from before: Cosmos selected. Paired with the failed unit,
    // that reads as a Cosmos failure, but A is overtaken, so nothing is
    // concluded.
    tracker.answered(true);
    const early = status(listing, .failed, false, false);
    try t.expectEqual(@FieldType(Status, "kind").failed, early.kind);
    try t.expect(!tracker.judge(early, false, listing.current.running, 0));
    // Answer B, asked for after the change, is judged: LAVD with options,
    // no profile, so nobody is blamed.
    listing.current.next = .{ .sched = "/usr/bin/scx_lavd", .args = &.{"--performance"} };
    listing.current.failure = .{ .message = "exited with status 1", .status = "exit-code/1" };
    tracker.answered(false);
    try t.expect(!tracker.judge(status(listing, .failed, false, false), false, listing.current.running, 0));
    // An answer not overtaken that shows Cosmos failed is Cosmos' failure.
    listing.current.next = .{ .sched = "/usr/bin/scx_cosmos" };
    tracker.answered(false);
    try t.expect(tracker.judge(status(listing, .failed, false, false), false, listing.current.running, 0));
}

test "a failed answer drops the restart history whatever the status shows" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const running = (try detected(a, "01-cosmos-running")).listing;
    const now = status(running, .active, false, false);
    var tracker: Tracker = .{};
    tracker.answered(false);
    try t.expect(!tracker.judge(now, false, running.current.running, 2));
    // scxcli fails while the status is unavailable (here: no sched_ext),
    // which is not marked stale for display.
    const none = status((try detected(a, "08-no-sched-ext")).listing, .active, false, false);
    try t.expectEqual(@FieldType(Status, "kind").unavailable, none.kind);
    try t.expect(!none.stale);
    try t.expect(!tracker.judge(none, true, null, 3));
    // Once scxcli answers again with the same command, the count is a new
    // starting point, not a restart of Cosmos.
    tracker.answered(false);
    try t.expect(!tracker.judge(now, false, running.current.running, 3));
    tracker.answered(false);
    try t.expect(tracker.judge(now, false, running.current.running, 4));
}

test "asking again while unconfirmed backs off to every 16 seconds and never stops" {
    var retry: Retry = .{};
    for ([_]u32{ 1, 2, 4, 8, 16, 16, 16, 16 }) |expected| try t.expectEqual(expected, retry.next());
    retry.reset();
    try t.expectEqual(@as(u32, 1), retry.next());
}

test "exit reasons are read from log text and systemd's status" {
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
    try t.expectEqualStrings("unknown profile id \"x\"", errorLine("scxcli: unknown profile id \"x\"\n\nUSAGE:\n  scxcli ..."));
    try t.expectEqualStrings("Not authorized.", errorLine("\nNot authorized.\n"));
    try t.expectEqualStrings("", errorLine(""));
}

test "edited profiles go back into the catalog with its other lists kept" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (fixtures.valid_catalogs) |catalog| {
        const profiles = try parseCatalog(a, catalog);
        try validate(profiles);
        const rendered = try renderCatalog(a, catalog, profiles);
        const again = try parseCatalog(a, rendered);
        try t.expectEqual(profiles.len, again.len);
        for (profiles, again) |x, y| {
            try t.expectEqualStrings(x.id, y.id);
            try t.expectEqualStrings(x.label, y.label);
            try t.expectEqualStrings(x.description, y.description);
            try t.expect(sameCommand(x, y));
            try t.expectEqual(x.custom(), y.custom());
        }
        // Every other key survives, and so does the version.
        const before = try std.json.parseFromSliceLeaky(std.json.Value, a, catalog, .{});
        const after = try std.json.parseFromSliceLeaky(std.json.Value, a, rendered, .{});
        for (before.object.keys()) |key| try t.expect(after.object.get(key) != null);
        try t.expectEqual(before.object.get("version").?.integer, after.object.get("version").?.integer);
        if (before.object.get("hidden")) |hidden| try t.expectEqual(hidden.array.items.len, after.object.get("hidden").?.array.items.len);
    }
    // A custom profile makes a version 1 file version 2, with the featured
    // list it derived written out and held to version 2's rule.
    const old = try parseCatalog(a, fixtures.version_1_catalog);
    const added = try a.alloc(Profile, old.len + 1);
    @memcpy(added[0..old.len], old);
    added[old.len] = .{ .id = "quiet", .label = "Quiet", .sched = "scx_cosmos", .args = &.{"-v"} };
    const upgraded = try std.json.parseFromSliceLeaky(std.json.Value, a, try renderCatalog(a, fixtures.version_1_catalog, added), .{});
    try t.expectEqual(@as(i64, 2), upgraded.object.get("version").?.integer);
    // scx_cosmos is listed as stable there, so it is not also featured.
    try t.expectEqual(@as(usize, 0), upgraded.object.get("featured").?.array.items.len);
    try t.expectEqual(@as(usize, 2), upgraded.object.get("stable").?.array.items.len);
    try t.expectEqualStrings("quiet", (try parseCatalog(a, try renderCatalog(a, fixtures.version_1_catalog, added)))[2].id);
    // Lists scxcli would reject for their profiles are never sent.
    const shipped = try parseCatalog(a, fixtures.shipped_catalog);
    try t.expectError(error.DefaultNotFirst, validate(shipped[1..]));
    try t.expectError(error.DuplicateProfile, validate(&.{ shipped[0], shipped[1], shipped[1] }));
    try t.expectError(error.InvalidProfile, validate(&.{ shipped[0], .{ .id = "scx_x", .label = "X", .args = &.{"-v"} } }));
    try t.expectError(error.InvalidProfile, validate(&.{ shipped[0], .{ .id = "scx_x", .label = "X", .sched = "scx_lavd" } }));
    try t.expectError(error.InvalidArgument, validate(&.{ shipped[0], .{ .id = "x", .label = "X", .sched = "scx_lavd", .args = &.{"$(reboot)"} } }));
    try t.expectError(error.InvalidLabel, validate(&.{ shipped[0], .{ .id = "x", .label = "", .sched = "scx_lavd" } }));
    try validate(&.{ shipped[0], .{ .id = "x", .label = "X", .sched = "scx_lavd" } });
}

test "a restart decided by an edit waits for the same command still running" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cosmos: Command = .{ .sched = "scx_cosmos" };
    // Still running: restart.
    try t.expect(stillRuns((try detected(a, "01-cosmos-running")).listing, cosmos));
    // Another scheduler started meanwhile (scxcli start scx_lavd), the unit
    // stopped, or the same scheduler restarted with options: leave it.
    try t.expect(!stillRuns((try detected(a, "05-run-with-options")).listing, cosmos));
    try t.expect(!stillRuns((try detected(a, "04-stopped-selection-kept")).listing, cosmos));
    try t.expect(!stillRuns((try detected(a, "10-later-file-overrides")).listing, cosmos));
    // Not yet attached says nothing runs yet.
    try t.expect(!stillRuns((try detected(a, "09-unit-active-not-yet-attached")).listing, cosmos));
}

test "a catalog larger than scxcli catalog save reads is refused before saving" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shipped = try parseCatalog(a, fixtures.shipped_catalog);
    var profiles: std.ArrayList(Profile) = .empty;
    try profiles.appendSlice(a, shipped);
    const description: [max_description]u8 = @splat('d');
    var n: usize = 0;
    // Valid profiles, until the rendered file crosses the limit.
    while (true) : (n += 1) {
        try profiles.append(a, .{ .id = try std.fmt.allocPrint(a, "p{d}", .{n}), .label = "Profile", .description = &description, .sched = "scx_lavd", .args = &.{"--performance"} });
        _ = renderCatalog(a, fixtures.shipped_catalog, profiles.items) catch |err| {
            try t.expectEqual(error.CatalogTooLarge, err);
            break;
        };
    }
    // The last list that fits is at most the limit.
    profiles.items.len -= 1;
    try t.expect((try renderCatalog(a, fixtures.shipped_catalog, profiles.items)).len <= max_save_bytes);
}

test "new profiles get ids of their own and what runs is started again when its command changes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = (try parseListing(a, fixtures.listing)).profiles;
    var buffer: [max_id]u8 = undefined;
    try t.expectEqualStrings("my-lavd-2", slug(&buffer, "  My LAVD #2! ", before));
    try t.expectEqualStrings("profile", slug(&buffer, "!!!", before));
    try t.expectEqualStrings("default-2", slug(&buffer, "Default", before));
    try t.expectEqualStrings("latency-2", slug(&buffer, "Latency", before));
    try t.expect(validProfileId(slug(&buffer, "SCX Cosmos", before)));
    const long: [100]u8 = @splat('a');
    try t.expect(validProfileId(slug(&buffer, &long, before)));

    // Only what the unit actually runs is followed.
    const latency: Command = .{ .sched = "scx_eevdf", .args = &.{ "--slice-us", "1600", "--disable-cgroups" } };
    const l = findIn(before, "latency").?;
    // Unchanged, or only renamed: nothing to do.
    try t.expect(reapply(before, before, latency, null) == null);
    var profiles = try a.dupe(Profile, before);
    profiles[l].label = "Fast";
    try t.expect(reapply(before, profiles, latency, null) == null);
    // New options: start the profile again.
    profiles[l].args = &.{"--slice-us=800"};
    try t.expectEqualStrings("latency", reapply(before, profiles, latency, null).?);
    // Stopped (`scxcli stop`), failed or Default: an edit starts nothing,
    // whatever it did to the selected profile.
    try t.expect(reapply(before, profiles, null, null) == null);
    // Deleted: back to Default.
    const without = try a.dupe(Profile, before[0..1]);
    try t.expectEqualStrings("default", reapply(before, without, latency, null).?);
    // A plain profile that became a custom one is started under its new id.
    var converted = try a.dupe(Profile, before);
    const cosmos = findIn(before, "scx_cosmos").?;
    const plain: Command = .{ .sched = "scx_cosmos" };
    converted[cosmos] = .{ .id = "cosmos-quiet", .label = "Cosmos", .sched = "scx_cosmos", .args = &.{"-v"} };
    try t.expectEqualStrings("cosmos-quiet", reapply(before, converted, plain, .{ .from = "scx_cosmos", .to = "cosmos-quiet" }).?);
    // A command outside the profiles is left alone.
    try t.expect(reapply(before, without, .{ .sched = "scx_lavd", .args = &.{"--performance"} }, null) == null);
    // Two profiles for one command: deleting or changing one leaves the
    // other standing for it, so nothing is started; changing both leaves
    // no record of which was picked, so nothing is started either.
    const twins = try a.alloc(Profile, before.len + 1);
    @memcpy(twins[0..before.len], before);
    twins[before.len] = .{ .id = "cosmos-too", .label = "Cosmos too", .sched = "scx_cosmos" };
    try t.expect(reapply(twins, try std.mem.concat(a, Profile, &.{ twins[0..cosmos], twins[cosmos + 1 ..] }), plain, null) == null);
    const both = try a.dupe(Profile, twins);
    both[cosmos].args = &.{"-v"};
    try t.expect(reapply(twins, both, plain, null) == null);
    both[before.len].args = &.{"-v"};
    try t.expect(reapply(twins, both, plain, null) == null);

    const args = try splitArgs(a, "  --slice-us 1600\t--disable-cgroups ");
    try t.expectEqual(@as(usize, 3), args.len);
    try t.expectEqualStrings("1600", args[1]);
    try t.expectEqual(@as(usize, 0), (try splitArgs(a, "   ")).len);
    try t.expectError(error.InvalidArgument, splitArgs(a, "--log $(reboot)"));
    try t.expectError(error.InvalidArgument, splitArgs(a, "-s '700'"));
    try t.expectError(error.InvalidArgument, splitArgs(a, "--util 50%"));
}
