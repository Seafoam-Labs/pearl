//! Keep enabled Settings plugins attached to their chosen shell surface.
const std = @import("std");
const prefs = @import("../config/preferences.zig");
const model = @import("model.zig");

pub fn update(a: std.mem.Allocator, document: *prefs.Preferences, previous: model.Config, current: *model.Config, add_to_bar: bool) !void {
    if (add_to_bar) current.placement.mode = .bar;
    const entering_bar = current.enabled and current.placement.mode == .bar and (!previous.enabled or previous.placement.mode != .bar);
    if (!add_to_bar and !entering_bar) return;
    const reference = try std.fmt.allocPrint(a, "plugin:{s}/main", .{current.id});
    try append(a, &document.bar.groups, reference);
    // Output overrides replace the global bar groups, so they need a placement too.
    const outputs = try a.dupe(prefs.Output, document.outputs);
    for (outputs) |*output| try append(a, &output.bar.groups, reference);
    document.outputs = outputs;
}
fn append(a: std.mem.Allocator, groups: *prefs.Groups, reference: []const u8) !void {
    for ([_][]const u8{ groups.left, groups.center, groups.right }) |group| {
        var parts = std.mem.splitScalar(u8, group, ',');
        while (parts.next()) |part| if (std.mem.eql(u8, part, reference)) return;
    }
    groups.right = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ groups.right, if (groups.right.len > 0) "," else "", reference });
    try groups.validate();
}

test "enabling a bar plugin places it on global and per-output bars without moving existing widgets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var document: prefs.Preferences = .{ .outputs = &.{
        .{ .connector = "DP-1", .bar = .{ .groups = .{ .center = "plugin:pearl.companion/main" } } },
        .{ .connector = "DP-2", .bar = .{ .edge = .left } },
    } };
    const previous: model.Config = .{ .id = "pearl.companion" };
    var current = previous;
    current.enabled = true;
    try update(arena.allocator(), &document, previous, &current, false);
    try std.testing.expect(std.mem.endsWith(u8, document.bar.groups.right, ",plugin:pearl.companion/main"));
    try std.testing.expectEqualStrings("plugin:pearl.companion/main", document.outputs[0].bar.groups.center);
    try std.testing.expect(std.mem.indexOf(u8, document.outputs[0].bar.groups.right, "plugin:") == null);
    try std.testing.expect(std.mem.endsWith(u8, document.outputs[1].bar.groups.right, ",plugin:pearl.companion/main"));
    const right = document.bar.groups.right;
    try update(arena.allocator(), &document, current, &current, true);
    try std.testing.expectEqualStrings(right, document.bar.groups.right);
}

test "Add to bar leaves overlay mode and ordinary edits preserve manually removed placements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var document: prefs.Preferences = .{};
    var current: model.Config = .{ .id = "pearl.companion", .enabled = true, .placement = .{ .mode = .overlay }, .grants = .{ .overlay = true } };
    try update(arena.allocator(), &document, current, &current, false);
    try std.testing.expect(std.mem.indexOf(u8, document.bar.groups.right, "plugin:") == null);
    try update(arena.allocator(), &document, current, &current, true);
    try std.testing.expectEqual(.bar, current.placement.mode);
    try std.testing.expect(std.mem.endsWith(u8, document.bar.groups.right, ",plugin:pearl.companion/main"));
    document.bar.groups = .{};
    try update(arena.allocator(), &document, current, &current, false);
    try std.testing.expect(std.mem.indexOf(u8, document.bar.groups.right, "plugin:") == null);
}
