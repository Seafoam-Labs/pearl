# User-controlled bar opacity

Status: implemented. This document records the behavior and implementation plan.

Add **Background opacity** to **Settings → Bar & dock**, alongside bar size and
Separate bar islands. Users can keep the current appearance or choose an exact
percentage. The setting affects the bar background; labels, icons, buttons and
their interaction states retain their existing rendering.

## Proposed behavior

- Provide **Automatic** (default) and **Custom** modes. Custom exposes a slider
  and numeric percentage control, from 0% to 100% in 1% steps. Initialize the
  remembered custom value to 86%. Explain the endpoints as Transparent / Opaque.
- Automatic preserves current behavior: Pearl palette backgrounds use 86%
  opacity with native blur capability and 100% without it; GTK backgrounds
  follow the selected GTK theme.
- Custom sets the background's absolute alpha to the chosen percentage,
  including when blur is unavailable. Do not multiply it by the existing 0.86
  alpha or a theme color's alpha. Blur continues to follow compositor policy.
  This is an intentional exception to the current automatic opaque fallback.
- Apply the same value to each island, or to the single continuous panel.
  Island gaps remain transparent. At 0%, bar controls remain visible and usable;
  transparent backgrounds do not make the bar click-through.
- Changes update the shared settings draft. **Apply & save** updates the running
  bars and persists the choice; **Discard** restores the saved values. Opening
  Settings does not modify preferences. A restart is unnecessary.
- The regular form edits the default bar. Per-display values remain available
  through Advanced, following the existing complete `outputs[].bar` override
  semantics. Explain that display overrides take priority.
- Returning to Automatic restores theme rendering and retains the last custom
  percentage for the next switch to Custom.

## Preference model

Extend `Bar` in [preferences.zig](../src/config/preferences.zig) with:

```zig
background_opacity: struct {
    mode: enum { automatic, custom } = .automatic,
    percent: u8 = 86,
} = .{},
```

Example fragment inside a bar object:

```json
"background_opacity": { "mode": "custom", "percent": 75 }
```

Keep preference version 1 and supply defaults for old documents. Validate the
percentage as 0–100 in `barValid`, including output overrides; reject invalid
types, unknown modes and out-of-range values. An omitted setting in a display
override means Automatic, even when the default bar uses Custom. Preserve
unrelated preferences through draft patches, merge, Apply and save.

## Implementation sequence

1. **Add the model and opacity policy.** Implement preference defaults and
   validation, plus a small pure helper for resolving Automatic versus Custom.
   Represent GTK Automatic as theme-owned rather than inventing a numeric alpha.
   Register any new pure module in [tests.zig](../src/tests.zig).

2. **Implement background rendering.** Integrate with
   [bar.zig](../src/desktop/bar.zig),
   [surface manager](../src/ui/surfaces/manager.zig), and the theme provider path
   in [service.zig](../src/config/service.zig). Scope overrides to each bar so
   displays can have different percentages. Target only the continuous panel
   background or island backgrounds. Account for
   [style.css](../resources/style.css),
   [gtk-theme.css](../resources/gtk-theme.css), and package styles; ensure the
   custom background wins over their background declarations without changing
   foregrounds. For Custom, use the active Pearl container color, or resolve
   GTK's named background color with a documented palette fallback when absent.
   Render a flat background in Custom so theme background images cannot hide
   the selected transparency. Automatic removes the override entirely.

3. **Connect runtime updates.** Resolve the bar preference through `forOutput`
   when bars are created and when committed preferences change. Keep the value
   correct after theme or variant changes, wallpaper-generated palettes,
   output hotplug, and island/edge changes. Preserve Automatic's blur capability
   handling in [effects.zig](../src/platform/wayland/effects.zig); Custom must
   survive capability changes. Release any per-bar providers on destruction
   and avoid rebuilding bar contents for an opacity-only change. Scope styling
   so dock, popovers, flyouts, OSD, wallpaper and Settings retain their rendering.

4. **Add accessible settings controls.** Extend
   [preference_pages.zig](../src/settings/preference_pages.zig) with the mode
   selector and synchronized slider/numeric control. Disable percentage input
   in Automatic. Use the existing editor transaction and read-only/locked/error
   states. Preserve keyboard focus and slider drag state during draft
   acknowledgments; coalesce rapid updates without losing the final value.
   Replace the existing positional `index == 3` bar-editor insertion with an
   explicit section boundary when adding these fields. Audit the compact form
   in [settings.zig](../src/desktop/settings.zig); if reachable, give it the same
   controls or a direct link to this standalone settings section.

5. **Verify and document.** Extend existing preference and bar-editor coverage,
   then update [PREFERENCES.md](PREFERENCES.md) and [SURFACES.md](SURFACES.md)
   with the field, Automatic/Custom distinction, GTK behavior and output rules.
   Save representative screenshots under `artifacts/bar-opacity/` during
   implementation verification.

## Acceptance checks

- Pure tests cover old-document defaults, round trips, 0/86/100%, invalid
  values, mode switching, and complete display overrides. Draft edits preserve
  unrelated values and participate in normal conflict handling.
- Settings integration covers mouse and keyboard editing, numeric/slider
  synchronization, Apply, Discard, reopening, and persistence after restart.
  Merely changing the draft must leave the live bar unchanged.
- Private-session visual checks cover 0/50/100% in continuous and island modes,
  light/dark palettes, GTK and package themes, and blur available/unavailable.
  Confirm readable unchanged foregrounds, transparent island gaps, and no
  compounded alpha. Check a GTK theme with a background image and one without
  the expected named color to validate the Custom fallback.
- Confirm two displays can show different values, a reconnected display uses
  its saved value, and all four bar edges retain layout, input and reservation.
  Verify unrelated shell surfaces retain their appearance.
- Run `zig build test -Doptimize=ReleaseSafe` and the affected existing targets:
  `test-settings-bar-editor`, `test-preferences`, `test-surfaces`, and
  `test-bar-layout`. Check GTK CSS diagnostics and provider cleanup during
  repeated Apply, theme switches and output removal.

Complete when a user can choose, apply, discard and persist bar background
opacity from Settings, with Automatic preserving existing behavior and Custom
working across supported theme modes and displays.

## Verification results

- ReleaseSafe build and all 169 pure tests passed.
- Settings bar editor: 17 checks passed, including slider/number synchronization,
  draft isolation, Apply, Discard, retained custom percentage and reopening.
- Preferences: 25 checks passed, including Custom opacity after restart and
  last-good recovery.
- Surfaces: 19 checks passed, including Custom opacity after output hotplug and
  across native blur capability changes.
- Bar layout and opacity: rendered pixel checks cover 0/50/100%, continuous
  panels and islands, dark/light Material, GTK named colors with existing alpha
  and background images, community palettes, and a system GTK theme without
  named colors. The latter uses the selected dark/light palette fallback.
- The compact settings form links directly to the standalone bar editor.
  Runtime overrides use providers attached only to each bar panel and its
  island widgets; Automatic clears those overrides. Existing editor debounce
  handles rapid slider updates.

See [verification artifacts](../artifacts/bar-opacity/README.md) for reports and
representative screenshots.
