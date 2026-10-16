# Aqueous layout redesign plan

Status: implemented in native Zig/GTK, October 15, 2026.
See [implementation evidence and verification](../artifacts/aqueous-layout/README.md).

Bring Aqueous and all seven sections into the visual family of the updated
Appearance, Assistant, and System pages: clear page context, rounded cards,
visible common choices, expandable secondary controls, and a stable action
footer. Preserve the complete schema-driven editor and its transaction rules.

Start with the [interactive mockup guide](mockups/aqueous-layout/README.md).
The mockup has editable sample controls on every page, shared draft review,
Apply/Discard, display Keep/Revert, theme switching, and failure scenarios.
It demonstrates presentation and interaction; the inventory below defines the
full production scope beyond those representative controls.

## Design references

Use the implemented [System](../artifacts/system-layout/README.md),
[Assistant](../artifacts/assistant-layout/README.md), and
[Appearance](../artifacts/appearance-redesign/README.md) pages and
[`settings-layout.css`](../resources/settings-layout.css) as the reference.
Reuse the existing navigation icons, selection treatment, typography and theme
tokens. Cards use 16 px corners and gaps, approximately 20 px insets, and the
existing 30 px desktop / 16 px narrow body margins. Interactive targets should
remain approximately 44 px, with natural text measurement and wrapping.

Keep the [Aqueous sublist navigation](AQUEOUS_SETTINGS_NAVIGATION_PLAN.md):
Appearance, Layouts, Input, Shortcuts, Rules, Displays, Advanced. The underlying
IDs remain `appearance`, `layouts`, `input`, `keybinds`, `rules`, `displays`,
`advanced`. The mockup calls the fourth section Keybindings to match the editor;
production retains its existing translated Shortcuts navigation label.
Aqueous opens the last section for internal navigation; external unqualified
activation retains its existing Appearance default. No additional Overview tab.

The existing [display design](AQUEOUS_DISPLAYS_IMPLEMENTATION_PLAN.md) and
[window rule builder](WINDOW_RULES_BUILDER_IMPLEMENTATION_PLAN.md) already have
specialized interactions. Integrate their cards and disclosures without replacing
their editors with generic controls.

## Shared page structure

1. **Context and title.** Aqueous context label, section title, one sentence
   explaining what this section controls. Preserve the window's fixed header.
2. **Primary card.** Put the page's main decision first. Use a draft illustration
   for appearance/layouts and the existing interactive diagram for displays.
   Label illustrations as previews; never imply a draft is observed runtime.
3. **Common controls.** Keep frequent settings visible in short, named groups.
   Use native switches/check buttons, dropdowns, numeric inputs and text fields
   according to helper metadata. Offer radio tiles only for small authoritative
   enumerations, without inventing unavailable choices.
4. **Secondary disclosures.** Use descriptive summaries and preserve expansion
   for the window lifetime. A hidden invalid field automatically exposes its
   group when the user follows an error. Unknown/new fields remain reachable.
5. **Shared footer.** Unsaved count and affected sections, Discard, and Review &
   apply. Refresh, explicit Validate, Rebase and operation details remain reachable
   from Advanced and relevant contextual errors. Displays retains its existing
   Apply changes entry point and automatic validation/preview sequence.

The mockup's Demo state, Reset demo, and theme switch
are review tools, not proposed production chrome. Production retains the indented
sidebar sublist and narrow Sections popover. Restore section scroll and valid
focus through navigation. Use one body viewport above the fixed wrapping footer;
do not add nested page scrollers to the standalone window.

## Complete control inventory

The pinned helper fixture has **221 scalar fields**: 37 Appearance, 33 Layouts,
26 Input, 117 Keybindings, 3 Rules and 5 Displays, after applying the existing
`layout.border_*` presentation remapping. Structured collections, raw sources,
requests and operation controls are additional. The live helper schema remains
authoritative; these counts are an audit baseline, not a fixed UI contract.
See [the field inventory](AQUEOUS_FIELD_INVENTORY.md) for every scalar ID.

