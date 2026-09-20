# Apply Matugen profiles automatically when wallpaper changes

Status: implemented locally, September 20, 2026. The sequence below records the
implementation contract. See [execution evidence](../artifacts/matugen-wallpaper-live/README.md)
for focused tests, regression results and measured latency.

## Outcome and scope

Once application themes are enabled and profiles are selected, changing the
committed wallpaper path or replacing the current image automatically regenerates
and applies the selected wallpaper-dependent templates. No additional Apply,
manual reload or Pearl restart is needed. Wallpaper selection in an uncommitted
Settings draft continues to use the existing Apply/Discard workflow.

This extends Pearl's existing managed Matugen profiles, including local profiles.
Importing arbitrary `~/.config/matugen/config.toml` destinations and hooks is a
separate feature. The current global wallpaper remains the only wallpaper source;
external wallpaper tools must update Pearl's configured path or its image file.

“Instant” means event-driven, asynchronous application after a short file-event
debounce. A cold palette extraction still takes time, and a consumer that requires
manual activation cannot be made live merely by updating its configuration file.

## Inspected starting behavior and gaps

| Area | Current implementation | Required change |
| --- | --- | --- |
| Events | `src/config/service.zig` watches `preferences.json` with a 180 ms debounce. Wallpaper contents require `preferences reload`. | Watch the active image and refresh without a preference edit. |
| Snapshot reuse | `prepareAppearance()` loads the saved application snapshot whenever `requested == null` and a digest exists. That snapshot includes render colors. | Retain committed template bytes while refreshing colors when their source changes. |
| Image consistency | Shell extraction receives the same image bytes used for decoding. `theme_provider.capture()` independently rereads an application wallpaper, with a 64 MiB limit. | Capture one input for all consumers and resolve the inconsistent limit explicitly. |
| Integration latency | Qt reconciliation runs before application rendering in the same integration stage. New reloads do not cancel that stage. | Prevent slow unrelated integration and obsolete rendering from delaying the newest wallpaper. |
| Rendering | `application_profiles.zig` has private Matugen configuration, bounded caches and owned-file journals. | Reuse these mechanisms with generation-aware staging and publication. |
| Status | Application status tracks preference revisions. Image bytes can change without a new preference revision. | Track desired and applied appearance generations separately. |

Relevant baseline contracts are in [Preferences](PREFERENCES.md),
[application themes](CUSTOM_THEMES.md), and the
[original profiles plan](MATUGEN_PROFILES_IMPLEMENTATION_PLAN.md).

## Behavior contract

| Configuration | Effect of a wallpaper change |
| --- | --- |
| Application management disabled, or an application Off | No rendering or activation for that application. |
| Application colors follow Pearl; shell uses dynamic wallpaper colors | Reuse the shell's complete new Matugen JSON. |
| Application colors explicitly use wallpaper | Refresh application colors in every shell mode. Share extraction with the shell when effective inputs match. |
| Application colors use a seed | No application regeneration solely because wallpaper changed. |
| Follow Pearl with seed, fixed package, static or GTK colors | Preserve the existing color-source contract; a wallpaper change does not turn this into wallpaper coloring. |

Successful automatic refresh preserves profile selections, captured template
bytes, theme assignments and manual/Off overrides. It does not adopt newly edited
profile files or updated packages. Existing explicit selection/adoption actions
remain responsible for changing those inputs.

## Implementation sequence

### W1 — Separate committed templates from changing color inputs

Update `src/theme/theme_provider.zig`, `src/theme/application_profiles.zig` and
`src/config/service.zig`:

- Separate profile capture from color resolution. A wallpaper refresh loads the
  committed descriptors/templates and builds new render data from current input;
  it must not rescan the catalog to adopt different template bytes.
- Record a versioned color-input identity: source, wallpaper content digest or
  seed, variant, generator version and adapter version. Preserve exact fixed
  package render data when wallpaper is not the selected source.
- Distinguish startup recovery, explicit preference changes, image changes,
  forced reload and integration retry. Forced reload checks current wallpaper
  contents; retry uses the latest desired immutable render snapshot.
- Capture validated image bytes once off the GTK thread and pass them to shell
  decoding and application palette generation. Read an image for application-only
  wallpaper colors even when the shell background is solid or gradient. Remove
  the provider's separate 64 MiB read path in favor of the existing wallpaper
  input policy; avoid unnecessary decoding when only extraction needs the image.
