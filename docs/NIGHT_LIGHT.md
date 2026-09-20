# Night Light

Night Light preferences, scheduling, shared status and temporary-off controls
are implemented. **Screen warming is not enabled on the current Aqueous contract.**
The shell reports unavailable support and never acquires exclusive gamma control.

Open **Settings → Appearance → Night Light** to configure the saved policy.
Changes join the existing shared draft and take effect only after **Apply & save**.
Saving an enabled policy currently changes its requested state, not screen colors.
The control-center section links to Appearance and explains this limitation.

## Preferences and runtime controls

Existing version-1 files omit the new block and default to disabled:

```json
"night_light": {
  "enabled": false,
  "temperature_kelvin": 4500,
  "schedule": "manual",
  "start_minute": 1200,
  "end_minute": 420
}
```

Temperature accepts 2500–6500 K. Custom daily schedules use local time; minutes
are 0–1439, the start is inclusive and the end exclusive. Overnight intervals
work; equal start and end are invalid. Manual mode follows `enabled` all day.
The UI presents separate hour/minute controls. Invalid drafts cannot replace the
committed configuration. Older Pearl versions with strict readers reject the new
field; remove it before downgrading.

```sh
pearlctl night-light status
pearlctl night-light off
pearlctl night-light resume
```

`off` creates a temporary override without writing preferences. With a custom
schedule it expires at the next actual local-time boundary; otherwise it lasts
until Pearl restarts. `resume` clears it. Unrelated saves preserve the override;
committing different Night Light settings clears it. Schedule boundaries account
for skipped/repeated daylight-saving hours. A session-wide clock check reevaluates
policy after sleep and clock changes. Expired overrides cannot resurrect when the
clock subsequently moves backward. Lock preserves requested state and rejects
interactive mutations.
Timezone or wall-clock changes may shorten an override to the newly computed
next boundary; they never extend its original deadline.

`on`, `toggle` when it would enable warming, and `retry` return
`OutputColorEligibilityUnavailable` until a validated output backend is available.
Rejected requests do not create an override. `status` separates `requested`,
`available`, `state`, `gamma_protocol`, and per-output unavailability reasons.
It does not claim that a request changed pixels. Settings exposes the same snapshot
and generation-checked, deduplicated actions over its authenticated transport.
Its `night_light` capability means the configuration/control API exists; consult
`available` for display support.

## Aqueous prerequisite

Source inspected: Aqueous `88587243059d58d72dd0fe2146d0ebdb64f26474`, its pinned
wlroots 0.20.2 archive (SHA-256
`972c7ac44b17828f4702bfae7cd8347346a3fb5b2c1076cfa2c3fcedac5ec343`), and patches
0025/0026 for the DRM/scene color pipeline.

- `compositor/aqueous/OutputManager.zig` creates a gamma manager and installs it
  on the wlroots scene. Registry advertisement is independent of output support.
- `types/wlr_gamma_control_v1.c` rejects a zero LUT size and existing ownership,
  consumes three arrays of `uint16_t`, and emits a gamma-change event on release.
- `types/scene/wlr_scene.c` uses hardware or renderer color-transform paths and
  invalidates controls on an unsuccessful output-state test. This is source
  evidence, not a measurement of physical restoration or calibration preservation.
- Pearl's live output records provide connector, geometry, scale and enabled/power
  state, but no generation-bound HDR/calibration/color-path eligibility. The
  vendored output-management protocol also lacks that information. Settings helper
  observations cannot atomically guard later gamma writes against an output change.

The [gamma-control protocol](../bindings/protocols/wlr-gamma-control-unstable-v1.xml)
provides exclusive control and generic failure, but no positive per-write applied
acknowledgement or explanation of a failure. Its XML is vendored for the private
probe only; production currently observes advertisement without binding a manager.

Before enabling screen warming, Aqueous needs a live, output-bound contract that:

1. Identifies output/color-state generation and whether a validated SDR path is
   eligible, including HDR, calibration, renderer, scanout and mode changes.
2. Enforces eligibility at acquisition/application time and revokes unsafe controls
   before committing a conflicting color-state change. Observation alone is racy.
3. Defines composition with existing calibration, restoration on release/crash,
   and ownership conflicts without taking over another color service.
4. Gives Pearl truthful application status, or explicitly documents the weaker
   status it can establish when using legacy gamma requests.

Then implement the bounded ramp writer and resource lifecycle, prove acquisition,
coalescing, contention, hotplug, failure and restoration with protocol fixtures,
and validate each enabled physical renderer/output path. Mixed-output operation,
actual warming, HDR/calibration compatibility and physical acceptance remain open.
There is no production environment-variable bypass for this gate.

## Verification

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-night-light -Doptimize=ReleaseSafe
```

The Night Light suite uses isolated HOME/XDG directories, D-Bus and the pinned
private Aqueous build. A separate C probe checks real gamma acquisition on its
headless output; Pearl's Wayland trace must contain no acquisition requests.
The suite covers defaults, validation, shared drafts, persistence, stale operations,
deduplicated actions, runtime overrides, lock and restart. Native GLib clock tests
exercise real New York spring/fall transitions and a timezone comparison.
Results and UI captures are indexed in [the evidence directory](../artifacts/night-light/README.md).
