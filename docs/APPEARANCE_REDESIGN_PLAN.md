# Appearance redesign plan

Status: native GTK layout implemented October 15, 2026. See the
[implementation captures and validation report](../artifacts/appearance-redesign/README.md).
The design specification below records the intended interaction and acceptance scope;
the report distinguishes verified behavior from remaining environment/manual checks.

Bring Appearance into the same visual family as Bar & dock and Power & battery:
a useful preview, clear section titles, visible choices, and compact summaries
for secondary settings. Keep the existing settings window and shared preference
draft. The main editing sequence becomes **preview → theme → wallpaper → details**.

Review the [dark desktop mockup](mockups/appearance/desktop.png),
[light variant](mockups/appearance/light.png), [390 px layout](mockups/appearance/narrow.png),
and [expanded details](mockups/appearance/details.png).
The [mockup source and reproduction instructions](mockups/appearance/README.md)
are alongside the images.

## What changes

The previous standalone page was built in
[`preferences_view.zig`](../src/settings/preferences_view.zig). It started with
theme dropdowns and border synchronization, then inserted the palette and theme
manager before Wallpaper. Typography, Qt integration, desktop icons, Night Light,
application profiles and login-screen synchronization followed. Several cards had
long technical explanations and the theme manager contained many equally prominent
actions. Wallpaper and everyday adjustments were consequently harder to find.

Use the existing visual patterns from
[`bar_view.zig`](../src/settings/bar_view.zig), Dock/Flyouts expanders in
[`preference_pages.zig`](../src/settings/preference_pages.zig), and the titled cards
and selection treatments in [`power_view.zig`](../src/settings/power_view.zig).
Retain the sidebar, header, theme colors, body scroll area and persistent footer.
This is a presentation change with no preference schema migration.

| Area | Proposed presentation | Existing behavior to retain |
| --- | --- | --- |
| Desktop preview | Compact wallpaper, sample window, bar and dock schematic; explicit draft label | Preview cannot change committed appearance |
| Theme and colors | Four selectable tiles: Material, Dynamic, GTK, Community; contextual rows underneath | `theme.mode`, variant, source, seed and GTK name |
| Wallpaper | Thumbnail, filename, fit summary and Choose image action | Existing chooser, editable path, four background modes, color, crops and slideshow |
| Text and layout | Expandable summary; font, numeric size, density and reduced motion inside | Exact values and existing ranges, including system font fallback |
| Desktop icons | Expandable summary; enabled switch, size and arrangement; secondary display and hidden-file options | Saved connector, automatic output behavior and all icon preferences |
| Night Light | Expandable status summary with schedule controls | Temperature, custom times, support status and Resume saved policy |
| Application appearance | Border synchronization, Qt controls and application profiles in named groups | All current checks, per-application assignments, recovery and review actions |
| Themes and customization | Installed/community browser, palette editor and widget style controls | Independent color/style choices, archives, sources, downloads, previews and defaults |
| Login screen | Collapsed explanation with explicit Sync to greeter action | Separate administrator authentication and existing synchronization behavior |

## Layout and interaction

Use existing 16 px card corners, 20 px card insets, 30 px desktop body margins
and 16 px narrow body margins from `resources/settings-layout.css`. Set 16 px
between cards and approximately 44 px minimum interactive row height. Use the
existing foreground and secondary text tokens; reserve the accent fill and
outline for selection and the primary save action. The SVG palette illustrates
the existing lavender Material appearance, not new hardcoded application colors.

Keep preview, theme choices and Wallpaper expanded. Other sections start
collapsed with useful summaries, and remember expansion state while the window
is open. Expanding a section stays in the same body viewport. Show warnings,
failed actions and pending reviews in the collapsed header; reveal the relevant
section when a validation error needs attention. Do not hide a failure in an
unopened expander.

