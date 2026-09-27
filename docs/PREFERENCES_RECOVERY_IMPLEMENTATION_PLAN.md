# Preserve preferences during recovery

Status: proposed; implementation has not started.

## Goal

An update, invalid setting, unavailable wallpaper, or broken theme must not reset
unrelated preferences. Pearl should keep the user's saved choices, run with the
smallest necessary temporary fallback, explain what failed, and allow safe
repairs without accidentally saving fallback values over the original choices.

This plan addresses confirmed recovery and persistence behavior in the current
code. The particular error behind the reported update-time resets has not been
identified; add diagnostics rather than assuming schema changes caused them.

## Current behavior

- `src/config/preferences.zig` parses and validates the whole typed document.
  Unknown fields and invalid known values reject the entire document. Version 0
  has an explicit migration; version 1 uses the current schema.
- `src/config/service.zig` routes startup preparation failures through `recover`.
  It replaces `Job.prefs` with `last-good.json`, or defaults if that cannot be
  loaded. Further appearance failures modify theme, wallpaper, and application
  integration preferences to produce a usable fallback.
- Recovery itself skips preference and last-good writes, but `prefs()` exposes
  the recovered values to both runtime consumers and editors. A later Apply can
  serialize these values to `preferences.json` and refresh `last-good.json`.
- Draft creation, standalone Settings downloads, legacy Settings, dock pinning,
  launcher associations, and wallpaper selection consume this shared state.
- The current three-way merge canonicalizes all inputs through the typed parser;
  it cannot preserve unknown or invalid members of the source document.
- A missing preference file is currently treated as `{}` and can refresh the
  last-good snapshot with defaults. Distinguish a first launch from a missing
  file in an established configuration.

## Required behavior

1. Loading, retrying, and displaying fallback values never rewrite the source
   document or promote a degraded configuration to last-good.
2. A valid saved field survives a failure in another independent field. Related
   fields are recovered together only where validation requires it.
3. Runtime availability failures do not invalidate saved choices. A missing
   wallpaper uses a temporary background while preserving its selected path;
   theme failure leaves bar layout, dock, clocks, pins, and other settings intact.
4. Saving an unrelated edit never commits temporary fallback values. Existing
   unknown members and unresolved invalid values survive unrelated edits.
5. Newly submitted known values remain strictly validated. Recovery does not
   execute unknown configuration or weaken existing bounds and validation.
6. Every mutation path enforces the same recovery rules, conflict checks, and
   backup requirements in the backend.

## Document and runtime model

Introduce a bounded preference document representation alongside the typed
`Preferences` model, with ownership tied to the existing job/draft lifetimes:

- Original source bytes and digest/etag, plus a DOM when the document is safely
  parseable. Retain missing, unreadable, and malformed as distinct states.
- The saved known preferences, with per-path provenance for values recovered
  from a snapshot or defaults. Do not label substituted values as saved choices.
- Effective runtime preferences and prepared appearance resources. Only these
  may contain temporary fallback substitutions.
- Recovery issues containing a stable code, JSON path or dependency group,
  source, fallback used, and whether an edit or retry can resolve the problem.
- A save policy: ordinary edits allowed, explicit repair required, or read-only
  because the source cannot safely be interpreted.

Replace ambiguous uses of `prefs()` with explicit runtime and editing accessors.
Audit every caller: presentation consumes effective values; drafts and writers
use the source document and explicit edits. Settings must show saved selections
alongside fallback explanations, not present a temporary fallback as a selection.

## Recovery policy

| Failure | Runtime behavior | Persistence behavior |
| --- | --- | --- |
| Valid preferences; wallpaper, renderer, theme, or snapshot unavailable | Preserve all saved preferences; substitute only the affected runtime resource or dependent appearance component | Unrelated valid edits remain available; keep the unavailable selection |
| Invalid known leaf in otherwise valid JSON | Use a valid same-path last-good value, then its default; retain other valid leaves | Preserve the original invalid value until explicitly repaired |
| Related fields violate a joint constraint | Recover the smallest documented dependency group and report its paths | Require explicit edits to repair that group; do not silently normalize it |
| Unknown field in supported schema version | Retain it as opaque data; use recognized valid fields | Preserve it through edits, drafts, merge, and serialization |
| Malformed JSON, duplicate keys, invalid encoding, resource-limit violation, or unsupported version | Use a compatible validated snapshot, otherwise safe defaults; report document-level recovery | Block ordinary writes; offer an explicit reviewed restore/replacement after backup |
| Source cannot be read safely | Use available runtime fallback without guessing the source contents | Block replacement until the source can be read and backed up |
| File absent on first launch, no snapshot | Normal defaults | Create preferences only on an explicit save |
| File absent with an existing snapshot | Recover the snapshot and report the missing source | Do not overwrite the snapshot with defaults; require explicit restore/create |

