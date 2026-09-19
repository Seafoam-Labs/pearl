# Running applications bar widget

Status: implemented, 2026-09-19. The approved design below is now available in
Pearl. Add **Running applications** through the existing bar selection editor;
existing layouts remain unchanged until it is added.

[Native screenshots and validation](../artifacts/running-apps/README.md) record
the ReleaseSafe build, 146 unit tests, 15 widget integration checks and the
Settings, preferences, bar-layout and dock regressions. Display power-off
successfully tears down the chooser and output surfaces. A separate hard-disable
test is blocked by the cached Aqueous compositor's `OutputManager.zig:575`
assertion; its failure log is retained in that evidence directory.

Implementation details: `task_model.zig` owns the pure global snapshot;
`task_apps.zig` adapts the shared GIO catalog and dock matching;
`running_apps.zig` contains the task strip and chooser. Compact bars use an
overlaid count, and long chooser lists append 50 items at a time. The actual
keyboard command follows Pearl's existing CLI conventions:
`pearlctl running-apps show [--output ID]`.

Add **Running applications** to Settings → Bar & dock → Add widget. It presents
one icon per running application, including its windows on inactive workspaces
and minimized windows. Selecting a window brings it into focus where it lives.
The existing dock remains independently configurable.

The [interactive mockup](mockups/running-apps/index.html) shows the widget in a
desktop bar and its placement inside Settings. See the
[mockup guide and captures](mockups/running-apps/README.md).

## Proposed behavior

Scope assumption: “every workspace” includes **all displays**. Every bar that
contains this widget shows the same global application set. The chooser names
both workspace and display so moving focus to another display is explicit.
There is no current-workspace filter in this first version.

| Situation | Behavior |
| --- | --- |
| One window in an application | Primary click activates that window, including switching workspace and restoring it if minimized |
| Several windows | Primary click opens a window chooser with title, workspace, display and state; selecting a row activates that exact window |
| Already focused window | Activation keeps focus; primary click never unexpectedly minimizes it |
| Any application | Secondary click opens the same chooser, including for a single window |
| Focus and count | Highlight the focused application; show a numeric badge only for multiple windows; tooltip and accessible name include the count and states |
| All windows minimized | Hollow running marker; chooser rows explicitly say “Minimized” |
| Limited bar space | Keep a measured subset of icons plus an overflow button labeled with the number of remaining applications; overflow lists every remaining group and expands to its windows |
| No eligible windows | Hide the runtime strip without reserving empty space; retain its Settings entry and schematic preview |
| Cannot activate | Keep the window visible with a disabled action and explanation; do not hide an open application just because activation is unavailable |

Use installed application icons when uniquely matched, then a safe symbolic
fallback. Unknown identity must not merge unrelated windows. Titles are display
text, never application identity or executable commands. Match the dock's
desktop-ID / StartupWMClass rules. Respect `skip_taskbar`, but do not exclude
`skip_switcher`, minimized or non-visible windows. “Every application” means
applications with compositor-reported taskbar windows, not background processes.

Keep groups stable during focus changes. For a running session, preserve first
appearance order; initialize deterministically by display name and stable key.
Append newly seen groups and remove groups only when their last window closes.
Use stable window IDs to preserve chooser selection during updates. Overflow
is presentation only: do not copy the dock's 32-group / 64-window truncation caps.
Use a scrollable, incrementally populated chooser for large collections, with
all IDs retained and reachable. Show actual counts, not capped counts.

The widget inherits bar size, edge, appearance and islands. Top/bottom bars use
a row; left/right bars use a column. Measure the available length after other
bar content, reserve the overflow button before allocating icons, and never
force clock or controls off the surface. At the minimum allocation, use one
“Running applications (N)” button opening all groups. When even this cannot fit,
the bar's existing section scrolling must keep it reachable. Changing focus
does not reorder icons or move the focused group out of overflow.

## Settings integration

- Add builtin token `running_apps` to the existing group grammar and friendly
  metadata: **Running applications** — “Open windows across all workspaces.”
- Make it an optional singleton in the current Add widget picker. Existing
  layouts and defaults stay as saved; the mockup illustrates adding it after
  Workspaces in Left. Users may reorder it or place it in any group.
- Use the existing move/reorder/remove menu and Apply/Discard draft workflow.
  An already placed instance is listed as added, including its current group.
- The schematic preview uses representative icons; it must not subscribe to
  live private window titles merely to preview a preference draft.
- No new preference fields, freeform configuration or permissions are needed.
  Scope is fixed and explained in the picker description/tooltip. The mockup's
  explanatory card is design detail; it does not require a new settings subpage.
- Preserve per-output override behavior: each effective layout decides whether
  that output hosts a widget, while the widget's window source stays global.

Pinning, launching new instances, minimize/maximize/close controls, thumbnails,
dragging windows, custom filters and changing dock defaults are outside this
initial version. The existing dock and Overview retain those separate roles.

## Implementation sequence

### 1. Shared application identity and grouping

Extract the dock's unique application matching into a small shared module
(`src/desktop/task_model.zig`). Keep output eligibility and pins in
dock policy. Give the new grouping path the complete result of
`client.model.windows(allocator, .{ .purpose = .taskbar })`, without output or
workspace filters. The existing reducer already supports this query.

Use owned group keys and window IDs, resolving borrowed window data only within
the current model generation. Inject the manager-owned `Apps.Index` instead of
scanning desktop entries for each bar. Cache an immutable global group snapshot
per model/index generation and share it across bars. Application rescans may
change icons/names/group identity; preserve selection by window ID when possible.
Avoid rebuilding GTK children for unrelated updates or on every clock tick.