| Section | Always visible | Expandable groups and retained capabilities |
| --- | --- | --- |
| Appearance | Draft window illustration; border width and focused color; blur and opacity enable controls | Border normal/urgent colors; all blur radius/passes/noise/contrast/brightness/vibrancy options; all opacity values and focus sensitivity; transition enable/rate; desktop font family/style/weight/slant/width/size; cursor managed/theme/size and sync reports/actions; four struts; fullscreen bar and maximize behavior; bell mode/file/volume |
| Layouts | Authoritative default-layout choices with illustration; inner/outer gaps | Master ratio/count and forced decorations; all four slots; all scrolling, dwindle, reverse-dwindle, monocle and floating options; named snap layouts with IDs/names/padding/default selection and ordered normalized zones; complete legacy zone editor; source inventories |
| Input | Keyboard layout, repeat rate/delay; mouse/touchpad natural scrolling and tap | Keyboard variant/options; global pointer acceleration/factor; independent mouse and touchpad profiles/speeds/handedness/middle emulation; touchpad disable-while-typing/click/scroll methods; focus-follows-mouse, mouse-follows-focus, focus-new, raise-on-focus and delay |
| Keybindings | Search by action/chord; common launch, window and overview actions; custom shortcut list with Add/Edit/Delete | All 117 helper fields remain searchable, grouped into launch/session, focus/movement, workspaces/outputs, layout selection, floating/sizing/snapping, and action commands. Preserve chord recorder, collision diagnostics, custom command syntax, source identities and inventories |
| Rules | Ordered rule cards with generated condition/effect summaries, Add/Edit/Delete and existing move actions | Existing native condition/effect builder, explicit inheritance/Off/zero semantics, unknown values, 40-rule pagination, generation checks and saved inventory; game remainder/fallback layouts and inner gap. Keep authoritative tester unavailable when unsupported |
| Displays | Existing numbered arrangement, screen selection, Identify, selected-screen enable/mode/refresh/scale/orientation/HDR, relative position/alignment | Exact coordinates; automatic and custom HDR/SDR brightness; mirrors; live/offline outputs; declaration/profile/membership/custom-mode editor; all five policies; diagnostics and explicit Refresh/Validate/Rebase; legacy helper fallback |
| Advanced | Configuration health and blocking issues; concise separate save/reload/sync/receipt/preview states; Refresh and Validate | Six raw sources (`wm`, `layout`, `input`, `outputs`, `rules`, `appearance`), full staged JSON request, explicit user override, candidate effects, transaction receipts, native preview and rollback details, Rebase and retry-reload when eligible |

Group fields by stable IDs/prefixes in a **presentation map**, keeping metadata
type, range, options, description, value, source, capability and enabled state.
Add a final “Additional settings” group per section for unmatched live fields,
including advanced fields. Never discard a field because it was absent from the
design fixture. Test exactly-once placement for all 221 baseline scalar IDs and
an injected future field. Unsupported values stay visible and preserved.

When newer helpers advertise single-window centering and per-layout overrides,
place these under Layout behavior, preserve inheritance, and retain aspect-ratio
controls. Do not add them on older helpers or change the pinned fixture to imply
support. Search should reveal a matching field's collapsed group and distinguish
no results from an unavailable editor.

Appearance's automatic border synchronization stays owned by Pearl Appearance.
Use a contextual link to that page while retaining the Aqueous draft; do not
introduce a second toggle with different persistence. Aqueous font/cursor sync
continues to report each target separately. The Settings window theme remains
the committed Pearl theme; an Aqueous appearance draft only updates its preview.

## Draft and operation behavior

Preserve the [existing Aqueous contract](AQUEOUS_SETTINGS.md). Layout work must
not introduce a new configuration parser, file writer, helper capability,
transport, authorization path, receipt policy or preference schema.

| State or action | Required behavior |
| --- | --- |
| Edit, navigate or expand | Stage the existing shared Aqueous draft. Opening disclosures and navigating must never submit a mutation. Keep Pearl preferences separate, including their retained-draft review path. |
| Review | Show changed sections and field/collection summaries. Bind review to the same candidate revision/digest that will apply. If effects or the candidate change, require renewed review. |
| Discard | Disclose every affected Aqueous section; restore saved values only after explicit confirmation. Cancel retains edits. Discard does not resolve an uncertain operation or clear a durable receipt. |
| Validate | Use canonical helper validation. Valid syntax alone is insufficient when semantic effects are unknown. Expose inline errors and retain invalid raw/request text. |
| Apply without display effects | Use the existing protected operation and durable operation ID once. Show saved, reload and toolkit-sync results independently. A failed reload must not be presented as an unsaved file. |
| Any live or deferred display effect | Obtain the authenticated native lease and wait for presentation before enabling Keep. Confirm the entire reviewed candidate, including changes in other sections. |
| Keep, Revert, Escape or timeout | Keep uses the protected commit. Revert retains the editable draft. Production uses the compositor deadline and terminal status, never the mockup's local timer. Suspension/partial rollback/unknown outcomes stay visible. |
| Preview unsupported | Retain editing but block display-affecting Apply with the backend explanation. Do not bypass the lease for offline declarations, raw display effects or store-only changes. Current production DRM previews remain unavailable. |
| External conflict | Preserve local input. Explain affected sources and offer explicit review/rebase through existing merge checks. Do not silently select new values or overwrite another writer. |
| Lost reply or unknown receipt | Refresh reconciles operation status; never automatically repeat Apply. Preserve durable uncertainty through Discard, navigation and restart. |
| Disconnected, locked or suspended | Use existing readiness gates, preserve the draft, show the relevant explanation, and disable mutations as required by the backend. |
| Rule reorder | Preserve the clean-draft requirement and exclusive move staging. Apply or discard the move before other mutations on any section. |
| Shortcut recording | Wait for acknowledged inhibition before accepting chords; Escape, timeout, navigation, disconnect and close release inhibition. Editing a command never executes it. |
| Raw versus structured edits | Preserve whole-file ownership and overlap disabling. Retain source identities, generation checks, request bounds and explicit system-to-user override. |

