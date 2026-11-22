//! The profile editor's data. A dialog stays open while the service swaps
//! in new listings (every `scxcli list --json` replaces the previous one and
//! frees it), so everything the dialog keeps is copied into its own arena
//! when it opens, and saving works against the listing current at that
//! moment, refusing when it is no longer the one the dialog was opened on.
//! Pure data; the Settings view puts it on screen.
const std = @import("std");
const p = @import("sched_profiles.zig");

/// A scheduler the editor offers.
pub const Choice = struct {
    name: []const u8,
    /// Null for the edited profile's own scheduler when the listing does not
    /// offer it, such as a hidden scheduler a custom profile configures.
    tier: ?p.Tier,
};

/// What the user entered.
pub const Input = struct {
    label: []const u8,
    description: []const u8,
    /// Index into `choices`.
    scheduler: usize,
    options: []const u8,
};

/// The list to save, and which profile the edit gave a new id.
pub const Edit = struct {
    profiles: []const p.Profile,
    renamed: ?p.Rename,
};

pub const Draft = struct {
    arena: std.heap.ArenaAllocator,
    /// The profile being edited; null when adding one.
    id: ?[]const u8 = null,
    /// The listing the dialog was opened on (`p.signature`).
    signature: u64,
    /// What the fields start with.
    label: []const u8 = "",
    description: []const u8 = "",
    options: []const u8 = "",
    /// The installed schedulers the catalog does not hide, in the order scx
    /// lists them, plus the edited profile's own when they lack it.
    choices: []const Choice = &.{},
    /// The choice the dropdown starts on.
    selected: ?usize = null,

    /// Copy out of `listing` everything the dialog needs. index is the
    /// profile to edit, null to add one; Default cannot be edited.
    pub fn open(gpa: std.mem.Allocator, listing: p.Listing, index: ?usize) !Draft {
        var self: Draft = .{ .arena = .init(gpa), .signature = p.signature(listing) };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const profile: ?p.Profile = if (index) |i| listing.profiles[i] else null;
        if (profile) |value| {
            if (value.isDefault()) return error.Locked;
            self.id = try a.dupe(u8, value.id);
            self.label = try a.dupe(u8, value.label);
            self.description = try a.dupe(u8, value.description);
            var out: std.Io.Writer.Allocating = .init(a);
            for (value.args, 0..) |arg, i| try out.writer.print("{s}{s}", .{ if (i == 0) "" else " ", arg });
            self.options = try out.toOwnedSlice();
        }
        var choices: std.ArrayList(Choice) = .empty;
        for (listing.all) |entry| try choices.append(a, .{ .name = try a.dupe(u8, entry.name), .tier = entry.tier });
        if (profile) |value| {
            const own = value.scheduler().?;
            for (choices.items, 0..) |choice, i| {
                if (std.mem.eql(u8, choice.name, own)) {
                    self.selected = i;
                    break;
                }
            } else {
                self.selected = choices.items.len;
                try choices.append(a, .{ .name = try a.dupe(u8, own), .tier = null });
            }
        }
        self.choices = choices.items;
        return self;
    }

    pub fn deinit(self: *Draft) void {
        self.arena.deinit();
    }

    /// The profile list after the edit, against `listing`, the one current
    /// now; input null deletes the profile. Refuses with CatalogChanged when
    /// the listing is not the one the dialog was opened on: the profile may
    /// have moved, changed or gone, or the schedulers offered changed. The
    /// result is allocated in `a` and may borrow from `listing`, so it is
    /// for saving right away.
    pub fn commit(self: *const Draft, a: std.mem.Allocator, listing: p.Listing, input: ?Input) !Edit {
        if (p.signature(listing) != self.signature) return error.CatalogChanged;
        const index: ?usize = if (self.id) |id| listing.find(id) orelse return error.CatalogChanged else null;
        var profiles: std.ArrayList(p.Profile) = .empty;
        try profiles.appendSlice(a, listing.profiles);
        var renamed: ?p.Rename = null;
        if (input) |value| {
            const label = std.mem.trim(u8, value.label, " \t");
            if (!p.validText(label, 1, p.max_label)) return error.InvalidName;
            const description = std.mem.trim(u8, value.description, " \t");
            if (!p.validText(description, 0, p.max_description)) return error.InvalidDescription;
            if (value.scheduler >= self.choices.len) return error.NoScheduler;
            const sched = try a.dupe(u8, self.choices[value.scheduler].name);
            const args = try p.splitArgs(a, try a.dupe(u8, value.options));
            const old: ?p.Profile = if (index) |i| listing.profiles[i] else null;
            var profile: p.Profile = .{ .id = "", .label = try a.dupe(u8, label), .description = try a.dupe(u8, description) };
            if (old != null and !old.?.custom() and std.mem.eql(u8, old.?.id, sched) and args.len == 0) {
                // Still the scheduler with its own defaults: a plain
                // profile, whose id is its scheduler.
                profile.id = old.?.id;
            } else {
                // A scheduler with options of the administrator's choosing
                // is a custom profile, under an id of its own. A plain
                // profile edited into one gets a new id, and what runs
                // follows it.
                profile.sched = sched;
                profile.args = args;
                if (old != null and old.?.custom()) {
                    profile.id = old.?.id;
                } else {
                    var buffer: [p.max_id]u8 = undefined;
                    profile.id = try a.dupe(u8, p.slug(&buffer, label, listing.profiles));
                    if (old) |value_old| renamed = .{ .from = value_old.id, .to = profile.id };
                }
            }
            if (index) |i| profiles.items[i] = profile else try profiles.append(a, profile);
        } else {
            _ = profiles.orderedRemove(index orelse return error.NothingToDelete);
        }
        try p.validate(profiles.items);
        return .{ .profiles = profiles.items, .renamed = renamed };
    }
};

