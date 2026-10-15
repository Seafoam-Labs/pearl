# Power & battery implementation plan

Status: implemented in Zig on October 15, 2026. Native Power settings, conditional
battery presentation, scoped persistence, session history/health, automatic saver,
and idle dim/output-power control are implemented. Physical laptop qualification
remains manual; private headless validation is recorded in
[verification notes](../artifacts/power-battery-ui/verification.md).

Implementation choices: history is a bounded session history (up to six hours),
not a persisted log or a fabricated historical chart. Health uses UPower's valid
aggregate capacity when available and is otherwise unknown. UPS and peripheral
batteries are excluded. Screen-off support uses the compositor's advertised
`zwlr_output_power_manager_v1`; unsupported displays retain capability feedback.

Reference: [approved visual direction](../artifacts/power-battery-mockup/power-battery-v1.png).
The mockup's values are illustrative, not defaults or production data.

Implement the mockup with one requested behavior change: when no battery is
detected, hide the battery presentation and battery-only settings. Keep useful
power, display, sleep, and session controls available. Preserve the mockup's
layout, styling, and immediate-application behavior on supported hardware.
All application, policy, protocol, and build changes use Zig. Existing Python
integration fixtures may be extended for validation.

## 1. Required behavior

| Area | Battery detected | No battery detected |
| --- | --- | --- |
| Battery status | Show icon, percentage, actual charging state, and available time estimate. | Remove the entire status card, including history and health; collapse its space. |
| Power mode | Power saver, Balanced, Performance; mark the actual active mode. | Keep the same supported modes; power saver can still reduce desktop energy use. |
| Display | Brightness slider and inactive-screen dimming, according to capabilities. | Keep available display controls. |
| Sleep settings | Show On battery / Plugged in selector; initially select the current power source. | Hide the selector and edit plugged-in settings directly. |
| Automatic power saver | Show threshold setting for battery operation. | Hide the row and suspend battery-triggered automation. |
| Session actions | Lock, Suspend, and More. | Keep the same capability-gated actions. |

Keep the existing route identifier and “Power & battery” navigation/page title.
Do not substitute a “No battery” card, empty chart, zero-percent battery, or
disabled battery illustration. No peripheral battery should cause the laptop
battery section to appear. Validate the system power-device classification;
handle UPS devices explicitly rather than accidentally treating a mouse battery
or a UPS as a laptop battery.

Presence and power source are independent: a laptop plugged into AC still shows
its battery. A valid 0% reading still represents a battery. Missing percentage,
time estimate, history, or health does not establish absence.

Update visibility without reopening Settings after insertion/removal or service
reconnection. If the focused control disappears, move focus to the nearest
remaining section. Preserve saved battery settings through absence; do not
rewrite them to AC values. Preserve a user's selected power-source tab during
ordinary refreshes, switching to AC only when the battery becomes unavailable.

During initial discovery, do not show fabricated battery data. Distinguish
confirmed absence from an unavailable service internally. On UPower loss, clear
stale battery presentation and show a compact service-error message only when
appropriate; independent controls remain usable. Reappearance restores current
data, not a cached percentage or an old chart from a different device.

## 2. Current implementation and gaps

| Existing code | Reuse or required change |
| --- | --- |
| `src/services/power.zig` | Owns UPower, profile, logind, brightness, pending writes, service generations, and view leases. Already exposes presence, percent, state, and time estimates. Add explicit telemetry validity, health/history, and automation support. |
| `src/settings/live_backend.zig` | Currently always emits a battery row, including an unavailable placeholder; combines brightness and profile buttons. Replace the power presentation with a typed snapshot. |
| `src/settings/live_protocol.zig` | Add a power-page payload alongside the existing typed sound/network payloads; retain compatible generic data where required by older consumers. |
| `src/settings/live_view.zig` | Dispatch power snapshots to a dedicated stable view, following the sound-view integration pattern. |
| `src/settings/sound_view.zig` | Reference for persistent widgets and updating live values without interrupting slider gestures or focus. |
| `src/settings/window.zig` | Integrate styling, narrow layout, fixture pages, diagnostics, and accurate footer/save state. |
| `src/services/idle_policy.zig`, `src/services/lifecycle.zig`, `src/platform/wayland/idle.zig` | Currently support separate AC/battery lock and suspend timers, with lock-before-suspend validation. Add distinct dim and screen-off behavior; do not relabel lock as screen off. |
| `src/config/preferences.zig`, `src/settings/preference_pages.zig` | Existing idle preferences are shared with Session & lock. Extend the schema and keep both pages consistent. |
| `src/settings/backend.zig`, `src/settings/editor.zig`, `src/config/service.zig` | Existing preferences use a shared draft and explicit Apply. Implement a scoped immediate-save path for this page without applying unrelated drafts. |

Battery history, health presentation, screen dimming, screen-off timing, and
automatic low-battery profile switching are functional additions. A static
render of those controls is not completion of this plan.

