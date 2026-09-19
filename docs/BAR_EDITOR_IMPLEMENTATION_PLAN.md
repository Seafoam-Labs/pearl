# Selection-based bar editor

Status: implemented, September 19, 2026. The native Settings app now uses
selection menus and ordered widget groups. The original browser mockup remains
a design reference. [Native screenshots and validation](../artifacts/bar-editor/README.md)
record the implementation and regression limits.

## Implementation checkpoint

- Added the pure `bar_model.zig` adapter and native `bar_view.zig` component.
- Replaced the standalone group text fields, retained exact edge/size/islands
  controls, and placed Dock/Flyouts controls in expandable sections.
- Connected atomic layout changes to the existing shared `Editor`, including
  stale-menu rejection, invalid-draft repair, focus restoration and announcements.
- Added the optional bounded `bar_widgets` snapshot capability and fresh plugin
  approval checks. The legacy widget text fields now link to the standalone page.
- Added `test-settings-bar-editor`, updated the affected services test, and
  documented the preference and frontend API contracts.

Native menus use GTK popovers. Add buttons sit above each group so they remain
reachable before a long widget list. GTK wraps the group cards to fit the window;
the existing appearance controls precede the schematic preview. These are
presentation adaptations of the mockup, with the same selection and draft flow.

## Outcome and design

In **Settings → Bar & dock**, replace the three comma-separated widget fields
with ordered selections. Users add a named widget, move it between groups,
change its order, or remove it without knowing internal identifiers.

Open the [interactive Settings mockup](mockups/bar-editor/index.html), or see the
[page](mockups/bar-editor/desktop.png), [Add widget menu](mockups/bar-editor/add-widget.png),
and [widget actions](mockups/bar-editor/widget-actions.png).

The page keeps Settings' sidebar, typography, rounded cards, accent color and
shared preference footer. Its content is:

1. **Bar preview:** a schematic of the current draft. Selecting a preview group
   focuses its editor. The preview never changes the desktop before Apply.
2. **Bar appearance:** edge selection, exact size control (32–160 px), and
   Separate islands toggle. Existing valid sizes are retained, including values
   between suggested presets; no rounding on open or save.
3. **Widgets:** Left, Center and Right cards, each containing an ordered list
   and an **Add widget** button. Empty groups show an explicit empty state.
4. **Dock** and **Flyouts:** collapsed sections retain the existing controls;
   changing widget editing must not drop their settings.
5. The existing **Discard / Apply & save** footer applies to the complete Pearl
   preference draft, including edits from Appearance and Plugins.

For left/right edges, label the groups **Top / Center / Bottom**, map those labels
to the existing `left / center / right` fields, and show top-to-bottom ordering.
Use the same ordered lists for all four edges. This matches the renderer's group
order; do not reverse stored widget order for bottom or right edges.

## Menu behavior

**Add widget** opens a labeled, keyboard-accessible picker with a destination
group selector and optional search. Every built-in has a friendly name, icon
and brief description. Available widgets are actionable; widgets already placed
are shown separately with their current group and cannot be added twice.
Selecting an available widget appends it to the selected group, closes the
picker, focuses the new row, and marks the shared draft dirty. Cancel/Escape
closes the picker without changes and returns focus to its trigger.

Each row has an **Actions for [widget]** button. Its menu offers:

| Action | Result |
| --- | --- |
| Move earlier / Move later | Swap adjacent items in the current group; disable at boundaries. |
| Move to Left / Center / Right | Move once, appending to the destination. Use Top/Bottom for vertical bars. |
| Remove from bar | Remove the placement; leave plugin installation, enablement and grants alone. |

Launcher is labeled **Required**. Its Remove action is disabled with an
explanation, but it can be reordered or moved between groups. It must remain
present exactly once across all three groups. Use accessible menu actions as
the first-release ordering method; optional drag-and-drop can follow later.

There are 15 current built-ins in `desktop.policy.Item`: Clipboard, Launcher,
Workspaces, Window title, Clock, Keyboard layout, Overview, Control center,
Sound, Battery, Network, Bluetooth, Notifications, Media and System tray.
Keep stable enum identifiers behind these display names. A temporarily absent
battery, audio device or media player must not delete its saved placement.

## Scope and compatibility

The first release edits the **default bar layout**, exactly as the current
standalone form does. State this above the editor: display overrides continue
to take precedence and are edited in Advanced. Preserve every `outputs[]`
entry and dock override when changing the default bar. A per-display visual
editor is a separate follow-up, not a prerequisite for replacing text fields.

Keep version 1 preferences and their comma-separated storage format. Translate
to ordered widget references for presentation and serialize at the draft
boundary. Opening the page is read-only; it must not rewrite the file, migrate
values, insert defaults into saved data or change plugin placement.

The native implementation starts in
[`src/settings/preference_pages.zig`](../src/settings/preference_pages.zig),
where all three groups are currently `Spec.kind = .text`. The older
[`src/desktop/settings.zig`](../src/desktop/settings.zig) also has two text fields,
but is not the standalone app's form. Audit its active entry points during
implementation; if still user-reachable, share the same selection component
or direct users to the standalone Bar & dock route. Do not leave a second,
inconsistent primary editing workflow.

## Draft model and invariants

Introduce a pure `src/settings/bar_model.zig` adapter with parse, add, remove,
reorder, move and serialize operations. Reuse
[`Groups.validate`](../src/desktop/policy.zig) as authority:

- No duplicate built-ins or plugin references across the three groups.
- Exactly one Launcher; other groups may be empty.
- Each serialized group is at most 512 bytes, with at most 16 plugin references
  in the whole layout. Count bytes, including commas, before accepting a change.
