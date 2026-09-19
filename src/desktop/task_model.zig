//! Owned global taskbar snapshot. No GTK or borrowed model pointers survive update.
const std = @import("std");
const entities = @import("../aqueous/entities.zig");
const Model = @import("../aqueous/reducer.zig").Model;
const Allocator = std.mem.Allocator;
pub const Application = struct { id: []const u8, name: []const u8, wmclass: ?[]const u8 = null };
pub fn matches(id: []const u8, wmclass: ?[]const u8, win: entities.Window) bool {
    for ([_]?[]const u8{ win.app_id, win.class }) |value| if (value) |v| {
        if (v.len != 0 and (std.mem.eql(u8, @import("dock_policy.zig").stem(id), @import("dock_policy.zig").stem(v)) or (wmclass != null and std.mem.eql(u8, wmclass.?, v)))) return true;
    };
    return false;
}
pub fn match(apps: []const Application, win: entities.Window) ?Application {
    var found: ?Application = null;
    for (apps) |app| if (matches(app.id, app.wmclass, win)) {
        if (found != null) return null;
        found = app;
    };
    return found;
}
pub const Window = struct { id: [:0]const u8, title: [:0]const u8, workspace: ?[:0]const u8, output: ?[:0]const u8, focused: bool, minimized: bool, can_activate: bool };
pub const Group = struct {
    key: [:0]const u8,
    desktop: ?[:0]const u8,
    name: [:0]const u8,
    windows: std.ArrayList(Window) = .empty,
    pub fn focused(self: Group) bool {
        for (self.windows.items) |win| if (win.focused) return true;
        return false;
    }
    pub fn minimized(self: Group) bool {
        for (self.windows.items) |win| if (!win.minimized) return false;
        return self.windows.items.len != 0;
    }
};
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    groups: []const Group = &.{},
    revision: u64 = 0,
    digest: ?u64 = null,
    session: []const u8 = "",
    sequence: []const u8 = "",
    catalog_generation: u64 = std.math.maxInt(u64),
    pub fn init(a: Allocator) Snapshot {
        return .{ .arena = .init(a) };
    }
    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }
    pub fn reset(self: *Snapshot) void {
        const next = self.revision +% 1;
        const a = self.arena.child_allocator;
        self.deinit();
        self.* = init(a);
        self.revision = next;
    }
    pub fn find(self: *const Snapshot, key: []const u8) ?Group {
        for (self.groups) |group| if (std.mem.eql(u8, key, group.key)) return group;
        return null;
    }
    pub fn update(self: *Snapshot, model: *const Model, apps: []const Application, generation: u64) !void {
        if (!model.ready) {
            if (self.groups.len != 0 or self.sequence.len != 0) self.reset();
            return;
        }
        if (std.mem.eql(u8, self.session, model.session) and std.mem.eql(u8, self.sequence, model.sequence) and self.catalog_generation == generation) return;
        var next = init(self.arena.child_allocator);
        errdefer next.deinit();
        const a = next.arena.allocator();
        next.session = try a.dupe(u8, model.session);
        next.sequence = try a.dupe(u8, model.sequence);
        next.catalog_generation = generation;
        var groups: std.ArrayList(Group) = .empty;
        var map: std.StringHashMapUnmanaged(usize) = .empty;
        for (try model.windows(a, .{ .purpose = .taskbar })) |win| {
            const app = match(apps, win.*);
            const identity = nonempty(win.app_id) orelse nonempty(win.class);
            const key = if (app) |v| try std.fmt.allocPrintSentinel(a, "desktop:{s}", .{v.id}, 0) else try std.fmt.allocPrintSentinel(a, "{s}:{s}", .{ if (nonempty(win.app_id) != null) "app" else if (identity != null) "class" else "window", identity orelse win.id }, 0);
            const slot = try map.getOrPut(a, key);
            if (!slot.found_existing) {
                slot.value_ptr.* = groups.items.len;
                try groups.append(a, .{ .key = key, .desktop = if (app) |v| try a.dupeZ(u8, v.id) else null, .name = try a.dupeZ(u8, if (app) |v| v.name else identity orelse "Application") });
            }
            const ws = if (win.workspace) |id| model.get(.workspace, id) else null;
            const output = if (win.output) |id| model.get(.output, id) else null;
            try groups.items[slot.value_ptr.*].windows.append(a, .{ .id = try a.dupeZ(u8, win.id), .title = try a.dupeZ(u8, nonempty(win.title) orelse identity orelse "Application"), .workspace = if (ws) |v| try a.dupeZ(u8, v.name) else null, .output = if (output) |v| try a.dupeZ(u8, v.name) else null, .focused = win.focused, .minimized = win.minimized, .can_activate = win.can_activate });
        }
        const previous = if (std.mem.eql(u8, self.session, model.session)) self.groups else &.{};
        std.mem.sort(Group, groups.items, previous, struct {
            fn rank(old: []const Group, key: []const u8) usize {
                for (old, 0..) |g, i| if (std.mem.eql(u8, g.key, key)) return i;
                return std.math.maxInt(usize);
            }
            fn less(old: []const Group, x: Group, y: Group) bool {
                const xr = rank(old, x.key);
                const yr = rank(old, y.key);
                if (xr != yr) return xr < yr;
                const order = std.mem.order(u8, x.name, y.name);
                return if (order == .eq) std.mem.lessThan(u8, x.key, y.key) else order == .lt;
            }
        }.less);
        next.groups = try groups.toOwnedSlice(a);
        var hash = std.hash.Wyhash.init(generation);
        hash.update(model.session);
        for (next.groups) |g| {
            hash.update(try std.json.Stringify.valueAlloc(a, .{ g.key, g.desktop, g.name, g.windows.items }, .{}));
        }
        next.digest = hash.final();
        next.revision = self.revision +% @as(u64, @intFromBool(self.digest == null or self.digest.? != next.digest.?));
        self.deinit();
        self.* = next;
    }
};
fn nonempty(value: ?[]const u8) ?[]const u8 {
    return if (value) |v| if (v.len != 0) v else null else null;
}

