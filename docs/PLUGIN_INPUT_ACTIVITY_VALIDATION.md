# Input activity implementation and validation

Implemented September 18, 2026 against Aqueous
`88587243059d58d72dd0fe2146d0ebdb64f26474`. The v0.1 component ABI is unchanged;
private helper IPC is version 2. [Setup and scope](AQUEOUS_PLUGIN_ACTIVITY.md)
explain authorization, permissions and unsupported sessions.

## Results

- Pearl: 128 pure tests; 17 real-helper checks across C, Zig and Rust, including
  subscription intent, unsubscribe, traps, availability changes and denied delivery.
- Both Wasm-enabled and disabled ReleaseSafe builds passed. A private session
  confirmed the disabled build preserves approvals without starting helpers.
- Live compositor ingress reached the cat while a separate GTK application was
  focused. Bar/overlay poses, pointer presses, held-repeat/virtual exclusion,
  shared subscriptions, independent grant revocation, no-subscriber cleanup,
  reduced motion and owner revocation passed.
- Acknowledged polkit inhibition, overlapping polkit/native lock and fixture PAM
  unlock passed. Suppressing inhibitor acknowledgments in the **test binary only**
  exercised the 500 ms fallback. Input did not replay on resume.
- Existing native lock/PAM/polkit/suspend regressions passed. The previous
  `b3d4869` compositor passed the plugin/main Settings/flyout-isolation regression.
- The new production compositor passed Pearl's settings/identity/display and
  capture suites. Protocol bindings regenerate to the recorded hash. Contracts,
  capability inventory and release target hashes were refreshed from this build.
- Upstream: 6 pure activity tests, the protocol suite with Xwayland, real systemd
  MainPID/capability handoff, unsupported production headless behavior and locker
  survival passed. Latency comparison used 6 rounds × 50 samples per mode/category.
- Staging verified all four example packages, exclusion of fixtures, stable/Git/
  Intel Git launcher paths, shell-selection conditions and `KillMode=process`.
  Aqueous owns the launcher and integration units; Pearl installs neither duplicate.

[Machine-readable results](plugin-input-activity-results.json) retain the measured
latencies and binary/source identities. Pearl timing runs inject synthetic physical
presses through Aqueous's diagnostic ingress, then observe GTK's after-paint
callback for the updated cat scene. They do not measure physical keyboard, GPU
presentation or scanout latency. The small sample's empirical p95/p99 are regression
indicators, not hardware latency guarantees. Guest calls remain capped at 10 Hz;
readiness/subscription requests are separately rate limited, with immediate acks.

Production builds contain no activity injection protocol or per-input telemetry.
The forced-ack failure and scene/event/paint probes compile only into Pearl's
instrumented test binary. Aqueous diagnostic support requires an explicit private
build and inherited control FD. Tests use private displays, homes and buses; only
the upstream bootstrap suite creates its named temporary fixture unit, refusing
an existing unit and cleaning up afterward. No running desktop was changed.

Measured synthetic ingress-to-after-paint timing (24 samples each):

| Run | Median | p95 | p99 / maximum |
| --- | --- | --- | --- |
| Normal inhibition, including lock/unlock | 65.089 ms | 83.966 ms | 91.697 ms |
| Forced inhibitor timeout, including lock/unlock | 68.818 ms | 88.168 ms | 100.389 ms |

## Reproduce

Use the pinned Zig/toolchain and build the example components with `--fixtures`
as described in [the plugin guide](PLUGIN_DEVELOPMENT.md). Then:

```sh
python3 scripts/build-aqueous-master.py
python3 scripts/build-aqueous-master.py --activity-testing --prefix .cache/aqueous-activity
python3 scripts/build-aqueous-master.py --bootstrap-testing --prefix .cache/aqueous-activity-bootstrap
zig build test
zig build test-plugin-host -Dwasm-plugins=true -Dwasmtime-prefix=/absolute/wasmtime-prefix
zig build test-plugin-activity -Dwasm-plugins=true -Dwasmtime-prefix=/absolute/wasmtime-prefix
zig build test-plugin-activity -Dwasm-plugins=true -Dwasmtime-prefix=/absolute/wasmtime-prefix -- --stall-ack --output .cache/activity-stalled-ack
```

`test-plugin-activity` stages the instrumented shell/helper and supplies private
locker/PAM fixtures. It requires the diagnostic prefix and example components;
it does not enable system services. For upstream checks, run the scripts under
`.cache/aqueous-activity/source/compositor/scripts/` against the diagnostic binary;
use the separate bootstrap binary for `test-input-activity-systemd.py`.

Local logs and full metadata are under `.cache/activity-*` and
`.cache/upstream-activity-*`. The older `.cache/aqueous-082` fixture remains intact
for missing-protocol checks; `test_plugins.py --prefix` selects it explicitly.

## Open acceptance gates

Physical keyboard/mouse, compositor shortcuts, VT switching and actual display
presentation latency in a native session still require hardware acceptance.
Extended overload/long-running soak, a third-party security audit and the broader
release matrix remain open. Earlier release evidence describes its recorded
binaries; updating the integration pin does not certify a new release. Do not
interpret Preview, diagnostic ingress, or an unsupported production headless
session as proof of physical-device acceptance.
