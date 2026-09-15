# Aqueous 0.8.2 integration evidence

Target: `b3d486920c42e24d45bed0a79e68915fe11c4815`, helper 0.8.2,
protocol 1, Zig 0.16.0 / ReleaseSafe. Implemented according to
[the A82 plan](../../docs/AQUEOUS_082_UPDATE_PLAN.md).
The previous `artifacts/aqueous-master` bundle and `tests/fixtures/aqueous-080`
remain historical evidence for the old pin.

## Automated acceptance

| Check | Evidence |
| --- | --- |
| Unit models, routing, source identities and existing policies: 84 tests | [Unit log](unit.log) |
| Adapter: 29 tests; generated bindings: 2 tests | [Unit log](unit.log) |
| Matching helper/compositor and rebuilt patched wlroots | [Build and fixture provenance](contracts/metadata.json) |
| Settings, protected collections, structured display profiles/members, mixed candidates, stale-source conflicts and save receipts | [22 integration checks](integration/metadata.json) |
| Presentation delay, inactive-session rollback and durable preview restart recovery | [3 instrumented lifecycle checks](preview/metadata.json) |
| Native capture, SDR conversion, all eight transforms and exact isolated pixels under an overlapping window | [4 capture checks](capture/metadata.json) |
| Material dark/light, native GTK, large text, accessible names and actual keyboard editing | [10 UI checks](ui/metadata.json) |
| Canonical collection semantics, protected collections, display mutations, journal recovery, native leases and scene capture | [6 upstream suites](upstream/metadata.json) |
| Package staging, permissions, startup and reversible migration | [Installation checks](install/metadata.json) |
| Notification, tray/menu, media and session-bus recovery | [Session services](session-services/result.json) |
| Release tooling and Python syntax | Four release-tool unit tests passed; Python compileall passed |
| Complete settings inventory | [494 entries, including 221 scalar fields](../../docs/AQUEOUS_CAPABILITY_COVERAGE.md) |

Each integration report records the tested Pearl binary hash. Production and
instrumented compositor hashes are separate; the latter never authorize hardware
support. Upstream harness changes only select private artifact paths and supply
the archived revision. Its original and adapted source hashes are recorded.

The capture fixture deliberately uses fixed pixels independent of focus state.
The source and covering window have identical geometry; the covering window is
focused. The isolated PNG is identical before and after removing that cover.

## Reproduce

```sh
python3 scripts/build-aqueous-master.py
uv venv .cache/aqueous-082/test-venv
uv pip install --python .cache/aqueous-082/test-venv/bin/python \
  -r tests/fixtures/aqueous-master/schema-test-requirements.txt
python3 scripts/aqueous-master-inventory.py
python3 scripts/aqueous-master-upstream-tests.py
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build \
  test test-adapter-unit test-bindings test-aqueous-master \
  test-aqueous-preview test-capture-master test-master-ui -Doptimize=ReleaseSafe
PEARL_TEST_AQUEOUS_PREFIX="$PWD/.cache/aqueous-082" \
  ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build \
  test-release-tools test-release test-session-services -Doptimize=ReleaseSafe
python3 scripts/aqueous-coverage.py
python3 scripts/aqueous-inventory.py
```

Tests use temporary HOME/XDG directories, private sockets/buses and virtual outputs.
The source archive and rebuilt wlroots live under `.cache/aqueous-082`; the upstream
working tree and host configuration are not changed.

## Remaining restrictions

Production physical display previews, HDR/VRR and other unaccepted backend features
remain governed by upstream support flags. Physical hardware, real login-session
and screen-reader acceptance are separate from this automated integration evidence.
An unacknowledged preview begin with no token remains unresolved because upstream
requires that token for lookup; known tokens recover across Pearl restarts.
See [remaining dependencies](../../docs/AQUEOUS_MASTER_DEPENDENCIES.md).
This update does not publish or approve a public release.