For partial recovery, split validation into field checks and explicit dependency
checks. Examples include wallpaper mode/path, dynamic-theme wallpaper source,
slideshow mode/folder, and bar clock definitions/group references. Keep unrelated
bar properties such as edge and opacity outside the clock recovery group.
Revalidate the complete effective configuration after substitution. If recovery
cannot establish a valid dependency group, escalate that group deterministically;
never loop through arbitrary substitutions or hide unresolved errors.

Handle collections by stable identity where unambiguous (for example output
connector or plugin ID). Preserve valid sibling records and original raw entries;
ambiguous identities and cross-record constraints require collection-level
recovery. Define and test these boundaries before enabling partial collection
repair. Recovered plugin approvals or external integrations must not acquire new
authority from defaults or snapshots; retain existing recovery restrictions on
external writes until their saved configuration is valid and explicitly applied.

Keep explicit version migrations pure and tested. Additive fields retain defaults;
renames and semantic changes need migrations. Do not implement compatibility by
globally ignoring unknown fields and then serializing only the typed structure.

## Safe editing and persistence

1. Represent structured changes as explicit path edits against a captured source
   revision. Overlay only those edits on the retained source DOM. Never infer
   user intent by comparing a complete effective fallback object to raw settings.
2. Validate changed values and affected dependency groups. Existing unresolved
   issues may remain only outside the edit's dependency scope; introduce no new
   issues. Unknown members survive semantically, including within nested objects
   and retained collection entries; formatting need not remain byte-identical.
3. Extend draft retention and three-way merge to retain source members and handle
   missing keys, additions, deletions, and unknown values. Preserve drafts on
   conflicts and reject ambiguous collection merges. A repaired field equal to
   its displayed fallback still needs an explicit edit marker.
4. Route Settings Apply, Advanced, CLI apply, dock pinning, launcher association
   edits, wallpaper changes, and theme actions through the shared policy. During
   transition, reject unconverted full-document writes in recovery. A legacy CLI
   full replacement must not bypass repair review by submitting defaults.
5. Provide an explicit repair/restore operation for whole-document replacement.
   Bind its preview to the source digest and candidate; show what will change.
   Advanced edits that remove unknown data are also explicit document edits,
   distinct from ordinary structured setting changes.
6. Before the first write to an existing degraded source, save an exact-byte,
   private, durable backup under `pearl/recovery/`, named by source digest. Reuse
   only a verified matching backup; abort the write if backup creation fails.
   Keep backups across restarts and upgrades; no automatic pruning in this scope.
   A missing file has no bytes to back up; preserve its existing snapshot.
7. Retain optimistic digest/etag checks and atomic replacement. The backup must
   correspond to the exact source being replaced. A concurrent edit invalidates
   the candidate and repair preview; keep the draft. A crash may leave an extra
   backup, but must not leave an unbacked replacement or a partial document.
8. Refresh `last-good.json` only from a fully validated, non-degraded committed
   document after successful preparation, preserving opaque source members. Do
   not promote partial recovery, runtime fallback, failed saves, or temporary
   source disappearance. Audit shell/lock and other service instances sharing
   the snapshot; designate the shell as its writer to avoid competing promotion.
9. Snapshot/asset pruning must retain references needed by the source, last-good,
   and retained recovery backups. Disable pruning of uncertain references rather
   than deleting assets needed for restoration.

## Runtime recovery and feedback

Split parsing/validation errors from resource preparation errors in `prepare`,
`recover`, and GTK provider validation. Reuse valid saved preferences through
appearance recovery; rebuilding a provider must not mutate the document model.
Try compatible prior resources before the built-in fallback where appropriate.

Keep the selected resource path available for recovery even while the effective
background is a fallback. Support explicit Retry and existing file/catalog events
to restore saved choices when resources return, without rewriting preferences or
changing draft revisions. Avoid polling and retry loops; retain cancellation and
publication-generation checks.