Checkpoints: grouping unit tests pass; existing dock matching and per-output
behavior are unchanged. Test ambiguous desktop entries, missing app IDs/classes,
XWayland class matching, null output/workspace and windows moving between them.
Windows with unknown location still appear with “Workspace unavailable.”

### 2. Widget and owned window chooser

Create a bar task-strip view (`src/desktop/running_apps.zig`) and connect
its lifetime to `Bar.create`, `build`, update and clear/destroy. Supply the shared
index/snapshot through `src/ui/surfaces/manager.zig`. Add an event carrying an
owned application key and originating output for a chooser; re-resolve its
members at open time. Use the manager's existing popup placement and dismissal
machinery with a dedicated chooser view. Permit only one shell popup at a time.

Keep the bar's layer-shell keyboard mode **none**, as required by the existing
[navigation policy](SETTINGS_NAVIGATION_PLAN.md#f4--bar-wiring-accessibility-and-handoff).
The chooser is a separately owned, keyboard-capable popup surface; do not rely
on a keyboard popover parented to the unfocusable bar. Tab/arrows navigate rows,
Enter activates, Escape dismisses. Opening a chooser on another output anchors
it to the initiating bar. Clamp all placements to usable output bounds.

Provide a keyboard entry point through the existing pane/CLI routing:
`pearlctl running-apps show --output ID`. With no group selected it opens all applications. This
allows an Aqueous keybinding without focusing the bar. Closing returns input
to the prior surface unless successful activation intentionally changes focus.

Submit the existing typed `window_activate` action using an opaque window ID
and appropriate seat. Validate against the latest model immediately before
dispatch. Let the compositor perform workspace/focus transitions; do not move
the window to the current workspace. Verify minimized restoration and remote
workspace/output activation in the native harness before calling them complete.
The current compositor shell command delegates to `activateShellWindow`.

While a chooser is open, handle window closure/movement and application exit
without retaining borrowed pointers or destroying a live callback. Refresh
rows by ID, choose the nearest surviving row, and show a short empty state if
the group disappears. Cancel stale requests when model/session generation
changes. Failed activation uses existing command feedback; do not optimistically
mark the application focused. Lock, IPC loss, output removal and bar teardown
dismiss the chooser and release input. Resnapshot after reconnect.

### 3. Layout token and selection editor

Add `running_apps` to `src/desktop/policy.zig` and audit every exhaustive `Item`
switch/enum-indexed array. Add localized metadata/icon in
`src/settings/bar_model.zig`; the picker in `bar_view.zig` already enumerates
builtins. Wire the widget in `src/desktop/bar.zig`, including orientation,
allocation, measured input/blur regions and cleanup. Follow existing source
translation conventions for labels, counts, states and fallback names.

Round-trip it through preferences, standalone Settings, live validation, CLI
and per-output layouts. Preserve unrelated preferences and existing launcher
requirements. Old configurations need no migration. Older Pearl binaries will
reject the new token; document removing the widget before downgrading. Update
`docs/PREFERENCES.md`, `docs/DESKTOP.md`, `docs/DOCK_ISLANDS.md`, relevant surface
and CLI docs. Ship Settings and shell token support in the same version.

### 4. Native verification and acceptance

| Check | Acceptance |
| --- | --- |
| Four workspaces, two outputs | Every eligible application appears; group counts include windows across both outputs |
| Cross-workspace and minimized activation | Chosen window restores/focuses on its own workspace/output; unrelated windows are not moved |
| Grouped windows | Duplicate titles remain distinct by ID and workspace/output context; first click opens chooser |
| Filtering | `skip_taskbar` excluded; `skip_switcher` alone retained; unavailable activation remains visible |
| Overflow | More than 32 apps and 64 windows in a group remain reachable; resize across thresholds loses no identities |
| Churn and stale actions | Close/move/rename during popup, app-index refresh, IPC reset and output removal cause no stale callback, focus leak or crash |
| Four edges and scaling | Icons/counts and popup bounds fit at mixed scales, narrow allocations and large text; scroll reaches fallback button |
| Keyboard and accessibility | Bar remains mode none; CLI opens navigable chooser; Escape releases input; names announce app/count/location/state |
| Settings | Add once, move/reorder/remove, preview, Apply/Discard, restart persistence and output overrides work |
| Dock coexistence | Dock pins, cycling, output scope, autohide and keyboard mode behave as before |
| Empty/disconnected/locked | No stale actionable windows or inaccessible blank bar reservation |

Run the build and unit suite, then add a private-session
`test-running-apps` integration target with real windows. Extend the existing
bar editor tests for the new picker item. Run `test-bar-layout`,
`test-settings-bar-editor`, `test-preferences` and `test-dock-islands` regressions.
Capture actual native screenshots on horizontal and vertical bars with a
cross-workspace chooser and overflow. HTML mockup checks alone cannot satisfy
these native acceptance criteria.

## Current repository basis

- `src/desktop/dock.zig`: application matching, grouping, icon resolution and
  validated actions; currently filters windows to its own output.
- `src/desktop/dock_policy.zig`: `skip_taskbar` / output eligibility and separate
  dock visibility policy.
- `src/aqueous/reducer.zig`: global taskbar query and authoritative window IDs.
- `src/aqueous/entities.zig`, `commands.zig`: workspace/output metadata,
  minimized/focused/capability fields and typed activation validation.
- `src/desktop/bar.zig`, `src/ui/surfaces/manager.zig`: bar layout, manager-owned
  application index and popup surface lifecycle.
- `src/settings/bar_model.zig`, `bar_view.zig`: selection-based editor and metadata.

The main implementation risks are fitting a variable-length widget alongside
existing groups, preserving callback ownership during live updates, and correct
focus handoff across outputs. Steps 1–2 should establish those behaviors before
polishing the Settings presentation.
