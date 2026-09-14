# Aqueous additions for Pearl T11

> Historical request, superseded for the pinned master by
> [current coverage](AQUEOUS_CAPABILITY_COVERAGE.md) and
> [remaining upstream dependencies](AQUEOUS_MASTER_DEPENDENCIES.md).
> The current helper has structured receipts and native protected previews;
> its hardware, collection-classification and scene-color limits remain explicit.


Status: **historical upstream handoff**. Aqueous master
`1d038dc3bafa0044d9599f8f51f84105a6a85bb3` now implements additive helper/display
contracts addressing these requests, with explicit hardware gates. Pearl has not
yet adopted them. Follow [the current integration update plan](AQUEOUS_MASTER_UPDATE_PLAN.md)
for implementation; the proposal and baseline below are retained as history.
Baseline inspected September 13, 2026: Aqueous revision
`7611e23c653a72b24d6dd4d8b6404d1d1feb7480`, `aqueous-config` 0.7.2, helper
protocol 1. Pearl uses Zig 0.16.0 and generated GTK/Wayland bindings.

Pearl replaces the existing Aqueous settings application. Keep the canonical
`aqueous-config` backend, but do not require work on the old GUI, a GUI handoff,
or a new `--shell pearl` appearance adapter. Neutral `--shell none` remains the
integration contract. This document requests changes in **Aqueous**; it does not
implement them or authorize installation into a running session.

Current behavior and evidence are in [AQUEOUS_SETTINGS.md](AQUEOUS_SETTINGS.md),
the [field inventory](AQUEOUS_FIELD_INVENTORY.md), and
[T11 verification](../artifacts/t11/verification/README.md). Source paths below
are relative to the Aqueous repository unless explicitly marked Pearl.

## What needs upstream support

T11 already renders 221 schema fields, preserves drafts, validates against the
original generation, saves through the canonical helper, records shortcuts with
inhibition, and reports reload/toolkit outcomes separately. An independent Pearl
guardian protects a limited set of live display changes after the GUI crashes.

The highest-priority additions are complete output configuration reporting,
authoritative change classification, and a compositor-owned display transaction.
Aqueous already implements output features such as HDR and mirroring. The gap is
exposing their effective state and protecting their configuration lifecycle.
Existing `monitor_mirroring` capability means the helper accepts that setting;
it does not promise a safe preview or support for every hardware combination.

| Current limitation | Aqueous addition | Priority |
| --- | --- | --- |
| Installer requires the old settings executable and installs its shell integration | Independent helper packaging | P1, independent |
| Monitor snapshot omits enabled/HDR/VRR/profile details | Complete configured and live display model | P0 |
| All raw outputs edits and some raw wm edits are gated | Parser-backed candidate impact report | P0 |
| Mirror/HDR/policy/custom-mode/offline cases cannot use Pearl's guardian | Protected native display transaction, with per-feature capabilities | P0 |
| Lost apply replies need raw-file comparison; reload comes from stderr | Structured outcomes and queryable operation receipts | P1 |
| Per-file replacement and backups do not provide a crash-atomic multi-file transaction | Writer coordination and recoverable commit journal | P0 for coordinated display persistence; P1 for general hardening |
| Collection IDs are tied to array/source indices | Optional collection schema and stronger identity contract | P2 |

P0 means required to remove the corresponding display safety gates. P1 improves
deployment and reliability of existing behavior. P2 is an editor enhancement,
not a prerequisite for current T11. Existing gates stay until the relevant
capability and its tests ship in both repositories.

## Source map and existing behavior to preserve

| Area | Starting points |
| --- | --- |
| Helper entrypoint and capabilities | `settingsApplication/src/config_main.zig`, `src/backend/schema.zig` under that directory |
| Snapshots, validation, collection edits, save | `settingsApplication/src/backend/operations.zig`, `config_document.zig` in the same backend directory |
| Reload completion and toolkit targets | `settingsApplication/src/backend/root.zig`, `reload.zig`, `control.zig`, `toolkit_sync.zig`, `cursor_sync.zig` |
| Helper build and packaging | `settingsApplication/build.zig`, `settingsApplication/packaging/install.sh` |
| Output configuration and precedence | `compositor/aqueous/wm/output/config.zig`, `compositor/aqueous/wm/config/loader.zig` |
| Live output state, test/apply, mirroring | `compositor/aqueous/OutputManager.zig`, `Output.zig`, `OutputMirror.zig` |
| IPC and advertised shell capabilities | `compositor/aqueous/IpcProtocol.zig`, `IpcServer.zig`, `ShellManager.zig`, `compositor/protocol/aqueous-ipc-v1.schema.json`, `aqueous-shell-v1.schema.json` in the same protocol directory |
| Existing tests | `settingsApplication/tests/backend/`, `settingsApplication/tests/test-reload.py`, `test-packaging.sh` in the same tests directory; `compositor/aqueous/wm/config_tests.zig` |

