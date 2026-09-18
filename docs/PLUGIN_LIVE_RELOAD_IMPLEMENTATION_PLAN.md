# Live plugin discovery and replacement

Status: implemented, September 18, 2026. The baseline review below refers to
Pearl `fcdc1dc`. See [validation and measured limits](PLUGIN_LIVE_RELOAD_VALIDATION.md)
for delivered behavior, test evidence and remaining release-acceptance scope.

## Outcome and scope

Installing, updating, removing, enabling, disabling and retrying a plugin should
work while Pearl stays running. Main **Settings → Plugins** updates automatically
and offers **Refresh plugins**. The CLI gains `pearlctl plugins refresh`.
Unchanged plugins keep their helper processes, timers and state.

Implementation detail: changing the selected source/path restarts the affected
helper, even for identical bytes; its existing fingerprint approval stays valid.
This keeps views tied to immutable records and makes retries use the current path.

Changed code still requires approval of its new fingerprint. Replacing a plugin
restarts only its helper and resets guest memory; saved settings and placement
remain. No WIT ABI change or guest save/restore interface is needed for this work.
Plugin controls remain exclusively in the main Settings application.

Updating Pearl itself, changing its compiled runtime support, or renewing revoked
Aqueous launch authorization can still require restarting Pearl. Those operations
are outside plugin package management.

## Baseline implementation and constraints (before this change)

- `src/plugins/manager.zig` launches one background `Registry.scan()` from
  `Manager.create()`. `scanned()` installs the registry and appends slots once.
  Calling that callback repeatedly today would duplicate slots and lose ownership
  of earlier registries.
- `src/plugins/registry.zig` owns package snapshots, paths and decoded PNGs.
  Slots copy `Entry` values containing borrowed pointers; the registry currently
  survives until manager teardown.
- `src/plugins/view.zig` retains a slot pointer and clip/image data. Its current
  unchanged-view check compares scene JSON and reduced motion, so an asset update
  with identical scene JSON would also need a package-generation check.
- Helpers reopen the package path and verify its fingerprint. The existing
  generation/sequence checks, sandbox, content validation and privacy broker must
  remain authoritative after rescanning.
- `retry()` and CLI `plugins reload` restart an existing slot; neither discovers
  package changes. Preserve that distinction and add an explicit refresh command.
- Settings rebuilds all plugin rows when its ID/digest list changes. Retained
  drafts already merge by plugin identity, but row replacement, stale approval
  actions and changed settings schemas need explicit handling.
- Preferences identify a plugin by ID. Registry duplicate detection currently
  compares ID plus version, which can admit multiple versions of one ID. Resolve
  this ambiguity before reconciling live installations.

## Behavioral decisions

| Observed change | Required behavior |
| --- | --- |
| New valid package | Show it disabled and unapproved; approval and Apply enable it. |
| Same selected ID, path and fingerprint | Keep the existing helper, scene and timers; update discovery metadata only. |
| Different fingerprint, including asset-only changes | Stop the affected instance, clear its views/activity, and show “Update requires approval.” |
| Package removed | Stop its instance and show “Not installed” for retained configuration; preserve settings and bar references. |
| Invalid or incomplete replacement | Run no replacement; show an actionable error and retry discovery within bounded limits. |
| Exact previously approved package restored | Resume if saved enablement, settings and grants remain valid and privacy gates permit. |
| New package fails at startup | Mark only that instance failed; require Retry or a newly validated package change, with no crash loop. |
| Refresh finds no changes | No helper restarts, approval changes or preference writes. |
| Installation changes during locking/authentication | Update discovery state, but start no helper or view until existing privacy gates reopen. |

