//! Owned global taskbar snapshot. No GTK or borrowed model pointers survive update.
const std = @import("std");
const entities = @import("../aqueous/entities.zig");
const Model = @import("../aqueous/reducer.zig").Model;
const Allocator = std.mem.Allocator;
const identity_policy = @import("app_identity.zig");
pub const Application = struct { id: []const u8, name: []const u8, wmclass: ?[]const u8 = null, available: bool = true };
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
pub fn resolve(apps: []const Application, win: entities.Window, choices: []const identity_policy.Association) ?Application {
    if (identity_policy.selected(choices, win)) |id| {
        for (apps) |app| if (std.mem.eql(u8, id, app.id)) return app;
        return .{ .id = id, .name = id, .available = false };
    }
    return match(apps, win);
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
    association_hash: u64 = 0,
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
        return self.updateWithLaunchers(model, apps, generation, &.{});
    }
    pub fn updateWithLaunchers(self: *Snapshot, model: *const Model, apps: []const Application, generation: u64, choices: []const identity_policy.Association) !void {
        if (!model.ready) {
            if (self.groups.len != 0 or self.sequence.len != 0) self.reset();
            return;
        }
        const association_hash = identity_policy.digest(choices);
        if (std.mem.eql(u8, self.session, model.session) and std.mem.eql(u8, self.sequence, model.sequence) and self.catalog_generation == generation and self.association_hash == association_hash) return;
        var next = init(self.arena.child_allocator);
        errdefer next.deinit();
        const a = next.arena.allocator();
        next.session = try a.dupe(u8, model.session);
        next.sequence = try a.dupe(u8, model.sequence);
        next.catalog_generation = generation;
        next.association_hash = association_hash;
        var groups: std.ArrayList(Group) = .empty;
        var map: std.StringHashMapUnmanaged(usize) = .empty;
        const taskbar = try model.windows(a, .{ .purpose = .taskbar });
        var indexed = false;
        for (taskbar) |win| if (win.layout_index != null) {
            indexed = true;
            break;
        };
        // Published layout order wins; without any index the ID-based order and
        // the previous-rank group comparator below stay in charge.
        if (indexed) std.mem.sort(*const entities.Window, taskbar, model, layoutOrderLess);
        for (taskbar) |win| {
            const app = resolve(apps, win.*, choices);
            const identity = nonempty(win.app_id) orelse nonempty(win.class);
            const key = if (app) |v| try std.fmt.allocPrintSentinel(a, "desktop:{s}", .{v.id}, 0) else try std.fmt.allocPrintSentinel(a, "{s}:{s}", .{ if (nonempty(win.app_id) != null) "app" else if (identity != null) "class" else "window", identity orelse win.id }, 0);
            const slot = try map.getOrPut(a, key);
            if (!slot.found_existing) {
                slot.value_ptr.* = groups.items.len;
                try groups.append(a, .{ .key = key, .desktop = if (app) |v| try a.dupeZ(u8, v.id) else null, .name = if (app != null and !app.?.available) try std.fmt.allocPrintSentinel(a, "{s} — launcher unavailable", .{app.?.id}, 0) else try a.dupeZ(u8, if (app) |v| v.name else identity orelse "Application") });
            }
            const ws = if (win.workspace) |id| model.get(.workspace, id) else null;
            const output = if (win.output) |id| model.get(.output, id) else null;
            try groups.items[slot.value_ptr.*].windows.append(a, .{ .id = try a.dupeZ(u8, win.id), .title = try a.dupeZ(u8, nonempty(win.title) orelse identity orelse "Application"), .workspace = if (ws) |v| try a.dupeZ(u8, v.name) else null, .output = if (output) |v| try a.dupeZ(u8, v.name) else null, .focused = win.focused, .minimized = win.minimized, .can_activate = win.can_activate });
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
/// Order key: output scope, workspace scope, index present before null, index
/// value, window id. Indexes from different scopes are not comparable, so the
/// scope keys come first and unresolved scopes sort last.
fn layoutOrderLess(model: *const Model, x: *const entities.Window, y: *const entities.Window) bool {
    const xo = if (x.output) |id| model.get(.output, id) else null;
    const yo = if (y.output) |id| model.get(.output, id) else null;
    if ((xo == null) != (yo == null)) return yo == null;
    if (xo) |xv| if (yo) |yv| {
        if (xv.bounds.x != yv.bounds.x) return xv.bounds.x < yv.bounds.x;
        if (xv.bounds.y != yv.bounds.y) return xv.bounds.y < yv.bounds.y;
        const name = std.mem.order(u8, xv.name, yv.name);
        if (name != .eq) return name == .lt;
        const id = std.mem.order(u8, xv.id, yv.id);
        if (id != .eq) return id == .lt;
    };
    const xw = if (x.workspace) |id| model.get(.workspace, id) else null;
    const yw = if (y.workspace) |id| model.get(.workspace, id) else null;
    if ((xw == null) != (yw == null)) return yw == null;
    if (xw) |xv| if (yw) |yv| {
        if (xv.number != yv.number) return xv.number < yv.number;
        const id = std.mem.order(u8, xv.id, yv.id);
        if (id != .eq) return id == .lt;
    };
    if ((x.layout_index == null) != (y.layout_index == null)) return y.layout_index == null;
    if (x.layout_index) |xv| if (y.layout_index) |yv| if (xv != yv) return xv < yv;
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

test "explicit launcher overrides identity and missing selections never fall back" {
    const t = std.testing;
    const apps = [_]Application{ .{ .id = "App.desktop", .name = "Packaged" }, .{ .id = "Custom.desktop", .name = "Custom" } };
    const choices = [_]identity_policy.Association{.{ .backend = .xdg, .identity = "App", .desktop_id = "Custom.desktop" }};
    const win = fixtureWindow("window", "App");
    try t.expectEqualStrings("Custom.desktop", resolve(&apps, win, &choices).?.id);
    const missing = resolve(apps[0..1], win, &choices).?;
    try t.expectEqualStrings("Custom.desktop", missing.id);
    try t.expect(!missing.available);
    try t.expectEqualStrings("App.desktop", resolve(&apps, win, &.{}).?.id);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var model = try Model.init(t.allocator, (@import("../aqueous/codec.zig").Limits{}).state_bytes);
    defer model.deinit();
    // Reuse the same model sequence while only the association changes.
    model.ready = true;
    try model.entities.put(model.arena.allocator(), .{ .kind = .window, .id = win.id }, .{ .window = win });
    var snapshot = Snapshot.init(arena.allocator());
    defer snapshot.deinit();
    try snapshot.updateWithLaunchers(&model, &apps, 1, &.{});
    try t.expect(snapshot.find("desktop:App.desktop") != null);
    const before = snapshot.revision;
    try snapshot.updateWithLaunchers(&model, &apps, 1, &choices);
    try t.expect(snapshot.revision > before);
    try t.expect(snapshot.find("desktop:Custom.desktop") != null);
}

const order_token = "0123456789abcdef0123456789abcdef";

fn fixtureOutput(id: []const u8, name: []const u8, x: i64) entities.Output {
    return .{ .id = id, .name = name, .bounds = .{ .x = x, .y = 0, .width = 1920, .height = 1080 }, .usable_bounds = .{ .x = x, .y = 0, .width = 1920, .height = 1080 }, .scale = 1, .transform = "normal", .active_workspace = null, .enabled = true, .powered = true };
}
fn fixtureWorkspace(id: []const u8, output: []const u8, number: u32) entities.Workspace {
    return .{ .id = id, .output = output, .name = id, .number = number, .active = false, .urgent = false };
}
fn scopedWindow(id: []const u8, app: ?[]const u8, output: ?[]const u8, workspace: ?[]const u8, index: ?u32) entities.Window {
    var win = fixtureWindow(id, app);
    win.output = output;
    win.workspace = workspace;
    win.layout_index = index;
    return win;
}
fn orderModel(allocator: Allocator, upsert: []const entities.Entity) !Model {
    var model = try Model.init(allocator, (@import("../aqueous/codec.zig").Limits{}).state_bytes);
    errdefer model.deinit();
    var values: std.ArrayList(entities.Entity) = .empty;
    defer values.deinit(allocator);
    try values.append(allocator, .{ .session = .{ .id = "session", .locked = false, .default_seat = null, .overview_output = null, .overview_window = null } });
    try values.appendSlice(allocator, upsert);
    try model.apply(.{ .type = .snapshot, .session = order_token, .sequence = "1", .base_sequence = null, .upsert = values.items, .removed = &.{} });
    return model;
}
fn orderDelta(model: *Model, sequence: []const u8, upsert: []const entities.Entity, removed: []const entities.Key) !void {
    try model.apply(.{ .type = .delta, .session = order_token, .sequence = sequence, .base_sequence = model.sequence, .upsert = upsert, .removed = removed });
}
fn expectKeys(t: anytype, snapshot: Snapshot, expected: []const []const u8) !void {
    try t.expectEqual(expected.len, snapshot.groups.len);
    for (expected, 0..) |key, i| try t.expectEqualStrings(key, snapshot.groups[i].key);
}

test "swapped layout indexes across applications swap group order" {
    const t = std.testing;
    var model = try orderModel(t.allocator, &.{
        .{ .output = fixtureOutput("o1", "HEADLESS-1", 0) },
        .{ .workspace = fixtureWorkspace("w1", "o1", 1) },
        .{ .window = scopedWindow("win-a", "Alpha", "o1", "w1", 1) },
        .{ .window = scopedWindow("win-b", "Beta", "o1", "w1", 0) },
    });
    defer model.deinit();
    var snapshot = Snapshot.init(t.allocator);
    defer snapshot.deinit();
    try snapshot.update(&model, &.{}, 0);
    try expectKeys(t, snapshot, &.{ "app:Beta", "app:Alpha" });
    const revision = snapshot.revision;
    try orderDelta(&model, "2", &.{
        .{ .window = scopedWindow("win-a", "Alpha", "o1", "w1", 0) },
        .{ .window = scopedWindow("win-b", "Beta", "o1", "w1", 1) },
    }, &.{});
    try snapshot.update(&model, &.{}, 0);
    try expectKeys(t, snapshot, &.{ "app:Alpha", "app:Beta" });
    try t.expect(snapshot.revision > revision);
}

test "swapped layout indexes within one application swap window order" {
    const t = std.testing;
    var model = try orderModel(t.allocator, &.{
        .{ .output = fixtureOutput("o1", "HEADLESS-1", 0) },
        .{ .workspace = fixtureWorkspace("w1", "o1", 1) },
        .{ .window = scopedWindow("win-a", "Alpha", "o1", "w1", 1) },
        .{ .window = scopedWindow("win-b", "Alpha", "o1", "w1", 0) },
    });
    defer model.deinit();
    var snapshot = Snapshot.init(t.allocator);
    defer snapshot.deinit();
    try snapshot.update(&model, &.{}, 0);
    try expectKeys(t, snapshot, &.{"app:Alpha"});
    try t.expectEqualStrings("win-b", snapshot.groups[0].windows.items[0].id);
    try t.expectEqualStrings("win-a", snapshot.groups[0].windows.items[1].id);
    const revision = snapshot.revision;
    try orderDelta(&model, "2", &.{
        .{ .window = scopedWindow("win-a", "Alpha", "o1", "w1", 0) },
        .{ .window = scopedWindow("win-b", "Alpha", "o1", "w1", 1) },
    }, &.{});
    try snapshot.update(&model, &.{}, 0);
    try t.expectEqual(@as(usize, 1), snapshot.groups.len);
    try t.expectEqualStrings("win-a", snapshot.groups[0].windows.items[0].id);
    try t.expectEqualStrings("win-b", snapshot.groups[0].windows.items[1].id);
    try t.expect(snapshot.revision > revision);
}

test "an order-only delta bumps revision with focus, counts and state unchanged" {
    const t = std.testing;
    var focused_a = scopedWindow("win-a", "Alpha", "o1", "w1", 1);
    focused_a.focused = true;
    var model = try orderModel(t.allocator, &.{
        .{ .output = fixtureOutput("o1", "HEADLESS-1", 0) },
        .{ .workspace = fixtureWorkspace("w1", "o1", 1) },
        .{ .window = focused_a },
        .{ .window = scopedWindow("win-b", "Beta", "o1", "w1", 0) },
    });
    defer model.deinit();
    var snapshot = Snapshot.init(t.allocator);
    defer snapshot.deinit();
    try snapshot.update(&model, &.{}, 0);
    const revision = snapshot.revision;
    try t.expect(snapshot.find("app:Alpha").?.focused());
    try orderDelta(&model, "2", &.{
        .{ .window = focused_a },
        .{ .window = scopedWindow("win-b", "Beta", "o1", "w1", 1) },
    }, &.{});
    var bumped = scopedWindow("win-a", "Alpha", "o1", "w1", 0);
    bumped.focused = true;
    try model.apply(.{ .type = .delta, .session = order_token, .sequence = "3", .base_sequence = "2", .upsert = &.{.{ .window = bumped }}, .removed = &.{} });
    try snapshot.update(&model, &.{}, 0);
    try expectKeys(t, snapshot, &.{ "app:Alpha", "app:Beta" });
    try t.expectEqual(@as(usize, 1), snapshot.find("app:Alpha").?.windows.items.len);
    try t.expectEqual(@as(usize, 1), snapshot.find("app:Beta").?.windows.items.len);
    try t.expect(snapshot.find("app:Alpha").?.focused());
    try t.expect(!snapshot.find("app:Beta").?.focused());
    try t.expect(snapshot.revision > revision);
}

test "equal layout indexes fall back to scope keys then window id" {
    const t = std.testing;
    var model = try orderModel(t.allocator, &.{
        .{ .output = fixtureOutput("o1", "HEADLESS-1", 0) },
        .{ .output = fixtureOutput("o2", "HEADLESS-2", 1920) },
        .{ .workspace = fixtureWorkspace("w1", "o1", 1) },
        .{ .workspace = fixtureWorkspace("w2", "o1", 2) },
        .{ .workspace = fixtureWorkspace("w3", "o2", 1) },
        .{ .window = scopedWindow("b", null, "o2", "w3", 0) },
        .{ .window = scopedWindow("d", null, "o1", "w2", 0) },
        .{ .window = scopedWindow("m2", null, "o1", "w1", 0) },
        .{ .window = scopedWindow("m1", null, "o1", "w1", 0) },
    });
    defer model.deinit();
    var snapshot = Snapshot.init(t.allocator);
    defer snapshot.deinit();
    try snapshot.update(&model, &.{}, 0);
    try expectKeys(t, snapshot, &.{ "window:m1", "window:m2", "window:d", "window:b" });
}

test "windows without any layout index keep the previous-rank group order" {
    const t = std.testing;
    var model = try orderModel(t.allocator, &.{
        .{ .window = fixtureWindow("z1", "Zed") },
        .{ .window = fixtureWindow("a1", "Alpha") },
    });
    defer model.deinit();
    var snapshot = Snapshot.init(t.allocator);
    defer snapshot.deinit();
    try snapshot.update(&model, &.{}, 0);
    try expectKeys(t, snapshot, &.{ "app:Alpha", "app:Zed" });
    try orderDelta(&model, "2", &.{.{ .window = fixtureWindow("m1", "Middle") }}, &.{});
    try snapshot.update(&model, &.{}, 0);
    // Previous rank outranks the name comparator: a name sort would put Middle before Zed.
    try expectKeys(t, snapshot, &.{ "app:Alpha", "app:Zed", "app:Middle" });
}

test "added and removed windows rebuild the layout order without stale entries" {
    const t = std.testing;
    var model = try orderModel(t.allocator, &.{
        .{ .output = fixtureOutput("o1", "HEADLESS-1", 0) },
        .{ .workspace = fixtureWorkspace("w1", "o1", 1) },
        .{ .window = scopedWindow("win-a", "Alpha", "o1", "w1", 1) },
        .{ .window = scopedWindow("win-b", "Beta", "o1", "w1", 0) },
    });
    defer model.deinit();
    var snapshot = Snapshot.init(t.allocator);
    defer snapshot.deinit();
    try snapshot.update(&model, &.{}, 0);
    const revision = snapshot.revision;
    try orderDelta(&model, "2", &.{
        .{ .window = scopedWindow("win-c", "Gamma", "o1", "w1", 0) },
        .{ .window = scopedWindow("win-a", "Alpha", "o1", "w1", 1) },
    }, &.{.{ .kind = .window, .id = "win-b" }});
    try snapshot.update(&model, &.{}, 0);
    try expectKeys(t, snapshot, &.{ "app:Gamma", "app:Alpha" });
    try t.expect(snapshot.find("app:Beta") == null);
    try t.expectEqual(@as(usize, 1), snapshot.find("app:Alpha").?.windows.items.len);
    try t.expect(snapshot.revision > revision);
}

test "layout order follows scope keys across outputs and workspaces with null scopes last" {
    const t = std.testing;
    var model = try orderModel(t.allocator, &.{
        .{ .output = fixtureOutput("o1", "HEADLESS-1", 0) },
        .{ .output = fixtureOutput("o2", "HEADLESS-2", 1920) },
        .{ .workspace = fixtureWorkspace("w1", "o1", 1) },
        .{ .workspace = fixtureWorkspace("w2", "o1", 2) },
        .{ .workspace = fixtureWorkspace("w3", "o2", 1) },
        .{ .window = scopedWindow("n", null, null, null, 0) },
        .{ .window = scopedWindow("s", null, "o2", "w3", 0) },
        .{ .window = scopedWindow("d", null, "o1", "w2", 0) },
        .{ .window = scopedWindow("c", null, "o1", "w1", 1) },
        .{ .window = scopedWindow("b", null, "o1", "w1", 0) },
    });
    defer model.deinit();
    var snapshot = Snapshot.init(t.allocator);
    defer snapshot.deinit();
    try snapshot.update(&model, &.{}, 0);
    try expectKeys(t, snapshot, &.{ "window:b", "window:c", "window:d", "window:s", "window:n" });
}

test "unindexed special-state windows keep identity and sort after indexed ones" {
    const t = std.testing;
    var minimized = scopedWindow("m1", "Alpha", "o1", "w1", null);
    minimized.minimized = true;
    var floating = scopedWindow("f1", "Alpha", "o1", "w1", null);
    floating.floating = true;
    var inert = scopedWindow("x1", "Alpha", "o1", "w1", null);
    inert.can_activate = false;
    var model = try orderModel(t.allocator, &.{
        .{ .output = fixtureOutput("o1", "HEADLESS-1", 0) },
        .{ .workspace = fixtureWorkspace("w1", "o1", 1) },
        .{ .window = scopedWindow("i1", "Alpha", "o1", "w1", 0) },
        .{ .window = minimized },
        .{ .window = floating },
        .{ .window = inert },
    });
    defer model.deinit();
    var snapshot = Snapshot.init(t.allocator);
    defer snapshot.deinit();
    try snapshot.update(&model, &.{}, 0);
    try expectKeys(t, snapshot, &.{"app:Alpha"});
    const windows = snapshot.groups[0].windows.items;
    try t.expectEqual(@as(usize, 4), windows.len);
    try t.expectEqualStrings("i1", windows[0].id);
    try t.expectEqualStrings("f1", windows[1].id);
    try t.expectEqualStrings("m1", windows[2].id);
    try t.expectEqualStrings("x1", windows[3].id);
    try t.expect(windows[2].minimized and !windows[0].minimized);
    try t.expect(!windows[3].can_activate and windows[0].can_activate);
}
