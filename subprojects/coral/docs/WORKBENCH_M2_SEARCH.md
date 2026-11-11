# M2: Quick Open and workspace search

**Implemented native increment; M2 implementation is now COMPLETE for the bounded workspace preview, with M4 Git/review next, not started.** See the [acceptance audit](WORKBENCH_M2_ACCEPTANCE.md). This builds on the [workspace/explorer model](WORKBENCH_M2_WORKSPACES.md). No language server, external search command, agent, network service or trust promotion is involved.

## Usage

Open a folder or workspace first, then use:

| Action | Shortcut / behavior |
| --- | --- |
| Quick Open | **Ctrl+P**; fuzzy filename/path matching across available roots |
| Search workspace | **Ctrl+Shift+F**; literal, case-insensitive text matching |
| Choose result | Up/Down skip group headers; Enter activates |
| Dismiss | Escape; cancels outstanding work and restores editor focus |
| Refresh | Explicitly rerun the current query against current files/buffers |

Both commands are also in the menu/command palette. Results use recycled GTK list rows, with root-qualified identities; text matches are grouped by root and file. Opening a result uses the captured active editor group. Quick Open closes after successful activation; text search remains available beside the editor workflow. Quick Open now uses an in-window overlay and text Search uses a movable dock. They share one query/result controller; switching modes replaces results rather than starting a second independent search. See [dock/picker controls](WORKBENCH_M2_DOCKS.md).

Quick Open ranks subsequence matches, preferring consecutive matches, boundaries, basename matches and shorter paths. It retains the best **128 evaluated candidates**, not an unlimited project index. Empty Quick Open queries are allowed. Text queries must be nonempty; matches are nonoverlapping. Both modes use Unicode simple lowercase, **not** normalization, full case folding, regex or locale-specific tailoring.

Text navigation uses GTK Unicode-character coordinates and verifies the match in the loaded document. It supports LF, CRLF, lone CR and Unicode paragraph separators without interpreting byte offsets as character positions. A changed/unavailable target is refused with Refresh feedback rather than selecting an unrelated range.

**Workspace-wide replace is not implemented.**

[Explicit workspace file operations](WORKBENCH_M2_OPERATIONS.md) target **Explorer selection**, not a Search/Quick Open result. Every kind requires worker preparation and separate review confirmation; created files are not automatically opened. After success, current Explorer is rescanned and Search/Quick Open results become **stale**: use **Refresh** to rerun the query, not an assumed automatic reindex. Opens/result activations are refused while the process-wide apply barrier is held through callback delivery; existing unaffected buffers remain editable. Mutations refuse all affected open documents, including clean documents and peer-window descendants. The guide also explains process-wide `WorkspaceBusy` for any unavailable root or lexical `..` root/manifest, even in an unrelated workspace.

## Unsaved documents

Dirty, file-backed documents inside the workspace are searched using a GTK-thread snapshot of their current text, with document IDs and revisions. The overlay replaces—not supplements—disk content. A deleted-but-dirty file can still participate if its parents are safe and current ignore/exclude policy permits it. Unnamed scratch buffers and documents outside the roots are not workspace search sources.

Oversized or over-budget overlays explicitly report omissions and **still suppress their disk versions**. There is no fallback to stale saved content. Matching does not modify documents, save files, stage Git changes or create missing paths.

Editing, closing, renaming/saving under a new path, or starting a load of a captured document invalidates the snapshot. This is deliberately conservative: edits to other captured open documents can require Refresh too. An existing loading document cannot be activated from an old search result. A pristine initial load triggered by a current result is separately routed and checked.

## Streaming, invalidation and filesystem boundaries

There is **one active search session, one latest pending query and one batch in transit**, with **150 ms query debounce**. Work runs on GTask workers, with immutable owned query/root/overlay snapshots. Superseded requests are cancelled and reaped before replacement work starts. Application holds cover worker cleanup; closing the UI never frees worker-owned storage early.

Text batches append results; fuzzy batches replace the current ranking. A result being opened owns its own target, so later batches are not lost or allowed to retarget it. Each activation has a separate serial: late successes and failures from an earlier activation cannot invalidate the latest selection.

