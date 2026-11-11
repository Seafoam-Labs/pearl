//! Headless configuration/ordinary process-owner regressions. Uses the same
//! pearl_app_c generated bindings as the app; links libc, GLib, GObject and GIO.
//! Descriptor-bound process tests also run via the libc-only transport_tests.
test {
    _ = @import("language/config.zig");
    _ = @import("tasks/process_test.zig");
}