Inspect current source before implementation; this is a pinned starting map.
The existing output parser already models `enabled`, `mirror_of`, mode, scale,
transform, position, adaptive sync, HDR, HDR level, SDR white level, auto HDR,
auto HDR boost, primary selection, EDID matching, profiles and five display
policy fields. Extend contracts around that implementation rather than inventing
a second parser or changing precedence to suit the UI.

The helper currently reloads after apply and requires an actual `applied`
acknowledgement from `aqueousctl session reload --json`. Preserve that behavior
for old clients; do not add a second unconditional reload in Pearl. Preserve
unknown TOML content, comments, explicit user-override authorization, validation,
generation checks, backups, neutral shell mode and individual toolkit reports.

## AQ-T11-01 — Package the canonical helper independently

**Owner:** Aqueous helper/build/packaging. **Dependencies:** none.

The `config` build step already exists. The supplied installer nevertheless
requires `aqueous-settings` and installs its desktop entry and DMS integration.
Provide a documented helper-only build/install/package path that installs
`aqueous-config`, required runtime dependencies (including its reload command),
licenses and backend documentation without requiring the retired frontend.
Verify that this path avoids fetching/building the GUI dependency as well.

Keep executable discovery through PATH and support the current
`version`, `snapshot`, `validate`, `apply`, `raw`, `--request -` and `--shell none`
interfaces. Moving the backend out of `settingsApplication/` is optional; if
done, preserve these interfaces and update the source map.

**Acceptance:** install into a temporary DESTDIR with no old GUI binary; run
version/snapshot/validate/apply against a temporary HOME; verify that the package
does not install GUI launchers or enable DMS/Noctalia integration. Installing
Pearl plus the helper must be sufficient to open Aqueous settings.

## AQ-T11-02 — Expose the complete display model

**Owner:** Aqueous helper and compositor. **Dependencies:** none.

Add a versioned, capability-advertised display model to helper snapshots and
validation results. Keep the existing `monitors`/`live_outputs` representation
for protocol-1 clients. Proposed capability: `display_model_v2`; the name and
JSON schema must be finalized together before Pearl consumes it.

The model must distinguish:

- **Configured declarations:** all output and profile entries, including offline
  matches, their source file, declaration identity, selector and fold order.
- **Effective configuration:** resolved values, inheritance/default provenance,
  active/fallback profile and legacy wm versus outputs precedence.
- **Live state:** session-scoped output identity, connector, available monitor
  identity information, connected/enabled status, actual mode/scale/transform/
  position, mirror relationship, primary selection and actual HDR/VRR state.
- **Support:** separate capabilities for storing, testing and previewing each
  feature. Include backend/hardware restrictions and machine-readable reasons;
  absence of support is not the same as a configured false value.

Cover every output property listed in the source map and every profile/policy
field. Preserve the distinction between absent/inherit, explicit false, and
explicit reset (for example, empty `mirror_of`). Publish mode dimensions and
integer refresh in millihertz, scale units/ranges, transform enumeration,
luminance units, profile limits and custom-mode constraints. Keep declaration
identity separate from a connected output instance: unplug/replug must not make
an old transaction target a new head accidentally. EDID may be absent or
non-unique; publish ambiguity rather than guessing.

Include compositor session identity and a display-state revision. Bind live
observations to one revision, and explicitly mark unavailable or stale live
state. The config generation and display revision are different values.

**Acceptance:** fixtures cover every property, inheritance/reset, duplicate or
wildcard selectors, legacy precedence, active/fallback profiles, disconnected
outputs, missing/duplicate EDID and reconnect. Compare effective candidates with
the compositor's own resolver. Unsupported hardware must report a reason without
silently dropping the requested property.

## AQ-T11-03 — Classify candidate effects in the canonical backend

**Owner:** Aqueous helper with shared compositor configuration semantics.
**Dependencies:** AQ-T11-02 for full display projection.

Extend validation with an authoritative impact report, computed from the parsed
original and candidate configuration. Proposed capability: `candidate_impact_v1`.
Return the original generation, candidate digest, changed files/fields, affected
output declarations and the completeness of the classification. Suggested
effect classes are `none`, `runtime_non_display`, `display_live`,
`display_deferred`, and `unknown`; a request can contain several classes.

