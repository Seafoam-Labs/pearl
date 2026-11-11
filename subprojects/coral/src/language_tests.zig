//! Standalone, libc only; no app/GTK or parent build changes.
//! From subprojects/coral: zig test src/language_tests.zig -lc
//! Real-pipe fixtures require /bin/python3 on transport's Linux platform.
test {
    _ = @import("language/client_test.zig");
}
