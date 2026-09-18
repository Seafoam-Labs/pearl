# Native community theme acceptance

September 18, 2026. All sessions used private XDG directories, compositor and
bus; the user's desktop theme was not changed. The deployed implementation and
`pearl-themes` author/package tool are Zig. Python runners are test infrastructure.

[acceptance.json](acceptance.json) records the actual binary hashes, initial
fixture manifest/archive digest, exact dark/light role values and style tokens.
The fixture is original, CC0, and shares colors/tokens with
[`themes/examples/meadow`](../../themes/examples/meadow/theme.json).

- [Dark palette and installed-package/preview controls](session/custom-palette.png)
- [Light palette, compact density and larger text](session/custom-light-compact-large-text.png)
- [Light frontend probe](light-probe.json): successful committed appearance with no editor error.

Passed: `test` (133 cases), `test-theme-packages`, `test-theme-repository`,
`test-custom-themes`, `test-preferences`, `test-settings-appearance` (15 groups),
`test-settings-boundary`, `test-components`, `test-lock`, `test-border-theme`,
`test-qt-theme-unit`, and `test-release`. Regression reports are in
[`regressions/`](regressions/). Native package/repository tests use temporary
data roots and print their results; they do not retain downloaded files.
The final three theme suites also passed with `-Doptimize=ReleaseSafe`; see
[native suite output](native-tests.log) and [unit suite output](unit-tests.log).

Coverage includes arbitrary previously unknown IDs published on a second HTTPS
index page; exact release pinning; immutable versions across pages and removal;
source conflicts; offline metadata; HTTPS-only redirects; malformed paths,
symlinks and CSS; duplicate IDs; catalog pagination; native archive round trips;
edited-file protection; interruption at journal/publication/receipt/removal
boundaries; independent style/color resolution; GTK preview/draft/discard;
light/dark styles and user typography/density; stale-catalog Apply rejection;
18 successive updates with bounded snapshot retention; package removal and
restart recovery; explicit built-in recovery; and no Matugen process for fixed
palettes. Explicit generated previews cover success, subprocess failure and
cancellation with temporary-file cleanup and unchanged committed preferences.
The GUI stale-read case is tested during another editor's commits.

`test-settings-presentation` rendered its theme/size cases but did not pass the
monitor-removal check: the private Aqueous compositor asserted in
`OutputManager.validateConfigCoordinates`. See
[the result](regressions/presentation.json) and
[compositor trace](regressions/presentation-compositor.log). No compositor source
was changed as part of this work. One parallel Appearance run also encountered
a GTK “snapshot GtkGizmo without a current allocation” warning; the subsequent
isolated full Appearance run passed.

This evidence does not mark the entire roadmap complete. Image-backed CSS,
automatic discovery, application profiles/full render
data, default repository hosting and additional visual coverage remain tracked
in the [implementation plan](../../docs/CUSTOM_THEMES_IMPLEMENTATION_PLAN.md).
