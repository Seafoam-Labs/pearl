# Running applications: native implementation evidence

The optional **Running applications** widget is implemented. Add it through
Settings → Bar & dock → Add widget, then Apply. `running_apps` can be placed in
any group, including output-specific layouts. It groups taskbar windows across
all workspaces and displays; the existing dock remains independently configured.

Primary click activates a single window or opens the chooser for a group.
Secondary click opens the chooser for either. Window rows show workspace,
display and minimized/unavailable state. Activation restores and focuses the
selected window where it lives. Overflow and incremental loading retain all
application/window identities. `pearlctl running-apps show [--output ID]` provides
a keyboard entry point while the bar keeps keyboard mode `none`.

The [approved plan](../../docs/RUNNING_APPLICATIONS_BAR_WIDGET_PLAN.md) and
[browser mockup](../../docs/mockups/running-apps/index.html) remain available.
These captures below come from real GTK windows in private Aqueous sessions.

| Native view | Capture |
| --- | --- |
| Group chooser with a minimized window on another display | [Horizontal chooser](session/horizontal-chooser.png) |
| Vertical task strip and chooser | [Left edge](session/chooser-left.png) |
| Small bar with overlaid counts | [Compact bar](session/compact-bar.png) |
| Overflow among 36 applications, including a 70-window group | [Overflow](session/overflow.png) |
| GTK theme, large text and mixed display scales | [GTK / large text](session/gtk-large-text-mixed-scale.png) |
| Native Settings selection editor | [Settings](regression/bar-editor/session/bar-editor-light-20-560.png) |

## Validation

| Check | Result / evidence |
| --- | --- |
| ReleaseSafe build | Passed · [build.log](build.log) |
| Unit suite | 146 passed · [unit-tests.log](unit-tests.log) |
| New `test-running-apps` target | 15 checks passed · [metadata.json](metadata.json), [native-tests.log](native-tests.log) |
| Selection editor, including new widget add/move/reorder/remove/discard/save/reopen | 12 checks passed · [metadata](regression/bar-editor/metadata.json) |
| Preferences compatibility and persistence | 24 checks passed · [metadata](regression/preferences/metadata.json) |
| Existing bar geometry across edges and themes | 20 cases passed · [metadata](regression/bar-layout/metadata.json) |
| Existing dock behavior and shared identity matching | 17 checks passed · [report](regression/dock/report.json) |

The widget target uses actual application windows across four workspaces on two
outputs. It checks cross-display activation/restoration, exact window identity,
window closure while a chooser is open, ambiguous catalog refresh and regrouping,
`skip_taskbar` versus `skip_switcher`, all four edges, compact bar measurement,
per-output placement, GTK/large text/mixed scale, 36 application groups, loading
all 70 windows in a group, keyboard entry/Escape and power-off teardown. GTK
warnings are fatal during these tests. Model tests also cover anonymous identity,
unavailable activation, owned strings after model destruction, stable order and
collections exceeding the dock's caps.

Test reports include executable hashes. Regression reports reflect the builds
used for those runs; subsequent changes are confined to task-strip rendering,
chooser state and count wording, with the final widget run validating those
paths. Preferences and editor behavior are unchanged by that later polish.

## Compositor limitation

A separate attempt to disable an output with `wlr-randr --off` crashed the cached
Aqueous compositor in `OutputManager.zig:575`, inside `validateConfigCoordinates`.
It disconnected the Wayland session before Pearl could finish the removal test.
See the [compositor trace](hard-disable-failure/compositor.log) and
[test failure](hard-disable-failure/test.log). No compositor source was changed.

The passing native test instead uses the real output-power protocol to turn off
the second display with its chooser open. Pearl then removes that output's
surfaces and dismisses the chooser, exercising its inactive-output teardown path.
This verifies power-off cleanup; it does not claim a successful hard-disable or
physical unplug test on this compositor build. IPC/session loss and lock use the
existing manager lifecycle; the dock regression separately exercises lock/input
release, and model invalidation is covered by unit tests.

## Reproduce

Use the repository's private-session prerequisites and cached Aqueous tools:

```sh
ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig zig build -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig zig build test
ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig zig build test-running-apps -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig zig build test-settings-bar-editor -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig zig build test-preferences -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig zig build test-bar-layout -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig zig build test-dock-islands -Doptimize=ReleaseSafe
```

Private D-Bus/Wayland sockets require an environment that permits local sockets.
The output-power fixture uses the cached compositor's protocol XML,
`wayland-scanner`, a C compiler and `libwayland-client`.
