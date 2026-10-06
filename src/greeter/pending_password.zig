//! One-use, volatile response for an administrator-declared password-first PAM stack.
//! This object never authorizes authentication; Client.answer validates the live prompt.
const std = @import("std");
const p = @import("protocol.zig");
const Controller = @import("controller.zig").Controller;

pub const Selection = struct {
    username: []const u8,
    desktop: []const u8,
    fingerprint: [64]u8,
    job: u64,
};

pub const Pending = struct {
    bytes: [4096]u8 = @splat(0),
    len: usize = 0,
    username: [256]u8 = @splat(0),
    username_len: usize = 0,
    desktop: [256]u8 = @splat(0),
    desktop_len: usize = 0,
    fingerprint: [64]u8 = @splat(0),
    job: u64 = 0,
    attempt: u64 = 0,
    connection: u64 = 0,
    phase: enum { empty, prepared, bound } = .empty,

    pub fn clear(self: *Pending) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.len = 0;
        self.username = @splat(0);
        self.username_len = 0;
        self.desktop = @splat(0);
        self.desktop_len = 0;
        self.fingerprint = @splat(0);
        self.job = 0;
        self.attempt = 0;
        self.connection = 0;
        self.phase = .empty;
    }

    pub fn capture(self: *Pending, selection: Selection, response: []const u8) !void {
        self.clear();
        if (!p.validText(response, self.bytes.len)) return error.InvalidResponse;
        if (selection.username.len == 0 or !p.validText(selection.username, 256) or selection.desktop.len == 0 or !p.validText(selection.desktop, 256)) return error.InvalidSelection;
        // Empty input starts authentication without guessing an empty PAM response.
        if (response.len == 0) return;
        @memcpy(self.bytes[0..response.len], response);
        self.len = response.len;
        @memcpy(self.username[0..selection.username.len], selection.username);
        self.username_len = selection.username.len;
        @memcpy(self.desktop[0..selection.desktop.len], selection.desktop);
        self.desktop_len = selection.desktop.len;
        self.fingerprint = selection.fingerprint;
        self.job = selection.job;
        self.phase = .prepared;
    }

    pub fn matches(self: *const Pending, selection: Selection) bool {
        return self.phase != .empty and self.job == selection.job and
            std.mem.eql(u8, self.username[0..self.username_len], selection.username) and
            std.mem.eql(u8, self.desktop[0..self.desktop_len], selection.desktop) and
            std.mem.eql(u8, &self.fingerprint, &selection.fingerprint);
    }

    pub fn bind(self: *Pending, c: *const Controller, selection: Selection) void {
        if (self.phase == .empty) return;
        if (self.phase != .prepared or c.state != .connecting or !self.matches(selection)) {
            self.clear();
            return;
        }
        self.attempt = c.attempt;
        self.connection = c.connection;
        self.phase = .bound;
    }

    /// Move into caller-owned scratch storage and wipe before any reentrant callback.
    /// Caller must wipe scratch even if sending fails. Only the first input can consume.
    pub fn take(self: *Pending, c: *const Controller, selection: Selection, scratch: *[4096]u8) ?[]const u8 {
        if (self.phase == .empty) return null;
        if (self.phase != .bound or !self.matches(selection) or c.attempt != self.attempt or c.connection != self.connection) {
            self.clear();
            return null;
        }
        if (!c.needsInput()) return null;
        defer self.clear();
        if (c.kind != .secret or c.pending != null) return null;
        const len = self.len;
        @memcpy(scratch[0..len], self.bytes[0..len]);
        return scratch[0..len];
    }
};

const fixture: Selection = .{ .username = "fixture-user", .desktop = "wayland:fixture.desktop", .fingerprint = @splat('a'), .job = 7 };

fn bound(pending: *Pending, c: *Controller) !void {
    try pending.capture(fixture, "fixture-secret");
    try c.begin();
    pending.bind(c, fixture);
    try c.connected();
}

