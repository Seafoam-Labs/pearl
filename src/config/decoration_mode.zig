//! Single "Window decorations" selection mapped onto the two compositor
//! settings it controls: `decoration.renderer` (who draws) and
//! `layout.force_ssd` (which windows). The dropdown is a derived view — no
//! new config key exists; every combination of the two flags maps to exactly
//! one mode, so the control is always consistent with raw edits.
const std = @import("std");

pub const renderer_id = "decoration.renderer";
pub const force_ssd_id = "layout.force_ssd";

pub const Mode = enum {
    /// renderer=compositor, force_ssd=false — every app keeps its own CSD.
    off,
    /// renderer=compositor, force_ssd=true — built-in borders on all capable apps.
    borders,
    /// renderer=shell, force_ssd=false — Pearl titlebars on SSD-preferring apps.
    pearl,
    /// renderer=shell, force_ssd=true — Pearl titlebars on all capable apps.
    pearl_all,
};

pub fn derive(renderer_value: []const u8, force_ssd: bool) Mode {
    const shell = std.mem.eql(u8, renderer_value, "shell");
    return if (shell)
        (if (force_ssd) .pearl_all else .pearl)
    else
        (if (force_ssd) .borders else .off);
}

pub fn renderer(mode: Mode) []const u8 {
    return switch (mode) {
        .off, .borders => "compositor",
        .pearl, .pearl_all => "shell",
    };
}

pub fn forceSsd(mode: Mode) bool {
    return mode == .borders or mode == .pearl_all;
}

test "decoration modes round-trip every renderer/force combination" {
    const cases = [_]struct { renderer: []const u8, force: bool, mode: Mode }{
        .{ .renderer = "compositor", .force = false, .mode = .off },
        .{ .renderer = "compositor", .force = true, .mode = .borders },
        .{ .renderer = "shell", .force = false, .mode = .pearl },
        .{ .renderer = "shell", .force = true, .mode = .pearl_all },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.mode, derive(case.renderer, case.force));
        try std.testing.expectEqualStrings(case.renderer, renderer(case.mode));
        try std.testing.expectEqual(case.force, forceSsd(case.mode));
    }
    // Unknown renderer values degrade to the compositor side, never crash.
    try std.testing.expectEqual(Mode.off, derive("future-renderer", false));
    try std.testing.expectEqual(Mode.borders, derive("future-renderer", true));
}