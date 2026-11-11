//! Pure standalone tests, no app/GTK/libc dependencies.
//! From subprojects/coral: zig test src/git_tests.zig
test {
    _ = @import("git/status_test.zig");
    _ = @import("git/command.zig");
}
