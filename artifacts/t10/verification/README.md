# T10 verification — September 13, 2026

Zig 0.16.0 ReleaseSafe with the pinned Ghostty bindings. All suites below use the
same final production/instrumented binaries; hashes are checked by
`scripts/t10-evidence.py` and recorded in [report.json](report.json).

| Suite | Result |
| --- | --- |
| Pure tests | 57 passed |
| Adapter/service unit tests | 16 passed |
| Binding API test | 1 passed |
| preferences | 21 passed |
| desktop | 15 passed |
| surfaces | 17 passed |
| session-services | 18 passed |
| lifecycle | 12 passed |
| services | 15 passed |
| connectivity | 27 passed |

Total: **74 unit/binding tests and 125 integration checks/groups**.

[The T10 result](metadata.json) records defaults, atomic save, shared surface
updates, corrupt/external edits, stale revisions, bounded images, palette cache,
missing fonts/themes, malformed GTK CSS, native GTK pixel checks, reservations,
connector policies, keyboard draft recovery/merge, export ownership/backups,
failed saves, migration, larger configurations, idle work, restart recovery,
generator errors/output limits/deadlines, rapid change cancellation/coalescing,
concurrent disk edits, shutdown/reaping, and operation without matugen.

[Actual captures](../comparison.html) compare Material settings with the frozen
DMS references and show native GTK styling. Images are unedited screenshots.
The custom green/purple GTK theme is an intentionally recognizable test fixture,
not a bundled Pearl theme. Surface regression includes native Aqueous blur.

[Source checksums](source-manifest.json), [build log](build.log), [unit log](unit.log),
and per-suite logs are retained here. See [PREFERENCES.md](../../../docs/PREFERENCES.md)
for schema, limits and CLI behavior. The tests use private buses, settings,
service fixtures and headless/nested compositors; no host radio scan, theme,
wallpaper, daemon ownership or Aqueous configuration was changed. T08's separate
physical scan acceptance remains pending.