// Fitting never caps the model, and reserves one slot for overflow before icons.
pub fn visibleCount(count: usize, slots: usize) usize {
    return if (count <= slots) count else @min(count, slots -| 1);
}

test "unique desktop matching and taskbar overflow have no collection cap" {
    const t = std.testing;
    var win: entities.Window = undefined;
    win.app_id = "org.test.App";
    win.class = null;
    const apps = [_]Application{ .{ .id = "org.test.App.desktop", .name = "App" }, .{ .id = "other.desktop", .name = "Other", .wmclass = "Legacy" } };
    try t.expectEqualStrings("App", match(&apps, win).?.name);
    win.app_id = null;
    win.class = "Legacy";
    try t.expectEqualStrings("Other", match(&apps, win).?.name);
    const ambiguous = [_]Application{ apps[1], .{ .id = "third.desktop", .name = "Third", .wmclass = "Legacy" } };
    try t.expect(match(&ambiguous, win) == null);
    win.class = "";
    try t.expect(match(&apps, win) == null);
    try t.expectEqual(@as(usize, 100), visibleCount(100, 100));
    try t.expectEqual(@as(usize, 5), visibleCount(100, 6));
    try t.expectEqual(@as(usize, 0), visibleCount(100, 1));
}

fn fixtureWindow(id: []const u8, app: ?[]const u8) entities.Window {
    return std.mem.zeroInit(entities.Window, .{ .id = id, .app_id = app, .title = "Shared title", .layout = "tile", .can_activate = true, .geometry = .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .outer_geometry = .{ .x = 0, .y = 0, .width = 100, .height = 100 } });
}
test "global snapshot retains all windows, exclusions, owned identities and stable ordering" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model = try Model.init(t.allocator, (@import("../aqueous/codec.zig").Limits{}).state_bytes);
    defer model.deinit();
    var snapshot = Snapshot.init(t.allocator);
    defer snapshot.deinit();
    var values: std.ArrayList(entities.Entity) = .empty;
    try values.append(a, .{ .session = .{ .id = "session", .locked = false, .default_seat = null, .overview_output = null, .overview_window = null } });
    for (0..70) |i| {
        var win = fixtureWindow(try std.fmt.allocPrint(a, "many-{d}", .{i}), "Many");
        win.minimized = i % 2 == 0;
        win.skip_switcher = true;
        win.can_activate = i != 69;
        try values.append(a, .{ .window = win });
    }
    for (0..40) |i| try values.append(a, .{ .window = fixtureWindow(try std.fmt.allocPrint(a, "one-{d}", .{i}), try std.fmt.allocPrint(a, "App-{d}", .{i})) });
    var excluded = fixtureWindow("excluded", "Excluded");
    excluded.skip_taskbar = true;
    try values.append(a, .{ .window = excluded });
    try values.append(a, .{ .window = fixtureWindow("anonymous-1", null) });
    try values.append(a, .{ .window = fixtureWindow("anonymous-2", "") });
    const token = "0123456789abcdef0123456789abcdef";
    try model.apply(.{ .type = .snapshot, .session = token, .sequence = "1", .base_sequence = null, .upsert = values.items, .removed = &.{} });
    try snapshot.update(&model, &.{}, 0);
    try t.expectEqual(@as(usize, 43), snapshot.groups.len);
    try t.expectEqual(@as(usize, 70), snapshot.find("app:Many").?.windows.items.len);
    try t.expect(snapshot.find("app:Excluded") == null);
    try t.expect(snapshot.find("window:anonymous-1") != null and snapshot.find("window:anonymous-2") != null);
    try t.expect(snapshot.find("app:Many").?.windows.items[0].workspace == null);
    const order = try a.dupe(u8, snapshot.groups[0].key);
    const revision = snapshot.revision;
    try snapshot.update(&model, &.{}, 0);
    try t.expectEqual(revision, snapshot.revision);
    var changed = fixtureWindow("many-0", "Many");
    changed.focused = true;
    try model.apply(.{ .type = .delta, .session = token, .sequence = "2", .base_sequence = "1", .upsert = &.{.{ .window = changed }}, .removed = &.{} });
    try snapshot.update(&model, &.{}, 0);
    try t.expect(snapshot.find("app:Many").?.focused());
    try t.expectEqualStrings(order, snapshot.groups[0].key);
    try t.expect(snapshot.revision > revision);
    // A new catalog can reclassify a group without losing windows.
    try snapshot.update(&model, &.{.{ .id = "Many.desktop", .name = "Installed app" }}, 1);
    try t.expectEqual(@as(usize, 70), snapshot.find("desktop:Many.desktop").?.windows.items.len);
    model.clear();
    try t.expectEqualStrings("Shared title", snapshot.find("desktop:Many.desktop").?.windows.items[0].title);
    try snapshot.update(&model, &.{}, 1);
    try t.expectEqual(@as(usize, 0), snapshot.groups.len);
}
