const std = @import("std");
test "M4 controllers type-check" {
    std.testing.refAllDecls(@import("git/remote_controller.zig"));
    std.testing.refAllDecls(@import("git/history_controller.zig"));
    std.testing.refAllDecls(@import("git/remote.zig"));
    std.testing.refAllDecls(@import("git/history.zig"));
}
