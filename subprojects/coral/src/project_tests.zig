//! Fork-based durable project tests run outside GTK/GIO worker processes.
test {
    _ = @import("workspace/project_test.zig");
}