- Persist the latest successful runtime color snapshot in separate backend-owned
  state, keyed to the committed profile selection and color settings. Do not
  rewrite user preferences or advance their revision for each image event.
  On restart, reject runtime state for different selections; refresh valid
  wallpaper sources and retain compatible last-good outputs if refresh fails.
- Keep legacy snapshots readable. Migrate their captured profiles without
  replacing them from disk, and bound pruning to retain the committed snapshot,
  current successful runtime snapshot and any in-flight references.

Acceptance: replacing wallpaper bytes followed by explicit reload updates
application colors even with an existing `matugen.snapshot_digest`; installed
profile edits/removal do not change the committed template used by that refresh.

### W2 — Observe the active wallpaper

Add a small watcher module, such as `src/config/wallpaper_watch.zig`, owned by
`Service`:

- Watch the containing directory and filter both event paths for the configured
  basename, covering in-place writes, rename-over replacement, deletion and
  recreation. Enable it only while wallpaper display or color extraction uses
  that path. Rebind after a committed path change and stop on service shutdown.
- Coalesce bursts with the existing 180 ms debounce. Deduplicate by content
  digest after reading; same bytes cause no render, output rewrite or reload.
- Mark image events as forced input refreshes so the unchanged-preferences hash
  shortcut cannot suppress them. Keep the watcher independent of Settings drafts.
- Treat missing/truncated images as transient failures: keep last-good appearance
  and outputs, report the error, and recover on the next valid event. Allow a
  bounded retry during an active write burst, without recurring idle polling.
- Handle directory-watch invalidation explicitly: watch a surviving parent for
  recreation or report watcher unavailability with manual reload still usable.
  Continue using existing regular-file validation for every opened input.

Acceptance: in-place replacement and atomic rename both update automatically;
old paths stop triggering work after selection changes; shutdown releases
monitors and timers; idle causes no jobs or Matugen processes.

### W3 — Make the newest generation win

Refactor preparation/integration in `src/config/service.zig` and rendering in
`src/theme/application_profiles.zig`:

- Assign a monotonic desired generation to effective appearance-input changes,
  independent of preference/draft revisions. Tag staged render outputs and status
  completions with that generation.
- Keep one active pipeline and only the newest pending input. Cancel obsolete
  cancellable preparation/render work and reap subprocesses. Preserve explicit
  preference Apply transaction semantics; queue image refresh behind its commit.
- Separate private rendering from destination publication. Check cancellation
  and generation validity at the publication boundary and before each subsequent
  destination transaction or adapter activation. Serialize those boundaries
  with generation updates so a check cannot race a stale write.
- Finish an already-started journaled file transaction safely, then stop obsolete
  work. Do not claim cross-application atomicity: files published before a newer
  event remain until the replacement generation completes.
- Publish wallpaper and shell palette together once validated. Application
  templates may follow asynchronously; one application failure must not undo the
  shell update or successful independent applications.
- Schedule the current application render/publication before unrelated Qt work,
  or split integration into independently cancellable serial tasks. Do not add
  workers sharing mutable jobs, scratch files or writer journals. Give slow
  adapters separate bounded deadlines and queue the newest refresh promptly.
- Preserve ownership checks, backups, session/lock authorization and recovery.
  Retrying one failed target must not regenerate or reactivate unchanged targets.

Acceptance: a deliberately delayed A → B → C change sequence converges to C;
obsolete completions cannot overwrite C or report it as applied. A Qt timeout
does not hold a newly queued wallpaper refresh for the full Qt deadline.

### W4 — Reduce latency and report what was applied

- Reuse the complete shell palette for matching application inputs. Keep existing
  bounded palette/render caches keyed by content, captured templates, variant
  and renderer identity. Skip unchanged output writes and adapter activation.
- Resolve Matugen version once per job and pass it through extraction/rendering
  instead of spawning a version query per profile. Measure before adding further
  batching; only batch cache misses if the measurements justify it.
- Extend `matugen_profiles.Status` and the Settings protocol with desired/applied
  generations and per-target completion where needed. Distinguish updating,
  installed/generated, activation required, ownership conflict and failure.
  A partial failure must not advertise the whole generation as applied.
