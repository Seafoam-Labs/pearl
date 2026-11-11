# M2: automatic projects, recent sessions and workspace roots

**M2 implementation is COMPLETE for the bounded workspace preview. M4 Git/review is next, not started.** Automatic per-project/latest per-window snapshots, scratch-window persistence, ordinary multi-window startup, native Recent Projects/Open Buffers pickers and reviewed root management complete the mandatory M2 feature scope. See the [acceptance audit](WORKBENCH_M2_ACCEPTANCE.md) for evidence and its separate final validation checkpoint. This is not a full IDE or unlimited history service.

## Three separate persistence mechanisms

| Mechanism | Location under `$XDG_STATE_HOME/coral` | Meaning |
| --- | --- | --- |
| Automatic project sessions | `projects/` | Latest snapshot per durable window/project identity; recent records and startup membership |
| Explicit workspace checkpoint | `sessions/current` | One shared slot, changed only by **Save Workspace Session**; explicit restore |
| Crash recovery | `recovery/` | Per-window journals with explicit Restore / Keep for later / Discard decisions |

The default state home is `~/.local/state`. Automatic writes and Forget **never overwrite or delete `sessions/current`**. Later Discard does not erase an explicitly saved checkpoint. Recovery retains its own format, scheduling and pathless-copy policy. None of these is a backup service; save important documents separately. Stored text is private but **not encrypted**.

## Open, switch and return

- **Open Folder… / Open Workspace…** replaces the current window's workspace model, **not its documents**. Dirty text, document identities and existing tabs remain. Before publishing a different project, Coral durably checkpoints and retires the old identity from automatic startup membership. Failure keeps the old workspace and documents; it does not silently continue the switch without retention.
- Each live window has a fresh durable session ID. Folder/manifest identity is its source kind and exact supplied native path bytes, not its display name or canonical aliases. Scratch windows have independent identities too. Catalog records are ordered by monotonically increasing snapshot sequence, not wall-clock time; the first exact project match is its latest snapshot. Older retained window records can still appear.
- **Open Recent Project… — Ctrl+Alt+P** (picker title: **Recent Projects and Workspaces**) activates a matching live owner **in this process**, or restores a retained record into a **new independent window**. Matching includes the original restore source and exact folder/manifest identity. It never swaps isolated tab sets within the current window. A live owner in another process is refused rather than remotely activated: there is no cross-process window-forwarding protocol.
- Restoring creates a new ID. Atomic publication consumes the old record's startup membership while retaining its snapshot in recents. It does not overwrite the predecessor. Selecting it again while its restored owner is live activates that owner, not another clone.
- Closing a window while siblings remain retains a recent record but removes that window from startup membership. Closing the last window, or **Quit All**, retains the intended next-launch membership, subject to the explicit close choices below.