Classify effective behavior, not a textual search for `[output]` or `[display]`.
Comments, multiline strings and formatting-only changes must not cause a false
display effect. Raw edits, inherited settings and structured edits must produce
equivalent reports for equivalent candidates. Unknown settings must remain
preserved; if their effect cannot be proven, return `unknown`, never a safe
default. The candidate digest binds the complete canonical write set, including
non-display edits in the same request.

For display policy, separately describe consequences **now**, **on reload**,
**at startup**, and **on hotplug/profile activation**. The fields
`display.apply_on_start`, `display.apply_on_reload`, `display.fallback_profile`,
`display.identify_by` and `display.rollback_seconds` must not all receive one
blanket behavior. The compatibility rollback setting must never be advertised as
a crash-safe transaction lease.

An inactive profile or offline declaration can be classified as save-only only
when the compositor confirms it has no current effect. Activation later must
still run normal compositor validation and recovery policy. If activation can
race the save, bind the classification to the display revision and recheck it.

**Acceptance:** raw outputs comments can save without preview; raw enabled/HDR/
mirror/profile changes cannot bypass protection. Equivalent structured/raw
requests have matching effects. Unknown output keys fail closed. Validation
does not write configuration, synchronize toolkits, reload or apply outputs.

## AQ-T11-04 — Add a compositor-owned display preview lease

**Owner:** Aqueous compositor/IPC. **Dependencies:** AQ-T11-02 and AQ-T11-03.

Prefer native Aqueous IPC because the compositor already owns the output model
and runtime. The existing wlr-output-management path remains useful for older
versions, but its state cannot express all Aqueous properties. Do not require a
new C bridge in Pearl; JSON IPC or generated bindings must be sufficient.

The following operation names are **proposals**, not current commands:

| Operation | Contract |
| --- | --- |
| `display.preview.begin` | Accept candidate digest, expected config generation, session/display revision and candidate display plan; reject stale/unsupported plans, test the complete plan, then apply it and return a lease |
| `display.preview.status` | Return lease state, remaining time, revisions, supported actions and any failure/rollback reason |
| `display.preview.revert` | Idempotently end the lease and restore only state still owned by it |
| `display.preview.commit` | Internal/helper-coordinated commit described in AQ-T11-06; never an unguarded release followed by a later save |

Define the wire schema, limits and capability (`display_preview_v1`, proposed)
in the protocol documentation and schemas together. Tokens are opaque, scoped to
the same user/session and bound to the validated candidate. Do not carry arbitrary
filesystem paths or shell commands in the compositor protocol. Use an explicit
owner connection distinct from short-lived status queries, and bound pending
transactions (start with one active display preview per session).

Required lifecycle:

1. Capture the baseline and affected output/dependency set in the compositor.
   Include mirror sources/destinations and policy consequences, not only changed
   connector rows. Test before making any live change.
2. A successful live apply starts a compositor-clock 15-second confirmation
   deadline. Pearl displays the returned remaining time. UI/helper restarts,
   wall-clock changes and repeated requests cannot extend it indefinitely.
3. Timeout, explicit Revert or owner disconnection before commit restore the
   baseline. Pearl SIGKILL and guardian/helper SIGKILL must not strand a preview.
4. Hotplug, lease dependency changes and competing display configuration
   invalidate the lease. Restore only values still owned by that lease; preserve
   unrelated or newer changes. Define behavior for other output-management
   clients: serialize or invalidate explicitly, never silently overwrite them.
5. Report failed or partial rollback with affected outputs and reason. Use a
   compositor-tested usable-output fallback if the original hardware/mode is no
   longer available; do not re-enable a removed head or claim restoration.
6. A compositor restart invalidates old tokens. Before Keep, canonical files are
   untouched, so startup uses the previous persisted configuration. Recovery
   after commit starts follows AQ-T11-05/06.

Support feature groups incrementally: current placement/mode/scale/rotation,
enable/disable, VRR/HDR and related luminance controls, mirroring, then profiles
and policies. Advertise a group only after its test/apply/restore path works.
Preserve current compositor restrictions on mirroring rather than promising
arbitrary mirror topologies. Reject disabling every usable output unless an
explicit, separately specified headless workflow exists. Custom modes require
backend support and a successful test; unsupported hardware remains gated.

