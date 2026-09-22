//! Saved slideshow policy and image ordering; no GTK, filesystem or clock dependencies.
const std = @import("std");

pub const Order = enum { sequential, random };
/// Concrete animations the wallpaper stack can play.
pub const Animation = enum { fade, slide, rotate, cover };
pub const Transition = enum { none, fade, slide, rotate, cover, random };

/// Resolves a transition to the animation for one change; `null` means cut.
/// `.random` re-rolls per change so consecutive slides can differ.
pub fn animation(transition: Transition, seed: u64) ?Animation {
    return switch (transition) {
        .none => null,
        .fade => .fade,
        .slide => .slide,
        .rotate => .rotate,
        .cover => .cover,
        .random => @enumFromInt(seed % @typeInfo(Animation).@"enum".fields.len),
    };
}

pub const Config = struct {
    enabled: bool = false,
    folder: []const u8 = "",
    interval_seconds: u32 = 900,
    order: Order = .sequential,
    transition: Transition = .fade,
    /// Length of one wallpaper animation, in milliseconds.
    transition_ms: u32 = 420,
    pub fn validate(self: Config) !void {
        if (self.interval_seconds < 10 or self.interval_seconds > 86400) return error.InvalidSlideshowInterval;
        if (self.transition_ms < 100 or self.transition_ms > 5000) return error.InvalidSlideshowTransition;
        if (self.enabled and self.folder.len == 0) return error.SlideshowFolderRequired;
    }
};

/// The wallpaper pipeline rejects anything that is not PNG or JPEG by magic
/// bytes, so the listing must not offer other extensions.
pub fn eligible(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return false;
    for ([_][]const u8{ ".png", ".jpg", ".jpeg" }) |extension| {
        if (name.len <= extension.len) continue;
        const suffix = name[name.len - extension.len ..];
        const matched = matched: {
            for (suffix, extension) |ch, expected| if (std.ascii.toLower(ch) != expected) break :matched false;
            break :matched true;
        };
        if (matched) return true;
    }
    return false;
}

/// Index of the image following `current`. `names` holds sorted, eligible
/// basenames; an unknown `current` restarts from the first entry.
pub fn next(names: []const []const u8, current: []const u8, order: Order, seed: u64) usize {
    if (names.len < 2) return 0;
    const at = for (names, 0..) |name, i| {
        if (std.mem.eql(u8, name, current)) break i;
    } else return 0;
    return switch (order) {
        .sequential => (at + 1) % names.len,
        .random => blk: {
            var prng = std.Random.DefaultPrng.init(seed);
            // Excludes the current entry so consecutive slides always differ.
            const pick = prng.random().intRangeLessThan(usize, 0, names.len - 1);
            break :blk if (pick < at) pick else pick + 1;
        },
    };
}

test "slideshow defaults validate and reject bad intervals or missing folders" {
    try (Config{}).validate();
    try std.testing.expect(!(Config{}).enabled);
    try std.testing.expectEqual(@as(u32, 900), (Config{}).interval_seconds);
    try std.testing.expectEqual(@as(u32, 420), (Config{}).transition_ms);
    try std.testing.expectError(error.InvalidSlideshowInterval, (Config{ .interval_seconds = 9 }).validate());
    try std.testing.expectError(error.InvalidSlideshowInterval, (Config{ .interval_seconds = 86401 }).validate());
    try std.testing.expectError(error.InvalidSlideshowTransition, (Config{ .transition_ms = 99 }).validate());
    try std.testing.expectError(error.InvalidSlideshowTransition, (Config{ .transition_ms = 5001 }).validate());
    try std.testing.expectError(error.SlideshowFolderRequired, (Config{ .enabled = true }).validate());
    try (Config{ .enabled = true, .folder = "/pictures" }).validate();
}

test "eligible accepts only the decodable image extensions" {
    for ([_][]const u8{ "a.png", "a.PNG", "a.jpg", "a.jpeg", "a.JPEG", "holiday photo.jpeg" }) |name| {
        try std.testing.expect(eligible(name));
    }
    for ([_][]const u8{ "a.webp", "a.gif", "a.svg", "a.txt", ".hidden.png", ".png", "", "png" }) |name| {
        try std.testing.expect(!eligible(name));
    }
}

test "transitions resolve to one animation and random covers them all" {
    try std.testing.expect(animation(.none, 3) == null);
    try std.testing.expectEqual(Animation.fade, animation(.fade, 3).?);
    try std.testing.expectEqual(Animation.slide, animation(.slide, 3).?);
    try std.testing.expectEqual(Animation.rotate, animation(.rotate, 3).?);
    try std.testing.expectEqual(Animation.cover, animation(.cover, 3).?);
    var seen = [_]usize{ 0, 0, 0, 0 };
    for (0..64) |seed| seen[@intFromEnum(animation(.random, seed).?)] += 1;
    for (seen) |count| try std.testing.expect(count > 0);
}

test "sequential rotation advances and wraps" {
    const names = [_][]const u8{ "a.png", "b.png", "c.png" };
    try std.testing.expectEqual(@as(usize, 1), next(&names, "a.png", .sequential, 0));
    try std.testing.expectEqual(@as(usize, 2), next(&names, "b.png", .sequential, 0));
    try std.testing.expectEqual(@as(usize, 0), next(&names, "c.png", .sequential, 0));
    // An image deleted out from under the rotation restarts rather than stalling.
    try std.testing.expectEqual(@as(usize, 0), next(&names, "gone.png", .sequential, 0));
}

test "rotation is inert for zero and one image" {
    const none = [_][]const u8{};
    try std.testing.expectEqual(@as(usize, 0), next(&none, "a.png", .sequential, 0));
    const one = [_][]const u8{"a.png"};
    try std.testing.expectEqual(@as(usize, 0), next(&one, "a.png", .sequential, 0));
    try std.testing.expectEqual(@as(usize, 0), next(&one, "a.png", .random, 7));
}

test "random rotation never repeats the current image" {
    const names = [_][]const u8{ "a.png", "b.png", "c.png", "d.png" };
    var seen = [_]usize{ 0, 0, 0, 0 };
    for (0..64) |seed| {
        const index = next(&names, "b.png", .random, seed);
        try std.testing.expect(index != 1);
        try std.testing.expect(index < names.len);
        seen[index] += 1;
    }
    // Every other entry must be reachable across the seed range.
    try std.testing.expect(seen[0] > 0 and seen[2] > 0 and seen[3] > 0);
}
