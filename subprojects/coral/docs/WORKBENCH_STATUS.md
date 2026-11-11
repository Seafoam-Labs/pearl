# Coral workbench implementation status

**M0 is accepted with documented bounded-editor tradeoffs. M1 implementation and native correctness acceptance are complete. M2 implementation is COMPLETE for the bounded workspace preview. Bounded M3 language intelligence is implemented and validated: COMPLETE. Next: M4 Git/review, not started.** The final feature audit concludes all mandatory M2 features are implemented: multi-root workspaces, explorer/search, settings/trust, docks/native pickers, explicit checkpoints, automatic project/latest per-window and scratch snapshots, ordinary multi-window startup, independent ownership, reviewed root management and bounded file operations. See the [M2 acceptance audit](WORKBENCH_M2_ACCEPTANCE.md) and the separate [final validation checkpoint](#full-m2-validation-checkpoint).

The user explicitly accepted the M0 tradeoffs and requested work on M2. This acceptance does not turn failed or unmeasured performance targets into passing measurements. This is not a full IDE or Zed parity release. M2 implementation is complete within its documented bounds; M3's implemented scope and completed frozen-source validation are recorded below; M4–M8 remain future milestones; M9 remains removed. The [interactive prototype](mockups/workbench/index.html) is a design fixture, not connected to native Git, LSP or agents.

## Historical native visual alignment before M3

The requested **M2 visual-alignment pass is implemented**: compact workspace/command titlebar, activity rail, Explorer/dock overflow controls, root-qualified tabs, per-group breadcrumbs, live status bar, responsive bottom-panel presentation and Coral mockup palettes. Native GTK and committed Follow Pearl ownership remain intact; no fake Git/LSP/terminal/agent panels were added. This records the pre-M3 visual increment, not the current language implementation or its aggregate result.

Final visual matrix **16/16**, widget suite **201/201**, all native M1/M2 checks **271/271**, and hooks-disabled production build passed. That visual increment's `test-m2` aggregate nevertheless failed on an unchanged process-supervisor unit-test abort; the standalone rerun freshly passed **326/326** main-root tests. This caveat is not erased by the rerun. See [visual scope, screenshots, intentional differences and exact validation](WORKBENCH_M2_VISUAL.md). Earlier closure counts below are historical, not the current patch's aggregate result.

## M3 language intelligence: implemented and validated, bounded scope complete

The [M3 user guide](WORKBENCH_M3_LANGUAGE.md) records every native command, configuration schema, protocol bounds and explicit refusals. Delivered behavior:

- Explicit workspace trust **then Language: Start… confirmation**; no auto-start on trust/open/restore. Default **`/usr/bin/zls` 0.17.0**, tested with **Zig 0.17.1**. User-owned **`~/.config/coral/languages.json`** is separate from repository settings; checked config ancestors cannot be symlinks and identities require birth time. Servers have user permissions, **not a sandbox**; no downloads/installation or network-service tests.
- One session per owning root/language, **eight per window**, with independent ownership, Start/Stop/Restart/Status, bounded stdio framing, negotiated UTF-8/16/32 positions and full/incremental synchronization. Incremental changes replace the old document range, not minimal diffs. Cancellation, versions/generations, trust/config/root invalidation and reaping reject stale work. Native queues are **8 MiB input / 4 MiB output per session**, not the standalone transport defaults of 64 KiB/256 KiB. Eight sessions reserve at most **96 MiB of queues**, excluding 8 MiB/session snapshots, 16 MiB/thread worker stacks, framing/events, editor and kernel storage. Versions advance only after successful sync; failures stop once with a stable error, not 20 ms retries. Protocol/message limits remain independent of retention limits.
- Native completion/hover/signatures, definition/declaration/type-definition/implementation/references, document/workspace symbols, document/selection formatting, rename and code actions. **Problems aggregates synchronized open documents** across the window's ready sessions, with real diagnostic tags and unversioned/unverified labelling where required.
- Actual **semantic-token full/delta GTK tags**, explicitly refreshed; **inlay hints are a position picker, not inline**. Lenses resolve to separately confirmed advertised server commands. File links use checked navigation; HTTP(S) external links require confirmation. No fake service panels.
- Navigation/text edits stay in the **same owning root**, not a peer root or external dependency/standard library. Supported multi-document text edits are reviewed, revalidated grouped undo transactions, **never autosaved**.
- **Single standalone create/rename/move/delete resources** go through reviewed Explorer workers and cause real disk changes after confirmation, **with no undo**. No mixed/batch resources, overwrite, ignore options, recursion or resource-follow-up commands. Capabilities advertise `failureHandling: textOnlyTransactional`; static filtered didCreate/didRename/didDelete notifications are implemented, not dynamic registration or will-operation requests.
- **`snippetSupport: false`** is intentional. Safe-subset flattening of unsolicited snippets is defensive text handling only; interactive snippets remain **M8**, not M3 delivery. Unknown/unconfigured languages, excerpt-origin requests and unsupported server-to-client services receive explicit refusals.

### M3 final frozen-source validation — passed

After the queue/synchronization fix, **`zig build test-m3 -Doptimize=safe -j1 --summary all` passed 99/99 steps**, exit 0, in **28m23.163s** within **2,400,000 ms (40 minutes)**: **36 fresh successful / 63 cached steps**. Main Zig root: **334 freshly passed**; **nine other runners cached**, including the five pure language runners already executed directly and freshly: **102 = 16 protocol + 20 transport + 36 client + 27 features + 3 file-operation tests**.

All **17 Python harness/fixture invocations ran fresh**: **75/75 mandatory native language cases passed / three optional blocked** (clangd, TypeScript, Python), **20/20 language-lifecycle groups**, **271 M1/M2 native groups**, **204 widgets in 42.099s**, and **25 fixture self-tests**. The five new capacity cases cover full/incremental sync of **128 KiB and 1 MiB Unicode documents**, plus oversized-message stable-error handling. Counts overlap and are not additive unique tests.

Hooks-disabled production passed **46/46 steps**, exit 0, **three fresh / 43 cached**, including fresh executable compilation in **30.053s**. Separate visuals passed **16/16 cases plus four font-ratio checks before the final queue/sync-only change**, not a rerun on the final binary. A secondary-panel footer still ellipsizes/clips at **390px**. Fake-server **67–133ms end-to-end** observations are not paint latency or evidence for the **unmeasured 50ms** target. Native harness reaping assertions passed; **no final baseline process/temporary-directory cleanup scan was done**.

Definitive local logs: [fresh pure suites](../../../.cache/coral-m3-complete-language-unit.log), [aggregate](../../../.cache/coral-m3-complete.log), [production](../../../.cache/coral-m3-complete-production.log), and [earlier separate visual pass](../../../.cache/coral-m3-final-visual.log). Latest `pearl/.cache/coral-language/results.json` and retained `pearl/.cache/coral-language/run-r_olc__s/results.json` contain the complete **75/0/3** matrix; `pearl/.cache/coral-workspace-lifecycle/results.json` records **20/20**. The [M3 final validation report](WORKBENCH_M3_LANGUAGE.md#final-validation-passed) records both final binary SHA-256 values and evidence links.

Earlier `coral-m3-full.log` / `coral-m3-final.log` attempts remain historical, including the missing-root diagnostic and lifecycle transcript cross-run contamination failures. The diagnostic and stale visual menu-category assertion were fixed; unique temporary transcripts per launch fixed contamination, followed by two passing 20-case lifecycle repeats and the final aggregate pass. `coral-m3-accepted.log` was green **before** the capacity fix and is superseded by `coral-m3-complete.log`. The pre-M3 process-supervisor abort and earlier M2 widget timeout remain historical failures, not erased by later work.

## Milestone acceptance

| Gate | Current evidence / disposition |
| --- | --- |
| M0 reference and interaction matrix | [Frozen references](WORKBENCH_M0_REFERENCES.md): Zed v1.27.0, ZLS 0.17.0, ACP schema-v1.29.1 / wire v1; intentional differences recorded. No live provider required or used. |
| M0 prototype review | [Technical UX review](WORKBENCH_M0_UX_REVIEW.md): 40 passing browser checks, 55 geometry checkpoints, inspected screenshots, no external requests. The user's subsequent tradeoff acceptance authorizes proceeding to M2; the report retains its historical technical-review evidence. |
| M0 independent views / editable excerpts | Native application groups and source-mapped editable excerpt tabs, independent presentation buffers, canonical undo and negative mapping tests. |
| M0 terminal feasibility | [GTK4 VTE spike](WORKBENCH_M0_TERMINAL.md): embedded real renderer, PTY Unicode input/output, resize, exit/cancel/close and reaping. VTE built privately, not installed on the host. M5 production terminal remains unimplemented. |
| M0 engine risks | Widget proofs for multiple marked edit positions, pane-local folding, mark-anchored overlays and checked suggestion acceptance. True inline reflow, full multicursor input/IME and production advanced editing remain unproven, not promised by these proofs. |
| M0 benchmarks | [Measured baselines and engine decision](WORKBENCH_M0_BENCHMARKS.md). Retain GtkSourceView for the bounded foundation. Full giant-paragraph rendering fails; the 1 MiB bounded-excerpt fallback completes all samples. Some proposed timing targets are missed; real injected-key-to-paint targets remain unverified. |
| M1 registry, views/groups and commands | Integrated and covered by native tests. |
| M1 stale/multi-document edit and undo safety | Checked transactions, attributable grouped history, protected typing intervals and save-generation guards; deliberate conflict refusal rather than partial rollback. |
| M1 file integrity, watchers and lifecycle | Existing regressions pass, plus undo-during-save and grouped-history clean-checkpoint regressions. Workspace identity rejects stale/cross-workspace callbacks. |
| M1 interrupted saves/recovery | Versioned durable journal, explicit restore/keep/discard, crash/publication fault tests, source conflict protection and current-layout recovery. |

**Recorded M0 acceptance:** the user stated, “i accept the trade off and begin work on m2.” Retain GtkSourceView with the visible syntax/long-line policy and bounded-excerpt fallback, accept the documented timing misses for this foundation, and defer real injected-input-to-paint qualification. Full giant-line rendering and paint targets have not passed; their evidence and limitations remain in the benchmark report. M0 is no longer blocked on these tradeoff decisions.

## M2 workspaces, discovery and policy: implemented increments

See [workspace usage and bounds](WORKBENCH_M2_WORKSPACES.md) for the schema and exact scope, and [full M2 acceptance](WORKBENCH_M2_ACCEPTANCE.md) for the composed evidence.

- Native **Open Folder…** and **Open Workspace…** menu/palette actions, plus explicit `--folder PATH` / `--workspace PATH` CLI options. Existing bare-directory file arguments remain rejected.
- Strict version-1 `.coral-workspace` manifests, up to 32 roots and 1 MiB of JSON. Relative roots resolve against the supplied manifest path's parent. Available canonical aliases deduplicate; colliding root names remain distinct through typed `RootId`s. Missing roots remain visible and are never created.
- Root-qualified tabs and a lazy expandable **GtkListView** explorer with recycled rows. **Load more** replaces a 256-entry window; sorting is per page, not global. **Roots / Back / Rescan / Close workspace / Reset tree** expose navigation and capacity recovery. Limits: 64 directory states, eight resident pages, 1 MiB page arenas; scans process at most 4,096 directory records per call.
- Nested `.gitignore`, final root-relative manifest `exclude` patterns and unconditional `.git` hiding. Policy read/parse/budget errors fail closed. Shared page/ancestor matching budgets bound adversarial work; empty incomplete pages remain resumable.
- Batched inotify updates for accessed directories and relevant ancestors/policy paths, not recursive monitoring of every descendant. One additional watch worker handles registration, symlink resolution, reads and retirement off GTK, with one replaceable queued plan, 128 subscriptions/snapshot and bounded path storage. Debounce is 100 ms / at most 500 ms until eligible. Monitor failure shows a manual Rescan fallback.
- Initial manifest publication waits for watch installation, revalidation and a notification-drain barrier; only EAGAIN confirms drain. Symlink target/link/intermediate-link changes, overflow and stale watch generations have regressions. Continuous traffic can delay publication; blocking filesystem calls can delay shutdown.
- Filesystem work runs on GTask workers. Request/model generations reject late results; switching/closing a workspace preserves open dirty documents. Failed manifests leave the previous workspace intact.
- Bounded admission: eight total outstanding operations including at most one workspace chooser; 128 KiB retained request-path budget; identical pending file opens deduplicate. Rejected requests do not invalidate accepted work. Canceled workers retain their slots and application holds until completion. Blocking mount I/O is still not forcibly interruptible.
- Restricted by default; a machine-owned controller now supports explicit persistent trust/revoke. Manifest/folder settings accept only four safe editor keys and language overrides. Executable settings and manifest-supplied trust remain rejected. This M2 increment enabled no executable features; M3 separately adds explicitly approved language processes.
- Descriptor-relative browser traversal rejects symlink components, special files and escapes. Search-only ancestor directories are supported. This is not a sandbox for the subsequent path-based document loader against concurrent rename races.
- Crash recovery still restores documents/layout, **not workspace roots/manifests**. Separate explicit checkpoints and automatic project sessions restore workspace sources and editor state. Real recovery decisions take precedence over automatic startup; empty journals do not.

**Explorer-increment validation (2026-11-09):** separate `test-m1`, `test-m2-slice` and `test-m2-explorer` runs passed with `-Doptimize=safe -j1 --summary all`: **158 widget tests, 40 native workflows, 14 group/history checks, 13 recovery groups, 18 workspace groups and 19 explorer groups**. Headless steps were cached successes on this final rerun. The initial aggregate invocation hit a 240-second timeout; separate runs totaled about 244 seconds with no reproduced deadlock. Attributable orphan private-session processes were cleaned up.

The native explorer fixture reached **100,000 files exactly once across 391 pages in 10.12 s**, with **205 peak row widgets** and RSS rising from **66,555,904 to 68,534,272 bytes**. Maximum input acknowledgement was **66.26 ms**, main-loop probe gap **26.06 ms**, and close/cancel acknowledgement **65.51 ms**. These are local input/loop measurements, **not paint latency**. This validates bounded explorer browsing, not recursive indexing/search or all of M2. Evidence and detailed limits: [workspace report](WORKBENCH_M2_WORKSPACES.md), `pearl/.cache/coral-explorer/` and `pearl/.cache/coral-workspaces/`.

### Quick Open and workspace search increment

- **Ctrl+P** fuzzy file picker and **Ctrl+Shift+F** literal case-insensitive text search, with root/file grouping and virtualized rows. Unicode-scalar navigation verifies the loaded match in the captured active group.
- Dirty file-backed documents override disk contents; omitted oversized overlays still suppress stale disk matches. Revision, workspace, policy and query invalidation discard stale results. Each activation has its own serial, so older successes/errors cannot invalidate a newer selection; streaming continues during activation without losing batches.
- One active session, one latest pending query, one batch in transit; 150 ms debounce. Native caps: 1,024 text matches / 128 fuzzy candidates, 1 MiB/file, 256 MiB total source bytes, 4 MiB retained overlay text, plus traversal/allocation/work ceilings. Incomplete results state omission reasons.
- Descriptor-checked reads, policy revalidation and cooperative cancellation; workers retain holds through cleanup. Snapshot results need **Refresh for unmonitored changes**: no persistent index or recursive watch expansion. No workspace-wide replace.
- **Nine native search groups passed**, including actual 100,000 nonempty files across 100 directories, exactly one complete result for each unique query, dirty preservation, policy/activation races and shutdown. Dedicated traversal input-ack maximum **25.33 ms**, real editor typing acknowledgement **92.80 ms**, peak widgets **205**. These are not paint timings; retry caveats and bounds are in the [search guide](WORKBENCH_M2_SEARCH.md).

### Settings provenance and workspace trust increment

- Safe `lines`, `wrap`, `spaces`, `indent` resolve defaults → explicit user → workspace → folder → workspace language → folder language. **Workspace: Settings and Trust…** shows values/origins; real full, duplicate and excerpt views use them. Logical language survives syntax-budget detachment. Global appearance/spelling remain user-owned.
- Optional root `.coral/settings.json` is bounded and descriptor-read on workers. Rescan refreshes folder-only and manifest models. Malformed/unreadable policy rejects the candidate without losing dirty documents; execute-only ancestors remain supported. Repository values never overwrite user preferences.
- Explicit confirmation persists trust outside the project. Exact identities include root/manifest-base paths, device/inode/birth time, repository policy, safe-user values/presence and versioned defaults/precedence. Unsupported birth time remains restricted. Ongoing identity changes need fresh approval, even when an alternate identity has a prior grant.
- Immediate revoke synchronously invalidates permits for matching lexical workspace scopes across this process, with serialized persistence and stale-approval cleanup. Failed persistence stays visibly restricted locally but may leave a disk approval; cross-process cancellation is not instantaneous. Bounded private store, locks, atomic synced writes and quarantine are covered. No executable consumer or blanket tool permission is implied.
- **17 native policy groups passed**, 168 fixture hashes and 34 absent execution sentinels. See [settings/trust guide](WORKBENCH_M2_POLICY.md) for schema, storage requirements, failure behavior and full validation.

### Explicit saved-session increment

- **Save Workspace Session / Restore Workspace Session** in the palette persist one checkpoint independently of crash journals. Restore preserves existing documents, tab order, groups, selections/scroll and editable excerpts. It requires closing an active workspace first; that does not close its documents.
- Clean files rebind only after regular-file/content/etag verification. Dirty, conflicting, duplicate-bound and unavailable files become pathless dirty copies requiring Save As. No source files are written or missing paths created.
- Fresh manifests/settings and separate trust revalidation apply. Missing roots remain unavailable; a missing/invalid manifest aborts restore with saved-root diagnostics. Supported lexical `.`/`..` root spellings roundtrip unchanged.
- Private bounded session v2 storage (v1 read compatibility), strict checksum/schema, nonblocking locks and atomic synced publication. Corrupt/future slots are kept and block replacement. One worker owns its snapshot/hold; stale callbacks are rejected, failed post-load restores roll back their own workspace/documents without touching newer selections.
- **Explicit-slot semantics:** one shared slot, last accepted explicit save wins. Automatic startup/close snapshots use a separate project catalog and never overwrite this slot; missing-manifest fallback remains unsupported. Later edits/Discard do not erase the explicit checkpoint; restoring it again is a deliberate action.
- **18 backend tests and 19 native session scenarios passed.** See [session usage, limits and validation](WORKBENCH_M2_SESSIONS.md).

### Native docks and picker increment

- Movable, resizable, hideable **Explorer/Search** docks at left/right/bottom, with activity rail, same-dock tabs, keyboard/palette commands and Reset layout. No placeholder service panels. Compact allocations display one auxiliary panel while preserving desired wide layout.
- Quick Open now overlays the editor without resizing it; Escape restores editor/excerpt focus, and successful navigation commits before dismissal. Quick Open and Search intentionally share a query/result controller. Command palette and folder/workspace choosers retain their existing lifecycles.
- Independently shrinkable editor-group viewports and ellipsized excerpt headers prevent long content from pushing sibling groups outside the editor. Registered shortcuts use selective capture; plain typing/widget-local handling propagates normally. Focus is parked safely during Explorer row recycling; watcher results do not steal editor/query focus or reveal hidden docks.
- Session **v2** adds validated desired dock layout, applied after successful restoration. V1 loads with default docks; older readers reject v2. The explicit checkpoint and automatic project snapshots both carry desired layout; they are separate stores. Crash recovery format is unchanged.
- **27 native dock scenarios and 190 widget-root tests passed**, including actual splitter drags, geometry across compact/wide sizes, tab/Find keyboard regressions, focus-safe watcher refresh, v1/v2 session handling and shutdown. See [dock guide](WORKBENCH_M2_DOCKS.md).

### Multi-window ownership increment

- **Ctrl+Shift+N** creates an independent native window; **Ctrl+Shift+W** closes its owner; **Ctrl+Q** now means **Quit All**, resolving windows sequentially. Cancel/save failure stops the chain without reopening already closed windows. Next/Previous Window are available in the menu/palette.
- Stable IDs and a limit of **16 live plus draining windows**. Window-local actions and worker/chooser/recovery holds keep callbacks bound to the correct App; closed owners are reclaimed after draining, not retained until process exit. CLI inputs and recovery discovery apply only to the first window.
- Documents, groups/history, workspaces, search, docks and recovery journals are independent. Canonical paths deduplicate only within a window. Same-file buffers are not shared; saved etags and **16 in-flight destination reservations** protect against conflicting/overlapping saves within the process, not external filesystem races.
- User preferences broadcast to live windows, each retaining its repository overrides; writes use one running plus latest pending snapshot. Palette/font CSS is scoped per owner. Named GTK themes remain display-wide with reference-counted lifetime.
- Matching-scope revocation uses **256 non-evicted generation markers**, failing closed at saturation. New windows cannot revive an old approval after pending/failed removal; fresh approval waits for matching cleanup even after its owner closes. Cross-process notification is not implemented.
- The explicit saved-session slot remains shared, with one operation admitted process-wide. No cross-window tab transfer or shared buffers. Automatic project sessions restore independent windows and their internal layout, not desktop window positions.
- **27 native window cases and 191 widget-root tests passed**, including real shortcuts/chooser buttons, callback drains, 24 create/close cycles, same-file saves, preference/CSS isolation, recovery and trust races. See [multi-window usage, bounds and evidence](WORKBENCH_M2_WINDOWS.md).

### Explicit workspace file-operation increment

- Explorer selection plus buttons/menu/**Explorer:** palette actions provide **New file, New directory, Rename, Move and Delete permanently**. Input → worker preparation → separate explicit review confirmation applies to **every kind**, with no writes before confirmation and no auto-open after creation. Restricted workspaces permit these explicit edits without tool execution.
- Exclusive empty-file `0600` / directory `0700` creation (umask applies), existing parents required; rename is a sibling basename, move is root-relative within the same root/filesystem, with no overwrite or copy fallback. Delete is regular-file/empty-directory only, with a permanent warning and no trash, undo or recursion.
- Checked paths reject symlinks, including canonical-root ancestors, special files, empty/`.`/`..`/`.git` components and absolute destination input; full paths are capped at 4,095 bytes. Retained source fd/stat metadata and root/parent chains are rechecked before syscall. No content hash, fsync durability or atomic protection against final external source/parent rename races is promised: this is best-effort containment, not a sandbox.
- Process-wide admission includes live/draining windows and refuses **all affected open documents, clean or dirty**, plus pending loads/choosers/saves/sessions/recovery. Save or explicitly discard as needed, then close affected documents everywhere; saving alone is insufficient. Peer/nested roots and active manifests are protected. Accepted confirmation holds a process-wide barrier through apply callback, refusing opens/saves/session/workspace switches/New Window while unaffected buffers remain editable.
- **Any unavailable root or lexical `..` in any open process workspace's root/manifest blocks all mutations with `WorkspaceBusy`.** Close the affected workspace or reopen verified available normalized/canonical paths; never blindly collapse `..` across possible symlinks. This deliberately includes apparently unrelated workspaces.
- Captured workspace/request identities fail stale requests safely; application holds cover workers, cancellation and descriptor cleanup. Success rescans current Explorer and invalidates Search for explicit Refresh. No in-place document rebinding. This M2 increment supplied no LSP events; M3 now adds static filtered did-file notifications after successful reviewed operations.
- New targets: `operations` and `test-m2-operations`. Historical results: **23 backend tests**, fresh **305 main-root tests** (including the backend and manager tests), initial **22 native scenarios**, then **three alias-review scenarios separately**, all passed; counts overlap. **Final all-25 native and all nine aggregate gates passed**, followed by a fresh hooks-disabled production build. See [usage, limitations and final validation](WORKBENCH_M2_OPERATIONS.md#final-validation--2026-11-09).

### Automatic projects, native pickers and root-management closure

- Automatic latest snapshots per window/project identity include scratch windows, desired docks, groups, selections and excerpts. **Ctrl+Alt+P Open Recent Project** activates a matching live owner or restores an independent window; **Ctrl+Shift+O Open Buffers** selects this owner's full/excerpt views. Open Folder/Workspace keeps documents and durably retires the old project; there are no isolated same-window tab sets.
- Ordinary no-file/folder/workspace-CLI startup restores the retained window set. Explicit CLI and actual recovery decisions suppress prior membership but retain recents; empty recovery does not. Cross-process lifetime leases and generation checks prevent duplicate claims, including the tested three-process race.
- Capture samples every second, scheduling after one second quiet / at most five seconds of change when eligible, plus worker latency. Errors are visible. Frozen pre-prompt close state reconciles Save and excludes Discard; cancellation/failure thaws survivors. Over 4 MiB/document or 8 MiB total text, explicit close-without-retention still requires Save/Discard and durable old-membership clearing.
- Catalog limits are **64 records / 16 startup members / 256 MiB**, with no silent dirty eviction. Forget requires confirmation, refuses live records across processes and atomically compares generation/removes membership. The explicit `sessions/current` is unchanged by automatic writes/Forget. Native snapshot pickers cap at **512 items / 50 displayed matches**, not unlimited pageable history.
- Folder-only root management requires **Save Workspace As…** to a new destination first; **Workspace: Add Folder… / Remove Selected Root…** then review and immediately write the manifest. Existing directories only; no disk deletion or document loss; last-root removal refused. Supported settings/excludes/names and absolute lexical path meaning survive serialization; source bytes/etag are revalidated. Dedicated root rename/reorder controls are not implemented.
- Confirmed new native suites: **25/25 projects** and **18/18 roots**. [Project/root guide](WORKBENCH_M2_PROJECTS.md) records exact controls, safety and limits. [Acceptance mapping](WORKBENCH_M2_ACCEPTANCE.md#w07-exact-coverage-not-an-inflated-single-test-claim) distinguishes rich W07/layout coverage from startup roots/membership assertions and complementary pending-operation races.

## M1 foundation: implemented and integrated

### Canonical documents, independent views and groups

- `src/editor/registry.zig` owns canonical documents with process-wide nonrecycled IDs. Canonical paths deduplicate opens within each window and follow Save As.
- `src/editor/view.zig` and `projection.zig` give each view its own GtkSourceBuffer, selection, caret and scroll. Edits synchronize incrementally with one authoritative document; mirrors never own file saves or divergent undo histories.
- `src/editor_groups.zig` and `src/app.zig` provide equal-width horizontal groups, split/focus/close actions and duplicate views. Closing a duplicate view does not prompt or destroy the document. Quit resolves each canonical dirty document once.
- Search, status, go-to, spelling, context menus, styles and editability route through the appropriate presentation. GTK iterators are not exchanged between buffers.
- Callback detachment protects retained tab/page/buffer widgets. The spelling-popover focus fix prevents opening a popover from detaching its own focus subtree.
- `src/workspace/identity.zig` provides typed process-local workspace IDs and generation tokens. Actual watcher/load callbacks validate them, resolve document IDs, and release resources even when rejecting late results. This is identity/lifecycle infrastructure, not M2 multi-root workspace support.

Use **Ctrl+\\** to split. The menu and **Ctrl+Shift+P** palette expose **Focus next/previous editor group**, **Close editor group**, **Edit selection as excerpt**, **Undo grouped edit**, and **Redo grouped edit**.

### Transactions, excerpts and guarded undo

`src/editor/transactions.zig` validates identity, revision, writable/busy state, complete source contents, UTF-8 boundaries, NUL, object content, ranges and overlaps before any mutation. Full-target validation remains in place after optimization. Preparation owns snapshots; retained buffers never retain a closed document. Successful plans cannot be replayed.

- Default transaction limits: 128 targets, 65,536 replacements, 16 MiB per buffer and 64 MiB combined bytes. These are separate from file-load and recovery limits.
- Replace, replace-all, spelling and excerpt edits use canonical checked transactions. Unchanged replacements create no edit.
- `excerpt.zig` uses source marks with explicit gravity; `excerpt_editor.zig` mounts an actual editable native view with a noneditable header. Historical snapshots are read-only. Source changes refresh bounded regions, not guessed concatenated offsets.
- `history.zig` validates all participating buffers before grouped undo/redo. Defaults: 100 records / 64 MiB accounted history budget. No atomic filesystem undo or automatic save is implied.
- `native_history.zig` isolates typing intervals from grouped operations because GTK user-action boundaries alone can merge adjacent edits. Native undo cannot undo half a grouped operation. Save generations prevent an older typing interval's clean marker from clearing a document that differs from the newest disk save.
- **Conservative history limits:** edits, including edit then native undo, can make older grouped records stale. The UI refuses rather than overwrites newer work. Typing history predating the first grouped-history boundary stays physically retained by GTK but is inaccessible through application undo; later protected intervals are retained across safe grouped replay. Arbitrary interleaving is not promised.

Guarantees are validation atomicity, not isolation from arbitrary synchronous GTK reentrancy or atomic multi-file writes. GLib allocation failures retain GLib's fatal-OOM behavior.

### File integrity, monitoring and saves

- Existing-file opens resolve regular local files and local file URIs without creating missing files or parents. Use **New → Save As** for creation. Directories, devices and FIFOs are rejected.
- Descriptor-checked asynchronous loads read the verified open file under a 128 MiB cap. Linux `/proc/self/fd` provides GIO-compatible descriptor metadata. This is not a filesystem sandbox or a universal coherent snapshot on hostile/network filesystems.
- File monitors flag external changes without replacing buffers. Async metadata queries coalesce and carry document/workspace identity and generations. Save As and close reject old callbacks safely.
- **Reload from Disk** requires explicit discard confirmation for dirty buffers. Completion and large-file acceptance both check starting revisions.
- Successful stale saves cannot mark the newer buffer clean, including when undo reaches the previous GTK clean checkpoint while the save is in flight. `Document.recordSavedRevision` tracks whether that checkpoint still represents disk; stale checkpoints stay conservatively dirty until a current save/load.
- Save cancellation/failure preserves buffers and existing file-integrity behavior. Multi-file buffer operations do not silently save, stage, commit or run commands.

### Durable recovery and session layout

`src/workspace/recovery*.zig`, `main.zig`, and App snapshot/restore APIs are connected, not standalone persistence modules.

- Private per-session journals under `$XDG_STATE_HOME/coral/recovery` (normally `~/.local/state/coral/recovery`), with lock ownership and descriptor-relative filesystem operations.
- Schema v2, v1 read compatibility, bounded JSON/base64 and SHA-256. Unknown/corrupt records are retained and refused, not silently migrated or deleted.
- Worker publication: temporary file → write → fsync → rename → directory fsync. One running and one coalesced pending write; uncertain durability prevents resolved deletion.
- Checkpoints debounce for 350 ms, with a two-second scheduling cap during continuous changes, plus actual write latency. A crash recovers the **last durable checkpoint**, not necessarily the latest keystroke.
- Explicit **Restore / Keep for later / Discard** chooser. Restoration creates unsaved copies, never overwrites newer source files. Original journals remain protected until a durable replacement checkpoint and explicit disposition.
- Preserves canonical sharing, groups/tabs, active views, directed Unicode selections, excerpt bounds, horizontal and logical vertical scrolling, BOM/newline metadata. Current groups are equal-width horizontal groups, not arbitrary split trees.
- Clean resolution flushes/closes asynchronously using application holds. Failures retain journals. Empty never-published sessions are handled separately from corrupt journals without deleting unknown contents.
- **Caps: 4 MiB/document, 8 MiB total text, 12 MiB manifest.** Exceeding a cap visibly rejects the entire checkpoint and retains any previous durable checkpoint; do not assume smaller documents have been newly protected while any open document exceeds the cap. Save important work explicitly. Recovery is not a backup service.

### Process and terminal foundations

`src/tasks/process.zig` copies argv/cwd/explicit environment, requires authorization, bounds combined output/time, and completes exactly once on the originating context. A private supervisor/subreaper owns the process group; TERM → 150 ms grace → KILL, then reaping, applies on cancellation, timeout, output limit, owner shutdown and leader exit. Typed workspace tokens let consumers discard stale results without skipping cleanup.

`src/terminal/pty.zig` provides PTY read/write/resize/cancel/wait. The optional VTE spike validates an actual renderer and foreign-PTY integration. Neither is a production task runner or terminal dock. Linux x86_64, glibc >=2.34 and kernel >=5.9 are the current transport implementation target. Process-group ownership is **not containment** of processes escaping into other groups/sessions; interactive job-control containment remains M5 work.

### Measured presentation policy

The policy is visible rather than silently presenting stalled full-feature editing:

- Language processing and automatic spelling are reduced at **524,288 GTK characters**, or for a logical line over **16 KiB**. The character threshold is not a byte threshold. The older >10 MiB load warning remains separate.
- Giant-line views show a notice and character-offset control to open an initially **2,048-character** editable excerpt. The hidden full view is parked on an empty widget buffer so it cannot continue expensive paragraph layout; the real presentation/canonical buffers remain intact.
- Whole sources beyond the **16 MiB checked-edit limit** disable that excerpt action with a specific explanation rather than offering a fallback that always fails. Saving unchanged content remains available.
- Final 1 MiB retained-source fallback completed five cycles / 1,000 samples in each wrap mode. Latest operation-plus-drain edit p95: **21.474 / 22.319 ms**; no recorded dispatch over 50 ms. These are not keystroke-to-paint numbers.
- B05 grouped excerpt edit p95 **18.186 ms** misses the proposed 16 ms screen. Full 1 MiB paragraph rendering remains unsupported/guarded. See the benchmark report for complete results, failures, clocks and hashes.

## Validation completed

Historical validation commands through the multi-window increment, run separately from `subprojects/coral` (not final file-operation validation):

```sh
zig build test-m1 -Doptimize=safe -j1 --summary all
zig build test-m2-slice -Doptimize=safe -j1 --summary all
zig build test-m2-explorer -Doptimize=safe -j1 --summary all
zig build test-m2-search -Doptimize=safe -j1 --summary all
zig build test-m2-policy -Doptimize=safe -j1 --summary all
zig build test-m2-sessions -Doptimize=safe -j1 --summary all
zig build test-m2-docks -Doptimize=safe -j1 --summary all
zig build test-m2-windows -Doptimize=safe -j1 --summary all
zig build -Doptimize=safe -Dtest-hooks=false -j1 --summary all
```

**Policy-increment baseline passed**, including:

- **264 headless-root tests**; separate trust target **24 passed / 1 skipped** (foreign ownership requires root). Trust fork tests run separately from GIO worker tests. Appearance tests also passed, cached on the final headless run.
- **180 display-backed widget-root tests** (includes transitive model tests; do not add this count to headless tests as unique cases).
- **40 existing/native workflow groups**, including the new undo-during-save regression and repeated native spelling-popover focus checks.
- **14 application/group acceptance checks**, including grouped/native undo boundaries and cross-epoch saved-checkpoint safety.
- **13 recovery acceptance groups**, including SIGKILL/restart, interrupted publication/save, conflict-safe copies, locks/concurrent instances, corruption, cap errors, layout and excerpt recovery.

Earlier search-increment validation ran all four aggregate targets separately with `--cache-dir ../../.cache/coral-search-validation-zig`, including **18 workspace, 19 explorer and nine search native groups**. The normal cache contained a non-executable widget artifact; a fresh-cache rebuild passed without a source workaround. The search test file was then wired directly into the headless root and all 242 tests passed. Full-controller routing fixtures run through native search acceptance, not the standalone widget binary. Production safe build (test hooks disabled), formatting, Python compilation and whitespace checks passed. Logs: `pearl/.cache/coral-search-validation-logs/`; search measurements: `pearl/.cache/coral-search/results.json`.

Final policy-increment validation on **Zig 0.17.1** ran `test-m1`, `test-m2-slice`, `test-m2-explorer`, `test-m2-search` and `test-m2-policy` separately with `-Doptimize=safe -j1 --summary all` using default caches. All have passing results: 18 workspace, 19 explorer, nine search and 17 policy native groups. The workspace suite exposed a new directory-read-permission requirement; settings/trust walks were corrected to use `O_PATH`, unit regressions added, and workspace/policy gates rerun. Production safe build with hooks disabled, formatting, Python compilation and whitespace checks passed. Logs/evidence: `pearl/.cache/coral-policy-validation-logs/` and `pearl/.cache/coral-policy/`.

Final session-increment validation on **Zig 0.17.1** ran all six aggregate gates above separately with `-Doptimize=safe -j1 --summary all`, followed by the production build with hooks disabled. All passed. The session gate executed **265 main headless tests + 18 standalone session tests**, **181 widget-root tests** and **19 native session scenarios**; trust/appearance runners were cached successes. Existing native gates passed **40 workflows, 14 group/history checks, 13 recovery groups, 18 workspace groups, 19 explorer groups, nine search groups and 17 policy groups**. Counts overlap transitively, not unique totals. Formatting, Python compilation and diff whitespace checks passed. Evidence: `pearl/.cache/coral-session-validation-logs/` and `pearl/.cache/coral-sessions/`.

Final dock-increment validation ran all seven aggregate gates separately with safe optimization and `-j1`; all passed, followed by the production build with hooks disabled (cached compilation). Fresh native checks: **27 docks, 19 sessions, 40 workflows, 14 group/history, 13 recovery, 18 workspace, 19 explorer, nine search and 17 policy**. Each applicable final gate executed **190 widget-root tests**; all four headless runners were cached on this final rerun. Focused session/layout validation executed 23 tests. Initial failing session-version fixture and keyboard/focus runs are retained, with fixes and repeatable regressions documented in the [dock guide](WORKBENCH_M2_DOCKS.md). Logs: `pearl/.cache/coral-dock-validation-logs/final-*.log`; native evidence: `pearl/.cache/coral-docks/`. These counts overlap and must not be summed as unique tests.

Final multi-window-increment validation on **Zig 0.17.1** ran all eight aggregate gates sequentially with safe optimization and `-j1`, followed by a fresh hooks-disabled production compilation; all passed. The window suite passed **27 native cases**, with no GTK warnings/criticals, panics or protocol errors. Each applicable gate freshly executed **191 widget-root tests**; all four direct headless runners were cached on the final rerun (earlier this increment: 270 main-root and seven appearance tests executed). Existing native suites passed **40 workflows, 14 group/history, 13 recovery, 18 workspace, 19 explorer, nine search, 17 policy, 19 sessions and 27 docks**. Counts overlap, not unique totals. Evidence: `pearl/.cache/coral-windows/results.json` and `pearl/.cache/coral-window-validation-logs/final-*.log`; earlier failures remain retained. See the [window guide](WORKBENCH_M2_WINDOWS.md) for fixture isolation and coverage limits.

### File-operation final validation

New commands from `subprojects/coral`:

```sh
zig build operations -Doptimize=safe -j1 --summary all
zig build test-m2-operations -Doptimize=safe -j1 --summary all
```

**All nine aggregate gates passed sequentially** with `-Doptimize=safe -j1 --summary all`, each with a **600,000 ms (600-second) timeout**: `test-m2-operations`, `test-m2-windows`, `test-m1`, `test-m2-slice`, `test-m2-explorer`, `test-m2-search`, `test-m2-policy`, `test-m2-sessions` and `test-m2-docks`. The final native results were **25/25 operations together, 27 windows, 40 M1 workflows, 14 group/history, 13 recovery, 18 workspace, 19 explorer, nine search, 17 policy, 19 sessions and 27 docks**. Each of the **eight widget-including gates executed 191 widget-root tests**; the workspace slice does not include widgets. All **four headless runners were cached** on this final rerun. No final regressions, timeouts or leaked test-session processes were reported.

Earlier fresh validation passed **305 main-root tests**, including **23 operation-backend tests and manager tests**. Focused backend validation also passed those 23 tests. The initial full **22-scenario native suite** and **three additional alias-review scenarios separately** passed before the final all-25 run. Backend/headless/transitive and repeated gate counts overlap; do not add them as unique totals.

The subsequent `zig build -Doptimize=safe -Dtest-hooks=false -j1 --summary all` passed **46/46 steps**, including a **fresh 25-second executable compilation**; dependency steps remained cached/reused. Earlier failures are retained: the `full-2` delay overflow, command-fixture list/count and headless missing-appearance-dependency build errors were fixed; review-found physical-alias protection issues were fixed and their native regressions are included in the final suite.

Proof: [operations results](../../../.cache/coral-operations/results.json), [final summary](../../../.cache/coral-operations-validation-logs/final-summary.log), [per-target gate logs](../../../.cache/coral-operations-validation-logs/) (`final-<target>.log`), [fresh production build](../../../.cache/coral-operations-validation-logs/final-build.log) and [process cleanup check](../../../.cache/coral-operations-validation-logs/final-process-check.log). See the [operations guide](WORKBENCH_M2_OPERATIONS.md#final-validation--2026-11-09) for individual gate links and coverage limits. This historical evidence passes the bounded file-operation increment; full M2 closure adds the project/root suites and composed audit below.

### Full M2 validation checkpoint

**Historical M2 feature-closure checkpoint: implementation and final consolidated acceptance COMPLETE.** This is not the newer visual or M3 aggregate result. Earlier focused evidence: [25/25 projects](../../../.cache/coral-projects-25-verified/results.json), [18/18 roots](../../../.cache/coral-roots/results.json), fresh **325 main-root tests** (includes 16 roots tests and two new startup-claim tests; earlier parent checkpoint was 323), and **35 separate project-backend tests** at the reported parent checkpoint. Counts overlap transitively and must not be summed as unique tests.

All [nine prior aggregate gates](../../../.cache/coral-m2-regressions/gate-summary.json) passed on rerun, with **198 widgets** in each widget-including gate. The sessions attempt first passed 19 native cases but hit the unchanged internal 60-second widget timeout at 101/198; the identical retry passed. Both attempts are retained. This is not a no-timeout campaign, and historical 191-widget/305-core operation-increment counts above remain historical.

Final **`test-m2` passed all 84 build steps**, exit 0, in **21m24s** within a 30-minute command bound. It includes the prior nine gates plus projects/roots, deduplicating shared dependencies: **325 main-root tests freshly passed**, four other headless runners cached (including project units), **198 widget tests ran once**, and **271 native check groups across 13 harnesses ran once**. Native counts: 40 workflows, 14 groups, 13 recovery, 18 workspace, 19 explorer, nine search, 17 policy, 19 sessions, 27 docks, 27 windows, 25 operations, 25 projects and 18 roots. The subsequent hooks-disabled production build passed **46/46 steps**, exit 0, with a fresh **23.6-second** compilation. No final-run retry or threshold change was needed; no attributable processes or temporary directories remained. Four pre-existing private-session directories were recorded and preserved.

Evidence: [complete aggregate log](../../../.cache/coral-m2-final/test-m2.log), [production log](../../../.cache/coral-m2-final/production.log), [validation/cleanup evidence](../../../.cache/coral-m2-final/validation-evidence.json) and [binary hashes](../../../.cache/coral-m2-final/SHA256SUMS). The [acceptance report](WORKBENCH_M2_ACCEPTANCE.md#final-validation-passed) records coverage boundaries and cache distinctions. This completes bounded M2 acceptance, not later IDE milestones.

The generic `-Dnative-python` option accepts a Python interpreter or validation-only launcher. This ICU79 host's older `/usr/lib/libxml2.so.16` requires ICU78; validation uses actual cached ICU 78.3-2 libraries privately under `pearl/.cache/coral-m2-runtime/lib`, with its cache-only launcher retaining private-session isolation. No host packages, global libraries or hardcoded production dependencies were changed. See [exact provenance and commands](WORKBENCH_M2_ACCEPTANCE.md#this-hosts-private-icu78-recovery).

### Earlier evidence and environment

Earlier foundation validation: **40 prototype browser checks / 55 geometry checkpoints**; optional GTK4 VTE fixture **four native scenarios**; final B05 and 1 MiB fallback benchmark run **three trials / zero trial failures**. Timing budget misses are reported separately from trial completion.

Current M2-completion toolchain: Zig 0.17.1 (earlier foundation used 0.17.0), GTK 4.24.1, GtkSourceView 5.22.0, Enchant 2.8.21. Evidence lives under `pearl/.cache/coral-native`, `coral-app-groups`, `coral-app-recovery`, `coral-widgets`, `coral-terminal-spike`, and `coral-benchmarks/run-ldrbm59w`. Prototype review artifacts live beside the interactive mockup. Older failing benchmark and native reports remain historical evidence, not current successes.

All native tests use private Wayland/XDG sessions and disposable files, not the live desktop. `--aqueous-prefix /usr` selects this host's installed test tooling; other setups can use the prepared private prefix. At these historical pre-M3 checkpoints, no service credentials, paid API calls, language servers, extension downloads or host VTE installation were configured. M3 separately tests an explicitly started pinned local ZLS. No commits were created.

## Remaining roadmap

- **M0:** accepted bounded-foundation tradeoffs; unsupported full giant-line rendering and deferred paint qualification remain documented, not passed.
- **M1:** implemented/tested bounded foundation; retain the documented undo, recovery, file-size and process-ownership limits.
- **M2:** implementation **COMPLETE** for the bounded workspace preview, including automatic projects/startup, recent/buffer pickers and reviewed root management. All mandatory feature scope is accounted for and the complete acceptance/production gates passed, as recorded above. Both 100k explorer and on-demand search fixtures are validated; no persistent index or full IDE parity is claimed.
- **M3:** bounded language intelligence **implemented and validated: COMPLETE**. Existing document/workspace/trust contracts and accepted M0 engine limits remain in force; the guide records deferred capabilities rather than claiming full LSP parity.
- **Next: M4 Git and review engine — not started.**
- **M4–M8:** real Git workbench, production terminal/tasks, native/ACP agents, MCP, DAP/test UI, extensions and advanced editing/accessibility qualification, including interactive snippets in M8.
- **M9:** removed, not silently reintroduced.
