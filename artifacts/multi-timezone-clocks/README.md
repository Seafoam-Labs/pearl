# Multiple time-zone clocks verification

Implemented and verified September 24, 2026. See the
[implementation plan](../../docs/MULTI_TIMEZONE_CLOCKS_IMPLEMENTATION_PLAN.md)
and [user documentation](../../docs/PREFERENCES.md#multiple-time-zone-clocks).

## Results

- Production build and standalone Settings build passed.
- `zig build test test-bar-clock`: **194 tests passed** (189 pure tests and
  5 GLib-backed tests). Covers legacy preferences, atomic edits, output isolation,
  bounds, DST gaps/folds, non-hour offsets, different dates, 12-hour noon/midnight,
  unavailable zones, aliases, discovery and local-zone changes.
- `zig build test-settings-bar-editor`: **20 checks passed**, including clock
  creation, editing, cancel, invalid zones, reordering/moving, remove/re-add,
  deletion of unused definitions, Apply/Discard, stale editor rejection, and
  persistence after restarting both Pearl and Settings.
- `zig build test-bar-layout`: **55 cases passed**. Includes multiple clocks on
  all edges, islands/continuous bars, long labels with large text on an 800-pixel
  output, definition-only changes, unavailable zones, independent output
  overrides and calendar activation from individual clocks.
- `zig build test-bar-autohide`: **21 checks passed**, including popup holds,
  session inhibition, output removal, remapping and clean shutdown.
- Python integration files compile and `git diff --check` passes.

Builds used `--global-cache-dir .cache/zig-global` because the ordinary global
cache is read-only in the workspace sandbox. Desktop checks ran in private
D-Bus/Wayland sessions with isolated XDG directories and fatal GTK warnings.
The test environment needed sandbox escalation to create those private sockets.

[Build/unit output](build-and-unit-tests.log),
[Settings results](settings/metadata.json),
[layout results](layout/metadata.json),
[autohide results](autohide-final/report.json).

## Screenshots

- [Clock editor and preview](settings/session/clock-editor-london.png)
- [Horizontal clocks](layout/session/clocks-top-islands.png)
- [Vertical clocks](layout/session/clocks-left-islands.png)
- [Narrow output with large text](layout/session/clocks-narrow-large-text.png)

## Regression findings and limits

The acceptance run exposed an existing wallpaper initialization warning:
`GtkStack` selected a named child before adding it. Selection now happens after
construction. Clock editors also release focus before disabling or destroying a
focused popup, preventing a GTK focus-out warning during concurrent draft edits.

The autohide test asserted that a window was unmapped immediately after inhibition,
but the existing renderer finishes its 180 ms fade asynchronously. The test now
checks immediate sensor suppression and waits up to two seconds for window
unmapping. No autohide production behavior was changed.

The narrow-output case exposed an omitted clock measurement after replacing the
singleton widget slot. Workspace allocation now includes all clock views; dates
and labels may ellipsize while time remains readable and primary controls stay
onscreen.

No host clock or host time zone was changed. DST/local-zone conversion uses fixed
instants and process-local test settings. Physical suspend and an actual system
time-zone database update were not exercised. The existing layout suite skips
its optional output-management hotplug case because the pinned compositor has a
known assertion there; output removal/remap is covered by the autohide suite.
