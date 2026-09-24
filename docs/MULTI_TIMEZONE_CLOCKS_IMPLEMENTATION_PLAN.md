# Multiple time-zone clocks on the bar

Status: implemented September 24, 2026. The sections below retain the design
and implementation scope. Native acceptance evidence is recorded in
[the verification report](../artifacts/multi-timezone-clocks/README.md).

Implementation notes:

- Clock policy, GLib conversion/discovery and GTK content live in
  `clock_policy.zig`, `clock_time.zig` and `clock_view.zig` respectively.
- The clock editor provides both searchable city/zone choices and direct zone
  entry, a draft preview, and the existing Apply/Discard workflow.
- One shared minute timer updates all clocks from one UTC instant. One shared
  one-second monitor detects resume/time jumps and changes to `/etc/localtime`
  and installed zone data, then refreshes cached zones and realigns the timer.
- Saved unused definitions have a Delete saved clock action below the widget
  groups. Re-adding them is available in the normal picker.
- Verification also exposed an existing startup GTK warning: wallpaper stack
  selection now occurs after its named children are added. Popup focus is cleared
  before disabling/destroying a focused editor to avoid GTK focus warnings.
- Clock views participate in workspace width allocation. Labels and dates can
  ellipsize on narrow outputs while the time stays readable.

## Intended behavior

Users can add several Clock widgets in **Settings → Bar & dock**, choose a time
zone and optional label for each, and move each clock independently between the
bar's three groups. Existing installations retain their single local clock and
its current appearance.

- Offer **System local time**, **UTC**, and searchable named time zones such as
  `America/New_York`, `Europe/London`, and `Asia/Tokyo`.
- Store named zones, not their current UTC offsets, so seasonal changes follow
  the installed time-zone database.
- Each clock has an optional label, a 12/24-hour choice, and a Show date toggle.
  Preserve 24-hour time and the visible date for the existing clock. New clocks
  default to 24-hour time without the date, with a city-derived display label.
- Example horizontal bar: `Thu 24 Sep · 09:30   London 14:30   Tokyo 22:30`.
  Each clock uses its own date, including when zones fall on different days.
- Full tooltips and accessible descriptions identify the zone, date, time and
  current UTC offset. Empty custom labels use a readable zone name for added
  clocks; the unchanged default clock needs no new visible label.
- Support all four bar edges. Side bars stack the label and time within the
  existing thickness. Labels may ellipsize; the time remains readable.
- Keep the current calendar action: clicking any clock opens the existing local
  calendar, anchored to that clock. Identify the action as “Open local calendar”
  in its accessible description/tooltip. A calendar following the clicked zone
  is outside this first release.
- Add, edit, reorder and remove operations update the shared draft. Apply & save
  updates the desktop; Discard restores the saved state. Closing a clock editor
  with Cancel leaves the draft unchanged.
- The visual editor continues to edit the default bar. Per-display overrides
  remain editable through Advanced and retain precedence.

## Existing implementation and constraints

- `src/desktop/policy.zig`: `Groups.validate()` accepts singleton built-ins and
  plugin references; duplicate `clock` tokens are currently invalid.
- `src/config/preferences.zig`: each `Bar` owns its groups; `outputs[].bar` is a
  complete override, not a field-by-field merge with the default bar.
- `src/desktop/bar.zig`: one `clock` label, one `clock_date` label and one widget
  slot implement the clock. `tick()` samples local time and formats fixed text.
- `src/ui/surfaces/manager.zig`: one minute-aligned timer refreshes bars across
  outputs. Existing popup anchoring tracks the clicked widget.
- `src/settings/bar_model.zig` and `bar_view.zig`: ordered string references,
  atomic draft patches, widget action menus, stale-menu rejection and focus
  restoration already support the required editing pattern.

## Configuration and identity

Keep version 1 preferences and comma-separated groups. Add `bar.clocks`, an
array of definitions scoped to that `Bar`; output overrides own their own array.
The following is a partial preference example:

```json
{
  "bar": {
    "groups": {
      "left": "launcher,workspaces,title",
      "center": "clock,clock:london,clock:tokyo",
      "right": "control"
    },
    "clocks": [
      { "id": "local", "timezone": "local", "label": "", "hour_format": "24h", "show_date": true },
      { "id": "london", "timezone": "Europe/London", "label": "London", "hour_format": "24h", "show_date": false },
      { "id": "tokyo", "timezone": "Asia/Tokyo", "label": "Tokyo", "hour_format": "24h", "show_date": false }
    ]
  }
}
```

- Bare `clock` resolves the reserved `local` definition, or an implicit legacy
  default if that definition is absent. Its configured zone may be changed;
  `local` is its stable identity, not a restriction on its zone.
- Added clocks use `clock:<id>`. Reject `clock:local` so the reserved instance has
  one spelling. IDs survive zone/label edits and reordering; Settings generates
  them independently of the display label.
- Omitted `clocks` defaults to an empty array. Opening old preferences performs
  no migration or write. Named references require matching definitions.
- Allow the same zone on different instances, but reject duplicate definition
  IDs and duplicate placement of one instance across a bar's groups. Keep all
  existing singleton/plugin rules and the required Launcher rule.
- Bound each bar to eight definitions/instances, counting the implicit default
  when present. Limit IDs to 32 ASCII letters, digits, underscores or hyphens;
  labels to 64 UTF-8 bytes without control characters; zones to 128 bytes.
  Retain existing group and document size limits.