## Implementation sequence

1. **Create the presentation map and shared card helpers.** Refactor row
   construction in [`aqueous_settings.zig`](../src/desktop/aqueous_settings.zig)
   without changing existing callbacks or field identities. Add pure Zig
   exactly-once coverage tests, fallback grouping and stable disclosure IDs.
   Scope styling under an Aqueous page class in the shared stylesheet.
2. **Recompose Appearance, Layouts and Input.** Put common controls in primary
   cards and specialized options in disclosures. Add illustrations driven by
   draft values. Reuse the snap-layout and collection editors. Keep typed source
   metadata, raw-overlap gates and dynamic helper capabilities intact.
3. **Recompose Keybindings and Rules.** Add local action/chord filtering over the
   complete live action inventory. Reuse acknowledged recorder and collection
   callbacks. Wrap the existing rule builder, source order and game controls in
   the shared card rhythm; do not invent rule names, enable toggles or a tester.
4. **Integrate Displays and Advanced.** Reuse
   [`aqueous_display_setup.zig`](../src/desktop/aqueous_display_setup.zig),
   display declaration editor and existing confirmation lifecycle. Organize
   Advanced around status/recovery followed by raw/request disclosures. Keep
   diagnostics selectable and errors readable outside collapsed details.
5. **Unify review and footer presentation.** Extend the existing cross-section
   disclosure in the Aqueous editor rather than creating another draft owner.
   Preserve operation reporting, capability gates, source generations, footer
   hosting and draft transfer in [`window.zig`](../src/settings/window.zig).
   Keep callbacks disconnected before rebuilt widgets are released; do not let
   polling erase focus, text selection, open menus or in-progress modal edits.
6. **Validate and capture production.** Translate new copy in English/German,
   extend diagnostics for stable card/disclosure/search controls, and record
   production evidence separately from this mockup under an artifacts directory.

Each production step is a reviewable native Zig/GTK change. Implement shared composition
first, then the three scalar pages, then collection pages, then recovery/review
integration. The user authorized HTML for this interactive design mockup;
its browser interactions use self-contained HTML/CSS/JavaScript. Production
application code and build tooling remain Zig.

## Acceptance criteria

- All seven sections match the updated reference pages at comparable size and
  theme. Every current scalar, collection and Advanced operation remains
  reachable. Schema additions appear in the fallback group without code changes.
- Navigate after edits in multiple sections, return, cancel review, apply or
  discard: values, affected-section counts and focus remain consistent. Pearl
  preference edits survive and cannot be saved/discarded by Aqueous actions.
- Test candidate validation failures, raw ownership, mixed effects, source
  changes, collection moves, helper capability removal, pending/double-click,
  failed reload, partial sync, lost replies, restart reconciliation, conflicts,
  disconnect/reconnect, lock and suspension using private fixtures.
- Display checks include Keep, Revert, Escape, deadline, lost begin reply,
  presentation delay, owner disconnect, suspension and partial rollback. No
  simulated mockup outcome is evidence of physical hardware support.
- Test shortcut search with all helper fields, empty results and unknown future
  actions. Verify actual recording inhibition and cleanup. Rule modal Cancel
  preserves only the shared draft; Save stages; moving remains exclusive.
- Keyboard-only navigation reaches every control/disclosure/footer action.
  Inputs have accessible labels, selection/expanded/disabled state and visible
  focus. Modal close restores focus. Changed status is announced without polling
  spam; full screen-reader traversal requires a separate manual pass.
- Capture dark, light and native GTK; 390/560 px and wide windows; short windows;
  enlarged text; English/German; display scales 1/1.25/1.5/2. No horizontal
  overflow, clipped controls, hidden errors or footer collisions. Use natural
  sizes, not screenshot-specific fixed heights.

Production verification after implementation:

```sh
zig build build-settings build-settings-test test -Doptimize=ReleaseSafe
zig build test-settings-services test-settings-displays test-settings-boundary -Doptimize=ReleaseSafe
zig build test-aqueous-settings test-aqueous-preview -Doptimize=ReleaseSafe
zig build test-settings-presentation test-settings-accessibility test-settings-app -Doptimize=ReleaseSafe
```

Run the existing rule-builder and shortcut fixture coverage when changing their
views, and `test-single-window-centering` with its required local prefix if that
capability is present. Report environmental/pre-existing failures separately.
The HTML mockup remains a separate design artifact. Native implementation,
captures, passing regressions, and environmental test limitations are recorded
in the [implementation report](../artifacts/aqueous-layout/README.md).
