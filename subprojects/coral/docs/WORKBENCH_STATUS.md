# Coral workbench implementation status

**In progress: native foundation batch. Not a completed M1 or M8 workbench.**

This report supplements the [M0–M8 roadmap](WORKBENCH_IMPLEMENTATION_PLAN.md). The [browser prototype](mockups/workbench/index.html) remains a design fixture; its workspace, Git, LSP and agent panels are not connected to the native application.

## Implemented and integrated

### Documents and views

- `src/editor/registry.zig` owns canonical documents and allocates process-wide, nonrecycled document IDs. Path lookup follows the document's current canonical path, including Save As.
- `src/document.zig` owns the GtkSourceView buffer, file metadata, search/spelling state and revision counter, not tab/view widgets. Revisions advance synchronously before controller observers, including undo/redo.
- `src/editor/view.zig` owns editor widgets, tab widgets, view IDs and saved caret/selection marks. The application keeps view and document collections separately.
- `src/app.zig` callbacks resolve their owning controller instead of using a global `App.instance`. Asynchronous file operations retain their existing application-lifetime protection.
- Tab teardown disconnects document-bound close/context callbacks before unparenting. Buffer teardown disconnects document callbacks even if a prepared transaction retains the buffer. Closing a tab restores typing focus to the remaining editor.

This is still a single-window, single-editor-group UI. The widget spike verifies shared-buffer views with independent saved selection positions and scroll adjustments. **GTK's visible insertion/selection marks are still buffer-wide.** Independent simultaneous selection rendering, editor-group UI and editable multibuffer excerpts remain open feasibility work; the spike is not claimed as finished split-editor support.

### Revision-checked editing

`src/editor/transactions.zig` provides prepare → preview accessors → commit for one or more buffers. It:

- Owns snapshots and replacement text; retains buffers without retaining a closed document.
- Checks document/buffer/revision identity, writable/busy policy, UTF-8 boundaries, NUL, ranges, duplicates, overlaps and ambiguous insertions before changing anything.
- Resolves current targets again at commit and rejects stale changes, even if an edit/undo returned to identical text.
- Applies descending range edits without resetting the entire buffer, preserving unaffected marks/tags and per-buffer undo history.
- Makes all fallible Zig allocations before mutation; successful commit cannot be replayed.

Native find/replace, replace-all and spelling corrections now use this boundary. Identical replacements do not create a dirty revision or undo entry. Edits during an asynchronous save remain permitted; the saved older revision does not clear newer dirty state.

Default limits are 128 targets, 65,536 replacements, 16 MiB per edited buffer (including intermediate growth), and 64 MiB combined snapshots/replacement bytes. The UI reports rejected oversized edits. The existing 128 MiB **file-load** limit is separate. Transactions do not save, stage, commit or execute commands.

Guarantees are validation atomicity, not isolation from synchronous GTK signal observers or atomic disk writes. Controller callbacks must not reenter arbitrary edits during application. Undo remains per buffer, not a workspace-wide journal; GLib allocation failures retain GLib's fatal-OOM behavior.

### Safe existing-file opens and loads

- `src/platform/open_target.zig` resolves existing regular local files and file URIs, with canonical symlink identity. Missing paths, directories, FIFOs/devices, malformed paths and nonlocal URIs are rejected without creating files or parents.
- `App.openExisting` replaces the old open-and-create behavior. **To create a file, use New document then Save As.** This is an intentional CLI behavior change too.
- `src/platform/load_file.zig` opens read-only/nonblocking in a GTask worker, verifies the opened descriptor is regular, then reads that same descriptor in bounded chunks. A file replaced by a FIFO cannot trap the loader in a blocking FIFO open; reload uses this same boundary.
- Loads preserve raw BOM/newline bytes for the existing codec. GIO-compatible etags are obtained through descriptor metadata at `/proc/self/fd/N`; no etag is guessed or sampled from a replacement at the original pathname.
- Descriptors close before completion; cancelled/oversized/failed loads do not return partial contents. Observable concurrent metadata changes across a read fail rather than accepting inconsistent data.

Linux procfs is required for the metadata bridge. This is not a filesystem sandbox or a universal coherent snapshot: in-place writes, timestamp resolution, FUSE/NFS stalls and GIO etag limitations still apply. Nonblocking open prevents the FIFO rendezvous, not all possible kernel stalls.

A native-only startup failure exposed a dangling local-VFS singleton in the installed GVfs backend after default-backend probing. The loader now uses GIO's selected native backend for the proc-fd metadata bridge; a regression test covers default-VFS initialization before loading. The original descriptor/type checks and etag validation remain intact.

### External-file changes and explicit reload

- Loaded/saved documents monitor their local file with GIO. Async type/etag queries update **Changed on disk** in the status bar; monitoring never modifies a buffer or marks it busy.
- Each document has at most one outstanding metadata query with coalesced pending events. Requests carry the controller, document ID and watcher generation, so closing a document or changing its Save As target cannot apply an old response to the wrong document.
- Monitors detach before document destruction; pending queries are cancelled/reaped. Application holds keep the controller alive through completion.
- Own-save notifications are compared against the committed etag, not treated as unrelated edits. Watcher reinstallation checks the load/save-to-watch gap.
- **Reload from Disk** is available through the editor menu and palette. Dirty documents require explicit discard confirmation. Failed reload, including a FIFO replacement, keeps the current buffer intact.
- Loads check the starting document revision before applying results and again after a large-file confirmation. Late edits cannot be overwritten by an older load; undo/redo is blocked while loading or awaiting acceptance. Cancelling a large reload preserves the original file identity even when the existing buffer is empty.

