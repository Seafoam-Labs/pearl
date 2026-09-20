# Bar opacity verification

Implemented Automatic / Custom background opacity in Settings → Bar & dock.
Custom accepts 0–100%, preserves foreground rendering, and participates in the
shared Apply & save / Discard workflow. Automatic retains existing theme and
blur behavior. Full preferences documentation is in
[PREFERENCES.md](../../docs/PREFERENCES.md#bar-background-opacity).

Verification used isolated D-Bus and Wayland sessions and private configuration
directories. The user's desktop preferences were not changed.

| Check | Result | Report |
| --- | --- | --- |
| ReleaseSafe build | Passed | `zig build -Doptimize=ReleaseSafe` |
| Pure tests | 169 passed | `zig build test -Doptimize=ReleaseSafe` |
| Settings bar editor | 17 passed | [metadata](settings/metadata.json) |
| Preferences and restart/recovery | 25 passed | [metadata](preferences/metadata.json) |
| Surfaces, blur capability changes and output reconnection | 19 passed | [results](surfaces/results.json) |
| Bar layout and rendered opacity | 45 cases passed | [metadata](layout/metadata.json) |

Representative captures:

- [Settings opacity controls](settings/session/bar-opacity-custom-settings.png)
- [Transparent bar](layout/session/opacity-dark-False-0.png)
- [50% bar](layout/session/opacity-dark-False-50.png)
- [Opaque bar](layout/session/opacity-dark-False-100.png)
- [GTK islands](layout/session/opacity-gtk-named-True-50.png)
- [Community theme islands](layout/session/opacity-package-True-50.png)
- [Missing GTK named color fallback](layout/missing-color/missing-gtk-color-uses-palette.png)
- [Custom opacity after output reconnection](surfaces/surfaces/bar-opacity-after-hotplug.png)

Pixel assertions verify absolute alpha in linear-light composition, transparent
island gaps and preserved foreground pixels. GTK fixtures expose background
areas through transparent buttons so the assertions measure the panel itself;
ordinary theme button rendering remains controlled by the theme.

The layout suite's optional launcher-icon hotplug case remains disabled on its
pinned compositor. Custom opacity hotplug is verified by the separate surface
suite, including a rendered pixel comparison before and after reconnection.
