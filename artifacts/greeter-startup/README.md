# Greeter startup abort

The September 15 boot journal recorded SIGABRT in `pearl-greeter-host`, followed
by `greeter exited without creating a session`. DMS later logged the same optional
GNOME Keyring warning and successfully logged in, so that warning was unrelated.

A production-path debugger reproduction located the null unwrap in Zig 0.16's
`Io.Threaded.Environ.scan`, called by the host's first `std.log.info`. GLib's
environment cleanup shortened the array referenced by Zig's original environment
slice before stderr's lazy initialization.

The fix initializes stderr before environment mutation in the host, greeter UI
and authenticated session launcher. The fixed production host reaches its main
loop after logging. The instrumented host now runs the same environment cleanup;
regression fixtures inject stale display/bus variables and verify removal, startup,
exit handling and descendant cleanup. Tests also passed against installed Aqueous
using a private headless display. No real login or VT handoff is claimed by these
tests, and no PAM changes were made.
