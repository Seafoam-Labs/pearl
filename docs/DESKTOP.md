# First desktop slice (T06)

[T15 dock and island layouts](DOCK_ISLANDS.md) add persistent app pins, per-output
dock behavior, split bar sections and matching native input/blur regions.

Pearl session mode now provides a live bar, application/window launcher,
clock/calendar and control center on Aqueous. It uses the existing T04 state
adapter and T05 surface/control machinery. All desktop discovery and launch
behavior comes from GIO; normal session mode never substitutes fixture data.
The demo gallery remains a separate `--demo` application mode.

This page records T06. [T07 services](SERVICES.md) now supply audio, battery,
brightness, power profiles and confirmed power actions; their bar groups and
control-center contents supersede the unavailable T06 placeholders below.

## Use the desktop

The launcher button opens a shared search surface on its output. Type to search,
use Up/Down to select, Enter to open and Escape to dismiss. Pointer activation
also works. The clock opens a local calendar; the settings icon opens the
control center. Opening another principal popup replaces the previous one.
Backdrop clicks dismiss without activating an application underneath.

Workspaces are identified by their Aqueous runtime IDs. Number/name is only the
label: the same number on another output remains a different target. The active
workspace has a purple pill, and urgent workspaces have an outline. The workspace
strip shows every available workspace on its output without a scrolling viewport.
When space is tight, buttons wrap into rows (columns on vertical bars), and the
bar grows to reserve the space they need. Focused window titles
ellipsize and have a full-text tooltip. The title becomes “Pearl” for layer focus,
rather than presenting a previously focused application as current. Keyboard
controls show the active seat's **effective layout name**, and clicking cycles
that keyboard group through the adapter's validated action API. With no keyboard
or an ambiguous seat, the control is unavailable.

The bar has configurable start/center/end groups. `GtkCenterBox` centers the
clock when the groups permit it. Narrow outputs hide the optional title and
bar overview button; overview remains available in the control center. Vertical
edges change group orientation. GTK measures the resulting bar thickness for
its exclusive reservation. Each process has one clock timer, aligned to the
next minute, instead of one timer per widget/output.

```sh
pearlctl launcher toggle
pearlctl launcher show --output OUTPUT_ID
pearlctl launcher hide
pearlctl calendar toggle --output OUTPUT_ID
pearlctl control-center toggle --output OUTPUT_ID
pearlctl overview toggle --output OUTPUT_ID
pearlctl bar groups --output OUTPUT_ID \
  --left launcher,workspaces,title --center clock --right keyboard,overview,control
```

Get runtime IDs from `pearlctl status`. Groups accept comma-separated `launcher`,
`workspaces`, `title`, `clock`, `keyboard`, `overview` and `control`. An empty group
is allowed; duplicate items, unknown items and configurations without a launcher
are rejected. All three groups are supplied together. These are **runtime
preferences**: restart or output removal resets them. Persistent preference
editing/migrations belong to T13. Existing `bar set` controls edge/thickness.

The control center uses the Material component system. Network, Bluetooth,
audio, brightness and media explicitly show unavailable because their service
adapters belong to later tasks. Its workspace-layout controls and window
overview action are real. Calendar browsing uses `GtkCalendar` and local time;
there is no account synchronization or fabricated event list. English/German
surface labels and GIO desktop labels follow GLib's language preferences.

## Application index and launcher

`src/desktop/apps.zig` owns one `GAppInfoMonitor` and immutable catalog shared
across all outputs. Catalog construction runs in one cancellable GTask.
Application changes are coalesced for 200 ms and published atomically. A failed
refresh retains the last catalog and records failure. Discovery uses
`GAppInfo.getAll`, `shouldShow` and `GDesktopAppInfo`: XDG precedence, `Hidden`,
`NoDisplay`, `OnlyShowIn`, `NotShowIn`, `TryExec`, translated names, keywords and
desktop actions remain GIO's responsibility.

The catalog admits at most 4,096 entries including actions, 16 actions per app,
32 keywords per entry, 4 KiB titles/descriptions and 1 KiB desktop IDs. The
`status.apps.truncated` flag reports the catalog limit. Catalogs own GObject
references and an arena; atomic reference counts keep replaced catalogs alive
only while search results/jobs still use them. Generated GIR pointer casts
correct missing nullability on GIO lists/string vectors without adding a C
bridge or separate ABI implementation.

