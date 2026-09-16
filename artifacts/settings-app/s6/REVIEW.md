# S6 — Acceptance and visual comparison

Status: implemented and automated acceptance passed. Physical
desktop and Orca validation are pending human execution.
Date: September 15, 2026.

The application and backend integration remain **Zig**. Python drives isolated
fixtures and creates the offline screenshot comparison.

## Delivered and corrected

- `test-settings-acceptance` runs pure tests and eighteen private suites, records
  executable/report/source hashes, rejects source changes during execution and
  supports safe resume when evidence still matches. Tests never change host
  configuration, services or physical devices.
- `test-settings-presentation` covers all eleven routes and all 221 Aqueous fields,
  with real private network/Bluetooth/audio/power data. It records 102 page/layout
  checks and 44 reference/theme/scale captures, including short windows and draft
  retention through output changes.
- The former popup-based master UI suite now opens the normal application. It
  retains structured rule and display-declaration keyboard editing, shared draft,
  receipt, shortcut cancellation, mixed-scale and theme assertions. Production
  AT-SPI checks verify headings and active navigation state for every route and
  exclude hidden pages from the visible tree. Production still rejects test probes.
- Frontend crash coverage now includes an unfinished password prompt and owned
  Bluetooth discovery, with no secret replay and no established network teardown.
  Lock during a frontend-owned display preview hides the window and restores the
  output. Existing close/crash/reconnect/receipt guarantees remain covered.
- Visual review found and fixed excess Appearance rows for inactive theme modes,
  wallpaper-preview insets, excessive service-card spacing and misleading service
  footer text. Service pages now explicitly distinguish immediate controls from
  retained preference drafts. The page heading has an explicit accessible role.
- Release validation includes presentation acceptance, and the master UI gate
  checks the production Settings hash as well as Pearl's hash.

## Validation

All Zig builds use `-Doptimize=ReleaseSafe`. Final machine-readable evidence is
under [final/results.json](final/results.json); the runner records exact commands,
binary hashes and each suite report. No release publication or host installation
was performed.

| Check | Result |
| --- | --- |
| Pure tests | 107 passed |
| Release tooling tests | 5 passed |
| Standalone window / Appearance / frontend boundary | 19 / 15 / 9 groups passed |
| Standalone services / devices / presentation | 25 / 9 / 5 groups passed |
| Normal-window master UI and AT-SPI / installed launch | 11 / 8 groups passed |
| Preferences / services / connectivity / session services | 24 / 15 / 27 / 18 groups passed |
| Aqueous transactions / preview / desktop / surfaces | 22 / 3 / 15 / 17 groups passed |
| Staged packaging / compact lifecycle | 2 / 10 groups passed |
| Production build, formatting and source whitespace | Passed |

The eighteen suites contain **254 passing check groups**. Presentation's five
groups include **102 page/layout checks**. The tested production executable hashes
match the default build and staged-install evidence. [Validation summary](validation.json).
The `final/` directory is authoritative; earlier directories retain exploratory
checks from before the final fixes.

### Acceptance mapping

| Requirement | Evidence |
| --- | --- |
| Desktop/CLI/handoff, ordinary window and stable identity | `final/launch`, `final/window`, `final/packaging` |
| Concurrent launches and two sessions | `final/window`, `final/boundary` |
| Drafts across pages/close/reopen, JSON/conflict/save failure | `final/appearance`, `final/services`, `final/preferences` |
| Identity/version/frame limits and disconnect/recovery without replay | `final/boundary`, `final/appearance`, `final/services`, pure protocol/transfer tests |
| Page departure, crash, owned prompts/discovery, established connections | `final/services`, `final/compact-lifecycle`, `final/connectivity` |
| Display preview during navigation/close/lock/crash | `final/services`, `final/aqueous`, `final/preview` |
| Every route, Aqueous inventory, hidden controls and keyboard traversal | `final/presentation`, `final/master-ui`, `final/window` |
| Themes, large text, narrow/short windows, four scales | `final/presentation`, `final/master-ui`, `final/devices` |
| Monitor changes and retained draft | `final/presentation`; physical unplug remains separate |

## Visual comparison

Open the [interactive reference comparison](comparison.html). It provides all five
reference pages across dark, light, native GTK, narrow and large-text captures.
Frames are clipped from the original screenshots in the browser; images are not
retouched. [Browser validation](comparison-validation.json) checks all 35 choices.

Reproduce with:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-settings-acceptance -Doptimize=ReleaseSafe -- --output artifacts/settings-app/s6/final
python3 scripts/settings-visual-review.py --report artifacts/settings-app/s6/final/presentation/results.json
```

The grouped sidebar, selected route, fixed header/footer, rounded surfaces and
page-local scrolling follow the reference. Real device capability and validation
states replace illustrative data. Numeric controls retain exact volume/brightness
editing; static colors use Pearl's existing palette, while seed editing belongs to
dynamic mode. The complete wallpaper editor includes path/fit/color controls.
Native GTK styling and compositor window decorations intentionally vary.

This is a visual comparison and behavior review, not a claim of pixel equality
between an HTML concept and GTK. The actual captures use production presentation
code with no sample-page mode.

## Remaining physical and human evidence

[MANUAL.md](MANUAL.md) is the concrete activation, monitor and Orca checklist.
No physical-desktop or screen-reader result is claimed. Private AT-SPI inspection
does not demonstrate spoken announcements or a user's assistive-technology flow.

The pinned compositor preserves a window's assignment when a headless output is
disabled. The suite records that behavior, verifies the same process and draft
survive, and recovers using the normal window-move operation. Disabling a headless
output does not prove physical-unplug remigration; that remains a manual check.

Full release signoff remains separate, including existing licensing and physical
hardware requirements. S6 implementation/automated acceptance can be reviewed
without representing these pending manual checks as passed.