**Acceptance:** timeout, disconnect, two simultaneous clients, stale revision,
rejected test, partial apply, unplug/replug, mirror-source removal, competing
output writes and session restart all have deterministic results. No test leaves
canonical files changed before Keep. Include real hardware mode/HDR/VRR/mirror
tests before claiming those capabilities beyond a simulated backend.

## AQ-T11-05 — Coordinate writers and recover multi-file saves

**Owner:** Aqueous helper/config loader. **Dependencies:** none; needed by 06.

The current helper checks generation while preparing, backs up multi-file edits,
replaces dirty files, and attempts restoration on a caught save error. This is
valuable but is not a crash-atomic transaction across all files. Specify a
recoverable transaction boundary rather than treating individual atomic renames
as an atomic multi-file save.

- Serialize cooperating helper writers with a per-user configuration lock.
  Re-read/check the original generation after obtaining the lock and before
  committing. Include source selection and user-override creation in that check.
- Stage the complete write set and a durable journal containing transaction ID,
  before/after digests, original file existence and commit phase. Bound retained
  journals/receipts and specify permissions, fsync ordering and cleanup.
- Coordinate the Aqueous loader and reload entrypoints so they never knowingly
  consume the middle of a cooperating multi-file transaction. Recovery must run
  before loading an interrupted transaction's files on startup.
- Define roll-forward versus rollback for each crash point. Restore/delete a
  file only when its current content still matches the transaction-owned version;
  a later external edit produces an explicit recovery conflict.
- Do not claim that an advisory lock prevents arbitrary editor writes. Recheck
  detected changes, preserve conflicting files, and document the residual race
  with non-cooperating writers. If stronger filesystem atomicity is required,
  specify a versioned configuration-directory switch as a separate migration.

Backups remain useful user artifacts and do not substitute for the journal.
Preserve the caller-authorized backup location and require explicit authorization
before creating user overrides. Avoid external toolkit effects until canonical
commit is durable; report them independently afterward.

**Acceptance:** concurrent helpers cannot both commit the same base generation.
Inject process death/failure before and after each rename/journal transition,
including a newly created override. Recovery yields a documented complete
generation or an explicit conflict; no reload reports success for an intermediate
write set. External edits after interruption survive recovery.

## AQ-T11-06 — Join Keep, canonical save and reload

**Owner:** Aqueous helper and compositor together.
**Dependencies:** AQ-T11-03, AQ-T11-04 and AQ-T11-05.

Provide a helper operation that commits a preview using its token, the original
generation, candidate digest and a client-generated operation ID. The user still
presses Keep in Pearl; only the canonical backend writes TOML. A token cannot be
used with a different candidate or renewed generation.

Specify and test this state machine before enabling the capability:

```text
validated -> previewing -> commit_authorized -> committed -> reload_reported
                 |                |
                 v                v
          reverted/invalidated   recovered/failed/conflict
```

Before `commit_authorized`, loss of the owner or the confirmation deadline causes
rollback. At authorization, atomically check lease ownership/deadline, display
revision and candidate identity in the compositor while the helper holds its
configuration lock and verifies the original generation. Grant a **bounded**
commit phase tied to the durable operation record. Do not expire the ordinary
preview independently in the middle of a valid commit, or hold outputs forever
if the helper dies.

During commit, serialize/invalidate competing display actions under a documented
policy and prevent file-watch reload/profile activation from applying the
candidate a second time. After durable save, acknowledge which generation and
candidate the compositor adopted and finalize the lease. A saved configuration
with failed reload is still saved; return the live display result separately.

For each failure after authorization, reconcile the journal with compositor
state. Before durable save, restore the lease-owned preview. After durable save,
recover/finalize according to the recorded commit decision; do not silently
pretend the files reverted because the live state rolled back. A client that
loses its reply must be able to query the operation ID and discover the decision.
Specify startup handling for compositor and helper death in either order.

**Acceptance:** kill Pearl, helper and compositor at every transition; race Keep
with timeout, external canonical edits, hotplug and other output clients. Keep
either commits the exact reviewed candidate or reports failure/conflict without
overwriting newer state. Duplicate commit/status requests cannot save or reload
twice. There is no unprotected interval between ending preview and persistence.

## AQ-T11-07 — Return structured, recoverable operation outcomes

**Owner:** Aqueous helper plus reload acknowledgement producer.
**Dependencies:** 05 for durable receipts; 06 for display receipt integration.

Add an opt-in structured result envelope and operation-status query. Proposed
capabilities: `apply_outcome_v1`, `operation_receipts_v1`. Keep old snapshot-shaped
responses and `--report-reload` behavior working until clients explicitly opt in.
If old semantics cannot be preserved additively, introduce a negotiated protocol
version and update Pearl rather than silently changing protocol 1.

