//! Test helper: resume only an existing workspace pause via the production API.
//! language_pause.py builds this against a verbatim disposable source snapshot;
//! it never writes store bytes directly or grants executable/workspace approval.
const std = @import("std");
const approvals = @import("src/language/approvals.zig");
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var home = try approvals.Home.init(allocator, null);
    defer home.deinit();
    var key: approvals.Key = undefined;
    _ = try std.fmt.hexToBytes(&key, std.mem.span(getenv("CORAL_TEST_PAUSE_KEY") orelse return error.MissingKey));
    approvals.setPaused(allocator, &home, key, false) catch |err| {
        // The native poll may briefly hold a shared lock. The parent retries
        // only contention, with a deadline; every other failure is fatal.
        if (err == error.Busy) std.process.exit(75);
        return err;
    };
}