Theme tiles form one keyboard-accessible selection group. Material maps to
`.static`, Dynamic to `.dynamic`, GTK to `.gtk`, and Community to `.package`.
Selection includes a radio indicator and accessible state, so color is not the
only signal. Tile decorations are illustrative; actual palette swatches belong
in the resolved preview or selected-theme details.

- Material shows Dark/Light. Dynamic also shows Wallpaper/Seed color, exposing
  the exact hexadecimal seed entry only for Seed color. Resolved colors appear
  in the desktop sample after Preview draft colors.
- GTK shows the existing theme-name entry and system-default explanation.
  Preserve variant behavior and disclose any GTK limitations near the control.
- Community reveals the installed-theme picker in the same card or expands and
  focuses Themes and customization. Selecting the mode must not invent a package
  ID or automatically download anything. Retain the existing validation for an
  absent selection and the separate Preview, Use colors, Use style and Use theme
  actions. Theme selection must preserve independent palette/style overrides.
- Image options exposes the exact path, Material gradient / Solid color / Cover /
  Contain choice, relevant background color, and slideshow switch. Slideshow
  expands its folder chooser, interval, order, transition and duration. Preserve
  disabled behavior when off and keep per-image crops intact.

At narrow widths, stack preview text under the image and wrap the four theme
tiles into two columns, then one column when enlarged text needs more room.
Stack row labels above controls when their natural widths do not fit. Keep
Sections navigation and a wrapping footer outside the sole content scroller.
The 390 px mockup is a layout target, not a fixed-height implementation: GTK
measurement must determine card heights. Full paths remain editable/selectable
even when their summaries are shortened.

## Preview and save semantics

Reuse the cancellable image loading in `preferences_view.zig` and the scoped
theme preview machinery in `themes_view.zig`. Add a small Zig presentation
component, `src/settings/appearance_preview.zig`, for the schematic.
Read the current shared draft for default bar/dock layout; do not create another
editor or simulate live shell controls. Label the composition as illustrative;
per-display overrides and actual window contents are outside this preview.

The existing theme preview can return no resolved palette and currently explains
that generated colors apply on save. Keep that distinction: show the wallpaper
and a labeled sample/fallback palette until actual colors are available. Do not
promise an exact generated palette or run a second frontend Matugen process.
Request color previews explicitly through Preview draft colors using existing
backend commands. Debounce image loading,
cancel superseded requests, and reject stale results using the originating draft
revision or digest. GTK mode must use native styling rather than claiming an
exact Material simulation.

Draft changes stay scoped to the preview; the settings window and desktop keep
their committed appearance until Apply. Reuse `Editor.edit()`, `editable()`,
Apply, Discard, conflict handling and reconnect behavior. Apply and Discard affect
the complete Pearl draft, including changes made in Bar & dock or Advanced.
An invalid Advanced document displays the existing repair path and disables
structured editing without replacing the document.

Distinguish preference edits from existing immediate operations. Theme downloads,
repository changes, palette authoring, application installation/activation, Qt
retry/review/reapply, Resume saved policy and Sync to greeter retain their own
action semantics. In particular, saving edits to an active local palette can
apply live. Label this beside the palette Save action; the footer must not imply
that Discard reverses it. Keep the Qt external-change review and greeter
authentication flows explicit. Merely opening an expander must never execute an
action, refresh a remote catalog or write settings.

## Implementation sequence

1. **Restructure existing controls.** In `preferences_view.zig`, introduce named
   section containers and summaries, reorder Wallpaper ahead of customization,
   and group existing Qt/profile/theme/greeter views under the appropriate
   expanders. Keep signal ownership, update/destroy paths, control IDs and current
   data transformations intact. Preserve the Advanced raw editor, which shares
   this view. Verify every current field and action remains reachable.
2. **Add visual selection.** Replace the theme-mode dropdown presentation with
   grouped native GTK controls; retain contextual rows and current validation.
   Add compact wallpaper metadata and responsive row arrangements. Scope any
   new CSS under an Appearance class in `resources/settings-layout.css`; use
   theme tokens from `resources/settings.css` and native GTK fallbacks. Leave
   other pages' card and row styling unchanged.
