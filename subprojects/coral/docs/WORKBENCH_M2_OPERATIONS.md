# M2: explicit workspace file operations

**Implemented bounded increment; M2 implementation is now COMPLETE for the workspace preview, with M3 next.** Explorer selection now supports new file, new directory, rename, move and permanent delete through buttons, menu actions and the command palette. These are explicit local edits, available in restricted workspaces without enabling tools or granting trust. File-operation-increment final validation **passed all 25 native scenarios together, all nine then-existing aggregate gates and a fresh hooks-disabled production build**; that historical evidence is below. The [full M2 acceptance audit](WORKBENCH_M2_ACCEPTANCE.md) records subsequent project/root closure and its validation separately.

## Select → input → prepare → review → confirm

1. Open a folder/workspace and **select an Explorer entry**. Selection is the target; activating a file opens it and may therefore make it ineligible for mutation until closed.
2. Use an Explorer button, the menu, or **Ctrl+Shift+P** and an **Explorer:** command listed below. These actions have no dedicated shortcuts.
3. Enter the name/path, or read the initial permanent-delete warning, then choose **Review…**. A worker prepares and validates a snapshot. **No filesystem mutation occurs during input or preparation.**
4. Review the operation, root, source and destination. **Every kind, including both creates, requires a separate explicit Confirm**; delete uses **Delete permanently**. Cancel is the dialog default. Changed workspace/path state requires a new request, not silent retargeting.
5. After success, Explorer is rescanned when the originating workspace is still current. Search/Quick Open results are invalidated with a stale notice: use **Refresh** to rerun the query. **A created file is not automatically opened.**

| Command | Destination and behavior |
| --- | --- |
| **Explorer: New file…** | Name or relative path beneath the selected directory/root; a selected file uses its parent. Exclusively creates an empty regular file with mode `0600`, further restricted by umask. |
| **Explorer: New directory…** | Same selection-relative input; creates one directory with mode `0700`, further restricted by umask. |
| **Explorer: Rename…** | One sibling basename, not a path. Applies to a regular file or directory. |
| **Explorer: Move…** | Destination relative to the selected entry's workspace root, not its current directory. Same-root, same-filesystem rename only. |
| **Explorer: Delete permanently…** | Regular file or **empty directory only**, with an explicit permanent-deletion warning. No trash, undo or recursive deletion. The Explorer button is labelled **Delete…**. |

Destination parents must already exist; create does not make intermediate directories. Existing destinations are never overwritten, including on collision after review. Rename/move use Linux `renameat2` with `RENAME_NOREPLACE`; there is **no copy/delete fallback** for cross-filesystem moves or unsupported rename semantics. A directory can be renamed/moved without copying its contents, subject to the protections below. A destination equal to or inside the source is rejected. Workspace roots themselves cannot be renamed, moved or deleted.

These commands do not rebind open documents in place, send LSP file-operation events, stage Git changes or run hooks/tasks/agents. New document → Save As remains the separate existing editor-content creation workflow; file opens/navigation still never create missing paths.

## Paths and the on-disk snapshot

- Operation paths must be valid UTF-8 without NUL, with no empty, `.` or `..` components and no `.git` component. Absolute destination input, repeated/trailing separators, special files and symlink entries are rejected rather than normalized into a different request.
- The limit is **4,095 bytes for the full absolute path**, including the canonical root and separator—not a 4,095-byte suffix allowance. Individual filesystem component limits also apply.
- The backend walks from `/` using checked no-follow descriptors, including **every ancestor of the captured canonical root**. Symlink components in that walk, source or destination-parent chain are refused. An ancestor replaced by a symlink after canonicalization is not followed. This is stricter than ordinary manually opened files' canonical symlink semantics.
- Preparation retains source and root/parent-chain descriptors plus `statx` metadata. Retaining the actual source descriptor prevents ordinary inode reuse from impersonating the reviewed source after unlink. Before applying, the worker reopens the canonical path, compares retained descriptors/current path edges, rechecks source identity/metadata and destination absence, then issues a descriptor-relative syscall.
- Identity checks cover device/inode/type and available mount/birth-time data. Source and root/descendant directory checks also compare mode, link count, size and modification/change times. Ancestors above the root use identity checks, so unrelated directory timestamp changes there need not invalidate review.

**Best-effort containment, not a sandbox or atomic source compare-and-swap.** Another process can move a checked parent outside the root or replace the source name between the last validation and `renameat2`/`unlinkat`. Linux does not provide conditional rename/unlink of the reviewed name by retained source fd. The descriptor checks detect observed changes; they cannot eliminate those final external namespace races. Metadata is not a content hash and cannot detect every change hidden by filesystem timestamp granularity. There is **no content-hash or fsync/power-loss durability guarantee**, rollback transaction, or filesystem undo. Success means the mutation syscall succeeded, not that it is durably committed to storage.

