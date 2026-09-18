# Live input activity for Pearl plugins

Status: implemented and tested in isolated compositor sessions, September 18, 2026.
Physical hardware/VT acceptance remains open. See the
[implementation validation record](PLUGIN_INPUT_ACTIVITY_VALIDATION.md) for measured
results, commands and the remaining release gates.

## Outcome

When Pearl Cat is enabled and the user grants input activity access, it should
animate while the user types or presses mouse buttons in other applications.
Activity remains coarse and rate limited: this is a typing indicator, not a
one-animation-per-key counter. Clicking the cat and Settings Preview continue to
work when global activity is unavailable.

Keep plugin controls exclusively in **main Settings → Plugins**. Keep permissions
off by default, preserve package approval, and retain graceful operation on older
Aqueous builds and launches without activity authorization.

## Verified upstream contract

The local Aqueous checkout at `/home/zoey/RiderProjects/Aqueous` has both `master`
and `origin/master` at **`88587243059d58d72dd0fe2146d0ebdb64f26474`**. This is the
reviewed integration target, not an instruction to follow a moving branch during
builds. Review covered the actual XML, compositor state machine/manager, bootstrap,
launcher, packaging, and test sources at that revision.

| Item | Reviewed contract |
| --- | --- |
| Protocol | `aqueous-input-activity-v1`; manager, subscription and inhibitor interfaces all version 1 |
| Transport | Existing GTK/GDK Wayland connection; no activity feed in shell IPC snapshots |
| Payload | Generation, notification sequence and category bits: keyboard `1`, mouse `2`, both `3` |
| Privacy | No key/button identity, text, modifiers, coordinates, device/app identity, input timestamps, press counts or intensity |
| Eligible input | Fresh physical keyboard and pointer-button presses on the default seat, including compositor shortcuts |
| Excluded input | Repeats, releases, virtual devices, motion, scrolling, touch, tablets and other seats |
| Rate/queue | Minimum 100 ms interval; one unacknowledged notification and one pending mask; pending activity older than 100 ms is dropped |
| Acknowledgment | Ack the exact generation and notification sequence; 1000 ms without an ack invalidates readiness |
| Availability | `available`, `permission_denied`, `unsupported`, `suspended`; the first authorized subscription starts suspended |
| Source gates | Authorized living owner, ready subscription, active native session, unlocked compositor and no inhibitors |
| Bootstrap | Aqueous's installed launcher obtains a one-use process/instance-bound capability FD for its expected Pearl service MainPID |
| Compatibility | Production nested/headless sessions without a native session source are unsupported; test support is explicitly compiled in |

XML SHA-256:
`a564fe42e852247fb7c7c2acb06702b0d35aad0444076beb30b09eded01f0cc4`.

Upstream references, pinned to the reviewed commit:

