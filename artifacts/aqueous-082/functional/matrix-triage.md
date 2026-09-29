# Release matrix triage, September 29, 2026

Full `scripts/release-validate.py` run at HEAD `b9fd1dd` plus the Phase 8 harness
change: 13 of 24 targets pass, 11 fail, source fingerprint unchanged
(`metadata.json`). The run used the established local override pointing the
drivers' hardcoded reference Aqueous source paths at
`.cache/aqueous-activity-production/source` (restored afterwards). No failure is
attributable to the logging workstream: `git diff ba72a98..HEAD` touches none of
the failing drivers and adds only three packaging lines (two `SyslogIdentifier=`
keys, one bugtracker URL).

## 1. Pinned-compositor abort on output-off (environmental, known)

test-surfaces, test-services, test-security, test-lock, test-clipboard-capture.

Each session's `compositor.log` ends in `thread <n> panic: reached unreachable
code` with frames `OutputManager.zig:621 validateConfigCoordinates` /
`:522 handleManagerApply` (paths under `.cache/aqueous-activity-production/source`),
triggered when the suite runs `wlr-randr --output <name> --off`; the shell and
the driver then fail downstream (BrokenPipe / stale status). The abort is in the
compositor, not Pearl. Previously recorded on this machine for test-security and
test-surfaces (2026-09-28/29).

## 2. Test expectations stale against pre-workstream source changes

- test-settings-boundary: `src/settings/server.zig:314` sends capability
  `application_profiles_version = 2`, added by `e8232b5` (2026-09-27, ancestor
  of base `ba72a98`); the driver's capability allowlist was not updated.
- test-settings-integration: `packaging/install.sh:11` requires `pearl-themes`,
  added by `cc11470` (2026-09-18, ancestor of base); the driver stages only
  pearl, pearlctl, pearl-settings, pearl-lock, so the install fails with
  `cannot stat .../binaries/pearl-themes`.
- test-settings-presentation: footer text changed by `63012d7` (2026-09-25,
  ancestor of base) to `... DND and history actions are immediate.`; the driver
  still asserts `'immediately' in footer_text`.

## 3. Pre-existing failures, verified identical at base `ba72a98`

Rebuilt and rerun from a scratch worktree at `ba72a98` with the same
`PEARL_TEST_AQUEOUS_PREFIX` (`.cache/aqueous-activity-production`):

- test-connectivity: deterministic at base and HEAD, same assertion
  (`('aqueous','status','--text','test-settings-page')` exits 4,
  `{"ok":false,"err":{"code":"Unavailable"}}`). Mechanism: after
  `pearlctl control-center show` succeeds, the settings popup closes by itself
  within the same second (`popup-opened output=1` → `settings-focus
  target=body,heading` → `popup-closed`, no error or warning in between), so the
  page-status query has no window to report on.
- test-settings-services: standalone runs time out at `test_settings_services.py:212`
  (waiting for the aqueous validate/save outcome) at both base and HEAD; under
  matrix load it fails earlier at `:144` (service prompt never appears).

## 4. Flake under matrix load

- test-settings-appearance: failed in the matrix inside the 15 s editor-ready
  wait after five passing groups; passes standalone at HEAD (exit 0) and at base
  (exit 0).

## Reproduction

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig"
export PEARL_TEST_AQUEOUS_PREFIX="$PWD/.cache/aqueous-activity-production"
# after pointing the hardcoded /home/zoey/RiderProjects/Aqueous paths in
# tests/integration/*.py at $PEARL_TEST_AQUEOUS_PREFIX/source:
zig build <target> -Doptimize=ReleaseSafe -Drelease=true -- --output <dir>
```
