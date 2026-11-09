# Coral workbench implementation status

**M0 is accepted with the documented bounded-editor tradeoffs. M1 implementation and native correctness acceptance are complete. M2 is in progress: the first native multi-root workspace/browser slice is implemented and tested.**

The user explicitly accepted the M0 tradeoffs and requested work on M2. This acceptance does not turn failed or unmeasured performance targets into passing measurements. This is not a full IDE or Zed parity release. M2 is partial; M3–M8 remain future milestones; M9 remains removed. The [interactive prototype](mockups/workbench/index.html) is a design fixture, not connected to native Git, LSP or agents.

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

## M2 first slice: implemented and integrated

See [workspace usage and remaining gates](WORKBENCH_M2_WORKSPACES.md) for the schema and exact scope.

- Native **Open Folder…** and **Open Workspace…** menu/palette actions, plus explicit `--folder PATH` / `--workspace PATH` CLI options. Existing bare-directory file arguments remain rejected.
- Strict version-1 `.coral-workspace` manifests, up to 32 roots and 1 MiB of JSON. Relative roots resolve against the supplied manifest path's parent. Available canonical aliases deduplicate; colliding root names remain distinct through typed `RootId`s. Missing roots remain visible and are never created.
- Root-qualified file tabs and a lazy, nonrecursive directory browser with **Roots / Back / Rescan / Close workspace**. Lists visibly truncate at 500 direct entries. This is not the finished virtualized explorer or the 100k-file performance gate.
- Filesystem work runs on GTask workers. Request/model generations reject late results; switching/closing a workspace preserves open dirty documents. Failed manifests leave the previous workspace intact.
- Bounded admission: eight total outstanding operations including at most one workspace chooser; 128 KiB retained request-path budget; identical pending file opens deduplicate. Rejected requests do not invalidate accepted work. Canceled workers retain their slots and application holds until completion. Blocking mount I/O is still not forcibly interruptible.
- Restricted-only state; manifest settings must be omitted or empty. Executable settings and manifest-supplied trust are rejected, never executed. No trust promotion or persistent grant store is implemented yet.
- Descriptor-relative browser traversal rejects symlink components, special files and escapes. Search-only ancestor directories are supported. This is not a sandbox for the subsequent path-based document loader against concurrent rename races.
- Recovery still restores documents/layout, **not workspace roots/manifests**; the UI says so. Ordinary project-session restoration remains an M2 gate.

**Fresh validation:** `zig build test-m2-slice test-m1 -Doptimize=safe -j1 --summary all` passed on the final code, including the bounded-admission and traversal-permission fixes. The final workspace harness has **18 native groups**, including real two-root typing, same-basename identity, malformed/FIFO manifests, restricted no-execution, missing roots, symlink replacement, delayed-result races, request bursts/dedup/budgets, chooser lifecycle and execute-only ancestors. M1's 99 widget, 40 native, 14 group and 13 recovery checks remain passing. Workspace evidence: `pearl/.cache/coral-workspaces/`.

## M1 foundation: implemented and integrated

### Canonical documents, independent views and groups

- `src/editor/registry.zig` owns canonical documents with process-wide nonrecycled IDs. Canonical paths deduplicate opens and follow Save As.
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

Final aggregate command from `subprojects/coral`:

```sh
zig build test-m1 -Doptimize=safe -j1 --summary all
```

**Passed** on the final code, including:

- Headless unit and appearance suites.
- **99 display-backed widget-root tests** (includes transitive model tests; do not add this count to headless tests as unique cases).
- **40 existing/native workflow groups**, including the new undo-during-save regression and repeated native spelling-popover focus checks.
- **14 application/group acceptance checks**, including grouped/native undo boundaries and cross-epoch saved-checkpoint safety.
- **13 recovery acceptance groups**, including SIGKILL/restart, interrupted publication/save, conflict-safe copies, locks/concurrent instances, corruption, cap errors, layout and excerpt recovery.

Additional executed validation: production safe build, formatting/whitespace checks; **40 prototype browser checks / 55 geometry checkpoints**; optional GTK4 VTE fixture **four native scenarios**; final B05 and 1 MiB fallback benchmark run **three trials / zero trial failures**. Timing budget misses are reported separately from trial completion.

Observed toolchain: Zig 0.17.0, GTK 4.24.1, GtkSourceView 5.22.0, Enchant 2.8.21. Evidence lives under `pearl/.cache/coral-native`, `coral-app-groups`, `coral-app-recovery`, `coral-widgets`, `coral-terminal-spike`, and `coral-benchmarks/run-ldrbm59w`. Prototype review artifacts live beside the interactive mockup. Older failing benchmark and native reports remain historical evidence, not current successes.

All native tests use private Wayland/XDG sessions and disposable files, not the live desktop. `--aqueous-prefix /usr` selects this host's installed test tooling; other setups can use the prepared private prefix. No service credentials, paid API calls, language servers, extension downloads or host VTE installation were configured. No commits were created.

## Remaining roadmap

- **M0:** accepted bounded-foundation tradeoffs; unsupported full giant-line rendering and deferred paint qualification remain documented, not passed.
- **M1:** implemented/tested bounded foundation; retain the documented undo, recovery, file-size and process-ownership limits.
- **M2:** first manifest/root/browser slice delivered. Remaining: virtualized/paged explorer, ignore/exclude rules, directory watching, quick-open/workspace search, settings precedence, persistent trust approval/revocation, workspace-root session recovery, docking and multi-window UI. The 100k-file gate is still open.
- **M3–M8:** LSP, real Git workbench, production terminal/tasks, native/ACP agents, MCP, DAP/test UI, extensions and advanced editing/accessibility qualification.
- **M9:** removed, not silently reintroduced.
