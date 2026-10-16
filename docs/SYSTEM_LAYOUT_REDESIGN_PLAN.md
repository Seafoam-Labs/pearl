# System layout redesign plan

Status: native Zig/GTK layout implemented October 15, 2026. See the
[native captures and validation report](../artifacts/system-layout/README.md).
The specification below records the design and acceptance scope; the report
distinguishes passing checks from broader suite failures and manual checks.

Bring Settings → System into the visual family of the recent Appearance and
Assistant updates: a clear status card, visible primary choices, compact
secondary details, and consistent spacing. The main sequence becomes **see what
is running → choose a scheduler → choose a mode → apply**.

Review the [dark desktop](mockups/system-layout/desktop.png),
[light desktop](mockups/system-layout/light.png),
[390 px layout](mockups/system-layout/narrow.png),
[expanded details](mockups/system-layout/details.png), and
[state examples](mockups/system-layout/states.png).
The [mockup guide](mockups/system-layout/README.md) includes editable SVG assets
and the Zig generator.

## Scope and reference

Use the implemented [Appearance](../artifacts/appearance-redesign/README.md) and
[Assistant](../artifacts/assistant-layout/README.md) pages as the reference, along
with [`settings-layout.css`](../resources/settings-layout.css). Keep the existing
sidebar, System route, page header, content scroller, theme support, and footer.

The previous [`sched_ext_view.zig`](../src/settings/sched_ext_view.zig) spread
status, two dropdowns, dependency information, resolved arguments, a full-width
apply button, a separate stop card, and boot information down the page. Give
these elements clearer priority without introducing unrelated system settings.
Keep the exact scheduler names; the catalog has no reliable human-readable
descriptions or performance rankings.

This is a native Zig/GTK presentation change. No preference schema, scheduler
protocol, command policy, package installation, boot editor, performance graph,
or benchmark is needed. The original
[scheduler implementation plan](SCHED_EXT_IMPLEMENTATION_PLAN.md) remains the
reference for the backend contract.

## Page structure and control inventory

| Area | Proposed presentation | Existing behavior retained |
| --- | --- | --- |
| Currently running | Prominent scheduler name or Kernel default, observed mode/detail, text status badge, Refresh, secondary Use kernel default action | Runtime state is separate from the pending choice; kernel/loader disagreements remain visible; stopping is gated by `can_stop` |
| CPU scheduler | Full-width installed-scheduler dropdown, concise installed count, local selection status | Dynamic catalog, exact names, installed executables only, selection remains local |
| Mode | Wrapping native radio tiles for the available Auto, Gaming, Low latency, Power saver, and Server modes | Only modes with non-null argument arrays are selectable; empty arrays remain valid |
| Apply scheduler | Primary button at the end of the selection card, with operation feedback directly below | Existing apply request, one operation in flight, already-applied and unavailable gating |
| Scheduler details | Collapsed summary with installed/missing counts; expanded selected mode arguments and missing executable names | Selectable JSON argument arrays preserve boundaries; missing dependencies remain inspectable |
| Startup configuration | Collapsed summary naming the configured boot scheduler and mode; read-only details inside | Runtime operations never edit loader boot configuration; null scheduler and unknown mode remain explicit |
| Footer | Existing fixed System instruction; existing retained-draft badge/review path when relevant | Global Apply & save / Discard remain hidden on System; drafts from other pages survive navigation and runtime operations |

Move Use kernel default into the status card, where its effect is clear. It stays
a neutral, explicitly labeled action and never becomes a mode tile. At narrow
widths it moves below the status text. Do not add a confirmation dialog or any
new privileged action to this layout update.

## Visual layout

Use 16 px card corners and gaps, approximately 20 px card insets, and the existing
30 px desktop / 16 px narrow body margins. Match the title hierarchy and native
radio treatment in Appearance and Assistant. Use theme tokens with GTK fallback
styling; the lavender mockup palette is illustrative, not new application CSS.
Keep readable secondary text and approximately 44 px interactive targets.

The current-state card leads with a small “Currently running” label, a larger
observed scheduler name, and its mode or raw status detail. A compact badge says
Running, Kernel default, Checking, or Unavailable as appropriate. Use text and
accessible state, not color alone. Avoid implying that installed means running
or that a selected mode has already been applied.

The selection card uses one scheduler dropdown instead of one card per binary.
Below it, show available mode tiles in a wrapping grid. Three columns at a wide
viewport and a single column at 390 px illustrate the target; GTK measurement
must determine wrapping for other widths and enlarged/translated text. Do not
force five tiles into one row. Use native grouped check buttons with a clear
checked indicator and keyboard focus. Mode labels describe the configured mode,
not a promised improvement in latency, battery life, or throughput.