An outcome contains independent canonical-save, reload, toolkit and display
results, plus operation ID, before/after generation and candidate digest. Use
stable error codes, human messages, retryability and affected file/field/output
identifiers. Include per-file commit/recovery detail and per-target toolkit
results. Proposed result vocabulary:

| Result | States |
| --- | --- |
| Save | `unchanged`, `saved`, `failed`, `uncertain`, `recovery_conflict` |
| Reload | `not_requested`, `applied`, `failed`, `unknown` |
| Toolkit target | `not_requested`, `synced`, `failed`, `unknown` |
| Display | `not_requested`, `previewing`, `kept`, `reverted`, `invalidated`, `failed` |

Bind confirmed reload to the compositor session, acknowledged sequence and
loaded configuration generation/digest. `accepted`, command exit success or a
file-watch event are insufficient proof of application. Once a canonical commit
is durable, failure while collecting a snapshot must not erase its saved status.
Never infer toolkit or reload completion from matching raw files.

Retain bounded operation receipts long enough for recovery and document expiry.
Reuse of an operation ID with different content is an error; reuse with the same
content returns its receipt, without repeating saves or external side effects.
An absent/expired receipt is explicitly unknown, not permission to replay.
Define JSON size/depth bounds, output framing and timeouts. Pearl currently
allows 4 MiB requests, 16 MiB stdout, 64 KiB stderr and 35 seconds per ordinary
helper operation; negotiate any changed limits.

**Acceptance:** saved plus failed reload stays saved; partial toolkit sync retains
target detail; broken stdout after save is recoverable by ID; duplicate retries
do not duplicate side effects. Test old Pearl against the upgraded helper and
new Pearl against helper 0.7.2 with capability fallbacks.

## AQ-T11-08 — Optional collection metadata for richer editors

**Owner:** Aqueous helper. **Dependencies:** none. **Priority:** P2.

Custom bindings, rules and snap layouts already support request-based editing.
Pearl can build visual editors today. Upstream additions would improve them:

- Publish rule field types/options/limits, matcher semantics, defaults and
  supported operations in machine-readable schema rather than a UI-maintained
  list of known keys. Include equivalent snap-layout/zone and custom-binding
  constraints, command prefixes and chord grammar.
- Make identity and ordering explicit. Either document index IDs as strictly
  generation-scoped, or add opaque stable IDs with a defined behavior for raw
  edits and duplicate records. Do not derive identity solely from editable text.
- Provide field/record diagnostics and collection change preconditions that
  allow independent edits to rebase without targeting a shifted array element.

**Acceptance:** reorder/delete/duplicate/raw-edit fixtures cannot retarget a stale
edit; published metadata agrees with backend validation for every supported rule
key and snap constraint. Keep existing request operations compatible.

## Pearl follow-up and delivery order

Deliver 01 independently. Implement 02 and 03 first to make the current gates
precise, then 04 and 05, then their joined commit contract in 06. Structured
outcomes in 07 can be developed alongside that work, but durable receipt and
display integration must use the same operation record. Finish optional 08 when
editor work benefits from it. Each task should land with schema/docs, focused
tests and an updated capability, not a capability promising future behavior.

For each shipped capability, update Pearl's model/client and tests before
enabling its controls. Relevant Pearl paths are `src/config/aqueous_model.zig`,
`aqueous_client.zig`, `display_guard.zig`, `helper_process.zig` in the same
directory, `src/desktop/aqueous_settings.zig`, and
`tests/integration/test_aqueous_settings.py`. Keep the existing guardian fallback
for older Aqueous versions; remove raw-file/display gates only for candidates
whose complete effects and protected path are proven by negotiated contracts.

These remaining tasks belong to Pearl and do **not** require Aqueous additions:
visual display placement, rule/custom-binding builders, snap canvases, persisting
drafts across a whole Pearl restart, and GTK/Material presentation. Existing
shortcut inhibition already passes real compositor interaction tests. Installed
GTK theme selection already belongs to Pearl T10. No new blur protocol or shell
appearance adapter is required for this T11 handoff.

All automated integration tests must use a temporary HOME/config/state, private
bus and isolated compositor. Record source/helper versions, capabilities and
fault-injection outcomes. Headless tests establish transaction behavior;
physical monitor coverage is a separate acceptance requirement for hardware
features. Update the field inventory and gate descriptions only after the
corresponding Aqueous and Pearl tests pass.
