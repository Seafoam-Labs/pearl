# First desktop slice (T06)

The bar supports optional **Autohide** in **Settings → Bar & dock → Bar
visibility**. Move the pointer to its screen edge to reveal it; the bar hides
450 ms after leaving unless a Pearl popup or bar gesture keeps it open. Autohide
works on every edge and overlays applications without resizing them. Existing
launcher and flyout commands still work while the bar is hidden. See
[preferences](PREFERENCES.md#standalone-editor) for Apply/Discard and display
override behavior.

[T15 dock and island layouts](DOCK_ISLANDS.md) add persistent app pins, per-output
dock behavior, split bar sections and matching native input/blur regions.

The dock and Running applications share preferred-launcher matching: an explicit
choice wins, followed by a unique matching pin, a unique matching user-local
launcher, or a unique system match. A custom desktop ID or StartupWMClass must
match the window for automatic selection. Ambiguous or unrelated IDs can be
associated through the dock's **Use launcher…** menu. Both surfaces use the same
effective desktop ID, icon and grouping, including after pin edits.
See [custom application launchers](DOCK_ISLANDS.md#custom-application-launchers)
for pin correction, reset and unavailable-entry behavior.

Pearl session mode now provides a live bar, application/window launcher,
clock/calendar and control center on Aqueous. It uses the existing T04 state
adapter and T05 surface/control machinery. All desktop discovery and launch
behavior comes from GIO; normal session mode never substitutes fixture data.
The demo gallery remains a separate `--demo` application mode.

This page records T06. [T07 services](SERVICES.md) now supply audio, battery,
brightness, power profiles and confirmed power actions; their bar groups and
control-center contents supersede the unavailable T06 placeholders below.

## Running applications in the bar

Add **Running applications** in Settings → Bar & dock → Add widget. Its builtin
layout token is `running_apps`. Existing layouts stay unchanged until you add it.
It groups taskbar windows across **all workspaces and displays**, including
minimized windows. `skip_taskbar` windows are excluded; `skip_switcher` alone
has no effect. Applications without windows are not included.

Click a single-window application to activate it. Click an application with
multiple windows, or secondary-click any application, to choose a window by
title, workspace and display. Activation restores a minimized window and
switches to its own workspace/display without relocating it. Unavailable
activation stays visible with a disabled window row. Focus is highlighted and
multi-window groups show a count; a hollow marker means all windows are minimized.

The strip fits the remaining bar length on any edge. Its overflow button opens
additional application groups; if space is very limited it opens the entire
list. All windows remain reachable. Long chooser lists load in batches of 50
through **Show more**. Focus changes preserve application order; new applications
append after existing groups. The strip disappears when no taskbar windows exist.

For a keyboard binding, use `pearlctl running-apps show [--output ID]`. The
chooser owns keyboard input; arrows/Tab navigate, Enter activates and Escape
dismisses it. The bar retains keyboard mode `none`. This command works even
without a widget in the selected output's bar. The chooser shares the normal
single-popup lifecycle, anchoring and dismissal policy.

The dock retains its own per-output groups, pins, cycling and visibility policy.
See [the implementation plan](RUNNING_APPLICATIONS_BAR_WIDGET_PLAN.md) for the
model and verification details. Before downgrading to a Pearl version without
this widget, remove `running_apps` from saved layouts; older versions reject
unknown widget tokens.

## Wallpaper in the bar

Add **Wallpaper** in Settings → Bar & dock → Add widget. Its builtin layout
token is `wallpaper`. Clicking it opens a thumbnail browser for the folder
configured under Appearance → Wallpaper → Slideshow → Image folder; clicking a
thumbnail applies that image immediately, with no Apply step, and outlines it as
the current wallpaper. The folder itself is chosen in Settings, not here.

The pane shows six landscape thumbnails per page in a three-by-two grid, with
**‹ / ›** and a page counter below the grid to move through longer folders, and a
refresh button in the header to rescan after adding or removing files. Previews
are decoded off the main thread at 192×108 and cached on disk under
`$XDG_CACHE_HOME/pearl/wallpaper-thumbs`, keyed by path, size and mtime, so pages
you have seen before — in this session or a later one — paint without touching
the source image again. Only PNG and JPEG are listed, matching what the
wallpaper pipeline accepts. Applying a wallpaper goes through the normal
preferences commit, so the wallpaper watch, wallpaper-derived colors and every
output surface stay consistent; if the theme follows the image, each pick
regenerates its palette. With no folder set the pane shows a hint instead of a
grid. Before downgrading to a Pearl version without this widget, remove
`wallpaper` from saved layouts.

## Compact settings navigation

Speaker, Network, Bluetooth and Battery open **Sound**, **Network**,
**Bluetooth** and **Power & battery** directly. The gear opens **Overview**.
The fixed heading and section chooser select one compact page at a time; each
page scrolls independently. Overview links to all four pages, media controls,
window overview and the existing Pearl/Aqueous editors, and retains session and
workspace-layout actions.

Clicking a different service icon switches the existing flyout on that output.
Clicking the same icon again closes it. Another output replaces the flyout there.
External links start at the heading; internal navigation restores page-local
scroll and focus. Escape, Close and permitted backdrop clicks dismiss it.
Clock, bell, media, tray, keyboard, launcher, workspace, overview and capture
actions keep their task-specific behavior.

```sh
pearlctl control-center show --page sound
pearlctl control-center toggle --page network --output OUTPUT_ID
```

Compact page IDs are `overview` (default), `sound`, `network`, `bluetooth` and
`power`. Invalid IDs are rejected before changing the flyout.
`pearlctl status` reports the selected route as `popup.page`; task popups use
`null`. This command always means the shell-owned compact flyout. The standalone
`pearl-settings` application has an independent normal-window lifecycle.
**Open full settings** carries the current route and available activation context;
a successful process launch dismisses the flyout to release keyboard input.
Missing installations disable the link with an explanation. A dispatch failure
keeps the flyout open with feedback. All existing compact controls work without it.

`pearlctl settings show [--page PAGE] [--section AQUEOUS_SECTION]` and
`pearlctl aqueous show [--section SECTION]` dispatch the fixed matching executable
directly from the verified backend. Repeated launches activate its existing window.
Legacy `--output ID` is validated but normal application placement belongs to the
compositor. The menu/dock use `org.aqueous.Pearl.Settings.desktop` and its installed
icon (Git packages use `org.aqueous.Pearl.Git.Settings.desktop`).

Bar service buttons expose an action name and a current-status description to
assistive technology. Selected headings are announced; inactive page controls are
absent from focus traversal. The flyout follows Pearl's font, dark/light/native
GTK theme and reduced-motion preferences. The bar retains layer-shell keyboard
mode `none`; keyboard navigation occurs within the flyout, with no on-demand bar
focus. See the
[navigation plan](SETTINGS_NAVIGATION_PLAN.md) and
[service-view ownership contract](SETTINGS_SERVICE_OWNERSHIP.md).

Run the complete compact navigation acceptance checks with:

```sh
zig build test-settings-navigation -Doptimize=ReleaseSafe --global-cache-dir .cache/zig
```

This runs pure tests and private page, lifecycle, accessibility, desktop, surface,
audio/power, connectivity and session-service fixtures. Evidence is written under
`artifacts/settings-navigation/f5/`; use `-- --output DIRECTORY` to choose another
artifact directory. Bar input is pointer-driven under the approved no-keyboard-focus
policy; the chooser, page controls, Close and Escape use actual keyboard input.

## Use the desktop

The launcher button opens a shared search surface on its output. Its icon can be
changed in **Settings → Bar & dock → Launcher actions → Change icon…**, with
bundled icons, installed theme names, or a local static PNG. Apply & save updates
it live; unavailable artwork uses the bundled fallback. See
[launcher icon preferences](PREFERENCES.md#launcher-button-icon) for limits, Retry,
and per-output behavior. Type to search,
use Up/Down to select, Enter to open and Escape to dismiss. Pointer activation
also works. The clock opens a local calendar; the settings icon opens the
control center. Opening another principal popup replaces the previous one.
Backdrop clicks dismiss without activating an application underneath.

Workspaces are identified by their Aqueous runtime IDs. Number/name is only the
label: the same number on another output remains a different target. The active
workspace has a purple pill, and urgent workspaces have an outline. The workspace
strip defaults to **Large**, showing every available workspace on its output.
In **Settings → Bar & dock → Workspaces → ⋯ → Display mode**, select **Small**
(active plus one neighbor on each side), **Medium** (two neighbors on each side),
or **Large** (all), then Apply. For workspace 5 of 1–9, Small shows 4, **5**, 6;
Medium shows 3, 4, **5**, 6, 7. At workspace 1, Small shows only **1**, 2.
Neighbors follow the sorted existing list even when numbers have gaps. Each
display follows its own active workspace immediately, including external shortcut
switches. Missing active state temporarily shows all; urgent workspaces outside
the selected range stay hidden. The Settings example reflects the draft and is
not live workspace state. Horizontal bars wrap
buttons into rows when space is tight. Vertical bars keep one workspace column
and stack widget icons and values, preserving the configured edge thickness.
If the output is too short for all controls, the vertical bar scrolls along its
length instead of growing wider. Focused window titles
ellipsize and have a full-text tooltip. The title becomes “Pearl” for layer focus,
rather than presenting a previously focused application as current. Keyboard
controls show the active seat's **effective layout name** (a compact two-character
indicator on vertical bars, with the full name accessible and in a tooltip), and clicking cycles
that keyboard group through the adapter's validated action API. With no keyboard
or an ambiguous seat, the control is unavailable.

The bar has configurable start/center/end groups. `GtkCenterBox` centers the
clock when the groups permit it. Narrow outputs hide the optional title and
bar overview button; overview remains available in the control center. Vertical
edges change group orientation. GTK measures the resulting bar thickness for
its exclusive reservation. Each process has one clock timer, aligned to the
next minute, instead of one timer per widget/output. A shared one-second monitor
refreshes after suspend, wall-clock jumps and system time-zone/database changes.
All clocks receive the same sampled UTC instant on a shared refresh.

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
`workspaces`, `title`, `clock`, `keyboard`, `overview` and `control`, plus
`clock:<id>` for clocks already defined in that output's effective `bar.clocks`.
Each clock instance has its own zone, label, format and date setting. Use
Settings → Bar & dock to add/configure clocks persistently; see
[clock preferences](PREFERENCES.md#multiple-time-zone-clocks). The original bare
`clock` remains compatible. All clock buttons open the local calendar and anchor
it to the clicked button. An empty group
is allowed; duplicate items, unknown items and configurations without a launcher
are rejected. All three groups are supplied together. These are **runtime
preferences**: restart or output removal resets them. Persistent preference
editing/migrations belong to T13. Existing `bar set` controls edge/thickness.

The original T06 control center used unavailable service placeholders; the compact
pages above now use live service adapters. Calendar browsing uses `GtkCalendar` and local time;
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

### Calculator

Type an expression such as `12*(3+4)` into the launcher to see `84` before any
matching applications. Enter or clicking the calculation copies the displayed
number to the regular clipboard and closes the launcher. Paste it in the
destination application normally. A failed copy leaves the result open for
retry. Bare numbers and ordinary names remain application/window searches.

A leading `=` selects calculator-only mode: `=42`, `=sqrt(81)`, or `=cos(pi)`.
Typing or pasting a trailing `=` continues the calculation in the entry:
`12*7=` becomes `84`, ready for `+6`; `=sqrt(81)=` becomes `=9`.
Continuation does not copy. Editing or moving the caret while a calculation is
pending cancels the pending continuation; editing also cancels pending Enter.

Supported syntax:

- Decimal numbers with `.`, scientific notation (`1e3`), parentheses, unary
  signs, and `+`, `-`, `*`, `/`, `^`. Powers associate to the right:
  `2^3^2` is `512`, `-2^2` is `-4`, and `2^-2` is `0.25`.
- In explicit mode, constants `pi`, `e` and functions `abs`, `sqrt`, `exp`,
  `ln`, `log` (base 10), `log2`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`,
  `ceil`, `floor`, `round`, `trunc`, and `mod(a,b)`. Names are case-insensitive;
  trig functions use radians. `round` rounds ties away from zero; `mod` gives
  the remainder with the dividend's sign.

Use decimal points without thousands separators or currency symbols. Commas
only separate `mod` arguments. Percentages, `%`, implicit multiplication such
as `2(3)`, units, conversion, variables, and persistent calculation history are
not supported. Incomplete expressions have no actionable answer; explicit mode
explains invalid syntax, division by zero, domain errors, and overflow.

Arithmetic uses approximate `f64` values with up to 15 significant display
digits. Very large/small results use scientific notation; negative zero is
shown as `0`. Copying and continuation use exactly the displayed, rounded text.
Large integers can lose precision and very small values can underflow to zero;
this is not an arbitrary-precision or financial decimal calculator.

The allocation-free evaluator bounds input to 512 bytes, 256 tokens, 32 nested
parser calls, and 256 operations. It runs inside the launcher's existing search
worker, including with an empty application catalog. Calculator activation uses
the same query/session freshness checks as other results and synchronizes
clipboard privacy before copying. Expressions are not logged or persisted.
Only an explicitly copied result enters the existing memory-only clipboard
history. See the [implementation plan](LAUNCHER_CALCULATOR_IMPLEMENTATION_PLAN.md).

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
`output`; `control_show/toggle` also accept validated optional `page`;
`launcher_hide` accepts none. `bar_groups` requires `output`, `left`,
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

## Window switcher

Add **Cycle windows** in **Settings → Bar & dock → Add widget**, then Apply & save.
Each click advances through eligible windows on every workspace and enabled display. Windows
keep a stable order, including across the 1.5-second idle dismissal; the last
window wraps to the first. Obscured windows and separate windows of one app are
included. Minimized windows, `skip_switcher` windows and parents blocked by a
modal dialog are excluded. An empty set disables the button; a sole window can
still be activated on its own workspace and display.

The compositor shows a temporary stack of live window textures and focuses each
selection immediately. It preserves actual window geometry and layout. The HUD
provides Previous/Cycle controls without taking keyboard focus. Escape or typing
dismisses the stack; selected focus remains. Pearl's Reduced motion preference
skips motion for its button/CLI requests. The stack stays on its initiating
display; its label names the destination workspace and display. Selection
activates that destination without moving the window. On idle dismissal, Escape,
typing, or explicit dismissal, the cursor moves into the final window after its
normal scene is restored. Physical pointer motion or an outside click cancels
that handoff. This explicit warp works independently of Mouse follows focus.

```
pearlctl window-switcher next [--output ID]
pearlctl window-switcher previous [--output ID]
pearlctl window-switcher dismiss [--output ID]
```

Global cycling requires both updated Pearl and Aqueous advertising
`global_window_switcher_v1`. With `workspace_switcher_v1` only, Pearl retains
workspace-only cycling, corresponding labels, and the disabled single-window
button. Without either capability the button explains that Aqueous needs an
update. `--output` chooses where to present the global switcher, not which
windows to include. The Aqueous settings helper exposes unbound `window_switcher_next`,
`window_switcher_previous` and `window_switcher_dismiss` shortcut actions. Assign
keys explicitly; `Super+Tab` remains assigned to ordinary `cycle_focus` by default.
To use it for the new switcher, clear `cycle_focus` and assign it to
`window_switcher_next`, with `Super+Shift+Tab` for reverse cycling. Native compositor
bindings use compositor animation support; Pearl's motion preference is sent by
Pearl commands and does not change unrelated native bindings.

See the [global implementation plan](GLOBAL_WINDOW_SWITCHER_IMPLEMENTATION_PLAN.md)
and [native validation](../artifacts/global-window-switcher/README.md).