## 3. Service and presentation contract

Add a pure `src/services/power_presentation.zig` model and a typed snapshot with:

- Discovery state and system battery identity/presence; optional validated
  percentage, charge state, positive time-to-empty/time-to-full, and health.
- A bounded six-hour history with timestamps and gaps, plus loading/unavailable
  state. Fetch supported history asynchronously through the shell service;
  otherwise collect a bounded session history and show the actual covered range.
- Available power modes, observed selected mode, pending requested mode,
  degradation reason, and operation-specific errors.
- Brightness availability, current value, limits, pending state, and generation.
- Current AC/battery source, saved timing/dimming/threshold values, capabilities,
  and revisions needed for safe edits.
- Existing session action capabilities and confirmations.

Do not infer “Good” from charge percentage. Read valid capacity/energy data from
the appropriate system battery devices, define the health classification in the
pure model, and display unknown when the available data cannot support it.
Establish aggregation for multiple internal batteries before exposing aggregate
health. Show charging time when charging, remaining time when discharging, and
no duration when the estimate is absent or zero.

Cap history samples and response bytes; reject invalid/future timestamps and
non-finite percentages. Break curves across missing data, device changes, and
unsupported intervals. Never stretch a short session into a fake six-hour trace.
The final measured point must agree with its timestamp and measurement; append
the current valid reading when needed rather than inventing intermediate data.

Keep all hardware access and policy in the shell. Settings owns presentation
only and sends validated operations over the existing authenticated connection.
Retain lease ownership, lock gates, generation checks, cancellation, and bounded
asynchronous calls. Background low-battery policy must work with Settings closed;
expensive chart fetching should follow page interest and stop when no view needs it.

## 4. Preferences and runtime behavior

### Timing and dimming

Extend each existing AC/battery timeout configuration with screen-off timing and
an opt-in dimming setting. Keep lock timing distinct and preserve existing values
on migration. Zero continues to mean Never where applicable. New fields default
to disabled so an upgrade cannot introduce automatic dimming, blanking, or sleep.
Dropdowns include Never and sensible minute values, while displaying an existing
custom duration accurately rather than rounding or overwriting it.

Validate timer relationships in a pure policy: dim precedes screen off; screen
off does not occur after enabled suspend; lock-before-suspend remains required.
Specify dimming as a bounded lead interval before screen off, with no dim timer
when screen off is Never. If an existing lock setting makes a new suspend value
invalid, explain the conflict and link to Session & lock; do not silently change
the user's lock timing.

Inspect the pinned Aqueous interfaces and local output-power fixture to establish
the supported display-power adapter before implementation. Screen off must use a
real supported output-power operation and restore on activity. If the compositor
lacks that contract, an adapter/compositor prerequisite remains required; the
control reports unsupported and this feature remains incomplete on that target.

Use compositor idle notifications and existing inhibitor/session gates. Restore
the previous brightness on activity only while Pearl still owns that temporary
dim operation; a manual brightness change becomes the new user intent. Handle
resume, output hotplug, backlight removal, lock, and shutdown without stale writes
or permanently dimmed/disabled outputs. Verify multiple-output behavior explicitly.

### Automatic power saver

Add a disabled-by-default threshold preference with choices Off, Below 10%,
Below 20%, and Below 30%. Do not enable it merely because the mockup shows 20%.
Activate only for a detected system battery that is discharging below the
selected threshold and when power-saver is supported. Use a five-percentage-point
exit margin to avoid oscillation. Record the prior profile and restore it on AC,
threshold recovery, battery removal, or disabling the policy only if the automatic
policy still owns the active profile and the prior profile remains supported.

An explicit user or external profile change ends automatic ownership and suppresses
re-entry until the low-battery episode ends. Serialize automatic and manual writes
through the existing profile service, check generations, and treat missing service,
denial, or unsupported profile as unavailable rather than retrying in a tight loop.
Use observed state for the selected radio button and separate pending feedback.

### Immediate application and persistence

Retain the mockup's “Changes apply automatically” behavior. Brightness and profile
changes already use immediate service operations. For persistent timing/dimming/
threshold edits, introduce a narrowly scoped backend operation that validates an
allowlisted field patch and expected committed revision, persists atomically using
the existing preference service, and publishes the successful configuration.
Do not implement auto-save by calling global `draft.apply` after each change.

Preserve unrelated shared drafts. Rebase disjoint draft edits onto the new committed
power values; reject overlapping edits with a clear conflict and retain user input.
Invalid or failed saves must not claim success or change the running policy. Return
receipts so uncertain requests can be queried without blindly replaying writes.
Keep saved values synchronized with Session & lock and Advanced, and preserve
their existing draft workflow. Document the scoped-save exception in the settings
API and preferences documentation. This is a prerequisite for the mockup footer.

## 5. Native view

Create `src/settings/power_view.zig` with stable widgets and these ordered sections:

