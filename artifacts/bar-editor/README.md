# Native selection-based bar editor

September 19, 2026. Implements the
[bar editor plan](../../docs/BAR_EDITOR_IMPLEMENTATION_PLAN.md) in the standalone
GTK Settings application. The legacy preferences flyout now opens this editor
instead of exposing separate widget text fields.

The production build (`zig build -Doptimize=ReleaseSafe`) also completed.

## Actual application captures

These images were captured in private Aqueous sessions with real GTK input.
They are separate from the HTML design mockup.

- [Desktop editor](session/bar-editor-desktop.png)
- [Add widget picker](session/bar-editor-picker.png)
- [Required Launcher actions](session/bar-editor-required-actions.png)
- [Narrow dark editor](session/bar-editor-dark-14-560.png)
- [Large text in light appearance](session/bar-editor-light-20-560.png)
- [390-pixel light editor](session/bar-editor-light-14-390.png)

The missing plugin in the screenshots is an intentional fixture. Its placement
survives all edits. A second minimal fixture exercises package discovery and
approval revalidation without requiring a working guest runtime.

## Verification

The build uses Zig 0.16.0 in ReleaseSafe. Private sessions have their own
configuration, D-Bus, Wayland sockets and compositor; user preferences are not
modified by these tests.

| Check | Result |
| --- | --- |
| `zig build test -Doptimize=ReleaseSafe` | 142 / 142 passed, including five bar-model groups and existing plugin-placement tests. |
| `test-settings-bar-editor` | [11 native interaction groups passed](metadata.json). |
| `test-settings-app` | [Window, activation and process-isolation checks passed](regressions/test-settings-app/results.json). |
| `test-preferences` | [Passed](regressions/test-preferences/metadata.json). |
| `test-bar-layout` | [Passed](regressions/test-bar-layout/metadata.json), including all four edges and live rotation. |
| `test-dock-islands` | [Passed](regressions/test-dock-islands/report.json). |
| Appearance regression diagnostic run | [All 15 groups passed](regressions/appearance-diagnostic/results.json), including failed saves, conflicts, lock/reconnect and backend restart. |

The appearance target initially timed out entering the seed color. An isolated
copy of the same test with extra failure-capture diagnostics completed all
checks; the diagnostics did not change the successful test path.

The presentation suite passed its four groups covering page composition,
light/dark/native GTK, enlarged text, 100–200% scale and short windows. It then
failed when disabling an output: the private Aqueous compositor asserted in
`OutputManager.validateConfigCoordinates`, disconnecting the test client.
See [presentation results](regressions/test-settings-presentation/results.json)
and [compositor log](regressions/test-settings-presentation/session/compositor.log).
This is a remaining regression-suite limitation, not a passing output-removal
check.

The broader services suite passed 15 groups through the new bar-selection and
shared-draft checks, but timed out later waiting for Aqueous Apply to progress
from validated to saved. A serial rerun reproduced that timeout. An earlier
attempt instead timed out opening a network password prompt. These remain
unresolved suite failures; no passing full-services claim is made. See the
[serial report](regressions/services-serial/report.json) and
[runner output](services-regression.log).

The native bar suite verifies real add/search/remove/reorder/move interactions,
required Launcher protection, duplicate prevention, plugin approval refresh,
shared draft preservation, Apply/Discard/reopen, stale-menu rejection, invalid
Advanced repair, Escape focus restoration, vertical group names, exact sizes,
and narrow/light/dark/large-text menus. It records the exact tested binary hashes.

Run the focused suite again with:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-settings-bar-editor -Doptimize=ReleaseSafe
```