## Process-wide document and workspace protection

Admission checks cover **all live and closing/draining windows in this process**, not just the requesting window. They run before preparation and again before acquiring the apply barrier.

- **Every affected open file-backed document blocks the operation, clean or dirty.** This includes descendants of a renamed/moved/deleted directory and affected destination paths. Resolve dirty edits by saving or explicitly discarding as appropriate, then **close every affected document in every window** and wait for callbacks to drain. Saving alone does not make an open clean document eligible. There is no implicit Save, Discard, close or path rebinding.
- Pending document loads/load decisions, file/workspace choosers, saves/save reservations, session work, recovery decisions/claims and competing dialogs prevent admission. Finish or cancel them and wait for cleanup before retrying. Draining owners still count.
- Source/destination changes may not affect open workspace roots (including peer/nested roots) or active manifests. The manager checks known lexical and canonical paths; a missing canonical manifest identity also fails closed.
- From **accepted confirmation until the apply completion callback**, one process-wide barrier prevents competing mutations, opens/reloads, saves/Save As, session save/restore, workspace switching/closing and New Window. Requests are refused rather than queued. Existing unaffected buffers remain usable for editing. Normal close/Quit All cannot dispose of an active operation; finish/cancel it and wait for worker cleanup first.

### Conservative `WorkspaceBusy` rule

**Any unavailable root, or any lexical `..` component in a root or manifest path in any open process workspace, blocks all workspace mutations—even in an otherwise unrelated root/window.** This is deliberate, not merely a check for overlap with the selected source/destination. Unavailable roots can hide physical aliases through symlinked ancestors; lexical `..` paths can depend on traversed directories that disappear from the canonical endpoint. Without a complete dependency snapshot, the manager refuses to guess.

If `WorkspaceBusy` persists after pending work drains, inspect workspaces in every window. **Close the affected workspace, or reopen it with available roots and a verified normalized/canonical spelling that names the intended location.** A manifest may need a separately verified path/root spelling. Do **not** blindly collapse lexical `..`: symlink traversal can change what that spelling means. Closing a workspace keeps its documents; affected open documents must still be resolved and closed separately. Loading/restoring such workspaces remains supported—the conservative restriction is on mutation admission, not a new session-format rejection.

This coordination is process-local. It does not lock other Coral processes, external editors or arbitrary filesystem actors, and is not a guarantee against unmodelled filesystem aliases.

## Worker ownership, cancellation and stale state

The controller owns one request at a time with captured workspace/root/request identities. Input and review stay on GTK; preparation, apply and prepared-descriptor retirement use GTask workers. An application hold covers dialogs, workers, cancellation and cleanup. No nested GTK loop or early worker-storage free is used.

Cancel before mutation leaves the filesystem unchanged. Closing a dialog retires prepared descriptors on a worker; cancelled work remains owned until completion. Workspace/request generation checks reject stale review/completion rather than applying it to a newer workspace. Cancellation is cooperative around filesystem calls; a blocked mount can delay cleanup/shutdown. Once the mutation syscall succeeds, a racing cancellation or shutdown does **not** turn that committed result into “cancelled” or attempt unsafe rollback. The apply barrier lasts through callback delivery, not just worker return.

## Source and validation

| Area | Files |
| --- | --- |
| Prepared descriptor snapshot, validation and syscalls | `src/workspace/operations_fs.zig` |
| Selection/input/review, workers, cancellation and refresh | `src/workspace/operations_controller.zig` |
| Process-wide admission/barrier and protected paths | `src/application.zig` |
| App, Explorer, session and action integration | `src/app.zig`, `src/workspace/controller.zig`, `src/workspace/session_controller.zig`, `src/workbench/commands.zig` |
| Backend regressions | `src/workspace/operations_test.zig`, included by `src/tests.zig` |
| Private native acceptance and build gates | `tests/operations.py`, `build.zig` |

From `subprojects/coral`:

```sh
# Native operations harness only:
zig build operations -Doptimize=safe -j1 --summary all
# Headless tests, widgets and native operations acceptance:
zig build test-m2-operations -Doptimize=safe -j1 --summary all
```

The native suite now contains **25 scenarios** covering real palette/menu/Explorer-button routing, filesystem success, cancellation for all five kinds, stale source/content/parent/root/collision review, invalid paths/types, own/peer clean and dirty documents and descendants, protected roots/manifests, unavailable-root aliases and lexical-parent dependencies, delayed apply/barrier, owner-close/Quit All, recovery buffers and repeated cleanup. Fixtures use private Wayland/D-Bus/HOME/XDG environments and disposable files, not the live desktop. Instrumented controls do not bypass preparation or explicit confirmation and are omitted from normal builds. These are bounded observed-race tests, not proof of hostile-race atomicity.

