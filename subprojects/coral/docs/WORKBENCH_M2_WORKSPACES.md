# M2: first native workspace slice

**Status: implemented and tested first slice, not completed M2.** The user accepted M0's documented bounded-editor tradeoffs and asked to begin M2. This slice connects a real multi-root model to the native editor; it does not claim a finished explorer, workspace search or full IDE.

## Open a workspace

Use **Open Folder…** or **Open Workspace…** from the editor menu or **Ctrl+Shift+P** command palette. The existing shared native chooser supports both workflows. Cancel leaves the current workspace intact.

From a shell:

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
  "settings": {}
}
```

- `version` must be the integer `1`; `roots` is required and may contain zero to 32 roots.
- `name` is optional. Names are display labels, not identities; identical names are supported.
- Root paths resolve against the **supplied manifest path's parent**, not the process working directory. Opening a symlinked manifest uses the parent of the supplied spelling. Symlink/`..` path semantics are not flattened before filesystem resolution.
- Available roots receive canonical directory paths and process-local typed `RootId`s. Canonical aliases deduplicate, preserving the first declaration's name. Ownership of a file in nested roots uses the longest canonical component prefix.
- Missing, inaccessible, non-directory or otherwise unavailable roots remain in the model with an explicit availability state. Coral does not recreate them. Reopen the folder/manifest to refresh that root-level availability snapshot.
- `settings` must currently be **omitted or empty**. Unsupported settings are rejected, not silently applied or ignored. Existing user `preferences.ini` remains unchanged.
- Unknown fields, duplicate fields (including escaped spellings), explicit null optionals, unsupported versions, invalid UTF-8/NUL and trailing JSON documents fail closed.
- Limits: **1 MiB JSON**, **32 roots**, **4,095-byte native paths**, **256-byte explicit root names**.

The manifest is opened read-only and nonblocking, and the opened descriptor must be a regular file before reading. FIFOs/devices/directories are rejected. This bounds allocation and avoids FIFO rendezvous; it does not make arbitrary filesystem/mount I/O interruptible or provide a universal coherent snapshot during concurrent writes.

## Native browser

The first slice mounts a bounded directory browser above the editor groups:

- **Roots** returns to the root list.
- Activating a root or directory reads only its direct children, on a worker.
- Activating a regular file opens it in the canonical document registry.
- **Back** moves to the parent directory or root list.
- **Rescan** refreshes the currently browsed directory; there is no recursive scan or directory watcher yet.
- **Close workspace** removes the root model/browser, **not open document tabs or dirty text**.

Tab and row labels include root identity/name, so `same.txt` in two roots remains distinguishable even if the root names also collide. Switching workspaces refreshes ownership labels while preserving document IDs, revisions, paths and edits. Documents outside the new roots remain open as ordinary documents.

### Bounded, not a full explorer

Each listing contains at most **500 direct entries**. Truncation is visible. The collected subset is sorted directories-first and then by name; because enumeration stops at the cap, it is **not** a globally sorted or complete listing. There is no next-page action in this slice. Use Open File for a path not included in the subset.

All entries, including dotfiles and generated directories, are presently shown subject to the cap. `.gitignore`, excludes, indexing and virtualized tree semantics are not implemented yet. A 510-entry truncation test does not qualify the roadmap's 100k-file responsiveness gate.

## Restricted workspace policy

The workspace model has only **restricted** state. It cannot become trusted through JSON or repository contents. There is no persistent approval store or trusted-mode button yet.

Opening/browsing a workspace does not launch tasks, language servers, hooks, agents or terminals. User-selected editing and explicit saves remain available. No new create/rename/delete/move operations are provided by this browser.

Browser traversal opens directory components descriptor-relatively without following symlinks. Traversal-only ancestors use `O_PATH`, so a readable project under search-only ancestors works without permission to list those ancestors. Only the final enumerated directory needs read access. Symlink entries, special files, inaccessible entries and unsupported filename encodings are visible but disabled. File activation revalidates the selected root/path and regular-file type on a worker.

**This is not an OS sandbox:** the subsequent document loader remains path-based, so concurrent namespace replacement can race the preliminary browser validation. Future executable or destructive workspace operations must not treat this preliminary check as authorization. Manually opened files retain the existing local-file semantics, including canonical symlink resolution.

## Async ownership and request bounds

`controller.zig` owns the model, request generations, browser epoch and work records. Each worker owns its inputs and cancellable and holds the application until completion. Results for replaced/closed models or superseded navigation cannot mutate the current browser. Model identity is separately owned from App's document-lifecycle identity, so changing roots does not retarget a document load.

Admission limits are checked **before** changing generations, canceling accepted work, allocating a new work record or taking a hold:

- **Eight pending operations total**, including at most one workspace chooser.
- **128 KiB retained request-path bytes**, counting root paths and NUL terminators.
- **64 KiB individual input limit** at controller admission; decoded native paths remain subject to the stricter model/path limits above.
- Identical pending file opens deduplicate using exact path, root/model identity and document scope.
- No secondary queue or automatic retry. A rejected request displays feedback; **the last accepted request wins**. Retry after pending work finishes.
- Canceled operations retain slots, bytes and holds until their callbacks finish; no storage is freed underneath a worker.

Cancellation is cooperative around filesystem calls. An unresponsive mount can delay worker completion and application shutdown, but cannot create an unbounded internal queue through repeated navigation.

## Recovery boundary

M1 recovery protects canonical documents, independent groups, excerpts and selection/scroll state under its existing limits. **It does not yet persist workspace roots or manifest identity.** The workspace UI explicitly says to reopen the manifest after recovery. No root/session restoration or persistent trust decision is inferred from recovering document text.

Root model replacement also does not create separate per-workspace tab sets: open tabs remain in the same window. Proper workspace sessions, switching/restoration and multiple windows remain later M2 work.

## Source and validation

| Area | Implementation |
| --- | --- |
| Schema/parser | `src/workspace/manifest.zig`, `manifest_test.zig` |
| Read-only filesystem/model | `manifest_fs.zig`, `model.zig`, `model_test.zig` |
| Bounded direct-directory reads | `browser_fs.zig` |
| Worker/controller/UI | `controller.zig`, `src/app.zig` |
| CLI/menu/palette | `src/main.zig`, `src/workbench/commands.zig` |
| Native acceptance | `tests/workspaces.py` |

From `subprojects/coral`:

```sh
zig build test-m2-slice test-m1 -Doptimize=safe -j1 --summary all
zig build -Doptimize=safe -Dtest-hooks=false
```

`test-m2-slice` runs the headless suite and the native workspace harness. `workspaces` runs just that native harness; pass `-- --aqueous-prefix /usr` to use the installed tooling on this host. All native tests use private Wayland/XDG sessions and disposable fixtures.

**18 native workspace groups passed**, covering:

- Two roots with colliding root names/basenames, real native typing and distinct canonical documents.
- Model switching with exact dirty-buffer preservation.
- Invalid/executable-settings/FIFO manifests retaining the previous workspace.
- Missing roots without directory creation; restricted content without process execution.
- Direct-child browsing, Back/Roots/Rescan, symlink replacement and root-escape rejection.
- Visible 500-entry truncation.
- Delayed model/scan/file completions after replacement, close and shutdown.
- Native folder/workspace choosers, cancellation, explicit relative CLI paths and last-option selection.
- Deterministic 64-request bursts, byte/slot limits, pending-file deduplication and chooser admission.
- Readable roots/files beneath execute-only ancestors, tested unprivileged with temporary permissions restored.

The full M1 suites remain passing: **99 widget tests, 40 native groups, 14 group/history checks and 13 recovery groups**, plus unit/appearance tests. Generated evidence is in `pearl/.cache/coral-workspaces/results.json` and adjacent screenshots/session logs. No host package installation, live-desktop mutation, paid service or commit was required.

## Next M2 increments

1. Paged/virtualized explorer with explicit excludes/ignore rules, batched directory watchers and cancellation/rescan behavior.
2. Bounded quick-open and streaming workspace search, including unsaved-buffer overlays and unambiguous root identity; qualify the 100k-file fixture.
3. Safe workspace/folder/language settings precedence with provenance; persistent machine-owned trust approval and revocation before executable features.
4. Versioned workspace/session persistence alongside recovery, including missing roots and conflicts; restore roots, tabs and layout without silently recreating paths.
5. Workbench docking/pickers, multi-window lifecycle and separately authorized filesystem operations.

M2 is intentionally still marked **in progress**.