Place the selected mode's explanation immediately below the group. Preserve the
three meanings: configured arguments, Auto with scheduler defaults, and a named
mode with no distinct arguments. Keep the last case visible without expanding
details. Show “Not applied”, “Currently applied”, or operation feedback near the
action. Keep “Applies now to all applications. Boot settings stay unchanged.”
visible before Apply scheduler, including on narrow windows.

Scheduler details and Startup configuration start collapsed and remember their
expansion state for the window lifetime. Opening them never runs a command or
changes the local selection. Summaries update from existing snapshots. Missing
binaries appear in the details summary; blocking errors stay visible beside the
affected action and can reveal details without stealing keyboard focus.

At 390 px, stack status actions, labels, mode choices, and selection feedback.
Allow names, JSON, boot summaries, and errors to wrap without horizontal
scrolling. Full values remain selectable. Use the existing Sections menu and
one body scroller above the fixed, wrapping footer. Do not copy SVG card heights
into GTK size requests. Retain navigation icons; the drawings omit them.

## State and action rules

Scheduler and mode selections are **local runtime selections**, not Pearl
preference edits. They do not dirty the shared draft. Only Apply scheduler or
Use kernel default submits a mutation. Refresh remains read-only. Keep existing
page-entry discovery, status polling, generation checks, and service ownership.
Expanding details or moving focus must not trigger additional service work.

| State | Presentation and action behavior |
| --- | --- |
| Initial loading or refresh | Label cached values as last observed until revalidated; prevent competing commands. Background refresh preserves local selector focus and open dropdowns. |
| Kernel default confirmed | Show Kernel default only when loader status is stopped and kernel sched-ext is disabled. Disable Use kernel default. |
| Managed scheduler running | Display observed name and mode/detail. Enable Use kernel default only when the snapshot permits it. |
| Selected values match runtime | Show Currently applied and disable Apply using existing `matches()` semantics, including own-defaults behavior. |
| Different selection | Keep runtime unchanged; show Not applied and enable Apply only when existing eligibility checks pass. |
| Applying or stopping | Keep selected values visible, disable competing commands, and show progress beside the initiating action. Locally submitted operations also freeze selectors until their receipts settle. Do not claim success until the reconciled snapshot confirms it. |
| Missing scxctl, unsupported config interface, no installed scheduler, or missing kernel support | Show the specific backend explanation prominently; gate mutations with existing snapshot flags. Refresh remains available when connected and idle. |
| Some binaries missing | Show installed count in the selector and missing count in the details summary. Keep installed choices usable when the service permits. |
| Loader denied/unavailable, unknown runtime, or external scheduler | Show unavailable/unknown state and original detail; never substitute Kernel default. Preserve backend mutation and stop eligibility. |
| Failure or uncertain outcome | Preserve the selected values and show failure plus observed state. Offer Refresh before a deliberate retry; no automatic mutation retry or assumed rollback. |
| Disconnected, suspended, locked, or older backend without scheduler data | Keep status readable with the existing connection/backend explanation. Disable actions until the existing editor gates permit them again. |

Retain valid selections and focus through refresh and page navigation. When a
scheduler disappears or its selected mode is removed, mark the choice unavailable
and disable Apply rather than silently choosing a replacement. Changing the
scheduler keeps the existing Auto reset; if Auto is absent, require an explicit
available mode choice. Never infer a mode for unknown/custom running arguments.

Use the existing typed snapshot and raw summary/feedback; it contains no separate
structured dependency-health fields. Do not infer readiness by parsing localized
summary strings or add invented “all checks passed” indicators. Use `pending`,
`available`, `can_stop`, status, kernel state, and catalog data where applicable.

Keep administrator access handling in the existing backend. A layout change
must not add sudo, pkexec, shell evaluation, direct binary launch, or automatic
service setup. Closing Settings does not undo an applied scheduler. Discarding
preferences on another page does not undo it either.

## Implementation sequence

1. **Restructure the existing view.** In `sched_ext_view.zig`, create the status
   and selection cards plus two disclosures. Relocate Refresh and Use kernel
   default without changing their callbacks. Keep the existing selection,
   render-arena, snapshot and lifecycle ownership. Scope new styling under a
   System page class in `resources/settings-layout.css`.
