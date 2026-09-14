# Pearl development

Pearl now has an application entry point, compiled GTK resources, a development
gallery with Material components and a private Aqueous launcher. Session mode
owns a persistent Aqueous adapter, per-output surfaces, native background blur
and a session-scoped `pearlctl` endpoint. See [SURFACES.md](SURFACES.md) for the
implemented surface policies, control schema and isolated Vulkan test.
[DESKTOP.md](DESKTOP.md) covers T06’s live bar, GIO launcher, local calendar,
control center, runtime groups and native layout requests.
[SERVICES.md](SERVICES.md) covers T07 audio/power adapters, CLI actions, service
restart policy, private fixtures and physical checks.

## Build and run

Use **Zig 0.16.0** and the packages in [COMPATIBILITY.md](COMPATIBILITY.md).
`glib-compile-resources` is also required for ordinary application builds.

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig"
zig build -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
zig build test-bindings -Doptimize=ReleaseSafe
zig build test-components -Doptimize=ReleaseSafe
zig build test-desktop -Doptimize=ReleaseSafe
zig build test-services -Doptimize=ReleaseSafe
zig build test-connectivity -Doptimize=ReleaseSafe
zig build test-session-services -Doptimize=ReleaseSafe
zig build integration -Doptimize=ReleaseSafe
```

`zig build` installs `zig-out/bin/pearl`, `pearlctl` and the retained `pearl-t00`. The `test` target
now runs pure startup/lifecycle, Aqueous codec/model, palette-contrast and translation tests without linking or initializing GTK. The
original T00 binding test has its own `test-bindings` target. Integration builds
a separate instrumented executable in the Zig cache and tests it on private
headless and nested Aqueous sessions. It needs the T00 compositor/aqueousctl
binaries, Python 3, `dbus-daemon`, `busctl` and `grim`. Override binary locations:

```sh
zig build integration -Doptimize=ReleaseSafe -- \
  --aqueous /path/to/aqueous --ctl /path/to/aqueousctl
```

The gallery is explicitly sample content. To see it inside your current Wayland
desktop, run:

```sh
zig build gallery -Doptimize=ReleaseSafe -Ddev-backend=nested
```

T03 adds dark/light palettes, compact density, larger text, reduced motion,
English/German labels and a searchable virtualized list. See
[COMPONENTS.md](COMPONENTS.md) for keyboard shortcuts, ownership conventions and
the isolated `test-components` harness. [Visual comparisons](../artifacts/t03/comparison.html)
retain the original DMS/Pearl screenshots and document deliberate differences.

This opens a separate Aqueous compositor window. It receives the parent Wayland
socket for rendering while Pearl receives the new compositor's display, IPC
socket, configuration directories and bus. The new compositor uses temporary
configuration; it does not reload or modify your running Aqueous configuration.
Close Pearl or press Ctrl+C in the launching terminal to stop the development
session. Parent compositors may throttle obscured nested windows; keep the
development compositor visible when checking rendering.

The default development backend is headless, so these commands do not open a
window on your desktop:

```sh
zig build gallery -Doptimize=ReleaseSafe
zig build run -Doptimize=ReleaseSafe
```

They run until Pearl exits or you press Ctrl+C. `run` selects session mode;
`gallery` adds `--demo`. Use the launcher directly for custom binaries/log paths:

```sh
python3 scripts/dev-session.py --backend nested --output .cache/my-gallery \
  -- ./zig-out/bin/pearl --demo
