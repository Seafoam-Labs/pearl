//! Once-per-session autostart launch claim. The shell launches XDG autostart
//! entries itself; a shell restarted within the same login session (systemd
//! Restart=on-failure) must not launch them again. The claim is a marker keyed
//! to the compositor session token under XDG_RUNTIME_DIR (tmpfs, cleared on
//! logout), created atomically with O_EXCL so only the first shell instance
//! wins. Pure std, so it is unit-testable without GTK or a compositor.
const std = @import("std");

/// Returns true when this caller created the marker and should launch; false
/// when a previous instance already claimed the session. Unavailable marker
/// storage fails open (true) so autostart is never worse than without the
/// guard; only a confirmed existing marker suppresses the launch.
pub fn claim(runtime: []const u8, session: []const u8) bool {
    if (runtime.len == 0 or runtime.len > 4096) return true;
    var dir_buffer: [4096 + 8]u8 = undefined;
    const dir = std.mem.printSentinel(&dir_buffer, "{s}/pearl", .{runtime}, 0) catch return true;
    _ = std.c.mkdir(dir, 0o700);
    var path_buffer: [4096 + 128]u8 = undefined;
    const path = std.mem.printSentinel(&path_buffer, "{s}/pearl/autostart-{s}.lock", .{ runtime, session }, 0) catch return true;
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o600));
    if (fd >= 0) {
        _ = std.c.close(fd);
        return true;
    }
    return std.c.errno(fd) != .EXIST;
}

test "claim launches once per session and again for a new session" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [512]u8 = undefined;
    const runtime = try std.mem.printSentinel(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    const session_a: []const u8 = "0123456789abcdef0123456789abcdef";
    const session_b: []const u8 = "fedcba9876543210fedcba9876543210";
    try t.expect(claim(runtime, session_a));
    try t.expect(!claim(runtime, session_a));
    try t.expect(claim(runtime, session_b));
    try t.expect(!claim(runtime, session_b));
}

test "claim fails open when marker storage is unusable" {
    const session: []const u8 = "0123456789abcdef0123456789abcdef";
    try std.testing.expect(claim("", session));
    try std.testing.expect(claim("/nonexistent-pearl-autostart-runtime/nope", session));
}