- Removing a placement retains its definition. The picker offers unplaced saved
  clocks for re-adding, and a Delete saved clock action for unused definitions.
  At the limit, explain how to remove an unused saved definition.
- Pure validation checks syntax, bounds and reference integrity. Resolve zones
  separately against installed zone data. A missing zone in an otherwise valid
  saved document must not invalidate all preferences or silently show local time.
- Newly configured unavailable zones receive an inline error before commit.
  A zone becoming unavailable later renders `—` with its label and an explanatory
  tooltip; other clocks continue working. Retry after relevant data/config changes.
- Older binaries use strict parsing and will reject the new fields/references;
  document this downgrade limitation rather than promising forward compatibility.

## Implementation sequence

### 1. Model, validation and persistence

Create `src/desktop/clock_policy.zig` for definition types, defaults, bounds and
reference parsing. Extend group validation to accept named clocks, and add
definition/reference cross-validation to preference validation for both default
and output bars. Keep GTK and filesystem-dependent zone resolution outside the
pure preference model.

Audit every consumer of group tokens, including CLI/protocol validation, DMS
import, Settings previews, widget enumeration and layout reports. Use a common
reference parser to distinguish built-ins, clocks and plugins. Legacy imported
clocks remain bare `clock`. The existing `bar groups` command can place configured
instances; reject unresolved references before replacing the active layout.

### 2. Zone discovery and time formatting

Add a runtime helper using the already vendored GLib `TimeZone.newIdentifier`
and `DateTime.toTimezone` bindings. Restrict selections to local, UTC and installed
named zones; do not accept arbitrary POSIX expressions or filesystem paths.
Build a bounded searchable catalog from installed zone tables, with city and
identifier search. Resolve valid saved aliases even if absent from the picker.
Local and UTC remain available when catalog discovery fails.

Convert one sampled UTC instant to every configured zone for each refresh.
Pass an explicit instant into formatting helpers so tests do not depend on the
wall clock. Cache named zone objects, define ownership, and release them when
configuration changes or bars are destroyed. Refresh the local zone when the
system zone changes; reload cached named zones when installed zone data changes.
Never alter the process-wide `TZ` environment.

### 3. Render and refresh multiple instances

Replace the singleton clock label fields with an owned collection of clock
views keyed by reference. Each view owns its button, labels and resolved zone.
Route bare `clock` and named references through the same renderer. Retain the
built-in widget array for other singleton widgets and audit callers that assume
the clock lives in that array. Include each clock separately in layout reports.

Pass the effective clock definitions together with groups from the surface
manager. Changes to zone, label or format must refresh the bar even when group
strings are unchanged. Preserve correct cleanup on rebuild, orientation change,
output removal and failed construction; dismiss popups before destroying anchors.

Retain one shared minute timer across all outputs; do not create a timer per
clock. Refresh immediately after Apply, bar creation, resume, system-time changes
and system-zone changes, then realign the timer. Inspect existing service signals
and use them where available; otherwise add a shared bounded monitor rather than
polling once per widget. Preserve the existing non-clock work in `Bar.tick()`.

Check allocation on narrow horizontal bars and side bars. Use compact time and
bounded labels within the existing layout/scroll behavior, preserving access to
Launcher and other controls. Do not introduce a separate overflow redesign.

### 4. Settings editing

Keep Clock available in Add widget after one is placed. Offer Add another clock
and any saved, unplaced clocks. A small editor presents Time zone, Label,
12/24-hour format and Show date, with a clearly labeled example preview.

Extend `bar_model.zig` with atomic create/edit/delete-definition operations.
Creating a clock adds its definition and placement in one validated patch.
Instance rows show a friendly label and zone and use stable reference IDs for
focus, accessibility, menus and test hooks. Reuse move/remove actions, draft
conflict detection and Apply/Discard. Preserve unrelated preferences and every
output override. Add translations following the existing Settings conventions.

### 5. Verification and documentation

- Pure tests: legacy defaults, serialization, distinct instances, same-zone
  instances, duplicate/unknown references, bounds, saved unplaced definitions,
  atomic edits and output override isolation.
- GLib-backed tests with fixed UTC instants: different dates across zones,
  spring/fall DST transitions, non-hour offsets, UTC, local-zone changes,
  12-hour midnight/noon and unavailable-zone behavior. Follow the existing
  `night_light_clock_tests.zig` build pattern.
- Extend Settings integration coverage for add/edit/reorder/move/remove/re-add,
  cancel, Discard, Apply, persistence after restart, invalid zones, stale editors,
  focus restoration and keyboard accessibility.
- Extend bar layout coverage for all edges, large text, long labels, several
  clocks, islands/continuous bars and calendar anchoring. Verify multi-output
  overrides, hotplug, repeated rebuilds and resume/time-change refresh.
- Run the pure and GLib-backed targets plus `test-settings-bar-editor` and
  `test-bar-layout`; run affected popup/autohide checks when anchor handling
  changes. Capture representative horizontal and vertical screenshots.
- Update `docs/PREFERENCES.md`, `docs/DESKTOP.md` and CLI help for named clock
  references, configuration bounds, local-calendar behavior and downgrade limits.

## Completion criteria

A user can place local, London and Tokyo clocks, configure and move each through
Settings, Apply, restart Pearl and retain the result. Every clock reflects its
own zone/date at the same instant, including DST boundaries. Existing preference
files retain the original local-clock behavior; display overrides remain isolated.
All clock views have correct labels, accessible actions and cleanup, with one
shared refresh schedule and no regressions to other bar widgets.