Use a deterministic selection policy: one selected package per ID; the user root
takes precedence over the system root. Multiple candidates for the same ID within
one root are a conflict, with no execution for that ID. Sort paths/IDs for stable
results and pagination; never select by directory enumeration order or arbitrary
version-string comparison. Show selected source and shadowed/conflicting packages.
A shadowed package becoming selected must pass the same fingerprint approval.
An invalid replacement of a previously selected user package must not silently
fall through to a system copy; report it until repaired or definitively removed.

## Stage 1 — Define ownership and reconciliation

Files: `src/plugins/{manager,registry,package,view,overlay}.zig`,
`src/ui/surfaces/manager.zig`, and new pure `src/plugins/discovery_policy.zig`.

1. Introduce immutable, independently retained package records containing source,
   path, fingerprint, manifest, component and decoded assets. The registry index,
   active instance and any view using package data hold explicit ownership.
   Transfer worker-built records to the GTK context before sharing them.
2. Separate discovery status (installed, missing, invalid, conflict, approval
   required) from helper status (starting, active, suspended, failed). Track a
   monotonically increasing discovery revision independently of helper generation
   and activity epoch.
3. Compute a pure diff of old/new selected records and retained preferences. It
   produces add, unchanged, replace, remove and unavailable decisions. Account for
   root precedence, duplicate IDs, source changes and byte-identical restores.
4. Reuse unchanged records and live instances. Retire changed/removed instances:
   stop dispatch, clear timers and queued input, close transport, invalidate views,
   and terminate the old helper. Its wait callback releases only that retired
   instance; it must never clear or restart a newer instance with the same ID.
5. Detach view tick/button/paint callbacks before freeing their slot/package data.
   Include package identity/generation in render invalidation even when published
   scene JSON is identical. Preserve shared ownership across multiple outputs.
6. Release retired records once all callbacks and views finish. Bound retained
   generations; repeated updates must not accumulate an unlimited retirement list.

Exit checks: pure diff tests cover every behavior above; integration tests replace
and remove an animated plugin without dangling references, leaked helpers or
restarting an unrelated plugin.

## Stage 2 — Make discovery repeatable and bounded

Files: `src/plugins/{manager,registry,package}.zig`, new
`src/plugins/discovery.zig`, `src/tests.zig`.

- Add `requestRefresh()` usable at startup, by monitors and by manual controls.
  Permit one scan in progress plus one coalesced request to scan again. Give work
  a ticket so stale completions cannot overwrite newer discovery or survive stop.
- Continue reading, hashing and decoding off the GTK thread. Commit a complete
  candidate index on the main context, then reconcile affected instances once.
- Return structured outcomes per root/path. Distinguish confirmed absence from
  permission errors, cancellation, resource exhaustion and incomplete scans. An
  unreadable root must not be interpreted as uninstalling all its packages.
- Keep existing path, symlink, component, asset and fingerprint validation. Detect
  files/directories changing during reads and reject unstable snapshots; a quiet
  timer alone cannot prove an installation is complete. Helper-side fingerprint
  verification remains required for changes between discovery and helper startup.
- Recommend staging a complete package outside the watched tree and atomically
  renaming it into place. Also support ordinary package-manager writes: debounce,
  bounded retry and an explicit incomplete/error state, never execution of a
  partially validated replacement. A currently loaded immutable instance may run
  during debounce; retire it once a changed/removed/invalid selected package is
  confirmed. Errors must not authorize replacement content.
- Preserve current limits of 32 admitted packages, 8 enabled plugins and 64 MiB
  of admitted package/decoded-image data. Add global traversal/work budgets, not
  just per-directory limits. Budget candidate plus retained package data explicitly
  (initial target: 128 MiB, excluding helper RSS); defer a new scan until retired
  data can be released rather than silently exceeding the budget.
- Refresh must not resurrect a failed unchanged plugin; Retry remains explicit.
  Shutdown cancels scans, removes timers, and safely frees late worker results.

Exit checks: concurrent refreshes coalesce; unchanged refresh preserves helper
generation; cancellation, read failures and slow/partial installs produce bounded,
truthful outcomes and leave the GTK loop responsive.

