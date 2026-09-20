# Night mode implementation plan

Status: software integration verified against Aqueous master
`cf6c4dcd649421184611d399f19cbeeb4acb4a0e` on September 19, 2026.
Saved configuration, scheduling, shared controls and the native display-write
adapter are implemented. Private headless Vulkan tests verify warming and
restoration. The complete plan is not yet delivered: physical qualification and
release dependency integration remain open. See [Night Light](NIGHT_LIGHT.md)
and [verification evidence](../artifacts/night-light/master-verification.md).

Scope assumption: “night mode” means **Night Light**, which warms display colors.
Pearl already supports manual dark/light appearance. Automatic theme switching
is a separate feature and is not required by this plan.

## Delivery status

| Stage | Status |
| --- | --- |
| 1: Display-control contract | Native output-warming-v1 landed on Aqueous master; production output qualification remains empty. |
| 2: Preferences and policy | Implemented, including validation, retained drafts, local schedules, overrides and clock-change tests. |
| 3: Service and adapter | Native leases, coalesced targets, per-output commit status and restoration implemented; physical lifecycle acceptance remains open. |
| 4: UI and CLI | Implemented with active/partial/pending/restoring/failure status and unavailable-output gating. |
| 5: Verification | Build, pure/clock tests, older-compositor feature tests and native headless runtime checks pass; physical acceptance and release repinning remain open. |

The stages below retain the original implementation requirements. The selected
backend is now the native warming protocol: Aqueous owns temperature conversion
and baseline composition, so Pearl does not generate or write legacy gamma ramps.

## Starting point before implementation

- `src/config/preferences.zig` already defines `theme.variant = dark | light`.
- `src/ui/gallery.zig` and `src/ui/i18n.zig` include a demo Night light tile and
  English/German labels, but there is no Night Light service or preference model.
- `docs/aqueous-capabilities.json` records gamma-control manager version 1 in an
  inspected registry. This is historical capability evidence, not output support.
- `docs/IMPLEMENTATION_PLAN.md` requires ownership checks and validation of the
  selected Aqueous renderer/output path before enabling Night Light.
- Services belong to the shell; compact controls and the standalone Settings
  app share backend state. Preferences use retained drafts and Apply & save.

## Intended behavior

Ship manual operation first, then a custom daily schedule. Use **Night Light**
as the UI name so it is distinct from the existing dark appearance setting.

| Control or event | Behavior |
| --- | --- |
| First launch or existing preferences | Disabled; do not acquire display color controls. |
| Settings configuration | Enable, choose temperature, and optionally set start/end times; commit through Apply & save. |
| Control-center tile | Toggle a temporary override; show whether it lasts until the next schedule boundary or session restart. |
| Resume schedule action | Clear the temporary override and immediately recompute the saved policy. |
| Temperature | Proposed range 2500–6500 K, default 4500 K; show a numeric value and warmer/cooler labels. |
| Custom schedule | Local time, default 20:00–07:00; crossing midnight works; equal start/end is invalid. |
| Mixed output support | Apply to supported outputs and show partial availability with per-output reasons. |
| Disable or session exit | Release Pearl's controls and restore through the validated backend release path. |
| Screen lock | Retain the current effect and schedule; reject interactive mutations through existing lock gates. |
| Resume or reconnect | Recompute policy, discard stale output handles, and revalidate support before applying. |

Persistent settings and temporary overrides have separate lifetimes. An override
is cleared by restart, explicit Resume schedule, or a committed Night Light
configuration change. With scheduling enabled it also expires at the next
boundary, including boundaries crossed while suspended. Unrelated preference
commits do not clear it. Runtime transitions never rewrite preferences.

Initial support targets validated SDR output paths. Sunset/sunrise, location
services, per-output temperature preferences, automatic dark-theme switching,
and HDR/color-managed operation without a verified contract are follow-ups.

## Stage 1 — Prove the display-control contract

