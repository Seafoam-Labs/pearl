# Power & battery verification

The implementation follows the [mockup](../power-battery-mockup/power-battery-v1.png)
and [implementation plan](../../docs/POWER_BATTERY_IMPLEMENTATION_PLAN.md).

## Delivered behavior

- Retained native controls for battery status/history/health, power profiles,
  brightness, AC/battery timing, dimming, automatic saver, and session actions.
- No battery card, source selector, or automatic-saver row without a system battery.
  Saved battery settings remain intact; AC controls remain available.
- Immediate, revision-checked power preference saves with operation receipts,
  atomic persistence, unrelated-draft preservation, and overlap rejection.
- Real compositor idle notifications and output-power requests; dimming restores
  the previous brightness after re-reading the device to honor external changes.
- Bounded session history and optional health; absent readings are never fabricated.

## Validation

Run with a writable Zig cache:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig-global" zig build -j2
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig-global" zig build test -j2
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig-global" zig build test-settings-devices -j2 -- --power-only --output artifacts/power-battery-ui
```

Build and pure tests passed. The focused integration suite uses private UPower,
profile, brightness and logind peers plus a private real Aqueous compositor. Its
[machine-readable report](report.json) records the latest run. It covers absent
battery at startup, hotplug, a valid 0% reading, invalid readings, peripheral-device
exclusion, real profile/brightness writes, scoped saves, draft conflicts,
background saver activation/restoration, real idle dim/off/wake, denial receipts,
connection-owned confirmations/cancellation, and responsive presentation.

`test-settings-boundary` and `test-security` passed. The latter includes real
lock-before-suspend sequencing, inhibitors, session validation, resume, and
AC/battery idle selection. The final security run passed all 27 checks; its
[report](security/report.json) records the tested binary hashes.

Four broader regression targets did not pass. All four also failed when run
against an untouched HEAD archive in `/tmp/pearl-power-baseline`:

| Target | Changed tree | Untouched baseline |
| --- | --- | --- |
| `test-services` | Output-removal/volume-OSD timeout. | Same check timed out. |
| `test-settings-lifecycle` | Existing compact settings probe returned Unavailable. | Same check returned Unavailable. |
| `test-settings-services` | Settings activation returned no JSON after a lock/display-preview flow. | Same failure at the same test line. |
| `test-settings-presentation` | Compositor/display connection broke during the presentation matrix. | Settings connection refused during the presentation matrix. |

See the [changed-tree log](regressions/run.log) and
[baseline log](regressions/baseline.log). These suites are not reported as passing.
The broad device suite's initial sound-control interaction also timed out; the
new `--power-only` selection exercises the power work independently.

## Captures and limits

Real native captures are in `session/`, including desktop/narrow views with and
without a battery. Values are supplied by private test devices. History reflects
actual samples collected during the test session.

Physical-panel brightness, firmware behavior, real battery capacity reporting,
and suspend/resume on a laptop still require hardware qualification. The private
test proves output-power requests and state transitions in Aqueous, not electrical
power consumption. Health is unknown if UPower does not supply aggregate capacity;
the implementation does not infer a multi-battery health rating from charge.