`src/desktop/launcher.zig` copies current Aqueous window IDs, titles, output and
workspace context into an immutable search job. Workers never read GTK or the
mutable Aqueous model. There are at most **two admitted search tasks across the
process**, including canceled tasks from closed popups, plus the one catalog
scan. Each view coalesces input to its newest generation. Task-held application
references let completion drain after windows close; callbacks from stale
sessions or generations cannot replace current results.

Ranking casefolds Unicode text, requires every query word to match, and favors
exact names, then prefixes, substrings and metadata. Empty queries favor running
windows and the last 32 successfully requested applications, kept in memory.
Stable tie-breaks include result kind, desktop ID plus action, or window ID.
Selections survive state refreshes by identity. Enter during a pending search
waits for its fresh result rather than activating an old query's selection.

A `GtkListView` virtualizes the top 200 results. The footer reports when only part
of a larger match set is shown and asks the user to refine the query. Search
input is bounded to 512 UTF-8 bytes. Titles/subtitles ellipsize, accessible labels
and descriptions retain their meaning, and missing theme icons use Pearl's
symbolic fallback. Themed and file icons continue through GTK/GIO.

Running-window results use authoritative `can_activate`, output enabled/powered,
`skip_switcher`, `visible` and `minimized` state. Hidden-workspace/minimized
windows remain searchable with explicit state subtitles. `skip_taskbar` alone
is not a switcher exclusion; a future taskbar must use that separate hint.
Activation revalidates the current session/window and queues the T04 typed
`window.activate` action. Display titles, workspace numbers and application
names are never used as action identity.

Application activation re-reads the desktop ID and validates visibility/action
existence before requesting launch. `GAppInfo.launch` and
`GDesktopAppInfo.launchAction` handle `Exec` field codes, `Path`, `Terminal`,
D-Bus activation and desktop actions with a `GdkAppLaunchContext` for this display.
Pearl does not parse `Exec`, interpolate it into a shell, pick an ad hoc terminal,
or import environment into the host service manager. Launch acceptance is not
proof that an application's eventual startup succeeded; GIO's desktop-action
API itself returns no completion result. Synchronous failure remains in the
launcher. Rejected/dropped/unknown compositor actions show a non-focusable OSD.

## Native runtime layout

`src/platform/wayland/layout.zig` uses generated
`aqueous_window_info_manager_v1` **version 3** (the server advertises version 8).
Its pinned XML and foreign-toplevel type dependency are recorded in
[the binding manifest](../bindings/protocols/inputs.json). It borrows GTK's
already-verified Aqueous connection; GTK remains the sole reader/dispatcher.
This extends T05's native integration instead of adding another display and
identity handshake. No IPC layout action is invented and no `aqueousctl`
subprocess is used in Pearl.

```sh
pearlctl layout get --output OUTPUT_ID
pearlctl layout set --output OUTPUT_ID --layout grid
pearlctl status
```

Names are `tile`, `monocle`, `grid`, `rows`, `dwindle`, `reverse-dwindle`,
`scrolling`, `float`, `game-mode` and `composable`. One request is outstanding at
a time, with a five-second deadline. Each request owns a short-lived manager
proxy, destroyed on reply, cancellation or timeout. Replies validate output and
layout; the result contains Aqueous's effective workspace number. Locked or
unavailable sessions cannot request changes. GTK rendering retains its existing
surface/blur lifecycle and never receives a manual buffer commit.

Layout is queried on opening the control center, on active-workspace changes
while it is open, and through Refresh or the CLI. The protocol does **not** send
a continuous stream of external layout changes. An external change on the same
workspace may therefore remain stale until refresh. No timer attempts to imitate
live observation. Continuous external-change parity requires a separate
capability-negotiated upstream extension. A runtime layout override is not a
persistent configuration save.

## Control v1 additions and module boundaries

T05's bounded, same-UID, per-session socket and exit codes remain in force.
New flat operations are `launcher_show`, `launcher_hide`, `launcher_toggle`,
`control_show`, `control_toggle`, `calendar_toggle`, `bar_groups`, `layout_get`,
`layout_set` and `overview_toggle`. Pane/overview operations accept optional
`output`; `launcher_hide` accepts none. `bar_groups` requires `output`, `left`,
`center`, `right`. `layout_get` requires `output`; `layout_set` additionally
requires `layout`. Existing `popup_show/toggle` are launcher aliases;
`popup_hide` dismisses whichever principal pane is open.

