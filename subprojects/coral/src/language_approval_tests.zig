//! Standalone Linux/libc tests, including fork-based concurrency fixtures.
//! From subprojects/coral: zig test src/language_approval_tests.zig -lc
//! No controller, configuration, build, GTK or trust-store integration.
test {
    _ = @import("language/approvals_test.zig");
}
