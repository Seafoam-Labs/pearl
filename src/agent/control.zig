//! Settings talks to the verified shell through its existing CLI protocol.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
pub fn command(a: std.mem.Allocator, operation: [:0]const u8, cancel: *gio.Cancellable) !@import("protocol.zig").ComputeStatus {
    var buffer: [4096]u8 = undefined;
    const own = try @import("../settings/distribution.zig").executable(&buffer);
    const exe = if (@import("build_options").test_hooks and glib.getenv("PEARL_TEST_CTL") != null) try a.dupeZ(u8, std.mem.span(glib.getenv("PEARL_TEST_CTL").?)) else try std.fmt.allocPrintSentinel(a, "{s}/pearlctl{s}", .{ std.fs.path.dirname(own).?, if (@import("../settings/distribution.zig").isGit(own)) "-git" else "" }, 0);
    const result = try @import("../config/helper_process.zig").run(a, &.{ exe, "assistant", operation }, null, cancel, 5000);
    const reply = try std.json.parseFromSliceLeaky(struct { ok: bool, result: ?struct { compute: @import("protocol.zig").ComputeStatus = .{}, handoff_pending: bool = false } = null }, a, result.stdout, .{ .ignore_unknown_fields = true });
    if (!reply.ok or !result.success) return error.AssistantControlUnavailable;
    var status = if (reply.result) |value| value.compute else @import("protocol.zig").ComputeStatus{};
    if (reply.result) |value| status.busy = status.busy or value.handoff_pending;
    return status;
}
