# Night Light verification

For the newer native adapter, see [Aqueous master verification](master-verification.md).
The original evidence below concerns the pinned older compositor.

`zig build test-night-light -Doptimize=ReleaseSafe` writes the private-session
report to `latest/results.json` and logs/captures to `latest/session/`.
`zig build test-night-light-clock -Doptimize=ReleaseSafe` runs the native GLib
timezone/DST tests separately; policy tests are also in the normal pure suite.

This evidence concerns configuration and unavailable-output gating. It does not
establish physical warming, gamma restoration, HDR or calibration compatibility.
Production display writes remain blocked as described in
[Night Light](../../docs/NIGHT_LIGHT.md).

Recorded September 19, 2026:

| Check | Result |
| --- | --- |
| ReleaseSafe production build | Passed |
| `test-night-light` | Passed: 156 pure tests, 6 native policy/clock tests and 12 private-session check groups |
| `test-preferences` | Passed; [report](regressions/preferences/metadata.json) |
| `test-settings-appearance` | Harness reports 15 groups passed; [report](regressions/appearance/results.json) |
| `test-settings-pages` | Passed; [report](regressions/pages/results.json) |

The initial `test-settings-services` run passed 15 groups before timing out on the
Aqueous Apply pointer action, while its backend remained idle and validated.
That run is preserved in [its report](regressions/services/report.json); it must
not be counted as a passing complete service regression.
A [repeat on the final implementation](regressions/services-retry/report.json)
and an [unchanged HEAD comparison](regressions/services-baseline/report.json)
at `3e74ec13a90c2f40ecbb30695c1392d0523356f4` fail at the same Apply action after
the same 15 passing groups. The baseline was extracted into
`/tmp/pearl-night-baseline` with `git archive` and used the same pinned private
Aqueous dependency. This failure predates the Night Light changes.

The private compositor probe reports an advertised manager, zero gamma size and
failed acquisition on pixman/headless. No output write is attempted by Pearl.
See [the feature report](latest/results.json),
[Appearance draft capture](latest/session/appearance-night-light-draft.png), and
[compact-control capture](latest/session/control-center-unavailable.png).
