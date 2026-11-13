# Flattened Aqueous navigation and merged Advanced page

Status: implemented November 13, 2026. Supersedes the sublist navigation in
[AQUEOUS_SETTINGS_NAVIGATION_PLAN.md](AQUEOUS_SETTINGS_NAVIGATION_PLAN.md).

## Goal

Remove the separate **Aqueous** category from Pearl Settings. Every Aqueous
editor section becomes a permanent top-level destination in its subject group,
and the former Aqueous **Advanced** section merges into the shared **Advanced**
page beside the Pearl preferences document.

## Delivered navigation

```text
GENERAL      Overview
CONNECTIONS  Network · Bluetooth
DEVICES      Sound · Power & session · Displays · Input · Shortcuts
DESKTOP      Appearance · Window appearance · Layouts · Rules · Assistant · Bar & dock · Notifications
SYSTEM       System · Startup applications · Advanced · Plugins
```

- The Aqueous appearance section is titled **Window appearance** so it is not
  confused with Pearl's own Appearance page. Its subtitle remains "Window
  borders, effects and desktop details."
- The retired parent row, indented child rows, parent-return behavior and the
  "Aqueous / …" heading context are gone. Headings and accessible names are the
  plain destination titles. Narrow windows use the same flat entries in the
  **Sections** popover; choosing an entry closes the popover.
- Overview tiles mirror the same entries.

## Routing compatibility

Internal routing keeps the stable `aqueous` page and section IDs
(`appearance`, `layouts`, `input`, `keybinds`, `rules`, `displays`). The shared
entry table lives in `src/desktop/settings_navigation.zig`
(`entries`, `entryIndex`, `Group`). `normalize()` maps the legacy
`{aqueous, advanced}` destination to the shared `advanced` route; it is applied
in `window.requestSelect`, `editor.navigate`, `Request.settingsTarget()` and the
backend `page.enter` handler, so CLI, wire and activation links all agree.
`pearlctl aqueous show --section advanced` (and `--text advanced`) open the
merged Advanced page. An Aqueous launch without a section still opens Window
appearance.

## Merged Advanced page

The Advanced page body is one scroll viewport with two cards:

1. **Pearl preferences** — the existing full preferences JSON editor and the
   header's **View saved JSON** action.
2. **Aqueous configuration** — the former Aqueous Advanced content: status with
   Refresh/Validate/Rebase, operation receipts and preview rollback details,
   the six raw TOML files with the source dropdown, the full draft request JSON
   and unknown-category fields.

The Aqueous view renders this content into an external host supplied by the
window (`createIn(..., advanced_host)`); the compact Control-center popup keeps
its own tabbed Advanced section. The two drafts stay independent: Pearl's
Apply & save / Discard / Merge row and the Aqueous action footer both appear on
the page, each with its own status message. Aqueous issue navigation, disclosure
expansion, preview/rule-move sensitivity and rebuild focus invalidation extend
to the merged page. Per-section scroll/focus restoration for the six editor
sections is unchanged.

## Validation

- `zig build` and `zig build test` (385 unit tests, translation template check).
- `zig build test-settings-app`, `test-aqueous-layout`, `test-settings-services`,
  `test-settings-presentation`, `test-aqueous-settings`, `test-settings-displays`,
  `test-window-rule-settings`: pass.
- Pre-existing on this machine, reproduced identically on a clean tree:
  `test-settings-integration` stops at the control-center flyout Settings
  handoff, and `test-settings-appearance` stops at the lock/unlock resume step.
  Benign `gdk_frame_timings` warnings and the missing German locale are recorded
  as allowed environment warnings where the suites already follow that pattern
  (docs/PROGRESS.md).