- Only known built-ins and syntactically valid `plugin:ID/WIDGET` references.
- Validate the entire candidate before publishing a local edit. On failure,
  preserve the previous selection and give a useful explanation.

A cross-group move must patch **both groups in one document edit**. Sending
two field edits would temporarily create a duplicate or missing Launcher.
Read from the latest `Editor.text()`, preserve unrelated fields, validate the
candidate, then call `Editor.edit()` once. The existing debounce, revision and
upload machinery remains responsible for backend synchronization.

Render from the shared draft rather than a separately persisted UI model.
Acknowledgments must not reset focus, close a picker or overwrite newer edits.
After navigation, reconstruct from the current draft and restore focus/scroll
where possible. Invalid Advanced JSON should show a repair message with a link
to Advanced and disable structured mutations; never silently replace it with
defaults or discard unrecognized values.

Apply uses the current backend validation and atomic persistence path. Surface
save failures without losing edits. External revision conflicts use the existing
review/merge flow; arrays and scalar group strings retain current merge semantics.
Discard restores the whole Pearl draft, as it does today. Lock/disconnect makes
editing unavailable according to `Editor.editable()` and retains draft state.

## Plugins

Preserve all valid plugin references, even if discovery is incomplete, the plugin
is disabled, its package is missing, or it currently uses a desktop overlay.
Show an explanatory status and retain reorder/move/remove actions for existing
placements. Use the reference as a fallback label when metadata is unavailable.
Removing a placement is not an uninstall or permission change.

Offer newly addable plugin widgets only when discovered, approved, enabled and
eligible for bar placement. Route setup/approval to the existing Plugins page.
Revalidate eligibility when a picker action is activated after a catalog update.
Reuse backend plugin snapshots; the frontend must not inspect package files or
start a second plugin host. The current `PluginInfo` has package metadata but no
general widget catalog. Current Settings placement creates `/main`; explicitly
model that supported widget first rather than inventing other widget IDs.
If accessing plugin data from the Bar route requires a protocol extension,
make it optional and capability-gated. Older backends still expose built-ins
and preserve existing references without promising plugin discovery.

Coordinate with [`src/plugins/placement.zig`](../src/plugins/placement.zig):
enabling a plugin or explicitly choosing Add to bar can append a placement to
default and output-specific layouts. Ordinary Bar edits must not invoke that
helper or re-add a removed widget. Keep its explicit enable/add behavior and
verify that it respects placements already moved to another group.

## Implementation sequence

| Step | Work and affected files | Completion evidence |
| --- | --- | --- |
| 1. Model | Add `bar_model.zig`; define builtin presentation metadata keyed by `policy.Item`; implement lossless order/reference conversion and atomic operations. | Pure tests for moves, limits, defaults, plugin preservation and invalid input. |
| 2. Native editor | Add `bar_view.zig`; replace only the three text specs in `preference_pages.zig`; integrate creation, update and destruction in `window.zig`; style via `resources/settings-layout.css`. | Three groups, picker, row actions, empty/required states and edge-aware preview work through real GTK input. |
| 3. Shared draft | Connect one-candidate mutations to `editor.zig`; handle acknowledgments, invalid Advanced drafts, Apply/Discard, conflict and offline states. | Navigation and Advanced edits stay synchronized; cross-group moves never send invalid intermediate documents. |
| 4. Plugin and legacy parity | Connect existing plugin metadata or add a bounded optional snapshot capability in `live_protocol.zig`/backend; check plugin placement helper interactions; resolve reachable legacy form. | Missing/disabled plugins survive unrelated edits; explicit plugin enabling does not duplicate placements; legacy entry points agree. |
| 5. Acceptance | Extend Settings control reporting in `window.zig` for group/widget/action IDs; add targeted native integration coverage; update `docs/PREFERENCES.md` and affected frontend API docs. | Keyboard, narrow layouts, themes, persistence and runtime bar regression evidence below. |

## Acceptance criteria and validation

- A user can add Bluetooth, move Clock to Right, reorder it, remove Bluetooth,
  and Apply without typing a widget identifier. Reopening shows the saved order.
- Launcher cannot be removed; moving it across groups succeeds atomically.
  Used widgets cannot be added twice. Empty Center/Right groups remain valid.
- Round-trip existing defaults, custom group order, empty groups and valid
  unavailable plugin references. Test byte/count boundaries and full groups.
- Unrelated Appearance, dock, plugin and output-specific settings survive each
  operation. Existing display overrides still take precedence after Apply.
- Preview responds to groups, edge, size and islands. Verify all four edges in
  the actual bar; the mockup's preview is schematic, not a renderer oracle.
- Navigate away/back, edit Advanced, discard, apply, simulate a failed save and
  an external conflict, lock/reconnect, and refresh plugin discovery with a menu
  open. No stale menu action may overwrite a newer draft or target another row.
- Keyboard-only add/move/remove; accessible widget/action names, group and
  position announcements, restored focus, Escape dismissal and disabled reasons.
- Narrow window, enlarged text, light/dark/native GTK and reduced-motion review.
  Stack group cards when necessary; never require horizontal scrolling to edit.
- Add a focused `test-settings-bar-editor` integration target. Run project pure
  tests plus affected `test-settings-app`, `test-settings-appearance`,
  `test-settings-presentation`, `test-preferences`, `test-bar-layout` and
  `test-dock-islands` targets during native implementation. Include plugin
  placement tests when wiring metadata and enablement interactions.

The HTML prototype demonstrates the design with sample data. Its
[verification](mockups/bar-editor/verification.json) covers that mockup only.
Native tests and actual Settings captures are recorded separately in the
[implementation evidence](../artifacts/bar-editor/README.md).