### Final validation — 2026-11-09

**All nine aggregate gates passed sequentially** with `-Doptimize=safe -j1 --summary all`, each bounded by **600,000 ms (600 seconds)**. The final operations run passed **25/25 scenarios together**, including the three physical-alias review regressions. No final regressions, timeouts or leaked test-session processes were reported.

| Final aggregate gate | Native results | Proof |
| --- | --- | --- |
| `test-m2-operations` | **25 operations** | [Log](../../../.cache/coral-operations-validation-logs/final-test-m2-operations.log) |
| `test-m2-windows` | **27 windows** | [Log](../../../.cache/coral-operations-validation-logs/final-test-m2-windows.log) |
| `test-m1` | **40 workflows, 14 group/history, 13 recovery** | [Log](../../../.cache/coral-operations-validation-logs/final-test-m1.log) |
| `test-m2-slice` | **18 workspace groups** | [Log](../../../.cache/coral-operations-validation-logs/final-test-m2-slice.log) |
| `test-m2-explorer` | **19 explorer groups** | [Log](../../../.cache/coral-operations-validation-logs/final-test-m2-explorer.log) |
| `test-m2-search` | **9 search groups** | [Log](../../../.cache/coral-operations-validation-logs/final-test-m2-search.log) |
| `test-m2-policy` | **17 policy groups** | [Log](../../../.cache/coral-operations-validation-logs/final-test-m2-policy.log) |
| `test-m2-sessions` | **19 session scenarios** | [Log](../../../.cache/coral-operations-validation-logs/final-test-m2-sessions.log) |
| `test-m2-docks` | **27 dock scenarios** | [Log](../../../.cache/coral-operations-validation-logs/final-test-m2-docks.log) |

Each of the **eight widget-including gates executed 191 widget-root tests**; `test-m2-slice` does not include widgets. The **four headless runners were cached** on the final rerun. Earlier fresh validation passed **305 main-root tests**, including **23 operation-backend tests and manager tests**. The 23 backend tests also passed in focused validation. These counts overlap transitively and across gates; they are **not additive unique-test totals**.

The subsequent production build, `zig build -Doptimize=safe -Dtest-hooks=false -j1 --summary all`, passed **46/46 steps**, with a **fresh 25-second executable compilation** rather than a cached executable success. See the [production build log](../../../.cache/coral-operations-validation-logs/final-build.log). This does not imply every dependency was rebuilt; dependency steps were cached/reused.

Historical runs remain accurate: the initial complete native suite passed **22 scenarios**, then the **three added alias-review scenarios passed separately**, before the final all-25 run. Earlier failures are retained: the `full-2` delay overflow was fixed, command-fixture list/count and headless missing-appearance-dependency build errors were fixed, and review-found physical-alias protection issues were fixed with native regressions included in the final suite. These earlier failures are not final-run failures. Earlier increment counts remain historical in the linked guides and [status report](WORKBENCH_STATUS.md).

Evidence: [operations results](../../../.cache/coral-operations/results.json), [final validation summary](../../../.cache/coral-operations-validation-logs/final-summary.log), [process cleanup check](../../../.cache/coral-operations-validation-logs/final-process-check.log), and the [validation log directory](../../../.cache/coral-operations-validation-logs/) (`final-<target>.log` and `final-build.log`). These are local evidence artifacts under `pearl/.cache/`, not bundled release files. Current operations-increment toolchain: **Zig 0.17.1, GTK 4.24.1, GtkSourceView 5.22.0 and Enchant 2.8.21**. These are historical file-operation-increment results, not counts for the later full M2 campaign.

## M2 closure and remaining boundaries

[Automatic projects, native recents/buffer pickers and reviewed root management](WORKBENCH_M2_PROJECTS.md) now complete mandatory M2 scope. Root Add/Remove/Save Workspace As are separate reviewed **manifest edits**, not Explorer rename/delete; they keep source documents open, preserve semantic settings/excludes/names and lexical path meaning, and validate source bytes/etag. They share process-wide apply admission but have their own documented checks.

**M2 implementation is COMPLETE; M3 is next.** See the [acceptance audit](WORKBENCH_M2_ACCEPTANCE.md) and [roadmap](WORKBENCH_IMPLEMENTATION_PLAN.md). Completion does not add trash, recursive delete, file-operation undo, cross-filesystem moves, open-document rebinding, LSP events or hostile-race atomicity. No later IDE milestone is claimed.