Traversal reuses descriptor-relative paged enumeration and `.gitignore`/manifest excludes. Nested roots use deepest-root ownership to avoid duplicated paths. Symlink components and special files are not followed. Reads inspect and use the same pinned regular-file descriptor, with metadata validation before/after reads and resumed match batches. Policy/continuation changes discard prior results instead of mixing generations. Ignored overlays retain policy generations too. Errors fail visibly rather than permitting unfiltered results.

**These are snapshots, not a continuously updated recursive index.** Existing explorer watches invalidate affected queries/results, but search does not install a watch for every traversed directory. Use **Refresh for unmonitored changes**. A completed file is not pinned forever, and the workspace is not an atomic filesystem snapshot. Activation rechecks current policy and the loaded match. Hostile timestamp restoration, hard-link/bind-mount alias deduplication and remote filesystem notification guarantees are not provided.

Cancellation is cooperative around calls and bounded work. An unresponsive mount may delay completion/shutdown. The eventual editor load remains path-based; this is not an OS sandbox against concurrent namespace replacement.

## Explicit bounds and incomplete results

The status distinguishes searching/partial, complete, incomplete, stale, cancelled and failed. Reasons such as `result_limit`, `depth_limit`, `file_too_large` and `overlay_too_large` are displayed. Unavailable roots prevent a whole-workspace completeness claim. Stale/failed results are discarded; Refresh starts a new snapshot.

| Resource | Native/default limit |
| --- | ---: |
| Query / relative path bytes | 1,024 / 4,095 |
| Roots / recursion depth | 32 / 64 |
| Traversal records / page-policy probes | 1,000,000 / 16,384 |
| Retained traversal/path storage | 8 MiB |
| Backend live requested allocations | 64 MiB, excluding caller inputs/allocator metadata |
| Batch storage / results per batch | 1 MiB / 128 |
| Native text results / fuzzy candidates | 1,024 / 128 |
| Individual file / total searched source bytes | 1 MiB / 256 MiB |
| Query work / policy work | 256 Mi / 1 Gi charged steps |
| Ignore-policy payload | 64 MiB |
| Captured document identities / path metadata | 4,096 / 1 MiB |
| Retained dirty-buffer text | 4 MiB total, 1 MiB per buffer |
| GTK buffer extraction attempts | At most 128 |

The backend's standalone text-result default is 4,096; the native controller lowers it to 1,024. GTK extraction also bounds inspected text; a single temporary UTF-8 extraction can use up to 4 MiB before the stricter retained-byte check. Omitted overlays use bounded metadata rather than copying large text.

Each backend turn processes at most one browser page, 1 MiB source bytes plus an EOF probe, 1 Mi charged query steps and 128 results, with separately bounded policy calls. Cancellation is polled during reads and charged matching work. Insufficient budget headroom can stop conservatively before the exact ceiling. These are work/allocation bounds, not wall-clock promises. Binary/NUL and invalid UTF-8 text are skipped with reasons; Quick Open disk candidates inspect paths rather than contents.

## Implementation and tests

| Area | Files |
| --- | --- |
| Incremental traversal/matching/ranking | `src/workspace/search.zig`, `search_test.zig` |
| Pinned descriptor reads and allocation limits | `src/workspace/search_fs.zig` |
| Shared checked policy and search pages | `src/workspace/browser_fs.zig` |
| Snapshots, dispatch, activation and lifetime | `src/workspace/search_controller.zig`, `controller.zig`, `src/app.zig` |
| Virtualized picker and keyboard behavior | `src/workspace/search_view.zig`, `search_widget_test.zig` |
| Commands | `src/workbench/commands.zig` |
| Private native acceptance | `tests/search.py` |

From `subprojects/coral`:

```sh
zig build test-m2-search -Doptimize=safe -j1 --summary all
# Native harness alone:
zig build search -Doptimize=safe -j1
```

`test-m2-search` runs headless regressions, standalone widget tests and the private native harness. The three full-controller routing fixtures execute through the instrumented native application, not the standalone widget binary. Normal builds omit the test hooks.

### Validation, 2026-11-09