fn expectWiped(pending: *const Pending) !void {
    try std.testing.expectEqual(.empty, pending.phase);
    try std.testing.expectEqual(@as(usize, 0), pending.len);
    for (pending.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "passive instructions retain a password for exactly one secret question" {
    var pending: Pending = .{};
    var c: Controller = .{};
    var scratch: [4096]u8 = @splat(0);
    defer std.crypto.secureZero(u8, &scratch);
    try bound(&pending, &c);
    for ([_]p.Prompt{ .info, .@"error", .info }) |kind| {
        try c.receive(c.connection, .{ .kind = .auth_message, .prompt = kind });
        try std.testing.expect(pending.take(&c, fixture, &scratch) == null);
        try c.acknowledge(c.passiveToken().?);
    }
    try c.receive(c.connection, .{ .kind = .auth_message, .prompt = .secret });
    try std.testing.expectEqualStrings("fixture-secret", pending.take(&c, fixture, &scratch).?);
    try expectWiped(&pending);
    try std.testing.expect(pending.take(&c, fixture, &scratch) == null);
    try c.answer(c.prompt_generation, false);
    try c.receive(c.connection, .{ .kind = .auth_message, .prompt = .secret });
    try std.testing.expect(pending.take(&c, fixture, &scratch) == null);
}

test "visible question wipes queued input before a later secret question" {
    var pending: Pending = .{};
    var c: Controller = .{};
    var scratch: [4096]u8 = @splat(0);
    try bound(&pending, &c);
    try c.receive(c.connection, .{ .kind = .auth_message, .prompt = .visible });
    try std.testing.expect(pending.take(&c, fixture, &scratch) == null);
    try expectWiped(&pending);
    try c.answer(c.prompt_generation, false);
    try c.receive(c.connection, .{ .kind = .auth_message, .prompt = .secret });
    try std.testing.expect(pending.take(&c, fixture, &scratch) == null);
}

test "user desktop fingerprint job attempt and connection changes reject pending input" {
    for (0..6) |field| {
        var pending: Pending = .{};
        var c: Controller = .{};
        var scratch: [4096]u8 = @splat(0);
        try bound(&pending, &c);
        try c.receive(c.connection, .{ .kind = .auth_message, .prompt = .secret });
        var changed = fixture;
        switch (field) {
            0 => changed.username = "another-user",
            1 => changed.desktop = "wayland:other.desktop",
            2 => changed.fingerprint[0] = 'b',
            3 => changed.job += 1,
            4 => c.attempt += 1,
            5 => c.connection += 1,
            else => unreachable,
        }
        try std.testing.expect(pending.take(&c, changed, &scratch) == null);
        try expectWiped(&pending);
    }
}

test "unbound or cancelled conversations cannot consume input" {
    var pending: Pending = .{};
    var c: Controller = .{};
    var scratch: [4096]u8 = @splat(0);
    try pending.capture(fixture, "fixture-secret");
    try std.testing.expect(pending.take(&c, fixture, &scratch) == null);
    try expectWiped(&pending);
    try bound(&pending, &c);
    try c.cancel();
    try std.testing.expect(pending.take(&c, fixture, &scratch) == null);
    try expectWiped(&pending);
}

test "empty invalid or oversized input cannot queue a truncated credential" {
    var pending: Pending = .{};
    try pending.capture(fixture, "");
    try expectWiped(&pending);
    for ([_][]const u8{ "bad\x00input", "\xff", &(@as([4097]u8, @splat('a'))) }) |invalid| {
        try pending.capture(fixture, "old-password");
        try std.testing.expectError(error.InvalidResponse, pending.capture(fixture, invalid));
        try expectWiped(&pending);
    }
    try pending.capture(fixture, &(@as([4096]u8, @splat('a'))));
    try std.testing.expectEqual(@as(usize, 4096), pending.len);
    pending.clear();
    try expectWiped(&pending);
}

test "explicit cleanup wipes unconsumed input including fingerprint-only success" {
    var pending: Pending = .{};
    var c: Controller = .{};
    try bound(&pending, &c);
    try c.receive(c.connection, .{ .kind = .success });
    pending.clear();
    try expectWiped(&pending);
}
