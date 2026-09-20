# Launcher button icon verification

Implemented 2026-09-20. See the [implementation plan](../../docs/LAUNCHER_ICON_IMPLEMENTATION_PLAN.md)
and [preference documentation](../../docs/PREFERENCES.md#launcher-button-icon).

The icon can be selected in **Bar & dock → Launcher actions → Change icon…**.
Bundled icons, installed theme names and local static PNGs use the shared draft,
preview, Apply & save, Discard and Reset. Retry reloads matching saved bar icons
and the Settings preview without saving the draft.

## Checks

- `zig build test test-theme-assets`: 205 tests passed (164 policy/model tests,
  41 image/resource tests).
- `zig build test-bar-layout`: 35 cases passed, including custom PNGs across all
  edges, GTK themes, enlarged text, invalid-image fallback, independent output
  overrides, minimum requested size in light/dark, and persistence at mixed scale.
  [Machine-readable result](bar-layout.json).
- `zig build test-preferences`: all existing preference regressions passed.
  [Machine-readable result](preferences.json).
- `zig build test-settings-bar-editor`: all 16 checks passed, including PNG
  selection/cancellation, rejection of corrupt PNGs, stale-dialog cancellation,
  draft preview/Apply/Discard, Retry, Reset and the existing editor regressions.
  [Machine-readable result](settings-bar-editor.json).
- The local browser mockup passed selection, preview, Apply and Discard checks.

The suites use private D-Bus, Wayland and XDG directories. Test commands used
`ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig-global` for the writable build cache.

## Captures

- [Native icon chooser](launcher-icon-menu.png)
- [Matching Settings preview and live PNG](launcher-icon-png.png)
- [Minimum requested bar size, dark](launcher-icon-minimum-dark.png)
- [Minimum requested bar size, light](launcher-icon-minimum-light.png)
- [Vertical bar](static-True-14-48-left.png)
- [GTK theme](gtk-True-14-48-top.png)
- [Saved PNG after restart at mixed scale](workspace-medium-restarted-scaled.png)

The PNG fixture is deliberately a transparent nonsquare rectangle to make
aspect-ratio preservation and bounded allocation easy to check.

## Remaining external check

Output disable/enable verification is blocked by the pinned Aqueous fixture:
`wlr-randr --output HEADLESS-2 --off` panics in
`OutputManager.validateConfigCoordinates` (`OutputManager.zig:575`), terminating
the compositor before Pearl can observe the hotplug. The opt-in reproducer is:

```sh
ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig-global zig build test-bar-layout -- --icon-hotplug --output /tmp/pearl-launcher-hotplug
```

Per-display selection and restart are covered. The code applies the saved icon
when a bar is created, but physical hotplug acceptance remains unverified until
the compositor fixture can complete output disable/enable.
