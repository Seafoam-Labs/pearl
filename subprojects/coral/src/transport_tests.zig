//! Standalone transport suite (no parent build changes or GTK imports):
//!   zig test src/transport_tests.zig -lc
//! Requires Linux x86_64, glibc >=2.34, Linux >=5.9, /bin/python3, /bin/sh,
//! /bin/cat and /bin/sleep. The parent may instead import transport_test.zig
//! from an existing src-rooted test module linked with libc.
test {
    _ = @import("language/transport_test.zig");
    _ = @import("terminal/executable_test.zig");
}