1. Battery card: large percentage and state, estimate, history, and health.
2. Power mode: three selectable cards with icon, label, description, and a clear
   selected indicator. Unsupported modes stay visibly unavailable with a reason.
3. Display: brightness slider with percent and inactive-screen dimming toggle.
4. Sleep & energy saving: source selector, screen-off timeout, suspend timeout,
   and automatic power-saver threshold.
5. Session actions: Lock and Suspend, plus a More popover for Hibernate, Log out,
   Pause/Resume automatic idle, Restart, and Shut down. Preserve existing action
   gates and confirmation flows, including access to cancel a pending confirmation.

Use Pearl theme tokens, existing symbolic icons, spacing, cards, and typography.
Do not embed the mockup bitmap or hard-code its purple colors. Support light,
dark, GTK-derived, and high-contrast themes. At narrow widths stack mode cards,
move controls below labels, and collapse the battery card vertically. No horizontal
scrolling at supported text scales. Battery absence removes the card completely
so Power mode starts directly below the page heading.

Update in place to retain scroll, focus, open dropdowns, and slider drags. Coalesce
brightness requests using existing service semantics. Bind radio selection to
observed mode, not to a button becoming disabled. Provide keyboard navigation,
accessible names/range values/selected states, a text alternative to the chart,
English/German strings, and localized duration formatting. Avoid repeating live
percentage announcements unnecessarily.

## 6. Delivery sequence

| Stage | Deliverable and exit criterion |
| --- | --- |
| 1 — State contract | Presence/validity model, typed snapshot, conditional battery data, device classification, fixture scenarios, and pure tests. A no-battery snapshot cannot render battery content. |
| 2 — Existing controls | Dedicated native layout, real battery status, profile cards, brightness slider, session actions, hotplug updates, and no-battery layout. Existing operations retain their authorization and error behavior. |
| 3 — Battery telemetry | Real bounded history and validated health, including unknown/loading states and multi-battery policy. No fabricated values or trends. |
| 4 — Configuration | Compatible schema extensions and scoped persistence with conflict/rollback tests. Editing this page cannot apply another page's draft. |
| 5 — Energy policy | Real dim/screen-off adapter, timing validation, automatic saver, restoration, inhibitors, resume, and service-restart handling. Works with Settings closed. |
| 6 — Acceptance | All controls functional on supported targets; battery/no-battery screenshots, accessibility checks, regression results, and updated user/API documentation. |

Stages are implementation checkpoints, not permission to ship placeholder controls
as completed functionality. Mark unavailable hardware capabilities explicitly;
record unresolved compositor prerequisites before declaring the feature complete.

## 7. Validation and acceptance

Add Zig tests for presentation/visibility, timer validation, optional telemetry,
history bounds/gaps, saver hysteresis and ownership, config migration, and scoped
save isolation. Extend the existing private-service power fixture and Settings
device tests; Python remains test infrastructure only.

Required scenarios:

- Battery discharging, charging on AC, full, valid 0%, unknown percentage/estimate,
  unavailable health/history, multiple internal batteries, and peripheral-only data.
- No battery at startup: no battery card, chart, health, On battery selector, or
  automatic-saver row; no reserved blank space; AC settings and supported modes,
  brightness, and session actions remain usable.
- Battery insertion/removal while visible, including while a battery control has
  focus; UPower loss/recovery; stale responses from a previous owner/device.
- Missing backlight, missing profile service, unsupported/degraded Performance,
  permission denial, delayed writes, rapid slider interaction, and external changes.
- Threshold crossing/recovery, AC connection, manual profile override, battery
  removal, and daemon restart, with Settings both open and closed.
- Idle dim/restore, real screen off/wake, suspend lock ordering, inhibitors,
  multiple displays, and resume. A screenshot alone does not prove output power.
- Persistence across restart, invalid and failed writes, overlapping edits,
  unrelated dirty drafts, second Settings clients, and operation receipt recovery.
- Narrow/short windows, large text, keyboard-only interaction, screen-reader
  semantics, German labels, theme changes, and preserved focus during live updates.

Run `zig build test` plus the build and focused integration targets appropriate
to each stage. Final affected coverage includes `test-services`,
`test-settings-devices`, `test-settings-services`, `test-settings-boundary`,
`test-settings-lifecycle`, `test-settings-presentation`, and `test-security`.
Extend existing targets where practical; add a focused power UI target only if
it provides independently useful coverage. Use private sessions and fixtures for
tests; physical backlight/output-power and wake behavior require hardware validation.

Save final captures and verification results under `artifacts/power-battery-ui/`,
including battery-present and battery-absent states at desktop and narrow sizes.
Update `docs/PREFERENCES.md`, `docs/SETTINGS_FRONTEND_API.md`, and
`docs/SETTINGS_SERVICE_OWNERSHIP.md` with the delivered schema, save semantics,
service ownership, and capability limitations.
