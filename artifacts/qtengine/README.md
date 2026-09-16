# QtEngine + Darkly application style — 2026-09-16

Pearl now manages QtEngine's shared Qt 5/6 JSON configuration and a generated KDE
color scheme. Darkly remains the application widget style. The supplied
`pearl-darkly-style` package excludes KWin decorations, KCM applications and
Plasma theme assets.

## Passing verification

| Test | Evidence |
| --- | --- |
| 16 QtEngine integration groups | [results](latest/results.json): actual Qt 5/6 QtEngine proxy over Darkly, palette/font consumption, unrelated JSON preservation, idempotence, marker handling, Quick/Kirigami inheritance, both running runtimes updating, density/scaling, conflicts/GC/restore, reviewed repair, interrupted writes, legacy qtct migration and external edits, override diagnostics, missing dependencies, symlink rejection and staged probes |
| 6 Settings session groups | [results](session/results.json): actual opt-in UI, no draft writes, committed dynamic seed/wallpaper, GTK fallback, backend review/reapply and disable/restore |
| 15 existing Appearance groups | [results](regressions/appearance/results.json): shared drafts, conflicts, lock gating, narrow/large-text views, recovery and close/reopen |
| Unit and release-tool tests | [log](logs/unit-release-tools.log): `zig build test test-release-tools` passed; includes new bounded JSON leaf and KDE scheme tests |
| Staged production release | [metadata](regressions/release/metadata.json): production payload/session checks and reversible migration |
| Application-only Darkly package | [provenance](provenance.json): exact staged three-file payload, hashes and dependency resolution; neither style needs KWin/KDecoration or legacy Qt 5 Kirigami |

Actual controls are captured at [1×](latest/qt6-light-1.png),
[1.5×](latest/qt6-light-1.5.png) and [2×](latest/qt6-light-2.png), plus the
[Appearance opt-in](session/desktop/qt-appearance-enabled.png). QtEngine uses
integer point fonts; Pearl's 14 logical pixels map to 11 points. The fixture's
existing semibold weight is preserved, demonstrating unrelated JSON retention.

The first Appearance attempt exposed fixed-size test scrolling oscillating past
a partly clipped control in a small viewport. The shared test helper now scrolls
the remaining distance near a control; both the QtEngine workflow and full
Appearance regression pass. Earlier QtEngine experiments used the old Darkly
binaries with an isolated library overlay. The final native and session runs use
the newly built application-only styles and repaired host libraries, with no
legacy dependency overlay.

## Reproduction and provenance

QtEngine source: `073987f0120ac77a92fb9f0c0877aa7f1f04d3bf`.
Darkly 0.5.39 source: `65f6fa62675e3c30986f8fc8e4fdbba053096491`, with
`packaging/arch-darkly-style/application-style.patch`. Private CMake builds and
the `package()` staging function were exercised. This is not a claim that a
complete Shelly installation was executed on the host.

Private plugins were staged under `.cache/qtengine/install/lib/{qt,qt6}/plugins`.
Commands:

```sh
zig build test test-release-tools -Doptimize=ReleaseSafe -Dqt-themes=true
zig build test-qt-theme -Doptimize=ReleaseSafe -Dqt-themes=true -- --engine-prefix .cache/qtengine/install --quick-compatibility
zig build test-qt-session -Doptimize=ReleaseSafe -Dqt-themes=true -- --engine-prefix .cache/qtengine/install
zig build test-settings-appearance -Doptimize=ReleaseSafe -Dqt-themes=true -- --output artifacts/qtengine/regressions/appearance
zig build test-release -Doptimize=ReleaseSafe -Dqt-themes=true -- --output artifacts/qtengine/regressions/release
```

Tests use temporary HOME/XDG directories and private D-Bus/Aqueous sessions.
Host packages, appearance preferences, activation environment and plugin files
were not changed. The Shelly setup/backup scripts were syntax checked, not run.

Qt Quick/Kirigami are partial support through Fusion QML palette inheritance.
Dolphin/Kate and KDE-runtime Flatpak remain unverified/unsupported, and fresh
physical login/UWSM propagation, GPU presentation and screen-reader speech remain
manual acceptance work. See [setup and ownership](../../docs/QT_THEMING.md).
