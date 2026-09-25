# Pearl development

Community themes add libcurl and libarchive development/runtime dependencies.
`zig build build-themes` builds the native `pearl-themes` validator, packer and
package manager. `zig build test-theme-packages` covers contracts and interrupted
installation/removal recovery; `test-theme-repository` uses a private HTTPS
fixture; `test-custom-themes` runs a private desktop. Python is development test
infrastructure only. See [the author guide](CUSTOM_THEMES.md).

For optional Qt application theming, build with `-Dqt-themes=true`; the default
build retains no Qt build dependency. Qt 5 and Qt 6.6+ development files and a C++
compiler build isolated probes. `zig build test-qt-theme-unit` covers pure policy
and INI contracts. `zig build test-qt-theme -Dqt-themes=true` runs real native
consumers against private configuration; it requires loadable Darkly application styles and QtEngine for
both runtimes. Add `-- --quick-compatibility` to require Qt 6 Quick Controls and
Kirigami fixtures too. `zig build test-qt-session -Dqt-themes=true` exercises the
actual Appearance editor, committed dynamic palettes and repair in private
Aqueous. Both integration runners accept `--libraries PATH` to supply test-only
runtime libraries without modifying the host. `--engine-prefix PATH` loads staged
QtEngine/Darkly plugins from `PATH/lib/{qt,qt6}/plugins` for private testing. See [Qt implementation and tests](QT_THEMING.md)
and [retained evidence](../artifacts/qtengine/README.md).

Current master integration: [migration and capability gates](AQUEOUS_MASTER_MIGRATION.md).
New candidate evidence is separate in `artifacts/aqueous-master`.


Pearl now has an application entry point, compiled GTK resources, a development
gallery with Material components and a private Aqueous launcher. Session mode
owns a persistent Aqueous adapter, per-output surfaces, native background blur
and a session-scoped `pearlctl` endpoint. See [SURFACES.md](SURFACES.md) for the
implemented surface policies, control schema and isolated Vulkan test.
[DESKTOP.md](DESKTOP.md) covers T06’s live bar, GIO launcher, local calendar,
control center, runtime groups and native layout requests.
[SERVICES.md](SERVICES.md) covers T07 audio/power adapters, CLI actions, service
restart policy, private fixtures and physical checks.

[SESSION_SECURITY.md](SESSION_SECURITY.md) covers T12 session actions, native idle,
polkit, PAM locking, packaging and the isolated security suite.
[LOCK_SCREEN.md](LOCK_SCREEN.md) covers T13 input, output lifecycle and the
private accessibility, helper-failure and resource tests.

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
zig build test-preferences -Doptimize=ReleaseSafe
zig build test-security -Doptimize=ReleaseSafe
zig build test-lock -Doptimize=ReleaseSafe
zig build integration -Doptimize=ReleaseSafe
```

`zig build` installs `zig-out/bin/pearl`, `pearlctl`, the native `pearl-lock` and the retained `pearl-t00`. The `test` target
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

## Release validation and migration

Use `-Drelease=true -Doptimize=ReleaseSafe` for stripped production builds.
`zig build test-release-tools` checks the fail-closed gate and source archive;
`zig build test-release` verifies staged binaries and offline migration against
a private compositor. `zig build test-release-performance` performs the 60-second
idle measurement and 1,000-cycle soak. Supply `-Doptimize=ReleaseSafe` to these
commands (and `-Drelease=true` when measuring production artifacts).

`python3 scripts/release-validate.py` runs the full matrix. To rerun a corrected
failure while retaining other results and prior logs, use
`python3 scripts/release-validate.py --resume --targets test-surfaces test-services`.
Do not treat a partial `--targets` run as full release acceptance. See
[RELEASE.md](RELEASE.md) for packaging, reproduction and manual gates, and
[MIGRATION.md](MIGRATION.md) for dry-run DMS import and restoration.
## Standalone Settings acceptance

The normal Settings window and its backend adapters are Zig. Run the complete
private-session acceptance target with:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-settings-acceptance -Doptimize=ReleaseSafe
```