- [Protocol XML](https://github.com/Seafoam-Labs/Aqueous-clean/blob/88587243059d58d72dd0fe2146d0ebdb64f26474/compositor/protocol/aqueous-input-activity-v1.xml)
  and [consumer contract](https://github.com/Seafoam-Labs/Aqueous-clean/blob/88587243059d58d72dd0fe2146d0ebdb64f26474/compositor/protocol/aqueous-input-activity-v1.md).
- [Protocol manager](https://github.com/Seafoam-Labs/Aqueous-clean/blob/88587243059d58d72dd0fe2146d0ebdb64f26474/compositor/aqueous/InputActivityManager.zig)
  and [activity policy](https://github.com/Seafoam-Labs/Aqueous-clean/blob/88587243059d58d72dd0fe2146d0ebdb64f26474/compositor/aqueous/input_activity.zig).
- [Authorization bootstrap](https://github.com/Seafoam-Labs/Aqueous-clean/blob/88587243059d58d72dd0fe2146d0ebdb64f26474/compositor/aqueous/activity_bootstrap.c),
  [launcher](https://github.com/Seafoam-Labs/Aqueous-clean/blob/88587243059d58d72dd0fe2146d0ebdb64f26474/compositor/aqueous/activity_launch.c)
  and [latency methodology/results](https://github.com/Seafoam-Labs/Aqueous-clean/blob/88587243059d58d72dd0fe2146d0ebdb64f26474/docs/input-activity-latency.md).

The upstream contract references `docs/input-activity-validation.md`, but that
file is absent from the reviewed checkout. Do not treat it as validation evidence.
The available latency record measures synthetic compositor/application handling,
not Pearl animation latency or physical typing. Re-run the supplied suites and
record Pearl's own acceptance evidence.

## Compatibility decisions

1. **Retain `pearl:plugin@0.1.0`.** Deliver the existing `activity` event with
   `count = 1`, meaning one coalesced notification, never a number of physical
   presses. Keep category masks internal to Pearl. Keyboard/mouse-specific guest
   behavior can use a separately versioned WIT change later.
2. **Use one session-owned broker and at most one live subscription.** Each guest
   requests delivery with the existing `input-activity(true)` call. Delivery also
   requires its declared capability, saved grant, current approved package and
   enabled/live instance. `false` removes that instance's request.
3. **Authorize early, subscribe on demand.** Consume the launch capability within
   its 10-second expiry, even if no plugin currently needs input. Retain the
   authorized manager until shutdown. Destroying it loses authorization for this
   launch; toggling plugins should only create/destroy the subscription.
4. **Version the private helper protocol separately.** Move supervisor/helper IPC
   to version 2 for host availability updates and subscription intent. The WIT
   interface and existing component packages remain compatible. Mixed helper
   versions fail with a clear mismatch instead of silently ignoring fields.
5. **Do not collect when unused.** Once no eligible guest wants activity, remove
   the subscription and clear pending events. Local inhibition tokens still
   prevent a new subscription from becoming ready during authentication.

## Implementation stages

### 1. Pin and generate the protocol

Files: `bindings/protocols/`, `bindings/licenses/`, `build.zig`,
`scripts/aqueous-target.json`, Aqueous build/fixture scripts and provenance docs.

- Vendor the reviewed XML with its MIT permission notice. Record the revision,
  input hash and generated output hash in `bindings/protocols/inputs.json`.
- Generate the manager, subscription and inhibitor through the existing
  zig-wayland scanner. Reuse the GTK connection pattern in
  `src/platform/wayland/effects.zig`; no competing reader, private display
  connection, handwritten wire code or blocking Wayland roundtrip.
- Build the new pinned Aqueous in a separate private prefix and refresh test
  provenance. Check the existing shell identity, settings, display and capture
  contracts before changing Pearl's general integration pin. Keep the previous
  target as a fixture for missing-protocol fallback tests.
- Keep `input-activity-testing` off in production and release packages. Use a
  separately named diagnostic build for injected-input acceptance.

Exit check: reproducible binding generation, enabled/disabled Pearl builds, and
existing Aqueous handshake/bindings checks pass against recorded inputs.

### 2. Own the launch capability and Wayland broker

Files: `src/main.zig`, `src/core/application.zig`,
new `src/platform/wayland/input_activity.zig`,
new pure `src/plugins/activity_policy.zig`, `src/ui/surfaces/manager.zig`.

- At Pearl startup, capture and validate `AQUEOUS_INPUT_ACTIVITY_FD`, set
  `FD_CLOEXEC` immediately, and remove the variable before starting workers or
  child processes. Clean retained environment copies used for spawning. Close
  the FD on every exit, error, demo and runtime-disabled path.
- Transfer ownership once to the broker. Bind version 1 on GDK's existing
  connection, validate capabilities, submit authorization, close the local FD
  after marshalling and flush through GDK. Never forward the proof to helpers,
  settings processes, applications or the locker.
- Track authorization, source status, subscription incarnation, compositor
  generation, request serials, notification sequence and local lifecycle epoch
  separately. A new plugin process has its own generation too.
- On the initial suspended state, request readiness for that generation when
  local gates allow it. Await the matching state ack before dispatch. Re-handshake
  after source-generation changes; avoid a readiness retry loop while suspended.
- Ack validated current notifications promptly on the GTK thread, independently
  of guest speed. Stale, duplicate or unknown-generation packets must not revive
  delivery or acknowledge newer input. Validate masks and clear pending data on
  every readiness, owner, generation or session transition.
- Handle absence, denial, timeout, global removal and shutdown without destroying
  GTK's display. Revoked manager authority requires a fresh service launch; a
  timed-out subscription can recover under its still-authorized manager.
- Deduplicate requests and rate-limit recovery below upstream's 64 requests/sec
  resource budget. Destroy child resources explicitly and keep callback ownership
  valid through asynchronous completion.

Exit check: state-machine and private Wayland tests cover startup, readiness,
stale generations/acks, timeout, denial and cleanup, with no FD leakage or damage
to ordinary GTK surfaces.

### 3. Connect guests to availability and bounded delivery

Files: `src/plugins/{manager,protocol,runtime,model}.zig`,
`src/plugin_host_main.zig`, `plugins/wit/plugin.wit` comments and SDK docs.

- Replace the launch-only grant boolean as the source of availability. Private
  v2 requests carry host state/epoch; replies carry guest subscription intent.
  Keep grants authoritative in the parent. `input-activity(true/false)` records
  intent and returns current availability without blocking on Wayland.
- Commit intent only after a successful guest callback, alongside the existing
  atomic scene/timer changes. A trap cannot leave an active subscription request
  behind. Repeated calls are idempotent; ungranted requests cannot acquire access.
- Add an acknowledged private host-state message that updates the runtime without
  calling Wasm. Serialize it with existing request sequencing; supply the latest
  state before the next guest event. Do not fake clicks/Preview to announce a
  capability change or restart unrelated plugins for broker status changes.
- Return `permission-denied` for missing grants or rejected authorization,
  `unsupported` for an absent protocol/source, `suspended` for pending readiness
  or lifecycle inhibition, and `available` only after all gates are open.
- Hold at most one pending category mask per guest with a local receipt time and
  source/plugin epochs. Merge bits, never increment a press counter. Drop data
  older than 100 ms rather than replaying a backlog after a stall.
- Integrate activity into the existing 100 ms guest rate limit. Schedule the
  earliest allowed callback instead of adding an unconditional second 100 ms
  delay. Busy/rate-limited activity is normal backpressure, not a plugin failure.
  Prioritize control/state and user interaction; ensure activity cannot starve
  timers or make timer rate-limit collisions fatal.
- Recheck approval, grant, enablement, intent, session and generations immediately
  before sending and before accepting related results. Clear queues on unsubscribe,
  revoke, disable, crash, retry, lock and disconnect.

Exit check: actual C/Zig/Rust helpers demonstrate subscribe/unsubscribe,
availability changes, grant enforcement, one busy plus one pending notification,
no stale replay, and unchanged click/timer behavior. The existing cat component
receives `activity` without a WIT ABI change.

### 4. Suspend before authentication and locking

Files: `src/services/polkit.zig`, `src/services/lifecycle.zig`,
`src/ui/surfaces/manager.zig`, broker and lifecycle tests.

The existing surface privacy gate is necessary but insufficient: polkit currently
presents its window before notifying observers, and lock preparation notifies
after spawning the locker. Move inhibition ahead of those operations.

- Add asynchronous sensitive-flow tokens owned by each polkit or lock flow.
  First disable local dispatch, clear queues and invalidate in-flight results;
  retain the existing removal of plugin views/helpers.
- If subscribed, create a compositor inhibitor with a unique serial. Normally,
  wait for its **suspended state acknowledgment** before presenting an interactive
  authentication prompt, initiating the conversation, or launching Pearl's locker.
  Keep GTK's main loop running.
- Use a bounded 500 ms acknowledgment deadline. On failure, keep activity locally
  disabled, destroy activity subscription/inhibitor objects and flush through
  GDK before proceeding. Do not block locking/authentication indefinitely, close
  the shared display, or report unconfirmed compositor suspension.
- Cancellation, polkit owner loss, lock failure, sleep preparation and shutdown
  must release each token exactly once. Nested flows remain inhibited until all
  tokens are released. Cancelled callbacks must never present a prompt.
- Re-enable only after trusted local gates reopen and a fresh source-generation/
  readiness handshake succeeds. Preserve logind delay-inhibitor and native
  lock-acquisition guarantees; this barrier does not replace either.
- Document scope: Pearl-managed authentication and compositor session locks are
  protected. Arbitrary application/browser password fields are not detectable by
  this protocol and must not be described as automatically excluded.

Exit check: inject input at each boundary, including stalled acks and overlapping
flows. No activity callback/pose crosses a suspended epoch, and lock/authentication
still complete when the broker fails.

### 5. Finish the cat and main Settings experience

Files: `plugins/examples/companion-c/`, `src/settings/plugins_view.zig`,
`src/settings/{live_backend,live_protocol}.zig`, `src/plugins/manager.zig` reports.

- Preserve clicks and Preview; alternate cat poses on generic activity and choose
  a still pose under reduced motion. Do not claim exact typing counts or which
  hand/key/button was used.
- Replace hardcoded unsupported labels with actual source and per-plugin status
  plus a short reason: permission needed, launch not authorized, unsupported
  compositor/session, suspended, or active.
- Show the grant separately from availability. Retain **Approve package → Enabled
  → Apply & save** and the overlay grant. Applied revocation immediately clears
  pending delivery.
- Status changes must not overwrite retained drafts or needlessly rebuild focused
  controls. Add truthful availability to CLI inspection too.
- Keep controls out of the flyout. Update the guide for coarse notifications,
  excluded repeat/motion and authenticated launches.

Exit check: main Settings tests cover grant/apply/revoke and each status reason;
flyout isolation passes. Bar and overlay both react with reduced motion respected.

### 6. Verify the packaged launch path

Files: Pearl packaging/docs and staged tests; inspect Aqueous's integration
packages without duplicating their owned units or launcher.

- Stable Aqueous stages `aqueous-pearl.service` with
  `/usr/bin/aqueous-activity-launch /usr/bin/pearl`. Git variants stage the matching
  `<instance>-pearl.service`, private-prefix launcher and `/usr/bin/pearl-git`.
  Validate release, Git and Intel Git against those actual package layouts.
- Pearl's own `pearl.service`/`pearl-git.service` and manual launches are fallback
  paths without authorized activity. Wrapping an unrelated unit does not satisfy
  MainPID/unit validation. Document the matching Aqueous Pearl integration package;
  preserve its selection conditions/drop-ins so only one shell starts.
- Preserve `KillMode=process` and locker survival. Do not install a second launcher
  or automatically change the user's running service during implementation/tests.
- Update release provenance only after rebuilding and validating the new target.
  Keep optional capability fallback; not every package satisfying the older
  general Aqueous version floor supplies this extension.
- Detect legacy startup paths in setup diagnostics. The reviewed upstream
  `packaging/install-welcome.sh` still emits a direct Pearl command; supported
  activity setup should use the component integration package.

Exit check: staged tests verify paths, names, service identity, no duplicate
shell, no inherited capability and production test flags off. A private production
launcher test establishes real systemd authorization.

### 7. Acceptance and evidence

Extend `tests/integration/test_plugins.py` and `test_plugin_host.py`; add focused
broker/lifecycle tests and an isolated end-to-end suite. Keep diagnostic input
injection separate from production binaries and the user's live desktop.

| Area | Required checks |
| --- | --- |
| Protocol/bootstrap | Missing global, invalid/expired/replayed/wrong-process proof, revoked owner, fd cleanup, initial suspended state, stale serial/generation/sequence, ack timeout, resource churn |
| Permissions | No grant, grant without intent, intent without grant, unsubscribe, multiple plugins sharing one source, revoke one while another stays active |
| Scheduling | Bursts/repeats, busy/trapped/timed-out helper, timer/click contention, bounded pending mask, stale drops, no backlog after restart |
| Privacy lifecycle | Lock preparation, locked state, sleep, inactive session/VT, polkit before/after ack, nested flows, cancellation, ack failure and reconnection |
| Actual ingress | Focus a different native Wayland app; verify normal typing/button delivery and cat poses. Repeat with Xwayland. Excluded inputs must produce no activity. Preview alone cannot pass. |
| UI | Main-only controls, status reasons, saved grants, bar/overlay, reduced motion, no updates during suspension, one guest instance across outputs |
| Packaging | Stable/Git/Intel paths, launcher/MainPID, no capability in children, older-Aqueous fallback, no diagnostic features in releases |
| Hardware | Real keyboard/mouse, held keys, shortcuts, physical VT switch, lock/unlock and polkit in a native session; record separately from headless results |

Run upstream pure tests and `test-input-activity.py` (also `--xwayland`),
`test-input-activity-systemd.py`, and its latency suite using the documented
private setup. Run Pearl's normal unit, bindings, lifecycle, settings, plugin
helper and desktop checks after integration. Retain runtime-disabled coverage.

Measure **ingress-to-visible-cat-pose**, not just compositor handler time. Record
median/p95/p99 latency and coalesced/dropped notifications using test-only hooks;
do not expose input timestamps/logging in production. Target p95 ≤250 ms and
p99 ≤350 ms in an otherwise idle reference session, accounting for upstream's
100 ms batching and Pearl's scheduling/rendering. Report hardware and synthetic
results separately. Under overload, drop stale input instead of animating a backlog.

The feature is complete when real-input delivery, grant/revocation controls,
authenticated launch, privacy boundaries and physical acceptance are verified.
If hardware access is unavailable, explicitly leave that gate open. Update
`PLUGINS.md`, `PLUGIN_DEVELOPMENT.md`, the original roadmap and release evidence
only with behavior actually verified.

## Delivery order

Complete stages 1–2, then guest delivery in stage 3. Finish stage 4's lifecycle
barriers before exposing live delivery in the UI. Complete Settings/cat behavior
and packaged launch validation, then run the acceptance matrix. Keep the optional
plugin build flag and existing permission defaults throughout.
