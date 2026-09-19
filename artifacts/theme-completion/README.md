# Community theme completion evidence

Local implementation, September 18, 2026. Production theme tooling is Zig;
Python files are development test drivers only. The GitHub community project has
not been created or published and the built-in source flag remains disabled.

`acceptance.json` records the exact fixture package digest, Matugen 4.2.0, complete
fixed render input hash and normalized PNG identity. `session/` contains shell,
Settings and compositor logs and screenshots of committed/preview images and the
application controls. The fixture is original and runs entirely in private XDG
roots; no host application configuration is changed.

Validated behavior:

- PNG decode/normalization and GResource lookup/release; corrupt PNG/APNG/path
  rejection, chunk offset/hash rejection, retention, corrupt-history protection
  and the durable asset quota.
- Event-driven missing-root creation, nested edits/removal, verification after
  watch rebuilding, idle timer teardown and backend catalog notifications.
- Complete dark/light fixed Matugen values, explicitly normalized default roles,
  all five attributed Seafoam templates (independent JSON/TOML syntax checks), cache reuse, immutable app snapshots,
  writer ownership, user-edit preservation and Starship review/backup/restore.
- Real package inheritance with Zed enabled and Steam Off, bounded multi-chunk
  frontend transfer, GTK preview, shared application draft/Discard, retry after
  template edits and image/profile recovery after package removal and restart.
- Native deterministic archives and two-page publication (17 arbitrary IDs),
  index/archive hashes, source removal persistence and explicit/empty lists in
  both enabled and disabled default-source builds. `verify_profiles` also renders
  both variants of the original publishable Mist example without installing it.

Regression reports are under `regressions/`. Passed targets: ReleaseSafe pure
and native tests; `test-theme-assets`, `test-matugen`, `test-theme-discovery`,
`test-theme-packages`, `test-theme-publishing`, `test-theme-repository`,
`test-theme-completion`, `test-custom-themes`, `test-preferences`,
`test-settings-appearance`, `test-settings-boundary`, `test-border-theme`,
`test-components`, `test-lock`, `test-release-tools`, `test-release` and `test-qt-session` (six groups with the private QtEngine fixture).
The production ReleaseSafe build passed. Qt integration passes with the existing
private `.cache/qtengine/install` fixture (15 groups); the host-only attempt lacked
the Qt 5 platform-theme plugin. Pure Qt contracts run with `test`.
Some retained execution logs include initial failures and their diagnosis;
`desktop.log`, `final-desktop.log`, `qt.log` and the JSON reports record corrected
outcomes. Historical artifact directories were restored after copying evidence.

## Gates that are still open

- `test-settings-presentation` reaches its output-removal case and reproduces the
  previously recorded Aqueous assertion in `OutputManager.validateConfigCoordinates`.
  See `regressions/presentation.json` and `presentation-compositor.log`. Earlier
  dark/light/native, scale, narrow and short-window checks pass. This is an
  unresolved release gate, not a passing full presentation result.
- The concrete archives and generation pages are in `publication/`. Actual
  community maintainers, repository creation/settings, pinned CI binary
  URLs/hashes, immutable GitHub release upload, public HTTPS round trip and final
  default-source enablement require the scaffold's launch process. Fixture HTTPS
  acceptance does not certify an unpublished GitHub endpoint.
- Physical application activation/reload behavior, Orca/physical-monitor testing,
  exhaustive crash-injection/low-memory/image visual combinations and the full
  adversarial acceptance matrix in the plan are not all certified by these
  focused tests. Starship fixture syntax is checked by the development parser; runtime
  installation remains explicitly reviewed and ownership protected. Do not mark all
  original T5/T6/T7 or M1–M6 manual acceptance criteria complete from this report.

Reproduction uses the commands in docs/DEVELOPMENT.md. The new author/repository
contracts and downgrade/recovery guidance are in docs/CUSTOM_THEMES.md and
THEME_REPOSITORIES.md. The reviewable project is `community-repository/`.
