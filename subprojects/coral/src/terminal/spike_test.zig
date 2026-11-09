//! Headless worker/authorization regression checks; renderer evidence is in
//! tests/terminal_spike.py, not established by these tests.
const std = @import("std");
const spike = @import("spike.zig");
const c = spike.c;

fn complete(job: *spike.Job) !void {
    const deadline = spike.transport.os.nowMs() + 3000;
    while (!job.done()) {
        if (spike.transport.os.nowMs() > deadline) return error.WorkerTimeout;
        c.g_usleep(1000);
    }
}
fn cleanup(job: *spike.Job) void {
    while (!job.ready()) c.g_usleep(1000);
    job.cancel();
    while (!job.done()) c.g_usleep(1000);
    _ = job.finish();
}
test "worker does not bypass denied authorization" {
    var job = spike.Job{ .config = .{ .argv = &.{"/bin/true"}, .cwd = "/" } };
    job.start();
    defer cleanup(&job);
    try complete(&job);
    try std.testing.expectEqual(error.Unauthorized, job.failure.?);
    try std.testing.expect(job.handle == null);
}
test "exec failure is published, reaped and finish is idempotent" {
    var job = spike.Job{ .config = .{
        .authorization = .approved,
        .argv = &.{"/no-such-coral-spike-executable"},
        .cwd = "/",
    } };
    job.start();
    defer cleanup(&job);
    try complete(&job);
    try std.testing.expect(job.failure == null);
    const report = job.finish().?;
    try std.testing.expect(report.spawn_errno != 0);
    // Existing transport reserves reaped=1 for successfully execed commands.
    try std.testing.expectEqual(@as(c_int, 0), report.reaped);
    job.cancel();
    try std.testing.expect(job.finish() == null);
}
