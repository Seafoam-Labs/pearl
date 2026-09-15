# Plan: adopt all settings exposed by Aqueous 0.8.2

Status: **A82-00–A82-07 implemented; automated acceptance passed**.
Evidence: [Aqueous 0.8.2 verification](../artifacts/aqueous-082/README.md).
Physical hardware and public release acceptance remain separate.
Source comparison and upstream verification: September 14, 2026.

## Target and scope

Update Pearl from Aqueous `1d038dc3bafa0044d9599f8f51f84105a6a85bb3`
(helper 0.8.0) to **`b3d486920c42e24d45bed0a79e68915fe11c4815`**
(helper **0.8.2**, protocol 1). The target matched remote `master` using
`git ls-remote https://github.com/Seafoam-Labs/Aqueous-clean.git refs/heads/master`.
Implementation must pin this revision; later upstream changes require another
comparison. Local uncommitted Aqueous packaging/welcome edits are outside this baseline.

This plan follows the implemented [AM00–AM09 update](AQUEOUS_MASTER_UPDATE_PLAN.md).
Keep its existing implementation and historical evidence. Its
[dependency list](AQUEOUS_MASTER_DEPENDENCIES.md) describes the old pin: several
dependencies now have upstream implementations adopted by this update. See
[integration evidence](../artifacts/aqueous-082/README.md) for the executed checks.

“All settings” means every canonical scalar field, collection operation and display
mutation has a usable editor or an explicit runtime capability restriction.
Do not force-enable settings, change users' defaults, or equate successful parsing
with permission to save. The scalar schema is unchanged across these commits;
the main work is unlocking collection persistence and adding complete display editors.
Retain the existing 221 scalar controls and regenerate their inventory to verify coverage.

## Verified changes and Pearl gaps

| Area | New upstream support | Work in Pearl |
| --- | --- | --- |
| Collection classification | `d63ecd7` classifies canonical collection semantics | Replace tests expecting all collection writes to fail with successful round trips; keep unknown-extension rejection |
| Protected collection saves | `37f45fc`: `protected_collection_apply_v1`, `collection_preconditions_v2` | Negotiate capabilities, build the collection-only request and consume its transaction baseline |
| Display declarations | `78a2d02`: `display_declaration_mutations_v1` | Add source-bound declaration CRUD, profiles, membership, ordering and explicit inheritance |
| Display fields | Structured enablement, primary, matching, HDR/VRR and related controls | Replace disabled placeholder controls with typed draft editors and per-feature apply restrictions |
| Display previews | `28bfe78`: backend reporting, presentation completion and session-aware rollback | Handle new observation/status fields and `waiting_session`; remove hard-coded blanket explanations |
| Isolated window capture | `3f1dba3`: destination scene color metadata on supported paths | Validate the existing capture consumer against successful scene export and unsupported-path rejection |
| Packaging | Core/session/optional integration components and multiple-installation support | Use the matching helper/compositor/library set and update Pearl's documented package requirements |

### Authoritative upstream references

All links below select the pinned target, not moving master:

