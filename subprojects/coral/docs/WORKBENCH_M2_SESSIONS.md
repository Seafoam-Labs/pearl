# M2: explicit workspace sessions

**Implemented and validated: the explicit checkpoint remains separate from crash recovery and automatic projects. M2 implementation is COMPLETE for the bounded workspace preview; M3 is next.** This guide describes the original explicit-slot increment and retains its historical evidence. [Automatic project/window snapshots and startup](WORKBENCH_M2_PROJECTS.md) are now delivered in a different store; they never overwrite `sessions/current`. [Independent windows](WORKBENCH_M2_WINDOWS.md) retain desired internal [dock layout](WORKBENCH_M2_DOCKS.md), not desktop window positions. See the [M2 acceptance audit](WORKBENCH_M2_ACCEPTANCE.md).

## Use

1. Open a folder or `.coral-workspace`, arrange tabs/groups/excerpts, and choose **Save Workspace Session** in **Ctrl+Shift+P**.
2. Wait for the saved confirmation. The checkpoint survives graceful exit. Later edits, closing tabs and choosing **Discard** do not modify this explicitly saved checkpoint.
3. On a later launch, choose **Restore Workspace Session**. If a workspace is already active, choose **Close workspace** first; that keeps its documents. Pending startup recovery, file/workspace operations and dialogs must finish first.

This explicit slot has no automatic restore or quit-time save; the automatic project catalog does. Explicit CLI files/workspaces and real recovery decisions take precedence over automatic startup, clearing prior membership without deleting recents. Empty recovery directories do not suppress it. Restore preserves existing documents, including dirty and unnamed buffers, and appends restored groups/views. Repeated restore can therefore create additional copies. It does not create isolated per-workspace tab sets.

**One shared slot:** another successful explicit Save Workspace Session replaces the previous checkpoint, even for another project or Coral application variant. Only one session operation is admitted across all windows in this process; concurrent requests receive Busy. Cross-process reads/writes use nonblocking locks. Sequential writers are last-accepted-save wins, not compare-and-swap: the API cannot detect a snapshot captured before another process completed its save. This is not a backup/history service.

## What is restored

- Folder/manifest source and supplied path; saved root paths/display names for diagnostics.
- Canonical document sharing, ordered tabs, current equal-width horizontal groups, active tab/group, directed Unicode selections, logical vertical/horizontal scrolling and source-mapped editable excerpts.
- Document text, BOM/newline metadata and saved disk etags, within the existing recovery caps.
- Desired Explorer/Search dock placement, visibility, active panel and sizes (v2). Layout applies only after successful restoration; v1 restores defaults.

The source manifest and folder settings are **reread**, not replaced with saved configuration. Current manifest roots/names/excludes/settings win if the manifest changed. Lexical `.` and `..` root components are preserved, not normalized across symlinks. Missing roots remain unavailable; no project paths are created. A missing/unreadable/invalid manifest **aborts restore** and reports the saved roots; these are not a fallback manifest. The checkpoint is kept for retry after repairing or restoring the manifest.

**File-operation coordination:** [explicit Explorer mutations](WORKBENCH_M2_OPERATIONS.md) refuse pending session/recovery work, and their process-wide apply barrier refuses Save/Restore Workspace Session until the completion callback. Any unavailable root or lexical `..` in any open process workspace's root/manifest blocks **all mutations** with `WorkspaceBusy`, even in another window. Such paths still load/roundtrip as described above. Close the affected workspace or reopen verified available normalized/canonical paths; do not blindly collapse `..` across symlinks. This does not change the session schema or the separate automatic project catalog.

Trust is not part of the session format. Loading uses the normal watched workspace/settings pipeline and separate machine-owned trust revalidation. A matching independently stored approval may be accepted by that controller; changed identities or policy require approval under its existing rules. Session restore never runs tasks, language servers, agents or hooks.

### File conflicts and dirty buffers

| Saved document | Restore behavior |
| --- | --- |
| Clean, regular local file, same decoded contents/BOM/newlines and saved etag | Rebind with the **saved** etag and file monitoring |
| Dirty or unnamed | Pathless dirty copy; use Save As |
| Changed disk contents/etag, missing etag, or already-open bound path | Pathless dirty conflict copy; existing document/file unchanged |
| Missing, unreadable, nonregular file | Pathless dirty unavailable copy; no creation or writes |

Verification is bounded and worker-owned. It pins a regular descriptor and compares contents plus before/after metadata; Linux `/proc/self/fd` supplies GIO metadata. It is not a filesystem sandbox or a universal atomic snapshot against hostile/network filesystems. Later changes remain subject to monitoring and conditional-save conflict handling; the saved etag is never silently refreshed to authorize overwriting newer content.

Combined existing-plus-restored caps are checked again after asynchronous workspace loading. Failure rolls back newly appended documents/groups and the workspace installed by this restore, preserving existing work. Request-token guards prevent rollback or late completion from removing a newer user-selected workspace.

## Storage, bounds and failure behavior

The single slot is `$XDG_STATE_HOME/coral/sessions/current`, normally `~/.local/state/coral/sessions/current`:

