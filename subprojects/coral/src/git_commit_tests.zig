//! Standalone M4 commit/uncommit backend tests.
//! From subprojects/coral: zig test src/git_commit_tests.zig -lc
test {
    _ = @import("git/commit_test.zig");
}
