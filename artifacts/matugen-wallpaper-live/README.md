# Live Matugen wallpaper updates

Verified September 20, 2026, with Zig 0.16.0 and Matugen 4.2.0.

The full build and all requested checks passed:

- `test-wallpaper-profiles`: 29 private-session checks, including in-place and
  atomic image replacement, shared extraction, source modes, dirty drafts,
  obsolete-job cancellation, changes during initial extraction, lock/unlock,
  missing files, directory-watch recovery, ownership conflicts, restart with
  removed profiles, bounded storage and subprocess cleanup.
- `test-matugen`: 51 native tests plus real rendering/format checks.
- `test-preferences`, `test-theme-completion`, and `test-border-theme`: passed.
- `test-settings-appearance`: all 15 groups passed. An earlier concurrent run
  failed its Settings shutdown check; isolated rerun and final verification both
  passed without changing that test or its shutdown assertion.

[Live acceptance](acceptance.json), [build/regression output](verification.log),
[Settings output](settings-verification.log), [preferences checks](preferences.json),
[theme completion](theme-completion.json), and [build identity](build.json)
contain the recorded results. Session logs retain generation/cancellation evidence.

## Observed latency

All five bundled profiles were enabled in a private headless session on an
AMD Ryzen 9 9950X3D shared workstation. Measurements include image creation,
event debounce, extraction/rendering, output publication and waiting for the
pipeline to settle. Fixtures are solid-color PNGs; running consumer activation
is not measured.

| Input | Samples | Median | Sample p95 |
| --- | ---: | ---: | ---: |
| Cached 64×64 images | 4 | 254 ms | 280 ms |
| Cold 64×64 images | 2 | 345 ms | 359 ms |
| Cold 2048×2048 images | 3 | 396 ms | 398 ms |

The cached-update target of 500 ms was met on this machine. These small samples
are descriptive, not a universal latency guarantee for photographs or other
hardware. Existing application activation requirements remain unchanged.

## Reproduce

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build install test-wallpaper-profiles test-matugen test-preferences test-theme-completion test-border-theme -Doptimize=ReleaseSafe --summary all
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-settings-appearance -Doptimize=ReleaseSafe --summary all -- --output artifacts/matugen-wallpaper-live/settings-regression
```

The integration harness uses private configuration, compositor and D-Bus roots.
Local socket permission is required. See the
[implementation plan](../../docs/MATUGEN_WALLPAPER_LIVE_UPDATE_PLAN.md).