- Existing, user-owned state home required; no implicit creation of its ancestors. Traversal uses checked no-symlink descriptors, with search-only ancestors supported.
- `coral/sessions` directories are private `0700`; `current` is an owner-only regular, single-link `0600` file. Contents include source text and are **not encrypted**.
- Independent **session v2** envelope: SHA-256 over a bounded workspace/layout descriptor plus the existing versioned recovery payload. V1 remains readable with default dock layout; the next explicit save upgrades it. Older binaries refuse v2. Native paths are base64; checksums detect corruption, not malicious same-UID tampering. Unknown fields/versions fail closed.
- At most **32 roots**, **4,096 bytes/path or saved name**, **1 MiB descriptor**. Recovery bounds remain **128 documents, 64 groups, 256 views, 4 MiB/document, 8 MiB total text and 12 MiB encoded recovery payload**. The complete session cap includes that payload, descriptor, separator and fixed header.
- One operation per controller, owned snapshot, GTask worker and application hold. No storage/encoding/fsync or file verification on the GTK submit thread; bounded buffer capture still runs on GTK.
- Publication: exclusive directory lock → validate previous checkpoint → write private temporary file → file fsync → atomic rename → directory fsync. Load holds a shared lock. Corrupt, unsafe, oversized and unsupported existing checkpoints are retained and block replacement, rather than being silently destroyed.
- A pre-rename failure leaves the previous slot intact. **DurabilityUncertain** means rename committed but durability is unconfirmed; the UI does not promise the old slot survived.
- Closing/switching rejects stale UI completion and reaps owned work. An already accepted explicit save can still finish and publish its captured checkpoint after switching/closing. Filesystem calls are not forcibly interruptible; shutdown can wait for the hold.

There is no in-app deletion/quarantine/history picker for this explicit slot. **Forget Recent Session** manages only automatic catalog records, never this file. If an unsupported/corrupt checkpoint blocks saving, preserve it separately and remove it from the slot only as an explicit manual decision.

## Relationship to crash recovery

M1 journals remain under `coral/recovery`, with their existing debounce, crash chooser, v1/v2 compatibility and explicit disposition. Recovery still restores documents/layout as unsaved copies, **not workspace roots**. The saved-session file is independent and never removed by resolving/discarding a recovery journal or closing a document. Resolve the startup recovery chooser before invoking session commands; restoring both is explicit and can yield duplicate copies.

Shared capture/layout helpers do not change recovery's pathless-copy policy. No recovery format migration was required for this increment.

## Implementation and validation

| Area | Files |
| --- | --- |
| Session format and ownership | `src/workspace/session_model.zig` |
| Descriptor persistence and publication | `src/workspace/session_fs.zig` |
| Worker lifecycle, verification and restore | `src/workspace/session_controller.zig` |
| Shared layout capture/restore | `src/workspace/recovery_controller.zig` |
| App/command/workspace integration | `src/app.zig`, `src/workbench/commands.zig`, `src/workspace/controller.zig` |
| Backend and native regressions | `src/workspace/session_test.zig`, `tests/sessions.py` |

From `subprojects/coral`:

```sh
zig build session-unit -Doptimize=safe -j1
zig build sessions -Doptimize=safe -j1
zig build test-m2-sessions -Doptimize=safe -j1 --summary all
```

Backend tests are also included in `zig build test`, in a **separate process** because publication/death tests fork. Native tests use disposable files and private HOME/XDG/Wayland sessions, never the live desktop.

**Original session-increment validation on Zig 0.17.1 (2026-11-09):** all sequential safe gates passed: `test-m2-sessions`, `test-m1`, `test-m2-slice`, `test-m2-explorer`, `test-m2-search`, `test-m2-policy`, followed by a production build with `-Dtest-hooks=false`. The session gate executed **265 main headless tests, 18 separate session tests, 181 widget-root tests and 19 native session scenarios**. Trust/appearance runners were cached successes; counts overlap transitively and must not be added as unique tests. Existing native gates passed **40 workflows, 14 group/history checks, 13 recovery groups, 18 workspace groups, 19 explorer groups, nine search groups and 17 policy groups**.

The 19 session scenarios cover layout/Unicode/scroll/excerpts, roots/clean rebinding, dirty/conflict/missing/special files, existing CLI and dirty-document preservation, explicit-only restart/Discard behavior, trust/config revalidation, malformed/future retention, cap refusal, lexical root spelling, stale callbacks, shutdown, and post-load rollback/retry with newer-workspace protection. Backend tests also cover locks, privacy/symlinks, interrupted publication and process death. Formatting, Python compilation and diff whitespace checks passed.

Evidence: `pearl/.cache/coral-sessions/results.json` and adjacent native logs/screenshots; full gate logs under `pearl/.cache/coral-session-validation-logs/`. Earlier focused runs remain in `coral-sessions-review-run2/` as additional evidence.

**Dock follow-up:** session v2 and v1 migration are now tested by the [27-scenario native dock gate](WORKBENCH_M2_DOCKS.md). The existing 19 session scenarios also pass after the schema upgrade; their future-version fixture no longer assumes a v1 writer. The separate backend root is now `src/session_tests.zig` and includes 23 tests with transitive layout checks.

[Multi-window lifecycle](WORKBENCH_M2_WINDOWS.md) is now implemented; restore affects only its requesting window and the explicit checkpoint remains shared. [Bounded explicit file operations](WORKBENCH_M2_OPERATIONS.md) are delivered, with separate confirmation for every kind and refusal of all affected open documents, clean or dirty, across windows—not in-place rebinding. [Final file-operation validation](WORKBENCH_M2_OPERATIONS.md#final-validation--2026-11-09) passed all 25 native scenarios together, all nine aggregate gates and a fresh hooks-disabled production build. The session gate again passed 19 native scenarios and executed 191 widget tests; the validation counts above remain historical session/dock evidence. The [automatic-project/root-management increment](WORKBENCH_M2_PROJECTS.md) now closes mandatory M2 scope with a separate catalog, native recents/buffer pickers and ordinary multi-window startup. The [acceptance audit](WORKBENCH_M2_ACCEPTANCE.md) records current evidence without relabelling these historical counts. Missing-manifest fallback remains unsupported; M3 is next and no LSP/Git/agent parity is claimed.
