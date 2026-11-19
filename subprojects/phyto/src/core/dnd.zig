const std = @import("std");

/// What a file drop should do. `ask` opens the copy/move/link choice dialog.
pub const Action = enum { none, copy, move, link, ask };

/// The actions the drag source and drop target both support.
pub const Offer = struct {
    copy: bool = false,
    move: bool = false,
    link: bool = false,
    ask: bool = false,
};

pub const Mods = struct { control: bool = false, shift: bool = false };

/// Ctrl forces copy, Shift forces move, Ctrl+Shift asks when the source offers
/// it. Without modifiers, moving within one filesystem is the default; crossing
/// filesystems copies so the original survives an interrupted transfer.
pub fn pickAction(offer: Offer, mods: Mods, same_filesystem: bool) Action {
    if (mods.control and mods.shift and offer.ask) return .ask;
    if (mods.control and offer.copy) return .copy;
    if (mods.shift and offer.move) return .move;
    if (offer.move and same_filesystem) return .move;
    if (offer.copy) return .copy;
    if (offer.move) return .move;
    if (offer.link) return .link;
    return .none;
}

test "pickAction modifiers override the filesystem default" {
    const both = Offer{ .copy = true, .move = true, .ask = true };
    try std.testing.expectEqual(Action.move, pickAction(both, .{}, true));
    try std.testing.expectEqual(Action.copy, pickAction(both, .{}, false));
    try std.testing.expectEqual(Action.copy, pickAction(both, .{ .control = true }, true));
    try std.testing.expectEqual(Action.move, pickAction(both, .{ .shift = true }, false));
    try std.testing.expectEqual(Action.ask, pickAction(both, .{ .control = true, .shift = true }, true));
}

test "pickAction only asks when the source offers it" {
    const external = Offer{ .copy = true, .move = true };
    try std.testing.expectEqual(Action.copy, pickAction(external, .{ .control = true, .shift = true }, true));
}

test "pickAction falls back through the available actions" {
    try std.testing.expectEqual(Action.move, pickAction(.{ .move = true }, .{}, false));
    try std.testing.expectEqual(Action.copy, pickAction(.{ .copy = true }, .{ .shift = true }, true));
    try std.testing.expectEqual(Action.link, pickAction(.{ .link = true }, .{}, true));
    try std.testing.expectEqual(Action.none, pickAction(.{}, .{}, true));
}
