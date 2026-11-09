# M2: native workspaces and bounded explorer

**Status: workspace, explorer, search, safe settings, persistent trust and explicit saved-session increments implemented and tested; M2 remains in progress.** The user accepted M0's documented bounded-editor tradeoffs. See the [search guide](WORKBENCH_M2_SEARCH.md), [settings/trust guide](WORKBENCH_M2_POLICY.md) and [session guide](WORKBENCH_M2_SESSIONS.md). Automatic/per-project session history, docking and multi-window support remain future work.

## Open a workspace

Use **Open Folder…** or **Open Workspace…** from the editor menu or **Ctrl+Shift+P** command palette. Cancel leaves the current workspace intact.

```sh
coral --folder /path/to/project
coral --workspace /path/to/project.coral-workspace
coral --workspace ./project.coral-workspace ./notes.txt
```

Explicit workspace paths can be relative to the working directory. If several `--folder` / `--workspace` options are supplied, the last one wins. Bare file arguments retain their existing meaning: a bare directory is not implicitly opened as a workspace. Opening a missing path never creates files or directories.

### Manifest format

```json
{
  "version": 1,
  "roots": [
    { "name": "Frontend", "path": "./frontend" },
    { "name": "Backend", "path": "./backend" }
  ],
  "exclude": ["build/", "**/*.tmp"],
  "settings": {}
}
```

- `version` must be the integer `1`; `roots` is required and may contain zero to 32 roots.
- `name` is optional. Names are display labels, not identities; identical names are supported.
- Root paths resolve against the **supplied manifest path's parent**, not the process working directory. Symlinked manifests retain that lexical parent for relative roots; symlink/`..` semantics are not flattened before filesystem resolution.
- Available roots receive canonical directory paths and process-local typed `RootId`s. Canonical aliases deduplicate, preserving the first declaration's name. File ownership in nested roots uses the longest canonical component prefix.
- Missing/non-directory roots remain visible and are never recreated. Covered parent watches detect disappearance/return; **Rescan** provides an explicit fallback. Permission/I/O-denied roots reject the candidate if their folder settings cannot be safely inspected.
- Optional `exclude` contains at most **128 root-relative patterns, 1,024 bytes each**. These final hides apply after `.gitignore`; negation is not accepted in `exclude`.
- Optional `settings` accepts safe `lines`, `wrap`, `spaces`, `indent` and `languages` overrides. Root-local `.coral/settings.json` supplies folder overrides. Unknown/executable settings remain rejected even when trusted; repository values never enter user `preferences.ini`. See [schema and precedence](WORKBENCH_M2_POLICY.md).
- Unknown/duplicate fields (including escaped spellings), explicit null optionals, unsupported versions, invalid UTF-8/NUL and trailing JSON documents fail closed.
- Other limits: **1 MiB JSON**, **4,095-byte native paths**, **256-byte explicit root names**.

The manifest is opened read-only and nonblocking and must be a regular file. FIFOs/devices/directories are rejected. This does not make arbitrary mount I/O interruptible or provide universal atomic snapshots during concurrent writes.

## Native explorer

A virtualized **GtkListView** above the editor groups renders a bounded expandable tree with recycled row widgets:

- **Roots** returns to the root list; **Back** moves toward the parent/root list.
- Activate a root/directory to expand or collapse it. Only accessed directories are enumerated, on workers; opening a workspace does not enumerate unopened descendants.
- Activate a regular file to open it in the canonical document registry.
- **Load more** replaces the directory's current **256-entry page window**. It does not accumulate all names or widgets in memory.
- **Rescan** refreshes content and rereads manifest/folder settings, including folder-only workspaces and when monitoring is unavailable. Invalidated directory continuations discard old pages and restart from the beginning.
- **Reset tree** releases cached directory state while preserving root identities and documents. It cannot bypass a pending policy error.
- **Close workspace** removes the model/explorer, **not open tabs or dirty text**.

Root-qualified labels/tooltips distinguish identical names across roots. Switching workspaces preserves document IDs, revisions, paths and edits. Expanded/selected paths survive paging, refresh, collapse/reexpand and reopening the same workspace; replacement root identities do not inherit unrelated state.

### Paging and memory bounds

| Resource | Bound |
| --- | ---: |
| Directory states, including roots | 64 |
| Visible entries per directory page | 256 |
| Resident pages | 8 |
| Resident page arena bytes | 1 MiB |
| Directory records processed per scan call | 4,096 |

Pages sort directories, files and blocked entries, then names bytewise **within each page**, not globally across the directory. Linux directory cookies continue without rescanning earlier pages; they are not persistent bookmarks. Generation checks cover directory/ancestor metadata, ignore contents and excludes before and after enumeration. A changed generation requires restarting, not appending a new snapshot to old rows.

An incomplete page can be empty when many records are ignored or the shared matching budget is exhausted. **Load more remains available**; an unfinished candidate is retried rather than skipped. Capacity feedback and Reset tree make bounded state explicit. This is not recursive indexing or an unlimited in-memory project tree.