Extend `pearlctl preferences status` and the Settings protocol with bounded issue
summaries, save policy, and a separate effective-versus-saved indication. Retain
the existing `recovered`/`err` fields as compatibility summaries. Use the existing
document transfer mechanism for full documents instead of increasing status
payloads without bounds.

Show a persistent, accessible Settings message such as “Wallpaper unavailable.
Your selection is saved; a temporary background is in use.” Offer Retry and
focused repair actions. Whole-document restore must show its effect and backup
location. Log recovery reason, affected paths, and transitions without dumping
the settings document. Clear issues only after successful revalidation.

## Implementation sequence

1. **Protect writes first.** Add recovery save-policy enforcement to the shared
   service, exact-source backup support, and regression tests proving recovered
   full-document saves cannot overwrite the source. Until later stages land,
   reject ordinary saves during recovery with an actionable error.
2. **Separate saved and runtime state.** Introduce document/provenance ownership,
   split appearance fallback from saved values, and audit all readers and writers.
   Add status diagnostics. Preserve existing last-good and source files on load.
3. **Recover valid portions.** Implement the bounded document loader, explicit
   validation dependencies, opaque-member preservation, and compatible snapshot
   selection. Keep ordinary write validation strict.
4. **Enable safe edits and repairs.** Convert drafts, merge, Settings/backend,
   CLI, and direct writers to explicit source edits; add reviewed replacement.
   Enable unrelated saves only once they preserve unresolved source values.
5. **Complete lifecycle behavior.** Implement resource retry, snapshot writer
   ownership, retention rules, and Settings recovery presentation. Document the
   behavior in `docs/PREFERENCES.md` and the CLI help where applicable.

Primary files: `src/config/{preferences,service,draft,merge,io}.zig`, new focused
document/recovery modules as needed, `src/settings/{backend,editor,client}.zig`,
the Settings protocol and views, `src/desktop/{settings,wallpapers,dock,
launcher_picker}.zig`, theme mutation paths, and CLI request handling.

## Verification and acceptance

Add pure document/validation/merge tests and private-XDG integration coverage.
Use saved configurations from earlier revisions as compatibility fixtures; do
not rely only on constructing fixtures with the current serializer.

- Missing wallpaper, failing renderer, invalid GTK CSS, and missing/corrupt theme
  snapshot: preserve saved choices and unrelated settings; change a dock or bar
  setting, restart, and confirm only the intended source edit was saved.
- One invalid scalar and multiple independent invalid fields: retain valid
  siblings, use deterministic per-path fallback, and preserve original invalid
  values on unrelated saves. Repair one issue without implicitly repairing others.
- Clock/group and output/plugin collection failures: exercise dependency and
  identity boundaries, preserving unaffected records and layout fields.
- Unknown nested fields: survive load, draft edit, merge, save, and restart;
  runtime consumers never execute them. Unsupported versions remain protected.
- Malformed JSON, duplicate keys, excessive depth/size, unreadable source, and
  invalid last-good: safe runtime behavior with no automatic destructive writes.
- Missing source with and without last-good: distinguish recovery from first run;
  never erase the only snapshot by starting with defaults.
- Every write entry point: enforce save policy, including direct CLI apply,
  wallpaper actions, dock pinning, launcher associations, and theme actions.
- Backup/write failure, allocation failure, cancellation, and concurrent edits:
  original source and drafts survive; replacement requires a matching backup and
  source revision. Test restart after each persistence boundary.
- Resource restoration: Retry/file events restore the saved appearance without
  persisting fallback values or disrupting an unsaved draft.
- Shell and lock/service overlap: no degraded snapshot promotion or premature
  pruning; external integrations do not run from unsafe recovered configuration.
- Recovery UI: saved selection and temporary behavior are distinguishable,
  diagnostics are accessible, and unrelated edits remain usable when permitted.

Run the repository's pure tests (`zig build test`) and affected private-session
suites: `test-preferences`, `test-settings-appearance`, `test-settings-bar-editor`,
`test-settings-boundary`, plus theme/Qt/lock suites affected by the final changes.
Add a dedicated recovery integration suite if the matrix outgrows the existing
preferences test. Run all fixtures under isolated XDG roots.

Acceptance: for every recovery scenario above, startup preserves the source
bytes, an unrelated save preserves every unedited source value, temporary
fallbacks never enter the saved document implicitly, and an explicit replacement
has a recoverable original. No implementation should ship with an unconverted
writer that can serialize effective fallback preferences over the source.
