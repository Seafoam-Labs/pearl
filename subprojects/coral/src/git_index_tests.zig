//! Standalone libc-only worker tests: zig test src/git_index_tests.zig -lc
//! Every Git write/fixture commit is confined to a private /tmp repository.
test {
    _ = @import("git/index_transaction_test.zig");
    _ = @import("git/hunk_test.zig");
    _ = @import("git/diff_render.zig");
}
