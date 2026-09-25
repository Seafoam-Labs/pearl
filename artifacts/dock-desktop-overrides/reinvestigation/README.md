# Issue #3: Pearl-only reinvestigation

Recorded 2026-09-24 against runtime source at `17dc872`, using the existing
integration build. [Results](results.json) include its SHA-256. No runtime or
Aqueous source changes were made for this investigation.

The observations reproduce two matching gaps: a custom pin does not receive its
running window, and duplicate StartupWMClass matches become unmatched even when
one matching launcher is pinned. A separately named launcher without a matching
identity also remains disconnected from its pin. Same-ID SVG override rendering
and launch arguments work, including spaces in the icon path. GIO accepts a
desktop ID with spaces that Pearl's CLI rejects.

These are **baseline observations**, including defects, not evidence of a passing
fix. The diagnostic runner has now been converted to
`tests/integration/test_preferred_launchers.py`, which asserts the corrected
matching and pin behavior. This is synthetic coverage; the reporter's precise
application remains unverified.

Run the replacement acceptance suite against the current integration build:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-preferred-launchers \
  -Doptimize=ReleaseSafe -- --output .cache/issue-3-preferred
```

Uses private HOME/XDG roots, D-Bus and a headless Aqueous session with real GTK
input. It requires permission to create local sockets and the existing local
Aqueous input fixture. Screenshots and full session logs go to the chosen output
directory; the compact report is retained here.

See the revised [Pearl fix plan](../../../docs/DOCK_LAUNCH_ATTRIBUTION_PLAN.md).