Layout and overview commands return `result: {"queued":true}`. This reports
admission, not compositor completion. Inspect `status.layout` for layout reply,
pending state, workspace/output and error. Other surface/configuration requests
retain T05's applied-to-GTK meaning. Stable errors additionally include `Busy`,
`Unsupported` and `InvalidGroups` (wire schema failures still use `InvalidRequest`).

Status adds application catalog count/generation/truncation, bar groups and
rendered keyboard/title text (title preview capped at a UTF-8 boundary), popup
kind/result count/frame latency, and native layout state. There is no global
activation bus name or cross-session endpoint discovery.

| Module | Owns |
| --- | --- |
| `desktop/policy.zig` | Pure group validation, search scores, window eligibility |
| `desktop/apps.zig` | Catalog scan/monitor, immutable metadata and recent app IDs |
| `desktop/launcher.zig` | Search generations, virtual list, selection and GIO launch |
| `desktop/bar.zig` | Per-output groups and ID-bound GTK callbacks |
| `desktop/panels.zig` | Calendar and control-center composition |
| `platform/wayland/layout.zig` | One-shot native layout queries/mutations |
| `ui/surfaces/manager.zig` | Output/popup ownership, action routing, global clock |

Monitor reconciliation watches both list membership and GDK monitor properties:
a connector can arrive after its monitor is inserted. Surfaces retain panel
references through GTK hotplug teardown; signal callbacks are disconnected
before view state is released. This closes the late-connector race exposed by
the T06 regression suite.

## Validation and visual review

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig"
zig build test -Doptimize=ReleaseSafe
zig build test-desktop -Doptimize=ReleaseSafe
zig build test-surfaces -Doptimize=ReleaseSafe -- --output artifacts/t06/surfaces
python3 scripts/check-wayland-bindings.py
```

The desktop suite requires Python/PyGObject GTK4, Pillow, `wtype`, `wlrctl`,
`wlr-randr`, `grim`, D-Bus and the existing private T00 Aqueous binary. It reuses
Aqueous's standalone C input fixture, generated/compiled in the temporary test
runtime; that executable is not linked into Pearl. Its source path is currently
`/home/zoey/RiderProjects/Aqueous`. All desktop files, terminal stubs, activation
names, injected input, output changes and rules belong to private sessions.
Nothing enables Pearl on the user's desktop.

[Desktop results](../artifacts/t06/latest/results.json) cover 2,000 catalog apps,
GIO visibility/launch/terminal/D-Bus/action semantics, duplicate titles and
workspace numbers, effective keyboard state, layout get/set, calendar, overview,
install/removal, empty/localized catalogs, 100/125/150/200% scale, long text and
pending-task teardown. [Surface regressions](../artifacts/t06/surfaces/results.json)
include native Vulkan blur, reservations, input/focus, hotplug and session
isolation. Earlier lifecycle/component/adapter suites are also retained under
`artifacts/t06` with verification logs.

Search timing runs from the latest refresh/input notification through GTK's
first after-paint callback with published results, including worker queue time.
Warm opening timing starts before `pearlctl launcher show` and ends after a
status query confirms a painted launcher, so it includes CLI handshake/process
and observation overhead. Results report samples, median, p95 or maximum; these
are private headless cairo-renderer measurements, not physical display latency.
The preview targets are search p95 <50 ms over 2,000 apps and warm opening <100 ms.
Physical GPU/input latency, the 60-second idle budget, full memory/refresh-rate
budgets and the 1,000-cycle release soak remain release-gate measurements.

[Visual comparison](../artifacts/t06/comparison.html) presents unedited actual
DMS reference captures beside the running Pearl desktop. Both use the purple
Material palette, rounded surfaces, a 48-pixel bar and grouped controls. Pearl's
launcher is 620×600 logical pixels where space allows, centered in Aqueous's
usable area, with a heading and explicit result footer. Its control center is
taller to expose native Aqueous layout controls; disabled service tiles are
truthful placeholders. Pearl uses symbolic icons and numbered workspace pills;
DMS's reference uses its Material icon font and compact workspace indicators.
The static gradient wallpaper, service coverage, dark-only session defaults and
local-only calendar are deliberate scope differences. T03 retains light/compact
component comparisons. Full service, settings, lock and accessibility parity is
not claimed at this milestone; T07 adds audio, power and OSD services next.