3. **Build the preview.** Add the Zig schematic component and integrate existing
   image/theme preview data. Include loading, unreadable image, unavailable
   palette, missing package and unsupported GTK preview states. Keep failures
   non-destructive and preserve the chosen values. Ensure pending callbacks
   cannot access destroyed widgets or replace a newer preview.
4. **Finish navigation and accessibility.** Update control reporting in
   `window.zig` for tiles, section toggles and new preview status. Preserve
   established field IDs for existing tests and automation. Store expansion
   locally; current route sections are Aqueous-only, so this work need not add
   Appearance deep-link routes. Add English/German labels, keyboard focus
   restoration and clear expanded/selected/disabled states.
5. **Validate and record native evidence.** Extend the existing appearance
   integration harness to expand sections before finding their children. Capture
   actual dark, light, GTK, narrow and enlarged-text views; put screenshots and
   test results in `artifacts/appearance-redesign/README.md` when implemented.

## Acceptance criteria

- At the same viewport and text scale as Bar & dock, Appearance shares its
  header, margins, card rhythm and footer. Theme and Wallpaper are reachable
  before the community catalog and integration details.
- Every existing preference and operation in the table remains reachable.
  Opening and closing sections never dirties the draft or changes saved values.
- Edit a theme, choose an image, navigate to Bar & dock, change a bar setting,
  return and Apply. Both changes persist. Repeat with Discard; both revert.
  Unrelated output overrides, crop records and independent styles survive.
- Check all four theme modes, both variants, both dynamic sources, valid and
  invalid hex input, missing packages, unavailable Matugen and a corrupt image.
  Failures retain the draft and explain the next action.
- Check slideshow on/off, text size/density/motion, desktop icons, Night Light,
  Qt external-change review, application profiles and greeter synchronization.
  Confirm existing immediate actions still have their established boundaries.
- A preview request finishing after another edit, navigation or window close
  cannot update the wrong draft or access freed state. Preview does not alter
  the real shell, committed application CSS or generated application files.
- Keyboard users can select modes, expand every section, choose files and
  reach the footer. Escape from a chooser returns focus to its trigger. Native
  accessible names expose mode selection, expansion, errors and disabled reasons.
- Review 390 and 560 px widths, a short window, enlarged text, scales 1/1.25/1.5/2,
  and dark/light/native GTK. No horizontal scrolling, clipped labels or footer
  overlap; reduced motion requires no animated preview.

Run `zig build test` plus the existing `test-settings-appearance`,
`test-settings-presentation`, `test-settings-accessibility`, `test-settings-app`,
`test-settings-bar-editor` and `test-preferences` targets after implementation.
Include existing theme, Qt, profile and greeter suites when their component
ownership or action wiring changes. Mockup rendering checks do not replace this
native validation.

## Implementation checkpoint

Implemented all presentation groups in native Zig/GTK, including shared-draft
mode tiles, wallpaper thumbnail, schematic preview, and section summaries.
The existing theme/profile/Qt/greeter components retain their action wiring.
Community without a selected package opens the picker while preserving the valid
current mode; it does not create an invalid package draft. Expander state lives
only in the window.

The schematic uses default bar/dock placement and illustrative symbols; it does
not render live widgets or per-output overrides. Static colors resolve locally;
generated and package colors use the existing explicit backend preview. GTK
uses native styling. Image loads are debounced/cancelled, and color results are
checked against their originating draft digest.

Native captures verify desktop, light, GTK, 390 px and enlarged-text layouts.
The new `test-appearance-redesign` target exercises real controls, the file chooser,
completed backend color previews, navigation, Apply and Discard. Broader suite
results and unverified scale/screen-reader checks are recorded in the
[validation report](../artifacts/appearance-redesign/README.md).