const t = std.testing;
const fixtures = @import("scx_fixtures");

/// The fixture listing parsed into an arena of its own, as the service
/// keeps each listing.
fn snapshot(arena: *std.heap.ArenaAllocator, bytes: []const u8) !p.Listing {
    // The service copies scxcli's output into the arena before parsing,
    // and the parsed strings may point into that copy.
    return p.parseListing(arena.allocator(), try arena.allocator().dupe(u8, bytes));
}

test "a dialog keeps working after the listing it was opened on is freed" {
    // The testing allocator poisons what is freed, so anything the draft
    // borrowed from the first listing would read back as garbage.
    var first = std.heap.ArenaAllocator.init(t.allocator);
    const before = try snapshot(&first, fixtures.listing);
    var draft = try Draft.open(t.allocator, before, before.find("latency").?);
    defer draft.deinit();
    // An equivalent listing replaces it, and the old one is freed.
    var second = std.heap.ArenaAllocator.init(t.allocator);
    defer second.deinit();
    const after = try snapshot(&second, fixtures.listing);
    first.deinit();

    try t.expectEqualStrings("latency", draft.id.?);
    try t.expectEqualStrings("Low latency", draft.label);
    try t.expectEqualStrings("--slice-us 1600 --disable-cgroups", draft.options);
    // latency's scheduler is not installed, so it is offered after the rest.
    try t.expectEqualStrings("scx_eevdf", draft.choices[draft.selected.?].name);
    try t.expect(draft.choices[draft.selected.?].tier == null);
    const lavd = for (draft.choices, 0..) |choice, i| {
        if (std.mem.eql(u8, choice.name, "scx_lavd")) break i;
    } else return error.NoLavd;
    try t.expectEqual(p.Tier.stable, draft.choices[lavd].tier.?);

    var scratch = std.heap.ArenaAllocator.init(t.allocator);
    defer scratch.deinit();
    const edit = try draft.commit(scratch.allocator(), after, .{ .label = "Fast", .description = "", .scheduler = lavd, .options = "--performance" });
    const saved = edit.profiles[after.find("latency").?];
    try t.expectEqualStrings("latency", saved.id);
    try t.expectEqualStrings("scx_lavd", saved.sched.?);
    try t.expectEqualStrings("--performance", saved.args[0]);
    try t.expect(edit.renamed == null);
}

test "a dialog refuses to save when the listing changed while it was open" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try snapshot(&arena, fixtures.listing);
    var draft = try Draft.open(t.allocator, before, before.find("scx_cosmos").?);
    defer draft.deinit();
    const input: Input = .{ .label = "Cosmos", .description = "", .scheduler = draft.selected.?, .options = "" };
    // Unchanged: saves, and a plain profile left with its own defaults stays
    // plain.
    const same = try draft.commit(a, before, input);
    try t.expect(!same.profiles[before.find("scx_cosmos").?].custom());

    // A scheduler installed meanwhile changes what the editor offers.
    var installed = before;
    const all = try a.alloc(p.Installed, before.all.len + 1);
    @memcpy(all[0..before.all.len], before.all);
    all[before.all.len] = .{ .name = "scx_ravd", .path = "/usr/local/bin/scx_ravd" };
    installed.all = all;
    try t.expectError(error.CatalogChanged, draft.commit(a, installed, input));
    // So does a profile edited, moved or deleted elsewhere.
    var edited = before;
    const profiles = try a.dupe(p.Profile, before.profiles);
    profiles[before.find("scx_cosmos").?].label = "Cosmos (edited elsewhere)";
    edited.profiles = profiles;
    try t.expectError(error.CatalogChanged, draft.commit(a, edited, input));
    var deleted = before;
    deleted.profiles = try std.mem.concat(a, p.Profile, &.{ before.profiles[0..1], before.profiles[2..] });
    try t.expectError(error.CatalogChanged, draft.commit(a, deleted, null));
    // What runs changing does not touch the profiles.
    var later = before;
    later.current.scheduler = "default";
    later.current.running = null;
    _ = try draft.commit(a, later, input);

    // Options turn it into a custom profile with an id of its own.
    const converted = try draft.commit(a, before, .{ .label = "Cosmos quiet", .description = "", .scheduler = draft.selected.?, .options = "-v" });
    try t.expectEqualStrings("cosmos-quiet", converted.renamed.?.to);
    try t.expectEqualStrings("scx_cosmos", converted.renamed.?.from);
    // Invalid input is reported, not saved.
    try t.expectError(error.InvalidName, draft.commit(a, before, .{ .label = " ", .description = "", .scheduler = 0, .options = "" }));
    try t.expectError(error.InvalidArgument, draft.commit(a, before, .{ .label = "X", .description = "", .scheduler = 0, .options = "50%" }));
    try t.expectError(error.NoScheduler, draft.commit(a, before, .{ .label = "X", .description = "", .scheduler = draft.choices.len, .options = "" }));
    try t.expectError(error.Locked, Draft.open(t.allocator, before, 0));
}

fn openAndCommit(gpa: std.mem.Allocator, listing: p.Listing) !void {
    var draft = try Draft.open(gpa, listing, listing.find("scx_cosmos").?);
    defer draft.deinit();
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    _ = try draft.commit(scratch.allocator(), listing, .{ .label = "Cosmos quiet", .description = "", .scheduler = draft.selected.?, .options = "-v" });
}

test "a draft frees what it took once, whichever allocation fails" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const listing = try snapshot(&arena, fixtures.listing);
    // Every allocation in turn fails; a double free or a leak on any of
    // those paths fails the test.
    try t.checkAllAllocationFailures(t.allocator, openAndCommit, .{listing});
}
