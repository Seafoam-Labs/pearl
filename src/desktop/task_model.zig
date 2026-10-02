//! Owned global taskbar snapshot. No GTK or borrowed model pointers survive update.
const std = @import("std");
const entities = @import("../aqueous/entities.zig");
const Model = @import("../aqueous/reducer.zig").Model;
const Allocator = std.mem.Allocator;
const identity_policy = @import("app_identity.zig");
pub const Application = struct { id: []const u8, name: []const u8, wmclass: ?[]const u8 = null, available: bool = true, user_local: bool = false };
pub fn matches(id: []const u8, wmclass: ?[]const u8, win: entities.Window) bool {
    for ([_]?[]const u8{ win.app_id, win.class }) |value| if (value) |v| {
        if (v.len != 0 and (std.mem.eql(u8, @import("dock_policy.zig").stem(id), @import("dock_policy.zig").stem(v)) or (wmclass != null and std.mem.eql(u8, wmclass.?, v)))) return true;
    };
    return false;
}
pub fn match(apps: []const Application, win: entities.Window, pins: []const []const u8) ?Application {
    var found: ?Application = null;
    var best: u8 = 0;
    var ambiguous = false;
    for (apps) |app| if (app.available and matches(app.id, app.wmclass, win)) {
        var rank: u8 = if (app.user_local) 2 else 1;
        for (pins) |id| if (std.mem.eql(u8, id, app.id)) {
            rank = 3;
            break;
        };
        if (rank > best) {
            best = rank;
            found = app;
            ambiguous = false;
        } else if (rank == best) ambiguous = true;
    };
    return if (ambiguous) null else found;
}
pub fn resolve(apps: []const Application, win: entities.Window, choices: []const identity_policy.Association, pins: []const []const u8) ?Application {
    if (identity_policy.selected(choices, win)) |id| {
        for (apps) |app| if (std.mem.eql(u8, id, app.id)) return app;
        return .{ .id = id, .name = id, .available = false };
    }
    return match(apps, win, pins);
}
pub const Window = struct { id: [:0]const u8, title: [:0]const u8, workspace: ?[:0]const u8, output: ?[:0]const u8, focused: bool, minimized: bool, can_activate: bool, icon: ?entities.Icon = null };
/// A flat task order alongside the chooser groups. Strings share the snapshot arena.
pub const Task = struct { window: Window, group: [:0]const u8 };
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
    windows: []const Task = &.{},
    revision: u64 = 0,
    digest: ?u64 = null,
    session: []const u8 = "",
    sequence: []const u8 = "",
    catalog_generation: u64 = std.math.maxInt(u64),
    association_hash: u64 = 0,
    pin_hash: u64 = 0,
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
        return self.updateWithLaunchers(model, apps, generation, &.{}, &.{});
    }
    pub fn updateWithLaunchers(self: *Snapshot, model: *const Model, apps: []const Application, generation: u64, choices: []const identity_policy.Association, pins: []const []const u8) !void {
        if (!model.ready) {
            if (self.groups.len != 0 or self.sequence.len != 0) self.reset();
            return;
        }
        const association_hash = identity_policy.digest(choices);
        const pin_hash = identity_policy.pinDigest(pins);
        if (std.mem.eql(u8, self.session, model.session) and std.mem.eql(u8, self.sequence, model.sequence) and self.catalog_generation == generation and self.association_hash == association_hash and self.pin_hash == pin_hash) return;
        var next = init(self.arena.child_allocator);
        errdefer next.deinit();
        const a = next.arena.allocator();
        next.session = try a.dupe(u8, model.session);
        next.sequence = try a.dupe(u8, model.sequence);
        next.catalog_generation = generation;
        next.association_hash = association_hash;
        next.pin_hash = pin_hash;
        var groups: std.ArrayList(Group) = .empty;
        var map: std.StringHashMapUnmanaged(usize) = .empty;
        const ordered = try model.windows(a, .{ .purpose = .taskbar });
        var indexed = false;
        for (ordered) |win| if (win.layout_index != null) {
            indexed = true;
            break;
        };
        if (indexed) std.mem.sort(*const entities.Window, ordered, model, layoutOrderLess);
        const windows = try a.alloc(Task, ordered.len);
        for (ordered, 0..) |win, i| {
            const app = resolve(apps, win.*, choices, pins);
            const identity = nonempty(win.app_id) orelse nonempty(win.class);
            const key = if (app) |v| try std.fmt.allocPrintSentinel(a, "desktop:{s}", .{v.id}, 0) else try std.fmt.allocPrintSentinel(a, "{s}:{s}", .{ if (nonempty(win.app_id) != null) "app" else if (identity != null) "class" else "window", identity orelse win.id }, 0);
            const slot = try map.getOrPut(a, key);
            if (!slot.found_existing) {
                slot.value_ptr.* = groups.items.len;
                try groups.append(a, .{ .key = key, .desktop = if (app) |v| try a.dupeZ(u8, v.id) else null, .name = if (app != null and !app.?.available) try std.fmt.allocPrintSentinel(a, "{s} — launcher unavailable", .{app.?.id}, 0) else try a.dupeZ(u8, if (app) |v| v.name else identity orelse "Application") });
            }
            const ws = if (win.workspace) |id| model.get(.workspace, id) else null;
            const output = if (win.output) |id| model.get(.output, id) else null;
            try groups.items[slot.value_ptr.*].windows.append(a, .{ .id = try a.dupeZ(u8, win.id), .title = try a.dupeZ(u8, nonempty(win.title) orelse identity orelse "Application"), .workspace = if (ws) |v| try a.dupeZ(u8, v.name) else null, .output = if (output) |v| try a.dupeZ(u8, v.name) else null, .focused = win.focused, .minimized = win.minimized, .can_activate = win.can_activate, .icon = try entities.clone(?entities.Icon, a, win.icon) });
            const group = groups.items[slot.value_ptr.*];
            windows[i] = .{ .window = group.windows.items[group.windows.items.len - 1], .group = group.key };
        }
        const previous = if (std.mem.eql(u8, self.session, model.session)) self.groups else &.{};
        if (!indexed) std.mem.sort(Group, groups.items, previous, struct {
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
        next.windows = windows;
        var hash = std.hash.Wyhash.init(generation);
        hash.update(model.session);
        for (next.groups) |g| {
            hash.update(try std.json.Stringify.valueAlloc(a, .{ g.key, g.desktop, g.name, g.windows.items }, .{}));
        }
        for (windows) |task| {
            hash.update(std.mem.asBytes(&task.window.id.len));
            hash.update(task.window.id);
        }
        next.digest = hash.final();
        next.revision = self.revision +% @as(u64, @intFromBool(self.digest == null or self.digest.? != next.digest.?));
        self.deinit();
        self.* = next;
    }
};
fn scopeOrder(x: ?[]const u8, y: ?[]const u8) std.math.Order {
    if (x == null or y == null) return if (x == null and y == null) .eq else if (x == null) .gt else .lt;
    return std.mem.order(u8, x.?, y.?);
}
fn layoutOrderLess(model: *const Model, x: *const entities.Window, y: *const entities.Window) bool {
    const xo = if (x.output) |id| model.get(.output, id) else null;
    const yo = if (y.output) |id| model.get(.output, id) else null;
    if ((xo == null) != (yo == null)) return yo == null;
    if (xo) |left| if (yo) |right| {
        if (left.bounds.x != right.bounds.x) return left.bounds.x < right.bounds.x;
        if (left.bounds.y != right.bounds.y) return left.bounds.y < right.bounds.y;
    };
    const output = scopeOrder(x.output, y.output);
    if (output != .eq) return output == .lt;
    const xw = if (x.workspace) |id| model.get(.workspace, id) else null;
    const yw = if (y.workspace) |id| model.get(.workspace, id) else null;
    if ((xw == null) != (yw == null)) return yw == null;
    if (xw) |left| if (yw) |right| if (left.number != right.number) return left.number < right.number;
    const workspace = scopeOrder(x.workspace, y.workspace);
    if (workspace != .eq) return workspace == .lt;
    if ((x.layout_index == null) != (y.layout_index == null)) return y.layout_index == null;
    if (x.layout_index) |left| if (y.layout_index) |right| if (left != right) return left < right;
    return std.mem.lessThan(u8, x.id, y.id);
}
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
    try t.expectEqualStrings("App", match(&apps, win, &.{}).?.name);
    win.app_id = null;
    win.class = "Legacy";
    try t.expectEqualStrings("Other", match(&apps, win, &.{}).?.name);
    const ambiguous = [_]Application{ apps[1], .{ .id = "third.desktop", .name = "Third", .wmclass = "Legacy" } };
    try t.expect(match(&ambiguous, win, &.{}) == null);
    win.class = "";
    try t.expect(match(&apps, win, &.{}) == null);
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

test "explicit launcher overrides identity and missing selections never fall back" {
    const t = std.testing;
    const apps = [_]Application{ .{ .id = "App.desktop", .name = "Packaged" }, .{ .id = "Custom.desktop", .name = "Custom" } };
    const choices = [_]identity_policy.Association{.{ .backend = .xdg, .identity = "App", .desktop_id = "Custom.desktop" }};
    const win = fixtureWindow("window", "App");
    try t.expectEqualStrings("Custom.desktop", resolve(&apps, win, &choices, &.{}).?.id);
    const missing = resolve(apps[0..1], win, &choices, &.{}).?;
    try t.expectEqualStrings("Custom.desktop", missing.id);
    try t.expect(!missing.available);
    try t.expectEqualStrings("App.desktop", resolve(&apps, win, &.{}, &.{}).?.id);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var model = try Model.init(t.allocator, (@import("../aqueous/codec.zig").Limits{}).state_bytes);
    defer model.deinit();
    // Reuse the same model sequence while only the association changes.
    model.ready = true;
    try model.entities.put(model.arena.allocator(), .{ .kind = .window, .id = win.id }, .{ .window = win });
    var snapshot = Snapshot.init(arena.allocator());
    defer snapshot.deinit();
    try snapshot.updateWithLaunchers(&model, &apps, 1, &.{}, &.{});
    try t.expect(snapshot.find("desktop:App.desktop") != null);
    const before = snapshot.revision;
    try snapshot.updateWithLaunchers(&model, &apps, 1, &choices, &.{});
    try t.expect(snapshot.revision > before);
    try t.expect(snapshot.find("desktop:Custom.desktop") != null);
}

test "preferred launcher ranking is independent of catalog order and never guesses an identity" {
    const t = std.testing;
    const packaged: Application = .{ .id = "App.desktop", .name = "Packaged", .wmclass = "App" };
    const custom: Application = .{ .id = "Custom App.desktop", .name = "Custom", .wmclass = "App", .user_local = true };
    const other: Application = .{ .id = "Other.desktop", .name = "Other", .wmclass = "App", .user_local = true };
    const unrelated: Application = .{ .id = "Unrelated.desktop", .name = "Unrelated", .user_local = true };
    const win = fixtureWindow("window", "App");
    for ([_][3]Application{ .{ packaged, custom, unrelated }, .{ unrelated, custom, packaged } }) |apps| {
        try t.expectEqualStrings(custom.id, match(&apps, win, &.{}).?.id);
        try t.expectEqualStrings(custom.id, match(&apps, win, &.{custom.id}).?.id);
        try t.expectEqualStrings(packaged.id, match(&apps, win, &.{ packaged.id, unrelated.id }).?.id);
        try t.expect(match(&apps, win, &.{ packaged.id, custom.id }) == null);
        const choices = [_]identity_policy.Association{.{ .backend = .xdg, .identity = "App", .desktop_id = custom.id }};
        try t.expectEqualStrings(custom.id, resolve(&apps, win, &choices, &.{packaged.id}).?.id);
    }
    try t.expect(match(&.{ packaged, custom, other }, win, &.{}) == null);
    try t.expectEqualStrings(packaged.id, match(&.{ custom, other, packaged }, win, &.{packaged.id}).?.id);
    try t.expectEqualStrings(packaged.id, match(&.{ unrelated, packaged }, win, &.{unrelated.id}).?.id);
    var legacy = win;
    legacy.backend = .xwayland;
    legacy.app_id = null;
    legacy.class = "App";
    try t.expectEqualStrings(custom.id, match(&.{ packaged, custom }, legacy, &.{}).?.id);
}

test "pin changes alone reclassify the global snapshot and removing pins restores user preference" {
    const t = std.testing;
    const apps = [_]Application{ .{ .id = "App.desktop", .name = "Packaged" }, .{ .id = "Custom.desktop", .name = "Custom", .wmclass = "App", .user_local = true } };
    var model = try Model.init(t.allocator, (@import("../aqueous/codec.zig").Limits{}).state_bytes);
    defer model.deinit();
    model.ready = true;
    const win = fixtureWindow("window", "App");
    try model.entities.put(model.arena.allocator(), .{ .kind = .window, .id = win.id }, .{ .window = win });
    var snapshot = Snapshot.init(t.allocator);
    defer snapshot.deinit();
    try snapshot.updateWithLaunchers(&model, &apps, 1, &.{}, &.{});
    try t.expect(snapshot.find("desktop:Custom.desktop") != null);
    const before = snapshot.revision;
    try snapshot.updateWithLaunchers(&model, &apps, 1, &.{}, &.{"App.desktop"});
    try t.expect(snapshot.revision > before);
    try t.expect(snapshot.find("desktop:App.desktop") != null);
    try snapshot.updateWithLaunchers(&model, &apps, 1, &.{}, &.{});
    try t.expect(snapshot.find("desktop:Custom.desktop") != null);
}

test "task order spans scopes and applications while chooser groups stay intact" {
    const t = std.testing;
    var model = try Model.init(t.allocator, (@import("../aqueous/codec.zig").Limits{}).state_bytes);
    defer model.deinit();
    var snapshot = Snapshot.init(t.allocator);
    defer snapshot.deinit();
    const token = "0123456789abcdef0123456789abcdef";
    var values = [_]entities.Entity{
        .{ .session = .{ .id = "session", .locked = false, .default_seat = null, .overview_output = null, .overview_window = null } },
        .{ .output = std.mem.zeroInit(entities.Output, .{ .id = "left", .name = "Left", .scale = 1, .transform = "normal", .active_workspace = "ws1" }) },
        .{ .output = std.mem.zeroInit(entities.Output, .{ .id = "right", .name = "Right", .scale = 1, .transform = "normal", .bounds = .{ .x = 1920, .y = 0, .width = 1920, .height = 1080 } }) },
        .{ .workspace = .{ .id = "ws1", .output = "left", .name = "1", .number = 1, .active = true, .urgent = false } },
        .{ .workspace = .{ .id = "ws2", .output = "left", .name = "2", .number = 2, .active = false, .urgent = false } },
        .{ .workspace = .{ .id = "ws3", .output = "right", .name = "1", .number = 1, .active = false, .urgent = false } },
        .{ .window = fixtureWindow("z", "Alpha") },
        .{ .window = fixtureWindow("y", "Beta") },
        .{ .window = fixtureWindow("x", "Alpha") },
        .{ .window = fixtureWindow("u", "Alpha") },
        .{ .window = fixtureWindow("w", "Alpha") },
        .{ .window = fixtureWindow("v", "Alpha") },
        .{ .window = fixtureWindow("a", null) },
    };
    for (values[6..12], 0..) |*value, i| {
        value.window.output = if (i == 5) "right" else "left";
        value.window.workspace = if (i == 5) "ws3" else if (i == 4) "ws2" else "ws1";
        value.window.layout_index = if (i == 3) null else if (i >= 4) 0 else @intCast(i);
    }
    values[9].window.minimized = true;
    try model.apply(.{ .type = .snapshot, .session = token, .sequence = "1", .base_sequence = null, .upsert = &values, .removed = &.{} });
    try snapshot.update(&model, &.{}, 0);
    const expected = [_][]const u8{ "z", "y", "x", "u", "w", "v", "a" };
    for (expected, snapshot.windows) |id, task| try t.expectEqualStrings(id, task.window.id);
    try t.expectEqual(@as(usize, 3), snapshot.groups.len);
    try t.expectEqual(@as(usize, 5), snapshot.find("app:Alpha").?.windows.items.len);
    const before = snapshot.revision;
    // Moving Beta past Alpha's second window changes only the flat order:
    // application order and the order inside each application remain the same.
    values[7].window.layout_index = 2;
    values[8].window.layout_index = 1;
    try model.apply(.{ .type = .delta, .session = token, .sequence = "2", .base_sequence = "1", .upsert = values[7..9], .removed = &.{} });
    try snapshot.update(&model, &.{}, 0);
    try t.expect(snapshot.revision > before);
    try t.expectEqualStrings("x", snapshot.windows[1].window.id);
    try t.expectEqualStrings("y", snapshot.windows[2].window.id);
    // Without any published indices preserve the reducer's ID order.
    for (values[6..]) |*value| value.window.layout_index = null;
    try model.apply(.{ .type = .delta, .session = token, .sequence = "3", .base_sequence = "2", .upsert = values[6..], .removed = &.{} });
    try snapshot.update(&model, &.{}, 0);
    const fallback = [_][]const u8{ "a", "u", "v", "w", "x", "y", "z" };
    for (fallback, snapshot.windows) |id, task| try t.expectEqualStrings(id, task.window.id);
    // Closing a window drops it from both presentations.
    try model.apply(.{ .type = .delta, .session = token, .sequence = "4", .base_sequence = "3", .upsert = &.{}, .removed = &.{.{ .kind = .window, .id = "y" }} });
    try snapshot.update(&model, &.{}, 0);
    try t.expectEqual(@as(usize, 6), snapshot.windows.len);
    try t.expect(snapshot.find("app:Beta") == null);
}
