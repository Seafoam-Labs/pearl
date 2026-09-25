//! Explicit launcher choices use stable compositor identities, never window titles.
const std = @import("std");
const Window = @import("../aqueous/entities.zig").Window;
pub const Backend = @FieldType(Window, "backend");
pub const Key = struct {
    backend: Backend,
    identity: []const u8,
    pub fn eql(self: Key, other: Key) bool {
        return self.backend == other.backend and std.mem.eql(u8, self.identity, other.identity);
    }
};
pub const Association = struct {
    backend: Backend,
    identity: []const u8,
    desktop_id: []const u8,
    pub fn key(self: Association) Key {
        return .{ .backend = self.backend, .identity = self.identity };
    }
};
pub fn key(win: Window) ?Key {
    const value = (switch (win.backend) {
        .xdg => win.app_id,
        .xwayland => win.class,
    }) orelse return null;
    if (!validIdentity(value)) return null;
    return .{ .backend = win.backend, .identity = value };
}
fn validIdentity(value: []const u8) bool {
    if (value.len == 0 or value.len > 1024 or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |c| if (c < 32 or c == 127) return false;
    return true;
}
pub fn validate(choices: []const Association) !void {
    if (choices.len > 128) return error.TooManyApplicationLaunchers;
    for (choices, 0..) |choice, i| {
        if (!validIdentity(choice.identity)) return error.InvalidApplicationIdentity;
        if (!@import("dock_policy.zig").desktopId(choice.desktop_id)) return error.InvalidDesktopId;
        for (choices[0..i]) |previous| if (choice.key().eql(previous.key())) return error.DuplicateApplicationLauncher;
    }
}
pub fn lookup(choices: []const Association, identity: Key) ?[]const u8 {
    for (choices) |choice| if (choice.key().eql(identity)) return choice.desktop_id;
    return null;
}
pub fn selected(choices: []const Association, win: Window) ?[]const u8 {
    return lookup(choices, key(win) orelse return null);
}
pub fn digest(choices: []const Association) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (choices) |choice| {
        hash.update(@tagName(choice.backend));
        hash.update(&.{0});
        hash.update(choice.identity);
        hash.update(&.{0});
        hash.update(choice.desktop_id);
        hash.update(&.{0});
    }
    return hash.final();
}
pub fn pinDigest(pins: []const []const u8) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (pins) |id| {
        hash.update(id);
        hash.update(&.{0});
    }
    return hash.final();
}
/// Classify the effective GIO filename, not a second desktop-file scan.
pub fn userDesktopFile(alloc: std.mem.Allocator, filename: []const u8, data_home: []const u8) !bool {
    const root = try std.fs.path.resolve(alloc, &.{ data_home, "applications" });
    defer alloc.free(root);
    const path = try std.fs.path.resolve(alloc, &.{filename});
    defer alloc.free(path);
    return path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}
/// Returned strings borrow the input; serialize before its owning arena expires.
pub fn change(alloc: std.mem.Allocator, choices: []const Association, identity: Key, desktop: ?[]const u8) ![]const Association {
    var result: std.ArrayList(Association) = .empty;
    for (choices) |choice| if (!choice.key().eql(identity)) try result.append(alloc, choice);
    if (desktop) |id| try result.append(alloc, .{ .backend = identity.backend, .identity = identity.identity, .desktop_id = id });
    try validate(result.items);
    return result.toOwnedSlice(alloc);
}
pub fn replacePin(alloc: std.mem.Allocator, pins: []const []const u8, source: ?[]const u8, target: ?[]const u8) ![]const []const u8 {
    const old = source orelse return pins;
    const next = target orelse return pins;
    if (std.mem.eql(u8, old, next)) return pins;
    var target_present = false;
    for (pins) |id| if (std.mem.eql(u8, id, next)) {
        target_present = true;
        break;
    };
    var result: std.ArrayList([]const u8) = .empty;
    for (pins) |id| {
        if (std.mem.eql(u8, id, old)) {
            if (!target_present) try result.append(alloc, next);
        } else try result.append(alloc, id);
    }
    return result.toOwnedSlice(alloc);
}
test "launcher choices are exact, bounded and backend specific" {
    const t = std.testing;
    const choices = [_]Association{.{ .backend = .xdg, .identity = "org.test.App", .desktop_id = "Custom.desktop" }};
    try validate(&choices);
    var win = std.mem.zeroInit(Window, .{ .backend = .xdg, .app_id = "org.test.App", .class = "Other" });
    try t.expectEqualStrings("Custom.desktop", selected(&choices, win).?);
    win.backend = .xwayland;
    try t.expect(selected(&choices, win) == null);
    const xchoices = [_]Association{.{ .backend = .xwayland, .identity = "Other", .desktop_id = "Legacy.desktop" }};
    try t.expectEqualStrings("Legacy.desktop", selected(&xchoices, win).?);
    win.class = null;
    try t.expect(key(win) == null);
    win.backend = .xdg;
    win.app_id = "org.test.app";
    try t.expect(selected(&choices, win) == null);
    try t.expectError(error.DuplicateApplicationLauncher, validate(&.{ choices[0], choices[0] }));
    try t.expectError(error.InvalidApplicationIdentity, validate(&.{.{ .backend = .xdg, .identity = "bad\n", .desktop_id = "Custom.desktop" }}));
    try t.expectError(error.InvalidDesktopId, validate(&.{.{ .backend = .xdg, .identity = "App", .desktop_id = "/tmp/Custom.desktop" }}));
}
test "changing a launcher corrects pins without reordering an existing target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pins: []const []const u8 = &.{ "First.desktop", "System.desktop", "Last.desktop" };
    const replaced = try replacePin(a, pins, "System.desktop", "Custom.desktop");
    try std.testing.expectEqualStrings("Custom.desktop", replaced[1]);
    const deduped = try replacePin(a, pins, "System.desktop", "Last.desktop");
    try std.testing.expectEqual(@as(usize, 2), deduped.len);
    try std.testing.expectEqualStrings("Last.desktop", deduped[1]);
    try std.testing.expectEqual(@as(usize, 3), (try replacePin(a, pins, "System.desktop", null)).len);
    const identity: Key = .{ .backend = .xdg, .identity = "App" };
    const choices = try change(a, &.{}, identity, "Custom.desktop");
    try std.testing.expectEqualStrings("Custom.desktop", lookup(choices, identity).?);
    try std.testing.expectEqual(@as(usize, 0), (try change(a, choices, identity, null)).len);
}

test "user desktop classification respects XDG directory boundaries and normalization" {
    const t = std.testing;
    try t.expect(try userDesktopFile(t.allocator, "/custom/data/applications/Custom App.desktop", "/custom/data/"));
    try t.expect(try userDesktopFile(t.allocator, "/custom/data/applications/vendor/App.desktop", "/custom/other/../data"));
    try t.expect(!try userDesktopFile(t.allocator, "/custom/data/applications-other/App.desktop", "/custom/data"));
    try t.expect(!try userDesktopFile(t.allocator, "/custom/data/applications/../../system/App.desktop", "/custom/data"));
    try t.expect(!try userDesktopFile(t.allocator, "/usr/share/applications/App.desktop", "/custom/data"));
}
