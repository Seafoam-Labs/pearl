//! Separate process: filesystem publication tests fork, unlike the GIO test root.
test {
    _ = @import("workspace/session_test.zig");
}