## Ignore and exclude policy

`.git` is always hidden. Root and nested `.gitignore` files support later-rule precedence, negation, parent-directory pruning, anchoring, directory-only rules, escaped comments/spaces, wildcards, globstars, brackets and POSIX character classes. Ignored parent directories must be re-included before their children can be reached. Explicit manifest excludes are final root-relative hides.

This is a bounded Git-style matcher, not full repository/config/global-ignore integration. Ignore read/parse/budget failures are visible and **fail closed**, never silently exposing unfiltered results.

Limits include 64 KiB per ignore file, 256 KiB rule/source storage, 2,048 rules and traversal depth 128. Each page has a shared **8,388,608-step** enumeration matching budget; both ancestor validation walks share a separate budget of that size, at most **512 KiB** ignore payload and **258** ignore probes. A single path also has an 8,388,608-step ceiling. Cancellation is checked every 4,096 charged steps and around parse/read work. Single-path or ancestor policy exhaustion fails visibly; page-budget exhaustion yields a resumable prefix.

## Batched live updates

Linux inotify covers roots, relevant ancestors, accessed directories and traversed ignore-policy ancestors—not every descendant. Manifest monitoring tracks lexical paths, intermediate symlinks, resolved targets and replacement locations. Create/delete/rename, ignore edits, manifest changes, unavailable-root return and queue overflow invalidate affected snapshots. Dirty documents remain unchanged.

Registration, symlink resolution, notification reads and descriptor retirement run on **one additional watch worker per controller**, not the GTK thread. GTK submits bounded plans and consumes generation-tagged mailboxes on a 25 ms pump; this is not filesystem polling. Ordinary content changes do not rebuild registrations. Structural/policy changes coalesce with **100 ms debounce / 500 ms maximum until eligible**, plus actual worker latency.

| Watch resource | Bound |
| --- | ---: |
| Active worker / replaceable queued plan | 1 / 1 |
| Subscriptions per snapshot | 128 |
| Inotify handles during handoff | 2 |
| Transient kernel watches | 256 |
| Strings per plan/snapshot | 128 KiB |
| Concurrent watch string capacity | 640 KiB, plus bounded scratch/metadata |
| Notification read per worker turn | 32 KiB |

Initial manifest loading is staged: unpublished candidate → watch installation → fresh read → notification drain barrier → publication. **Only EAGAIN confirms a drained queue**; short positive reads and EINTR leave the barrier pending. EOF/hard errors report monitor failure separately. Continuous traffic can delay publication until the queue drains.

Registration failures/capacity limits show a manual **Rescan** fallback. Notifications are not guaranteed on all remote filesystems. Blocking filesystem calls cannot be forcibly interrupted; shutdown can wait for the worker's hold to be released. No periodic recursive scans are used.

## Workspace trust boundary

Workspaces default to **restricted**. JSON/repository contents cannot grant trust. A separate machine-owned policy controller now provides [explicit persistent approval and revocation](WORKBENCH_M2_POLICY.md), with exact root/policy identities and generation-checked permits. Trust is not per-tool approval and launches no tasks, language servers, hooks, agents or terminals. Explicit editing/saves remain available without trust. No new create/rename/delete/move operations are provided by the explorer.

Browser traversal opens directory components descriptor-relatively without following symlinks. Traversal-only ancestors use `O_PATH`, supporting readable projects beneath search-only ancestors. Symlinks, special/inaccessible entries and unsupported filename encodings are disabled. File activation revalidates the selected root/path and regular-file type on a worker.

**This is not an OS sandbox:** the subsequent document loader remains path-based, so concurrent namespace replacement can race preliminary explorer validation. Future executable/destructive operations must not treat that check as authorization. Manually opened files retain existing canonical symlink semantics.

## Async ownership and request bounds

`controller.zig` owns model/request generations, explorer epochs and work records. Workers own inputs/cancellables and hold the application until completion. Replaced/closed models and superseded navigation cannot accept stale results. Model identity is separate from App's document lifecycle, so changing roots does not retarget document loads.

Admission checks precede generation changes, cancellation, work allocation and holds:

- **Eight pending load/scan/file/chooser operations**, including at most one chooser; the single watch worker is additional.
- **128 KiB retained request-path bytes**, including root paths and NUL terminators.
- **64 KiB individual input limit** at admission; decoded native paths have the stricter limits above.
- Identical pending opens deduplicate by path, root/model identity and document scope.
- Rejected user requests display feedback without invalidating accepted work; retry after work finishes.
- Canceled operations retain slots, bytes and holds until reaped; worker-owned descriptors/storage are not freed underneath them.

## Recovery boundary

M1 recovery protects documents, groups, excerpts and selection/scroll under its existing limits. **It does not persist workspace roots or manifest identity.** Reopen the manifest explicitly after recovery. No trust decision is inferred from recovered text.