## Stage 3 — Watch installation changes

Files: new `src/plugins/discovery.zig`, `src/plugins/manager.zig`.

- Use the repository's GIO file-monitor pattern. Watch both resolved plugin roots,
  allowed container/package directories, and directories holding declared nested
  component/asset paths. GIO directory watches are not assumed to be recursive.
- If a root is absent, watch its nearest existing ancestor and move the watch
  when the root is created. Rebuild watches after deletion, rename or atomic
  replacement, including replacement of a directory without replacing its parent.
- Feed relevant create/change/delete/move events into a single debounce timer.
  Initial targets: 250 ms quiet period, at most one scan start per second, and a
  2-second maximum deferral under continuous events. Changes during a scan set
  the one pending refresh flag. Byte-identical changes never restart instances.
- Bound monitor count and discovery traversal together. When monitors are
  unavailable, incomplete or exhausted, display degraded monitoring and use a
  bounded fallback scan every 30 seconds. Manual Refresh remains available.
- Ignore unrelated temporary files where possible, without missing newly valid
  packages. Never expose a watcher or raw filesystem events to Wasm guests.
- Remove all monitor signals, sources and retained paths on manager shutdown.

Exit checks: install into an initially missing root, modify a nested asset, rename
a package/root, and remove/reinstall a package without restarting Pearl. Event
storms remain bounded; a simulated monitor failure still recovers through fallback.

## Stage 4 — Approval, configuration and privacy

Files: `src/plugins/{manager,model}.zig`, `src/config/{preferences,merge}.zig`,
`src/ui/surfaces/manager.zig`, Settings backend validation.

- Discovery never writes preferences or changes saved enablement/grants. Effective
  execution requires the currently selected fingerprint to match saved approval,
  a valid configuration, enabled status and an open privacy gate.
- Show old approval and new fingerprint clearly. Approving an updated package
  stages the new fingerprint and explicit permission review in the existing draft;
  require grants to be reconfirmed for changed content. Newly requested permissions
  default off, including any stale grant left from an older version. No background
  carry-forward can grant a capability to newly discovered code.
- Keep compatible saved settings and placement. Report removed keys, changed types,
  invalid values or withdrawn capabilities for explicit correction/reset; do not
  silently rewrite saved settings or discard unrelated draft edits.
- Validate approval against the current discovered fingerprint at Apply and again
  at helper startup. An obsolete approval action must not approve a different
  update that arrived while Settings was open. Missing packages may retain old
  configuration, but remain non-runnable.
- Clear pending activity and refresh broker demand when retiring an instance.
  Starting a replacement obtains a fresh helper generation and subscription intent;
  it receives no timer, click, Preview or activity queued for its predecessor.
- Keep the session-owned authorized Aqueous manager alive through all refreshes.
  Never restart/re-authorize the broker simply because plugin files changed.
  Lock, polkit, sleep, inactivity, grant revocation and shutdown remain authoritative.

Exit checks: stale approval and newly added capabilities cannot run implicitly;
an unrelated settings draft survives package changes; update/removal during a
privacy transition cannot publish a view or replay input on resume.

## Stage 5 — Main Settings and CLI

Files: `src/settings/{protocol,live_protocol,backend,live_backend,plugins_view}.zig`,
`src/cli/{options,protocol}.zig`, `src/ui/surfaces/manager.zig`.

- Add a page-level **Refresh plugins** action, discovery progress, last result and
  monitoring status. It starts/coalesces discovery without applying a settings draft.
  Use a dedicated page action rather than a fabricated plugin ID.
- Publish discovery revision, installed/missing/error status, selected source and
  available/approved fingerprints through the existing live Settings boundary.
  Keep protocol changes additive where possible and negotiate new operations using
  the existing compatibility mechanism; older frontends must remain usable.
