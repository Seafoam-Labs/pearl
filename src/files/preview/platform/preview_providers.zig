//! Fixed provider discovery; executed only in the display-independent helper.
const std = @import("std");
const glib = @import("glib2");
const runner = @import("preview_runner.zig");
const policy = @import("../core/preview.zig");
const a = std.heap.c_allocator;
pub const Snapshot = extern struct {
    magic: [4]u8 = "PHP1".*,
    pdf: u8 = @intFromEnum(policy.Status.sandbox),
    video: u8 = @intFromEnum(policy.Status.sandbox),
    reserved: [2]u8 = .{ 0, 0 },
    pdf_version: [32]u8 = @splat('0'),
    video_version: [32]u8 = @splat('0'),
};
pub fn tool(comptime name: []const u8) [:0]const u8 {
    if (@import("build_options").test_hooks) if (glib.getenv("PHYTO_TEST_PROVIDER_" ++ name)) |value| return std.mem.span(value);
    return "/usr/bin/" ++ name;
}
fn available(path: [:0]const u8) bool {
    return std.c.access(path, std.c.X_OK) == 0;
}
pub fn fingerprint(p: policy.Provider) [32]u8 {
    var hash = std.crypto.hash.Md5.init(.{});
    hash.update(if (p == .pdf) "poppler-pdf-v1:crop:first-page:1" else "ffmpeg-video-v1:10percent:SDR:1");
    const paths = if (p == .pdf) [_][:0]const u8{ tool("pdftoppm"), "/usr/bin/bwrap" } else [_][:0]const u8{ tool("ffmpeg"), tool("ffprobe") };
    for (paths) |path| {
        hash.update(path);
        var st: std.os.linux.Statx = std.mem.zeroes(std.os.linux.Statx);
        if (std.c.statx(std.os.linux.AT.FDCWD, path, 0, std.os.linux.STATX.BASIC_STATS, &st) == 0) {
            // Device, inode, size and nanosecond modification/creation identity.
            const values = [_]u64{ st.dev_major, st.dev_minor, st.ino, st.size, @bitCast(st.mtime.sec), st.mtime.nsec, @bitCast(st.ctime.sec), st.ctime.nsec };
            hash.update(std.mem.asBytes(&values));
        }
    }
    var digest: [16]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}
pub fn discover() Snapshot {
    var snapshot: Snapshot = .{ .pdf_version = fingerprint(.pdf), .video_version = fingerprint(.video) };
    const fd = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return snapshot;
    defer _ = std.c.close(fd);
    const sandbox = runner.run("/usr/bin/true", &.{}, fd, 1500, 1024);
    defer sandbox.deinit();
    if (sandbox.status != .ok) return snapshot;
    snapshot.pdf = @intFromEnum(policy.Status.missing_pdf);
    snapshot.video = @intFromEnum(policy.Status.missing_video);
    if (available(tool("pdftoppm"))) {
        const result = runner.run(tool("pdftoppm"), &.{"-h"}, fd, 1000, 16384);
        defer result.deinit();
        if (result.status == .ok) snapshot.pdf = @intFromEnum(policy.Status.ok);
    }
    if (available(tool("ffmpeg")) and available(tool("ffprobe"))) {
        const ffmpeg = runner.run(tool("ffmpeg"), &.{"-version"}, fd, 1000, 16384);
        defer ffmpeg.deinit();
        const ffprobe = runner.run(tool("ffprobe"), &.{"-version"}, fd, 1000, 16384);
        defer ffprobe.deinit();
        if (ffmpeg.status == .ok and ffprobe.status == .ok) snapshot.video = @intFromEnum(policy.Status.ok);
    }
    return snapshot;
}
pub fn emit() void {
    const snapshot = discover();
    const bytes = std.mem.asBytes(&snapshot);
    _ = std.c.write(1, bytes.ptr, bytes.len);
}
pub fn versionZ(p: policy.Provider) [:0]u8 {
    const version = fingerprint(p);
    return a.dupeZ(u8, &version) catch unreachable;
}