1. Inspect the matching Aqueous and patched wlroots source/binaries identified
   by `docs/COMPATIBILITY.md` and `packaging/release.json`. Record exact revisions,
   renderer/backend, output mode, and whether the existing gamma path can safely
   coexist with calibration and color management.
2. Build an isolated probe for acquire, apply, failure, release, client death,
   output removal, and competition with another gamma client. Use private
   compositor sessions for protocol work and an explicit physical-output test
   for the visible effect and restoration.
3. Prefer the existing `zwlr_gamma_control_manager_v1` path if it passes. If it
   cannot represent eligibility or safely apply the transform, document a bounded
   Aqueous extension as a prerequisite before implementing the dependent adapter.
4. Establish how Pearl learns output eligibility and invalidates it after mode,
   renderer, HDR, or color-management changes. Unknown eligibility stays unavailable.
5. Do not terminate an existing color service or continuously retry ownership.
   A generic protocol failure must remain generic unless independent evidence
   identifies a conflict; provide an explicit Retry action.

The upstream [gamma-control protocol](https://raw.githubusercontent.com/swaywm/wlr-protocols/master/unstable/wlr-gamma-control-unstable-v1.xml)
grants exclusive per-output control, can invalidate that control with a `failed`
event, and specifies restoration when a valid control is destroyed. Its failure
event does not identify which possible cause occurred. It supplies no positive
per-write applied acknowledgement; status must describe only what the selected
backend can establish.

Exit criterion: a recorded support matrix and a proven restoration/ownership
contract. Protocol advertisement or a successful screenshot is insufficient
evidence that a physical display's colors changed.

## Stage 2 — Add preferences and deterministic policy

Files: new `src/services/night_light_policy.zig`, plus
`src/config/preferences.zig`, the shared editor field allowlists/serialization,
and `docs/PREFERENCES.md`.

Proposed preference block:

```json
"night_light": {
  "enabled": false,
  "temperature_kelvin": 4500,
  "schedule": "manual",
  "start_minute": 1200,
  "end_minute": 420
}
```

- Accept omitted fields with safe defaults, following the current version-1
  additive schema convention. Validate enum values, temperature, minute ranges
  0–1439, and unequal custom schedule boundaries. Document that older strict
  readers will reject the new field if users downgrade.
- Reuse atomic persistence, last-good recovery, external-edit detection, retained
  drafts and three-way merging. Add no separate configuration file or direct
  Settings writes.
- Keep desired policy separate from effective per-output status. Evaluate
  enabled/scheduled state, override expiry, and next transition in pure functions
  with an injected clock.
- Define custom intervals as start-inclusive and end-exclusive. Evaluate current
  local civil time through DST and timezone changes; use absolute deadlines for
  override expiry so a backward clock change does not resurrect an expired one.
- Use the next deadline plus a bounded clock-change check, and recompute on
  resume/timezone changes. Do not poll once per view or write gamma every tick.

Exit criterion: pure tests cover defaults, malformed input, midnight, boundaries,
DST jumps/repeated hours, clock/timezone changes, and override expiry after sleep.

## Stage 3 — Implement the shell-owned service and Wayland adapter

Files: new `src/services/night_light.zig` and
`src/platform/wayland/gamma_control.zig`; integrate in
`src/ui/surfaces/manager.zig`. If using gamma control, vendor pinned XML and its
license under `bindings/`, and register generated bindings in `build.zig`.

- Follow Pearl's GTK-owned Wayland dispatch pattern. Create protocol objects on
  the same connection as their `wl_output`; never introduce a competing reader.
- Maintain one service for all outputs. Match connectors using established
  output identity rules, reject ambiguous matches, and invalidate handles on
  hotplug/disconnect rather than persisting runtime IDs.
- Model off, scheduled/inactive, acquiring, active/requested, unavailable and
  failed states, plus an aggregate partial state. Keep requested temperature
  separate from confirmed capabilities; expose truthful backend status.
- Bound output counts, ramp sizes, allocations, file descriptors and retries.
  Validate buffer arithmetic against the pinned implementation. Generate finite,
  bounded, monotonic channel ramps from a documented temperature conversion;
  test neutral endpoints and any calibration composition supported by Stage 1.
- Coalesce rapid changes and preserve the final target. Start with direct changes;
  add a short bounded fade only after correctness, honoring reduced motion.
- Acquire only when the effective policy requests warming. At inactivity or
  disable, release ownership through the verified restoration path. Never attempt
  to restore a guessed “original” LUT after another client takes ownership.
- Cancel queued work and guard asynchronous completions with output/service
  generations. Handle failed controls, global removal, sleep, shutdown and crash
  cleanup without stale writes or tight retry loops.

Exit criterion: protocol fixtures demonstrate lifecycle correctness, partial
failure isolation, restoration and bounded resource use.

## Stage 4 — Connect Settings, control center and CLI

Files: `src/desktop/panels.zig`, `src/settings/appearance.zig`,
`src/settings/{protocol,backend,live_protocol,live_backend}.zig`, the relevant
navigation/view code, `src/cli/{options,protocol}.zig`,
`src/ui/surfaces/manager.zig`, and `src/ui/i18n.zig`.

1. Add a Night Light section to Appearance for the saved policy, with a live
   status summary and per-output explanations. Editing values changes the shared
   draft; Apply & save activates them. Avoid a separate preview lifetime in v1.
2. Add a control-center tile showing Off, On, Scheduled or Unavailable, with
   partial support visible. Its action sets the temporary override and offers
   Resume schedule. Link to the Appearance section for persistent configuration.
3. Extend the authenticated Settings transport with capability discovery, bounded
   snapshots and explicit override/retry operations. Reuse operation identities,
   stale-generation checks, frontend disconnect handling, and lock restrictions.
4. Proposed CLI: `pearlctl night-light status`, `on`, `off`, `toggle`, `resume`,
   and `retry`. `on`/`off`/`toggle` affect the temporary override; `resume` returns
   to saved policy. Document output statuses and meaningful errors.
5. Provide keyboard navigation, accessible names/current values, English/German
   strings, and layouts that fit small windows and larger text. Opening or closing
   a page must not acquire/release an otherwise active Night Light effect.

Exit criterion: two Settings clients, the flyout and CLI agree on state; stale or
locked requests cannot mutate it; unsaved settings remain unsaved.

## Stage 5 — Verify and document delivery

- Add `tests/integration/test_night_light.py` and a `test-night-light` build step
  with an injectable clock and isolated protocol fixtures. Test unsupported and
  mixed outputs, owner contention, acquisition/application failure, hotplug,
  restart, suspend, lock, disconnect, and shutdown/client-death restoration.
- Extend preferences and Settings tests for retained drafts, Apply/discard,
  conflicting external edits, transport compatibility and concurrent frontends.
- Run the pure suite, new feature tests, and affected `test-preferences`,
  `test-settings-appearance`, `test-settings-services`, and navigation checks.
  Run broader checks only where changes affect their contracts.
- Verify actual warming and restoration on supported physical SDR paths; record
  renderer/output details and competing-service behavior. Keep HDR, calibration,
  and untested renderer paths explicitly unsupported until separately validated.
- Capture UI states at normal/large text in dark and light themes. Screenshots
  document controls, not proof of the physical gamma transform.
- Add `docs/NIGHT_LIGHT.md` and an `artifacts/night-light/README.md` evidence index;
  update compatibility, capability coverage, preferences, CLI and progress docs.

Deliver in reviewable order: capability probe → policy/preferences → adapter and
manual controls → scheduling → physical acceptance. Stage 1 may expose an upstream
dependency; do not estimate or claim full output support before resolving it.