```

The launcher defaults to `.cache/aqueous/bin/aqueous`, prepared in T00. It gives
a useful error if the binary or selected parent display is missing. Use distinct
output directories for concurrent development sessions. No shell service, login
entry or host configuration is installed by these commands.

## Application modes and isolation

`pearl --help` and `--version` work without a display. Ordinary session mode
requires an Aqueous desktop token, a Wayland display, a normalized runtime path
and an existing Unix socket at `aqueous/<instance>/ipc.sock` within that runtime.
These are launch checks. T04 performs the authoritative paired handshake
and state subscription, publishes connection availability, and reconnects to the same
endpoint after failure. The [adapter contract](AQUEOUS_ADAPTER.md) documents its
command API and ownership rules; T02 supplies the [decoder and atomic model](AQUEOUS_MODEL.md).

`pearl --demo` permits the gallery on another Wayland desktop and never requests
Aqueous state or system-service data. Sample text is loaded only in this mode.
Both modes use the Wayland GTK backend. Unknown arguments and unsupported launch
environments exit with status 2; application/resource failures use status 1.

T01 uses `GtkApplication` with a null application ID and `NON_UNIQUE`. Launches
stay local, and Pearl owns no shared application activation name. GTK may still
connect to a session bus for toolkit facilities. Multiple local launches are
allowed for demo mode. Session mode now allows one control owner per verified
Aqueous session, checked against GTK’s native display identity. `pearlctl` uses
that session’s private socket; it does not use GTK application activation.

The launcher starts a private bus without service activation directories and
points system-bus access at a nonexistent private socket. It preserves only
PATH and locale/timezone variables from its caller; HOME/XDG directories,
display/IPC/bus addresses and configuration are constructed anew. It does not
import service-manager environment, activation tokens, Wayland FDs or other
shell sockets. System fonts and installed libraries remain readable.

Headless mode creates two outputs. Nested mode creates one Wayland output.
Both use the T00 no-effects binary with pixman and GTK cairo. The private
configuration uses a floating layout: the tested Aqueous-in-Aqueous setup
stalled while starting the nested backend under a populated monocle parent.
This observation is limited to that test configuration; it does not establish
the upstream cause or change any host layout. GPU/blur checks remain separate.

## Ownership and asynchronous work conventions

`src/core/lifecycle.zig` is a pure main-context state machine. It admits one
background job, rejects work while busy/stopping, and disallows restart until
completion is drained. `src/core/application.zig` owns the GTK application,
builder, CSS provider, cancellable, signal connections and main-context sources.

- All GTK access, lifecycle transitions and view updates occur on the creating
  GLib thread. Completion callbacks assert this thread identity.
- The window has one explicit owned reference in addition to GTK's application
  ownership. Builder-returned children are borrowed while the builder lives.
  Signal connections are retained and disconnected before owners are released.
- The application holds its run loop while active. A job takes an additional
  hold. Closing the window or receiving SIGINT/SIGTERM marks stopping, cancels
  work, destroys the window and releases the active hold. The job completion
  releases the final hold after discarding any result for the stopped view.
- `GTask.runInThread` performs the gallery resource load. Return-on-cancel stays
  **false** so completion follows worker exit. Its input is immutable until the
  callback drains. The one-job admission limit bounds this application's use
  of GLib's shared thread pool; idle views schedule no polling work.
- GTask results use GLib allocation and matching `g_free`; GBytes/GResource and
  GObjects use their own ref/unref APIs. Do not free those through a Zig
  allocator. Argument storage uses the process arena. Future retained Zig
  models should receive an explicit allocator, use task-local temporary arenas
  for parsing, and transfer owned results rather than sharing temporary slices.
- Every accepted job has exactly one completion, including cancellation.
  Do not call `Application.quit` while workers still reference application
  state. New adapters must support cooperative cancellation and bounded work.

Resources are compiled to a binary GResource and embedded in the Zig executable;
no generated C registration glue is used. CSS is scoped below `.pearl-root`.
The resource compiler's dependency file tracks CSS/UI/text edits. Teardown
removes the CSS provider, disconnects signals, removes sources, releases objects
and unregisters the resource bundle. Resource lookup is independent of the
working directory or source checkout at runtime.

Logs use `std.log.scoped(.pearl)` with lifecycle event fields. They do not log
typed content, secrets or host environment dumps.

## Verification and limits

[T01 results](../artifacts/t01/latest/results.json) cover unsupported environments,
missing/non-socket endpoints, failed compositor startup cleanup, sixteen
application lifecycles within two processes, successful and canceled background
work, GTK close requests, SIGINT/SIGTERM, same-display independence, nested
display independence and a deliberately reused bus. The outer compositor is a
private stand-in for a host; no test connects to your real display or bus.

The instrumented executable checks actual weak finalization of owned GObjects
and GTasks, and verifies resources are no longer registered after each cycle.
GTK/GLib warnings are fatal in the suite. Deterministic delay/close/repeat hooks
are compiled only into that executable; installed `pearl` ignores those test
environment variables. These checks do not assert that GTK's process-global
caches or shared worker pool are destroyed between application lifetimes.

[Gallery capture](../artifacts/t01/latest/gallery.png) preserves the historical T01 fixture.
[T03 captures](../artifacts/t03/comparison.html) show the implemented component system. Full shell services,
authenticated locking, accessibility and physical-display validation remain
the tasks specified in [TASKS.md](TASKS.md).

## Adapter regression tests (T04)

`zig build test-adapter-unit -Doptimize=ReleaseSafe` checks endpoint validation,
credential rejection and bounded icon handling through the generated bindings.
`zig build test-adapter -Doptimize=ReleaseSafe` adds scripted socket faults and
real commands in private nested Aqueous. See [AQUEOUS_ADAPTER.md](AQUEOUS_ADAPTER.md)
for full commands, completion semantics and test-driver isolation.


## Desktop preview tests (T06)

`zig build test-desktop -Doptimize=ReleaseSafe` drives real private desktop files,
application launches, bar workspace/window actions, keyboard state, native layout
changes and the calendar/control center. It needs Python/PyGObject GTK4 and the
T00 input fixture compiler dependencies in addition to the normal integration
tools. Its 2,000-app test records search-to-frame and warm opening latency.
See [DESKTOP.md](DESKTOP.md) for limits, ownership, the full CLI and reproduction.


## Aqueous settings replacement (T11)

`pearlctl aqueous show` opens the GTK replacement; `--text displays` selects a
page. `aqueous status`, `draft --text JSON`, `validate`, `apply`, `refresh`,
`rebase`, `discard`, `reload`, `keep` and `revert` expose the retained-draft
workflow. The canonical helper is required; the old settings frontend is not.
See [AQUEOUS_SETTINGS.md](AQUEOUS_SETTINGS.md) for request examples and gates.

Run `zig build test-aqueous-settings -Doptimize=ReleaseSafe` with the workspace
`ZIG_GLOBAL_CACHE_DIR`. The suite only modifies private HOME/configuration,
synthetic keyboard bindings and headless outputs, including a deliberate Pearl
SIGKILL to verify independent rollback. It does not reconfigure host displays.