Detection is metadata/etag-based, not content hashing. Missing/inaccessible metadata is conservatively marked changed. Monitoring setup failures are surfaced; there is no full-tree polling fallback in this batch.

### Commands and native palette

`src/workbench/commands.zig` centralizes currently executable commands and metadata. Menu entries, GActions, common keyboard shortcuts and the palette use the same command dispatch.

**Ctrl+Shift+P** opens the native palette. It filters labels/action names/shortcut hints, supports keyboard selection and dispatch, reports no matches and dismisses with Escape. Cancelling restores the prior live focus widget—including Find/Replace fields—rather than redirecting typing into the document. The palette follows Coral's appearance. Navigation bubbles after entry/IME event handling; physical IME qualification remains pending.

Only implemented actions are listed; no fake Git/LSP/agent commands were added.

### Bounded subprocess foundation

`src/tasks/process.zig` is a tested async capture API for future short-lived backend commands. It owns argv/cwd/environment and request identity, requires explicit caller authorization, clears inherited environment unless allowed explicitly, drains stdout/stderr under a combined cap, and handles nonzero exit, signal, timeout, cancellation and exactly-once completion on the originating main context.

**It is not yet a user-facing terminal/task runner, OS sandbox, persistent protocol transport, or process-tree supervisor.** Cancellation kills/reaps only the direct child and closes capture pipes; descendant termination and PTY integration remain open. Completion may be delayed by an uninterruptible spawn/kernel operation. No provider/network service is enabled by adding this module.

## Validation completed

Toolchain/library versions used for this batch:

| Component | Version |
| --- | --- |
| Zig | 0.17.0 |
| Installed ZLS | 0.17.0 (availability recorded only; no Coral LSP integration yet) |
| GTK | 4.24.1 |
| GtkSourceView | 5.22.0 |
| Enchant | 2.8.21 |

Commands run from `subprojects/coral/`:

```sh
zig build test -Doptimize=safe
zig build -Doptimize=safe
zig build widgets -Doptimize=safe -- --aqueous-prefix /usr
zig build integration -Doptimize=safe -- --aqueous-prefix /usr --output /home/zoey/Projects/pearl/.cache/coral-workbench-native
```

- **Headless unit suite passed:** path resolution, document identity/lifetime, revision transitions, transaction Unicode/overlap/staleness/undo/allocation failure, loader FIFO/path-swap/limits/cancellation/etag behavior, selections, subprocess lifecycle and command/palette models.
- **12 display-backed widget tests passed** in a private Wayland session: retained-widget callback detachment, teardown ordering, saved selection/focus/scroll behavior and palette lifecycle, including transitively imported model tests.
- **39 native check groups passed** in a private Wayland session: palette dispatch/focus, external changes/deletion/atomic replacement, dirty reload decisions, own-save/Save As monitoring, FIFO reload, async reload edits, stale large-load acceptance, empty-file reload cancellation, canonical opens, Unicode transaction undo, save races/cancellation, spelling, format preservation, theme/narrow/scaled UI and existing large-file checks.
- Formatting and Git whitespace checks passed.
- Native evidence is under `pearl/.cache/coral-workbench-native/`; widget evidence is under `pearl/.cache/coral-widgets/`. These are local generated results, not replacements for the tracked historical `artifacts/native/` gallery.

`--aqueous-prefix /usr` uses this host's installed test compositor/tooling. It is an explicit alternative to the repository's prepared private prefix; do not infer portability or the historical fixture's provenance from these results. All application/config/file mutations in these suites use private test fixtures, not the live desktop or developer checkout.

## Milestone gates still open

| Milestone | Current state |
| --- | --- |
| M0 | Interactive design exists; native view/lifetime feasibility exercised. Frozen Zed behavior reference, full independent-pane rendering, editable excerpt and terminal spikes, benchmark baselines remain open. |
| M1 | Registry/view separation, command palette, checked edit transactions, external-file monitoring and bounded command capture implemented. Recovery/session journal, independent editor groups, workspace-wide undo/recovery semantics and complete process-tree lifecycle remain open. |
| M2 | Workspace/root identities, multi-root model, explorer/search, trust, settings/session restoration and multiple windows not implemented. |
| M3–M8 | LSP, Git workbench, terminal/tasks, native/ACP agents, MCP, DAP/test UI and extensions not implemented. |


No service subscriptions, model credentials, installed language servers, paid API calls or extension downloads are configured by this batch. No commits were created.

## Next implementation sequence

1. Complete M0's independent-view/excerpt decision and pin the target Zed behavior/version before claiming parity.
2. Implement versioned recovery snapshots and a session restore chooser with crash/disk-conflict fault-injection tests; preserve unrelated user edits.
3. Add workspace/root identities and trusted configuration boundaries, then native workspace navigation against the established document/transaction APIs.
4. Extend the process boundary for protocol transports and process-tree ownership before using it for LSP, tasks or agents.

Keep these gates visible. Passing the text-editor regression suite does not establish full workbench feature or security acceptance.
