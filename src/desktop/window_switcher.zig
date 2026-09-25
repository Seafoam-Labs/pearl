//! Negotiated global/workspace scope and eligibility shared by the bar and command controller.
const std = @import("std");
const Model = @import("../aqueous/reducer.zig").Model;
const Window = @import("../aqueous/entities.zig").Window;
const commands = @import("../aqueous/commands.zig");
pub const Direction = enum { next, previous, dismiss };
pub fn eligible(window: Window, output: []const u8, workspace: []const u8) bool {
    return (window.switcher_eligible orelse true) and window.can_activate and !window.skip_switcher and !window.minimized and
        std.mem.eql(u8, window.output orelse return false, output) and
        std.mem.eql(u8, window.workspace orelse return false, workspace);
}
pub fn globalEligible(model: *const Model, window: Window) bool {
    const output = model.get(.output, window.output orelse return false) orelse return false;
    const workspace = model.get(.workspace, window.workspace orelse return false) orelse return false;
    return output.enabled and output.powered and std.mem.eql(u8, workspace.output, output.id) and
        eligible(window, output.id, workspace.id);
}
pub fn count(model: *const Model, output: []const u8, all: bool) usize {
    const workspace = if (all) null else model.activeWorkspace(output) orelse return 0;
    var total: usize = 0;
    var it = model.entities.valueIterator();
    while (it.next()) |entity| if (entity.* == .window and (if (all) globalEligible(model, entity.window) else eligible(entity.window, output, workspace.?.id))) {
        total += 1;
    };
    return total;
}
pub fn action(model: *const Model, output: []const u8, direction: Direction, reduced_motion: bool, all: bool) !commands.Action {
    const workspace = if (all) null else model.activeWorkspace(output) orelse return error.Unavailable;
    const focus = try model.focus(null);
    const fields: commands.Switcher = .{ .output = output, .workspace = if (workspace) |ws| ws.id else null, .scope = if (all) .all else null, .seat = focus.seat.id, .reduced_motion = reduced_motion };
    return switch (direction) {
        .next => .{ .switcher_next = fields },
        .previous => .{ .switcher_previous = fields },
        .dismiss => .{ .switcher_dismiss = fields },
    };
}
test "switcher includes obscured and skip-taskbar windows but excludes minimized remote and skip-switcher" {
    var w = std.mem.zeroes(Window);
    w.output = "o";
    w.workspace = "w";
    w.can_activate = true;
    w.skip_taskbar = true;
    try std.testing.expect(eligible(w, "o", "w"));
    try std.testing.expect(!eligible(w, "other", "w"));
    try std.testing.expect(!eligible(w, "o", "other"));
    w.minimized = true;
    try std.testing.expect(!eligible(w, "o", "w"));
    w.minimized = false;
    w.skip_switcher = true;
    try std.testing.expect(!eligible(w, "o", "w"));
    w.skip_switcher = false;
    w.can_activate = false;
    try std.testing.expect(!eligible(w, "o", "w"));
}
