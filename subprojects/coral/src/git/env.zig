//! Explicit environment/prefix policy for Git workflows.
//! Inspection uses the locked-down read-only policy in command.zig.
//! Repository writes and network operations intentionally use the user's Git
//! identity/helpers after a separate disclosure; they are not sandboxed.
const std = @import("std");
const process = @import("../tasks/process.zig");
const command = @import("command.zig");

pub const Environment = process.Environment;

pub const write_prefix: []const []const u8 = &.{
    "/usr/bin/git", "--no-pager",           "--no-optional-locks", "--literal-pathspecs",
    "-c",           "core.fsmonitor=false", "-c",                  "core.untrackedCache=false",
};

pub const network_prefix: []const []const u8 = &.{
    "/usr/bin/git", "--no-pager",           "--no-optional-locks", "--literal-pathspecs",
    "-c",           "core.fsmonitor=false", "-c",                  "core.untrackedCache=false",
};

fn getenv(name: []const u8) ?[]const u8 {
    var buf: [128:0]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const value = std.c.getenv(&buf) orelse return null;
    return std.mem.span(value);
}

fn base(a: std.mem.Allocator) !std.ArrayList(Environment) {
    var list: std.ArrayList(Environment) = .empty;
    errdefer list.deinit(a);
    const home = getenv("HOME") orelse return error.HomeUnavailable;
    try list.append(a, .{ .name = "PATH", .value = "/usr/bin:/bin" });
    try list.append(a, .{ .name = "HOME", .value = try a.dupe(u8, home) });
    const xdg = getenv("XDG_CONFIG_HOME");
    if (xdg) |value| {
        if (value.len != 0) try list.append(a, .{ .name = "XDG_CONFIG_HOME", .value = try a.dupe(u8, value) });
    }
    try list.append(a, .{ .name = "LC_ALL", .value = "C" });
    try list.append(a, .{ .name = "LANG", .value = "C" });
    try list.append(a, .{ .name = "TZ", .value = "UTC" });
    try list.append(a, .{ .name = "GIT_TERMINAL_PROMPT", .value = "0" });
    try list.append(a, .{ .name = "GIT_NO_REPLACE_OBJECTS", .value = "1" });
    return list;
}

/// Local repository writes: hooks/signing may execute configured programs.
pub fn write(a: std.mem.Allocator) ![]Environment {
    var list = try base(a);
    errdefer list.deinit(a);
    try list.append(a, .{ .name = "GIT_EDITOR", .value = "true" });
    for ([_][]const u8{ "GPG_TTY", "GNUPGHOME", "SSH_AUTH_SOCK" }) |name| {
        if (getenv(name)) |value| {
            if (value.len != 0) try list.append(a, .{ .name = try a.dupe(u8, name), .value = try a.dupe(u8, value) });
        }
    }
    return list.toOwnedSlice(a);
}

/// Network operations: credential/askpass helpers may execute and access secrets.
pub fn network(a: std.mem.Allocator) ![]Environment {
    var list = try base(a);
    errdefer list.deinit(a);
    for ([_][]const u8{ "SSH_AUTH_SOCK", "GPG_TTY", "GNUPGHOME", "GIT_ASKPASS", "SSH_ASKPASS", "DISPLAY", "WAYLAND_DISPLAY" }) |name| {
        if (getenv(name)) |value| {
            if (value.len != 0) try list.append(a, .{ .name = try a.dupe(u8, name), .value = try a.dupe(u8, value) });
        }
    }
    return list.toOwnedSlice(a);
}

test "write and network environments are explicit allowlists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try write(a);
    const n = try network(a);
    try std.testing.expect(w.len >= 8);
    try std.testing.expect(n.len >= w.len);
    for (w) |entry| try std.testing.expect(entry.name.len != 0);
    _ = command.prefix;
}