- All **242 headless-root tests** passed after wiring `search_test.zig` directly into `src/tests.zig`; the separate appearance suite also passed (cached on that final run).
- **160 widget tests** passed, including the search keyboard/group-header and virtualization checks.
- **Nine native search groups** passed: routing; keyboard/root identity/Unicode; overlays; policy/staleness; limits; 100k traversal; overlapping activation; cancellation/close; shutdown.
- Existing M1: **40 native workflows, 14 group/history checks, 13 recovery groups**. Existing M2: **18 workspace groups, 19 explorer groups**.
- Production safe build with test hooks disabled, Zig formatting, Python compilation and whitespace checks passed.

Final regression runs used `--cache-dir ../../.cache/coral-search-validation-zig`: an ordinary-cache widget artifact was not a valid executable, so validation rebuilt into a fresh cache. No source workaround was applied for that artifact failure. Initial native validation also exposed an overflowing test-delay conversion; both instrumented delay hooks were widened before multiplication and all native checks reran successfully.

### Actual 100k fixture

The fixture contains **100,000 nonempty files across 100 directories**. Quick Open and text queries each returned exactly one expected result with complete status. Text progress counted **100,000 read files / 2,699,991 source bytes**; traversal counted 100,302 records and 1,604 page/policy probes. This validates real recursive search, not merely synthetic result rows or explorer paging.

Latest local evidence:

| Measurement | Result |
| --- | ---: |
| Observed Quick Open completion interval after query acknowledgement | 0.32 s |
| Observed text completion interval after query acknowledgement | 0.57 s |
| Dedicated traversal input-ack samples / maximum | 11 / 25.33 ms |
| Real editor typing acknowledgement during traversal | 92.80 ms |
| Sampled RSS baseline / peak during traversal | 126,607,360 / 126,660,608 bytes |
| Peak search row widgets | 205 |
| Cancel / Escape / close-workspace acknowledgements | 35.55 / 115.97 / 35.62 ms |

The files were freshly created and cached locally; timings are not cold-disk or general-project performance guarantees. Completion intervals include harness observation and exclude time before the query acknowledgement. RSS samples are not allocator high-water measurements. Input acknowledgements include harness overhead and **are not paint/frame latency**. Two read-only probes elsewhere in the suite needed a retry and took about 276 ms; the under-250-ms gate applies to the dedicated traversal/cancellation samples, not every suite command.

Evidence: `pearl/.cache/coral-search/results.json` and adjacent screenshots/session logs. Regression logs: `pearl/.cache/coral-search-validation-logs/`. All fixtures use private Wayland/XDG sessions and disposable files. No commits, external service credentials, packages or live-desktop changes were required.

## M2 closure and remaining boundaries

[Safe settings precedence/provenance and persistent machine-owned trust](WORKBENCH_M2_POLICY.md), [explicit sessions](WORKBENCH_M2_SESSIONS.md), [native docks/picker integration](WORKBENCH_M2_DOCKS.md), [multi-window lifecycle](WORKBENCH_M2_WINDOWS.md) and [bounded explicit file operations](WORKBENCH_M2_OPERATIONS.md) are delivered. Search and dirty-buffer overlays belong to their window, not to peer windows; file-operation admission checks affected documents process-wide. [Final file-operation validation](WORKBENCH_M2_OPERATIONS.md#final-validation--2026-11-09) passed all 25 native scenarios together, all nine aggregate gates and a fresh hooks-disabled production build. The search gate again passed nine native groups and executed 191 widget tests; the search measurements above remain historical. [Automatic projects, native recents/buffer pickers and reviewed root management](WORKBENCH_M2_PROJECTS.md) now close mandatory M2 scope. **Ctrl+Alt+P** opens Recent Projects; **Ctrl+Shift+O** opens this window's buffer/view picker, distinct from workspace Quick Open. The [acceptance audit](WORKBENCH_M2_ACCEPTANCE.md) maps W07 colliding-root navigation and rich restoration separately from existing search/workspace pending-operation races. Persistent indexing is not supplied by this on-demand scanner. M3 now implements bounded language services and detected-language automatic startup, separately from search; its baseline validation is historical and [automatic-increment validation is separately accepted](WORKBENCH_M3_LANGUAGE.md#automatic-increment-validation--accepted). M4 Git/review is next, not started; agents remain later milestones.
