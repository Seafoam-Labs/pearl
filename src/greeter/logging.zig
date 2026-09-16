const std = @import("std");

/// Zig 0.16 lazily scans its original envp when stderr is first used. GLib's
/// unsetenv can shorten that array, leaving null entries inside Zig's saved
/// slice. Cache stderr's environment before any GLib/GTK environment changes,
/// so normal logging and error reporting remain usable after sanitization.
pub fn init() void {
    var buffer: [64]u8 = undefined;
    _ = std.debug.lockStderr(&buffer);
    std.debug.unlockStderr();
}