A failed/invalid source manifest is not recreated from a snapshot. Repair it and retry; saved roots are diagnostics, not a fallback manifest. Missing roots remain unavailable. Current manifests/settings are reread, and trust is revalidated separately. Restoration never implies trust. Historically M2 executed no tools; current [M3 detected-language discovery](WORKBENCH_M3_LANGUAGE.md#automatic-startup-approvals-and-persistent-stop) can automatically start servers for eligible restored file-backed documents only with independent current exact workspace trust, exact server approval and no workspace pause. New/changed keys require a first-use prompt; Stop persists a workspace pause and Start/Restart resumes with fresh checks. Pathless copies remain ineligible until saved. Language approval/pause state lives separately in `coral/language`, never in project snapshots. [Separate validation of this automatic-language increment is accepted](WORKBENCH_M3_LANGUAGE.md#automatic-increment-validation--accepted).

## Ordinary startup and precedence

Launch `coral` without file/folder/workspace arguments to restore the retained startup set, including independent scratch windows, up to the window limit. Display/theme options do not themselves constitute explicit project input.

1. Real crash-recovery decisions take precedence. Restore, Keep for later and Discard suppress prior automatic startup membership, avoiding duplicate restoration or resurrection of explicitly discarded recovery text. Recents remain retained.
2. Explicit CLI file/folder/workspace inputs also suppress prior startup membership and apply to the first window, rather than being displaced by automatic sessions. Recovery decisions remain explicit if offered.
3. With neither, ordinary startup restores eligible non-live records. Empty never-published recovery directories do **not** suppress it; failed/contended recovery claims do not count as a presented recovery decision.

Suppression does not delete recent snapshots or steal another live process's records. Lifetime leases and generation checks arbitrate startup claims, not a potentially stale catalog listing. The same old startup member is consumed once even when three processes read it concurrently; losing claimants report the conflict and remain usable, without restoring the source membership during cleanup. This is coordination between cooperating local processes, not an OS security sandbox.

## Restored text and layout

Automatic snapshots use the existing session model and restore verification: roots/source, ordered tabs, equal-width horizontal groups, active views, directed selections, scrolling, editable excerpts and desired Explorer/Search dock layout.

- Clean regular files rebind only after content, format and saved-etag verification.
- **Dirty, conflicting, unavailable and duplicate-bound files restore as pathless unsaved copies requiring Save As.** No original file is automatically overwritten or recreated.
- Dock layout is desired panel placement/visibility/sizes, not desktop window positions or arbitrary split trees. Compact allocations do not overwrite the desired wide layout.
- Existing documents in the invoking window stay untouched when Recent Projects creates another owner. Same-file buffers in different windows remain independent.

The [explicit session guide](WORKBENCH_M2_SESSIONS.md) details verification, rollback and missing-manifest behavior; it describes a separate explicit slot, not the automatic catalog.

## Sampling, publication and visible failures

The project controller samples on a **1-second timer**. Metadata change notifications do not capture buffers or write files. Eligible changed fingerprints are captured after **1 second of quiet or 5 seconds since the first change**, evaluated on timer ticks, plus capture/worker latency. This is a scheduling bound, **not a five-second durability guarantee**. Pending loads, restoration, retirement, close freeze, recovery decisions, session work and operation barriers can defer capture. Unchanged state does not republish.

Bounded GTK-thread capture feeds worker-owned encoding, checksumming, locking, reads and fsync. There is at most one running and one pending snapshot per window; only a pending snapshot of the **same identity** is coalesced. A retired project's final image is not replaced by the next project's edits. Worker failures impose a five-second automatic retry backoff; an unchanged failed capture is not repeatedly recaptured until its fingerprint changes or an explicit retry occurs. Recent Projects refresh also retries pending suppression/restore cleanup. Errors are visible and logged; an error does not mean the latest edits were retained.

The private `projects/` store uses a checksummed index referencing immutable checksummed session revisions. Nonblocking shared/exclusive directory locks cover whole operations. The controller retries `Busy` on the worker at 25 ms intervals, at most 40 retries (about one second plus operation time), then reports failure; it never waits for a lease indefinitely. Lifetime lease files protect live owners and restore sources. Publication syncs the snapshot, renames it, syncs the directory, then syncs and atomically replaces the index and syncs the directory again. The index rename is the commit point. Precommit failure preserves old references; `DurabilityUncertain` means commit occurred but durability is unconfirmed. Orphan snapshots are never promoted by readers.

Corrupt, future, missing referenced, unsafe or unknown data is preserved and can block mutation rather than being silently discarded. State-home ancestry must exist; Coral creates only private children, with checked no-symlink traversal, owner-private directories and owner-only regular files. Same-UID malicious interference and unresponsive mounts are not contained; blocking filesystem calls can delay shutdown.

## Graceful close, Save and Discard

The window's layout and text are **frozen before dirty-document prompts change focus**. Quit All freezes every participating owner before resolving windows sequentially. Full and excerpt views stop editing; revision/baseline guards also reject unexpected canonical changes.

- Successful Save/Save As reconciles the frozen image with the resulting clean path/etag/format baseline while retaining pre-prompt layout and selection.
- Explicit Discard excludes that document and its full/excerpt views from the new automatic close snapshot. It does not delete an older explicit checkpoint or all older retained recents.
- Cancel, save failure or rejected final-state validation keeps unresolved documents and thaws the surviving windows. Already closed windows are not reopened; Quit All is not an atomic all-window transaction.
- Documents are removed only after the accepted automatic close write finishes and final guards pass.

**Oversize or failed retention is an explicit decision, not silent data eviction.** A document over **4 MiB**, or combined text over **8 MiB**, cannot be retained in a new automatic snapshot even if normal editing/loading supports it. The dialog offers Cancel or **Close without automatic session**. This opt-out still requires normal Save/Discard for every unsaved document; it is not permission to lose dirty edits silently. Old startup membership is cleared **durably before close**, so an older automatic image is not silently resurrected on next ordinary launch. Failure to clear it keeps the window open. Existing recent records and explicit checkpoints are not deleted by this option.

## Catalog and picker bounds

| Resource | Limit / behavior |
| --- | --- |
| Retained automatic records | **64**; no silent eviction, including dirty snapshots |
| Startup members | **16**; distinct from the process's 16 live/draining-window admission limit |
| Store byte budget | **256 MiB**, including old/new publication headroom and index reserves |
| Index / lease files | **1 MiB** index; at most **80** leases |
| Snapshot | Session limits: 128 documents, 64 groups, 256 views, 4 MiB/document, 8 MiB text, 12 MiB recovery payload plus bounded descriptor/header |
| Generic native picker snapshot | **512 items**, at most **50 displayed matches** |

**Open Buffers… — Ctrl+Shift+O** lists this window's full/excerpt views with dirty state and group/path qualifiers. Selection targets a view identity, not a basename; duplicate names and multiple views cannot silently select a different document. It is not a filesystem picker or cross-window buffer list.

Recent Projects, Open Buffers and Forget use native snapshot filtering, Up/Down, Enter and Escape, also reachable through menu/palette commands. Filtering is over the captured labels/details, not live history discovery. When more than 50 match, refine the filter. There is **no pagination or guarantee that every older identically labelled record is individually addressable through this bounded prefix**; do not interpret the storage capacity or the test controller's exact-ID selection as unlimited UI history access.

**Forget Recent Session…** opens a separate irreversible confirmation. It removes only that retained automatic record, not files or explicit checkpoints. Live records cannot be forgotten, including owners in another process. Generation comparison and removal happen atomically under the directory lock with lease exclusion; a stale confirmation fails rather than deleting a newer snapshot. Physical revision reclamation follows a durable index removal, not before it. At capacity, save important work and explicitly manage retained records; Coral never silently evicts dirty history to admit a new window.

## Reviewed workspace root management

Use the menu or command palette:

1. For a folder-only workspace, **Save Workspace As…** first. Add/Remove refuses with `SaveWorkspaceFirst`; there is no implicit manifest or staged unsaved root list.
2. Choose a **new destination** with an existing parent and review the exact generated JSON. Save As refuses existing files, directories, symlinks and late collisions, rather than overwriting them.
3. **Workspace: Add Folder…** selects an **existing directory**. Review and confirm to write the active manifest immediately. It does not create the directory; available canonical aliases are refused as duplicates. The 32-root cap remains.
4. Select an Explorer root or one of its descendants, then **Workspace: Remove Selected Root…**. Review names the typed root identity; confirmation writes the active manifest immediately. The last root cannot be removed through this action, although the reader accepts zero-root manifests.

All three operations require separate review; chooser acceptance alone does not write. **Only the manifest is written: no root folders/files are deleted, and no open documents or dirty text are closed or lost.** Removed-root documents remain open, now subject to their current workspace ownership/settings.

Serialization preserves supported settings and language overrides, excludes, existing root names and remaining order **semantically**, not original JSON formatting. Paths are written as **absolute lexical spellings** so Save As into another directory preserves meaning. `.`/`..` are not blindly normalized across symlinks; unavailable-root spellings are retained. Added roots use the normal default name. There are no dedicated root-rename/reorder controls; such edits remain manual manifest editing, not a delivered UI feature.

Preparation rereads the source and compares the loaded model, policy, names and lexical paths. Apply revalidates source identity/metadata, **etag and exact source bytes**, added-directory identity and destination state. Add/Remove uses conditional GIO replacement; Save As uses a synced private temporary file and `RENAME_NOREPLACE` followed by directory fsync. An uncertain post-commit result is reported, not rolled back over newer data. This is not atomic isolation from every external namespace race.

A manifest bound as an open document blocks writes, **clean or dirty in any live/draining window**, including symlink/hard-link aliases and a binding added after preparation. Resolve and close the manifest document before retrying; ordinary source documents under a removed root need not close. Request/workspace generations reject stale review. The process-wide apply barrier prevents competing opens/saves/sessions/workspace changes/New Window and owner close through completion. Cancel drains workers/descriptors before releasing ownership. Success reloads through the watched workspace/settings pipeline and revalidates trust; it grants no execution authority.

## Source and focused validation

| Area | Source / tests |
| --- | --- |
| Automatic lifecycle and startup/close integration | `src/workspace/project_controller.zig`, `src/application.zig`, `src/main.zig`, `src/app.zig` |
| Catalog, leases and atomic publication | `src/workspace/project_fs.zig`, `project_test.zig`, `src/project_tests.zig` |
| Native snapshot pickers | `src/workbench/workspace_picker.zig`, `workspace_picker_test.zig`, `commands.zig` |
| Reviewed root management | `src/workspace/roots_controller.zig`, `roots_fs.zig`, `roots_test.zig` |
| Private native acceptance | `tests/projects.py`, `tests/roots.py` |

From `subprojects/coral`:

```sh
zig build project-unit -Doptimize=safe -j1
zig build projects -Doptimize=safe -j1
zig build roots -Doptimize=safe -j1
zig build test-m2-projects -Doptimize=safe -j1 --summary all
zig build test-m2-roots -Doptimize=safe -j1 --summary all
zig build test-m2 -Doptimize=safe -j1 --summary all
```

`project-unit` is a separate fork-safe backend runner, also included by `test`. Root backend tests are included in the main headless root. `projects`/`roots` are native harnesses; their aggregate targets include headless tests and widgets. `test-m2` composes the prior nine gates plus these two new gates, retaining M1 regressions.

Confirmed native evidence: **25/25 projects**, including the three-process startup race, at [projects results](../../../.cache/coral-projects-25-verified/results.json); **18/18 roots** at [roots results](../../../.cache/coral-roots/results.json). Tests use disposable files and private Wayland/HOME/XDG sessions, never the live desktop. See the [acceptance matrix and validation environment](WORKBENCH_M2_ACCEPTANCE.md) for exact W07 coverage, headless/regression counts and the generic `-Dnative-python` validation-launcher option.