- [Helper capabilities and scalar schema](https://github.com/Seafoam-Labs/Aqueous-clean/blob/b3d486920c42e24d45bed0a79e68915fe11c4815/settingsApplication/src/backend/schema.zig).
- [Protected collections](https://github.com/Seafoam-Labs/Aqueous-clean/blob/b3d486920c42e24d45bed0a79e68915fe11c4815/settingsApplication/docs/PROTECTED_COLLECTIONS.md).
- [Display mutation contract](https://github.com/Seafoam-Labs/Aqueous-clean/blob/b3d486920c42e24d45bed0a79e68915fe11c4815/settingsApplication/docs/DISPLAY_MUTATIONS.md).
- [Preview implementation](https://github.com/Seafoam-Labs/Aqueous-clean/blob/b3d486920c42e24d45bed0a79e68915fe11c4815/compositor/aqueous/DisplayPreview.zig) and [backend policy](https://github.com/Seafoam-Labs/Aqueous-clean/blob/b3d486920c42e24d45bed0a79e68915fe11c4815/compositor/aqueous/display_preview_policy.zig).
- [Scene color protocol](https://github.com/Seafoam-Labs/Aqueous-clean/blob/b3d486920c42e24d45bed0a79e68915fe11c4815/compositor/protocol/aqueous-capture-color-v1.xml) and [package ownership](https://github.com/Seafoam-Labs/Aqueous-clean/blob/b3d486920c42e24d45bed0a79e68915fe11c4815/packaging/components.json).

These contracts were inspected in the local source checkout. The display mutation
guide's blanket physical-preview description predates the later preview commit;
use the pinned implementation and live support flags for actual backend behavior.

## Delivery plan and acceptance requirements

### A82-00 — Pin matching tools and capture the contract delta

**Depends on:** nothing.

- Update build/inventory/upstream-test scripts to share explicit target metadata.
  Audit hard-coded revision/version checks in tests, fixture helpers and release tooling.
- Build from a clean archive into a new private cache prefix. Preserve old fixtures
  and evidence as the 0.8.0 baseline until matching 0.8.2 replacements pass.
- Build or verify the target's patched wlroots too: the existing build script reuses
  the upstream checkout's library, whose scene-capture patch may be stale. Record
  source/patch hashes, compiler options and all binary/library hashes.
- Capture version, snapshot, validation, collection transaction, display source IDs,
  declaration metadata, preview states and registry/color fixtures with provenance.
- Make inventory generation enumerate the new contracts. Remove hard-coded
  `upstream-gated` classifications only after consumer acceptance passes.

**Acceptance:** the private compositor, helper and aqueousctl match the pin;
every addition/removal has a coverage row and work-package owner. No host configuration
is changed and no test silently uses installed or cached tools from the old baseline.

### A82-01 — Extend models and select the right transaction contract

**Depends on:** A82-00.
**Files:** `src/config/aqueous_contract.zig`, `aqueous_model.zig`,
`aqueous_client.zig`, `aqueous_operations.zig`.

- Negotiate the three new helper capabilities independently. Keep existing readable
  settings and supported operations working when an optional capability is absent.
- Decode bounded `collection_preconditions_v2`, `collection_transaction`,
  `display_declaration_mutations`, `display_source_ids`, declaration `id`/`kind`/
  `parent_id`, `preview_backend` and `preview_acceptance_only` fields.
- Extend the request allowlist and conflict detection for the new mutation forms.
  Keep generation, digest, lease token, source authorization and receipt metadata
  under service control; Advanced must not bypass their validation.
- Add explicit routing for collection-only, ordinary fresh-generation and display
  requests. Empty `changes`/`raw_files` members in Pearl's generic request skeleton
  must not leak into the strict collection-only contract.
- Adapt `Impact.read`, which currently requires the draft generation, to validate
  collection impact against the verified effective baseline. Keep display mutations
  bound to their original fresh generation.

**Acceptance:** fixtures reject malformed identities, unsupported versions, excess
sources/operations and invalid contract mixtures. Missing capability affects only
its dependent workflow. Response/request bounds remain enforced.

### A82-02 — Make every collection editor persist safely

**Depends on:** A82-01.
**Files:** `src/config/aqueous_collections.zig`, `aqueous_client.zig`,
`aqueous_model.zig`, `src/desktop/aqueous_collections.zig`, `aqueous_snap_layouts.zig`.

- Preserve the existing rule, shortcut, named-layout and legacy-zone editors.
  Audit every operation and field against the current collection schema.
- Collection-only requests use `collection_apply_version:1`, `protected_apply:true`
  and v2 descriptors for exactly the touched `rules`, `wm` and/or `layout` sources.
  Copy path/existence/digest descriptors from the base snapshot; never compute them.
  Empty collection arrays still require their source descriptor. Default layout
  selection accompanies `snap_layouts`.
- Validate and retain `collection_transaction.effective_generation`,
  `base_preconditions` and `candidate_digest`. Apply the same mutations with those
  verified values. Candidate snapshot generation/descriptors are not apply baselines.
- Allow the helper's stale-generation exception only for unchanged touched sources.
  Changed source bytes, path, existence or record order require conflict resolution.
  A changed full-candidate digest requires fresh validation and review.
- Mixed scalar/raw/display/collection requests use the ordinary fresh-generation
  route and, when display effects exist, the native preview lease. Do not attach
  collection-only metadata or split one user apply into partial saves.
- Preserve operation receipts and lost-response recovery without replaying writes
  or reloads. Clear old blanket collection-blocked messages only on supported paths.

**Acceptance:** add/update/delete/reorder rules and shortcuts where their schema
allows it; round-trip named layouts, default selection and legacy geometry. Test
unrelated external edits, touched-source reorder, missing versus empty files,
mixed requests, digest mismatch, no-op apply and restart after lost stdout.

### A82-03 — Add canonical display mutation staging

**Depends on:** A82-01.
**Files:** new `src/config/aqueous_display_mutations.zig`, `aqueous_model.zig`,
`aqueous_client.zig`; corresponding tests.

- Build `display_declaration_changes:{version:1,sources,operations}`. Retain opaque
  IDs and exact source tokens from the original snapshot. A connector or profile
  name is never a declaration identity.
- Support add/update/delete/move for outputs and profiles, profile membership,
  profile ordering, and policy add/update/delete. Support ordered `ref`/`new:ref`
  references for a new profile and its members in one draft.
- Preserve `wm` versus `outputs` source selection. Detect raw, legacy monitor and
  scalar conflicts with any touched source. Permit compatible other-source edits.
- Implement `set` versus `unset` explicitly, preserving false, zero and allowed
  empty strings. Combine edits to an existing node into one operation; enforce the
  256-operation ceiling and upstream batch/reference constraints.
- Profile deletion chooses deletion or reassignment of members. Renaming/deleting
  a fallback profile must produce a valid final policy in the same candidate.
- Preserve the original request IDs/generation after validation; use returned
  canonical sources/digest for preview and the original mutations for Keep.
  Display IDs never enter the collection stale-generation exception.

**Acceptance:** duplicate names, offline/disabled declarations, negative origins,
inheritance, absent source creation, profile/member moves and same-batch additions
round-trip through the helper. Stale IDs, forward/cross-source references, conflicting
edits and ambiguous original syntax produce actionable errors without writes.

### A82-04 — Expose the complete Displays editor

**Depends on:** A82-03; apply completion also requires A82-05.
**Files:** `src/desktop/aqueous_displays.zig`, `aqueous_settings.zig`.

Provide connected, disabled and configured-offline displays plus named profiles
and display policy. Show source, inherited/local values and effective observations
without deriving precedence in Pearl. Preserve placement diagram and keyboard controls.

| Group | Controls |
| --- | --- |
| Identity | `name`, `edid`, explicit source and declaration selection |
| Arrangement | `enabled`, `primary`, `position`, `scale`, `transform`, `mode`, `mirror_of` |
| Color and refresh | `adaptive_sync`, `hdr`, `auto_hdr`, `hdr_level`, `sdr_white_level`, `auto_hdr_boost` |
| Profiles | Create, rename, delete, reorder, add/remove/reassign member declarations |
| Policy | `apply_on_start`, `apply_on_reload`, `fallback_profile`, `identify_by`, `rollback_seconds` |

Use helper-advertised mutation metadata and canonical constraints for widget types,
options and validation. Include “Use inherited value” for removable overrides.
`identify_by` and `rollback_seconds` retain compatibility-only runtime semantics;
the latter does not change the native confirmation lease.

Permit supported draft construction and validation even when live apply is blocked.
Show the specific output/feature reason beside the controls and in candidate review.
Do not silently omit blocked settings from a mixed draft. Preserve advanced raw
repair for sources the structured editor cannot safely modify.

**Acceptance:** every mutation field and operation has a GTK entry point and coverage
row; keyboard-only editing works at large text sizes in Material light/dark and GTK
themes. Capability restrictions explain exactly why a candidate cannot be applied.

### A82-05 — Follow the expanded native preview state machine

**Depends on:** A82-01.
**Files:** `aqueous_client.zig`, `aqueous_contract.zig`, `aqueous_display_ipc.zig`,
`src/desktop/aqueous_displays.zig`.

- Treat `waiting_session`, `reverting` and commit-writer waits as pending outcomes.
  Pearl currently treats any polling state other than `applying`/`previewing` as
  terminal and reports Revert immediately after acknowledgement; fix both paths.
- Observe `hardware_matches`, `presented`, partial rollback and terminal reasons.
  Show Keep only when upstream reports an active confirmable preview. The native
  lease owns timing; Pearl's current fixed 25-second loop must not turn a session
  pause or rollback-in-progress into a claimed successful revert.
- Keep UI responsive, cancellation bounded and unresolved rollback visible.
  Reconcile native state/receipts on reconnect and session resume; never repeat a
  save or assume disconnect restored hardware after commit authorization.
- Read per-output backend and feature support. Production DRM previews remain
  unavailable at this pin. An explicit `-Ddisplay-preview-acceptance=true` build
  plus exact `AQUEOUS_DISPLAY_PREVIEW_ACCEPTANCE_OUTPUTS` selection permits only
  the supported SDR acceptance path. Label `preview_acceptance_only` clearly.
- HDR/VRR remain blocked; DRM mirroring/custom modes remain separately blocked.
  Headless mirroring still depends on renderer support. Deferred/offline display
  changes still require a lease; `store:true` cannot bypass protected apply.

**Acceptance:** test delayed/failed presentation, timeout, owner exit, lock, inactive
session/resume, hotplug, partial rollback, competing writer and lost Keep response.
An acknowledged Revert is never displayed as completed until terminal evidence arrives.
Production and acceptance-build results are recorded separately. Physical tests are
a separately scheduled, explicitly authorized hardware task, not part of unattended CI.

### A82-06 — Adopt adjacent capture and packaging fixes

**Depends on:** A82-00. This complements settings completion.

- Refresh `bindings/protocols/aqueous-capture-color-v1.xml` and audit
  `src/services/image_copy.zig` against the new scene metadata. Keep destination
  gamma22-to-sRGB conversion and fail closed on unavailable/unsupported encodings.
- Update `tests/integration/test_capture_master.py`, which currently requires scene
  export to fail. Require successful isolated-window export on the supported path,
  prove unrelated overlapping pixels are absent, and keep unavailable metadata,
  removed-source and unsupported-conversion cases.
- Update package/session compatibility documentation for the core package containing
  compositor/helper and optional shell integrations. Audit helper PATH resolution
  with multiple Aqueous installations and report mismatches actionably.
- Keep instrumented/physical-acceptance binaries out of production packages. Recheck
  Pearl's startup/session contracts against upstream packaging changes.

**Acceptance:** scene capture passes with matching patched libraries; package inspection
and private session tests prove the intended helper and compositor are selected.

### A82-07 — Complete regression evidence and documentation

**Depends on:** A82-02 through A82-06.

- Extend the matching-master upstream runner with `test-collection-impact.py`,
  `test-protected-collections.py`, `test-display-mutations.py`, the expanded native
  preview suite and `test-scene-capture.py`. Preserve production/instrumented provenance.
- Run Pearl's unit/adapter/bindings checks, `test-aqueous-settings`,
  `test-aqueous-master`, capture integration and `test-master-ui` with matching tools.
  Run affected packaging/session checks after integration changes.
- Replace obsolete negative expectations with positive round trips plus targeted
  unsupported/conflict cases. A historical pass is not evidence for the new pin.
- Regenerate both inventories and update settings, compatibility, release, README
  and dependency documentation. Mark upstream fixes adopted only after tests pass;
  retain physical hardware restrictions and any actually observed remaining gaps.

**Done when:** all 221 scalar fields and every advertised collection/display setting
have verified coverage; all supported saves survive refresh/restart; mixed candidates
remain atomic; unresolved operations cannot trigger duplicate side effects; UI checks
pass; and remaining restrictions exactly match live upstream capabilities.

## Suggested implementation sequence

1. A82-00 + A82-01: pinned tools, fixtures and transaction routing.
2. A82-02: unlock existing collection editors with complete acceptance.
3. A82-03 + A82-05: display mutation service and correct preview lifecycle.
4. A82-04: complete display forms and accessibility verification.
5. A82-06 + A82-07: adjacent integration checks and final evidence.

The first user-visible milestone is reliable rule/shortcut/layout saves. The second
is complete structured display editing, with apply availability determined by the
running compositor. Broad production physical-display support remains upstream work.