The separate **Save Workspace Session / Restore Workspace Session** palette commands now persist one explicit checkpoint of workspace source/roots, tabs, groups, excerpts and view state. Verified clean files rebind; dirty/conflicting/unavailable files become unsaved copies. Existing documents are preserved. Missing roots remain unavailable; missing manifests abort restore with saved-root diagnostics rather than creating a fallback manifest. Trust is revalidated separately. See [session behavior and validation](WORKBENCH_M2_SESSIONS.md).

Model replacement does not create separate per-workspace tab sets. There is no automatic startup resume or quit-time session save; explicit checkpoints survive later Discard. Multiple windows and automatic/per-project session management remain future work.

## Source and validation

| Area | Implementation |
| --- | --- |
| Schema/model | `src/workspace/manifest.zig`, `manifest_fs.zig`, `model.zig` and tests |
| Paged descriptor-relative reads | `src/workspace/browser_fs.zig`, `browser_fs_test.zig` |
| Bounded ignore matching/loading | `src/workspace/ignore.zig`, `ignore_fs.zig`, `ignore_test.zig` |
| Virtualized tree and worker/controller | `src/workspace/explorer.zig`, `controller.zig`, `src/app.zig` |
| Batched watch worker | `src/workspace/explorer_watch.zig` |
| Widget regressions | `src/workspace/explorer_widget_test.zig`, `src/widget_tests.zig` |
| Native acceptance | `tests/workspaces.py`, `tests/explorer.py` |

Run separately from `subprojects/coral` (allow several minutes per target):

```sh
zig build test-m1 -Doptimize=safe -j1 --summary all
zig build test-m2-slice -Doptimize=safe -j1 --summary all
zig build test-m2-explorer -Doptimize=safe -j1 --summary all
zig build -Doptimize=safe -Dtest-hooks=false
```

`test-m2-slice` includes headless tests and workspace compatibility acceptance. `test-m2-explorer` includes headless/widget tests and native explorer acceptance. `workspaces` and `explorer` run the respective native harness alone. Private Wayland/XDG sessions use disposable fixtures; `-- --aqueous-prefix /usr` selects this host's installed test tooling.

### Explorer-increment validation, 2026-11-09

All three targets passed separately: **158 widget-root tests, 40 native workflow groups, 14 group/history checks, 13 recovery groups, 18 workspace groups and 19 explorer groups**. Headless unit/appearance steps were cached successes on the final rerun. Production safe build, Zig formatting, Python compilation and diff whitespace checks passed.

The initial combined invocation exceeded its 240-second tool timeout. Separate cached-build runs took about **135 / 35 / 74 seconds** (244 seconds total), with no reproduced deadlock. Only attributable orphan private-session processes were terminated; interrupted evidence was preserved.

Explorer acceptance covers exact-once paging, real typing/dirty preservation, inherited ignores/excludes, empty incomplete pages, generation resets without monitor delivery, expansion state, live edits/policy errors, missing roots returning, coalesced storms, overflow/failure fallback, initial read/watch races, symlink retargeting, delayed registrations and cancellation/shutdown ownership. Widget tests additionally cover real short inotify reads, EINTR/error/EOF and stopping with an undrained queue.

| Local 100k explorer measurement | Result |
| --- | ---: |
| Flat files / additional nested fixture files | 100,000 / 11,002 |
| Pages to visit all flat names exactly once | 391 |
| Paging elapsed | 10.12 s |
| Baseline / peak process RSS | 66,555,904 / 68,534,272 bytes |
| Peak recycled row widgets | 205 |
| Resident page bytes in measured flat traversal | 9,264 |
| Maximum input acknowledgement | 66.26 ms |
| Maximum main-loop probe gap | 26.06 ms |
| Close/cancel UI acknowledgement | 65.51 ms |
| Content storm scans / watch-storm builds | 2 / 2 |

These are local fixture measurements, **not keystroke-to-paint latency**. The input harness includes waits. They qualify bounded explorer browsing on 100k files, not recursive indexing/search or all of M2. A fixture with a missing root can show a watch-fallback status; this does not demonstrate all subscriptions active.

Evidence: `pearl/.cache/coral-explorer/results.json`, `100k-paged.png` and adjacent session logs; compatibility/M1 outputs under `pearl/.cache/coral-{workspaces,widgets,native,app-groups,app-recovery}/`. No host package installation, live-desktop mutation, paid service or commit was required.

## Next M2 increments

Quick Open and streaming workspace search with unsaved overlays are now [implemented and validated on 100k nonempty files](WORKBENCH_M2_SEARCH.md). This is on-demand traversal, not a persistent index.

Safe settings precedence/provenance and machine-owned trust approval/revocation are now [implemented](WORKBENCH_M2_POLICY.md), without executable features.

Versioned **explicit workspace sessions** are now [implemented and validated](WORKBENCH_M2_SESSIONS.md), including missing-root/conflict handling and restoration of tabs/layout without recreating paths. Automatic/per-project management and missing-manifest fallback are not implemented.

Next: workbench docking/pickers, multi-window lifecycle and separately authorized filesystem operations.

M2 remains **in progress**.