- Update rows by stable plugin ID. Preserve unaffected widgets, keyboard focus,
  scrolling, unsaved values and retained drafts. For a changed schema, keep the
  draft document and offer review; disable stale row actions until refreshed.
  Handle pagination changes deterministically and avoid mismatching rows/schemas.
- Add `pearlctl plugins refresh` to queue discovery. Return its requested discovery
  revision/ticket, then expose pending/completed/error state in `plugins list`.
  Document that acceptance of a refresh request is not completion or approval.
  Keep `plugins reload --path ID` and Settings Retry as instance-restart actions.
- Maintain the existing session-bound command authorization and Settings view/
  operation checks. Refresh is discovery-only and must not bypass approval.
- Replace “restart Pearl after installing/updating” guidance only once these paths
  pass. Update `PLUGINS.md`, `PLUGIN_DEVELOPMENT.md`, `plugins/README.md`, CLI help
  and the original plugin roadmap. No flyout controls or new package-service units.

Exit checks: installation appears while Settings is open, removal preserves the
draft, asset-only updates redraw after approval, manual Refresh works without
monitors, and the flyout still rejects the Plugins route.

## Stage 6 — Acceptance and delivery

Add `tests/integration/test_plugin_discovery.py` and a corresponding build target;
extend existing plugin, helper, Settings and activity suites where appropriate.
Use temporary package roots, private displays/buses, and test-only delays for
deterministic filesystem races. Do not modify the user's installed plugins.

| Area | Required coverage |
| --- | --- |
| Discovery | Startup, absent roots created later, install/remove/restore, nested assets, atomic directory moves, invalid manifests/components/PNGs, unknown or changed IDs, root access failure. |
| Selection | User/system precedence, same-ID different versions, same-root conflicts, removal of an override, stable ordering and pagination. |
| Approval | New/updated fingerprint, asset-only change, stale draft/Apply, capability additions/removals, invalid settings migration, restore of approved bytes, no automatic preference writes. |
| Lifetime | Replace while a callback/timer/animation is active, helper exit after replacement, removal across multiple outputs, identical scene with changed assets, shutdown during scans. |
| Scheduling | One active scan and one pending request, stale completion rejection, monitor storms, watch exhaustion/failure, bounded retries, traversal/memory budgets. |
| Isolation | Unchanged helper PID/generation and guest state survive refresh; one corrupt or crashing update leaves other plugins and native controls responsive. |
| Privacy | Refresh/update/remove while locked, polkit pending, inhibitor ack stalled, session inactive and input queued; preserve authorization and prevent stale activity. |
| UI/CLI | Main-only Refresh, progress/errors, draft/focus preservation, schema change review, refresh completion ticket and unchanged Retry semantics. |
| Compatibility | Wasm-disabled build discovers packages without helpers; older Aqueous retains clicks/Preview; existing WIT components remain compatible. |
| Repeated changes | At least 100 install/update/remove cycles plus close/reopen Settings; helper, FD, monitor and package allocations return to baseline. |

Run unit tests, enabled/disabled builds, helper and plugin desktop suites, the new
discovery suite, and existing activity/lock regressions. Measure idle cost with
working monitors and bound work during a file-event storm. After a settled valid
install, target discovery within 2 seconds on the reference private session; report
fallback polling separately. Record measured results rather than claiming hardware
or whole-release acceptance from these checks.

Delivery order: ownership/diff → explicit background refresh → replacement and
approval/privacy tests → Settings/CLI → automatic monitoring → combined acceptance
and guide updates. Manual refresh provides a reviewable milestone before watchers
start triggering the same path automatically.

Done means one unchanged Pearl PID/session handles a complete install → approval →
enable → update → new approval → disable → removal → reinstall workflow, with no
restart instruction and no disturbance to unchanged plugins. Existing physical
input and broader release acceptance gates remain tracked separately in the
[activity validation record](PLUGIN_INPUT_ACTIVITY_VALIDATION.md).