It runs pure tests and eighteen isolated suites covering the normal window,
Appearance drafts, frontend protocol, live services, Aqueous editors, AT-SPI,
packaged launch paths and affected shell regressions. Evidence defaults to
`artifacts/settings-app/s6/acceptance/`. Pass `-- --jobs 1` for serial execution;
`-- --resume` reuses passed reports only when source, binary and report hashes
still match. Production binaries reject the read-only test probes.

Focused checks are `test-settings-app`, `test-settings-presentation` and
`test-master-ui`. The last now uses the normal application and separate production
and instrumented Settings binaries, preserving the original keyboard/receipt
assertions. No host services or configuration are changed by these fixtures.

After presentation passes, generate the offline visual comparison:

```sh
python3 scripts/settings-visual-review.py
```

Physical activation, monitor unplug and Orca acceptance use the separate
[manual checklist](../artifacts/settings-app/s6/MANUAL.md). Private AT-SPI inspection
is automated evidence and does not substitute for a screen-reader review.


## Completion feature checks

`test-theme-assets` checks PNG decoding/bounds and native GResource lifetime.
`test-theme-discovery` checks missing roots, nested edits and idle teardown.
`test-matugen` checks private JSON rendering, attributed profiles, immutable
snapshots, conditional ownership and Starship review/backup. `test-theme-completion`
uses a private compositor/XDG session for image chunks, committed/preview GTK
rendering, automatic discovery, exact fixed app colors and offline recovery.
`test-theme-publishing` checks deterministic multipage publication and source
migration in private roots. These require libpng and Matugen 4.2.0; Python remains
only development orchestration. Evidence is in artifacts/theme-completion.

`zig build test-wallpaper-profiles -Doptimize=ReleaseSafe` runs the live wallpaper
suite with all five application profiles in private XDG/compositor/D-Bus roots.
It covers shared extraction, image edits/replacement, draft preservation,
generation cancellation, independent color sources, ownership conflicts, snapshot
retry and restart with missing profile assets. Slow extraction/render fixtures
exercise cancellation; real Matugen produces every successful result. Evidence
and end-to-end latency samples are written to `artifacts/matugen-wallpaper-live/`.
The suite requires permission to create local sockets for the private session.


## Notification filters

`zig build test` includes configuration/lifecycle tests and the GLib Unicode
matcher tests. The latter can also run independently with
`zig build test-notification-filters -Doptimize=ReleaseSafe`; they require GLib
but no GTK display or compositor.

`zig build test-notification-filter-settings -Doptimize=ReleaseSafe` drives
the native Settings rule editor and tester against a real private notification
bus. It checks shared drafts, Apply/Discard, Block and History only, replacements,
Unicode/desktop identity, external reloads, startup publication, and native
themes/compact layouts. Evidence is written to `artifacts/notification-filters/`;
`-- --output /tmp/filter-check` selects another directory. The test uses the
existing private Aqueous fixture under `.cache/aqueous-activity-production`.

### Native window-rule builder

`zig build test-window-rule-settings -Doptimize=ReleaseSafe` exercises the shared
native rule builder in private Aqueous/D-Bus sessions. It checks creation,
pending additions, explicit false, null removals, repeated edits, stale modal
saves, isolated moves, canonical Apply and 390/560-pixel dialogs. It uses the
production private fixture at `.cache/aqueous-activity-production` and writes
screenshots and `report.json` beneath `artifacts/window-rules` (override with
`-- --output /tmp/window-rules-check`). Run `zig build test` for pure projection,
merge, identity and move-guard checks, and `test-notification-filter-settings`
when changing shared presentation. `test-settings-services` covers navigation,
focus restoration, receipts and the complete shared Aqueous boundary.
