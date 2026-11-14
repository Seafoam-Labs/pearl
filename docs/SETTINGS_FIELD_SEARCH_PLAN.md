# Settings field-level search

Status: planned; not implemented.

**Recorded decision:** accept Pearl registry drift for the initial version
(static manifest). The structural anti-drift fix (co-located metadata + derived
index + coverage gate) is deferred to a future update — see
[Eliminate drift](#future-update-eliminate-drift-deferred).

## Goal

Extend the navigation search box (see
[AQUEOUS_FLATTENED_NAVIGATION_PLAN.md](AQUEOUS_FLATTENED_NAVIGATION_PLAN.md))
from filtering destinations to returning **individual settings**. Typing
`launcher` returns every launcher-related setting — the Launcher bar widget,
Launcher icon, Application launchers, per-output icon overrides, and the Aqueous
`toggle_start_menu` keybind — and selecting a result navigates to its page,
expands its section, and focuses the control.

Most `launcher` settings are Pearl preferences (Bar & dock, Advanced); only the
start-menu keybinds are Aqueous fields. The feature therefore spans both settings
systems.

## Existing machinery to reuse

- **Aqueous field index**: the helper snapshot's `fields` (241 entries) with
  `id/category/label/description/value`, localized through
  `i18n.aqueousField(id, .label/.description, …)`. The window already holds this
  via `self.aqueous.value()`.
- **Matching and location**: `aqueous_presentation.matches(query, id, label,
  value)` and `group(field)` → `spec(group).page` + disclosure section.
- **Reveal + focus by id**: `issue_focus` + `revealIssue()` + `focusIssue()` +
  the `open_section` callback, used today for validation errors. Generalize
  beyond keybinds.
- **Pearl seeds**: `bar_model.metadata` (name/description per bar widget) and
  `bar_view.rememberFocus(id)` (post-rebuild focus restore).
- The global search UI and `settings_navigation.containsIgnoreCase`.

## Initial design (drift accepted)

- A unified `SearchHit { id, label, description, location, keywords }` fed by two
  sources:
  - **Aqueous**: derived from the live snapshot fields. No drift here — the index
    is the schema.
  - **Pearl**: a **static declarative manifest**
    `{ id, label, description, route, section, keywords }` maintained alongside
    the views. This is the accepted-drift component.
- **Result UI**: a bounded, keyboard-navigable list under the search box showing
  label + breadcrumb (page › section); Enter activates the focused result.
- **Reveal on selection**:
  - Aqueous: the existing `issue_focus`/`revealIssue`/`focusIssue` path, ensuring
    the page's forms are built first (`forms_stale`).
  - Pearl: a per-view `reveal(id)` that expands the matching section and focuses
    the control. **Graceful fallback**: if a control cannot be resolved, navigate
    to the page/section heading instead of failing — so a stale manifest entry
    degrades to navigation rather than a dead click.
- **Lifecycle**: build the index when the schema/views are ready; rebuild on
  refresh/rebase/page-enter; offline or locked states contribute no results.
  Debounce input and cap results.

## Accepted risk (explicit)

The Pearl manifest is a second copy of facts that live in the widgets, so it can
drift:

- **Dead ids** — a removed/renamed control still listed.
- **Stale location** — a control moved page/section but the manifest path did not.
- **Stale label/description** — manifest text diverges from the UI.
- **Missing coverage** — a new control never added to the manifest.

For the initial version this is **accepted**. The runtime fallback limits the
damage (a stale entry still lands on the right page/section heading), but results
may be incomplete or point at the wrong section until the manifest is corrected
by hand. No structural guarantee or coverage gate is required to ship the initial
version.

## Future update: eliminate drift (deferred)

Replace the parallel manifest with a derivation of the existing control
registrations, and gate it with a test:

1. **Co-locate metadata.** Extend the `Control { id, widget }` arrays every view
   already maintains (and the probe already walks) to carry
   `{label, description, keywords}` at the creation site. Build the index from
   those live registrations — there is no second list to forget. Bar widgets pull
   text from `bar_model.metadata`.
2. **Resolve reveal against live widgets.** Per-view `reveal(id)` walks its
   current structure (control → ancestor expander → expand → scroll → focus),
   like Aqueous `revealIssue` walks `self.editors`. Never store a static path.
3. **Coverage gate.** Mirror `aqueous_presentation`'s
   *"all pinned scalar fields have exactly one section and future fields remain
   reachable"* test. Because Pearl controls are widgets and fixture mode builds
   only placeholders, run it in the **integration harness** against real views,
   reusing the probe's id + focus reporting:
   - no dead results — every index id resolves and `reveal(id)` lands focus;
   - no gaps — every searchable-class probe id is in the index;
   - unique ids across views.
4. **Optional compile-time rigor.** A shared `ControlId` enum with an exhaustive
   `reveal` switch makes control removal a compile error. Use it at reveal entry
   points only; many leaf ids are dynamic, so the coverage test remains the
   primary gate.

Net effect: drift moves from a user-facing dead link to a failed PR check. The
one-time cost is touching each control-creation site to attach metadata.

## Phasing

1. **Aqueous field results** — reuse existing machinery; no drift.
2. **Pearl static manifest + reveal + runtime fallback** — drift accepted.
3. **Future: co-location + coverage gate** — drift eliminated.

## Acceptance criteria (initial version)

- `launcher` returns the launcher-related Pearl settings plus `toggle_start_menu`;
  selecting a result navigates, expands, and focuses — or falls back to the
  section heading when unresolved.
- Aqueous fields are searchable across all categories, not only keybinds.
- The index handles offline/locked/rebuild states without dead clicks.
- New UI strings are extracted; an integration test covers the `launcher` flow.

## Open decisions

- Result presentation: inline list under the box vs. a dedicated panel; whether
  nav filtering stays active simultaneously.
- Match scope: labels/descriptions/keywords only, or also current values
  (Aqueous `matches` already supports values); result cap.
- Manifest ownership and file location.
