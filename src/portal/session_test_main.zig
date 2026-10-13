//! Test-only entry point for the independent D-Bus fixture.
const std = @import("std");
const session = @import("portal_session.zig");
comptime {
    for (.{ "pearl_session_portal_start", "pearl_session_portal_stop", "pearl_session_portal_holds", "pearl_session_portal_update", "pearl_session_portal_begin_end" }) |name| {
        @export(&@field(session, name), .{ .name = name });
    }
}
extern fn pearl_session_harness_main() c_int;
pub fn main() void {
    std.process.exit(@intCast(pearl_session_harness_main()));
}
