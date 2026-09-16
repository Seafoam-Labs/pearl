# Qt/Darkly implementation evidence — 2026-09-16

Native Qt 5/6 integration is implemented. Management remains opt-in. Tests use
temporary HOME/XDG directories; session tests use private Aqueous and D-Bus.
No host theme files, installed packages, user-manager environment or Flatpak
overrides were changed.

## Results

| Check | Evidence |
| --- | --- |
| 20 native integration checks | [results](latest/results.json): actual Qt 5/6 Darkly consumers, dark/light palettes, font round trip, no-op Apply, unrelated edits, conflicts, conditional restore, crash recovery, symlink rejection, stale review, explicit repair, compact density, scaled fonts, marker handling, palette collection, dependency recheck, both-target disable, staged probe packaging, interrupted-acquisition review |
| Live palette updates | Both already-running Qt 5 and Qt 6 Widgets fixtures observe the new light palette |
| Qt Quick / Kirigami | `quick_compatibility` in the native results uses Pearl-generated dark colors with Qt 6 Fusion QML controls; partial support |
| 6 private Settings groups | [results](session/results.json): real UI opt-in with no draft writes, committed Apply, dynamic seed, wallpaper generation, GTK static fallback, reviewed repair and disable/restore |
| Existing preferences | [metadata](regressions/preferences/metadata.json): 24 preference/generator/recovery scenarios |
| Existing Appearance | [results](regressions/settings-appearance/results.json): 15 editor/draft/recovery groups |
| Backend boundary | [result](regressions/settings-boundary/result.json): private transport/session boundary checks |
| Staged Settings | [results](regressions/settings-integration/results.json): stable/Git identity, launcher handoff, installed frontend |
| Staged release | [metadata](regressions/release/metadata.json): production installation and reversible migration |
| Unit and release-tool tests | `zig build test test-release-tools` passed; the new pure Qt/INI tests are included in `test` |
| Default build | `zig build -Doptimize=ReleaseSafe` passed with optional Qt build integration off |

Captures include [the real Appearance opt-in](session/desktop/qt-appearance-enabled.png)
and real Darkly controls at [1×](latest/qt6-light-compact-1.png),
[1.5×](latest/qt6-light-compact-1.5.png) and
[2×](latest/qt6-light-compact-2.png). Focused Darkly controls use Pearl's accent
after synchronizing the four optional KDE keys.

## Reproduction

With compatible Darkly/qtct installations:

```sh
zig build test test-release-tools -Doptimize=ReleaseSafe -Dqt-themes=true
zig build test-qt-theme -Doptimize=ReleaseSafe -Dqt-themes=true -- --quick-compatibility
zig build test-qt-session -Doptimize=ReleaseSafe -Dqt-themes=true
```

The retained runs add `--libraries .cache/qt-darkly/deps/usr/lib` to both Qt
integration commands. That directory contains dependencies extracted from cached
packages solely for the private test environment. The host's existing Darkly
plugins are not package-owned and fail to load without those dependencies. The
production probe detects this condition instead of switching applications to a
broken style.

Existing regression commands were `zig build test-preferences`,
`test-settings-appearance`, `test-settings-boundary`, `test-settings-integration`
and `test-release`, with `-Doptimize=ReleaseSafe -Dqt-themes=true`. The first staged
Settings run selected the host Git edition by its shared display name. The test
now selects the exact staged desktop ID, and its isolated rerun passes. Historical
artifact paths embedded inside copied regression metadata describe original
capture locations; the current files are retained beneath `regressions/` here.

## Provenance and limits

[Provenance](q1/provenance.json) records Qt/qtct versions and hashes of both actual
Darkly binaries. The inspected source is Darkly 0.5.39 at
`65f6fa62675e3c30986f8fc8e4fdbba053096491`; this is not asserted to be the installed
binaries' revision. `q1/contract.json` and `q1/quick.json` are preliminary consumer
experiments with a system qtct palette; `latest/results.json` supersedes them with
actual Pearl-generated colors. `q1/session` contains preliminary session logs,
not a separate passed acceptance run.

Dolphin and Kate were unavailable. Installed Flatpaks provided no representative
KDE-runtime application. They remain unsupported pending explicit validation;
no runtime-specific extension packaging or per-app Flatpak override is claimed.
Fresh physical login/UWSM activation propagation, GPU presentation and full
screen-reader speech remain manual release acceptance work. The headless
fixtures establish the tested native binary contract only.

See [user/setup documentation](../../docs/QT_THEMING.md) and
[milestone status](../../docs/QT_DARKLY_IMPLEMENTATION_PLAN.md).