- Update `src/settings/profiles_view.zig` to explain that wallpaper-derived colors
  follow committed changes automatically. Provide a backend-owned retry action
  for failed current-generation work; retain the current draft workflow.
- Keep current adapters honest: Zed/Equibop installation does not prove a running
  application has reloaded; Starship installation remains explicitly opt-in;
  Fluxer/Steam continue to expose activation instructions where necessary.
  Any live reload added must be a tested adapter action, without executing global
  Matugen hooks or restarting applications automatically.
- Instrument event receipt, preparation, rendering, publication and completion.
  Initial benchmark target: cached file-change updates publish outputs within
  500 ms including debounce on documented reference hardware. Measure cold-path
  p50/p95 for small and large wallpapers and all five profiles; publish observed
  latency rather than claiming a universal instant cold path.

### W5 — Acceptance and documentation

Add focused coverage to native snapshot/renderer tests and an isolated integration
suite, proposed as `tests/integration/test_wallpaper_profiles.py` with a
`test-wallpaper-profiles` build target. Use private XDG roots and controllably slow
or failing Matugen fixtures for deterministic race tests, plus real Matugen for
palette/template compatibility.

Required scenarios:

1. Committed picker/CLI path changes, preference-file edits, in-place image edits,
   rename-over replacement and same-content replacement.
2. The complete color-source matrix above, including application-only wallpaper
   extraction with a solid shell background and shared extraction when applicable.
3. Rapid changes during preparation, rendering, publication and Qt integration;
   multiple monitors still cause one shared palette extraction per effective input.
4. Missing/invalid images, Matugen unavailable/timeout, malformed templates,
   ownership conflicts and one failed application alongside successful targets.
5. Restart with saved snapshots, changed wallpaper while Pearl was stopped,
   removed/edited profile assets, and crash recovery during runtime-state updates.
6. Dirty Settings drafts, Apply/Discard and lock/shutdown behavior: automatic
   refresh must neither apply draft fields nor manufacture preference conflicts.
7. Duplicate events, cache hits, unchanged output timestamps, bounded cache/state
   storage and no ongoing work at idle.

Run the new target plus relevant existing `test-matugen`, `test-preferences`,
`test-theme-completion`, `test-settings-appearance` and `test-border-theme` checks
in the private environment documented in [Development](DEVELOPMENT.md).
Record timing and race evidence under `artifacts/matugen-wallpaper-live/`.
Update Preferences, Custom Themes and Settings Frontend API documentation to
describe automatic refresh, runtime generations, recovery and activation limits.

Delivery order: W1 fixes stale colors first; W2 enables automatic detection; W3
is required before treating live updates as complete; W4 establishes latency and
status behavior; W5 gates release. No additional auto-apply toggle is needed:
application management and the selected color source already express intent.


## Implementation notes

- `wallpaper_watch.zig` watches the active image's directory, including atomic
  replacement events. Directory invalidation reports `watcher_error`; explicit
  reload reattaches after the directory is restored. One bounded retry handles
  transient invalid image writes, without idle polling.
- The application snapshot now separates a canonical selection identity and a
  color-input identity. Legacy snapshots remain readable. Runtime state is stored
  separately from preferences, and pruning retains committed/current/previous
  snapshot references. Retry uses the current prepared snapshot.
- A publication gate serializes generation invalidation with each application's
  bounded file transaction. Application generation/publication and Qt integration
  run as separate serial stages, each with a 15-second deadline. Already-started
  file transactions finish safely; cross-application atomicity is not promised.
- Matching shell/application sources share extraction. A job shares its Matugen
  version probe, unchanged snapshots skip application reconciliation, and cached
  outputs avoid destination rewrites. No batching was needed to meet the initial
  cached-update target on the measured machine.
- Status reports pending/applied generations, per-target completion, timeout and
  watcher errors. Lock revocation cancels publication; unlock resumes the latest
  prepared input. Existing application activation requirements remain.

The benchmark uses solid-color 64×64 and 2048×2048 PNG fixtures and all five
profiles in an isolated headless session. Its small sample p95 is descriptive;
complex photographs, different hardware and running consumer reload latency need
separate measurements. No new live-reload adapter commands were introduced.
