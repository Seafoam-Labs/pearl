# T07 verification

Exact Zig 0.16.0, ReleaseSafe. All integration sessions, audio devices, buses,
brightness files and power replies are private fixtures. No host audio or
physical power/brightness mutation was performed.

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig"
zig build install test-services -Doptimize=ReleaseSafe --summary all
zig build test test-adapter-unit test-bindings -Doptimize=ReleaseSafe --summary all
zig build test-desktop -Doptimize=ReleaseSafe --summary all -- --output artifacts/t07/desktop
zig build test-surfaces -Doptimize=ReleaseSafe --summary all -- --output artifacts/t07/surfaces
zig build integration -Doptimize=ReleaseSafe --summary all -- --output artifacts/t07/lifecycle
python3 scripts/check-pulse-bindings.py
zig fmt --check build.zig src
```

| Check | Evidence |
| --- | --- |
| 54 unit/binding tests | [final-unit.log](final-unit.log) |
| 15 service groups | [services.log](services.log), [results](../latest/results.json) |
| 15 desktop groups | [desktop.log](desktop.log), [results](../desktop/results.json) |
| 17 surface/blur checks | [surfaces.log](surfaces.log), [results](../surfaces/results.json) |
| 12 lifecycle checks | [lifecycle.log](lifecycle.log), [results](../lifecycle/results.json) |
| Fresh-cache libpulse declaration identity | [bindings.log](bindings.log) |

[Metadata](metadata.json) records versions, clean Aqueous revision, production
and instrumented binary identities, original DMS reference identity and the
pinned header manifest. [Source hashes](source-sha256.json) identify the reviewed
implementation and fixture files. Desktop/surface hashes match the installed
production Pearl; service fixtures match the lifecycle test executable, which
also checks the final production binary.

The [actual captures](../comparison.html) show service rows, battery/brightness,
profiles, permission denial, disconnected audio, confirmation and OSD.
[Power records](../latest/services/power-actions.jsonl) show delayed writes and
fake reboot denial/acceptance. Real GTK keyboard navigation activates the
confirmation path; one activation never sends a power request. Private Wayland
traces verify one OSD layer surface across 50 replacements and unchanged seat
focus. T05's previously documented private Vulkan teardown diagnostic remains
in the compositor log; Pearl passes with fatal GTK warnings enabled.

The [physical release checklist](../../../docs/SERVICES.md#validation-and-physical-release-checklist)
remains open for real backlight/battery/power hardware, authorization agents,
audio hotplug/privacy and extended performance/accessibility checks. Test
success does not claim those physical release gates complete.