2. **Replace mode presentation.** Build grouped native radios from the current
   scheduler's non-null mode arrays. Preserve enum mapping, Auto reset, empty
   argument behavior, stale selection handling and `m.matches()` eligibility.
   Use the Assistant keyboard-navigation pattern where FlowBox wrappers require
   explicit arrows/Home/End handling. Disconnect rebuilt and destroyed controls.
3. **Connect summaries and feedback.** Derive observed state from existing typed
   fields, keep selected state separate, and render missing counts, exact JSON
   arguments and read-only boot defaults in the disclosures. Preserve backend
   errors and expose pending/failure state beside both Apply and Stop. Translate
   new copy into English and German.
4. **Preserve window integration.** In `window.zig`, keep System's footer and
   preference-action visibility rules. Retain `sched-ext/scheduler`, `/apply`,
   `/stop`, and `/refresh` reporting. Update the former `sched-ext/mode` dropdown
   diagnostic deliberately to report the mode group and stable per-mode controls;
   migrate harness consumers together rather than pretending radios are a dropdown.
   Report disclosure toggles for native layout tests.
5. **Validate the native page.** Extend the existing scheduler integration
   harness for actual radio/disclosure input and responsive captures. Record
   native evidence under `artifacts/system-layout/README.md`, separate from
   these static proposals. Keep the backend and protocol unchanged unless a
   separately documented defect is discovered.

## Acceptance and verification

- At comparable viewport and text scale, System matches Appearance and Assistant
  in card spacing, typography, selection state and footer alignment. Current
  runtime, pending choice and configured boot default cannot be mistaken for
  one another. All controls in the inventory remain reachable.
- Selecting a scheduler/mode, opening details and navigating submits no mutation
  and creates no preference draft. Apply sends exactly one existing request with
  scheduler, mode and generation. Stop uses its existing eligibility checks.
- Fixture tests cover all five modes, absent versus empty mode arguments, custom
  runtime arguments, already-applied selection, catalog removal/change, missing
  dependencies, external/unknown state, denial, pending/double-click, failure,
  timeout, stale generations, lock, disconnect and reconnect.
- Change an Appearance preference, visit System, select and apply a scheduler,
  then return. The preference draft is retained; saving/discarding it cannot
  apply or revert the scheduler. Closing/reopening Settings preserves observed
  runtime while rebuilding the selection from established initialization rules.
- Refresh preserves valid selection and keyboard focus. Rebuilding a mode group
  cannot leave callbacks pointing into freed widgets or trigger an apply.
- Keyboard-only users can reach navigation, Refresh, Stop, scheduler, all mode
  radios, disclosures, Apply and any retained-draft review action. Screen readers
  receive selected/expanded/disabled states and useful status feedback without
  repeated announcements from unchanged polling snapshots.
- Capture dark, light and native GTK at desktop and 390/560 px widths, a short
  window, enlarged text, English/German and scales 1/1.25/1.5/2. No clipped labels,
  horizontal overflow, overlapping controls, hidden errors or footer collisions.

After implementation run:

```sh
zig build build-settings build-settings-test test -Doptimize=ReleaseSafe
```

Then run `test-settings-sched-ext`, `test-settings-boundary`,
`test-settings-services`, `test-settings-presentation`, `test-settings-accessibility`
and `test-settings-app` as appropriate build targets. Record any environmental
or pre-existing failures separately from passing focused checks.

Scheduler interaction tests use the existing private scxctl and kernel-state
fixtures, never the developer's active scheduler. Mockup verification covers Zig
generation, SVG rendering, visual inspection, document links and whitespace;
it does not establish native interaction or accessibility correctness.

## Implementation checkpoint

The native System page now has the observed-runtime card, grouped mode radios,
compact actions and two persistent-in-window disclosures. Theme tokens cover
the new tiles in Material variants and GTK fallback styling. Existing snapshot,
generation, Apply, Stop, boot-default and preference-draft behavior is retained.
No scheduler service or protocol implementation changed.

Mode widgets and signal handlers remain stable; unavailable modes hide their
FlowBox wrappers, and removed selections cannot silently select replacements.
Arrow keys and Home/End traverse only available modes. Background snapshot
refreshes keep local selection controls usable so periodic polling cannot remove
keyboard focus or close the scheduler dropdown. Command buttons remain gated;
locally submitted operations freeze selectors through their existing receipts.
Changed settled status is announced without repeating unchanged polling results.

`test-system-layout` covers native interaction, no implicit mutation, missing
mode/catalog recovery, pending/failure states, preference draft separation,
English/German, dark/light/GTK, narrow/short windows, enlarged text and display
scales. The scheduler and boundary suites pass; broader failures are preserved
in the linked validation report rather than counted as passes.
