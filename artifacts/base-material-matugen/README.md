# Base Material application profiles — local verification

Implemented September 27, 2026, against the pinned DMS inventory in
[src/theme/material/coverage.json](../../src/theme/material/coverage.json).
Niri, Hyprland, MangoWC and dgop are excluded. Source assets, role mapping and
licenses are recorded in [ATTRIBUTION.md](../../src/theme/material/ATTRIBUTION.md).

Passing checks:

- `zig build test -Doptimize=ReleaseSafe`: pure unit suite.
- `zig build test-base-material-profiles -Doptimize=ReleaseSafe`: native Matugen
  suite (73 tests), existing Seafoam format checks and
  [23-target integration results](results.json). Includes fixed palettes,
  independent parsers, a real Neovim load, VSIX contents, Flatpak ownership,
  missing Matugen, explicit Pywalfox argv, snapshot Retry, GTK restoration and
  isolation of a redirected GTK destination from valid target updates.
- `zig build test-base-material-session -Doptimize=ReleaseSafe`:
  [actual Settings and GTK 3/4 consumers](session-test/results.json), including
  shared draft, Apply/Discard, both variants, restart and restoration.
- `test-wallpaper-profiles`: [live updates and recovery](wallpaper/acceptance.json).
- `test-preferences`: 25 preference, palette, GTK, persistence and recovery checks
  passed in private roots (see `preferences/` screenshots and session logs).
- `test-theme-completion`: [packages, snapshots and controls](theme-completion/acceptance.json).
- `test-settings-appearance`: [15 Settings groups](settings/results.json).
- `test-qt-theme`: [15 QtEngine/Darkly groups](qt/results.json), using the existing
  isolated `.cache/qtengine/install` prefix for Qt 5/6 plugins.

The static palette is byte-for-byte reproducible with Matugen 4.2.0 using
`scripts/generate-material-palette.py`. Its SHA-256 is
`f2fe2bf75fbd76d4b9f76f59b87e89d3d7196ce45e3df5cd23aadb35bdf20109`.
Rendered outputs for supported variants are saved alongside this report; desktop
screenshots are in `session-test/session/` and the regression directories.

The initial desktop test attempt could not bind private D-Bus sockets under the
sandbox; those tests were rerun with local socket access. The Settings suite
passed on rerun after an initial seed-field input timeout. The system Qt 5
QtEngine plugin was unavailable; the documented isolated prefix passed both
runtimes. Historical evidence outside this directory was restored after those
initial attempts.

All writes used private XDG roots and nested desktops. These checks do not
certify every third-party application's live activation: browsers, Discord
clients, terminal reloads, Emacs, Fcitx5, VS Code-family activation and the real
Pywalfox browser helper still require application-specific manual verification.
The Pywalfox action was checked with a private helper fixture. Fluxer and Steam
are explicitly dark-only. VSIX palette updates require reinstalling the generated
extension; Pearl does not modify installed extension directories.
